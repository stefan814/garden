import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif

/// Garden's first choice: speech-to-text the phone already has (Apple's on-device SpeechTranscriber, or the older
/// dictation model on devices without it). iOS installs the language model once for every app, so nothing of
/// ours is downloaded. The Simulator has neither model.
@available(iOS 26, macOS 26, *)
public enum SystemSpeech {
    public struct Phrase: Sendable, Equatable {
        public let text: String
        public let start: Double
        public let end: Double
    }

    public enum Status: Sendable, Equatable {
        /// Installed: transcribe right away.
        case ready
        /// The device supports it; iOS will fetch the language model (once, shared by all apps) on [install].
        case needsInstall
        /// No on-device speech model for this language on this device.
        case unavailable
    }

    public enum Engine: String, Sendable { case transcriber, dictation }

    public static func status(locale: Locale = .current) async -> Status {
        guard let (module, _) = await module(locale: locale) else { return .unavailable }
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .ready
        case .unsupported: return .unavailable
        default: return .needsInstall
        }
    }

    /// Asks iOS to fetch the language model if it isn't installed. [progress] runs 0…1.
    public static func install(locale: Locale = .current, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let (module, _) = await module(locale: locale) else { throw SpeechError.unavailable }
        guard let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let watch = progress.map { cb in
            Task { while !Task.isCancelled { cb(req.progress.fractionCompleted); try? await Task.sleep(for: .milliseconds(300)) } }
        }
        defer { watch?.cancel() }
        try await req.downloadAndInstall()
        progress?(1)
    }

    /// Transcribes an audio file (any format AVAudioFile reads). Phrases are in order, timed from the file start.
    public static func transcribe(_ file: URL, locale: Locale = .current, engine: Engine? = nil) async throws -> [Phrase] {
        guard let (module, kind) = await module(locale: locale, forcing: engine) else { throw SpeechError.unavailable }
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) { try await req.downloadAndInstall() }
        let audio = try AVAudioFile(forReading: file)
        if audio.length == 0 { return [] }  // the analyzer never finishes on an empty file
        let collect: Task<[Phrase], Error>
        switch kind {
        case .transcriber:
            let t = module as! SpeechTranscriber
            collect = Task {
                var out = [Phrase]()
                for try await r in t.results { out += clean([(String(r.text.characters), r.range)]) }
                return out
            }
        case .dictation:
            let t = module as! DictationTranscriber
            collect = Task {
                var out = [Phrase]()
                for try await r in t.results where r.isFinal { out += clean(phrases(r.text, r.range)) }
                return out
            }
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .lingering))
        // Convert to the analyzer's own format ourselves (iOS refuses some files, e.g. 16 kHz Int16 WAV, that macOS
        // takes), into a temp file on disk so a three-hour recording never sits in memory. The analyzer then reads
        // that file at its own pace.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("garden-speech-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw SpeechError.unavailable
            }
            try convert(audio, to: format, file: tmp)
            if let last = try await analyzer.analyzeSequence(from: AVAudioFile(forReading: tmp)) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                collect.cancel()
                await analyzer.cancelAndFinishNow()
                return []
            }
        } catch {
            collect.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collect.value
    }

    /// Converts [file] a second at a time into a new file at [dest] in [format].
    static func convert(_ file: AVAudioFile, to format: AVAudioFormat, file dest: URL) throws {
        let writer = try AVAudioFile(forWriting: dest, settings: format.settings, commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        let src = file.processingFormat
        let chunk = AVAudioFrameCount(src.sampleRate)
        guard let converter = AVAudioConverter(from: src, to: format) else { throw ConvertError() }
        var done = false
        while !done {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunk) else { throw ConvertError() }
            if file.framePosition < file.length { try file.read(into: inBuf, frameCount: chunk) }  // reading at the end throws
            done = inBuf.frameLength == 0
            let cap = AVAudioFrameCount(Double(max(inBuf.frameLength, 1)) * format.sampleRate / src.sampleRate) + 1024
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { throw ConvertError() }
            var fed = false
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, state in
                if done { state.pointee = .endOfStream; return nil }
                if fed { state.pointee = .noDataNow; return nil }
                fed = true; state.pointee = .haveData; return inBuf
            }
            if status == .error { throw err ?? ConvertError() }
            if outBuf.frameLength > 0 { try writer.write(from: outBuf) }
        }
    }

    struct ConvertError: Error, LocalizedError { var errorDescription: String? { "Couldn't convert the audio for speech recognition" } }

    public enum SpeechError: Error, LocalizedError {
        case unavailable
        public var errorDescription: String? { "On-device speech recognition isn't available for this language on this device" }
    }

    // MARK: Internals

    static func module(locale: Locale, forcing: Engine? = nil) async -> (any SpeechModule, Engine)? {
        func pick(_ supported: (Locale) async -> Locale?) async -> Locale? {
            if let l = await supported(locale) { return l }
            return await supported(Locale(identifier: "en-US"))
        }
        if forcing != .dictation, SpeechTranscriber.isAvailable,
           let l = await pick({ await SpeechTranscriber.supportedLocale(equivalentTo: $0) }) {
            return (SpeechTranscriber(locale: l, preset: .transcription), .transcriber)
        }
        if forcing != .transcriber, let l = await pick({ await DictationTranscriber.supportedLocale(equivalentTo: $0) }) {
            return (DictationTranscriber(locale: l, preset: .timeIndexedLongDictation), .dictation)
        }
        return nil
    }

    /// Dictation returns long runs; split them where the words pause for more than 0.35 s.
    static func phrases(_ text: AttributedString, _ whole: CMTimeRange) -> [(String, CMTimeRange)] {
        var out: [(String, CMTimeRange)] = []
        var cur = "", start: CMTime?, end = CMTime.zero
        for run in text.runs {
            let word = String(text[run.range].characters)
            if let r = run.audioTimeRange {
                if let s = start, (r.start - end).seconds > 0.35, !cur.trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append((cur, CMTimeRange(start: s, end: end))); cur = ""; start = nil
                }
                if start == nil { start = r.start }
                end = r.end
            }
            cur += word
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append((cur, CMTimeRange(start: start ?? whole.start, end: start == nil ? whole.end : end)))
        }
        return out.isEmpty ? [(String(text.characters), whole)] : out
    }

    static func clean(_ raw: [(String, CMTimeRange)]) -> [Phrase] {
        raw.compactMap { s, r in
            var t = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
            if t.hasPrefix(".") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let f = t.first, f.isLowercase { t = f.uppercased() + t.dropFirst() }
            guard t.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return Phrase(text: t, start: r.start.seconds, end: r.end.seconds)
        }
    }
}

/// Garden's first choice for text: Apple's on-device Foundation Models, where the device has Apple Intelligence.
@available(iOS 26, macOS 26, *)
public enum SystemText {
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModelProbe.available
        #else
        return false
        #endif
    }
}

#if canImport(FoundationModels)
import FoundationModels
@available(iOS 26, macOS 26, *)
enum SystemLanguageModelProbe {
    static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
}
#endif
