import AVFoundation
import Foundation
import NaturalLanguage

public struct VoiceInfo: Codable, Sendable {
    public var id: String
    public var name: String
    public var language: String
    public var quality: String
}

public struct VoiceResult: Sendable {
    public var url: URL
    public var duration: Double
    public var words: [WordTiming]
    /// True when word times come from the synthesizer; false when estimated from text length.
    public var exactTimings: Bool
}

/// Text-to-speech with the voices built into macOS (offline, free). Writes a CAF file and returns
/// per-word timings so animation and captions can follow the narration.
public enum VoiceSynth {
    public static func voices(language: String? = nil) -> [VoiceInfo] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { v in language.map { v.language.lowercased().hasPrefix($0.lowercased()) } ?? true }
            .map { v in
                let q: String
                switch v.quality {
                case .premium: q = "premium"
                case .enhanced: q = "enhanced"
                default: q = "default"
                }
                return VoiceInfo(id: v.identifier, name: v.name, language: v.language, quality: q)
            }
            .sorted { ($0.language, rank($1.quality), $0.name) < ($1.language, rank($0.quality), $1.name) }
    }

    private static func rank(_ q: String) -> Int { q == "premium" ? 2 : q == "enhanced" ? 1 : 0 }

    /// Best voice for a language: premium > enhanced > default.
    public static func bestVoice(language: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix(language.lowercased()) }
        return candidates.max { a, b in a.quality.rawValue < b.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Synthesizes `text` to `url` (CAF). `rate` is a multiplier of the normal speaking rate (1 = normal).
    /// Blocking; safe to call from any thread (pumps the run loop when called on the main thread).
    public static func synthesize(_ text: String, voiceId: String? = nil, language: String? = nil,
                                  rate: Double = 1, to url: URL, timeout: TimeInterval? = nil) throws -> VoiceResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AudioError.failed("text is empty") }
        // Synthesis runs much faster than real time; this only guards against a stuck speech service.
        let timeout = timeout ?? (20 + Double(trimmed.count) * 0.1)

        let utterance = AVSpeechUtterance(string: trimmed)
        if let voiceId {
            guard let v = AVSpeechSynthesisVoice(identifier: voiceId) else {
                throw AudioError.failed("Unknown voice '\(voiceId)'. Use list_voices.")
            }
            utterance.voice = v
        } else {
            utterance.voice = bestVoice(language: language ?? detectLanguage(trimmed))
        }
        let r = Float(rate) * AVSpeechUtteranceDefaultSpeechRate
        utterance.rate = min(max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)

        try? FileManager.default.removeItem(at: url)
        let state = SynthState()
        let synth = AVSpeechSynthesizer()

        synth.write(utterance, toBufferCallback: { buffer in
            state.lock.lock(); defer { state.lock.unlock() }
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { state.done = true; return }
            do {
                if state.file == nil {
                    state.file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                                 commonFormat: pcm.format.commonFormat,
                                                 interleaved: pcm.format.isInterleaved)
                    state.sampleRate = pcm.format.sampleRate
                    state.bytesPerFrame = Double(pcm.format.streamDescription.pointee.mBytesPerFrame)
                }
                try state.file?.write(from: pcm)
                state.frames += Int64(pcm.frameLength)
            } catch {
                state.error = error
                state.done = true
            }
        }, toMarkerCallback: { markers in
            state.lock.lock(); defer { state.lock.unlock() }
            state.markers += markers
        })

        let deadline = Date().addingTimeInterval(timeout)
        while !state.isDone && Date() < deadline {
            // On the main thread, service the run loop in case callbacks are delivered there.
            // run(…) returns immediately when there is nothing to do, so always sleep a little too.
            if Thread.isMainThread {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            usleep(10_000)
        }
        _ = synth // keep alive until finished

        state.lock.lock(); defer { state.lock.unlock() }
        if let e = state.error { throw e }
        guard state.isDoneUnlocked else {
            throw AudioError.failed("speech synthesis timed out: the macOS speech service did not respond")
        }
        guard state.frames > 0, state.sampleRate > 0 else {
            throw AudioError.failed("speech synthesis produced no audio (is a voice for this language installed?)")
        }
        state.file = nil // close
        let duration = Double(state.frames) / state.sampleRate

        let ns = trimmed as NSString
        var words: [WordTiming] = state.markers
            .filter { $0.mark == .word }
            .compactMap { m in
                guard m.textRange.location != NSNotFound, NSMaxRange(m.textRange) <= ns.length else { return nil }
                let w = ns.substring(with: m.textRange).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !w.isEmpty else { return nil }
                // byteSampleOffset is a byte offset into the synthesized audio.
                let t = Double(m.byteSampleOffset) / max(state.bytesPerFrame, 1) / state.sampleRate
                return WordTiming(t: min(max(t, 0), duration), text: w)
            }
        let exact = !words.isEmpty && words.last!.t <= duration + 0.05
        if !exact { words = estimateTimings(trimmed, duration: duration) }
        return VoiceResult(url: url, duration: duration, words: words, exactTimings: exact)
    }

    /// Dominant language of a script ("vi", "en", …), defaulting to English.
    public static func detectLanguage(_ text: String) -> String {
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage?.rawValue ?? "en"
    }

    /// Fallback: spreads words over the duration in proportion to their length (pauses at punctuation).
    public static func estimateTimings(_ text: String, duration: Double) -> [WordTiming] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let weights = tokens.map { w -> Double in
            var x = Double(w.count) + 1
            if let l = w.last, ",;:".contains(l) { x += 3 }
            if let l = w.last, ".!?".contains(l) { x += 6 }
            return x
        }
        let total = weights.reduce(0, +)
        var t = 0.0
        var out: [WordTiming] = []
        for (w, wt) in zip(tokens, weights) {
            out.append(WordTiming(t: t, text: w))
            t += duration * wt / total
        }
        return out
    }
}

private final class SynthState: @unchecked Sendable {
    let lock = NSLock()
    var file: AVAudioFile?
    var frames: Int64 = 0
    var sampleRate = 0.0
    var bytesPerFrame = 0.0
    var markers: [AVSpeechSynthesisMarker] = []
    var error: Error?
    var done = false

    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    var isDoneUnlocked: Bool { done }
}
