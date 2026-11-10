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
    /// 3D layers: the whole projection of the layer's plane (row-major 3×3, not normalized: w = camera depth), applied
    /// after the corner pin and puppet pins instead of the layer's own 2.5D rotation.
    private var projective: [Double]?
    private var facesAway3D = false

    init?(_ layer: MotionLayer, box: CGRect, at t: Double, projective: [Double]? = nil, facesAway: Bool = false) {
        self.projective = projective
        facesAway3D = facesAway
        if projective == nil {
            rotX = layer.value(.rotationX, at: t)
            rotY = layer.value(.rotationY, at: t)
            distance = max(50, layer.value(.perspective, at: t))
        }
        hideBackface = layer.hideBackface
        self.box = box
        if let cp = layer.cornerPin { pin = cp.value(at: t, loop: layer.loop["cornerPin"]) }
        pins = layer.pins.map { p in
            (CGPoint(x: p.x, y: p.y), CGPoint(x: p.x + p.dx.value(at: t), y: p.y + p.dy.value(at: t)))
        }
        let rotates = abs(rotX) > 0.01 || abs(rotY) > 0.01
        let pinsMove = pins.contains { hypot($0.q.x - $0.p.x, $0.q.y - $0.p.y) > 0.01 }
        guard rotates || pin != nil || pinsMove || projective != nil else { return nil }
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
        projective != nil ? facesAway3D : cos(rotX * .pi / 180) * cos(rotY * .pi / 180) < 0
    }

    func map(_ v: CGPoint) -> CGPoint {
        mapped(v, clamp: true) ?? v
    }

    /// Like `map`, but nil for a point of a 3D layer that is behind the camera.
    func mapChecked(_ v: CGPoint) -> CGPoint? {
        mapped(v, clamp: false)
    }

    private func mapped(_ v: CGPoint, clamp: Bool) -> CGPoint? {
        var p = v
        if !pins.isEmpty { p = Self.mls(p, pins) }
        if let h = homography {
            let w = h[6] * p.x + h[7] * p.y + 1
            p = CGPoint(x: (h[0] * p.x + h[1] * p.y + h[2]) / w, y: (h[3] * p.x + h[4] * p.y + h[5]) / w)
        }
        if rotates {
            let r = turned(p)
            let s = distance / max(distance + r.z, distance * 0.05)
            p = CGPoint(x: r.x * s, y: r.y * s)
        }
        if let h = projective {
            var w = h[6] * p.x + h[7] * p.y + h[8]
            if w <= View3D.near {
                guard clamp else { return nil }
                w = View3D.near
            }
            p = CGPoint(x: (h[0] * p.x + h[1] * p.y + h[2]) / w, y: (h[3] * p.x + h[4] * p.y + h[5]) / w)
        }
        return p
    }

    private var rotates: Bool { abs(rotX) > 0.01 || abs(rotY) > 0.01 }

    /// Turns a point around the layer's vertical axis (rotationY, + = right side goes back), then its horizontal one
    /// (rotationX, + = top goes back); z is the distance added between the point and the eye.
    private func turned(_ p: CGPoint) -> (x: Double, y: Double, z: Double) {
        let a = rotY * .pi / 180, b = rotX * .pi / 180
        let x1 = p.x * cos(a), z1 = p.x * sin(a)
        // (y, z) turned by b; y points down, so a positive b sends the top (y < 0) away (z > 0).
        return (x1, p.y * cos(b) + z1 * sin(b), -p.y * sin(b) + z1 * cos(b))
    }

    /// Without puppet pins, rotation + perspective and corner pin are projective, so the whole warp of `box` is the
    /// homography through its four corners: [h0…h7] with h8 = 1. Nil when there are pins, or when the plane reaches
    /// behind the eye or a crossed corner pin folds it (the line at infinity crosses the box).
    func projectiveMap(over box: CGRect) -> [Double]? {
        guard pins.isEmpty, box.width > 0, box.height > 0 else { return nil }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        var pinned = corners
        if let h = homography {
            for (i, p) in corners.enumerated() {
                let w = h[6] * p.x + h[7] * p.y + 1
                guard w > 1e-6 else { return nil }
                pinned[i] = CGPoint(x: (h[0] * p.x + h[1] * p.y + h[2]) / w, y: (h[3] * p.x + h[4] * p.y + h[5]) / w)
            }
        }
        // 3D: the plane's projection after the corner pin, kept unnormalized so pixels behind the camera are known.
        if let p = projective { return homography.map { Self.mul3(p, $0) } ?? p }
        // The same clamp `map` applies: past it the projection is no longer the plane's.
        if rotates, pinned.contains(where: { distance + turned($0).z < distance * 0.05 + 1e-6 }) { return nil }
        guard let h = Self.homography(from: corners, to: corners.map(map)) else { return nil }
        for p in corners where h[6] * p.x + h[7] * p.y + 1 <= 1e-6 { return nil }
        return h
    }

    /// Draws `src` (premultiplied RGBA bitmap of the layer flat: row 0 at flat.minY, columns across flat) into `ctx`
    /// warped by the homography `h` (layer space to warped layer space). Every device pixel is mapped back to the
    /// source and sampled bilinearly 2×2 times, so there are no seams and the edges stay antialiased.
    /// With `depth` (3D layers drawn straight into the frame), each pixel is hidden where something nearer was drawn
    /// before and, when the layer is opaque, records its own depth.
    static func drawProjective(_ src: CGContext, flat: CGRect, homography h: [Double], in ctx: CGContext,
                               depth: DepthTarget? = nil) {
        guard let sp = src.data?.assumingMemoryBound(to: UInt8.self), src.bitsPerPixel == 32 else { return }
        let sw = src.width, sh = src.height, srb = src.bytesPerRow
        let m = ctx.ctm
        // Device box of the warped layer, within what the context can show. A 3D plane reaching behind the camera can
        // cover anything: then the whole visible area is scanned and pixels whose source is behind are skipped.
        let h8 = h.count == 9 ? h[8] : 1
        var box = CGRect.null
        for p in [CGPoint(x: flat.minX, y: flat.minY), CGPoint(x: flat.maxX, y: flat.minY),
                  CGPoint(x: flat.maxX, y: flat.maxY), CGPoint(x: flat.minX, y: flat.maxY)] {
            let w = h[6] * p.x + h[7] * p.y + h8
            guard w > View3D.near * 1e-3 else { box = .infinite; break }
            let q = CGPoint(x: (h[0] * p.x + h[1] * p.y + h[2]) / w, y: (h[3] * p.x + h[4] * p.y + h[5]) / w)
            box = box.union(CGRect(origin: q.applying(m), size: .zero))
        }
        box = box.intersection(ctx.boundingBoxOfClipPath.applying(m)).integral
        guard !box.isNull, box.width >= 1, box.height >= 1, box.width * box.height <= 8192 * 8192,
              let inv = invert3(h) else { return }
        let dw = Int(box.width), dh = Int(box.height)
        guard let dst = CGContext(data: nil, width: dw, height: dh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: src.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let dp = dst.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let drb = dst.bytesPerRow
        // device px → layer (inverse CTM) → flat layer (inverse homography) → source px (pixel centers at integers).
        let mi = m.inverted()
        let toLayer: [Double] = [mi.a, mi.c, mi.tx, mi.b, mi.d, mi.ty, 0, 0, 1]
        let kx = Double(sw) / flat.width, ky = Double(sh) / flat.height
        let toSource: [Double] = [kx, 0, -flat.minX * kx - 0.5, 0, ky, -flat.minY * ky - 0.5, 0, 0, 1]
        let t = mul3(toSource, mul3(inv, toLayer))
        let offs: [Double] = [-0.25, 0.25]
        let zb = depth?.buffer
        @inline(__always) func texel(_ x: Int, _ y: Int) -> (Float, Float, Float, Float) {
            guard x >= 0, y >= 0, x < sw, y < sh else { return (0, 0, 0, 0) }
            let q = sp + y * srb + x * 4
            return (Float(q[0]), Float(q[1]), Float(q[2]), Float(q[3]))
        }
        for row in 0..<dh {
            let out = dp + row * drb
            let devY = Int(box.maxY) - 1 - row
            for col in 0..<dw {
                // Depth at the pixel's center (1 / w of the inverse mapping).
                var z: Float = 0
                var zi = -1
                if let zb, devY >= 0, devY < zb.height {
                    let devX = Int(box.minX) + col
                    if devX >= 0, devX < zb.width {
                        let x = Double(devX) + 0.5, y = Double(devY) + 0.5
                        let w = t[6] * x + t[7] * y + t[8]
                        guard w > 1e-12 else { continue }
                        z = Float(1 / w)
                        zi = devY * zb.width + devX
                        if zb.hides(z, at: zi) { continue }
                    }
                }
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                for oy in offs {
                    // Memory row 0 is the top of the device box (device y points up).
                    let y = Double(box.maxY) - Double(row) - 0.5 + oy
                    for ox in offs {
                        let x = Double(box.minX) + Double(col) + 0.5 + ox
                        let w = t[6] * x + t[7] * y + t[8]
                        guard w > 1e-9 else { continue }
                        let sx = (t[0] * x + t[1] * y + t[2]) / w, sy = (t[3] * x + t[4] * y + t[5]) / w
                        guard sx > -1, sy > -1, sx < Double(sw), sy < Double(sh) else { continue }
                        let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                        let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                        let p00 = texel(x0, y0), p10 = texel(x0 + 1, y0), p01 = texel(x0, y0 + 1), p11 = texel(x0 + 1, y0 + 1)
                        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                        r += p00.0 * w00 + p10.0 * w10 + p01.0 * w01 + p11.0 * w11
                        g += p00.1 * w00 + p10.1 * w10 + p01.1 * w01 + p11.1 * w11
                        b += p00.2 * w00 + p10.2 * w10 + p01.2 * w01 + p11.2 * w11
                        a += p00.3 * w00 + p10.3 * w10 + p01.3 * w01 + p11.3 * w11
                    }
                }
                guard a > 0 else { continue }
                if zi >= 0, depth!.writes, a >= 2 * 255 { zb!.record(z, at: zi) }
                let q = out + col * 4
                q[0] = UInt8(min(255, r / 4 + 0.5)); q[1] = UInt8(min(255, g / 4 + 0.5))
                q[2] = UInt8(min(255, b / 4 + 0.5)); q[3] = UInt8(min(255, a / 4 + 0.5))
            }
        }
        guard let image = dst.makeImage() else { return }
        ctx.saveGState()
        ctx.concatenate(mi) // device space: the image lands on whole pixels, no resampling
        ctx.draw(image, in: box)
        ctx.restoreGState()
    }

    /// Row-major 3×3 product a·b (a homography given as 8 values gets h8 = 1).
    static func mul3(_ a: [Double], _ b: [Double]) -> [Double] {
        let a = a.count == 8 ? a + [1] : a, b = b.count == 8 ? b + [1] : b
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j] } }
        return r
    }

    /// Inverse of a homography [h0…h7] (h8 = 1), as 9 values; nil when singular.
    private static func invert3(_ h: [Double]) -> [Double]? {
        let m = h.count == 8 ? h + [1] : h
        let c00 = m[4] * m[8] - m[5] * m[7], c01 = m[5] * m[6] - m[3] * m[8], c02 = m[3] * m[7] - m[4] * m[6]
        let det = m[0] * c00 + m[1] * c01 + m[2] * c02
        guard abs(det) > 1e-12 else { return nil }
        let r: [Double] = [c00, m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
                           c01, m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
                           c02, m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3]]
        return r.map { $0 / det }
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

/// Depth of what the 3D layers drawn so far show at each device pixel of the frame (camera-space z; +∞ = nothing yet).
/// 3D layers are sorted far to near, so this only matters where that order is wrong: intersecting planes, a floor
/// reaching under a card, a model passing through a layer.
final class DepthBuffer {
    let width: Int
    let height: Int
    private var data: [Float]

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        data = [Float](repeating: .infinity, count: width * height)
    }

    func reset() {
        data.withUnsafeMutableBufferPointer { $0.update(repeating: .infinity) }
    }

    /// Something nearer than `z` is already at index `i` (with a little slack for layers that touch).
    @inline(__always) func hides(_ z: Float, at i: Int) -> Bool {
        z > data[i] * 1.002 + 0.5
    }

    /// The farthest depth still drawn at index `i` (+∞ = anything).
    @inline(__always) func limit(at i: Int) -> Float {
        data[i] * 1.002 + 0.5
    }

    @inline(__always) func record(_ z: Float, at i: Int) {
        if z < data[i] { data[i] = z }
    }
}

/// Where a 3D layer meets the frame's depth buffer: `writes` when it is opaque enough to hide what is behind it.
struct DepthTarget {
    var buffer: DepthBuffer
    var writes: Bool
}
