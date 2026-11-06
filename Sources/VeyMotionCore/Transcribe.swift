import AVFoundation
import Foundation
import Speech

// MARK: - Audio of any media file

/// Reads the sound of any file AVFoundation opens (audio files and movies) with AVAssetReader.
/// The mixer uses it for video layers; transcription uses it for both audio and video layers.
public enum MediaAudio {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var trackCache: [String: (modified: Date?, hasAudio: Bool)] = [:]

    /// True if the file has an audio track (false for image sequences). Cached per path and modification date.
    public static func hasAudioTrack(_ path: String) -> Bool {
        let p = AssetStore.expand(path).path
        guard !VideoSource.isSequence(p) else { return false }
        let modified = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        lock.lock()
        if let c = trackCache[p], c.modified == modified { lock.unlock(); return c.hasAudio }
        lock.unlock()
        let asset = AVURLAsset(url: URL(fileURLWithPath: p))
        let has = modified != nil && ((try? blocking { try await !asset.loadTracks(withMediaType: .audio).isEmpty }) ?? false)
        lock.lock(); trackCache[p] = (modified, has); lock.unlock()
        return has
    }

    /// Decodes `duration` seconds (nil = to the end) from file time `from` as deinterleaved float at `sampleRate`
    /// with `channels` (1 or 2). Returns nil when the file has no audio track.
    public static func read(path: String, from: Double, duration: Double?, sampleRate: Double, channels: Int) throws -> AVAudioPCMBuffer? {
        let url = AssetStore.expand(path)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
            return nil
        }
        // Audio files (and some .mp4) open with AVAudioFile; movies need AVAssetReader.
        if let b = try readAudioFile(url, from: from, duration: duration, format: format) { return b }
        return try readAsset(url, from: from, duration: duration, format: format)
    }

    /// nil when AVAudioFile cannot decode the file.
    private static func readAudioFile(_ url: URL, from: Double, duration: Double?, format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let inFormat = file.processingFormat
        // Setting framePosition on a file that cannot be decoded raises an Objective-C exception: probe first.
        guard let probe = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 1),
              (try? file.read(into: probe, frameCount: 1)) != nil else { return nil }
        let startFrame = AVAudioFramePosition(max(0, from) * inFormat.sampleRate)
        let available = max(0, file.length - startFrame)
        let inFrames = min(available, duration.map { AVAudioFramePosition(($0 * inFormat.sampleRate).rounded(.up)) } ?? available)
        let outCapacity = AVAudioFrameCount(Double(inFrames) * format.sampleRate / inFormat.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity),
              let converter = AVAudioConverter(from: inFormat, to: format) else {
            throw AudioError.failed("cannot convert \(url.lastPathComponent)")
        }
        guard inFrames > 0 else { return out }
        converter.downmix = true
        file.framePosition = startFrame
        let chunk: AVAudioFrameCount = 65_536
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { throw AudioError.failed("alloc") }
        var remaining = inFrames
        var readFailed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inStatus in
            guard remaining > 0, !readFailed else { inStatus.pointee = .endOfStream; return nil }
            do {
                try file.read(into: input, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunk), remaining)))
            } catch {
                readFailed = true
            }
            guard !readFailed, input.frameLength > 0 else { inStatus.pointee = .endOfStream; return nil }
            remaining -= AVAudioFramePosition(input.frameLength)
            inStatus.pointee = .haveData
            return input
        }
        if status == .error || readFailed { throw AudioError.cannotRead(url.path) }
        return out
    }

    private static func readAsset(_ url: URL, from: Double, duration: Double?, format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate, channels = Int(format.channelCount)
        let asset = AVURLAsset(url: url)
        let loaded: (AVAssetTrack, Double)?
        do {
            loaded = try blocking {
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
                return (track, try await asset.load(.duration).seconds)
            }
        } catch {
            throw AudioError.cannotRead(url.path)
        }
        guard let (track, total) = loaded else { return nil }
        let start = max(0, from)
        let span = min(duration ?? .infinity, (total.isFinite ? total : start) - start)
        guard span > 0 else { return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) }
        let capacity = Int((span * sampleRate).rounded(.up))
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(capacity, 1))) else {
            throw AudioError.failed("cannot allocate audio buffer")
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw AudioError.cannotRead(url.path) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioError.cannotRead(url.path) }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000),
                                       duration: duration.map { CMTime(seconds: $0, preferredTimescale: 48_000) } ?? .positiveInfinity)
        guard reader.startReading() else { throw AudioError.cannotRead(url.path) }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let dst = out.floatChannelData!
        var written = 0
        var interleaved: [Float] = []
        while written < capacity, let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let bytes = CMBlockBufferGetDataLength(block)
            let frames = bytes / (4 * channels)
            guard frames > 0 else { continue }
            if interleaved.count < frames * channels { interleaved = [Float](repeating: 0, count: frames * channels) }
            let status = interleaved.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: frames * channels * 4, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            let n = min(frames, capacity - written)
            for c in 0..<channels {
                let ch = dst[c].advanced(by: written)
                for k in 0..<n { ch[k] = interleaved[k * channels + c] }
            }
            written += n
        }
        if reader.status == .failed { throw AudioError.cannotRead(url.path) }
        out.frameLength = AVAudioFrameCount(written)
        return out
    }
}

// MARK: - Speech to text

public struct TranscriptionResult: Sendable {
    /// The recognized text, with punctuation where the recognizer adds it.
    public var text: String
    /// Word timings in file seconds (with durations).
    public var words: [WordTiming]
    /// Locale used, e.g. "en-US".
    public var language: String
    /// True when recognition ran on this Mac; false when it went through Apple's servers.
    public var onDevice: Bool
}

/// Speech recognition with Apple's Speech framework (SFSpeechRecognizer): on this Mac when the language supports it,
/// otherwise through Apple's servers. Long audio is cut into pieces under a minute at quiet points (the server
/// limit), and the word times are put back together.
public enum Transcriber {
    static let sampleRate = 16_000.0
    /// Pieces stay under the ~1 minute server limit; cuts are made at the quietest moment in this window.
    static let cutWindow = (min: 35.0, max: 50.0)

    /// Locales speech recognition supports, e.g. ["en-US", "ja-JP", "vi-VN", …].
    public static func supportedLanguages() -> [String] {
        SFSpeechRecognizer.supportedLocales().map { normalized($0.identifier) }.sorted()
    }

    private static func normalized(_ id: String) -> String { id.replacingOccurrences(of: "_", with: "-") }

    /// "en" → en-US, "ja" → ja-JP, "zh" → zh-CN, "vi-VN" → vi-VN… nil = the system language.
    public static func resolveLanguage(_ language: String?) throws -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        let wanted = normalized(language?.trimmingCharacters(in: .whitespaces) ?? "")
        if wanted.isEmpty {
            let current = normalized(Locale.current.identifier)
            if let l = supported.first(where: { normalized($0.identifier) == current }) { return l }
            return try resolveLanguage(Locale.current.language.languageCode?.identifier ?? "en")
        }
        if let l = supported.first(where: { normalized($0.identifier).lowercased() == wanted.lowercased() }) { return l }
        let code = String(wanted.lowercased().split(separator: "-").first ?? "")
        let matches = supported.filter { $0.language.languageCode?.identifier.lowercased() == code }
            .sorted { $0.identifier < $1.identifier }
        let preferred = ["en": "en-US", "zh": "zh-CN", "es": "es-ES", "pt": "pt-BR", "fr": "fr-FR", "de": "de-DE",
                         "ar": "ar-SA", "it": "it-IT", "nl": "nl-NL"]
        if let p = preferred[code], let l = matches.first(where: { normalized($0.identifier) == p }) { return l }
        if let region = Locale.current.region?.identifier, let l = matches.first(where: { $0.region?.identifier == region }) {
            return l
        }
        if let l = matches.first { return l }
        throw AudioError.failed("Speech recognition does not support '\(language ?? "")'. Supported: "
                                + supportedLanguages().joined(separator: ", "))
    }

    /// Transcribes `duration` seconds (nil = to the end) of a file's sound from file time `from`.
    /// Blocking (minutes for long files); call it off the main thread.
    public static func transcribe(path: String, from: Double = 0, duration: Double? = nil,
                                  language: String? = nil) throws -> TranscriptionResult {
        try authorize()
        let locale = try resolveLanguage(language)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw AudioError.failed("No speech recognizer for \(locale.identifier)")
        }
        // Result handlers run on the main queue by default; keep them off it so a blocked main thread can't stall us.
        recognizer.queue = OperationQueue()
        let onDevice = recognizer.supportsOnDeviceRecognition
        guard onDevice || recognizer.isAvailable else {
            throw AudioError.failed("Speech recognition for \(normalized(locale.identifier)) needs Apple's servers, which "
                                    + "are not reachable right now (check the network connection).")
        }
        guard let audio = try MediaAudio.read(path: path, from: from, duration: duration,
                                              sampleRate: sampleRate, channels: 1),
              audio.frameLength > 0 else {
            throw AudioError.failed("\((path as NSString).lastPathComponent) has no sound to transcribe")
        }
        let samples = audio.floatChannelData![0]
        let count = Int(audio.frameLength)

        var words: [WordTiming] = []
        var texts: [String] = []
        for (a, b) in pieces(samples, count: count) {
            guard let t = try recognize(recognizer, samples.advanced(by: a), count: b - a, format: audio.format,
                                        onDevice: onDevice) else { continue }
            let offset = from + Double(a) / sampleRate
            // The formatted string carries punctuation and capitals; use its words when they line up with the segments.
            let formatted = t.formattedString.split(whereSeparator: \.isWhitespace).map(String.init)
            let useFormatted = formatted.count == t.segments.count
            for (k, s) in t.segments.enumerated() {
                let text = useFormatted ? formatted[k] : s.substring
                guard !text.isEmpty else { continue }
                words.append(WordTiming(t: round2(offset + s.timestamp), text: text, d: round2(s.duration)))
            }
            texts.append(t.formattedString)
        }
        return TranscriptionResult(text: texts.joined(separator: " "), words: words,
                                   language: normalized(locale.identifier), onDevice: onDevice)
    }

    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// Splits audio into pieces of at most `cutWindow.max` seconds, cutting at the quietest 50 ms in the window.
    /// Silent pieces are left out.
    static func pieces(_ s: UnsafePointer<Float>, count: Int) -> [(Int, Int)] {
        let hop = Int(sampleRate * 0.05)
        func energy(_ i: Int) -> Float {
            var e: Float = 0
            for k in i..<min(i + hop, count) { e += s[k] * s[k] }
            return e
        }
        var out: [(Int, Int)] = []
        var a = 0
        let maxLen = Int(cutWindow.max * sampleRate), minLen = Int(cutWindow.min * sampleRate)
        while a < count {
            var b = count
            if count - a > maxLen {
                var best = a + maxLen, bestE = Float.infinity
                var i = a + minLen
                while i + hop <= a + maxLen {
                    let e = energy(i)
                    if e < bestE { bestE = e; best = i + hop / 2 }
                    i += hop
                }
                b = best
            }
            var peak: Float = 0
            for k in a..<b { peak = max(peak, abs(s[k])) }
            if peak > 0.003 { out.append((a, b)) }
            a = b
        }
        return out
    }

    /// One recognition request. nil when no speech was found.
    private static func recognize(_ recognizer: SFSpeechRecognizer, _ samples: UnsafePointer<Float>, count: Int,
                                  format: AVAudioFormat, onDevice: Bool) throws -> SFTranscription? {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        request.taskHint = .dictation

        let state = RecognitionState()
        let task = recognizer.recognitionTask(with: request) { result, error in
            state.lock.lock(); defer { state.lock.unlock() }
            guard !state.done else { return }
            if let result, result.isFinal {
                state.result = result.bestTranscription
                state.done = true
                state.signal.signal()
            } else if let error {
                state.error = error
                state.done = true
                state.signal.signal()
            }
        }
        var i = 0
        while i < count {
            let n = min(Int(sampleRate), count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            buf.floatChannelData![0].update(from: samples.advanced(by: i), count: n)
            request.append(buf)
            i += n
        }
        request.endAudio()

        // Recognition runs faster than real time; this only catches a stuck service.
        let timeout = 60 + Double(count) / sampleRate * 3
        if state.signal.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw AudioError.failed("speech recognition timed out")
        }
        state.lock.lock(); defer { state.lock.unlock() }
        if let error = state.error {
            let ns = error as NSError
            // kAFAssistantErrorDomain 1110: no speech detected.
            if ns.code == 1110 { return nil }
            throw AudioError.failed("Speech recognition failed: \(error.localizedDescription)")
        }
        return state.result
    }

    /// Asks for permission the first time. Without a usage description in Info.plist macOS kills the process,
    /// so processes without one (the debug build, the CLI) get an error instead.
    static func authorize() throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw AudioError.failed("Speech recognition needs the VeyMotion app bundle: this process (the debug build from "
                                    + "swift run, or vmotion --scene) has no Info.plist to ask for the permission. "
                                    + "Run bash scripts/bundle.sh, open dist/VeyMotion.app and transcribe there.")
        }
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let box = AuthBox()
            SFSpeechRecognizer.requestAuthorization { s in
                box.lock.lock(); box.status = s; box.lock.unlock()
                box.signal.signal()
            }
            // The user answers a system prompt; on the main thread keep the run loop going meanwhile.
            let deadline = Date().addingTimeInterval(300)
            while Date() < deadline {
                if box.signal.wait(timeout: .now() + 0.05) == .success { break }
                if Thread.isMainThread { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            }
            box.lock.lock(); status = box.status; box.lock.unlock()
        }
        switch status {
        case .authorized: return
        case .notDetermined: throw AudioError.failed("Speech recognition permission was not answered")
        case .restricted: throw AudioError.failed("Speech recognition is restricted on this Mac")
        default:
            throw AudioError.failed("Speech recognition is turned off for VeyMotion. Turn it on in System Settings → "
                                    + "Privacy & Security → Speech Recognition.")
        }
    }
}

private final class RecognitionState: @unchecked Sendable {
    let lock = NSLock()
    let signal = DispatchSemaphore(value: 0)
    var result: SFTranscription?
    var error: Error?
    var done = false
}

private final class AuthBox: @unchecked Sendable {
    let lock = NSLock()
    let signal = DispatchSemaphore(value: 0)
    var status: SFSpeechRecognizerAuthorizationStatus = .notDetermined
}

// MARK: - Scene

extension MotionLayer {
    /// The part of the source file a layer plays: file start and length (nil = to the end of the file).
    public func playedSourceRange(sceneDuration: Double) -> (from: Double, duration: Double?) {
        let rate = type == .video ? speed : 1
        let len = (effectiveEnd(sceneDuration: sceneDuration) - start) * rate
        // Looping videos replay the same source; anything else stops at the end of the file.
        return (trimIn, type == .video && playback == .loop ? nil : max(0, len))
    }
}

extension MotionScene {
    /// Stores a transcription on an audio or video layer (`transcript` + `words`), so add_captions can use it.
    public mutating func setTranscription(_ id: String, _ result: TranscriptionResult) throws {
        let i = try layerIndex(id)
        guard layers[i].type == .audio || layers[i].type == .video else {
            throw SceneError.invalid("'\(id)' is not an audio or video layer")
        }
        layers[i].transcript = result.text
        layers[i].words = result.words
    }
}
