import CryptoKit
import Foundation

/// Where a ready model's files live.
public enum Tier: Sendable, Equatable { case shared, `private` }

public enum ModelState: Sendable, Equatable {
    /// Every file is on this device and this app holds it. Just open it.
    case ready(Tier)
    /// Another app of ours already downloaded it into the shared store. [ModelLibrary.adopt] uses it with no network.
    case sharedAvailable
    /// Something has to be downloaded: [bytes] still to fetch, [partial] of them already fetched and resumable.
    case missing(bytes: Int64, partial: Int64)
}

/// A model ready for an engine: one local file URL per catalog file name.
public struct OpenModel: Sendable {
    public let model: Model
    public let tier: Tier
    let urls: [String: URL]
    public func url(_ fileName: String) throws -> URL {
        guard let u = urls[fileName] else { throw ModelLibraryError.unknownFile(model.id, fileName) }
        return u
    }
}

/**
 Shared on-device models for Apple platforms. One copy per device, found by SHA-256.

 - **Shared store**: an App Group container that all our apps list in their entitlements (same team only).
   Files sit at `Garden/blobs/<sha256>`. Each app that uses a file leaves a marker at
   `Garden/users/<sha256>/<appID>`. A file is deleted when the last marker goes. Pass `sharedContainer: nil`
   when the app has no App Group: the Model Library then works with only the private store.
 - **Private store**: the app's own Application Support. Used when there's no shared store or the user says
   "keep it in this app".
 - Nothing is ever handed to an engine unless every file is present at its catalog size.

 All calls do file I/O: call them off the main thread.
 */
public final class ModelLibrary: Sendable {
    public let catalog: Catalog
    public let appID: String
    let shared: URL?
    let priv: URL
    let attempts: Int
    let retryDelay: Duration
    let configuration: URLSessionConfiguration

    /// - Parameters:
    ///   - appID: this app's name in the shared store's markers, e.g. its bundle id.
    ///   - sharedContainer: the App Group container (see [appGroupContainer]), or nil for no shared tier.
    ///   - privateDirectory: defaults to `Application Support/Garden`.
    ///   - catalog: this app's models (e.g. `Catalog.bundled("my-models")`).
    public init(appID: String, sharedContainer: URL?, privateDirectory: URL? = nil, catalog: Catalog,
                downloadAttempts: Int = 3, retryDelay: Duration = .seconds(2),
                configuration: URLSessionConfiguration = .default) throws {
        precondition(appID.wholeMatch(of: /[A-Za-z0-9._\-]{1,128}/) != nil, "appID must be a plain name like a bundle id")
        self.appID = appID
        self.catalog = catalog
        // "Garden": the library's old name, kept on purpose. Phones and apps on older versions use these folders.
        self.shared = sharedContainer?.appendingPathComponent("Garden", isDirectory: true)
        self.priv = try privateDirectory ?? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Garden", isDirectory: true)
        self.attempts = max(1, downloadAttempts)
        self.retryDelay = retryDelay
        self.configuration = configuration
        try Self.makeDir(priv.appendingPathComponent("blobs"))
        try Self.makeDir(priv.appendingPathComponent("partial"))
        if let s = shared {
            try Self.makeDir(s.appendingPathComponent("blobs"))
            try Self.makeDir(s.appendingPathComponent("users"))
        }
    }

    /// The App Group container, or nil when this build has no such group (e.g. a free personal team).
    public static func appGroupContainer(_ groupID: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    public var hasSharedStore: Bool { shared != nil }

    // MARK: State

    public func state(_ id: String) throws -> ModelState {
        let m = try catalog.model(id)
        var mine = [Tier](), available = true, missing: Int64 = 0, partial: Int64 = 0
        for f in m.files {
            if let t = held(f) { mine.append(t); continue }
            if sharedPresent(f) { continue }
            available = false
            missing += f.size
            partial += min(Self.size(partialURL(f)) ?? 0, f.size)
        }
        if mine.count == m.files.count { return .ready(mine.contains(.shared) ? .shared : .private) }
        if available { return .sharedAvailable }
        return .missing(bytes: missing, partial: partial)
    }

    /// Opens the model for an engine. Throws [ModelLibraryError.notReady] rather than hand over a missing or short file.
    public func open(_ id: String) throws -> OpenModel {
        let m = try catalog.model(id)
        var urls = [String: URL](), tiers = [Tier]()
        for f in m.files {
            guard let t = held(f) else { throw ModelLibraryError.notReady(id, "\(f.name) isn't on this device") }
            urls[f.name] = t == .private ? privateURL(f) : sharedURL(f)!
            tiers.append(t)
        }
        return OpenModel(model: m, tier: tiers.contains(.shared) ? .shared : .private, urls: urls)
    }

    // MARK: Getting a model

    /// Starts using the shared copy another app downloaded. No network.
    public func adopt(_ id: String) throws {
        let m = try catalog.model(id)
        try withSharedLock {
            for f in m.files where held(f) == nil {
                guard sharedPresent(f) else { throw ModelLibraryError.notReady(id, "\(f.name) isn't in the shared store") }
                try mark(f)
            }
        }
    }

    /**
     Downloads whatever is missing, resuming partial files and trying each url in turn. Files already in the
     shared store are adopted instead of downloaded. With [share] (and a shared store) the new files go to the
     shared store for our other apps; otherwise they stay private to this app.
     [onProgress] gets (bytes done, bytes total) for the files being fetched. Cancel the Task to stop; the
     partial files are kept for next time.
     */
    public func download(_ id: String, share: Bool = true,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) async throws {
        let m = try catalog.model(id)
        var todo = [ModelFile]()
        for f in m.files where held(f) == nil {
            if sharedPresent(f) { try withSharedLock { try mark(f) } } else { todo.append(f) }
        }
        let total = todo.reduce(0) { $0 + $1.size }
        var before: Int64 = 0
        for f in todo {
            let base = before
            try await fetch(f) { onProgress(base + $0, total) }
            try place(f, from: partialURL(f), share: share)
            before += f.size
        }
        onProgress(total, total)
    }

    /// Moves files this app already has (e.g. bundled in the app, or an old private copy) into the Model Library without a
    /// download. [source] returns a file URL for a catalog file, or nil. Every file is SHA-checked; files are copied.
    public func contribute(_ id: String, share: Bool = true, source: (ModelFile) -> URL?) throws {
        let m = try catalog.model(id)
        for f in m.files where held(f) == nil {
            if sharedPresent(f) { try withSharedLock { try mark(f) }; continue }
            guard let src = source(f) else { continue }
            guard Self.size(src) == f.size, try Self.sha256(src) == f.sha256 else { throw ModelLibraryError.checksum(f.name) }
            let tmp = partialURL(f).appendingPathExtension("in")
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.copyItem(at: src, to: tmp)
            try place(f, from: tmp, share: share)
        }
    }

    /// Lets go of a model: this app's private copy is deleted, and its hold on shared files is released.
    /// A shared file is deleted only when no app holds it any more.
    public func remove(_ id: String) throws {
        let m = try catalog.model(id)
        for f in m.files {
            try? FileManager.default.removeItem(at: privateURL(f))
            try? FileManager.default.removeItem(at: partialURL(f))
        }
        guard shared != nil else { return }
        try withSharedLock {
            for f in m.files {
                let users = usersDir(f)
                try? FileManager.default.removeItem(at: users.appendingPathComponent(appID))
                let left = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
                if left.isEmpty {
                    try? FileManager.default.removeItem(at: sharedURL(f)!)
                    try? FileManager.default.removeItem(at: users)
                }
            }
        }
    }

    /// Which apps hold a shared file (for a settings screen). Markers of apps that were deleted stay until a
    /// user removes the model from every remaining app; iOS gives no way to see other apps' installs.
    public func holders(_ id: String) throws -> Set<String> {
        guard shared != nil else { return [] }
        return try catalog.model(id).files.reduce(into: Set<String>()) { s, f in
            s.formUnion((try? FileManager.default.contentsOfDirectory(atPath: usersDir(f).path)) ?? [])
        }
    }

    // MARK: Internals

    func privateURL(_ f: ModelFile) -> URL { priv.appendingPathComponent("blobs/\(f.sha256)") }
    func partialURL(_ f: ModelFile) -> URL { priv.appendingPathComponent("partial/\(f.sha256)") }
    func sharedURL(_ f: ModelFile) -> URL? { shared?.appendingPathComponent("blobs/\(f.sha256)") }
    func usersDir(_ f: ModelFile) -> URL { shared!.appendingPathComponent("users/\(f.sha256)", isDirectory: true) }

    /// Shared files are only ever moved in whole and SHA-checked, so a right-sized file is a good one.
    func sharedPresent(_ f: ModelFile) -> Bool { sharedURL(f).map { Self.size($0) == f.size } ?? false }

    func held(_ f: ModelFile) -> Tier? {
        if Self.size(privateURL(f)) == f.size { return .private }
        if sharedPresent(f), FileManager.default.fileExists(atPath: usersDir(f).appendingPathComponent(appID).path) {
            return .shared
        }
        return nil
    }

    func mark(_ f: ModelFile) throws {
        let dir = usersDir(f)
        try Self.makeDir(dir)
        try Data().write(to: dir.appendingPathComponent(appID))
    }

    /// Moves a verified file into its store. If another app put the same file in the shared store meanwhile,
    /// ours is dropped and theirs used.
    func place(_ f: ModelFile, from src: URL, share: Bool) throws {
        let fm = FileManager.default
        if share, let dst = sharedURL(f) {
            try withSharedLock {
                if sharedPresent(f) { try? fm.removeItem(at: src) } else {
                    try? fm.removeItem(at: dst)
                    try fm.moveItem(at: src, to: dst)
                }
                try mark(f)
            }
            try? fm.removeItem(at: privateURL(f))
        } else {
            try? fm.removeItem(at: privateURL(f))
            try fm.moveItem(at: src, to: privateURL(f))
        }
    }

    /// Serialises adopt/place/remove across our apps (flock on a file in the shared container).
    func withSharedLock<T>(_ body: () throws -> T) throws -> T {
        guard let s = shared else { return try body() }
        let fd = Darwin.open(s.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    static func makeDir(_ u: URL) throws {
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues()
        v.isExcludedFromBackup = true  // models can always be downloaded again
        var u = u
        try? u.setResourceValues(v)
    }

    static func size(_ u: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.int64Value
    }

    static func sha256(_ u: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: u)
        defer { try? h.close() }
        var sha = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { sha.update(data: d) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
