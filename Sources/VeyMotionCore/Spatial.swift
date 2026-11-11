import CoreGraphics
import Foundation

/// Spatial interpolation of position (After Effects style): the x/y keys become one 2D path, a cubic Bezier between
/// each pair of key positions, and each segment's easing moves the layer along that curve by distance, so the speed
/// stays even around bends instead of each axis easing on its own.
public struct SpatialPath: Codable, Equatable, Hashable, Sendable {
    /// true = auto-Bezier curve through the key positions; false = straight lines (custom handles still bend them).
    public var smooth: Bool
    /// Rotate the layer to face the direction of travel (added to `rotation`).
    public var orient: Bool
    /// Custom handles for the keys at these times (other keys stay auto).
    public var handles: [SpatialHandle]

    public init(smooth: Bool = true, orient: Bool = false, handles: [SpatialHandle] = []) {
        self.smooth = smooth; self.orient = orient; self.handles = handles
    }

    enum CodingKeys: String, CodingKey { case smooth, orient, handles }

    /// Accepts `true` as shorthand for the defaults.
    public init(from decoder: Decoder) throws {
        if let b = try? decoder.singleValueContainer().decode(Bool.self) {
            smooth = b; orient = false; handles = []
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smooth = try c.decodeIfPresent(Bool.self, forKey: .smooth) ?? true
        orient = try c.decodeIfPresent(Bool.self, forKey: .orient) ?? false
        handles = try c.decodeIfPresent([SpatialHandle].self, forKey: .handles) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(smooth, forKey: .smooth)
        if orient { try c.encode(orient, forKey: .orient) }
        if !handles.isEmpty { try c.encode(handles, forKey: .handles) }
    }

    func handle(at t: Double) -> SpatialHandle? {
        handles.first { abs($0.t - t) < MotionScene.keyTimeTolerance }
    }

    mutating func moveHandle(at t: Double, to newT: Double) {
        guard let i = handles.firstIndex(where: { abs($0.t - t) < MotionScene.keyTimeTolerance }) else { return }
        var h = handles.remove(at: i)
        handles.removeAll { abs($0.t - newT) < MotionScene.keyTimeTolerance }
        h.t = newT
        handles.append(h)
    }
}

/// Tangents of one position key, in scene px relative to the key's position (`in` toward the previous key).
public struct SpatialHandle: Codable, Equatable, Hashable, Sendable {
    public var t: Double
    public var `in`: PathPoint?
    public var out: PathPoint?

    public init(t: Double, in i: PathPoint? = nil, out: PathPoint? = nil) {
        self.t = t; self.in = i; self.out = out
    }
}

extension MotionLayer {
    /// Position from the x/y keys as one spatial path, or nil when the layer doesn't use one.
    func spatialPosition(at t: Double) -> (point: CGPoint, pathAngle: Double)? {
        guard let sp = spatial, x.isAnimated || y.isAnimated,
              links["x"] == nil, links["y"] == nil else { return nil }
        let keys = spatialKeys(sp)
        guard keys.count >= 2, let first = keys.first, let last = keys.last, last.t - first.t > 1e-6 else { return nil }

        var lt = t, shift = CGPoint.zero
        if t > last.t, let mode = loop["x"] ?? loop["y"] {
            let span = last.t - first.t
            let cycles = floor((t - first.t) / span)
            let local = t - first.t - cycles * span
            switch mode {
            case .cycle: lt = first.t + local
            case .pingpong: lt = Int(cycles) % 2 == 1 ? last.t - local : first.t + local
            case .offset:
                lt = first.t + local
                shift = CGPoint(x: (last.p.x - first.p.x) * cycles, y: (last.p.y - first.p.y) * cycles)
            }
        }

        let s = spatialSample(keys, at: lt)
        let pt = CGPoint(x: s.point.x + shift.x + proceduralOffset(.x, at: t),
                         y: s.point.y + shift.y + proceduralOffset(.y, at: t))
        return (pt, sp.orient ? s.angle : 0)
    }

    /// The Bezier segments of the spatial path (for drawing it), in the layer's parent space.
    public func spatialSegments() -> [(p0: CGPoint, c1: CGPoint, c2: CGPoint, p1: CGPoint, t0: Double, t1: Double)] {
        guard let sp = spatial else { return [] }
        let keys = spatialKeys(sp)
        guard keys.count >= 2 else { return [] }
        return (0..<(keys.count - 1)).map { i in
            let a = keys[i], b = keys[i + 1]
            return (a.p, a.p.plus(a.out), b.p.plus(b.in), b.p, a.t, b.t)
        }
    }

    private struct SpatialKey {
        var t: Double
        var p: CGPoint
        var easing: Easing
        var `in` = CGPoint.zero
        var out = CGPoint.zero
    }

    /// Keys at every x or y key time, with their tangents (custom, auto-Bezier or none).
    private func spatialKeys(_ sp: SpatialPath) -> [SpatialKey] {
        var times = (x.keyframeList.map(\.t) + y.keyframeList.map(\.t)).sorted()
        times = times.reduce(into: [Double]()) { acc, t in
            if let l = acc.last, abs(t - l) < MotionScene.keyTimeTolerance { return }
            acc.append(t)
        }
        var keys = times.map { t -> SpatialKey in
            let e = x.keyframeList.first { abs($0.t - t) < MotionScene.keyTimeTolerance }?.easing
                ?? y.keyframeList.first { abs($0.t - t) < MotionScene.keyTimeTolerance }?.easing ?? .linear
            return SpatialKey(t: t, p: CGPoint(x: x.value(at: t), y: y.value(at: t)), easing: e)
        }
        let n = keys.count
        guard n >= 2 else { return keys }

        if sp.smooth && n > 2 {
            for i in 1..<(n - 1) {
                let d = keys[i + 1].p.minus(keys[i - 1].p)
                let len = d.length
                guard len > 1e-9 else { continue }
                let dir = CGPoint(x: d.x / len, y: d.y / len)
                keys[i].out = dir.times(keys[i + 1].p.minus(keys[i].p).length / 3)
                keys[i].in = dir.times(-keys[i].p.minus(keys[i - 1].p).length / 3)
            }
        }
        for i in 0..<n {
            guard let h = sp.handle(at: keys[i].t) else { continue }
            if let v = h.in { keys[i].in = CGPoint(x: v.x, y: v.y) }
            if let v = h.out { keys[i].out = CGPoint(x: v.x, y: v.y) }
        }
        // An end key without a custom handle aims at its neighbor's handle, so the path leaves it along the curve.
        func aim(_ from: CGPoint, toward target: CGPoint, length: Double) -> CGPoint {
            let d = target.minus(from), l = d.length
            return l > 1e-9 ? d.times(length / l) : .zero
        }
        if sp.smooth {
            if sp.handle(at: keys[0].t)?.out == nil {
                let seg = keys[1].p.minus(keys[0].p).length
                keys[0].out = aim(keys[0].p, toward: keys[1].p.plus(keys[1].in), length: seg / 3)
            }
            if sp.handle(at: keys[n - 1].t)?.in == nil {
                let seg = keys[n - 1].p.minus(keys[n - 2].p).length
                keys[n - 1].in = aim(keys[n - 1].p, toward: keys[n - 2].p.plus(keys[n - 2].out), length: seg / 3)
            }
        }
        return keys
    }

    /// Point and direction (degrees) at time t: the arriving key's easing gives the fraction of the segment's length.
    private func spatialSample(_ keys: [SpatialKey], at t: Double) -> (point: CGPoint, angle: Double) {
        let n = keys.count
        var i = 0
        if t >= keys[n - 1].t {
            i = n - 2
        } else if t > keys[0].t {
            while i < n - 2 && keys[i + 1].t <= t { i += 1 }
        }
        let a = keys[i], b = keys[i + 1]
        let span = b.t - a.t
        let p = span > 0 ? min(max((t - a.t) / span, 0), 1) : 1
        let curve = Bezier(a.p, a.p.plus(a.out), b.p.plus(b.in), b.p)
        let at = curve.atDistance(b.easing.apply(p))
        var angle = at.angle
        if curve.length < 1e-6 { angle = travelAngle(keys, around: i) }
        return (at.point, angle)
    }

    /// Direction of the nearest segment that moves, for orienting while the layer holds still.
    private func travelAngle(_ keys: [SpatialKey], around i: Int) -> Double {
        let segs = keys.count - 1
        for d in 1..<max(segs, 2) {
            for j in [i - d, i + d] where j >= 0 && j < segs {
                let c = Bezier(keys[j].p, keys[j].p.plus(keys[j].out), keys[j + 1].p.plus(keys[j + 1].in), keys[j + 1].p)
                if c.length >= 1e-6 { return c.atDistance(j < i ? 1 : 0).angle }
            }
        }
        return 0
    }
}

/// A cubic Bezier sampled by distance along it.
private struct Bezier {
    let p0, p1, p2, p3: CGPoint
    private var lengths: [Double] = [0]
    private static let steps = 32

    init(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) {
        self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3
        var prev = p0
        for k in 1...Self.steps {
            let q = point(Double(k) / Double(Self.steps))
            lengths.append(lengths[k - 1] + q.minus(prev).length)
            prev = q
        }
    }

    var length: Double { lengths[Self.steps] }

    func point(_ u: Double) -> CGPoint {
        let v = 1 - u
        let a = v * v * v, b = 3 * v * v * u, c = 3 * v * u * u, d = u * u * u
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    func tangent(_ u: Double) -> CGPoint {
        let v = 1 - u
        let d = p1.minus(p0).times(3 * v * v).plus(p2.minus(p1).times(6 * v * u)).plus(p3.minus(p2).times(3 * u * u))
        return d.length > 1e-9 ? d : p3.minus(p0)
    }

    /// Point at a fraction of the length; beyond 0…1 (overshooting easings) it carries on along the end tangent.
    func atDistance(_ f: Double) -> (point: CGPoint, angle: Double) {
        func angle(_ d: CGPoint) -> Double { atan2(d.y, d.x) * 180 / Double.pi }
        let total = length
        guard total > 1e-9 else { return (p0, 0) }
        if f < 0 || f > 1 {
            let end = f < 0 ? 0.0 : 1.0
            let d = tangent(end), l = d.length
            let base = end == 0 ? p0 : p3
            guard l > 1e-9 else { return (base, 0) }
            let extra = (f - end) * total
            return (base.plus(d.times(extra / l)), angle(d))
        }
        let target = f * total
        var lo = 0, hi = Self.steps
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if lengths[mid] <= target { lo = mid } else { hi = mid }
        }
        let seg = lengths[hi] - lengths[lo]
        let u = (Double(lo) + (seg > 0 ? (target - lengths[lo]) / seg : 0)) / Double(Self.steps)
        return (point(u), angle(tangent(u)))
    }
}

private extension CGPoint {
    func plus(_ b: CGPoint) -> CGPoint { CGPoint(x: x + b.x, y: y + b.y) }
    func minus(_ b: CGPoint) -> CGPoint { CGPoint(x: x - b.x, y: y - b.y) }
    func times(_ s: Double) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    var length: Double { hypot(x, y) }
}
