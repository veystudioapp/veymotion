import Foundation

// A music bed made to measure for a cut (`generate_music`): drums, bass, pad and a mallet motif on a tempo grid,
// with accents (a crash + sub boom, the drums dropping out on the beat before and a riser over the bar before) on the
// moments that matter, an ending hit on the last bar line, or a seamless loop. Deterministic like `SoundSynth`
// (seeded by the settings), so the same settings give the same file, and every bar line and accent time is known
// exactly instead of analyzed afterwards.

public enum MusicStyle: String, CaseIterable, Codable, Sendable {
    /// Syncopated kick, soft clap, 8th hats, plucked bass, a sparse motif: explainers, product, UI.
    case minimal
    /// Four on the floor, open hats off the beat, rolling bass pumping under the kick: promos, launches, reels.
    case driving
    /// No hats, a soft kick on beats 1 and 3, a wide pad and slow notes in a large room: calm, premium, emotional.
    case ambient
}

public struct MusicSettings: Hashable, Codable, Sendable {
    public var style: MusicStyle
    /// Beats per minute (40…200). A loop adjusts it so the duration holds whole bars.
    public var bpm: Double
    /// Seconds of music.
    public var duration: Double
    /// "A minor", "C major", "F#m", "Eb" (a bare note is major).
    public var key: String
    /// File seconds of the moments to hit; each is moved to the nearest 8th note.
    public var accents: [Double]
    /// The end flows into the start (whole bars, no intro or ending, tails wrapped around).
    public var loop: Bool
    /// Another motif and chord progression for the same settings.
    public var variant: Int

    public init(style: MusicStyle = .minimal, bpm: Double = 110, duration: Double, key: String = "A minor",
                accents: [Double] = [], loop: Bool = false, variant: Int = 0) {
        self.style = style; self.bpm = bpm; self.duration = duration; self.key = key
        self.accents = accents; self.loop = loop; self.variant = variant
    }

    var fileKey: String {
        let s = [style.rawValue, String(format: "%.3f", bpm), String(format: "%.3f", duration), key.lowercased(),
                 accents.map { String(format: "%.3f", $0) }.joined(separator: ","), loop ? "loop" : "-", String(variant)]
            .joined(separator: "|")
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h ^ (h >> 32)))
    }
}

public struct MusicResult: Sendable {
    public let url: URL
    public let duration: Double
    /// The tempo used (a loop may have adjusted it).
    public let bpm: Double
    /// File seconds of every bar's first beat.
    public let bars: [Double]
    /// File seconds where the accents landed (snapped to 8th notes).
    public let accents: [Double]
    /// File seconds of the ending hit (nil for loops and pieces under two bars).
    public let ending: Double?
    public var beat: Double { 60 / bpm }
}

public enum MusicSynth {
    static let sampleRate = SoundSynth.sampleRate

    /// Pitch class (C = 0) and minor/major of a key name.
    static func parseKey(_ name: String) -> (pc: Int, minor: Bool) {
        let letters: [Character: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11]
        var rest = Substring(name.lowercased().trimmingCharacters(in: .whitespaces))
        guard let first = rest.first, var pc = letters[first] else { return (9, true) }
        rest = rest.dropFirst()
        if rest.first == "#" || rest.first == "♯" { pc += 1; rest = rest.dropFirst() }
        else if rest.first == "b" || rest.first == "♭" { pc += 11; rest = rest.dropFirst() }
        let mode = rest.trimmingCharacters(in: .whitespaces)
        let minor = mode.hasPrefix("min") || mode == "m" || mode.hasPrefix("m ")
        return (pc % 12, minor)
    }

    public static func render(_ s: MusicSettings) -> (left: [Float], right: [Float], result: MusicResult) {
        var r = Arranger(s)
        r.run()
        let result = MusicResult(url: URL(fileURLWithPath: "/"), duration: Double(r.left.count) / sampleRate, bpm: r.bpm,
                                 bars: r.barTimes, accents: r.accents, ending: r.ending)
        return (r.left, r.right, result)
    }

    /// Writes a 16-bit stereo WAV into the asset library (`music/` in projects). Same settings reuse the same file.
    public static func generate(_ s: MusicSettings, folder: String? = nil) throws -> MusicResult {
        let folder = AssetStore.routed(folder, default: "music")
        var dir = AssetStore.directory
        let sub = try AssetStore.validFolder(folder)
        if !sub.isEmpty { dir = dir.appendingPathComponent(sub, isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("music-\(s.style.rawValue)-\(s.fileKey).wav")
        let out = render(s)
        if !FileManager.default.fileExists(atPath: url.path) {
            // Not `.atomic`: that stages the file in the system temp folder, which sandboxed processes cannot use.
            let part = url.appendingPathExtension("part")
            try SoundSynth.wav(left: out.left, right: out.right).write(to: part)
            try FileManager.default.moveItem(at: part, to: url)
        }
        let r = out.result
        return MusicResult(url: url, duration: r.duration, bpm: r.bpm, bars: r.bars, accents: r.accents, ending: r.ending)
    }

    struct Arranger {
        typealias RNG = SoundSynth.RNG
        typealias SVF = SoundSynth.SVF

        let s: MusicSettings
        let bpm: Double
        let length: Double
        let step: Double          // a 16th note
        let bar: Double
        let barCount: Int
        let keyPC: Int, minor: Bool
        var rng: RNG
        var barTimes: [Double] = []
        var accents: [Double] = []
        var ending: Double?
        // Buses: drums are dry and never ducked; `tonal` pumps under the kick; `send` goes to the room.
        var drumsL: [Double], drumsR: [Double], tonalL: [Double], tonalR: [Double], sendL: [Double], sendR: [Double]
        var kicks: [Double] = []
        var left: [Float] = [], right: [Float] = []

        init(_ s: MusicSettings) {
            self.s = s
            length = min(max(s.duration, 1), 300)
            var bpm = min(max(s.bpm, 40), 200)
            if s.loop {
                let bars = max(1, (length / (240 / bpm)).rounded())
                bpm = bars * 240 / length
            }
            self.bpm = bpm
            step = 15 / bpm
            bar = 16 * step
            barCount = Int((length / bar - 1e-6).rounded(.up))
            (keyPC, minor) = MusicSynth.parseKey(s.key)
            var seed: UInt64 = 0x6d75736963
            for b in "\(s.style.rawValue)#\(s.variant)#\(keyPC)".utf8 { seed = (seed ^ UInt64(b)) &* 0x100000001b3 }
            rng = RNG(state: seed)
            let total = Int((length + 4) * MusicSynth.sampleRate)
            drumsL = [Double](repeating: 0, count: total); drumsR = drumsL
            tonalL = drumsL; tonalR = drumsL; sendL = drumsL; sendR = drumsL
        }

        func n(_ t: Double) -> Int { Int(t * MusicSynth.sampleRate) }
        static func freq(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

        mutating func put(_ mono: [Double], at t: Double, pan: Double = 0, gain: Double = 1, bus: Int, send: Double = 0) {
            let o = n(t), angle = (min(max(pan, -1), 1) + 1) * .pi / 4
            let gl = cos(angle) * 1.414 * gain, gr = sin(angle) * 1.414 * gain
            let count = min(mono.count, drumsL.count - o)
            guard o >= 0, count > 0 else { return }
            for i in 0..<count {
                let l = mono[i] * gl, r = mono[i] * gr
                if bus == 0 { drumsL[o + i] += l; drumsR[o + i] += r } else { tonalL[o + i] += l; tonalR[o + i] += r }
                if send > 0 { sendL[o + i] += l * send; sendR[o + i] += r * send }
            }
        }

        /// The chord of a bar: (root pitch class offset from the key, minor).
        func chord(_ barIndex: Int) -> (Int, Bool) {
            let minorProgs: [[(Int, Bool)]] = [[(0, true), (8, false), (3, false), (10, false)],
                                               [(0, true), (5, true), (8, false), (7, false)]]
            let majorProgs: [[(Int, Bool)]] = [[(0, false), (7, false), (9, true), (5, false)],
                                               [(0, false), (9, true), (5, false), (7, false)]]
            let progs = minor ? minorProgs : majorProgs
            let prog = progs[abs(s.variant) % progs.count]
            let per = s.style == .ambient ? 2 : 1
            return prog[(barIndex / per) % prog.count]
        }

        /// Chord tones as MIDI notes: root, third, fifth in the octave from `base`.
        func tones(_ barIndex: Int, base: Int) -> [Double] {
            let (deg, isMinor) = chord(barIndex)
            let root = Double(base + (keyPC + deg) % 12)
            return [root, root + (isMinor ? 3 : 4), root + 7]
        }

        mutating func run() {
            let style = s.style
            barTimes = (0..<barCount).map { Double($0) * bar }.filter { $0 < length - 1e-6 }
            let eighth = 2 * step
            accents = Array(Set(s.accents.map { min(max(0, ($0 / eighth).rounded() * eighth), length) }
                .filter { $0 < length - 1e-6 })).sorted()
            if !s.loop, barCount >= 2 {
                let ring = min(1.5, max(0.6, bar * 0.5))
                let last = ((length - ring) / bar).rounded(.down) * bar
                if last >= bar { ending = last }
            }
            let stop = ending ?? length
            let intro = !s.loop && barCount >= 6

            // A motif of chord-tone notes on 16ths, kept for the whole piece.
            let density: Double = style == .driving ? 0.5 : style == .ambient ? 1 : 0.35
            var motif: [Int?] = []
            for i in 0..<16 {
                // Ambient notes fall on the beats, so the slow motif still states the tempo.
                let allowed = style == .ambient ? i % 4 == 0 : true
                motif.append(allowed && (i == 0 || rng.unit() < density) ? Int(rng.unit() * 4) : nil)
            }

            // Drum, bass and motif events on the 16th grid.
            let steps = Int((stop / step).rounded(.up))
            for k in 0..<max(0, steps) {
                let t = Double(k) * step
                guard t < stop - 1e-6 else { break }
                let b = k / 16, i = k % 16
                let gap = accents.contains { $0 >= bar && t >= $0 - 4 * step && t < $0 }
                let full = !(intro && b == 0)
                if !gap {
                    switch style {
                    case .minimal:
                        if i == 0 || i == 8 { kick(at: t, gain: 1) }
                        if i == 11 { kick(at: t, gain: 0.55) }
                        if i == 4 || i == 12 { clap(at: t, gain: 0.85) }
                        if full, i % 2 == 0 { hat(at: t, open: false, gain: i % 4 == 2 ? 0.7 : 0.4) }
                    case .driving:
                        if i % 4 == 0 { kick(at: t, gain: 1) }
                        if i == 4 || i == 12 { clap(at: t, gain: 0.7) }
                        if full, i % 4 == 2 { hat(at: t, open: true, gain: 0.55) }
                        if full, i % 2 == 1 { hat(at: t, open: false, gain: 0.25) }
                    case .ambient:
                        if i == 0 || i == 8 { kick(at: t, gain: i == 0 ? 0.55 : 0.35) }
                    }
                }
                // Bass.
                let root = tones(b, base: 36)[0]
                switch style {
                case .minimal:
                    if [0, 3, 8, 11].contains(i) { bass(root + (i == 11 ? 7 : 0), at: t, length: step * 1.6, gain: 0.8) }
                case .driving:
                    if i % 4 != 0 { bass(root + (i % 4 == 2 ? 12 : 0), at: t, length: step * 0.8, gain: 0.7) }
                case .ambient:
                    if i == 0, b % 2 == 0 { sub(root, at: t, length: bar * 2, gain: 0.55) }
                }
                // Motif.
                if full, let which = motif[i] {
                    let notes = tones(b, base: 72) + [tones(b, base: 72)[0] + 12]
                    mallet(notes[which % notes.count], at: t, gain: style == .ambient ? 0.32 : 0.22,
                           pan: (i % 4 < 2 ? -0.35 : 0.35), decay: style == .ambient ? 0.9 : 0.35)
                }
            }
            // Pads: one chord per chord change, held to the next.
            let per = style == .ambient ? 2 : 1
            var b = 0
            while Double(b) * bar < stop - 1e-6 {
                let t = Double(b) * bar
                let hold = min(Double(per) * bar, stop - t)
                pad(tones(b, base: 60), at: t, length: hold, gain: style == .ambient ? 0.42 : style == .driving ? 0.16 : 0.22)
                b += per
            }
            // Accents: riser over the bar before, crash + boom on the hit.
            for a in accents {
                if a >= bar { riser(from: a - bar, to: a) }
                crash(at: a)
                kick(at: a, gain: 1.1)
            }
            if let e = ending {
                crash(at: e)
                kick(at: e, gain: 1.1)
                let last = Int((e / bar).rounded())
                pad(tones(last, base: 60) + [tones(last, base: 60)[0] + 12], at: e, length: length - e, gain: 0.35)
                sub(tones(last, base: 36)[0], at: e, length: length - e, gain: 0.6)
                for (j, note) in tones(last, base: 72).enumerated() {
                    mallet(note, at: e + Double(j) * 0.03, gain: 0.25, pan: Double(j - 1) * 0.4, decay: 1.2)
                }
            }
            mix()
        }

        // MARK: Voices

        mutating func kick(at t: Double, gain: Double) {
            kicks.append(t)
            let count = n(0.4)
            var phase = 0.0
            var mono = [Double](repeating: 0, count: count)
            let punch = s.style == .ambient ? 0.02 : 0.032
            for i in 0..<count {
                let x = Double(i) / MusicSynth.sampleRate
                phase += 2 * .pi * (46 + 120 * exp(-x / punch)) / MusicSynth.sampleRate
                let click = x < 0.004 ? rng.noise() * (1 - x / 0.004) * 0.3 : 0
                mono[i] = tanh((sin(phase) * exp(-x / 0.22) + click) * 1.3) * min(1, x / 0.0008)
            }
            put(mono, at: t, gain: gain * 0.9, bus: 0)
        }

        mutating func hat(at t: Double, open: Bool, gain: Double) {
            let count = n(open ? 0.25 : 0.06)
            var hp = SVF()
            var mono = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let x = Double(i) / MusicSynth.sampleRate
                mono[i] = hp.run(rng.noise(), cutoff: 7500, q: 0.8).hp * exp(-x / (open ? 0.09 : 0.018)) * min(1, x / 0.0005)
            }
            put(mono, at: t, pan: open ? 0.25 : -0.2, gain: gain * 0.35, bus: 0, send: 0.1)
        }

        mutating func clap(at t: Double, gain: Double) {
            let count = n(0.3)
            var bp = SVF()
            let starts = [0.0, 0.009, 0.019, 0.028]
            var mono = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let x = Double(i) / MusicSynth.sampleRate
                var env = 0.0
                for (j, o) in starts.enumerated() where x >= o {
                    env = max(env, exp(-(x - o) / (j == starts.count - 1 ? 0.05 : 0.006)))
                }
                mono[i] = bp.run(rng.noise(), cutoff: 1400, q: 1.1).bp * 2 * env
            }
            put(mono, at: t, gain: gain * 0.6, bus: 0, send: 0.35)
        }

        mutating func bass(_ midi: Double, at t: Double, length d: Double, gain: Double) {
            let count = n(d + 0.05), f = Arranger.freq(midi)
            var lp = SVF()
            var phase = 0.0
            var mono = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let x = Double(i) / MusicSynth.sampleRate
                phase += f / MusicSynth.sampleRate
                if phase >= 1 { phase -= 1 }
                let saw = 2 * phase - 1
                let cutoff = 180 + 1400 * exp(-x / 0.07)
                let env = min(1, x / 0.003) * (x < d ? 1 : max(0, 1 - (x - d) / 0.05))
                mono[i] = (lp.run(saw, cutoff: cutoff, q: 1.4).lp + 0.5 * sin(2 * .pi * phase)) * env
            }
            put(mono, at: t, gain: gain * 0.55, bus: 1)
        }

        mutating func sub(_ midi: Double, at t: Double, length d: Double, gain: Double) {
            let count = n(d), f = Arranger.freq(midi)
            var mono = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let x = Double(i) / MusicSynth.sampleRate
                let env = min(1, x / 0.4) * min(1, max(0, d - x) / 0.6)
                mono[i] = (sin(2 * .pi * f * x) + 0.2 * sin(4 * .pi * f * x)) * env
            }
            put(mono, at: t, gain: gain * 0.5, bus: 1)
        }

        mutating func mallet(_ midi: Double, at t: Double, gain: Double, pan: Double, decay: Double) {
            let count = n(decay * 4), f = Arranger.freq(midi)
            var mono = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let x = Double(i) / MusicSynth.sampleRate, w = 2 * .pi * f * x
                mono[i] = (sin(w) * exp(-x / decay) + 0.25 * sin(2 * w) * exp(-x / (decay * 0.3))
                           + 0.08 * sin(4.2 * w) * exp(-x / (decay * 0.1))) * min(1, x / 0.002)
            }
            put(mono, at: t, pan: pan, gain: gain, bus: 1, send: 0.45)
        }

        mutating func pad(_ notes: [Double], at t: Double, length d: Double, gain: Double) {
            let release = 0.6, count = n(d + release)
            var lp = SVF()
            var phases = notes.flatMap { _ in [rng.unit(), rng.unit()] }
            var mono = [Double](repeating: 0, count: count)
            let freqs = notes.flatMap { [Arranger.freq($0) * 0.997, Arranger.freq($0) * 1.003] }
            for i in 0..<count {
                let x = Double(i) / MusicSynth.sampleRate
                var v = 0.0
                for j in freqs.indices {
                    phases[j] += freqs[j] / MusicSynth.sampleRate
                    if phases[j] >= 1 { phases[j] -= 1 }
                    v += 2 * phases[j] - 1
                }
                let env = min(1, x / 0.35) * (x < d ? 1 : max(0, 1 - (x - d) / release))
                let cutoff = 700 + 500 * sin(2 * .pi * (t + x) / 7)
                mono[i] = lp.run(v / Double(freqs.count), cutoff: cutoff, q: 0.9).lp * env
            }
            put(mono, at: t, gain: gain * 1.6, bus: 1, send: 0.5)
        }

        mutating func crash(at t: Double) {
            let count = n(2.2)
            var hp = SVF(), bp = SVF()
            var mono = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let x = Double(i) / MusicSynth.sampleRate, noise = rng.noise()
                let shimmer = hp.run(noise, cutoff: 5000, q: 0.7).hp + 0.5 * bp.run(noise, cutoff: 3200, q: 2).bp
                let boom = sin(2 * .pi * (42 + 30 * exp(-x / 0.05)) * x) * exp(-x / 0.45)
                mono[i] = (shimmer * exp(-x / 0.7) * 0.4 + boom * 0.9) * min(1, x / 0.001)
            }
            put(mono, at: t, gain: 0.8, bus: 0, send: 0.4)
        }

        mutating func riser(from a: Double, to b: Double) {
            let d = b - a, count = n(d)
            var bp = SVF()
            var mono = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let p = Double(i) / Double(max(count, 1))
                mono[i] = bp.run(rng.noise(), cutoff: 400 * pow(15, p), q: 1.6).bp * p * p * 1.4
            }
            put(mono, at: a, gain: 0.5, bus: 0, send: 0.3)
        }

        // MARK: Mix

        mutating func mix() {
            let total = drumsL.count, sr = MusicSynth.sampleRate
            // The tonal bus dips under every kick (sidechain pump), deeper for driving.
            let depth = s.style == .driving ? 0.55 : s.style == .minimal ? 0.35 : 0.15
            var duck = [Double](repeating: 1, count: total)
            for k in kicks.sorted() {
                let o = n(k), span = min(total - o, n(0.5))
                guard o >= 0, span > 0 else { continue }
                for i in 0..<span { duck[o + i] = min(duck[o + i], 1 - depth * exp(-Double(i) / sr / 0.12)) }
            }
            var rl = SoundSynth.Reverb(offsetMs: s.style == .ambient ? 12 : 0)
            var rr = SoundSynth.Reverb(offsetMs: s.style == .ambient ? 13.3 : 1.3)
            let wet = s.style == .ambient ? 1.1 : 0.6
            var l = [Double](repeating: 0, count: total), r = l
            for i in 0..<total {
                l[i] = drumsL[i] + tonalL[i] * duck[i] + rl.run(sendL[i]) * wet
                r[i] = drumsR[i] + tonalR[i] * duck[i] + rr.run(sendR[i]) * wet
            }
            let end = n(length)
            if s.loop {
                // What rings past the end plays over the start of the next time round.
                for i in end..<total { l[i - end] += l[i]; r[i - end] += r[i] }
            }
            l = Array(l[..<end]); r = Array(r[..<end])
            // DC out, gentle saturation, normalize to -1 dBFS.
            for ch in 0..<2 {
                var x = ch == 0 ? l : r
                var prevIn = 0.0, prevOut = 0.0
                if !s.loop {
                    for i in x.indices {
                        let y = x[i] - prevIn + 0.9995 * prevOut
                        prevIn = x[i]; prevOut = y; x[i] = y
                    }
                }
                if ch == 0 { l = x } else { r = x }
            }
            let peak = max(l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
            let g = peak > 1e-9 ? 1.4 / peak : 1
            let norm = tanh(1.4)
            left = l.map { Float(tanh($0 * g) / norm * 0.89) }
            right = r.map { Float(tanh($0 * g) / norm * 0.89) }
            if !s.loop {
                let fade = min(left.count, n(0.3))
                for j in 0..<fade {
                    let k = Float(j) / Float(max(fade, 1))
                    left[left.count - 1 - j] *= k
                    right[right.count - 1 - j] *= k
                }
            }
        }
    }
}
