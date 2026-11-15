import CryptoKit
import Foundation
import Testing
@testable import GardenKit

/// Repo root, from this file's path (apple/Tests/GardenKitTests/GardenTests.swift).
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

func tempDir(_ name: String) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("garden-tests/\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// The fault-injecting server the Android tests use (android/tests/server.py), on its own port, serving
/// random files made for these tests.
final class TestServer: @unchecked Sendable {
    static let shared = try! TestServer()
    let root: URL, log: URL, port = Int.random(in: 20000...40000)
    private let proc = Process()
    private let keepAlive = Pipe()  // the server is killed when this test process exits and the pipe closes

    init() throws {
        root = try tempDir("server")
        log = root.appendingPathComponent("requests.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "python3 \"$0\" \"$1\" \"$2\" \"$3\" & p=$!; read _; kill $p",
                          repo.appendingPathComponent("android/tests/server.py").path, root.path, log.path, "\(port)"]
        proc.standardInput = keepAlive
        try proc.run()
        for _ in 0..<50 {  // wait for it to listen
            if (try? Data(contentsOf: URL(string: "http://127.0.0.1:\(port)/dead/x")!)) != nil || ping() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    private func ping() -> Bool {
        let s = socket(AF_INET, SOCK_STREAM, 0); defer { close(s) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(port).bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    /// Writes a random file the server will serve; returns (name, size, sha).
    func file(_ name: String, size: Int) throws -> (String, Int, String) {
        var d = Data(count: size)
        d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, size) }
        try d.write(to: root.appendingPathComponent(name))
        return (name, size, hex(d))
    }

    func url(_ mode: String, _ name: String) -> String { "http://127.0.0.1:\(port)/\(mode)/\(name)" }

    func requests(_ name: String) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { $0.contains(" \(name) ") }
    }
}

/// A test catalog of one-file models: (id, file name, size, sha, urls).
func catalog(_ models: [(String, String, Int, String, [String])]) throws -> Catalog {
    let ms = models.map { id, name, size, sha, urls in
        #"{"id":"\#(id)","title":"t","capability":"test","license":"","files":[{"name":"\#(name)","size":\#(size),"sha256":"\#(sha)","urls":[\#(urls.map { "\"\($0)\"" }.joined(separator: ","))]}]}"#
    }
    return try Catalog.parse(Data(#"{"scheme":1,"models":[\#(ms.joined(separator: ","))]}"#.utf8), allowSameFile: true)
}

func garden(_ app: String, shared: URL?, _ c: Catalog) throws -> Garden {
    try Garden(appID: app, sharedContainer: shared, privateDirectory: try tempDir("private-\(app)"), catalog: c,
               downloadAttempts: 2, retryDelay: .milliseconds(50))
}

@Suite struct CatalogTests {
    @Test func bundledCatalogIsTheRepoCatalog() throws {
        let root = try Data(contentsOf: repo.appendingPathComponent("catalog/garden-catalog.json"))
        let bundled = try Data(contentsOf: try Catalog.bundledURL())
        #expect(root == bundled, "apple/Sources/GardenKit/garden-catalog.json must be a copy of catalog/garden-catalog.json")
        let c = try Catalog.bundled()
        #expect(c.models.map(\.id).contains("parakeet-tdt-110m-en-int8"))
        #expect(try c.model("parakeet-tdt-110m-en-int8").files.count == 4)
    }

    @Test func rejectsBadCatalogs() {
        let sha = String(repeating: "a", count: 64)
        func json(_ files: String, id: String = "m", scheme: Int = 1) -> Data {
            Data(#"{"scheme":\#(scheme),"models":[{"id":"\#(id)","title":"t","capability":"c","license":"","files":[\#(files)]}]}"#.utf8)
        }
        let f = #"{"name":"a.onnx","size":1,"sha256":"\#(sha)","urls":["https://x/a"]}"#
        #expect(throws: Never.self) { try Catalog.parse(json(f)) }
        #expect(throws: GardenError.self) { try Catalog.parse(json(f, scheme: 2)) }
        #expect(throws: GardenError.self) { try Catalog.parse(json(f, id: "Bad Id")) }
        #expect(throws: GardenError.self) { try Catalog.parse(json(f.replacingOccurrences(of: sha, with: "ABC"))) }
        #expect(throws: GardenError.self) { try Catalog.parse(json(f.replacingOccurrences(of: "https", with: "file"))) }
        #expect(throws: GardenError.self) { try Catalog.parse(json("\(f),\(f)")) }  // same name twice
        let g = f.replacingOccurrences(of: "a.onnx", with: "b.onnx")
        #expect(throws: GardenError.self) { try Catalog.parse(json("\(f),\(g)")) }  // same file twice
        #expect(throws: Never.self) { try Catalog.parse(json("\(f),\(g)"), allowSameFile: true) }
    }
}

@Suite(.serialized) struct StoreTests {
    let s = TestServer.shared

    @Test func twoAppsShareOneCopy() async throws {
        let (n, size, sha) = try s.file("share.bin", size: 300_000)
        let c = try catalog([("m", n, size, sha, [s.url("ok", n)])])
        let group = try tempDir("group")
        let a = try garden("app.a", shared: group, c), b = try garden("app.b", shared: group, c)

        #expect(try a.state("m") == .missing(bytes: Int64(size), partial: 0))
        #expect(throws: GardenError.self) { try a.open("m") }
        try await a.download("m", share: true)
        #expect(try a.state("m") == .ready(.shared))
        #expect(try b.state("m") == .sharedAvailable)
        #expect(throws: GardenError.self) { try b.open("m") }  // not B's until it adopts

        let before = s.requests(n).count
        try b.adopt("m")
        #expect(try b.state("m") == .ready(.shared))
        #expect(s.requests(n).count == before, "adopt must not touch the network")
        #expect(try a.open("m").url(n) == b.open("m").url(n))
        #expect(try a.holders("m") == ["app.a", "app.b"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: group.appendingPathComponent("Garden/blobs").path).count == 1)

        // download() on an app that hasn't adopted yet adopts instead of fetching
        let c2 = try garden("app.c", shared: group, c)
        try await c2.download("m")
        #expect(s.requests(n).count == before)
        try c2.remove("m")

        try a.remove("m")
        #expect(try a.state("m") == .sharedAvailable, "B still holds it, so it stays")
        #expect(try b.state("m") == .ready(.shared))
        try b.remove("m")
        #expect(try b.state("m") == .missing(bytes: Int64(size), partial: 0))
        #expect(try FileManager.default.contentsOfDirectory(atPath: group.appendingPathComponent("Garden/blobs").path).isEmpty)
    }

    @Test func privateDownloadStaysInTheApp() async throws {
        let (n, size, sha) = try s.file("private.bin", size: 100_000)
        let c = try catalog([("m", n, size, sha, [s.url("ok", n)])])
        let group = try tempDir("group")
        let a = try garden("app.a", shared: group, c), b = try garden("app.b", shared: group, c)
        try await a.download("m", share: false)
        #expect(try a.state("m") == .ready(.private))
        #expect(try b.state("m") == .missing(bytes: Int64(size), partial: 0))
        let u = try a.open("m").url(n)
        #expect(try Garden.sha256(u) == sha)
        let dirExcluded = try u.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(dirExcluded == true, "model folders are excluded from backup")
        try a.remove("m")
        #expect(try a.state("m") == .missing(bytes: Int64(size), partial: 0))
    }

    @Test func noAppGroupMeansPrivateOnly() async throws {
        let (n, size, sha) = try s.file("nogroup.bin", size: 50_000)
        let c = try catalog([("m", n, size, sha, [s.url("ok", n)])])
        let a = try garden("app.a", shared: nil, c)
        #expect(!a.hasSharedStore)
        try await a.download("m", share: true)
        #expect(try a.state("m") == .ready(.private))
        #expect(try a.holders("m").isEmpty)
    }

    @Test func resumesACutDownload() async throws {
        let (n, size, sha) = try s.file("cut.bin", size: 2_000_000)
        let c = try catalog([("m", n, size, sha, [s.url("cut", n)])])
        let a = try garden("app.a", shared: try tempDir("group"), c)
        let seen = Progress()
        try await a.download("m") { done, total in seen.note(done, total) }
        #expect(try a.state("m") == .ready(.shared))
        let reqs = s.requests(n)
        #expect(reqs.count == 2)
        #expect(reqs.last?.contains("bytes=\(size / 2)-") == true, "second request resumes where the first stopped: \(reqs)")
        #expect(seen.last?.0 == Int64(size) && seen.last?.1 == Int64(size))
        #expect(seen.monotonic)
    }

    @Test func restartsWhenTheServerIgnoresRange() async throws {
        let (n, size, sha) = try s.file("norange.bin", size: 1_000_000)
        let c = try catalog([("m", n, size, sha, [s.url("cutnorange", n)])])
        let a = try garden("app.a", shared: try tempDir("group"), c)
        try await a.download("m")
        #expect(try Garden.sha256(a.open("m").url(n)) == sha)
    }

    @Test func refusesCorruptBytes() async throws {
        let (n, size, sha) = try s.file("corrupt.bin", size: 20_000)
        let c = try catalog([("m", n, size, sha, [s.url("corrupt", n)])])
        let group = try tempDir("group")
        let a = try garden("app.a", shared: group, c)
        await #expect(throws: GardenError.self) { try await a.download("m") }
        #expect(try a.state("m") == .missing(bytes: Int64(size), partial: 0))
        #expect(try FileManager.default.contentsOfDirectory(atPath: group.appendingPathComponent("Garden/blobs").path).isEmpty)
    }

    @Test func fallsBackToTheNextUrl() async throws {
        let (n, size, sha) = try s.file("mirror.bin", size: 20_000)
        let c = try catalog([("m", n, size, sha, [s.url("dead", n), s.url("ok", n)])])
        let a = try garden("app.a", shared: try tempDir("group"), c)
        try await a.download("m")
        #expect(try a.state("m") == .ready(.shared))
        #expect(s.requests(n).map { $0.split(separator: " ")[0] } == ["dead", "ok"])
    }

    @Test func cancelKeepsThePartialFile() async throws {
        let (n, size, sha) = try s.file("cancel.bin", size: 30_000_000)
        let c = try catalog([("m", n, size, sha, [s.url("ok", n)])])
        let a = try garden("app.a", shared: try tempDir("group"), c)
        let t = Task { try await a.download("m") { done, _ in if done > 1_000_000 { withUnsafeCurrentTask { $0?.cancel() } } } }
        try? await Task.sleep(for: .milliseconds(1))
        let started = Date()
        while case .missing(_, let p) = try a.state("m"), p < 1_000_000, Date().timeIntervalSince(started) < 10 {
            try await Task.sleep(for: .milliseconds(5))
        }
        t.cancel()
        _ = await t.result
        guard case .missing(_, let partial) = try a.state("m") else { Issue.record("finished before the cancel"); return }
        #expect(partial > 0)
        try await a.download("m")  // resumes
        #expect(try Garden.sha256(a.open("m").url(n)) == sha)
        #expect(s.requests(n).last?.contains("bytes=") == true)
    }

    @Test func contributeChecksHashes() throws {
        let (n, size, sha) = try s.file("contrib.bin", size: 10_000)
        let c = try catalog([("m", n, size, sha, [s.url("dead", n)])])
        let group = try tempDir("group")
        let a = try garden("app.a", shared: group, c)
        let wrong = try tempDir("wrong").appendingPathComponent(n)
        try Data(count: size).write(to: wrong)
        #expect(throws: GardenError.checksum(n)) { try a.contribute("m") { _ in wrong } }
        #expect(try a.state("m") == .missing(bytes: Int64(size), partial: 0))
        try a.contribute("m") { _ in s.root.appendingPathComponent(n) }
        #expect(try a.state("m") == .ready(.shared))
        #expect(FileManager.default.fileExists(atPath: s.root.appendingPathComponent(n).path), "source is copied, not moved")
    }

    @Test func shortSharedFileIsNotReady() async throws {
        let (n, size, sha) = try s.file("short.bin", size: 10_000)
        let c = try catalog([("m", n, size, sha, [s.url("ok", n)])])
        let group = try tempDir("group")
        let a = try garden("app.a", shared: group, c)
        try await a.download("m")
        let u = try a.open("m").url(n)
        let h = try FileHandle(forWritingTo: u); try h.truncate(atOffset: 10); try h.close()
        #expect(throws: GardenError.self) { try a.open("m") }
        #expect(try a.state("m") == .missing(bytes: Int64(size), partial: 0))
    }
}

final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [(Int64, Int64)]()
    func note(_ d: Int64, _ t: Int64) { lock.withLock { values.append((d, t)) } }
    var last: (Int64, Int64)? { lock.withLock { values.last } }
    var monotonic: Bool { lock.withLock { zip(values, values.dropFirst()).allSatisfy { $0.0 <= $1.0 } } }
}

@Suite struct SystemSpeechTests {
    @Test(arguments: ["transcriber", "dictation"]) func transcribesTheTestSentence(engine: String) async throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let status = await SystemSpeech.status(locale: Locale(identifier: "en-US"))
        print("SystemSpeech status:", status)
        try #require(status != .unavailable, "no on-device speech model on this Mac")
        let wav = try #require(Bundle.module.url(forResource: "Resources/test", withExtension: "wav"))
        let phrases = try await SystemSpeech.transcribe(wav, locale: Locale(identifier: "en-US"), engine: .init(rawValue: engine))
        let text = phrases.map(\.text).joined(separator: " ")
        print("SystemSpeech (\(engine)) heard:", phrases)
        #expect(text.lowercased().contains("goblin king"))
        #expect(text.lowercased().contains("three pieces of gold"))
        #expect(phrases.allSatisfy { $0.start <= $0.end })
    }
}

/// Long-recording memory check: GARDEN_LONG_MINUTES=40 swift test --filter longRecording (run under /usr/bin/time -l).
@Suite struct LongRecordingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GARDEN_LONG_MINUTES"] != nil))
    func longRecording() async throws {
        guard #available(macOS 26, iOS 26, *) else { return }
        let minutes = Int(ProcessInfo.processInfo.environment["GARDEN_LONG_MINUTES"]!)!
        let wav = try Data(contentsOf: try #require(Bundle.module.url(forResource: "Resources/test", withExtension: "wav")))
        let pcm = wav.dropFirst(44), silence = Data(count: 16_000)  // 0.5 s between repeats
        let reps = minutes * 60 * 32_000 / (pcm.count + silence.count)
        var body = Data(); body.reserveCapacity(reps * (pcm.count + silence.count))
        for _ in 0..<reps { body.append(pcm); body.append(silence) }
        var h = Data(wav.prefix(44))
        func put(_ v: UInt32, at o: Int) { withUnsafeBytes(of: v.littleEndian) { h.replaceSubrange(o..<o + 4, with: $0) } }
        put(UInt32(36 + body.count), at: 4); put(UInt32(body.count), at: 40)
        let file = try tempDir("long").appendingPathComponent("long.wav")
        try (h + body).write(to: file)
        body = Data()
        let started = Date()
        let phrases = try await SystemSpeech.transcribe(file, locale: Locale(identifier: "en-US"))
        let goblins = phrases.filter { $0.text.lowercased().contains("goblin") }.count
        print("LONG: \(minutes) min, \(reps) sentences, \(phrases.count) phrases, \(goblins) with 'goblin', \(Int(Date().timeIntervalSince(started))) s, last ends \(Int(phrases.last?.end ?? 0)) s")
        #expect(goblins > reps * 9 / 10)
    }
}
