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

    /// Sets the Bezier handles around the number keyframe at `t` (graph editor): `incoming` is (x2, y2) of the
    /// segment arriving at it, `outgoing` is (x1, y1) of the segment leaving it, in that segment's 0…1 space.
    /// A segment whose easing has no Bezier form starts from linear. nil leaves a side unchanged.
    public mutating func setKeyHandles(_ id: String, property p: AnimProperty, at t: Double,
                                       incoming: (x: Double, y: Double)?, outgoing: (x: Double, y: Double)?) throws {
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        func controls(_ e: Easing) -> (Double, Double, Double, Double) {
            e.bezierControls ?? Easing.linear.bezierControls!
        }
        try withLayer(id) { l in
            var kfs = l[p].keyframeList
            guard let k = kfs.firstIndex(where: { abs($0.t - t) < Self.keyTimeTolerance }) else {
                throw SceneError.invalid("'\(id)' has no \(p.rawValue) keyframe at \(t)s")
            }
            if let h = incoming, k > 0 {
                let c = controls(kfs[k].easing)
                kfs[k].easing = .cubicBezier(r(c.0), r(c.1), r(min(max(h.x, 0), 1)), r(h.y))
            }
            if let h = outgoing, k + 1 < kfs.count {
                let c = controls(kfs[k + 1].easing)
                kfs[k + 1].easing = .cubicBezier(r(min(max(h.x, 0), 1)), r(h.y), r(c.2), r(c.3))
            }
            l[p] = .keyframes(kfs)
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

    /// Switches layers off (not drawn, not heard) or back on.
    public mutating func setHidden(_ ids: [String], _ hidden: Bool) throws {
        for id in ids { try withLayer(id) { $0.hidden = hidden } }
    }

    /// Cuts a top-level layer in two at `t`, like a video editor's split: the layer ends at `t` and a copy right above
    /// it starts there. Both keep every keyframe (times are absolute), so the animation runs on across the cut; audio
    /// and video go on in the file (the copy's in-point moves), fades stay on the outer ends, and a localTime group's
    /// copy keeps its children's clock. Returns the copy's id.
    @discardableResult
    public mutating func splitLayer(_ id: String, at t: Double) throws -> String {
        let i = try layerIndex(id)
        let minLen = 1.0 / Double(max(fps, 1))
        var a = layers[i]
        let end = a.effectiveEnd(sceneDuration: duration)
        guard t >= a.start + minLen - 1e-9, t <= end - minLen + 1e-9 else {
            throw SceneError.invalid(String(format: "'%@' runs %.2f–%.2fs: split it at a time inside, at least one frame from its ends",
                                            id, a.start, end))
        }
        var b = a
        b.id = uniqueId(base: id)
        if b.type == .group {
            var seen = Set(allLayers.map(\.id))
            seen.insert(b.id)
            Self.normalizeIds(&b.children, seen: &seen)
        }
        a.end = t
        b.start = t // b.end stays: an open end still ends at the scene end, or where the file runs out
        if a.type == .audio || a.type == .video {
            if a.type == .audio || a.timeRemap == nil {
                let rate = a.type == .video ? max(a.speed, 0.01) : 1
                var inPoint = a.trimIn + (t - a.start) * rate
                if a.type == .video, a.playback == .loop, let total = a.sourceDuration, total - a.trimIn > 1e-6, inPoint >= total {
                    inPoint = a.trimIn + (inPoint - a.trimIn).truncatingRemainder(dividingBy: total - a.trimIn)
                }
                b.trimIn = inPoint
            }
            a.fadeOut = 0
            b.fadeIn = 0
        }
        Self.keepClock(&b, from: a.start)
        layers[i] = a
        layers.insert(b, at: i + 1)
        return b.id
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
