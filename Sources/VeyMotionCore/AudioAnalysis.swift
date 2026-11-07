import Accelerate
import AVFoundation
import Foundation

/// What an `audioReact` follows: a loudness band, or a pulse on every beat / bar.
public enum AudioBand: String, Codable, CaseIterable, Sendable {
    case level, bass, mid, treble, beat, downbeat

    public var title: String {
        switch self {
        case .level: return "Level"
        case .bass: return "Bass"
        case .mid: return "Mid"
        case .treble: return "Treble"
        case .beat: return "Beat"
        case .downbeat: return "Bar"
        }
    }
}

/// Rhythm and loudness of an audio file (all times are file seconds): tempo, beats, downbeats, strong hits (onsets)
/// and loudness envelopes per band. Used by `analyze_audio`, the timeline's beat markers and `audioReact`.
public struct AudioAnalysis: Sendable {
    /// Envelope samples per second.
    public static let frameRate = 100.0
    /// Flux peaks about a frame before the attack (the analysis window is centered), so hit times are shifted by this.
    static let onsetLatency = 0.01

    public struct Onset: Sendable {
        public let t: Double
        /// 0…1 relative to the file's strongest hits.
        public let strength: Double
    }

    public let duration: Double
    /// nil when the file has no steady beat (silence, speech, free-time music).
    public let bpm: Double?
    public let beats: [Double]
    /// First beat of each bar (4/4 assumed).
    public let downbeats: [Double]
    public let onsets: [Onset]
    /// level/bass/mid/treble: 0…1 per frame (1 ≈ the file's loud parts).
    let bands: [AudioBand: [Float]]
    /// Log-spaced bands from ~30 Hz to 11 kHz, `spectrumBands` per frame, each 0…1 against its own loud parts
    /// (so the highs move as much as the bass, like a music visualizer).
    var spectrum: [Float] = []
    var spectrumBands = 0

    /// Envelope of a band at `frameRate`, with an instant attack and an exponential `release` (seconds).
    /// beat/downbeat: a pulse of 1 on each beat/bar that fades over `release`.
    public func envelope(_ band: AudioBand, release: Double) -> [Float] {
        let count = Int((duration * Self.frameRate).rounded(.up)) + 1
        let decay = Float(exp(-1 / (max(release, 0.01) * Self.frameRate)))
        var out = [Float](repeating: 0, count: count)
        switch band {
        case .beat, .downbeat:
            var hits = [Bool](repeating: false, count: count)
            for t in band == .beat ? beats : downbeats {
                let i = Int((t * Self.frameRate).rounded())
                if i >= 0 && i < count { hits[i] = true }
            }
            var v: Float = 0
            for i in 0..<count {
                v = hits[i] ? 1 : v * decay
                out[i] = v
            }
        default:
            let raw = bands[band] ?? []
            var v: Float = 0
            for i in 0..<min(count, raw.count) {
                v = max(raw[i], v * decay)
                out[i] = v
            }
        }
        return out
    }

    /// Loudness (0…1) averaged over each `step` seconds from `from` to `to`.
    public func loudness(from: Double, to: Double, step: Double = 1) -> [Double] {
        guard let level = bands[.level], to > from else { return [] }
        var out: [Double] = []
        var t = from
        while t < to - 1e-9 {
            let a = max(0, Int(t * Self.frameRate)), b = min(level.count, Int(min(t + step, to) * Self.frameRate))
            out.append(b > a ? Double(level[a..<b].reduce(0, +)) / Double(b - a) : 0)
            t += step
        }
        return out
    }

    // MARK: - Analysis

    /// Decodes and analyzes a whole file (about a second for a few minutes of music).
    public static func analyze(path: String) throws -> AudioAnalysis {
        let (samples, rate) = try readMono(path)
        return analyze(samples: samples, sampleRate: rate)
    }

    static func analyze(samples: [Float], sampleRate sr: Double) -> AudioAnalysis {
        let duration = Double(samples.count) / sr
        let n = 1024, half = n / 2
        let log2n = vDSP_Length(10)
        let hop = sr / frameRate
        let frames = max(1, Int(Double(samples.count) / hop) + 1)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return AudioAnalysis(duration: duration, bpm: nil, beats: [], downbeats: [], onsets: [], bands: [:])
        }
        defer { vDSP_destroy_fftsetup(fft) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        let binHz = sr / Double(n)
        let bassEnd = max(2, Int(150 / binHz)), midEnd = max(bassEnd + 1, Int(2000 / binHz))
        let trebleEnd = min(half, max(midEnd + 1, Int(10_000 / binHz)))

        // Onsets are measured on ~log-spaced bands (like a mel scale), so a kick drum's few low bins count as much as
        // a hi-hat's hundreds of high ones; otherwise beat tracking locks onto off-beat hats.
        var edges: [Int] = []
        let bandCount = 40
        for b in 0...bandCount {
            let hz = 30 * pow(11_000 / 30, Double(b) / Double(bandCount))
            let k = min(trebleEnd, max(1, Int((hz / binHz).rounded())))
            if edges.last.map({ k > $0 }) ?? true { edges.append(k) }
        }
        var level = [Float](repeating: 0, count: frames), bass = level, mid = level, treble = level, flux = level
        var frame = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var logMag = [Float](repeating: 0, count: edges.count), prevLog = logMag
        let specBands = edges.count - 1
        var spectrum = [Float](repeating: 0, count: frames * specBands)
        let norm = Float(n) // vDSP's forward FFT is 2× the DFT; a full-scale sine under a Hann window ≈ n/4 × 2 = n/2

        for f in 0..<frames {
            let start = Int(Double(f) * hop) - half
            for k in 0..<n {
                let i = start + k
                frame[k] = (i >= 0 && i < samples.count) ? samples[i] * window[k] : 0
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                }
            }
            power[0] = 0 // DC (and the packed Nyquist bin)
            var b: Float = 0, m: Float = 0, tr: Float = 0, sum: Float = 0, fl: Float = 0
            for k in 1..<trebleEnd {
                let p = power[k]
                sum += p
                if k < bassEnd { b += p } else if k < midEnd { m += p } else { tr += p }
            }
            for j in 0..<(edges.count - 1) {
                var p: Float = 0
                for k in edges[j]..<edges[j + 1] { p += power[k] }
                logMag[j] = log(1 + 100 * sqrt(p) / norm)
                fl += max(0, logMag[j] - prevLog[j])
                spectrum[f * specBands + j] = logMag[j]
            }
            swap(&logMag, &prevLog)
            level[f] = sqrt(sum) / norm
            bass[f] = sqrt(b) / norm
            mid[f] = sqrt(m) / norm
            treble[f] = sqrt(tr) / norm
            flux[f] = f == 0 ? 0 : fl
        }

        let bands: [AudioBand: [Float]] = [.level: normalized(level), .bass: normalized(bass),
                                           .mid: normalized(mid), .treble: normalized(treble)]
        // Each spectrum band against its own loud parts.
        for j in 0..<specBands {
            let column = normalized((0..<frames).map { spectrum[$0 * specBands + j] })
            for f in 0..<frames { spectrum[f * specBands + j] = column[f] }
        }
        func finish(_ a: AudioAnalysis) -> AudioAnalysis {
            var a = a
            a.spectrum = spectrum
            a.spectrumBands = specBands
            return a
        }
        let onsetEnv = onsetStrength(flux)
        let onsets = pickOnsets(onsetEnv)
        guard let period = tempo(onsetEnv) else {
            return finish(AudioAnalysis(duration: duration, bpm: nil, beats: [], downbeats: [], onsets: onsets, bands: bands))
        }
        var beatFrames = trackBeats(onsetEnv, period: period)
        // Drop beats in silence at the start and end.
        let loud = bands[.level]!
        func audible(_ f: Int) -> Bool {
            let a = max(0, f - 10), b = min(loud.count, f + 10)
            return b > a && loud[a..<b].max()! > 0.05
        }
        while let first = beatFrames.first, !audible(first) { beatFrames.removeFirst() }
        while let last = beatFrames.last, !audible(last) { beatFrames.removeLast() }
        let beats = beatFrames.map { Double($0) / frameRate + onsetLatency }

        // Tempo from the beats themselves (least squares slope of time against beat number).
        var bpm = 60 * frameRate / period
        if beats.count >= 4 {
            let k = Double(beats.count)
            let mx = (k - 1) / 2, my = beats.reduce(0, +) / k
            var num = 0.0, den = 0.0
            for (i, t) in beats.enumerated() { num += (Double(i) - mx) * (t - my); den += (Double(i) - mx) * (Double(i) - mx) }
            if num > 0 { bpm = 60 / (num / den) }
        }

        // Downbeats: the phase (of 4) whose beats carry the most bass and onset energy.
        var downbeats: [Double] = []
        if beatFrames.count >= 8, let low = bands[.bass] {
            var best = 0, bestScore = -Float.infinity
            for phase in 0..<4 {
                var s: Float = 0
                for (i, f) in beatFrames.enumerated() where i % 4 == phase && f < low.count {
                    s += low[f] + 0.5 * onsetEnv[f]
                }
                if s > bestScore { bestScore = s; best = phase }
            }
            downbeats = beats.enumerated().filter { $0.offset % 4 == best }.map(\.element)
        }
        return finish(AudioAnalysis(duration: duration, bpm: (bpm * 10).rounded() / 10, beats: beats,
                                    downbeats: downbeats, onsets: onsets, bands: bands))
    }

    /// Scales so the loud parts (98th percentile) are 1.
    static func normalized(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        let sorted = v.sorted()
        let ref = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.98))]
        guard ref > 1e-5 else { return [Float](repeating: 0, count: v.count) }
        return v.map { min($0 / ref, 1) }
    }

    /// Spectral flux minus its 1 s running mean, in standard deviations (≥ 0). The deviation has a floor so the tiny
    /// fluctuations of a steady sound (pads, drones) are not blown up into hits: music with drums measures ≈ 2+.
    static func onsetStrength(_ flux: [Float]) -> [Float] {
        let n = flux.count, r = Int(frameRate / 2)
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(flux[i]) }
        var o = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - r), b = min(n, i + r + 1)
            o[i] = max(0, flux[i] - Float((prefix[b] - prefix[a]) / Double(b - a)))
        }
        let mean = o.reduce(0, +) / Float(max(n, 1))
        let sd = sqrt(o.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(n, 1)))
        let scale = max(sd, 0.5)
        return o.map { $0 / scale }
    }

    /// Local peaks of the onset strength that stand out from their neighborhood, at least 80 ms apart.
    static func pickOnsets(_ o: [Float]) -> [Onset] {
        let n = o.count
        guard n > 8 else { return [] }
        let sorted = o.sorted()
        let top = max(sorted[min(n - 1, Int(Double(n) * 0.99))], 1e-6)
        var out: [Onset] = []
        var last = -100
        for i in 0..<n where o[i] > 1 {
            let a = max(0, i - 3), b = min(n, i + 4)
            guard o[i] >= o[a..<b].max()!, i - last >= 8 else { continue }
            let ma = max(0, i - 10)
            let localMean = o[ma..<b].reduce(0, +) / Float(b - ma)
            guard o[i] >= localMean + 0.5 else { continue }
            out.append(Onset(t: Double(i) / frameRate + onsetLatency, strength: Double(min(o[i] / top, 1))))
            last = i
        }
        return out
    }

    /// Beat period in frames (60–200 BPM, favoring ~120), from the autocorrelation of the onset strength.
    static func tempo(_ o: [Float]) -> Double? {
        let n = o.count
        let minLag = Int(frameRate * 60 / 200), maxLag = Int(frameRate * 60 / 60)
        guard n > maxLag * 4 else { return nil }
        // No rhythm without regular hits: most of the loudest 1% of frames must be clear onsets.
        guard o.sorted()[n * 99 / 100] >= 1.5 else { return nil }
        let mean = o.reduce(0, +) / Float(n)
        let c = o.map { $0 - mean }
        var ac = [Double](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) {
            var s: Float = 0
            vDSP_dotpr(c, 1, Array(c[lag...]), 1, &s, vDSP_Length(n - lag))
            ac[lag] = Double(s) / Double(n - lag)
        }
        var best = -1, bestScore = 0.0
        for lag in minLag...maxLag where ac[lag] > 0 && ac[lag] >= ac[lag - 1] && ac[lag] >= ac[lag + 1] {
            let bpm = 60 * frameRate / Double(lag)
            let weight = exp(-0.5 * pow(log2(bpm / 120), 2))
            if ac[lag] * weight > bestScore { bestScore = ac[lag] * weight; best = lag }
        }
        guard best > 0 else { return nil }
        // A beat needs a clear periodicity: the peak must stand out from the average correlation.
        let avg = ac[minLag...maxLag].map { max($0, 0) }.reduce(0, +) / Double(maxLag - minLag + 1)
        guard ac[best] > avg * 1.3 else { return nil }
        // Parabolic interpolation around the peak for sub-frame precision.
        let y0 = ac[best - 1], y1 = ac[best], y2 = ac[best + 1]
        let d = (y0 - 2 * y1 + y2)
        let shift = abs(d) > 1e-12 ? 0.5 * (y0 - y2) / d : 0
        return Double(best) + max(-0.5, min(0.5, shift))
    }

    /// Dynamic-programming beat tracker (Ellis 2007): beats on strong onsets, spaced close to `period` frames.
    static func trackBeats(_ o: [Float], period: Double) -> [Int] {
        let n = o.count
        guard n > 0 else { return [] }
        // Lightly smoothed onset strength as the local score.
        let sigma = max(1, period / 32)
        let radius = Int(ceil(3 * sigma))
        let kernel = (-radius...radius).map { Float(exp(-0.5 * pow(Double($0) / sigma, 2))) }
        var local = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = 0
            for (j, w) in kernel.enumerated() {
                let k = i + j - radius
                if k >= 0 && k < n { s += o[k] * w }
            }
            local[i] = s
        }
        let tightness = 100.0
        let lo = Int((period / 2).rounded()), hi = Int((period * 2).rounded())
        // Transition cost per distance, precomputed.
        var cost = [Double](repeating: 0, count: hi + 1)
        for d in max(lo, 1)...hi { cost[d] = tightness * pow(log(Double(d) / period), 2) }
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        for i in 0..<n {
            var best = -Double.infinity, arg = -1
            let from = max(0, i - hi), to = i - max(lo, 1)
            if to >= from {
                for j in from...to {
                    let s = score[j] - cost[i - j]
                    if s > best { best = s; arg = j }
                }
            }
            if arg >= 0 && best > 0 {
                score[i] = Double(local[i]) + best
                back[i] = arg
            } else {
                score[i] = Double(local[i])
            }
        }
        // End on the best-scoring frame within the last two periods, then follow the chain back.
        let tail = max(0, n - hi)
        var i = (tail..<n).max { score[$0] < score[$1] } ?? (n - 1)
        var beats: [Int] = []
        while i >= 0 {
            beats.append(i)
            i = back[i]
        }
        return beats.reversed()
    }

    /// The file as mono samples, downsampled by averaging to about 22–24 kHz (plenty for rhythm and bands).
    static func readMono(_ path: String) throws -> ([Float], Double) {
        let url = AssetStore.expand(path)
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioError.cannotRead(url.path) }
        let fmt = file.processingFormat
        let channels = Int(fmt.channelCount)
        let factor = fmt.sampleRate >= 88_200 ? 4 : fmt.sampleRate >= 44_100 ? 2 : 1
        let chunk: AVAudioFrameCount = 65_536
        guard channels > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else {
            throw AudioError.cannotRead(url.path)
        }
        var out: [Float] = []
        out.reserveCapacity(Int(file.length) / factor + 1)
        var acc: Float = 0
        var inAcc = 0
        let scale = 1 / Float(channels * factor)
        while file.framePosition < file.length {
            // read(into:) throws on files it cannot decode (rather than crashing like a seek would).
            do { try file.read(into: buf, frameCount: chunk) } catch { throw AudioError.cannotRead(url.path) }
            let count = Int(buf.frameLength)
            if count == 0 { break }
            guard let data = buf.floatChannelData else { throw AudioError.cannotRead(url.path) }
            for i in 0..<count {
                for c in 0..<channels { acc += data[c][i] }
                inAcc += 1
                if inAcc == factor { out.append(acc * scale); acc = 0; inAcc = 0 }
            }
        }
        return (out, fmt.sampleRate / Double(factor))
    }
}

// MARK: - Cache

/// Analyses and envelopes per file, shared by the renderer (any thread), tools and the UI.
/// Files that cannot be decoded are remembered as failures so they are not retried every frame.
public enum AudioAnalysisCache {
    /// Analyses run outside the lock (decoding a song takes seconds), so lookups of other files never wait on them.
    private static let cond = NSCondition()
    nonisolated(unsafe) private static var results: [String: Result<AudioAnalysis, Error>] = [:]
    nonisolated(unsafe) private static var envelopes: [String: [Float]] = [:]
    nonisolated(unsafe) private static var inFlight = Set<String>()
    nonisolated(unsafe) private static var generation = 0
    private static let noWaitKey = "VeyMotion.AudioAnalysisCache.noWait"

    /// Posted on the main thread whenever an analysis finishes.
    public static let didAnalyze = Notification.Name("VeyMotion.AudioAnalysisCache.didAnalyze")

    /// Analyzes the file on first use (blocking) and caches the result.
    public static func analysis(path: String) throws -> AudioAnalysis {
        // Non-nil when waiting.
        try result(path, wait: true)!.get()
    }

    /// The cached analysis if it is ready (never blocks on decoding).
    public static func cached(path: String) -> AudioAnalysis? {
        cond.lock(); defer { cond.unlock() }
        return try? results[path]?.get()
    }

    /// Off in the app, so inspector/canvas reads never freeze the UI. The CLI renders on its main thread and must wait.
    nonisolated(unsafe) public static var waitsOnMainThread = true

    /// Runs `body` (e.g. a preview frame) without waiting for analyses: audio-reactive values read as 0 until
    /// their file is analyzed in the background, then `didAnalyze` is posted.
    public static func withoutWaiting<T>(_ body: () throws -> T) rethrows -> T {
        let d = Thread.current.threadDictionary
        let old = d[noWaitKey]
        d[noWaitKey] = true
        defer { d[noWaitKey] = old }
        return try body()
    }

    /// The analysis for drawing a frame: waits like `envelope` does (not on the app's main thread or inside
    /// `withoutWaiting`). nil when it cannot be analyzed or is not ready yet.
    public static func forRendering(path: String) -> AudioAnalysis? {
        let wait = (waitsOnMainThread || !Thread.isMainThread) && Thread.current.threadDictionary[noWaitKey] == nil
        return try? result(path, wait: wait)?.get()
    }

    /// Smoothed envelope of a band (see `AudioAnalysis.envelope`); nil if the file cannot be analyzed (or, when
    /// not waiting, is not analyzed yet).
    public static func envelope(path: String, band: AudioBand, release: Double) -> [Float]? {
        let key = "\(path)|\(band.rawValue)|\((release * 1000).rounded())"
        cond.lock()
        let e = envelopes[key]
        cond.unlock()
        if let e { return e }
        let wait = (waitsOnMainThread || !Thread.isMainThread) && Thread.current.threadDictionary[noWaitKey] == nil
        guard let a = try? result(path, wait: wait)?.get() else { return nil }
        let env = a.envelope(band, release: release)
        cond.lock()
        envelopes[key] = env
        cond.unlock()
        return env
    }

    /// Forgets a file (e.g. after it was overwritten), or everything.
    public static func invalidate(path: String? = nil) {
        cond.lock(); defer { cond.unlock() }
        generation += 1
        if let path {
            results[path] = nil
            envelopes = envelopes.filter { !$0.key.hasPrefix(path + "|") }
        } else {
            results = [:]
            envelopes = [:]
        }
    }

    /// The file's analysis; nil only when not waiting and it is not ready (it is then started in the background).
    private static func result(_ path: String, wait: Bool) -> Result<AudioAnalysis, Error>? {
        cond.lock(); defer { cond.unlock() }
        while true {
            if let r = results[path] { return r }
            guard inFlight.contains(path) else { break }
            guard wait else { return nil }
            cond.wait()
        }
        inFlight.insert(path)
        let gen = generation
        guard wait else {
            DispatchQueue.global(qos: .userInitiated).async {
                let r = Result { try AudioAnalysis.analyze(path: path) }
                cond.lock()
                finish(path, r, generation: gen)
                cond.unlock()
            }
            return nil
        }
        cond.unlock()
        let r = Result { try AudioAnalysis.analyze(path: path) }
        cond.lock()
        finish(path, r, generation: gen)
        return r
    }

    /// Call with `cond` locked. A result that started before an `invalidate` is not kept.
    private static func finish(_ path: String, _ r: Result<AudioAnalysis, Error>, generation gen: Int) {
        inFlight.remove(path)
        if gen == generation { results[path] = r }
        cond.broadcast()
        DispatchQueue.main.async { NotificationCenter.default.post(name: didAnalyze, object: path) }
    }
}

extension AudioAnalysis {
    /// `count` spectrum values (0…1, low to high) at file time `t`: each band falls back over `release` seconds
    /// after a peak, so bars rise fast and drop smoothly.
    public func spectrum(at t: Double, count: Int, release: Double = 0.12) -> [Double] {
        let nb = spectrumBands
        guard nb > 0, count > 0 else { return [Double](repeating: 0, count: max(count, 0)) }
        let frames = spectrum.count / nb
        let f = Int((t * Self.frameRate).rounded(.down))
        let back = max(1, Int(release * Self.frameRate * 3))
        var bands = [Double](repeating: 0, count: nb)
        if f >= 0 && f < frames + back {
            for k in 0..<back {
                let i = f - k
                guard i >= 0, i < frames else { continue }
                let decay = exp(-Double(k) / (release * Self.frameRate))
                for j in 0..<nb { bands[j] = max(bands[j], Double(spectrum[i * nb + j]) * decay) }
            }
        }
        // Resample to `count` values across the bands.
        return (0..<count).map { c in
            let x = count == 1 ? 0 : Double(c) / Double(count - 1) * Double(nb - 1)
            let i = min(Int(x), nb - 2), fr = x - Double(i)
            return nb == 1 ? bands[0] : bands[i] + (bands[i + 1] - bands[i]) * fr
        }
    }

    /// Linear interpolation into an envelope at file time `t`.
    static func sample(_ env: [Float], at t: Double) -> Double {
        let x = t * frameRate
        guard x >= 0, !env.isEmpty else { return 0 }
        let i = Int(x)
        guard i + 1 < env.count else { return i < env.count ? Double(env[i]) : 0 }
        let f = Float(x - Double(i))
        return Double(env[i] + (env[i + 1] - env[i]) * f)
    }
}
