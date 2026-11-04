import Foundation

/// Retiming operations used by the timeline (drag keyframes, move/trim layers, easing).
/// A keyframe is addressed by (layer, property, time); `property == nil` means "every property
/// that has a keyframe at that time" (the summary diamonds on a layer row).
extension MotionScene {
    public static let keyTimeTolerance = 1e-3

    private func tracks(of layer: MotionLayer, _ k: KeyTrack?, at t: Double) -> [KeyTrack] {
        if let k { return [k] }
        return KeyTrack.all.filter { layer.hasKey($0, at: t, tolerance: Self.keyTimeTolerance) }
    }

    /// Moves the keyframe(s) at `t` to `newT`.
    public mutating func moveKeyframes(_ id: String, track: KeyTrack?, from t: Double, to newT: Double) throws {
        let i = try layerIndex(id)
        let target = min(max(newT, 0), duration)
        for k in tracks(of: layers[i], track, at: t) {
            layers[i].moveKey(k, at: t, to: target, tolerance: Self.keyTimeTolerance)
        }
    }

    /// Sets the easing of the segment arriving at the keyframe(s) at `t`.
    public mutating func setEasing(_ id: String, track: KeyTrack?, at t: Double, easing: Easing) throws {
        let i = try layerIndex(id)
        for k in tracks(of: layers[i], track, at: t) {
            layers[i].setEasing(k, at: t, easing, tolerance: Self.keyTimeTolerance)
        }
    }

    /// Deletes the keyframe(s) at `t`. A track left without keyframes becomes constant at that value.
    public mutating func deleteKeyframes(_ id: String, track: KeyTrack?, at t: Double) throws {
        let i = try layerIndex(id)
        for k in tracks(of: layers[i], track, at: t) {
            layers[i].deleteKey(k, at: t, tolerance: Self.keyTimeTolerance)
        }
    }

    /// Shifts layers in time (start, end, every keyframe and text animator) by `dt`, never before 0.
    public mutating func shiftLayers(_ ids: [String], by dt: Double) throws {
        let idx = try ids.map { try layerIndex($0) }
        guard !idx.isEmpty else { return }
        let earliest = idx.map { i -> Double in
            min(layers[i].start, layers[i].earliestKeyTime ?? layers[i].start)
        }.min() ?? 0
        let d = max(dt, -earliest)
        guard d != 0 else { return }
        for i in idx {
            layers[i].start += d
            if let e = layers[i].end { layers[i].end = e + d }
            layers[i].shiftKeys(by: d)
        }
    }

    /// Sets a layer's visible range. Pass nil to leave a side unchanged.
    public mutating func setTiming(_ id: String, start: Double?, end: Double?) throws {
        let i = try layerIndex(id)
        let minLen = 1.0 / Double(max(fps, 1))
        if layers[i].type == .audio || layers[i].type == .video {
            try setMediaTiming(i, start: start, end: end, minLen: minLen)
            return
        }
        var s = max(0, start ?? layers[i].start)
        var e = min(end ?? layers[i].effectiveEnd(sceneDuration: duration), duration)
        if start != nil && end == nil {
            s = max(0, min(s, e - minLen))  // trimming the start stops at the end
        } else {
            e = max(e, s + minLen)          // trimming the end stops at the start
        }
        layers[i].start = s
        layers[i].end = (end == nil && layers[i].end == nil) ? nil : e
    }

    /// Audio and video trim like a video editor: moving the start also moves the in-point inside the file, so the
    /// content stays where it was; the end can't extend past the end of the file (videos that hold or loop can).
    private mutating func setMediaTiming(_ i: Int, start: Double?, end: Double?, minLen: Double) throws {
        var l = layers[i]
        let oldStart = l.start
        let curEnd = l.effectiveEnd(sceneDuration: duration)
        let rate = l.type == .video ? max(l.speed, 0.01) : 1 // source seconds per scene second
        if let start {
            var s = max(0, start, oldStart - l.trimIn / rate) // can't reveal media before the file starts
            s = min(s, curEnd - minLen)
            l.trimIn = max(0, l.trimIn + (s - oldStart) * rate)
            l.start = s
        }
        if let end {
            var e = max(end, l.start + minLen)
            if let len = l.mediaLength { e = min(e, l.start + len) }
            if l.type == .video { e = min(e, duration) }
            l.end = e
        }
        layers[i] = l
    }
}
