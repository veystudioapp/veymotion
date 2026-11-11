import Foundation

/// Shape of a named easing family (the "Back" in easeOutBack).
public enum EaseCurve: String, CaseIterable, Sendable {
    case sine, quad, cubic, quart, quint, expo, circ, back, elastic, bounce

    public var title: String { rawValue.capitalized }

    /// The ease-in form; out and inOut are derived from it.
    func easeIn(_ p: Double) -> Double {
        switch self {
        case .sine: return 1 - cos(p * .pi / 2)
        case .quad: return p * p
        case .cubic: return p * p * p
        case .quart: return p * p * p * p
        case .quint: return p * p * p * p * p
        case .expo: return p <= 0 ? 0 : pow(2, 10 * p - 10)
        case .circ: return 1 - (1 - p * p).squareRoot()
        case .back:
            let c1 = 1.70158, c3 = c1 + 1
            return c3 * p * p * p - c1 * p * p
        case .elastic:
            if p <= 0 || p >= 1 { return p }
            return -pow(2, 10 * p - 10) * sin((10 * p - 10.75) * (2 * .pi / 3))
        case .bounce:
            return 1 - Self.bounceOut(1 - p)
        }
    }

    static func bounceOut(_ p: Double) -> Double {
        let n1 = 7.5625, d1 = 2.75
        if p < 1 / d1 { return n1 * p * p }
        if p < 2 / d1 { let q = p - 1.5 / d1; return n1 * q * q + 0.75 }
        if p < 2.5 / d1 { let q = p - 2.25 / d1; return n1 * q * q + 0.9375 }
        let q = p - 2.625 / d1
        return n1 * q * q + 0.984375
    }
}

public enum EaseMode: String, CaseIterable, Sendable {
    case `in` = "In", out = "Out", inOut = "InOut"

    public var title: String {
        switch self {
        case .in: return "In"
        case .out: return "Out"
        case .inOut: return "In Out"
        }
    }
}

/// Easing curve applied to the segment that *arrives* at a keyframe.
/// Serialized as a string: "linear", "easeIn", "easeOut", "easeInOut", "hold", "spring",
/// "ease<In|Out|InOut><Sine|Quad|Cubic|Quart|Quint|Expo|Circ|Back|Elastic|Bounce>" (e.g. "easeOutBack"),
/// "spring(damping,frequency)", "steps(n)" or "cubicBezier(x1,y1,x2,y2)".
public enum Easing: Equatable, Hashable, Sendable, Codable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case hold
    case spring
    case curve(EaseCurve, EaseMode)
    /// Damped spring. `damping` ≈ how fast it settles (3 = very bouncy, 12 = barely overshoots),
    /// `frequency` ≈ how many wobbles (radians over the segment; 10 ≈ 1.5 wobbles).
    case springWith(damping: Double, frequency: Double)
    /// Jumps in n equal steps (like a frame-by-frame animation).
    case steps(Int)
    case cubicBezier(Double, Double, Double, Double)

    public static let allNamed: [Easing] = [.linear, .easeIn, .easeOut, .easeInOut, .hold, .spring]
        + EaseCurve.allCases.flatMap { c in EaseMode.allCases.map { Easing.curve(c, $0) } }

    public init?(string raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let key = s.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch key {
        case "linear": self = .linear; return
        case "easein": self = .easeIn; return
        case "easeout": self = .easeOut; return
        case "easeinout", "ease": self = .easeInOut; return
        case "hold", "step": self = .hold; return
        case "spring": self = .spring; return
        default: break
        }
        if key.hasPrefix("ease") {
            var rest = Substring(key.dropFirst(4))
            let mode: EaseMode
            if rest.hasPrefix("inout") { mode = .inOut; rest = rest.dropFirst(5) }
            else if rest.hasPrefix("in") { mode = .in; rest = rest.dropFirst(2) }
            else if rest.hasPrefix("out") { mode = .out; rest = rest.dropFirst(3) }
            else { return nil }
            guard let curve = EaseCurve(rawValue: String(rest)) else { return nil }
            self = .curve(curve, mode)
            return
        }
        guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
        let name = key.prefix { $0 != "(" }
        let nums = s[s.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        switch name {
        case "cubicbezier":
            guard nums.count == 4 else { return nil }
            self = .cubicBezier(nums[0], nums[1], nums[2], nums[3])
        case "spring":
            guard nums.count == 2, nums[0] > 0, nums[1] >= 0 else { return nil }
            self = .springWith(damping: nums[0], frequency: nums[1])
        case "steps":
            guard nums.count == 1, nums[0] >= 1 else { return nil }
            self = .steps(Int(nums[0]))
        default:
            return nil
        }
    }

    public var string: String {
        switch self {
        case .linear: return "linear"
        case .easeIn: return "easeIn"
        case .easeOut: return "easeOut"
        case .easeInOut: return "easeInOut"
        case .hold: return "hold"
        case .spring: return "spring"
        case let .curve(c, m): return "ease\(m.rawValue)\(c.rawValue.capitalized)"
        case let .springWith(d, f): return "spring(\(Self.num(d)),\(Self.num(f)))"
        case let .steps(n): return "steps(\(n))"
        case let .cubicBezier(a, b, c, d): return "cubicBezier(\(Self.num(a)),\(Self.num(b)),\(Self.num(c)),\(Self.num(d)))"
        }
    }

    /// Human-readable name for menus and tooltips.
    public var title: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Ease In"
        case .easeOut: return "Ease Out"
        case .easeInOut: return "Ease In Out"
        case .hold: return "Hold"
        case .spring: return "Spring"
        case let .curve(c, m): return "\(c.title) \(m.title)"
        case let .springWith(d, f): return "Spring (\(Self.num(d)), \(Self.num(f)))"
        case let .steps(n): return "Steps (\(n))"
        case .cubicBezier: return "Custom Bezier"
        }
    }

    /// Control points (x1, y1, x2, y2) as a cubic Bezier: exact, or the usual close fit for the named curves.
    /// nil for hold, steps, springs, elastic and bounce.
    public var bezierControls: (Double, Double, Double, Double)? {
        switch self {
        case .linear: return (1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3)
        case .easeIn: return (0.55, 0, 0.75, 0.2)
        case .easeOut: return (0.22, 1, 0.36, 1)
        case .easeInOut: return (0.65, 0, 0.35, 1)
        case let .cubicBezier(a, b, c, d): return (a, b, c, d)
        case .hold, .spring, .springWith, .steps: return nil
        case let .curve(c, m):
            guard let f = Self.bezierFits[c] else { return nil }
            switch m {
            case .in: return f[0]
            case .out: return f[1]
            case .inOut: return f[2]
            }
        }
    }

    /// In, out and in-out fits per curve (from easings.net).
    private static let bezierFits: [EaseCurve: [(Double, Double, Double, Double)]] = [
        .sine: [(0.12, 0, 0.39, 0), (0.61, 1, 0.88, 1), (0.37, 0, 0.63, 1)],
        .quad: [(0.11, 0, 0.5, 0), (0.5, 1, 0.89, 1), (0.45, 0, 0.55, 1)],
        .cubic: [(0.32, 0, 0.67, 0), (0.33, 1, 0.68, 1), (0.65, 0, 0.35, 1)],
        .quart: [(0.5, 0, 0.75, 0), (0.25, 1, 0.5, 1), (0.76, 0, 0.24, 1)],
        .quint: [(0.64, 0, 0.78, 0), (0.22, 1, 0.36, 1), (0.83, 0, 0.17, 1)],
        .expo: [(0.7, 0, 0.84, 0), (0.16, 1, 0.3, 1), (0.87, 0, 0.13, 1)],
        .circ: [(0.55, 0, 1, 0.45), (0, 0.55, 0.45, 1), (0.85, 0, 0.15, 1)],
        .back: [(0.36, 0, 0.66, -0.56), (0.34, 1.56, 0.64, 1), (0.68, -0.6, 0.32, 1.6)],
    ]

    private static func num(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%g", v)
    }

    /// Maps linear progress p in [0, 1] to eased progress. Back, elastic and spring overshoot [0, 1].
    public func apply(_ p: Double) -> Double {
        let p = min(max(p, 0), 1)
        switch self {
        case .linear: return p
        case .hold: return p >= 1 ? 1 : 0
        case .easeIn: return Self.bezier(0.55, 0, 0.75, 0.2, p)
        case .easeOut: return Self.bezier(0.22, 1, 0.36, 1, p)
        case .easeInOut: return Self.bezier(0.65, 0, 0.35, 1, p)
        case .spring: return Self.spring(p, damping: 6, frequency: 10)
        case let .springWith(d, f): return Self.spring(p, damping: d, frequency: f)
        case let .curve(c, m):
            switch m {
            case .in: return c.easeIn(p)
            case .out: return 1 - c.easeIn(1 - p)
            case .inOut: return p < 0.5 ? c.easeIn(2 * p) / 2 : 1 - c.easeIn(2 - 2 * p) / 2
            }
        case let .steps(n):
            let n = Double(max(n, 1))
            return p >= 1 ? 1 : floor(p * n) / n
        case let .cubicBezier(x1, y1, x2, y2): return Self.bezier(x1, y1, x2, y2, p)
        }
    }

    /// Damped oscillation that starts at 0 and lands exactly on 1 at p = 1 (the tiny remaining wobble is
    /// blended out linearly so there is no jump at the keyframe).
    static func spring(_ p: Double, damping: Double, frequency: Double) -> Double {
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        let tail = exp(-damping) * cos(frequency)
        return 1 - (exp(-damping * p) * cos(frequency * p) - p * tail)
    }

    /// CSS-style cubic bezier with endpoints (0,0) and (1,1).
    static func bezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func sample(_ a1: Double, _ a2: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a1 + 3 * u * t * t * a2 + t * t * t
        }
        func slope(_ a1: Double, _ a2: Double, _ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * a1 + 6 * u * t * (a2 - a1) + 3 * t * t * (1 - a2)
        }
        // Newton-Raphson, falling back to bisection.
        var t = x
        for _ in 0..<8 {
            let err = sample(x1, x2, t) - x
            if abs(err) < 1e-6 { return sample(y1, y2, t) }
            let d = slope(x1, x2, t)
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        for _ in 0..<40 {
            let v = sample(x1, x2, t)
            if abs(v - x) < 1e-7 { break }
            if v < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return sample(y1, y2, t)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        guard let e = Easing(string: s) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown easing '\(s)'. Use linear, easeIn, easeOut, easeInOut, hold, spring, "
                    + "ease<In|Out|InOut><Sine|Quad|Cubic|Quart|Quint|Expo|Circ|Back|Elastic|Bounce> (e.g. easeOutBack), "
                    + "spring(damping,frequency), steps(n) or cubicBezier(x1,y1,x2,y2).")
        }
        self = e
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
