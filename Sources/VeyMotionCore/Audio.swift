import AVFoundation
import Foundation

/// The asset library: the shared library, or the open project's `assets/` folder while a project is open.
public enum AssetStore {
    /// The shared library, used when no project is open (and browsable from projects).
    public static var sharedDirectory: URL {
        if let p = ProcessInfo.processInfo.environment["VEYMOTION_ASSETS_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VeyMotion/assets", isDirectory: true)
    }

    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var active: URL?

    /// The library that asset tools and the Assets panel work on.
    public static var directory: URL {
        activeLock.lock(); defer { activeLock.unlock() }
        return active ?? sharedDirectory
    }

    /// Switches to a project's assets folder (nil = back to the shared library).
    public static func setActiveLibrary(_ url: URL?) {
        activeLock.lock(); defer { activeLock.unlock() }
        active = url?.standardizedFileURL
    }

    /// True while a project's library is active. New files then go into type folders (images/, music/, …) by default.
    public static var isProjectLibrary: Bool {
        activeLock.lock(); defer { activeLock.unlock() }
        return active != nil
    }

    /// `folder` if given; otherwise `fallback` inside a project library, nil (top level) in the shared one.
    public static func routed(_ folder: String?, default fallback: String) -> String? {
        folder ?? (isProjectLibrary ? fallback : nil)
    }

    /// A new, uniquely named file for generated content. `folder` is created if needed.
    public static func newFile(prefix: String, ext: String, folder: String? = nil) throws -> URL {
        var dir = directory
        if let folder, !folder.isEmpty { dir = dir.appendingPathComponent(try validName(folder), isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    public static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}

public enum AudioError: LocalizedError {
    case cannotRead(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .cannotRead(p): return "Cannot read audio file: \(p)"
        case let .failed(m): return m
        }
    }
}

public enum AudioFileInfo {
    /// True if the file's audio can actually be decoded (not just its header read).
    public static func isDecodable(_ path: String) -> Bool {
        guard let f = try? AVAudioFile(forReading: expandPath(path)),
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 1) else { return false }
        return (try? f.read(into: buf, frameCount: 1)) != nil
    }

    private static func expandPath(_ path: String) -> URL { AssetStore.expand(path) }

    /// Duration in seconds of an audio file (anything AVAudioFile reads: wav, aiff, caf, m4a, mp3…).
    public static func duration(of path: String) throws -> Double {
        let url = AssetStore.expand(path)
        do {
            let f = try AVAudioFile(forReading: url)
            return Double(f.length) / f.fileFormat.sampleRate
        } catch {
            throw AudioError.cannotRead(url.path)
        }
    }
}

extension MotionScene {
    public var audioLayers: [MotionLayer] { layers.filter { $0.type == .audio && $0.path != nil } }

    /// Everything the mixer plays: audio layers, plus video layers whose movie has sound (at normal speed).
    public var soundLayers: [MotionLayer] {
        layers.filter { l in
            guard let p = l.path else { return false }
            switch l.type {
            case .audio: return true
            case .video: return l.speed == 1 && MediaAudio.hasAudioTrack(p)
            default: return false
            }
        }
    }

    /// Fills `sourceDuration` for audio and video layers that don't have it yet. Returns problems (unreadable files).
    @discardableResult
    public mutating func refreshMediaInfo() -> [String] {
        var problems: [String] = []
        for i in layers.indices where layers[i].sourceDuration == nil {
            guard let p = layers[i].path else { continue }
            do {
                switch layers[i].type {
                case .audio: layers[i].sourceDuration = try AudioFileInfo.duration(of: p)
                case .video: try layers[i].loadVideoInfo(sceneFps: fps)
                default: break
                }
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        return problems
    }
}

// MARK: - Mixing

/// Offline mixer: renders the scene's audio layers to one stereo buffer. Used by preview and export,
/// so what you hear while editing is what gets exported.
public enum AudioMixer {
    public static let sampleRate = 48_000.0
    public static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    static let duckRamp = 0.25

    public static func hasAudio(_ scene: MotionScene) -> Bool { !scene.soundLayers.isEmpty }

    /// Gain of a layer at scene time t: volume × fades × ducking.
    static func gain(_ l: MotionLayer, at t: Double, start: Double, end: Double, voice: [(Double, Double)]) -> Float {
        var g = l.volume.value(at: t)
        if l.fadeIn > 0 { g *= min(1, max(0, (t - start) / l.fadeIn)) }
        if l.fadeOut > 0 { g *= min(1, max(0, (end - t) / l.fadeOut)) }
        if let duck = l.duckTo, l.role == .music {
            var amount = 0.0
            for (a, b) in voice {
                if t >= a && t <= b { amount = 1; break }
                if t < a && a - t < duckRamp { amount = max(amount, 1 - (a - t) / duckRamp) }
                if t > b && t - b < duckRamp { amount = max(amount, 1 - (t - b) / duckRamp) }
            }
            g *= 1 - (1 - duck) * amount
        }
        return Float(max(0, g))
    }

    /// Mixes scene time [from, to) into a stereo float buffer at 48 kHz.
    public static func render(_ scene: MotionScene, from t0: Double = 0, to t1: Double? = nil) throws -> AVAudioPCMBuffer {
        let end = min(t1 ?? scene.duration, scene.duration)
        let frames = AVAudioFrameCount(max(0, (end - t0) * sampleRate).rounded())
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)) else {
            throw AudioError.failed("cannot allocate mix buffer")
        }
        out.frameLength = frames
        let outL = out.floatChannelData![0], outR = out.floatChannelData![1]
        outL.update(repeating: 0, count: Int(frames))
        outR.update(repeating: 0, count: Int(frames))

        let voice = scene.audioLayers.filter { $0.role == .voice }
            .map { ($0.start, $0.effectiveEnd(sceneDuration: scene.duration)) }

        for l in scene.soundLayers {
            guard let path = l.path else { continue }
            // Fades end where the sound actually stops: the layer end or the scene end, whichever is first.
            let ls = l.start, le = min(l.effectiveEnd(sceneDuration: scene.duration), scene.duration)
            let segStart = max(ls, t0), segEnd = min(le, end)
            guard segEnd > segStart else { continue }

            for piece in sourcePieces(l, from: segStart, to: segEnd) {
                let src: AVAudioPCMBuffer
                if l.type == .audio {
                    src = try readSegment(path: path, from: piece.file, duration: piece.end - piece.start)
                } else {
                    // A movie's sound; an unreadable one stays silent rather than failing the whole mix.
                    guard let b = try? MediaAudio.read(path: path, from: piece.file, duration: piece.end - piece.start,
                                                       sampleRate: sampleRate, channels: 2) else { continue }
                    src = b
                }
                let n = Int(src.frameLength)
                guard n > 0, let ch = src.floatChannelData else { continue }
                let srcChannels = Int(src.format.channelCount)
                let left = ch[0], right = ch[min(1, srcChannels - 1)]
                let offset = Int(((piece.start - t0) * sampleRate).rounded())
                let count = min(n, Int(frames) - offset)
                guard count > 0 else { continue }

                // Gain is evaluated per block of 128 frames (plenty smooth, much cheaper than per sample).
                var i = 0
                while i < count {
                    let blockEnd = min(i + 128, count)
                    let t = piece.start + Double(i) / sampleRate
                    let g = gain(l, at: t, start: ls, end: le, voice: voice)
                    if g > 0 {
                        for k in i..<blockEnd {
                            outL[offset + k] += left[k] * g
                            outR[offset + k] += right[k] * g
                        }
                    }
                    i = blockEnd
                }
            }
        }
        // Soft safety limit.
        for k in 0..<Int(frames) {
            outL[k] = max(-1, min(1, outL[k]))
            outR[k] = max(-1, min(1, outR[k]))
        }
        return out
    }

    /// The stretches of scene time [from, to) where a layer plays its file continuously, with the file time at
    /// each start. Audio is one stretch; a video stops at the end of its clip (once / hold) or starts over (loop).
    static func sourcePieces(_ l: MotionLayer, from: Double, to: Double) -> [(start: Double, end: Double, file: Double)] {
        let file = l.trimIn + (from - l.start)
        guard l.type == .video, let total = l.sourceDuration, total > l.trimIn else { return [(from, to, file)] }
        let span = total - l.trimIn
        guard l.playback == .loop else {
            let stop = min(to, l.start + span)
            return stop > from ? [(from, stop, file)] : []
        }
        var out: [(Double, Double, Double)] = []
        var k = ((from - l.start) / span).rounded(.down)
        while l.start + k * span < to {
            let a = l.start + k * span
            let s = max(from, a), e = min(to, a + span)
            if e > s { out.append((s, e, l.trimIn + (s - a))) }
            k += 1
        }
        return out
    }

    /// Reads `duration` seconds from `from` (file time), resampled to 48 kHz, channels unchanged.
    static func readSegment(path: String, from: Double, duration: Double) throws -> AVAudioPCMBuffer {
        let url = AssetStore.expand(path)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioError.cannotRead(url.path) }
        let fmt = file.processingFormat
        let startFrame = AVAudioFramePosition(max(0, from) * fmt.sampleRate)
        guard startFrame < file.length else {
            return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        }
        let want = AVAudioFrameCount(min(Double(file.length - startFrame), (duration * fmt.sampleRate).rounded(.up)))
        guard want > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: want) else {
            return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        }
        // Setting framePosition on a file that cannot be decoded raises an Objective-C exception (a crash),
        // while read(into:) throws. Probe with a read first so a bad file becomes an error.
        guard let probe = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1) else { throw AudioError.cannotRead(url.path) }
        do { try file.read(into: probe, frameCount: 1) } catch { throw AudioError.cannotRead(url.path) }
        file.framePosition = startFrame
        try file.read(into: buf, frameCount: want)
        if abs(fmt.sampleRate - sampleRate) < 1 { return buf }
        return try resample(buf, to: sampleRate)
    }

    static func resample(_ input: AVAudioPCMBuffer, to rate: Double) throws -> AVAudioPCMBuffer {
        guard let outFmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: input.format.channelCount),
              let conv = AVAudioConverter(from: input.format, to: outFmt) else {
            throw AudioError.failed("cannot create resampler")
        }
        let cap = AVAudioFrameCount(Double(input.frameLength) * rate / input.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { throw AudioError.failed("alloc") }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .endOfStream; return nil }
            fed = true
            inStatus.pointee = .haveData
            return input
        }
        if status == .error { throw AudioError.failed(err?.localizedDescription ?? "resample failed") }
        return out
    }

    /// Writes a buffer to a CAF file (lossless float).
    public static func write(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let f = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        try f.write(from: buffer)
    }

    /// Mixes the whole scene into a temporary CAF file. Caller deletes it.
    public static func renderToTempFile(_ scene: MotionScene) throws -> URL {
        let url = try AssetStore.newFile(prefix: ".mix", ext: "caf")
        try write(render(scene), to: url)
        return url
    }

    /// Copies part of a buffer (used to start preview playback mid-scene).
    public static func slice(_ b: AVAudioPCMBuffer, fromFrame start: Int) -> AVAudioPCMBuffer? {
        let total = Int(b.frameLength)
        guard start < total, let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: AVAudioFrameCount(total - start)) else {
            return nil
        }
        out.frameLength = AVAudioFrameCount(total - start)
        for c in 0..<Int(b.format.channelCount) {
            out.floatChannelData![c].update(from: b.floatChannelData![c].advanced(by: start), count: total - start)
        }
        return out
    }
}

// MARK: - Waveform

public enum Waveform {
    public static let binsPerSecond = 50.0

    /// Peak amplitude (0...1) per 1/50 s of the file.
    public static func peaks(path: String) throws -> [Float] {
        let url = AssetStore.expand(path)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioError.cannotRead(url.path) }
        let fmt = file.processingFormat
        let framesPerBin = max(1, Int(fmt.sampleRate / binsPerSecond))
        let chunk = AVAudioFrameCount(framesPerBin * 200)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return [] }
        var peaks: [Float] = []
        peaks.reserveCapacity(Int(Double(file.length) / Double(framesPerBin)) + 1)
        var current: Float = 0
        var inBin = 0
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: chunk)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            let chans = Int(fmt.channelCount)
            for i in 0..<n {
                var m: Float = 0
                for c in 0..<chans { m = max(m, abs(buf.floatChannelData![c][i])) }
                current = max(current, m)
                inBin += 1
                if inBin == framesPerBin { peaks.append(min(current, 1)); current = 0; inBin = 0 }
            }
        }
        if inBin > 0 { peaks.append(min(current, 1)) }
        return peaks
    }
}

// MARK: - Captions

public struct CaptionStyle: Sendable {
    public var fontSize: Double = 46
    public var y: Double?
    public var color: RGBA = .white
    public var maxChars = 42
    public var background = true

    public init() {}
}

/// One caption as created by `addCaptions`: its number (for `setCaptionTexts`), layer id, scene times and text.
public struct CaptionLine: Sendable {
    public var number: Int
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String
}

extension MotionScene {
    /// Turns the word timings of a voice-over or a transcribed audio/video layer into caption text layers
    /// (ids "cap-<layer>-<n>"). Replaces existing captions for that layer.
    @discardableResult
    public mutating func addCaptions(for id: String, style: CaptionStyle = CaptionStyle()) throws -> [CaptionLine] {
        let source = try layer(id)
        guard source.type == .audio || source.type == .video else {
            throw SceneError.invalid("'\(id)' is not an audio or video layer")
        }
        guard let words = source.words, !words.isEmpty else {
            throw SceneError.invalid("'\(id)' has no word timings: generate a voice-over, or transcribe the layer first")
        }
        let prefix = "cap-\(id)-"
        let rate = source.type == .video ? source.speed : 1
        let sourceEnd = source.effectiveEnd(sceneDuration: duration)
        func sceneTime(_ fileTime: Double) -> Double { source.start + (fileTime - source.trimIn) / rate }

        // Group words into readable chunks: break at sentence ends, at pauses, or when the line gets long.
        var chunks: [[WordTiming]] = []
        var cur: [WordTiming] = []
        var chars = 0
        for w in words where sceneTime(w.t) >= source.start - 0.01 && sceneTime(w.t) < sourceEnd {
            if let prev = cur.last {
                let pause = prev.d.map { sceneTime(w.t) - sceneTime(prev.t + $0) > 0.7 } ?? false
                if pause || chars + w.text.count + 1 > style.maxChars { chunks.append(cur); cur = []; chars = 0 }
            }
            cur.append(w)
            chars += w.text.count + 1
            if let last = w.text.last, ".!?…。！？".contains(last) { chunks.append(cur); cur = []; chars = 0 }
        }
        if !cur.isEmpty { chunks.append(cur) }

        var lines: [CaptionLine] = []
        for (n, chunk) in chunks.enumerated() {
            guard let first = chunk.first, let last = chunk.last else { continue }
            let start = sceneTime(first.t)
            let next = n + 1 < chunks.count ? sceneTime(chunks[n + 1][0].t) : sourceEnd
            var end = n + 1 < chunks.count ? next : min(sourceEnd, sceneTime(last.t) + 0.8)
            if let d = last.d {
                // Leave shortly after the last word is spoken, but give short lines time to be read.
                end = min(next, max(sceneTime(last.t + d) + 0.5, start + 1))
            }
            lines.append(CaptionLine(number: n + 1, id: "\(prefix)\(n + 1)", start: start, end: max(end, start + 0.3),
                                     text: Self.joinWords(chunk.map(\.text))))
        }

        // Replace the old captions in one assignment (every write to `layers` re-links audio reactions).
        var all = layers
        all.removeAll { $0.id.hasPrefix(prefix) }
        let y = style.y ?? Double(height) - 110
        if style.background {
            // One bar per run of back-to-back captions, so no empty bar stays up during long pauses.
            var runs: [(Double, Double)] = []
            for l in lines {
                if let r = runs.last, l.start - r.1 < 0.3 { runs[runs.count - 1].1 = max(r.1, l.end) } else { runs.append((l.start, l.end)) }
            }
            for (k, run) in runs.enumerated() {
                var bar = MotionLayer(id: prefix + (k == 0 ? "bg" : "bg\(k + 1)"), name: "Caption background",
                                      type: .rect, x: Double(width) / 2, y: y)
                bar.width = .constant(min(Double(width) - 160, Double(style.maxChars) * style.fontSize * 0.55 + 80))
                bar.height = .constant(style.fontSize * 1.9)
                bar.cornerRadius = .constant(14)
                bar.fill = .constant(RGBA(r: 0, g: 0, b: 0, a: 0.55))
                bar.start = run.0
                bar.end = run.1
                all.append(bar)
            }
        }
        for l in lines {
            var t = MotionLayer(id: l.id, name: "Caption \(l.number)", type: .text, x: Double(width) / 2, y: y)
            t.text = l.text
            t.fontSize = style.fontSize
            t.fontWeight = "semibold"
            t.color = .constant(style.color)
            t.maxWidth = Double(width) - 240
            t.start = l.start
            t.end = l.end
            all.append(t)
        }
        layers = all
        return lines
    }

    /// Replaces the text of captions number `from`, `from + 1`, … of a layer (numbers as listed by addCaptions),
    /// e.g. with a translation. Timing and style stay.
    public mutating func setCaptionTexts(_ id: String, from: Int = 1, texts: [String]) throws {
        var all = layers
        for (k, text) in texts.enumerated() {
            let cid = "cap-\(id)-\(from + k)"
            guard let i = all.firstIndex(where: { $0.id == cid }) else {
                throw SceneError.invalid("No caption '\(cid)' (add_captions lists the caption numbers of '\(id)')")
            }
            all[i].text = text
        }
        layers = all
    }

    /// The caption layers of an audio/video layer, in order.
    public func captions(of id: String) -> [CaptionLine] {
        let prefix = "cap-\(id)-"
        return layers.compactMap { l -> CaptionLine? in
            guard l.type == .text, l.id.hasPrefix(prefix), let n = Int(l.id.dropFirst(prefix.count)) else { return nil }
            return CaptionLine(number: n, id: l.id, start: l.start, end: l.effectiveEnd(sceneDuration: duration), text: l.text)
        }
        .sorted { $0.number < $1.number }
    }

    /// Joins recognized words with spaces, except between Chinese / Japanese characters.
    static func joinWords(_ words: [String]) -> String {
        func isCJK(_ c: Character?) -> Bool {
            guard let s = c?.unicodeScalars.first?.value else { return false }
            return (0x3040...0x30FF).contains(s) || (0x3400...0x9FFF).contains(s) || (0xFF00...0xFFEF).contains(s)
                || (0x3000...0x303F).contains(s)
        }
        var out = ""
        for w in words {
            if !out.isEmpty && !(isCJK(out.last) && isCJK(w.first)) { out += " " }
            out += w
        }
        return out
    }
}
