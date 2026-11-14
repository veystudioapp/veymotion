import Foundation

/// Built-in sound effects, synthesized (no network, no license): whooshes, pops, clicks, dings, risers, impacts,
/// game and interface sounds, cinematic hits and a few beds (wind, drone).
/// Each one is made to measure (duration, pitch, direction) and knows exactly where its hit is, so it can be placed
/// on the frame where the picture moves. The same settings always give the same file.
public enum SynthKind: String, CaseIterable, Codable, Sendable {
    case whoosh, swoosh, pop, blip, click, tick, ding, chime, sparkle, riser, impact, thud, drop, glitch, typing
    case swell, braam, explosion, subdrop, laser
    case notification, error, beep, coin, powerup, tada
    case shutter, clap, droplet, boing, heartbeat, scribble
    case `static`, wind, drone

    public var title: String { rawValue.capitalized }

    /// What it sounds like and what it suits (for agents and the UI).
    public var use: String {
        switch self {
        case .whoosh: return "air rushing past; slides, zooms, camera moves, big transitions (peaks mid-way)"
        case .swoosh: return "short fast whoosh; quick cuts, flicks, small elements flying in"
        case .pop: return "bubbly pop; things scaling in or appearing, bubbles, icons"
        case .blip: return "rising digital blip; UI elements, toggles, notifications, small reveals"
        case .click: return "crisp click; buttons, cursor clicks, things snapping into place"
        case .tick: return "soft high tick; counters, each step of a list, clock ticks (use count)"
        case .ding: return "bright bell; success, check marks, highlights, key numbers"
        case .chime: return "three rising bell notes; reveals, achievements, happy endings"
        case .sparkle: return "glittery shimmer; magic, shine sweeps, stars, premium feel"
        case .riser: return "build-up that tops out at its end; tension before a reveal or drop (hit = the end)"
        case .impact: return "deep cinematic hit; title slams, logo landings, big drops"
        case .thud: return "soft low thump; objects landing, cards dropping, subtle accents"
        case .drop: return "falling tone; exits, errors, things falling away"
        case .glitch: return "digital stutter; glitch transitions, tech/error moments"
        case .typing: return "keyboard typing; typewriter text (set duration to the typing time, or count = keystrokes)"
        case .swell: return "reverse cymbal: airy shimmer that swells and cuts off at its end; soft lead-in to a cut or title (hit = the end)"
        case .braam: return "trailer brass blast, low and distorted; cinematic titles, dramatic reveals, chapter cards"
        case .explosion: return "blast with a long rumble; explosions, things bursting apart, heavy destruction"
        case .subdrop: return "sub-bass dive; slow-motion moments, a beat drop, weight under a big title"
        case .laser: return "sci-fi zap; shots, beams, fast streaks, energy lines (use count for a burst)"
        case .notification: return "two soft rising notes; message bubbles, alerts, toasts, phone UI"
        case .error: return "two low buzzy notes; wrong answers, declined, crossed-out items"
        case .beep: return "plain tone; countdowns (count over the seconds), timers, censoring, machine UI"
        case .coin: return "game coin: two bright square notes; points, rewards, prices, counters reaching a goal"
        case .powerup: return "rising arcade arpeggio; level up, upgrades, growth, progress bars filling (hit = the top note)"
        case .tada: return "short brass fanfare, ta-DA; winners, the final result, product reveals (hit = the second chord)"
        case .shutter: return "camera shutter; photos snapping in, screenshots, freeze frames"
        case .clap: return "single hand clap; beat accents, slate/cut marks, snappy appearances (use count for a rhythm)"
        case .droplet: return "water drip; liquid shapes, ripples, calm minimal accents"
        case .boing: return "cartoon spring; bounces, overshoots, playful characters"
        case .heartbeat: return "lub-dub; tension, health, love, slow reveals (count = beats over duration)"
        case .scribble: return "pencil strokes on paper; draw-on lines, handwriting, sketches (duration = the drawing time)"
        case .static: return "TV/radio static burst; channel-change cuts, signal loss, retro screens"
        case .wind: return "wind bed with slow gusts; outdoor scenes, emptiness, air under a quiet moment (a bed, not a hit)"
        case .drone: return "dark sustained pad; suspense under a scene without music (a bed, not a hit)"
        }
    }

    /// Default length in seconds; nil = fixed by the sound.
    public var defaultDuration: Double {
        switch self {
        case .whoosh: return 0.8
        case .swoosh: return 0.35
        case .pop: return 0.18
        case .blip: return 0.14
        case .click: return 0.06
        case .tick: return 0.05
        case .ding: return 1.6
        case .chime: return 1.5
        case .sparkle: return 1.0
        case .riser: return 2
        case .impact: return 1.6
        case .thud: return 0.45
        case .drop: return 0.7
        case .glitch: return 0.45
        case .typing: return 1.5
        case .swell: return 1.5
        case .braam: return 2.8
        case .explosion: return 2.2
        case .subdrop: return 1.6
        case .laser: return 0.3
        case .notification: return 0.6
        case .error: return 0.4
        case .beep: return 0.14
        case .coin: return 0.5
        case .powerup: return 0.7
        case .tada: return 1.6
        case .shutter: return 0.2
        case .clap: return 0.3
        case .droplet: return 0.3
        case .boing: return 0.7
        case .heartbeat: return 0.5
        case .scribble: return 1.2
        case .static: return 0.5
        case .wind: return 4
        case .drone: return 6
        }
    }

    /// Lengths that make sense for a stretching kind (the UI's slider).
    public var durationRange: ClosedRange<Double> {
        switch self {
        case .riser, .swell: return 0.5...6
        case .braam, .explosion, .subdrop, .tada: return 0.8...6
        case .wind, .drone: return 1...30
        case .scribble, .typing: return 0.2...10
        default: return 0.1...3
        }
    }

    /// Peak level, 1 = -1 dBFS. Steady tones and beds are louder than a click at the same peak, so they sit lower.
    var level: Double {
        switch self {
        case .error, .beep: return 0.6
        case .coin, .powerup, .wind, .drone: return 0.7
        default: return 1
        }
    }

    /// Time between repeats when `count` is given without a duration.
    var repeatGap: Double {
        switch self {
        case .heartbeat: return 0.85
        case .beep: return 1
        case .clap, .droplet, .laser, .coin: return 0.18
        default: return 0.12
        }
    }

    /// The synthesized kind a stock-sound search is looking for, if any ("deep whoosh" → whoosh, "bell" → ding).
    public static func matching(_ query: String) -> SynthKind? {
        let words = query.lowercased().split { !$0.isLetter }.map(String.init)
        let table: [(SynthKind, [String])] = [
            (.swell, ["swell", "reverse", "cymbal"]),
            (.riser, ["riser", "risers", "buildup", "build-up", "uplifter", "tension"]),
            (.braam, ["braam", "braams", "trailer", "horn"]),
            (.explosion, ["explosion", "explode", "blast", "bang"]),
            (.subdrop, ["subdrop", "sub", "808", "bass"]),
            (.laser, ["laser", "zap", "pew"]),
            (.notification, ["notification", "notify", "alert", "message"]),
            (.error, ["error", "wrong", "buzzer", "denied", "fail"]),
            (.beep, ["beep", "beeps", "countdown", "censor"]),
            (.coin, ["coin", "coins", "pickup", "collect", "reward"]),
            (.powerup, ["powerup", "levelup", "upgrade", "arcade"]),
            (.tada, ["tada", "fanfare", "victory", "winner"]),
            (.shutter, ["shutter", "camera", "snapshot"]),
            (.clap, ["clap", "claps"]),
            (.droplet, ["droplet", "drip", "drips"]),
            (.boing, ["boing", "spring", "bounce"]),
            (.heartbeat, ["heartbeat", "heart"]),
            (.scribble, ["scribble", "pencil", "writing", "sketch", "chalk"]),
            (.static, ["static", "interference"]),
            (.wind, ["wind", "gust", "breeze"]),
            (.drone, ["drone", "suspense", "ominous"]),
            (.whoosh, ["whoosh", "woosh", "swoosh", "swish", "swipe", "swosh", "transition"]),
            (.pop, ["pop", "pops", "bubble", "plop"]),
            (.blip, ["blip", "blips", "toggle"]),
            (.click, ["click", "clicks", "button", "snap"]),
            (.tick, ["tick", "ticks", "counter"]),
            (.chime, ["chime", "chimes"]),
            (.ding, ["ding", "bell", "success"]),
            (.sparkle, ["sparkle", "shimmer", "glitter", "magic", "twinkle"]),
            (.impact, ["impact", "boom", "slam", "punch", "hit", "hits"]),
            (.thud, ["thud", "thump", "landing"]),
            (.drop, ["drop", "fall", "falling", "downer"]),
            (.glitch, ["glitch", "glitches", "digital"]),
            (.typing, ["typing", "keyboard", "typewriter", "keystroke"]),
        ]
        return table.first { entry in entry.1.contains { words.contains($0) } }?.0
    }

    /// Kinds whose length follows `duration` (others have a natural length and only repeat to fill it).
    public var stretches: Bool {
        [.whoosh, .swoosh, .riser, .drop, .glitch, .typing, .sparkle, .swell, .braam, .explosion, .subdrop, .powerup, .tada,
         .boing, .scribble, .static, .wind, .drone].contains(self)
    }
    /// Kinds that can repeat `count` times over `duration`.
    public var repeats: Bool {
        [.pop, .blip, .click, .tick, .thud, .ding, .laser, .beep, .coin, .clap, .droplet, .heartbeat].contains(self)
    }
    /// Kinds that `direction` pans across the stereo field.
    public var pans: Bool { [.whoosh, .swoosh, .riser, .swell].contains(self) }

    public var defaultReverb: Double {
        switch self {
        case .ding, .chime: return 0.3
        case .impact: return 0.25
        case .sparkle, .swell: return 0.2
        case .braam: return 0.4
        case .explosion, .tada, .droplet: return 0.3
        case .clap, .notification: return 0.15
        default: return 0
        }
    }
}

public struct SynthSettings: Hashable, Codable, Sendable {
    public var kind: SynthKind
    /// Seconds (stretching kinds), or the span `count` repeats are spread over.
    public var duration: Double?
    /// Frequency multiplier, 0.5…2 (lower = bigger/heavier).
    public var pitch: Double = 1
    /// Different random detail for the same settings.
    public var variant: Int = 0
    /// 0…1; nil = the kind's default.
    public var reverb: Double?
    /// Whoosh/swoosh/riser/swell: moves "left" (right → left) or "right" (left → right); nil = centered.
    public var direction: String?
    /// Repeat a short sound this many times over `duration` (see `SynthKind.repeats`); typing keystrokes.
    public var count: Int?

    public init(kind: SynthKind, duration: Double? = nil, pitch: Double = 1, variant: Int = 0, reverb: Double? = nil,
                direction: String? = nil, count: Int? = nil) {
        self.kind = kind
        self.duration = duration
        self.pitch = pitch
        self.variant = variant
        self.reverb = reverb
        self.direction = direction
        self.count = count
    }

    /// Stable short hash of the settings (file names: same settings → same file).
    var key: String {
        let s = [kind.rawValue, duration.map { String(format: "%.3f", $0) } ?? "-", String(format: "%.3f", pitch),
                 String(variant), reverb.map { String(format: "%.2f", $0) } ?? "-", direction ?? "-",
                 count.map(String.init) ?? "-"].joined(separator: "|")
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h ^ (h >> 32)))
    }
}

public struct SynthResult: Sendable {
    public let url: URL
    public let duration: Double
    /// File seconds of the hit(s): the moment to line up with the picture (first = main one).
    public let hits: [Double]
}

public enum SoundSynth {
    public static let sampleRate = 48_000.0

    /// Renders to stereo samples (left, right) and the hit times.
    public static func render(_ s: SynthSettings) -> (left: [Float], right: [Float], hits: [Double]) {
        var r = Renderer(s)
        r.run()
        return (r.left, r.right, r.hits)
    }

    /// Writes a 16-bit stereo WAV into the asset library (`sfx/` in projects) and returns it. Same settings reuse
    /// the same file.
    public static func generate(_ s: SynthSettings, folder: String? = nil) throws -> SynthResult {
        let folder = AssetStore.routed(folder, default: "sfx")
        var dir = AssetStore.directory
        let sub = try AssetStore.validFolder(folder)
        if !sub.isEmpty { dir = dir.appendingPathComponent(sub, isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(s.kind.rawValue)-\(s.key).wav")
        let out = render(s)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Not `.atomic`: that stages the file in the system temp folder, which sandboxed processes cannot use.
            let part = url.appendingPathExtension("part")
            try wav(left: out.left, right: out.right).write(to: part)
            try FileManager.default.moveItem(at: part, to: url)
        }
        return SynthResult(url: url, duration: Double(out.left.count) / sampleRate, hits: out.hits)
    }

    /// 16-bit PCM WAV data.
    public static func wav(left: [Float], right: [Float]) -> Data {
        let frames = min(left.count, right.count)
        var d = Data(capacity: 44 + frames * 4)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 4))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 4)
        u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 4))
        var pcm = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            pcm[2 * i] = Int16(max(-1, min(1, left[i])) * 32767)
            pcm[2 * i + 1] = Int16(max(-1, min(1, right[i])) * 32767)
        }
        pcm.withUnsafeBytes { raw in
            for v in raw.bindMemory(to: Int16.self) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }

    // MARK: - DSP

    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func noise() -> Double { unit() * 2 - 1 }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    }

    /// Topology-preserving state-variable filter (stable at any cutoff).
    struct SVF {
        var ic1 = 0.0, ic2 = 0.0
        mutating func run(_ x: Double, cutoff: Double, q: Double) -> (lp: Double, bp: Double, hp: Double) {
            let g = tan(.pi * min(max(cutoff, 10), sampleRate * 0.45) / sampleRate)
            let k = 1 / max(q, 0.1)
            let a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2
            let v3 = x - ic2
            let v1 = a1 * ic1 + a2 * v3
            let v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2 * v1 - ic1
            ic2 = 2 * v2 - ic2
            return (v2, v1, x - k * v1 - v2)
        }
    }

    /// Small stereo Schroeder reverb.
    struct Reverb {
        var combs: [[Double]], combPos: [Int], combLP: [Double]
        var aps: [[Double]], apPos: [Int]
        init(offsetMs: Double) {
            combs = [29.7, 37.1, 41.1, 43.7].map { [Double](repeating: 0, count: Int(($0 + offsetMs) * sampleRate / 1000)) }
            combPos = [0, 0, 0, 0]; combLP = [0, 0, 0, 0]
            aps = [5.0, 1.7].map { [Double](repeating: 0, count: Int(($0 + offsetMs * 0.3) * sampleRate / 1000)) }
            apPos = [0, 0]
        }
        mutating func run(_ x: Double) -> Double {
            var y = 0.0
            for i in combs.indices {
                let out = combs[i][combPos[i]]
                combLP[i] = out * 0.75 + combLP[i] * 0.25
                combs[i][combPos[i]] = x + combLP[i] * 0.8
                combPos[i] = (combPos[i] + 1) % combs[i].count
                y += out
            }
            y *= 0.25
            for i in aps.indices {
                let buf = aps[i][apPos[i]]
                let v = y + buf * 0.6
                aps[i][apPos[i]] = v
                y = buf - v * 0.6
                apPos[i] = (apPos[i] + 1) % aps[i].count
            }
            return y
        }
    }

    struct Renderer {
        let s: SynthSettings
        let pitch: Double
        let length: Double
        var rng: RNG
        var left: [Float] = []
        var right: [Float] = []
        var hits: [Double] = []

        init(_ s: SynthSettings) {
            self.s = s
            pitch = min(max(s.pitch, 0.25), 4)
            length = min(max(s.duration ?? s.kind.defaultDuration, 0.02), 30)
            var seed: UInt64 = 0x5eed
            for b in "\(s.kind.rawValue)#\(s.variant)".utf8 { seed = (seed ^ UInt64(b)) &* 0x100000001b3 }
            rng = RNG(state: seed)
        }

        func n(_ seconds: Double) -> Int { Int(seconds * sampleRate) }

        /// Adds a mono voice with a pan (-1…1, per sample) at `offset` seconds.
        mutating func add(_ mono: [Double], at offset: Double, pan: (Int) -> Double = { _ in 0 }) {
            let o = max(0, n(offset))
            let need = o + mono.count
            if left.count < need {
                left += [Float](repeating: 0, count: need - left.count)
                right += [Float](repeating: 0, count: need - right.count)
            }
            for i in mono.indices {
                let p = min(max(pan(i), -1), 1)
                let angle = (p + 1) * .pi / 4
                left[o + i] += Float(mono[i] * cos(angle) * 1.414)
                right[o + i] += Float(mono[i] * sin(angle) * 1.414)
            }
        }

        mutating func run() {
            let k = s.kind
            if k.repeats, let c = s.count, c > 1 {
                let span = s.duration ?? Double(c) * k.repeatGap
                for j in 0..<c {
                    let t = span * Double(j) / Double(c)
                    let jitter = 1 + rng.range(-0.03, 0.03)
                    one(k, at: t, pitch: pitch * jitter, gain: j == 0 ? 1 : rng.range(0.8, 1))
                }
            } else {
                one(k, at: 0, pitch: pitch, gain: 1)
            }
            hits.sort()
            finish()
        }

        mutating func one(_ k: SynthKind, at t0: Double, pitch p: Double, gain: Double) {
            switch k {
            case .whoosh: whoosh(length, peakAt: 0.55, low: 250, high: 2900, q: 1.1, rumble: 0.35, pitch: p)
            case .swoosh: whoosh(length, peakAt: 0.42, low: 700, high: 6500, q: 0.8, rumble: 0.1, pitch: p)
            case .riser: riser(p)
            case .drop: drop(p)
            case .glitch: glitch(p)
            case .typing: typing(p)
            case .sparkle: sparkle(p)
            case .chime: chime(p)
            case .swell: swell(p)
            case .braam: braam(p)
            case .explosion: explosion(p)
            case .subdrop: subdrop(p)
            case .powerup: powerup(p)
            case .tada: tada(p)
            case .boing: boing(p)
            case .scribble: scribble(p)
            case .static: staticBurst(p)
            case .wind: wind(p)
            case .drone: drone(p)
            default:
                let (mono, hit) = shortSound(k, pitch: p)
                add(mono.map { $0 * gain }, at: t0)
                hits.append(t0 + hit)
            }
        }

        // MARK: Sounds

        mutating func whoosh(_ d: Double, peakAt pk: Double, low: Double, high: Double, q: Double, rumble: Double, pitch p: Double) {
            let count = n(d)
            var bp = SVF(), lp = SVF()
            var mono = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let u = Double(i) / Double(count)
                let env = u < pk ? pow(sin(.pi / 2 * u / pk), 2.2) : pow(cos(.pi / 2 * (u - pk) / (1 - pk)), 2.6)
                // Brighter while approaching (a bit of Doppler), darker going away.
                let doppler = u < pk ? 1.0 : 1 - 0.35 * (u - pk) / (1 - pk)
                let cut = p * (low + (high - low) * env) * doppler
                let x = rng.noise()
                let band = bp.run(x, cutoff: cut, q: q).bp
                let body = lp.run(x, cutoff: 160 * p, q: 0.7).lp
                mono[i] = (band * 1.4 + body * rumble * 2.5) * env
            }
            let dir = direction
            add(mono, at: 0) { i in dir * (Double(i) / Double(count) * 2 - 1) * 0.8 }
            hits.append(d * pk)
        }

        var direction: Double {
            switch s.direction?.lowercased() {
            case "left": return -1
            case "right": return 1
            default: return 0
            }
        }

        mutating func riser(_ p: Double) {
            let d = length, count = n(d)
            var bp = SVF()
            var mono = [Double](repeating: 0, count: count)
            var phase = 0.0, trem = 0.0
            for i in 0..<count {
                let t = Double(i) / sampleRate, u = t / d
                let env = pow(u, 2.2) * min(1, (1 - u) * d / 0.012 + 0.02)
                let cut = p * 220 * pow(36, pow(u, 1.4))
                let air = bp.run(rng.noise(), cutoff: cut, q: 1.6).bp * 1.6
                let f = p * 110 * pow(8, u * u)
                phase += 2 * .pi * f / sampleRate
                trem += 2 * .pi * (4 + 14 * u) / sampleRate
                let tone = (sin(phase) + 0.3 * sin(2 * phase)) * (0.75 + 0.25 * sin(trem)) * 0.35
                mono[i] = (air + tone) * env
            }
            let dir = direction
            add(mono, at: 0) { i in dir * (Double(i) / Double(count) * 2 - 1) * 0.6 }
            hits.append(d)
        }

        mutating func drop(_ p: Double) {
            let d = length, count = n(d)
            var bp = SVF()
            var mono = [Double](repeating: 0, count: count)
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / sampleRate, u = t / d
                let env = min(1, t / 0.005) * pow(1 - u, 1.5)
                let f = p * 900 * pow(0.08, u)
                phase += 2 * .pi * f / sampleRate
                let noise = bp.run(rng.noise(), cutoff: f * 2, q: 2).bp * 0.5
                mono[i] = (sin(phase) * 0.8 + noise) * env
            }
            add(mono, at: 0)
            hits.append(0.01)
        }

        mutating func glitch(_ p: Double) {
            let d = length, count = n(d)
            var mono = [Double](repeating: 0, count: count)
            var i = 0
            var last: [Double] = []
            while i < count {
                let segLen = min(count - i, n(rng.range(0.015, 0.055)))
                var seg = [Double](repeating: 0, count: segLen)
                let kind = rng.unit()
                let amp = rng.range(0.5, 1)
                if kind < 0.18 {
                    // silence
                } else if kind < 0.35, !last.isEmpty {
                    for j in 0..<segLen { seg[j] = last[j % last.count] } // stutter
                } else if kind < 0.65 {
                    let f = p * rng.range(80, 1800)
                    for j in 0..<segLen { seg[j] = (sin(2 * .pi * f * Double(j) / sampleRate) >= 0 ? 0.6 : -0.6) * amp }
                } else {
                    let hold = Int(rng.range(4, 40))
                    var v = 0.0
                    for j in 0..<segLen {
                        if j % hold == 0 { v = (rng.noise() * 4).rounded() / 4 }
                        seg[j] = v * amp * 0.8
                    }
                }
                // 2 ms edges so cuts click on purpose but do not crackle.
                let edge = min(segLen / 2, n(0.002))
                for j in 0..<edge { let g = Double(j) / Double(max(edge, 1)); seg[j] *= g; seg[segLen - 1 - j] *= g }
                for j in 0..<segLen { mono[i + j] = seg[j] }
                if !seg.allSatisfy({ $0 == 0 }) { last = seg }
                i += segLen
            }
            add(mono, at: 0) { j in sin(Double(j) / sampleRate * 37) * 0.4 }
            hits.append(0)
        }

        mutating func typing(_ p: Double) {
            let d = length
            var times: [Double] = []
            if let c = s.count, c > 0 {
                for j in 0..<c { times.append(d * Double(j) / Double(c) + (j == 0 ? 0 : rng.range(-0.012, 0.012))) }
            } else {
                var t = 0.0
                while t < d - 0.04 {
                    times.append(t)
                    t += rng.unit() < 0.08 ? rng.range(0.2, 0.3) : rng.range(0.06, 0.15)
                }
            }
            for t in times {
                let count = n(0.06)
                var bp = SVF()
                let f = p * rng.range(1800, 3200)
                let thock = p * rng.range(150, 220)
                let amp = rng.range(0.55, 1)
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let tt = Double(i) / sampleRate
                    let click = bp.run(rng.noise(), cutoff: f, q: 1.4).bp * exp(-tt / 0.006) * 2
                    let low = sin(2 * .pi * thock * tt) * exp(-tt / 0.014) * 0.45
                    mono[i] = (click + low) * amp * min(1, tt / 0.0005)
                }
                let pan = rng.range(-0.25, 0.25)
                add(mono, at: max(0, t)) { _ in pan }
                hits.append(max(0, t) + 0.001)
            }
        }

        mutating func sparkle(_ p: Double) {
            let d = length
            let pings = Int(18 * d) + 4
            for j in 0..<pings {
                let t = pow(rng.unit(), 1.6) * d * 0.7 + (j == 0 ? 0 : 0.01)
                let at = j == 0 ? 0 : t
                let f = p * rng.range(2600, 8000)
                let decay = rng.range(0.04, 0.16)
                let count = n(decay * 5)
                let amp = rng.range(0.15, 0.4) * (j == 0 ? 1.6 : 1)
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let tt = Double(i) / sampleRate
                    mono[i] = sin(2 * .pi * f * tt) * exp(-tt / decay) * amp * min(1, tt / 0.001)
                }
                let pan = rng.range(-0.8, 0.8)
                add(mono, at: at) { _ in pan }
            }
            // A soft airy shimmer under the pings.
            let count = n(d)
            var hp = SVF()
            var bed = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let u = Double(i) / Double(count)
                bed[i] = hp.run(rng.noise(), cutoff: 7000 * p, q: 0.7).hp * sin(.pi * min(1, u * 1.4)) * 0.12
            }
            add(bed, at: 0)
            hits.append(0.002)
        }

        mutating func chime(_ p: Double) {
            // Rising major arpeggio; the variant picks the root.
            let roots = [1046.5, 1174.7, 1318.5, 880.0]
            let root = roots[abs(s.variant) % roots.count] * p
            for (j, ratio) in [1.0, 1.26, 1.5].enumerated() {
                let (mono, _) = bell(root * ratio, decay: 0.7, length: length - Double(j) * 0.1)
                add(mono.map { $0 * (j == 2 ? 1 : 0.8) }, at: Double(j) * 0.1) { _ in Double(j - 1) * 0.3 }
            }
            hits.append(0.002)
        }

        // MARK: Cinematic

        /// Reverse cymbal: bright noise and a few metallic partials growing exponentially, cut at the end.
        mutating func swell(_ p: Double) {
            let d = length, count = n(d)
            var hp = SVF(), ring = SVF()
            var mono = [Double](repeating: 0, count: count)
            let partials = [3200.0, 4350, 5630, 7100, 8870].map { ($0 * p, rng.range(0, 2 * .pi)) }
            for i in 0..<count {
                let t = Double(i) / sampleRate, u = t / d
                let env = exp((u - 1) * 5.5) * min(1, (d - t) / 0.006)
                let x = rng.noise()
                var v = hp.run(x, cutoff: p * (2600 + 3400 * u), q: 0.7).hp * 0.8
                v += ring.run(x, cutoff: p * 5200, q: 6).bp * 0.6
                for (f, ph) in partials { v += sin(2 * .pi * f * t + ph) * 0.07 }
                mono[i] = v * env
            }
            let dir = direction
            add(mono, at: 0) { i in dir * (Double(i) / Double(count) * 2 - 1) * 0.6 }
            hits.append(d)
        }

        /// Band-limited sawtooth from a phase in 0…1 that advances `dt` per sample (polyBLEP at the jump).
        static func saw(_ phase: Double, _ dt: Double) -> Double {
            var v = 2 * phase - 1
            if phase < dt { let x = phase / dt; v -= x + x - x * x - 1 }
            else if phase > 1 - dt { let x = (phase - 1) / dt; v -= x * x + x + x + 1 }
            return v
        }

        /// Brass: pairs of detuned saws through a lowpass that opens with the attack and closes as the note fades.
        mutating func brass(_ freqs: [Double], length d: Double, attack: Double, release: Double, bright: Double,
                            detune: Double, drive: Double) -> [Double] {
            let count = n(max(0.02, d))
            var phases = (0..<freqs.count * 2).map { _ in rng.unit() }
            var lp = SVF()
            var mono = [Double](repeating: 0, count: count)
            let scale = 1 / Double(freqs.count * 2).squareRoot()
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let a = min(1, t / attack)
                let r = pow(min(1, max(0, (d - t) / release)), 1.5)
                var x = 0.0
                for (j, f) in freqs.enumerated() {
                    for k in 0..<2 {
                        let dt = f * (1 + (k == 0 ? -detune : detune)) / sampleRate
                        var ph = phases[2 * j + k] + dt
                        if ph >= 1 { ph -= 1 }
                        phases[2 * j + k] = ph
                        x += Self.saw(ph, dt)
                    }
                }
                let cut = freqs[0] * 2 + bright * a * a * (0.35 + 0.65 * exp(-t / (d * 0.5)))
                mono[i] = tanh(lp.run(x * scale, cutoff: cut, q: 0.9).lp * drive) * a * r
            }
            return mono
        }

        mutating func braam(_ p: Double) {
            let d = max(1, length)
            var mono = brass([55, 110, 164.8].map { $0 * p }, length: d, attack: 0.05, release: d * 0.7, bright: 3600,
                             detune: 0.007, drive: 2.5)
            var lp = SVF()
            for i in mono.indices {
                let t = Double(i) / sampleRate
                let sub = sin(2 * .pi * 55 * p * t) * 0.3 * min(1, t / 0.03) * pow(max(0, 1 - t / d), 1.5)
                let grit = lp.run(rng.noise(), cutoff: 900 * p, q: 0.8).lp * exp(-t / 0.06) * 1.5
                mono[i] += sub + grit * min(1, t / 0.002)
            }
            add(mono, at: 0)
            hits.append(0.05)
        }

        mutating func explosion(_ p: Double) {
            let d = max(0.8, length), count = n(d)
            var body = SVF(), low = SVF(), hp = SVF()
            var mono = [Double](repeating: 0, count: count)
            var phase = 0.0
            let wobble = rng.range(0, 2 * .pi)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let x = rng.noise()
                let crack = hp.run(x, cutoff: 1800 * p, q: 0.7).hp * exp(-t / 0.012) * 0.8
                let fire = body.run(x, cutoff: p * (120 + 3000 * exp(-t / 0.12)), q: 0.8).lp * exp(-t / (d * 0.22)) * 2.2
                let rumble = low.run(rng.noise(), cutoff: 90 * p, q: 1.2).lp * exp(-t / (d * 0.4)) * 10
                    * (0.7 + 0.3 * sin(2 * .pi * 7 * t + wobble))
                phase += 2 * .pi * p * (38 + 60 * exp(-t / 0.06)) / sampleRate
                let sub = sin(phase) * exp(-t / (d * 0.25))
                mono[i] = tanh((crack + fire + rumble + sub) * 1.5) * min(1, t / 0.0008) * min(1, (d - t) / 0.05)
            }
            add(mono, at: 0)
            hits.append(0.005)
        }

        mutating func subdrop(_ p: Double) {
            let d = max(0.4, length), count = n(d)
            var hp = SVF()
            var mono = [Double](repeating: 0, count: count)
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / sampleRate, u = t / d
                phase += 2 * .pi * p * (30 + 95 * exp(-t / (d * 0.22))) / sampleRate
                let click = hp.run(rng.noise(), cutoff: 2000, q: 0.7).hp * exp(-t / 0.003) * 0.2
                // Driven a little, so small speakers that cannot play the fundamental still get its harmonics.
                mono[i] = (tanh(sin(phase) * 1.8) + click) * min(1, t / 0.004) * pow(1 - u, 1.3)
            }
            add(mono, at: 0)
            hits.append(0.005)
        }

        // MARK: Game and interface

        mutating func powerup(_ p: Double) {
            let d = length
            let steps = [0, 4, 7, 12, 16, 19, 24, 28]
            let step = d / Double(steps.count + 2)
            var top = 0.0
            for (j, semis) in steps.enumerated() {
                let last = j == steps.count - 1
                let f = 330 * p * pow(2, Double(semis) / 12)
                let count = n(last ? step * 3 : step * 1.1)
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let ph = 2 * .pi * f * t
                    let env = min(1, t / 0.002) * (last ? exp(-t / (step * 1.2)) : min(1, (Double(count) / sampleRate - t) / 0.004))
                    mono[i] = (tanh(2.5 * sin(ph)) * 0.5 + sin(ph) * 0.3) * env
                }
                top = step * Double(j)
                add(mono, at: top)
            }
            hits.append(top + 0.002)
        }

        mutating func tada(_ p: Double) {
            let d = max(0.8, length)
            let ta = brass([392.0, 523.25, 659.25].map { $0 * p }, length: 0.16, attack: 0.012, release: 0.05, bright: 3200,
                           detune: 0.003, drive: 1.2)
            let da = brass([523.25, 659.25, 783.99, 1046.5].map { $0 * p }, length: d - 0.2, attack: 0.018,
                           release: min(0.6, (d - 0.2) * 0.6), bright: 4200, detune: 0.003, drive: 1.2)
            add(ta.map { $0 * 0.7 }, at: 0)
            add(da, at: 0.2)
            hits.append(0.215)
        }

        mutating func boing(_ p: Double) {
            let d = length, count = n(d)
            var mono = [Double](repeating: 0, count: count)
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let wobble = 0.55 * exp(-t / (d * 0.35)) * sin(2 * .pi * 11 * t)
                phase += 2 * .pi * p * 150 * (1 + wobble) * (1 + 0.3 * exp(-t / 0.03)) / sampleRate
                let tone = sin(phase) + 0.5 * sin(2 * phase) + 0.3 * sin(3 * phase) + 0.15 * sin(5 * phase)
                mono[i] = tone * 0.5 * min(1, t / 0.002) * exp(-t / (d * 0.3))
            }
            add(mono, at: 0)
            hits.append(0.004)
        }

        // MARK: Textures and beds

        /// Pencil on paper: strokes of band-passed noise, brighter where the hand moves faster, with paper grain.
        mutating func scribble(_ p: Double) {
            let d = length
            var t0 = 0.0
            var first = true
            while t0 < d - 0.05 || first {
                let len = min(max(0.05, d - t0), rng.range(0.08, 0.26))
                let count = n(len)
                var bp = SVF(), grainLP = SVF()
                let amp = first ? 1 : rng.range(0.5, 1)
                let base = p * rng.range(1900, 2600)
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let u = Double(i) / Double(count)
                    let speed = sin(.pi * u)
                    let grain = 0.65 + 10 * grainLP.run(rng.noise(), cutoff: 70, q: 0.7).lp
                    mono[i] = bp.run(rng.noise(), cutoff: base + 1500 * p * speed, q: 1.5).bp * pow(speed, 0.6) * max(0, grain) * amp
                }
                let from = rng.range(-0.3, 0.3), to = rng.range(-0.3, 0.3)
                add(mono, at: t0) { i in from + (to - from) * Double(i) / Double(count) }
                if first { hits.append(t0 + len * 0.5) }
                first = false
                t0 += len + rng.range(0.02, 0.09)
            }
        }

        mutating func staticBurst(_ p: Double) {
            let d = length, count = n(d)
            var bp = SVF()
            var mono = [Double](repeating: 0, count: count)
            var level = 1.0, hold = 0, crackle = 0.0
            for i in 0..<count {
                let t = Double(i) / sampleRate
                if hold == 0 { level = rng.range(0.45, 1); hold = n(rng.range(0.008, 0.04)) }
                hold -= 1
                if rng.unit() < 0.0015 { crackle = rng.range(0.6, 1.2) * (rng.unit() < 0.5 ? -1 : 1) }
                crackle *= 0.9
                let x = rng.noise()
                let hiss = bp.run(x, cutoff: 2800 * p, q: 0.5).bp + x * 0.3
                mono[i] = (hiss * level * 0.7 + crackle) * min(1, t / 0.003) * min(1, (d - t) / 0.003)
            }
            add(mono, at: 0)
            hits.append(0)
        }

        /// A slow random curve in 0…1: three sines at rates the listener cannot follow.
        mutating func drift(_ lowest: Double, _ highest: Double) -> (Double) -> Double {
            let parts = (0..<3).map { _ in (rng.range(lowest, highest), rng.range(0, 2 * .pi)) }
            return { t in
                var v = 0.0
                for (rate, ph) in parts { v += sin(2 * .pi * rate * t + ph) }
                return 0.5 + v / 6
            }
        }

        /// A bed's fade in and out (never more than a third of it each).
        func bedFade(_ t: Double, _ d: Double, fadeIn: Double, fadeOut: Double) -> Double {
            let a = min(fadeIn, d / 3), r = min(fadeOut, d / 3)
            let up = min(1, t / a), down = min(1, max(0, (d - t) / r))
            return up * up * (3 - 2 * up) * down * down * (3 - 2 * down)
        }

        mutating func wind(_ p: Double) {
            let d = max(0.5, length), count = n(d)
            var bpL = SVF(), bpR = SVF(), lp = SVF()
            let tone = drift(0.08, 0.45), gust = drift(0.05, 0.3), side = drift(0.05, 0.2)
            var l = [Double](repeating: 0, count: count), r = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let cut = p * (320 + 700 * tone(t))
                let g = (0.35 + 0.65 * gust(t)) * bedFade(t, d, fadeIn: 0.6, fadeOut: 0.9)
                let body = lp.run(rng.noise(), cutoff: 170 * p, q: 0.7).lp * 2.5
                // Two noise sources so the wind is wide, leaning slowly from one side to the other.
                let lean = (side(t) - 0.5) * 0.6
                l[i] = (bpL.run(rng.noise(), cutoff: cut, q: 1.6).bp * 1.6 * (1 - lean) + body) * g
                r[i] = (bpR.run(rng.noise(), cutoff: cut * 1.07, q: 1.6).bp * 1.6 * (1 + lean) + body) * g
            }
            add(l, at: 0) { _ in -1 }
            add(r, at: 0) { _ in 1 }
            hits.append(0)
        }

        mutating func drone(_ p: Double) {
            let d = max(1, length), count = n(d)
            let roots = [55.0, 49, 61.74, 46.25]
            let root = roots[abs(s.variant) % roots.count] * p
            // (ratio, level, pan): unison pair, fifth, and two octaves that small speakers can still play.
            let voices: [(Double, Double, Double)] = [(1, 1, -0.5), (1.004, 1, 0.5), (1.498, 0.45, -0.3), (2.003, 0.6, 0.3),
                                                      (4.01, 0.3, 0)]
            var phases = voices.map { _ in rng.unit() }
            let open = drift(0.03, 0.11), swellLFO = drift(0.04, 0.16)
            var lpL = SVF(), lpR = SVF(), air = SVF()
            var l = [Double](repeating: 0, count: count), r = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                var xl = 0.0, xr = 0.0
                for (j, v) in voices.enumerated() {
                    let dt = root * v.0 / sampleRate
                    var ph = phases[j] + dt
                    if ph >= 1 { ph -= 1 }
                    phases[j] = ph
                    let x = Self.saw(ph, dt) * v.1
                    xl += x * (1 - v.2) * 0.5
                    xr += x * (1 + v.2) * 0.5
                }
                let sub = sin(2 * .pi * root * 0.5 * t) * 0.6
                let cut = root * (5 + 9 * open(t))
                let hiss = air.run(rng.noise(), cutoff: 5000, q: 0.7).hp * 0.012
                let g = (0.75 + 0.25 * swellLFO(t)) * bedFade(t, d, fadeIn: 2, fadeOut: 2.5)
                l[i] = (lpL.run(xl, cutoff: cut, q: 1.2).lp + sub + hiss) * g
                r[i] = (lpR.run(xr, cutoff: cut, q: 1.2).lp + sub + hiss) * g
            }
            add(l, at: 0) { _ in -1 }
            add(r, at: 0) { _ in 1 }
            hits.append(0)
        }

        /// A soft mallet note: a sine with two harmonics that die sooner.
        func mallet(_ f: Double, decay: Double, at t: Double) -> Double {
            guard t >= 0 else { return 0 }
            let w = 2 * .pi * f * t
            return (sin(w) * exp(-t / decay) + 0.3 * sin(2 * w) * exp(-t / (decay * 0.4)) + 0.12 * sin(4 * w) * exp(-t / (decay * 0.2)))
                * min(1, t / 0.0015)
        }

        func bell(_ f0: Double, decay: Double, length d: Double) -> ([Double], Double) {
            let count = n(max(0.05, d))
            var mono = [Double](repeating: 0, count: count)
            let partials: [(Double, Double, Double)] = [(1, 1, 1), (2.0, 0.45, 0.6), (3.01, 0.22, 0.4), (4.17, 0.14, 0.25), (5.43, 0.08, 0.16)]
            for i in 0..<count {
                let t = Double(i) / sampleRate
                var v = 0.0
                for (r, a, dk) in partials { v += sin(2 * .pi * f0 * r * t) * a * exp(-t / (decay * dk)) }
                mono[i] = v * 0.45 * min(1, t / 0.002)
            }
            return (mono, 0.002)
        }

        /// Fixed-length one-shots. Returns the sound and its hit time.
        mutating func shortSound(_ k: SynthKind, pitch p: Double) -> ([Double], Double) {
            switch k {
            case .pop:
                let count = n(0.18)
                var phase = 0.0
                var hp = SVF()
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let f = p * (240 + 760 * exp(-t / 0.012))
                    phase += 2 * .pi * f / sampleRate
                    let body = sin(phase) * exp(-t / 0.035) * (1 - exp(-t / 0.0012))
                    let click = hp.run(rng.noise(), cutoff: 2500 * p, q: 0.7).hp * exp(-t / 0.002) * 0.35
                    mono[i] = body + click
                }
                return (mono, 0.004)
            case .blip:
                let count = n(0.14)
                var phase = 0.0
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let f = p * 520 * pow(2.6, min(1, t / 0.06))
                    phase += 2 * .pi * f / sampleRate
                    mono[i] = (sin(phase) + 0.25 * sin(3 * phase)) * 0.7 * min(1, t / 0.003) * exp(-max(0, t - 0.03) / 0.03)
                }
                return (mono, 0.03)
            case .click:
                let count = n(0.06)
                var bp = SVF()
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let noise = bp.run(rng.noise(), cutoff: 3500 * p, q: 1.8).bp * exp(-t / 0.004) * 2.2
                    let tone = sin(2 * .pi * 1800 * p * t) * exp(-t / 0.006) * 0.5
                    mono[i] = (noise + tone) * min(1, t / 0.0003)
                }
                return (mono, 0.001)
            case .tick:
                let count = n(0.05)
                var hp = SVF()
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let tone = sin(2 * .pi * 4200 * p * t) * exp(-t / 0.004) * 0.55
                    let noise = hp.run(rng.noise(), cutoff: 6000 * p, q: 0.7).hp * exp(-t / 0.0015) * 0.35
                    mono[i] = (tone + noise) * min(1, t / 0.0003)
                }
                return (mono, 0.001)
            case .ding:
                return bell(1318.5 * p, decay: 1.1, length: length)
            case .thud:
                let count = n(0.45)
                var phase = 0.0
                var lp = SVF()
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let f = p * (55 + 70 * exp(-t / 0.03))
                    phase += 2 * .pi * f / sampleRate
                    let body = sin(phase) * exp(-t / 0.12)
                    let knock = lp.run(rng.noise(), cutoff: 900 * p, q: 0.8).lp * exp(-t / 0.025) * 0.9
                    mono[i] = tanh((body + knock) * 1.4) * min(1, t / 0.001)
                }
                return (mono, 0.006)
            case .laser:
                let count = n(0.3)
                var phase = 0.0
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    phase += 2 * .pi * p * (300 + 3200 * exp(-t / 0.05)) / sampleRate
                    mono[i] = sin(phase + 0.8 * sin(phase * 2.01)) * exp(-t / 0.07) * min(1, t / 0.001)
                }
                return (mono, 0.002)
            case .beep:
                let d = 0.14, count = n(d)
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let w = 2 * .pi * 1000 * p * t
                    mono[i] = (sin(w) + 0.15 * sin(2 * w)) * 0.8 * min(1, t / 0.004) * min(1, (d - t) / 0.008)
                }
                return (mono, 0.004)
            case .coin:
                let count = n(0.5)
                var phase = 0.0
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    phase += 2 * .pi * p * (t < 0.07 ? 987.77 : 1318.5) / sampleRate
                    let env = t < 0.07 ? 0.8 : exp(-(t - 0.07) / 0.12)
                    mono[i] = tanh(3 * sin(phase)) * 0.5 * env * min(1, t / 0.001)
                }
                return (mono, 0.002)
            case .notification:
                let pairs = [(783.99, 1046.5), (880.0, 1318.5), (659.25, 987.77), (1046.5, 1567.98)]
                let (a, b) = pairs[abs(s.variant) % pairs.count]
                let count = n(0.6)
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    mono[i] = (mallet(a * p, decay: 0.11, at: t) + mallet(b * p, decay: 0.16, at: t - 0.13)) * 0.6
                }
                return (mono, 0.002)
            case .error:
                let count = n(0.4)
                var phase = 0.0
                var lp = SVF()
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    // Two notes, the second lower: 0–0.14 s and 0.19–0.4 s.
                    let second = t >= 0.19
                    let local = second ? t - 0.19 : t, len = second ? 0.21 : 0.14
                    phase += 2 * .pi * p * (second ? 146.83 : 196) / sampleRate
                    let env = min(1, local / 0.004) * min(1, max(0, (len - local) / 0.012))
                    mono[i] = lp.run(sin(phase) >= 0 ? 0.7 : -0.7, cutoff: 1800 * p, q: 0.8).lp * env
                }
                return (mono, 0.005)
            case .shutter:
                let count = n(0.2)
                var snap = SVF(), whir = SVF()
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let x = rng.noise()
                    // The curtain opens, a short mechanical whir, and it closes (a little softer).
                    let t2 = t - 0.075
                    let open = exp(-t / 0.004) * min(1, t / 0.0003)
                    let close = t2 >= 0 ? exp(-t2 / 0.006) * min(1, t2 / 0.0003) * 0.8 : 0
                    let clicks = snap.run(x, cutoff: p * (t2 >= 0 ? 2600 : 3600), q: 2).bp * (open + close) * 2
                    let thock = sin(2 * .pi * 420 * p * t) * open * 0.4 + (t2 >= 0 ? sin(2 * .pi * 300 * p * t2) * close * 0.4 : 0)
                    let motor = t < 0.075 ? whir.run(x, cutoff: 900 * p, q: 3).bp * 0.12 : 0
                    mono[i] = clicks + thock + motor
                }
                return (mono, 0.002)
            case .clap:
                let count = n(0.3)
                var body = SVF(), air = SVF()
                // Several palms landing a few ms apart, then the room.
                let starts = [0.0, rng.range(0.008, 0.012), rng.range(0.018, 0.023), 0.03]
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    var env = 0.0
                    for (j, o) in starts.enumerated() where t >= o {
                        env = max(env, exp(-(t - o) / (j == starts.count - 1 ? 0.045 : 0.006)))
                    }
                    let x = rng.noise()
                    mono[i] = (body.run(x, cutoff: 1300 * p, q: 1.2).bp * 2.2 + air.run(x, cutoff: 3500 * p, q: 0.7).hp * 0.35) * env
                }
                return (mono, 0.02)
            case .droplet:
                let count = n(0.3)
                var phase = 0.0, phase2 = 0.0
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    phase += 2 * .pi * p * (700 + 1100 * (1 - exp(-t / 0.018))) / sampleRate
                    var v = sin(phase) * exp(-t / 0.045) * (1 - exp(-t / 0.0015))
                    let t2 = t - 0.085
                    if t2 >= 0 {
                        phase2 += 2 * .pi * p * (1500 + 900 * (1 - exp(-t2 / 0.012))) / sampleRate
                        v += sin(phase2) * exp(-t2 / 0.03) * (1 - exp(-t2 / 0.0015)) * 0.35
                    }
                    mono[i] = v
                }
                return (mono, 0.004)
            case .heartbeat:
                let count = n(0.5)
                var mono = [Double](repeating: 0, count: count)
                // Lub (lower, louder) and dub; the pitch of each falls within 25 ms.
                func thump(_ t: Double, base: Double, amp: Double) -> Double {
                    guard t >= 0 else { return 0 }
                    let phase = 2 * .pi * p * (base * t + 40 * 0.025 * (1 - exp(-t / 0.025)))
                    return (sin(phase) + 0.3 * sin(2 * phase)) * exp(-t / 0.07) * (1 - exp(-t / 0.004)) * amp
                }
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    mono[i] = tanh((thump(t, base: 48, amp: 1) + thump(t - 0.26, base: 58, amp: 0.75)) * 1.5)
                }
                return (mono, 0.012)
            default: // impact
                let count = n(max(0.6, length))
                var phase = 0.0
                var lp = SVF(), hp = SVF()
                var mono = [Double](repeating: 0, count: count)
                for i in 0..<count {
                    let t = Double(i) / sampleRate
                    let f = p * (42 + 110 * exp(-t / 0.045))
                    phase += 2 * .pi * f / sampleRate
                    let sub = sin(phase) * exp(-t / 0.5)
                    let x = rng.noise()
                    let crunch = lp.run(x, cutoff: p * (200 + 2600 * exp(-t / 0.05)), q: 0.9).lp * exp(-t / 0.09) * 1.2
                    let snap = hp.run(x, cutoff: 3000 * p, q: 0.7).hp * exp(-t / 0.004) * 0.6
                    mono[i] = tanh((sub + crunch + snap) * 1.6) * min(1, t / 0.0008)
                }
                return (mono, 0.006)
            }
        }

        // MARK: Finish

        mutating func finish() {
            guard !left.isEmpty else { left = [0]; right = [0]; return }
            let amount = min(max(s.reverb ?? s.kind.defaultReverb, 0), 1)
            if amount > 0 {
                let tail = n(0.4 + 1.2 * amount)
                left += [Float](repeating: 0, count: tail)
                right += [Float](repeating: 0, count: tail)
                var rl = Reverb(offsetMs: 0), rr = Reverb(offsetMs: 1.3)
                let wet = 0.5 * amount
                for i in left.indices {
                    let l = Double(left[i]), r = Double(right[i])
                    left[i] = Float(l + rl.run(l) * wet)
                    right[i] = Float(r + rr.run(r) * wet)
                }
            }
            // Remove DC, normalize to -1 dBFS, fade the very end.
            for ch in 0..<2 {
                var x = ch == 0 ? left : right
                var prevIn: Float = 0, prevOut: Float = 0
                for i in x.indices {
                    let y = x[i] - prevIn + 0.9995 * prevOut
                    prevIn = x[i]; prevOut = y; x[i] = y
                }
                if ch == 0 { left = x } else { right = x }
            }
            let peak = max(left.map(abs).max() ?? 0, right.map(abs).max() ?? 0)
            if peak > 1e-6 {
                let g = Float(0.89 * s.kind.level) / peak
                for i in left.indices { left[i] *= g; right[i] *= g }
            }
            // Trim trailing near-silence, then a 10 ms fade-out.
            let floor: Float = 0.0005
            var end = left.count
            while end > 1 && abs(left[end - 1]) < floor && abs(right[end - 1]) < floor { end -= 1 }
            end = min(left.count, end + n(0.01))
            left = Array(left[..<end]); right = Array(right[..<end])
            let fade = min(left.count, n(0.01))
            for j in 0..<fade {
                let g = Float(j) / Float(max(fade, 1))
                left[left.count - 1 - j] *= g
                right[right.count - 1 - j] *= g
            }
        }
    }
}
