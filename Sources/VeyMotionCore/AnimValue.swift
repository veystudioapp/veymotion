import Foundation

/// A value that can be keyframed: numbers and colors.
public protocol Interpolatable: Codable, Equatable, Hashable, Sendable {
    static func lerp(_ a: Self, _ b: Self, _ p: Double) -> Self
    /// Value used when an empty keyframe list is decoded.
    static var zero: Self { get }
    /// `v` moved on by `cycles` repetitions of the change from `first` to `last` (loop "offset").
    static func extrapolate(_ v: Self, first: Self, last: Self, cycles: Double) -> Self
}

extension Double: Interpolatable {
    public static func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }
    public static var zero: Double { 0 }
    public static func extrapolate(_ v: Double, first: Double, last: Double, cycles: Double) -> Double {
        v + (last - first) * cycles
    }
}

extension RGBA: Interpolatable {
    public static func lerp(_ a: RGBA, _ b: RGBA, _ p: Double) -> RGBA {
        func c(_ x: Double, _ y: Double) -> Double { min(max(x + (y - x) * p, 0), 1) }
        return RGBA(r: c(a.r, b.r), g: c(a.g, b.g), b: c(a.b, b.b), a: c(a.a, b.a))
    }
    public static var zero: RGBA { .clear }
    public static func extrapolate(_ v: RGBA, first: RGBA, last: RGBA, cycles: Double) -> RGBA { v }
}

public struct Keyframe<V: Interpolatable>: Codable, Equatable, Hashable, Sendable {
    /// Absolute scene time in seconds.
    public var t: Double
    public var v: V
    /// Easing of the segment arriving at this keyframe (from the previous one).
    public var easing: Easing

    public init(t: Double, v: V, easing: Easing = .easeInOut) {
        self.t = t; self.v = v; self.easing = easing
    }

    enum CodingKeys: String, CodingKey { case t, v, easing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        v = try c.decode(V.self, forKey: .v)
        easing = try c.decodeIfPresent(Easing.self, forKey: .easing) ?? .easeInOut
    }
}

public typealias MotionKeyframe = Keyframe<Double>
public typealias ColorKeyframe = Keyframe<RGBA>

/// How a track continues after its last keyframe.
public enum LoopMode: String, Codable, CaseIterable, Sendable {
    /// Repeat the keyframes from the first to the last.
    case cycle
    /// Play forward, then backward, and so on.
    case pingpong
    /// Repeat, adding the total change each time (e.g. endless rotation). Colors behave like cycle.
    case offset

    public var title: String {
        switch self {
        case .cycle: return "Cycle"
        case .pingpong: return "Ping-pong"
        case .offset: return "Offset"
        }
    }
}

/// An animatable value. JSON form is either a plain value (constant)
/// or `{"keyframes": [{"t": 0, "v": 0}, {"t": 1, "v": 100, "easing": "easeOut"}]}`.
public enum Animated<V: Interpolatable>: Equatable, Hashable, Sendable, Codable {
    case constant(V)
    case keyframes([Keyframe<V>])

    public var isAnimated: Bool {
        if case .keyframes = self { return true }
        return false
    }

    public var keyframeList: [Keyframe<V>] {
        if case let .keyframes(k) = self { return k }
        return []
    }

    public func value(at t: Double) -> V {
        switch self {
        case let .constant(v):
            return v
        case let .keyframes(kfs):
            guard let first = kfs.first, let last = kfs.last else { return V.zero }
            if t <= first.t { return first.v }
            if t >= last.t { return last.v }
            for i in 0..<(kfs.count - 1) {
                let a = kfs[i], b = kfs[i + 1]
                if t >= a.t && t < b.t {
                    let span = b.t - a.t
                    let p = span > 0 ? (t - a.t) / span : 1
                    return V.lerp(a.v, b.v, b.easing.apply(p))
                }
            }
            return last.v
        }
    }

    /// Value with the track repeating after its last keyframe.
    public func value(at t: Double, loop: LoopMode?) -> V {
        guard let loop, case let .keyframes(kfs) = self, kfs.count >= 2,
              let first = kfs.first, let last = kfs.last, last.t - first.t > 1e-6, t > last.t
        else { return value(at: t) }
        let span = last.t - first.t
        let elapsed = t - first.t
        let cycles = floor(elapsed / span)
        let local = elapsed - cycles * span
        switch loop {
        case .cycle:
            return value(at: first.t + local)
        case .pingpong:
            let backward = Int(cycles) % 2 == 1
            return value(at: backward ? last.t - local : first.t + local)
        case .offset:
            return V.extrapolate(value(at: first.t + local), first: first.v, last: last.v, cycles: cycles)
        }
    }

    /// Normalizes keyframes: sorted by time, collapsing an empty list to a constant.
    public static func make(_ kfs: [Keyframe<V>], fallback: V) -> Animated<V> {
        let sorted = kfs.sorted { $0.t < $1.t }
        if sorted.isEmpty { return .constant(fallback) }
        return .keyframes(sorted)
    }

    /// Replaces keyframes inside [lo, hi] with `new`, keeping the rest.
    public func inserting(_ new: [Keyframe<V>], replacing lo: Double, _ hi: Double) -> Animated<V> {
        let kept = keyframeList.filter { $0.t < lo - 1e-6 || $0.t > hi + 1e-6 }
        return Animated.make(kept + new, fallback: value(at: lo))
    }

    /// Sets the value at time t: updates the constant, or upserts a keyframe if animated.
    public func setting(_ v: V, at t: Double) -> Animated<V> {
        switch self {
        case .constant:
            return .constant(v)
        case let .keyframes(kfs):
            var list = kfs
            if let i = list.firstIndex(where: { abs($0.t - t) < 1e-4 }) {
                list[i].v = v
            } else {
                list.append(Keyframe(t: t, v: v))
            }
            return Animated.make(list, fallback: v)
        }
    }

    // MARK: Timeline edits (a key is addressed by its time)

    public func hasKey(at t: Double, tolerance: Double) -> Bool {
        keyframeList.contains { abs($0.t - t) < tolerance }
    }

    public func movingKey(at t: Double, to newT: Double, tolerance: Double) -> Animated<V> {
        var kfs = keyframeList
        guard let k = kfs.firstIndex(where: { abs($0.t - t) < tolerance }) else { return self }
        kfs[k].t = newT
        return Animated.make(kfs, fallback: kfs[k].v)
    }

    public func settingEasing(at t: Double, _ easing: Easing, tolerance: Double) -> Animated<V> {
        guard isAnimated else { return self }
        var kfs = keyframeList
        for k in kfs.indices where abs(kfs[k].t - t) < tolerance { kfs[k].easing = easing }
        return .keyframes(kfs)
    }

    /// Deletes the key at t. A track left without keys becomes constant at its value at t.
    public func deletingKey(at t: Double, tolerance: Double) -> Animated<V> {
        let kept = keyframeList.filter { abs($0.t - t) >= tolerance }
        return Animated.make(kept, fallback: value(at: t))
    }

    public func shifted(by d: Double) -> Animated<V> {
        guard isAnimated else { return self }
        return .keyframes(keyframeList.map { Keyframe(t: $0.t + d, v: $0.v, easing: $0.easing) })
    }

    // MARK: Codable

    private struct Wrapper: Codable { var keyframes: [Keyframe<V>] }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(V.self) {
            self = .constant(v)
        } else if let w = try? c.decode(Wrapper.self) {
            self = Animated.make(w.keyframes, fallback: V.zero)
        } else if let list = try? c.decode([Keyframe<V>].self) {
            self = Animated.make(list, fallback: V.zero)
        } else {
            let what = V.self == RGBA.self ? "a color \"#RRGGBB[AA]\"" : "a number"
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Expected \(what) or {\"keyframes\": [{\"t\", \"v\", \"easing\"?}]}")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .constant(v): try c.encode(v)
        case let .keyframes(k): try c.encode(Wrapper(keyframes: k))
        }
    }
}

public typealias AnimValue = Animated<Double>
public typealias ColorValue = Animated<RGBA>

extension Animated: ExpressibleByIntegerLiteral where V == Double {
    public init(integerLiteral value: Int) { self = .constant(Double(value)) }
}

extension Animated: ExpressibleByFloatLiteral where V == Double {
    public init(floatLiteral value: Double) { self = .constant(value) }
}
