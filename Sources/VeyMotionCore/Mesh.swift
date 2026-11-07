import CoreGraphics
import Foundation

// Mesh warps: 2.5D rotation with perspective, corner pin and puppet pins. CoreGraphics has no perspective transform,
// so the renderer draws the layer flat into a bitmap, cuts it into a grid of triangles and draws each one with the
// affine transform that maps it onto the warped grid (a good approximation of a projective warp at ~10 cells).

/// Four corners of a layer's box after a corner pin, in layer px around its center (top-left, top-right,
/// bottom-right, bottom-left). Animatable: keyframes interpolate each corner.
public struct CornerPin: Interpolatable {
    public var tl: PathPoint
    public var tr: PathPoint
    public var br: PathPoint
    public var bl: PathPoint

    public init(tl: PathPoint, tr: PathPoint, br: PathPoint, bl: PathPoint) {
        self.tl = tl; self.tr = tr; self.br = br; self.bl = bl
    }

    public static var zero: CornerPin {
        let o = PathPoint(x: 0, y: 0)
        return CornerPin(tl: o, tr: o, br: o, bl: o)
    }

    public static func lerp(_ a: CornerPin, _ b: CornerPin, _ p: Double) -> CornerPin {
        func l(_ u: PathPoint, _ v: PathPoint) -> PathPoint { PathPoint(x: u.x + (v.x - u.x) * p, y: u.y + (v.y - u.y) * p) }
        return CornerPin(tl: l(a.tl, b.tl), tr: l(a.tr, b.tr), br: l(a.br, b.br), bl: l(a.bl, b.bl))
    }

    public static func extrapolate(_ v: CornerPin, first: CornerPin, last: CornerPin, cycles: Double) -> CornerPin { v }

    enum CodingKeys: String, CodingKey { case tl, tr, br, bl }
}

public typealias CornerPinValue = Animated<CornerPin>

/// A handle on the layer: the point at (x, y) (layer px, at rest) moves by (dx, dy). Pins pull the picture around
/// them like After Effects' Puppet tool; pins that do not move hold their part in place.
public struct PuppetPin: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var dx: AnimValue
    public var dy: AnimValue

    public init(x: Double, y: Double, dx: AnimValue = .constant(0), dy: AnimValue = .constant(0)) {
        self.x = x; self.y = y; self.dx = dx; self.dy = dy
    }

    enum CodingKeys: String, CodingKey { case x, y, dx, dy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        dx = try c.decodeIfPresent(AnimValue.self, forKey: .dx) ?? .constant(0)
        dy = try c.decodeIfPresent(AnimValue.self, forKey: .dy) ?? .constant(0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        if dx != .constant(0) { try c.encode(dx, forKey: .dx) }
        if dy != .constant(0) { try c.encode(dy, forKey: .dy) }
    }

    func shifted(by d: Double) -> PuppetPin {
        PuppetPin(x: x, y: y, dx: dx.shifted(by: d), dy: dy.shifted(by: d))
    }
}

extension MotionLayer {
    /// Whether the layer may be mesh-warped (cheap check, before evaluating anything).
    var rotationXYOrPinned: Bool {
        cornerPin != nil || !pins.isEmpty || extra[.rotationX] != nil || extra[.rotationY] != nil
    }
}

/// The warp of one layer at one time, mapping layer-local points (around its center) to warped local points.
struct MeshWarp {
    var rotX = 0.0, rotY = 0.0, distance = 1200.0
    var pin: CornerPin?
    var pins: [(p: CGPoint, q: CGPoint)] = []
    /// The box a corner pin maps from (the layer's content box).
    var box = CGRect.zero
    var hideBackface = false
    private var homography: [Double]?

    init?(_ layer: MotionLayer, box: CGRect, at t: Double) {
        rotX = layer.value(.rotationX, at: t)
        rotY = layer.value(.rotationY, at: t)
        distance = max(50, layer.value(.perspective, at: t))
        hideBackface = layer.hideBackface
        self.box = box
        if let cp = layer.cornerPin { pin = cp.value(at: t, loop: layer.loop["cornerPin"]) }
        pins = layer.pins.map { p in
            (CGPoint(x: p.x, y: p.y), CGPoint(x: p.x + p.dx.value(at: t), y: p.y + p.dy.value(at: t)))
        }
        let rotates = abs(rotX) > 0.01 || abs(rotY) > 0.01
        let pinsMove = pins.contains { hypot($0.q.x - $0.p.x, $0.q.y - $0.p.y) > 0.01 }
        guard rotates || pin != nil || pinsMove else { return nil }
        if !pinsMove { pins = [] }
        if let pin, box.width > 0, box.height > 0 {
            homography = Self.homography(from: [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                                                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)],
                                         to: [pin.tl, pin.tr, pin.br, pin.bl].map { CGPoint(x: $0.x, y: $0.y) })
        }
    }

    /// Grid cells per side: puppet pins bend more than perspective does.
    var cells: Int { pins.isEmpty ? 12 : 20 }

    /// True when the layer is turned away from the viewer.
    var facesAway: Bool {
        cos(rotX * .pi / 180) * cos(rotY * .pi / 180) < 0
    }

    func map(_ v: CGPoint) -> CGPoint {
        var p = v
        if !pins.isEmpty { p = Self.mls(p, pins) }
        if let h = homography {
            let w = h[6] * p.x + h[7] * p.y + 1
            p = CGPoint(x: (h[0] * p.x + h[1] * p.y + h[2]) / w, y: (h[3] * p.x + h[4] * p.y + h[5]) / w)
        }
        if abs(rotX) > 0.01 || abs(rotY) > 0.01 {
            // Turn around the layer's vertical axis (rotationY, + = right side goes back), then its horizontal one
            // (rotationX, + = top goes back), then project with the eye `distance` px in front of the layer.
            let a = rotY * .pi / 180, b = rotX * .pi / 180
            let x1 = p.x * cos(a), z1 = p.x * sin(a)
            // (y, z) turned by b; y points down, so a positive b sends the top (y < 0) away (z > 0).
            let y2 = p.y * cos(b) + z1 * sin(b), z2 = -p.y * sin(b) + z1 * cos(b)
            let depth = max(distance + z2, distance * 0.05)
            let s = distance / depth
            p = CGPoint(x: x1 * s, y: y2 * s)
        }
        return p
    }

    // MARK: Moving least squares (similarity), Schaefer et al. 2006

    static func mls(_ v: CGPoint, _ pins: [(p: CGPoint, q: CGPoint)]) -> CGPoint {
        if pins.count == 1 { return CGPoint(x: v.x + pins[0].q.x - pins[0].p.x, y: v.y + pins[0].q.y - pins[0].p.y) }
        var ws = [Double](), sw = 0.0
        var ps = CGPoint.zero, qs = CGPoint.zero
        for pin in pins {
            let d2 = (pin.p.x - v.x) * (pin.p.x - v.x) + (pin.p.y - v.y) * (pin.p.y - v.y)
            if d2 < 1e-6 { return pin.q }
            let w = 1 / d2
            ws.append(w); sw += w
            ps.x += w * pin.p.x; ps.y += w * pin.p.y
            qs.x += w * pin.q.x; qs.y += w * pin.q.y
        }
        ps.x /= sw; ps.y /= sw; qs.x /= sw; qs.y /= sw
        let d = CGPoint(x: v.x - ps.x, y: v.y - ps.y)
        var mu = 0.0, fx = 0.0, fy = 0.0
        for (i, pin) in pins.enumerated() {
            let ph = CGPoint(x: pin.p.x - ps.x, y: pin.p.y - ps.y), qh = CGPoint(x: pin.q.x - qs.x, y: pin.q.y - qs.y)
            mu += ws[i] * (ph.x * ph.x + ph.y * ph.y)
            // A = w [p̂; -p̂⊥] [d, -d⊥], with (x, y)⊥ = (-y, x).
            let a00 = ph.x * d.x + ph.y * d.y, a01 = ph.x * d.y - ph.y * d.x
            let a10 = -(ph.x * d.y - ph.y * d.x), a11 = ph.x * d.x + ph.y * d.y
            fx += ws[i] * (qh.x * a00 + qh.y * a10)
            fy += ws[i] * (qh.x * a01 + qh.y * a11)
        }
        guard mu > 1e-9 else { return CGPoint(x: v.x + qs.x - ps.x, y: v.y + qs.y - ps.y) }
        return CGPoint(x: fx / mu + qs.x, y: fy / mu + qs.y)
    }

    // MARK: Homography from 4 point pairs (h33 = 1)

    static func homography(from s: [CGPoint], to d: [CGPoint]) -> [Double]? {
        // 8 unknowns: solve A h = b with Gaussian elimination.
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = s[i].x, y = s[i].y, u = d[i].x, v = d[i].y
            a[2 * i] = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[2 * i + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        for col in 0..<8 {
            guard let piv = (col..<8).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[piv][col]) > 1e-12 else { return nil }
            a.swapAt(col, piv)
            for r in 0..<8 where r != col {
                let f = a[r][col] / a[col][col]
                if f != 0 { for k in col..<9 { a[r][k] -= f * a[col][k] } }
            }
        }
        return (0..<8).map { a[$0][8] / a[$0][$0] }
    }
}
