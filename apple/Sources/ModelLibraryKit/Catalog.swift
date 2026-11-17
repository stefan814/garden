import Foundation

/// One file of a model, pinned by size and SHA-256. Every url serves exactly these bytes.
public struct ModelFile: Codable, Sendable, Hashable {
    public let name: String
    public let size: Int64
    public let sha256: String
    public let urls: [URL]

    public init(name: String, size: Int64, sha256: String, urls: [URL]) {
        self.name = name; self.size = size; self.sha256 = sha256; self.urls = urls
    }
}

/// A model: one or more files an engine loads together. [id] and the file names are this app's own words for it;
/// sharing between apps goes by each file's SHA-256 alone, so two apps may call the same file anything they like.
public struct Model: Codable, Sendable, Hashable {
    public let id: String
    public let files: [ModelFile]
    public let title: String
    public let capability: String
    public let license: String

    public init(id: String, files: [ModelFile], title: String? = nil, capability: String = "", license: String = "") {
        self.id = id; self.files = files; self.title = title ?? id; self.capability = capability; self.license = license
    }

    public init(from decoder: Decoder) throws {
        enum K: String, CodingKey { case id, files, title, capability, license }
        let c = try decoder.container(keyedBy: K.self)
        self.init(id: try c.decode(String.self, forKey: .id), files: try c.decode([ModelFile].self, forKey: .files),
                  title: try c.decodeIfPresent(String.self, forKey: .title),
                  capability: try c.decodeIfPresent(String.self, forKey: .capability) ?? "",
                  license: try c.decodeIfPresent(String.self, forKey: .license) ?? "")
    }

    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public func file(_ name: String) throws -> ModelFile {
        guard let f = files.first(where: { $0.name == name }) else { throw ModelLibraryError.unknownFile(id, name) }
        return f
    }
}

/// The models one app uses. Each app brings its own (any model, from anywhere): the Model Library shares a file with every other
/// app that lists the same bytes (same SHA-256), whatever either app calls it. Build one in code or with [parse].
public struct Catalog: Sendable {
    /// The JSON layout version ("format"; older files call it "scheme"). Only 1 exists.
    public static let format = 1
    public let models: [Model]

    /// [allowSameFile] is for tests only: within one app's list a file must not be in two models, or removing one
    /// model would take the file away from the other.
    public init(models: [Model], allowSameFile: Bool = false) throws {
        try Self.validate(models, allowSameFile: allowSameFile)
        self.models = models
    }

    public func model(_ id: String) throws -> Model {
        guard let m = models.first(where: { $0.id == id }) else { throw ModelLibraryError.unknownModel(id) }
        return m
    }

    public func models(for capability: String) -> [Model] { models.filter { $0.capability == capability } }

    /// A catalog JSON file in this app's bundle.
    public static func bundled(_ name: String, in bundle: Bundle = .main) throws -> Catalog {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw ModelLibraryError.badCatalog("\(name).json isn't in the app's bundle")
        }
        return try parse(Data(contentsOf: url))
    }

    /// {"format": 1, "models": [{"id", "files": [{"name", "size", "sha256", "urls"}], "title"?, "capability"?,
    /// "license"?}]}. "format" may be left out.
    public static func parse(_ data: Data, allowSameFile: Bool = false) throws -> Catalog {
        struct Root: Decodable { let format: Int?; let scheme: Int?; let models: [Model] }
        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) } catch { throw ModelLibraryError.badCatalog("\(error)") }
        let f = root.format ?? root.scheme ?? format
        guard f == format else { throw ModelLibraryError.badCatalog("format \(f), ModelLibraryKit knows \(format)") }
        return try Catalog(models: root.models, allowSameFile: allowSameFile)
    }

    private static func validate(_ models: [Model], allowSameFile: Bool) throws {
        func check(_ ok: Bool, _ why: @autoclosure () -> String) throws { if !ok { throw ModelLibraryError.badCatalog(why()) } }
        let id = /[a-z0-9][a-z0-9.\-]{0,47}/, name = /[A-Za-z0-9][A-Za-z0-9._\-]{0,47}/, sha = /[0-9a-f]{64}/
        var ids = Set<String>(), hashes = [String: String]()
        for m in models {
            try check(m.id.wholeMatch(of: id) != nil, "bad model id '\(m.id)'")
            try check(ids.insert(m.id).inserted, "duplicate model id '\(m.id)'")
            try check(!m.files.isEmpty, "\(m.id) has no files")
            var names = Set<String>()
            for f in m.files {
                try check(f.name.wholeMatch(of: name) != nil, "\(m.id): bad file name '\(f.name)'")
                try check(names.insert(f.name).inserted, "\(m.id): duplicate file '\(f.name)'")
                try check(f.sha256.wholeMatch(of: sha) != nil, "\(m.id)/\(f.name): sha256 must be 64 lowercase hex")
                try check(f.size > 0, "\(m.id)/\(f.name): size must be positive")
                try check(f.urls.allSatisfy { ["https", "http"].contains($0.scheme ?? "") }, "\(m.id)/\(f.name): bad url")
                if let other = hashes.updateValue("\(m.id)/\(f.name)", forKey: f.sha256), !allowSameFile {
                    try check(false, "\(m.id)/\(f.name) is the same file as \(other)")
                }
            }
        }
    }
}

public enum ModelLibraryError: Error, LocalizedError, Equatable {
    case unknownModel(String)
    case unknownFile(String, String)
    case badCatalog(String)
    /// The model isn't fully on this device. Never hand an engine a file that isn't there.
    case notReady(String, String)
    case checksum(String)
    case download(String, String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): "No model '\(id)' in this app's model list"
        case .unknownFile(let id, let f): "\(id) has no file \(f)"
        case .badCatalog(let why): "Bad model list: \(why)"
        case .notReady(let id, let why): "Model '\(id)' isn't ready: \(why)"
        case .checksum(let f): "\(f) didn't match its SHA-256; it will be downloaded again"
        case .download(let f, let why): "Couldn't download \(f): \(why)"
        }
    }
}
