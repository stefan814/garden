import Foundation

/// One file of a model, pinned by size and SHA-256. Every url serves exactly these bytes.
public struct ModelFile: Codable, Sendable, Hashable {
    public let name: String
    public let size: Int64
    public let sha256: String
    public let urls: [URL]
}

/// A model: one or more files an engine loads together.
public struct Model: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let capability: String
    public let license: String
    public let files: [ModelFile]

    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public func file(_ name: String) throws -> ModelFile {
        guard let f = files.first(where: { $0.name == name }) else { throw GardenError.unknownFile(id, name) }
        return f
    }
}

/// The shared list of models, the same file the Android library reads (catalog/garden-catalog.json).
public struct Catalog: Sendable {
    public static let scheme = 1
    public let models: [Model]

    public func model(_ id: String) throws -> Model {
        guard let m = models.first(where: { $0.id == id }) else { throw GardenError.unknownModel(id) }
        return m
    }

    public func models(for capability: String) -> [Model] { models.filter { $0.capability == capability } }

    /// The catalog bundled with GardenKit.
    public static func bundled() throws -> Catalog { try parse(Data(contentsOf: bundledURL())) }

    static func bundledURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "garden-catalog", withExtension: "json") else {
            throw GardenError.badCatalog("garden-catalog.json is missing from GardenKit's bundle")
        }
        return url
    }

    /// [allowSameFile] is for test catalogs only: real ones must not list one file in two models.
    public static func parse(_ data: Data, allowSameFile: Bool = false) throws -> Catalog {
        struct Root: Decodable { let scheme: Int; let models: [Model] }
        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) } catch { throw GardenError.badCatalog("\(error)") }
        guard root.scheme == scheme else { throw GardenError.badCatalog("scheme \(root.scheme), GardenKit knows \(scheme)") }
        try validate(root.models, allowSameFile: allowSameFile)
        return Catalog(models: root.models)
    }

    private static func validate(_ models: [Model], allowSameFile: Bool) throws {
        func check(_ ok: Bool, _ why: @autoclosure () -> String) throws { if !ok { throw GardenError.badCatalog(why()) } }
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

public enum GardenError: Error, LocalizedError, Equatable {
    case unknownModel(String)
    case unknownFile(String, String)
    case badCatalog(String)
    /// The model isn't fully on this device. Never hand an engine a file that isn't there.
    case notReady(String, String)
    case checksum(String)
    case download(String, String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): "No model '\(id)' in the Garden catalog"
        case .unknownFile(let id, let f): "\(id) has no file \(f)"
        case .badCatalog(let why): "Bad Garden catalog: \(why)"
        case .notReady(let id, let why): "Model '\(id)' isn't ready: \(why)"
        case .checksum(let f): "\(f) didn't match its SHA-256; it will be downloaded again"
        case .download(let f, let why): "Couldn't download \(f): \(why)"
        }
    }
}
