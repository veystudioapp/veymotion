import CoreGraphics
import Foundation

// Cut-out rigs: a scene keeps a list of bones (a chain of joints, each with a length and an angle relative to its
// parent), layers can be attached to a bone (`MotionLayer.bone`: their x/y/rotation are then in the bone's space),
// and `solveIK` turns a chain so its tip reaches a point (CCD, with angle limits). Bones have no visual of their
// own; the parts of an imported SVG are the usual thing to hang on them.
// Frame-by-frame drawings: a `drawing` layer holds a list of frames, each a list of strokes (path data in layer px)
// held for a number of frames at the drawing's own fps, so hand-drawn animation ("on 2s") lives next to keyframes.

// MARK: - Bones

public struct Bone: Codable, Equatable, Sendable {
    public var id: String
    /// Parent bone id; nil = a root bone placed at x/y.
    public var parent: String?
    /// Root bones only: where the bone starts (scene px). Child bones start at their parent's tip.
    public var x: AnimValue
    public var y: AnimValue
    public var length: Double
    /// Degrees. Root: absolute (0 = pointing right, 90 = down). Child: relative to the parent's direction.
    public var angle: AnimValue
    /// Limits for IK (degrees, same frame as `angle`); nil = free.
    public var minAngle: Double?
    public var maxAngle: Double?

    public init(id: String, parent: String? = nil, x: Double = 0, y: Double = 0, length: Double, angle: Double = 0,
                minAngle: Double? = nil, maxAngle: Double? = nil) {
        self.id = id; self.parent = parent; self.x = .constant(x); self.y = .constant(y); self.length = length
        self.angle = .constant(angle); self.minAngle = minAngle; self.maxAngle = maxAngle
    }

    enum CodingKeys: String, CodingKey { case id, parent, x, y, length, angle, minAngle, maxAngle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parent = try c.decodeIfPresent(String.self, forKey: .parent).flatMap { $0.isEmpty ? nil : $0 }
        x = try c.decodeIfPresent(AnimValue.self, forKey: .x) ?? .constant(0)
        y = try c.decodeIfPresent(AnimValue.self, forKey: .y) ?? .constant(0)
        length = max(0, try c.decodeIfPresent(Double.self, forKey: .length) ?? 100)
        angle = try c.decodeIfPresent(AnimValue.self, forKey: .angle) ?? .constant(0)
        minAngle = try c.decodeIfPresent(Double.self, forKey: .minAngle)
        maxAngle = try c.decodeIfPresent(Double.self, forKey: .maxAngle)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(parent, forKey: .parent)
        if parent == nil { try c.encode(x, forKey: .x); try c.encode(y, forKey: .y) }
        try c.encode(length, forKey: .length)
        try c.encode(angle, forKey: .angle)
        try c.encodeIfPresent(minAngle, forKey: .minAngle)
        try c.encodeIfPresent(maxAngle, forKey: .maxAngle)
    }

    func clamped(_ a: Double) -> Double {
        var v = a
        if let lo = minAngle { v = max(v, lo) }
        if let hi = maxAngle { v = min(v, hi) }
        return v
    }
}

extension MotionScene {
    public func bone(_ id: String) -> Bone? { bones.first { $0.id == id } }

    /// Bone-local space (origin at the bone's start, x along the bone) → scene px (before the camera).
    /// `overrides` replaces angles while solving.
    public func boneTransform(_ id: String, at t: Double, overrides: [String: Double] = [:]) -> CGAffineTransform? {
        var chain: [Bone] = []
        var seen = Set<String>()
        var cur: String? = id
        while let c = cur, !seen.contains(c), let b = bone(c) {
            chain.append(b)
            seen.insert(c)
            cur = b.parent
        }
        guard !chain.isEmpty else { return nil }
        var m = CGAffineTransform.identity
        for (i, b) in chain.reversed().enumerated() {
            let deg = overrides[b.id] ?? b.angle.value(at: t)
            if i == 0 {
                m = CGAffineTransform(translationX: b.x.value(at: t), y: b.y.value(at: t))
                    .rotated(by: deg * .pi / 180)
            } else {
                let parentLength = chain.reversed()[i - 1].length
                m = m.translatedBy(x: parentLength, y: 0).rotated(by: deg * .pi / 180)
            }
        }
        return m
    }

    public func boneStart(_ id: String, at t: Double, overrides: [String: Double] = [:]) -> CGPoint? {
        boneTransform(id, at: t, overrides: overrides).map { CGPoint.zero.applying($0) }
    }

    public func boneTip(_ id: String, at t: Double, overrides: [String: Double] = [:]) -> CGPoint? {
        guard let b = bone(id), let m = boneTransform(id, at: t, overrides: overrides) else { return nil }
        return CGPoint(x: b.length, y: 0).applying(m)
    }

    /// Adds or replaces bones (by id). `replace` drops the ones not listed.
    public mutating func setBones(_ list: [Bone], replace: Bool) throws {
        var merged = replace ? [] : bones
        for b in list {
            guard !b.id.isEmpty else { throw SceneError.invalid("A bone needs an id") }
            if let i = merged.firstIndex(where: { $0.id == b.id }) { merged[i] = b } else { merged.append(b) }
        }
        for b in merged {
            if let p = b.parent, !merged.contains(where: { $0.id == p }) { throw SceneError.invalid("Bone '\(b.id)': parent '\(p)' not found") }
        }
        bones = merged
        // Attached layers must still have their bone.
        let ids = Set(merged.map(\.id))
        for i in layers.indices where layers[i].bone.map({ !ids.contains($0) }) ?? false { layers[i].bone = nil }
    }

    /// Hangs a layer on a bone without moving it at time t: its x/y/rotation become bone-relative. nil detaches it
    /// (keeping its place too).
    public mutating func bind(_ id: String, toBone boneId: String?, at t: Double) throws {
        let l = try layer(id)
        if let b = boneId { guard bone(b) != nil else { throw SceneError.invalid("Bone '\(b)' not found") } }
        let before = parentTransform(of: l, at: t)
        var linked = l
        linked.bone = boneId
        if boneId != nil { linked.parent = nil }
        let after = parentTransform(of: linked, at: t)
        let world = l.position(at: t).point.applying(before)
        let local = world.applying(after.inverted())
        let dx = local.x - l.position(at: t).point.x, dy = local.y - l.position(at: t).point.y
        // Rotation: the angle the two spaces differ by.
        let angleBefore = atan2(before.b, before.a), angleAfter = atan2(after.b, after.a)
        let dr = (angleBefore - angleAfter) * 180 / .pi
        try withLayer(id) { l in
            l.bone = boneId
            if boneId != nil { l.parent = nil }
            if var mp = l.motionPath {
                mp.points = mp.points.map { PathPoint(x: $0.x + dx, y: $0.y + dy) }
                l.motionPath = mp
            } else {
                l.x = l.x.offset(by: dx)
                l.y = l.y.offset(by: dy)
            }
            if abs(dr) > 1e-6 { l.rotation = l.rotation.offset(by: dr) }
        }
    }

    /// Sets bone angles (degrees). With a time, each becomes a keyframe there (and the previous pose is kept
    /// `hold` seconds before it when the bone had no keyframes yet); without one, a constant.
    public mutating func poseBones(_ angles: [String: Double], at t: Double?, hold: Double = 0.4) throws {
        for (id, deg) in angles {
            guard let i = bones.firstIndex(where: { $0.id == id }) else { throw SceneError.invalid("Bone '\(id)' not found") }
            bones[i].angle = Self.keyed(bones[i].angle, value: deg, at: t, hold: hold)
        }
    }

    static func keyed(_ track: AnimValue, value: Double, at t: Double?, hold: Double) -> AnimValue {
        guard let t else { return .constant(value) }
        switch track {
        case let .constant(c):
            var keys = [MotionKeyframe(t: t, v: value, easing: .easeInOut)]
            if t - hold > 0 { keys.insert(MotionKeyframe(t: t - hold, v: c, easing: .linear), at: 0) }
            return .keyframes(keys)
        case .keyframes:
            return track.setting(value, at: t)
        }
    }

    /// Turns the chain ending at `boneId` (`chain` bones, the bone and its parents) so the bone's tip reaches
    /// (x, y) in scene px, within the bones' limits. Returns the angles it chose (degrees).
    @discardableResult
    public mutating func solveIK(_ boneId: String, target: CGPoint, chain: Int = 2, at t: Double?, hold: Double = 0.4) throws -> [String: Double] {
        guard bone(boneId) != nil else { throw SceneError.invalid("Bone '\(boneId)' not found") }
        let time = t ?? 0
        var ids: [String] = []
        var cur: String? = boneId
        while let c = cur, ids.count < max(1, chain), let b = bone(c) { ids.append(c); cur = b.parent }
        var angles: [String: Double] = [:]
        for id in ids { angles[id] = bone(id)!.angle.value(at: time) }
        func norm(_ a: Double) -> Double { var v = a; while v > .pi { v -= 2 * .pi }; while v < -.pi { v += 2 * .pi }; return v }
        for _ in 0..<32 {
            for id in ids {
                guard let b = bone(id), let joint = boneStart(id, at: time, overrides: angles),
                      let tip = boneTip(boneId, at: time, overrides: angles) else { continue }
                let a1 = atan2(tip.y - joint.y, tip.x - joint.x), a2 = atan2(target.y - joint.y, target.x - joint.x)
                let delta = norm(a2 - a1) * 180 / .pi
                angles[id] = b.clamped(angles[id]! + delta)
            }
            if let tip = boneTip(boneId, at: time, overrides: angles), hypot(tip.x - target.x, tip.y - target.y) < 0.5 { break }
        }
        try poseBones(angles, at: t, hold: hold)
        return angles
    }
}

// MARK: - Frame-by-frame drawing

public struct DrawingStroke: Codable, Equatable, Hashable, Sendable {
    /// Path data in layer px around the layer's x/y (same syntax as a path layer's d).
    public var d: String
    public var stroke: RGBA?
    public var strokeWidth: Double
    public var fill: RGBA?

    public init(d: String, stroke: RGBA? = .black, strokeWidth: Double = 6, fill: RGBA? = nil) {
        self.d = d; self.stroke = stroke; self.strokeWidth = strokeWidth; self.fill = fill
    }

    enum CodingKeys: String, CodingKey { case d, stroke, strokeWidth, fill }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        d = try c.decode(String.self, forKey: .d)
        stroke = try c.decodeIfPresent(RGBA.self, forKey: .stroke) ?? (c.contains(.stroke) ? nil : .black)
        strokeWidth = max(0, try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 6)
        fill = try c.decodeIfPresent(RGBA.self, forKey: .fill)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(d, forKey: .d)
        try c.encodeIfPresent(stroke, forKey: .stroke)
        if strokeWidth != 6 { try c.encode(strokeWidth, forKey: .strokeWidth) }
        try c.encodeIfPresent(fill, forKey: .fill)
    }
}

public struct DrawingFrame: Codable, Equatable, Hashable, Sendable {
    /// How many drawing frames (at the drawing's fps) this picture is held: 2 = "on 2s".
    public var hold: Int
    public var strokes: [DrawingStroke]

    public init(hold: Int = 1, strokes: [DrawingStroke]) { self.hold = max(1, hold); self.strokes = strokes }

    enum CodingKeys: String, CodingKey { case hold, strokes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hold = max(1, try c.decodeIfPresent(Int.self, forKey: .hold) ?? 1)
        strokes = try c.decodeIfPresent([DrawingStroke].self, forKey: .strokes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if hold != 1 { try c.encode(hold, forKey: .hold) }
        try c.encode(strokes, forKey: .strokes)
    }
}

public struct Drawing: Codable, Equatable, Hashable, Sendable {
    /// Drawing frames per second (12 = classic animation; holds multiply).
    public var fps: Double
    public var frames: [DrawingFrame]
    /// Start over after the last frame (else hold it).
    public var loop: Bool

    public init(fps: Double = 12, frames: [DrawingFrame] = [], loop: Bool = true) {
        self.fps = max(0.1, fps); self.frames = frames; self.loop = loop
    }

    enum CodingKeys: String, CodingKey { case fps, frames, loop }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fps = max(0.1, try c.decodeIfPresent(Double.self, forKey: .fps) ?? 12)
        frames = try c.decodeIfPresent([DrawingFrame].self, forKey: .frames) ?? []
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if fps != 12 { try c.encode(fps, forKey: .fps) }
        try c.encode(frames, forKey: .frames)
        if !loop { try c.encode(loop, forKey: .loop) }
    }

    /// Total length in drawing frames (holds included).
    public var tickCount: Int { frames.reduce(0) { $0 + $1.hold } }
    /// Seconds one pass takes.
    public var cycle: Double { Double(tickCount) / fps }

    /// Which frame shows `local` seconds after the layer starts.
    public func frameIndex(at local: Double) -> Int? {
        let ticks = tickCount
        guard ticks > 0 else { return nil }
        var tick = Int(floor(max(0, local) * fps + 1e-6))
        if loop { tick %= ticks } else { tick = min(tick, ticks - 1) }
        var acc = 0
        for (i, f) in frames.enumerated() {
            acc += f.hold
            if tick < acc { return i }
        }
        return frames.count - 1
    }
}

extension MotionScene {
    /// Sets (index given) or appends a frame of a drawing layer.
    public mutating func setDrawingFrame(_ id: String, index: Int?, frame: DrawingFrame) throws {
        try withLayer(id) { l in
            guard l.type == .drawing else { throw SceneError.invalid("'\(id)' is not a drawing layer") }
            if let i = index, i >= 0, i < l.drawing.frames.count { l.drawing.frames[i] = frame }
            else if let i = index { l.drawing.frames.insert(frame, at: min(max(i, 0), l.drawing.frames.count)) }
            else { l.drawing.frames.append(frame) }
        }
    }
}
