import Foundation

// Music-driven editing: put presets, pulses, cuts and flashes on the beats of an audio layer in one step.

public enum BeatAction: String, CaseIterable, Codable, Sendable {
    /// Apply a preset at each beat, cycling through the layers (beat 1 → first layer, beat 2 → second…).
    case preset
    /// Kick a property (scale, brightness, glow, y…) up by `amount` at each beat and let it fall back.
    case pulse
    /// Show the layers one after another, each for one interval between beats (a slideshow cut to the music).
    case cut
    /// A white flash over the whole frame on each beat.
    case flash
}

public enum BeatGrid: String, CaseIterable, Codable, Sendable {
    /// Every beat; `bar` = first beat of each bar; `half` = every other beat; `onset` = strong hits (drums, accents).
    case beat, bar, half, onset
}

extension MotionScene {
    /// Scene times of the chosen grid of an audio layer (default: the music) between `from` and `to`.
    public func beatTimes(source: String?, grid: BeatGrid, from: Double?, to: Double?, minStrength: Double = 0.4) throws -> [Double] {
        let audio = audioLayers
        guard let src = source.map({ id in audio.first { $0.id == id } }) ?? defaultReactSource else {
            throw SceneError.invalid(source.map { "'\($0)' is not an audio layer with a file" } ?? "The scene has no audio layer")
        }
        guard let path = src.path else { throw SceneError.invalid("'\(src.id)' has no file") }
        let a = try AudioAnalysisCache.analysis(path: path)
        let end = src.effectiveEnd(sceneDuration: duration)
        func scene(_ ft: Double) -> Double { src.start + ft - src.trimIn }
        var times: [Double]
        switch grid {
        case .beat: times = a.beats.map(scene)
        case .half: times = a.beats.enumerated().filter { $0.offset % 2 == 0 }.map { scene($0.element) }
        case .bar: times = a.downbeats.map(scene)
        case .onset: times = a.onsets.filter { $0.strength >= minStrength }.map { scene($0.t) }
        }
        let lo = max(from ?? src.start, src.start), hi = min(to ?? end, end)
        times = times.filter { $0 >= lo - 1e-6 && $0 <= hi + 1e-6 }
        guard !times.isEmpty else {
            throw SceneError.invalid("No \(grid.rawValue)s found between \(lo)s and \(hi)s (is the music analyzed and rhythmic?)")
        }
        return times
    }

    /// Edits layers to the beats. Returns how many beats were used.
    @discardableResult
    public mutating func syncToBeats(_ ids: [String], action: BeatAction, times: [Double], preset: Preset?,
                                     property: AnimProperty?, amount: Double, release: Double, duration: Double?) throws -> Int {
        guard !times.isEmpty else { return 0 }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        let typical = gaps.isEmpty ? 0.5 : gaps.sorted()[gaps.count / 2]
        switch action {
        case .preset:
            guard let preset else { throw SceneError.invalid("Give `preset` for action preset") }
            guard !ids.isEmpty else { throw SceneError.invalid("Give the layer ids") }
            let d = duration ?? min(0.6, typical * 0.85)
            for (k, t) in times.enumerated() {
                try applyPreset(preset, to: ids[k % ids.count], start: t, duration: d)
            }
        case .pulse:
            guard let p = property else { throw SceneError.invalid("Give `property` for action pulse (e.g. scale, brightness, glow)") }
            guard !ids.isEmpty else { throw SceneError.invalid("Give the layer ids") }
            let rel = min(release, typical * 0.95)
            for id in ids {
                try withLayer(id) { l in
                    let base = l[p]
                    var kfs: [MotionKeyframe] = []
                    for t in times {
                        let b = base.value(at: t)
                        // Instant attack, eased fall back before the next beat.
                        kfs.append(MotionKeyframe(t: t - 0.001, v: b, easing: .linear))
                        kfs.append(MotionKeyframe(t: t + 0.03, v: b + amount, easing: .easeOut))
                        kfs.append(MotionKeyframe(t: t + rel, v: b, easing: .curve(.cubic, .out)))
                    }
                    var track = base
                    for i in stride(from: 0, to: kfs.count, by: 3) {
                        track = track.inserting(Array(kfs[i..<i + 3]), replacing: kfs[i].t, kfs[i + 2].t)
                    }
                    l[p] = track
                }
            }
        case .cut:
            guard !ids.isEmpty else { throw SceneError.invalid("Give the layer ids to cut between") }
            // Interval k runs from beat k to beat k+1 (the last one to the end of the music).
            for (k, id) in ids.enumerated() where k < times.count {
                let s = times[k], e = k + 1 < times.count ? times[k + 1] : nil
                try withLayer(id) { l in
                    let shift = s - l.start
                    if abs(shift) > 1e-6 { l.shiftKeys(by: shift) }
                    l.start = s
                    l.end = e
                }
            }
        case .flash:
            for (k, t) in times.enumerated() {
                var f = MotionLayer(id: "flash", name: "Beat Flash \(k + 1)", type: .rect, x: Double(width) / 2, y: Double(height) / 2)
                f.width = .constant(Double(width)); f.height = .constant(Double(height))
                f.fill = .constant(.white)
                f.blendMode = .add
                f.start = t; f.end = t + min(release, typical * 0.9)
                f.opacity = .keyframes([MotionKeyframe(t: t, v: min(max(amount, 0), 1), easing: .linear),
                                        MotionKeyframe(t: f.end!, v: 0, easing: .curve(.quad, .out))])
                addLayer(f)
            }
        }
        return action == .cut ? min(ids.count, times.count) : times.count
    }
}
