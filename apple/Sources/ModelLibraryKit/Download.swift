import Foundation

extension ModelLibrary {
    /// Fetches one file into its partial path: resumes with Range, tries each url, retries a few rounds,
    /// SHA-checks the result. On return the partial file is complete and verified.
    func fetch(_ f: ModelFile, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let part = partialURL(f)
        var lastError = "no urls"
        for round in 0..<attempts {
            if round > 0 { try await Task.sleep(for: retryDelay) }
            for url in f.urls {
                try Task.checkCancellation()
                if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
                var have = Self.size(part) ?? 0
                if have > f.size { try truncate(part, to: 0); have = 0 }
                if have < f.size {
                    let r = await Fetcher.run(url: url, file: part, offset: have, configuration: configuration, onBytes: onBytes)
                    if case .failed(let why) = r { lastError = why; if Task.isCancelled { throw CancellationError() }; continue }
                }
                guard Self.size(part) == f.size else { lastError = "ended at \(Self.size(part) ?? 0) of \(f.size) bytes"; continue }
                if try Self.sha256(part) == f.sha256 { return }
                try? FileManager.default.removeItem(at: part)
                lastError = ModelLibraryError.checksum(f.name).localizedDescription
            }
        }
        throw ModelLibraryError.download(f.name, lastError)
    }

    private func truncate(_ u: URL, to n: Int64) throws {
        let h = try FileHandle(forWritingTo: u)
        try h.truncate(atOffset: UInt64(n))
        try h.close()
    }
}

/// One HTTP request appended to a file. A 206 must start at our offset; a 200 restarts the file.
final class Fetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome: Sendable { case finished, failed(String) }

    private let lock = NSLock()
    private let handle: FileHandle
    private let offset: Int64
    private let onBytes: @Sendable (Int64) -> Void
    private var written: Int64 = 0
    private var problem: String?
    private var done: CheckedContinuation<Outcome, Never>?

    private init(handle: FileHandle, offset: Int64, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle; self.offset = offset; self.onBytes = onBytes
    }

    static func run(url: URL, file: URL, offset: Int64, configuration: URLSessionConfiguration,
                    onBytes: @escaping @Sendable (Int64) -> Void) async -> Outcome {
        guard let h = try? FileHandle(forWritingTo: file) else { return .failed("can't write \(file.lastPathComponent)") }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        let f = Fetcher(handle: h, offset: offset, onBytes: onBytes)
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = min(config.timeoutIntervalForRequest, 30)
        let session = URLSession(configuration: config, delegate: f, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url)
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: req)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                f.lock.withLock { f.done = c }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")
        let ok: Bool = lock.withLock {
            switch code {
            case 200:
                // The server ignored Range (or we asked for none): start the file over.
                do { try handle.truncate(atOffset: 0); written = -offset } catch { problem = "\(error)"; return false }
                return true
            case 206:
                let start = range.flatMap { $0.wholeMatch(of: /bytes (\d+)-\d+\/\d+/) }.flatMap { Int64($0.1) }
                if start == offset { return true }
                problem = "server resumed at the wrong place (\(range ?? "no Content-Range"))"; return false
            default:
                problem = "HTTP \(code)"; return false
            }
        }
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let total: Int64? = lock.withLock {
            guard problem == nil else { return nil }
            do { try handle.write(contentsOf: data) } catch { problem = "\(error)"; dataTask.cancel(); return nil }
            written += Int64(data.count)
            return offset + written
        }
        if let total { onBytes(total) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, outcome): (CheckedContinuation<Outcome, Never>?, Outcome) = lock.withLock {
            let c = done; done = nil
            if let p = problem { return (c, .failed(p)) }
            if let e = error { return (c, .failed(e.localizedDescription)) }
            return (c, .finished)
        }
        c?.resume(returning: outcome)
    }
}
