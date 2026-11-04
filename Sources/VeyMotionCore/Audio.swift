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

    /// Fills `sourceDuration` for audio layers that don't have it yet. Returns problems (unreadable files).
    @discardableResult
    public mutating func refreshAudioInfo() -> [String] {
        var problems: [String] = []
        for i in layers.indices where layers[i].type == .audio && layers[i].sourceDuration == nil {
            guard let p = layers[i].path else { continue }
            do { layers[i].sourceDuration = try AudioFileInfo.duration(of: p) } catch { problems.append(error.localizedDescription) }
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

    public static func hasAudio(_ scene: MotionScene) -> Bool { !scene.audioLayers.isEmpty }

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

        for l in scene.audioLayers {
            guard let path = l.path else { continue }
            // Fades end where the sound actually stops: the layer end or the scene end, whichever is first.
            let ls = l.start, le = min(l.effectiveEnd(sceneDuration: scene.duration), scene.duration)
            let segStart = max(ls, t0), segEnd = min(le, end)
            guard segEnd > segStart else { continue }

            let src = try readSegment(path: path, from: l.trimIn + (segStart - ls), duration: segEnd - segStart)
            let n = Int(src.frameLength)
            guard n > 0, let ch = src.floatChannelData else { continue }
            let srcChannels = Int(src.format.channelCount)
            let left = ch[0], right = ch[min(1, srcChannels - 1)]
            let offset = Int(((segStart - t0) * sampleRate).rounded())
            let count = min(n, Int(frames) - offset)
            guard count > 0 else { continue }

            // Gain is evaluated per block of 128 frames (plenty smooth, much cheaper than per sample).
            var i = 0
            while i < count {
                let blockEnd = min(i + 128, count)
                let t = segStart + Double(i) / sampleRate
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
        // Soft safety limit.
        for k in 0..<Int(frames) {
            outL[k] = max(-1, min(1, outL[k]))
            outR[k] = max(-1, min(1, outR[k]))
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

extension MotionScene {
    /// Turns a voice layer's word timings into caption text layers (ids "cap-<voice>-<n>").
    /// Replaces existing captions for that voice. Returns the new layer ids.
    @discardableResult
    public mutating func addCaptions(forVoice id: String, style: CaptionStyle = CaptionStyle()) throws -> [String] {
        let voice = try layer(id)
        guard voice.type == .audio else { throw SceneError.invalid("'\(id)' is not an audio layer") }
        guard let words = voice.words, !words.isEmpty else {
            throw SceneError.invalid("'\(id)' has no word timings (only generated voice-overs have them)")
        }
        let prefix = "cap-\(id)-"
        layers.removeAll { $0.id.hasPrefix(prefix) }

        let voiceEnd = voice.effectiveEnd(sceneDuration: duration)
        func sceneTime(_ w: WordTiming) -> Double { voice.start + (w.t - voice.trimIn) }

        // Group words into readable chunks: break at sentence ends or when the line gets long.
        var chunks: [[WordTiming]] = []
        var cur: [WordTiming] = []
        var chars = 0
        for w in words where sceneTime(w) >= voice.start - 0.01 && sceneTime(w) < voiceEnd {
            if !cur.isEmpty && chars + w.text.count + 1 > style.maxChars {
                chunks.append(cur); cur = []; chars = 0
            }
            cur.append(w)
            chars += w.text.count + 1
            if let last = w.text.last, ".!?…。".contains(last) { chunks.append(cur); cur = []; chars = 0 }
        }
        if !cur.isEmpty { chunks.append(cur) }

        let y = style.y ?? Double(height) - 110
        var ids: [String] = []
        if style.background, let first = chunks.first?.first, let last = chunks.last?.last {
            var bar = MotionLayer(id: prefix + "bg", name: "Caption background", type: .rect, x: Double(width) / 2, y: y)
            bar.width = .constant(min(Double(width) - 160, Double(style.maxChars) * style.fontSize * 0.55 + 80))
            bar.height = .constant(style.fontSize * 1.9)
            bar.cornerRadius = 14
            bar.fill = .constant(RGBA(r: 0, g: 0, b: 0, a: 0.55))
            bar.start = sceneTime(first)
            bar.end = min(voiceEnd, sceneTime(last) + 0.8)
            ids.append(addLayer(bar))
        }
        for (n, chunk) in chunks.enumerated() {
            guard let first = chunk.first, let last = chunk.last else { continue }
            var t = MotionLayer(id: "\(prefix)\(n + 1)", name: "Caption \(n + 1)", type: .text, x: Double(width) / 2, y: y)
            t.text = chunk.map(\.text).joined(separator: " ")
            t.fontSize = style.fontSize
            t.fontWeight = "semibold"
            t.color = .constant(style.color)
            t.maxWidth = Double(width) - 240
            t.start = sceneTime(first)
            let nextStart = n + 1 < chunks.count ? sceneTime(chunks[n + 1][0]) : min(voiceEnd, sceneTime(last) + 0.8)
            t.end = max(nextStart, t.start + 0.3)
            ids.append(addLayer(t))
        }
        return ids
    }
}
