import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import UniformTypeIdentifiers

/// The shape of a short sound (a sound effect), so an agent can choose and place one without hearing it: where the
/// sound starts after any leading silence, where it hits hardest (the moment to line up with the picture), where it
/// dies out, how many separate hits the file holds, and what kind of sound it is (hit, whoosh, riser, sustained).
/// All times are file seconds.
public struct SoundProfile: Sendable {
    /// One separate sound in the file (hits are split by at least ~80 ms of near-silence).
    public struct Burst: Sendable {
        public let start: Double
        /// The loudest moment: line this up with the visual event.
        public let peak: Double
        public let end: Double
        /// 0…1 against the loudest burst.
        public let level: Double
        public var length: Double { end - start }
    }

    public enum Shape: String, Sendable {
        /// Sharp attack then decay: pop, click, impact, ding.
        case hit
        /// Swells up and fades out: whoosh, swoosh, swipe.
        case whoosh
        /// Builds up to the end: riser, build-up, reverse cymbal.
        case riser
        /// Steady level: ambience, loop, drone, room tone.
        case sustained
        /// Several separate sounds in one file.
        case multiple
        case silent

        public var meaning: String {
            switch self {
            case .hit: return "sharp hit that decays"
            case .whoosh: return "swells then fades (whoosh-like)"
            case .riser: return "builds up to the end (riser)"
            case .sustained: return "steady sound (ambience/loop)"
            case .multiple: return "several separate sounds"
            case .silent: return "silent"
            }
        }
    }

    /// Envelope samples per second.
    public static let rate = 200.0

    public let duration: Double
    /// First and last audible moment (about 40 dB below the loudest part).
    public let soundStart: Double
    public let soundEnd: Double
    /// The main hit: the loudest burst's peak (for a riser, where it tops out).
    public let peak: Double
    public let bursts: [Burst]
    public let shape: Shape
    /// Loudest sample, dBFS.
    public let peakDB: Double
    /// "low", "mid" or "bright", from the energy-weighted zero-crossing rate.
    public let tone: String
    /// Peak absolute amplitude per 1/`rate` s (0…1 of full scale), for drawing.
    public let envelope: [Float]

    /// The burst an agent means by `hit` (1-based), or the main one.
    public func burst(_ hit: Int?) -> Burst? {
        if let hit, hit >= 1, hit <= bursts.count { return bursts[hit - 1] }
        return bursts.max { $0.level < $1.level }
    }

    // MARK: Analysis

    /// Decodes and profiles a file (meant for sound effects; long files take a while and say little).
    public static func analyze(path: String) throws -> SoundProfile {
        let (samples, sr) = try AudioAnalysis.readMono(path)
        return analyze(samples: samples, sampleRate: sr)
    }

    public static func analyze(samples: [Float], sampleRate sr: Double) -> SoundProfile {
        let duration = Double(samples.count) / sr
        let hop = max(1, Int(sr / rate))
        let count = (samples.count + hop - 1) / hop
        var peakEnv = [Float](repeating: 0, count: count)
        var rms = [Float](repeating: 0, count: count)
        var zcrWeighted = 0.0, energyTotal = 0.0
        for w in 0..<count {
            let a = w * hop, b = min(samples.count, a + hop)
            var p: Float = 0, s: Float = 0, zc = 0
            for i in a..<b {
                let v = samples[i]
                p = max(p, abs(v))
                s += v * v
                if i > a, (v >= 0) != (samples[i - 1] >= 0) { zc += 1 }
            }
            peakEnv[w] = p
            let e = Double(s)
            rms[w] = sqrt(s / Float(max(1, b - a)))
            zcrWeighted += Double(zc) / Double(max(1, b - a)) * e
            energyTotal += e
        }
        let maxPeak = peakEnv.max() ?? 0
        let peakDB = maxPeak > 0 ? 20 * log10(Double(maxPeak)) : -120
        // Lightly smoothed loudness (15 ms) for finding peaks and edges.
        var loud = rms
        if count > 2 { for i in 1..<(count - 1) { loud[i] = (rms[i - 1] + rms[i] + rms[i + 1]) / 3 } }
        let top = loud.max() ?? 0
        guard top > 1e-4 else {
            return SoundProfile(duration: duration, soundStart: 0, soundEnd: duration, peak: 0, bursts: [], shape: .silent,
                                peakDB: peakDB, tone: "mid", envelope: peakEnv)
        }
        // 40 ms centered average, for the top of slow swells.
        var smooth = [Float](repeating: 0, count: count)
        do {
            var prefix = [Float](repeating: 0, count: count + 1)
            for i in 0..<count { prefix[i + 1] = prefix[i] + rms[i] }
            let r = 4
            for i in 0..<count {
                let a = max(0, i - r), b = min(count, i + r + 1)
                smooth[i] = (prefix[b] - prefix[a]) / Float(b - a)
            }
        }
        func db(_ d: Float) -> Float { top * pow(10, d / 20) }
        let audible = db(-40), separate = db(-26)
        let first = loud.firstIndex { $0 > audible } ?? 0
        let last = loud.lastIndex { $0 > audible } ?? (count - 1)

        // Bursts: runs above -26 dB, merged across gaps under 80 ms, widened to the -40 dB edges.
        var runs: [(Int, Int)] = []
        var i = 0
        while i < count {
            guard loud[i] > separate else { i += 1; continue }
            var j = i
            while j + 1 < count && loud[j + 1] > separate { j += 1 }
            if let prev = runs.last, Double(i - prev.1) / rate < 0.08 { runs[runs.count - 1].1 = j } else { runs.append((i, j)) }
            i = j + 1
        }
        var bursts: [Burst] = []
        for (k, run) in runs.enumerated() {
            let floor = k > 0 ? runs[k - 1].1 + 1 : 0
            let ceiling = k + 1 < runs.count ? runs[k + 1].0 - 1 : count - 1
            var a = run.0, b = run.1
            while a > floor && loud[a - 1] > audible && loud[a - 1] <= loud[a] * 1.05 { a -= 1 }
            while b < ceiling && loud[b + 1] > audible { b += 1 }
            let p = (run.0...run.1).max { loud[$0] < loud[$1] } ?? run.0
            // The hit: for a sharp attack (within 60 ms of the start) the strike, where the level first reaches
            // -3 dB of the peak; otherwise the top of the 40 ms-smoothed loudness (the middle of a whoosh, the end
            // of a riser), which noise cannot pull around like the raw maximum.
            var hit: Int
            if Double(p - a) / rate <= 0.08 {
                let near = loud[p] * 0.7
                hit = (a...p).first { loud[$0] >= near } ?? p
            } else {
                hit = (a...b).max { smooth[$0] < smooth[$1] } ?? p
            }
            hit = min(max(hit, a), b)
            bursts.append(Burst(start: Double(a) / rate, peak: (Double(hit) + 0.5) / rate,
                                end: min(duration, Double(b + 1) / rate), level: Double(loud[p] / top)))
        }
        // Drop crumbs (very short and quiet) so "3 hits" means three real ones.
        bursts = bursts.filter { $0.level >= 0.12 || $0.length >= 0.15 }
        if bursts.isEmpty {
            bursts = [Burst(start: Double(first) / rate, peak: Double(loud.firstIndex(of: top) ?? first) / rate,
                            end: Double(last + 1) / rate, level: 1)]
        }
        let main = bursts.max { $0.level < $1.level }!

        // Shape of the main burst.
        let shape: Shape
        let length = main.length, attack = main.peak - main.start, release = main.end - main.peak
        let strong = bursts.filter { $0.level >= 0.3 }
        let a = Int(main.start * rate), b = max(a + 1, min(count, Int(main.end * rate)))
        let levels = loud[a..<b].sorted()
        let spread = levels[Int(Double(levels.count) * 0.9)] / max(levels[Int(Double(levels.count) * 0.2)], 1e-6)
        if strong.count >= 2 {
            shape = .multiple
        } else if length > 2.5 && spread < 4 {
            shape = .sustained
        } else if attack >= 0.6 * length && length > 0.3 {
            shape = .riser
        } else if attack <= 0.03 || (attack <= 0.08 && release >= 2.5 * attack) {
            // Real hits (punches, slams, glitches) often take 50–80 ms to peak; what sets them apart from a
            // whoosh is that they die out much more slowly than they rise.
            shape = .hit
        } else {
            shape = .whoosh
        }
        let hz = energyTotal > 0 ? zcrWeighted / energyTotal * sr / 2 : 0
        let tone = hz < 600 ? "low" : hz < 2500 ? "mid" : "bright"
        return SoundProfile(duration: duration, soundStart: Double(first) / rate, soundEnd: min(duration, Double(last + 1) / rate),
                            peak: main.peak, bursts: bursts, shape: shape, peakDB: peakDB, tone: tone, envelope: peakEnv)
    }

    // MARK: Description and placement

    static func fmt(_ v: Double) -> String {
        var s = String(format: "%.2f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }

    /// One line for agents, e.g. "whoosh (swells then fades): sound 0.05–1.1s, peak 0.62s, mid tone, -3 dBFS".
    public var summary: String {
        guard shape != .silent else { return "silent" }
        var parts: [String] = ["\(shape.rawValue) (\(shape.meaning))"]
        if shape == .multiple {
            let peaks = bursts.prefix(8).map { Self.fmt($0.peak) + "s" }.joined(separator: ", ")
            parts.append("\(bursts.count) sounds peaking at \(peaks)\(bursts.count > 8 ? ", …" : "") — pick one with hit")
        } else {
            parts.append("sound \(Self.fmt(soundStart))–\(Self.fmt(soundEnd))s, peak \(Self.fmt(peak))s")
        }
        if soundStart >= 0.08 { parts.append("near-silent until \(Self.fmt(soundStart))s") }
        if duration - soundEnd >= 0.3 { parts.append("silent after \(Self.fmt(soundEnd))s") }
        parts.append("\(tone) tone")
        parts.append(String(format: "%.0f dBFS", peakDB))
        return parts.joined(separator: ", ")
    }

    public struct Placement: Sendable {
        /// Scene time the layer starts, file seconds skipped, scene time it stops (nil = end of file).
        public var start: Double
        public var trimIn: Double
        public var end: Double?
        public var fadeOut: Double
        public var hitTime: Double
    }

    /// Where an audio layer must start so that `burst` (1-based, default the main one) peaks at scene time `hitAt`:
    /// leading silence is skipped and the layer stops after that burst (so other sounds in the file stay silent).
    public func placement(hitAt: Double, hit: Int? = nil) -> Placement? {
        guard let b = burst(hit) else { return nil }
        var trimIn = max(0, b.start - 0.01)
        var start = hitAt - (b.peak - trimIn)
        if start < 0 { trimIn = min(b.peak, trimIn - start); start = 0 }
        let isLast = b.start >= (bursts.last?.start ?? 0)
        let stop = isLast ? min(duration, max(b.end, soundEnd) + 0.05) : min(duration, b.end + 0.05)
        let end: Double? = stop >= duration - 0.01 ? nil : start + (stop - trimIn)
        return Placement(start: start, trimIn: trimIn, end: end, fadeOut: end == nil ? 0 : 0.03,
                         hitTime: start + (b.peak - trimIn))
    }

    // MARK: Cache

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (Date?, SoundProfile)] = [:]

    /// Profile of a file, cached by path and modification date. Files over 60 s are not profiled (nil).
    public static func cached(path: String) -> SoundProfile? {
        let url = AssetStore.expand(path)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        lock.lock()
        if let hit = cache[url.path], hit.0 == mtime { lock.unlock(); return hit.1 }
        lock.unlock()
        guard let d = try? AudioFileInfo.duration(of: url.path), d <= 60, let p = try? analyze(path: url.path) else { return nil }
        lock.lock(); cache[url.path] = (mtime, p); lock.unlock()
        return p
    }

    // MARK: Waveform sheet

    /// A numbered grid of waveforms (PNG), so an agent can see what each sound effect looks like: loudness on a dB
    /// scale, the main peak as an orange line, bursts underlined, and the length and shape as a label.
    public static func sheet(_ profiles: [SoundProfile?], columns: Int = 2, cellWidth: Int = 420, cellHeight: Int = 84) -> Data? {
        guard !profiles.isEmpty else { return nil }
        let cols = min(columns, profiles.count)
        let rows = (profiles.count + cols - 1) / cols
        let w = cols * cellWidth, h = rows * cellHeight
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: FrameRenderer.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func text(_ s: String, size: CGFloat, color: CGColor, bold: Bool = false) -> CTLine {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
            return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs))
        }
        for (i, profile) in profiles.enumerated() {
            let col = i % cols, row = i / cols
            let cell = CGRect(x: col * cellWidth, y: h - (row + 1) * cellHeight, width: cellWidth, height: cellHeight)
                .insetBy(dx: 3, dy: 3)
            ctx.setFillColor(CGColor(gray: 0.16, alpha: 1))
            ctx.fill(cell)
            let plot = CGRect(x: cell.minX + 34, y: cell.minY + 16, width: cell.width - 40, height: cell.height - 22)
            if let p = profile, !p.envelope.isEmpty, p.duration > 0 {
                let seconds = p.duration
                func x(_ t: Double) -> CGFloat { plot.minX + CGFloat(t / seconds) * plot.width }
                // Second ticks.
                let step = seconds <= 2 ? 0.25 : seconds <= 6 ? 1 : seconds <= 20 ? 2 : 5
                ctx.setFillColor(CGColor(gray: 0.28, alpha: 1))
                var t = step
                while t < seconds { ctx.fill(CGRect(x: x(t), y: plot.minY, width: 1, height: plot.height)); t += step }
                // Bursts.
                for b in p.bursts {
                    ctx.setFillColor(CGColor(red: 0.3, green: 0.75, blue: 1, alpha: 0.18))
                    ctx.fill(CGRect(x: x(b.start), y: plot.minY, width: max(1, x(b.end) - x(b.start)), height: plot.height))
                }
                // Waveform on a 48 dB scale, mirrored around the middle.
                let n = p.envelope.count
                let midY = plot.midY
                ctx.setFillColor(CGColor(red: 0.45, green: 0.85, blue: 1, alpha: 1))
                let columnsCount = Int(plot.width)
                for c in 0..<columnsCount {
                    let a = c * n / columnsCount, b = max(a + 1, (c + 1) * n / columnsCount)
                    var v: Float = 0
                    for k in a..<min(b, n) { v = max(v, p.envelope[k]) }
                    let level = v > 0 ? max(0, (20 * log10(Double(v)) + 48) / 48) : 0
                    let hh = CGFloat(level) * plot.height / 2
                    if hh > 0.3 { ctx.fill(CGRect(x: plot.minX + CGFloat(c), y: midY - hh, width: 1, height: hh * 2)) }
                }
                // Main peak.
                ctx.setFillColor(CGColor(red: 1, green: 0.55, blue: 0.1, alpha: 1))
                ctx.fill(CGRect(x: x(p.peak) - 1, y: plot.minY, width: 2, height: plot.height))
                let label = text("\(fmt(seconds))s · \(p.shape.rawValue) · peak \(fmt(p.peak))s · \(p.tone)",
                                 size: 11, color: CGColor(gray: 0.85, alpha: 1))
                ctx.textPosition = CGPoint(x: plot.minX, y: cell.minY + 3)
                CTLineDraw(label, ctx)
            } else {
                let label = text("no preview (could not download or decode)", size: 11, color: CGColor(gray: 0.6, alpha: 1))
                ctx.textPosition = CGPoint(x: plot.minX, y: plot.midY - 4)
                CTLineDraw(label, ctx)
            }
            // Number badge.
            let badge = text("\(i + 1)", size: 15, color: CGColor(gray: 1, alpha: 1), bold: true)
            ctx.textPosition = CGPoint(x: cell.minX + 6, y: cell.maxY - 20)
            CTLineDraw(badge, ctx)
        }
        guard let img = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
