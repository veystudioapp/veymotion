import CoreGraphics
import Foundation

// Per-layer effects in the spirit of After Effects' Color Correction and Transition categories.
// Their amounts are ordinary animatable properties (brightness, contrast, saturation, hue, tint, wipe), so keyframes,
// loops, wiggle and audioReact work on them; the settings that do not animate live in `tintColor` and `wipeStyle`.

// MARK: - Color correction

/// Affine color transform `out = m · rgb + b` on straight (not premultiplied) colors in 0…1.
public struct ColorMatrix: Equatable, Sendable {
    /// 3×3, row-major: `m[3 * i + j]` is how much input channel j adds to output channel i.
    public var m: [Double]
    public var b: [Double]

    public static let identity = ColorMatrix(m: [1, 0, 0, 0, 1, 0, 0, 0, 1], b: [0, 0, 0])

    /// Rec. 709 luma weights.
    static let luma = [0.2126, 0.7152, 0.0722]

    /// This transform followed by `next`.
    public func then(_ next: ColorMatrix) -> ColorMatrix {
        var m2 = [Double](repeating: 0, count: 9), b2 = [Double](repeating: 0, count: 3)
        for i in 0..<3 {
            var bi: Double = next.b[i]
            for k in 0..<3 {
                let nk: Double = next.m[3 * i + k]
                for j in 0..<3 { m2[3 * i + j] += nk * m[3 * k + j] }
                bi += nk * b[k]
            }
            b2[i] = bi
        }
        return ColorMatrix(m: m2, b: b2)
    }

    /// `amount` = -1…1 (0 = unchanged): adds that much light to every channel.
    static func brightness(_ amount: Double) -> ColorMatrix {
        ColorMatrix(m: identity.m, b: [amount, amount, amount])
    }

    /// `amount` = -1 (flat gray) … 0 (unchanged) … 1 (twice the contrast), around middle gray.
    static func contrast(_ amount: Double) -> ColorMatrix {
        let f = max(0, 1 + amount)
        let o = 0.5 * (1 - f)
        return ColorMatrix(m: [f, 0, 0, 0, f, 0, 0, 0, f], b: [o, o, o])
    }

    /// `amount` = -1 (grayscale) … 0 (unchanged) … 1 (twice as saturated). Keeps luminance.
    static func saturation(_ amount: Double) -> ColorMatrix {
        let s = max(0, 1 + amount)
        var m = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 { m[3 * i + j] = (1 - s) * luma[j] + (i == j ? s : 0) }
        }
        return ColorMatrix(m: m, b: [0, 0, 0])
    }

    /// Turns hues around the color wheel by `degrees`, keeping luminance (like SVG's hueRotate).
    static func hue(_ degrees: Double) -> ColorMatrix {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a)
        return ColorMatrix(m: [
            0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928,
            0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283,
            0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072,
        ], b: [0, 0, 0])
    }

    /// Maps black to black and white to `color` by luminance (AE's Tint), mixed in by `amount` (0…1).
    static func tint(_ amount: Double, color: RGBA) -> ColorMatrix {
        let k = min(max(amount, 0), 1)
        let target = [color.r, color.g, color.b]
        var m = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 { m[3 * i + j] = (1 - k) * (i == j ? 1 : 0) + k * target[i] * luma[j] }
        }
        return ColorMatrix(m: m, b: [0, 0, 0])
    }
}

extension MotionLayer {
    /// The layer's color correction at time t, or nil when it leaves colors unchanged.
    /// Applied in AE's usual order: hue, saturation, tint, then brightness and contrast.
    public func colorMatrix(at t: Double) -> ColorMatrix? {
        let hue = value(.hue, at: t), sat = value(.saturation, at: t), tint = value(.tint, at: t)
        let bright = value(.brightness, at: t), contrast = value(.contrast, at: t)
        let eps = 1e-4
        guard abs(hue) > eps || abs(sat) > eps || tint > eps || abs(bright) > eps || abs(contrast) > eps else { return nil }
        var cm = ColorMatrix.identity
        if abs(hue) > eps { cm = cm.then(.hue(hue)) }
        if abs(sat) > eps { cm = cm.then(.saturation(sat)) }
        if tint > eps { cm = cm.then(.tint(tint, color: tintColor ?? .white)) }
        if abs(bright) > eps { cm = cm.then(.brightness(bright)) }
        if abs(contrast) > eps { cm = cm.then(.contrast(contrast)) }
        return cm
    }
}

// MARK: - Wipe transitions

public enum WipeType: String, Codable, CaseIterable, Sendable {
    /// A straight edge sweeps across the layer.
    case linear
    /// A clock hand sweeps around the layer's center.
    case radial
    /// A circle closes on the center (or, reversed, a hole opens from it).
    case iris
    /// Stripes that each close like venetian blinds.
    case blinds
    /// Random squares drop out (AE's Block Dissolve).
    case blocks

    public var title: String {
        switch self {
        case .linear: return "Linear"
        case .radial: return "Clock"
        case .iris: return "Iris"
        case .blinds: return "Blinds"
        case .blocks: return "Blocks"
        }
    }
}

/// How the `wipe` property hides the layer: 0 = whole layer shows, 1 = all of it is wiped away.
public struct WipeStyle: Codable, Equatable, Hashable, Sendable {
    public var type: WipeType
    /// linear/blinds: the direction the edge travels as wipe goes 0 → 1 (0 = rightward, 90 = downward).
    /// radial: where the hand starts (0 = 12 o'clock, 90 = 3 o'clock).
    public var angle: Double
    /// Soft edge width in layer px (0 = sharp).
    public var feather: Double
    /// blinds: number of stripes; blocks: number of blocks across the layer's longer side.
    public var count: Int
    /// radial: counter-clockwise; iris: a hole grows from the center instead of the layer shrinking into it.
    public var reverse: Bool
    /// blocks: change to get another random order.
    public var seed: Int

    public init(type: WipeType = .linear, angle: Double = 0, feather: Double = 0, count: Int = 8,
                reverse: Bool = false, seed: Int = 0) {
        self.type = type; self.angle = angle; self.feather = feather; self.count = count
        self.reverse = reverse; self.seed = seed
    }

    enum CodingKeys: String, CodingKey { case type, angle, feather, count, reverse, seed }

    /// Also accepts a bare type name ("iris").
    public init(from decoder: Decoder) throws {
        if let t = try? decoder.singleValueContainer().decode(WipeType.self) {
            self.init(type: t)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(type: try c.decodeIfPresent(WipeType.self, forKey: .type) ?? .linear,
                  angle: try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0,
                  feather: max(0, try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0),
                  count: min(max(try c.decodeIfPresent(Int.self, forKey: .count) ?? 8, 1), 200),
                  reverse: try c.decodeIfPresent(Bool.self, forKey: .reverse) ?? false,
                  seed: try c.decodeIfPresent(Int.self, forKey: .seed) ?? 0)
    }

    /// Writes only what differs from the defaults (type always).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if angle != 0 { try c.encode(angle, forKey: .angle) }
        if feather != 0 { try c.encode(feather, forKey: .feather) }
        if count != 8 && (type == .blinds || type == .blocks) { try c.encode(count, forKey: .count) }
        if reverse { try c.encode(reverse, forKey: .reverse) }
        if seed != 0 { try c.encode(seed, forKey: .seed) }
    }

    /// The part of the layer that still shows at wipe `progress` (0…1), in layer coordinates, for an even-odd fill.
    /// `box` is the layer's content box; the region reaches far beyond it so shadows and glows are not cut off.
    /// nil when nothing shows.
    public func visibleRegion(progress: Double, box: CGRect) -> CGPath? {
        let p = min(max(progress, 0), 1)
        guard p < 1 - 1e-6, box.width > 0 || box.height > 0 else { return nil }
        let far = 4 * max(box.width, box.height) + 4 * feather + 10_000
        let center = CGPoint(x: box.midX, y: box.midY)
        let path = CGMutablePath()
        // Unit vector of `angle` in layer space (y down) and its normal.
        let a = angle * .pi / 180
        let u = CGPoint(x: cos(a), y: sin(a)), v = CGPoint(x: -u.y, y: u.x)
        /// Extent of the box along u.
        func span() -> (lo: Double, hi: Double) {
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
            let d = corners.map { $0.x * u.x + $0.y * u.y }
            return (d.min()!, d.max()!)
        }
        /// The band between `from` and `to` along u, as wide as `far` across.
        func band(_ from: Double, _ to: Double) {
            guard to > from else { return }
            func pt(_ s: Double, _ w: Double) -> CGPoint { CGPoint(x: u.x * s + v.x * w, y: u.y * s + v.y * w) }
            path.addLines(between: [pt(from, -far), pt(to, -far), pt(to, far), pt(from, far)])
            path.closeSubpath()
        }
        switch type {
        case .linear:
            // The edge starts and ends a feather beyond the box, so 0 and 1 show and hide all of it.
            let (lo, hi) = span()
            let f = feather
            band(lo - f + p * (hi - lo + 2 * f), hi + far)
        case .blinds:
            let (lo, hi) = span()
            let n = max(count, 1)
            let w = (hi - lo) / Double(n)
            // Each stripe closes from its leading side; the ends stay open so nothing beyond the box is cut.
            band(lo - far, lo)
            for k in 0..<n {
                let s = lo + Double(k) * w
                band(s + p * w, s + w)
            }
            band(hi, hi + far)
        case .radial:
            // The hidden sector grows clockwise from `angle` (counter-clockwise when reversed); with y pointing down,
            // growing angles turn clockwise, and 12 o'clock is -90°. The visible sector is the rest of the turn.
            let zero = (angle - 90) * .pi / 180
            let sweep = 2 * Double.pi * (1 - p)
            let from = reverse ? zero : zero + 2 * .pi * p
            let steps = max(2, Int(sweep / (2 * .pi) * 180))
            path.move(to: center)
            for k in 0...steps {
                let aa = from + sweep * Double(k) / Double(steps)
                path.addLine(to: CGPoint(x: center.x + far * cos(aa), y: center.y + far * sin(aa)))
            }
            path.closeSubpath()
        case .iris:
            let rmax = hypot(box.width, box.height) / 2 + feather
            if reverse {
                let r = p * rmax
                path.addRect(CGRect(x: center.x - far, y: center.y - far, width: 2 * far, height: 2 * far))
                if r > 0 { path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)) }
            } else {
                let r = (1 - p) * rmax
                guard r > 0 else { return nil }
                path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
            }
        case .blocks:
            let n = max(count, 1)
            let size = max(box.width, box.height) / Double(n)
            guard size > 0 else { return nil }
            let cols = max(1, Int(ceil(box.width / size))), rows = max(1, Int(ceil(box.height / size)))
            let salt = Noise.mix(UInt64(bitPattern: Int64(seed)) &+ 0x5EED)
            // Blocks centered on the box; each drops out once progress passes its random threshold.
            let ox = box.midX - Double(cols) * size / 2, oy = box.midY - Double(rows) * size / 2
            for r in 0..<rows {
                for c in 0..<cols where Noise.unit(r * 7919 + c, salt) >= p {
                    path.addRect(CGRect(x: ox + Double(c) * size, y: oy + Double(r) * size, width: size, height: size))
                }
            }
            guard !path.isEmpty else { return nil }
        }
        return path
    }
}
