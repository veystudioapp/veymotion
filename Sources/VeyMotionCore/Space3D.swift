import CoreGraphics
import Foundation
import simd

// The scene's 3D space. Scene pixels on x/y (origin top-left, y down) and z pointing away from the viewer, so a
// layer at z 0 seen by the default camera looks exactly as it would in 2D. `threeD` layers, `model` layers and the
// children of a 3D group live here: each gets a 4×4 world matrix (its parents included), the camera's view matrix
// turns that into camera space, and a pinhole projection maps it to the frame. A planar layer's whole projection is
// one homography, so the renderer can reuse the projective warp of `Mesh.swift`; models go through `Raster3D`.

typealias Mat4 = simd_double4x4

extension simd_double4x4 {
    static func translation(_ x: Double, _ y: Double, _ z: Double) -> Mat4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4(x, y, z, 1)
        return m
    }

    static func scaling(_ x: Double, _ y: Double, _ z: Double) -> Mat4 { Mat4(diagonal: SIMD4(x, y, z, 1)) }

    /// + tips the top (y < 0) away from the viewer (z > 0), like the 2.5D `rotationX`.
    static func rotationX(degrees d: Double) -> Mat4 {
        let a = d * .pi / 180, c = cos(a), s = sin(a)
        return Mat4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)])
    }

    /// + turns the right side (x > 0) away from the viewer, like the 2.5D `rotationY`.
    static func rotationY(degrees d: Double) -> Mat4 {
        let a = d * .pi / 180, c = cos(a), s = sin(a)
        return Mat4(rows: [SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)])
    }

    /// Clockwise on screen (y down), like `rotation`.
    static func rotationZ(degrees d: Double) -> Mat4 {
        let a = d * .pi / 180, c = cos(a), s = sin(a)
        return Mat4(rows: [SIMD4(c, -s, 0, 0), SIMD4(s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)])
    }

    /// A 2D transform acting on x/y (z untouched).
    init(affine m: CGAffineTransform) {
        self.init(rows: [SIMD4(m.a, m.c, 0, m.tx), SIMD4(m.b, m.d, 0, m.ty), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)])
    }

    func point(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let r = self * SIMD4(p, 1)
        return SIMD3(r.x, r.y, r.z)
    }
}

/// The camera as seen by 3D layers: where it looks, from how far, through which lens.
public struct View3D: Equatable, Sendable {
    /// The world point at the frame's center.
    public var target: SIMD3<Double>
    /// Distance from the camera to the target (px).
    public var distance: Double
    /// Focal length in px, zoom included: a plane at `distance` shows at focal / distance.
    public var focal: Double
    /// Degrees: orbitY turns the camera around the target to the right, orbitX raises it (looking down).
    public var orbitX: Double
    public var orbitY: Double
    /// Degrees, clockwise (the camera's `rotation`).
    public var roll: Double
    /// The frame's center in scene px.
    public var center: CGPoint

    /// Nearest camera depth drawn (px).
    public static let near = 1.0

    /// World → camera space (x right, y down, z = depth in front of the camera).
    var matrix: Mat4 {
        Mat4.translation(0, 0, distance) * Mat4.rotationX(degrees: -orbitX) * Mat4.rotationY(degrees: -orbitY)
            * Mat4.translation(-target.x, -target.y, -target.z)
    }

    /// Row-major 3×3: camera-space point → homogeneous scene point (its w is the depth).
    var projection: [Double] {
        let r = roll * .pi / 180, c = cos(r), s = sin(r)
        return [focal * c, -focal * s, center.x,
                focal * s, focal * c, center.y,
                0, 0, 1]
    }

    /// Scene point of a camera-space point, nil when it is behind the near plane.
    public func project(_ p: SIMD3<Double>) -> CGPoint? {
        guard p.z > Self.near else { return nil }
        let h = projection
        return CGPoint(x: (h[0] * p.x + h[1] * p.y) / p.z + h[2], y: (h[3] * p.x + h[4] * p.y) / p.z + h[5])
    }
}

/// Where a 3D layer lands in the frame at one time.
public struct LayerProjection {
    /// Layer-local → world.
    var world: Mat4
    public var view: View3D
    /// Row-major 3×3: layer-local (u, v, 1) on the layer's plane → homogeneous scene point. Not normalized: its w is
    /// the camera depth, positive in front of the camera.
    public var homography: [Double]
    /// Camera depth of the layer's origin (px in front of the camera).
    public var depth: Double
    /// The layer's front (the side facing the viewer at rest) is turned away from the camera.
    public var facesAway: Bool

    init(world: Mat4, view: View3D) {
        self.world = world
        self.view = view
        let mv = view.matrix * world
        let c0 = mv.columns.0, c1 = mv.columns.1, c3 = mv.columns.3
        let p = view.projection
        var h = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            let row = SIMD3(p[r * 3], p[r * 3 + 1], p[r * 3 + 2])
            h[r * 3] = simd_dot(row, SIMD3(c0.x, c0.y, c0.z))
            h[r * 3 + 1] = simd_dot(row, SIMD3(c1.x, c1.y, c1.z))
            h[r * 3 + 2] = simd_dot(row, SIMD3(c3.x, c3.y, c3.z))
        }
        homography = h
        depth = c3.z
        // The camera (camera-space origin) as seen from the layer: behind its plane (local z > 0) = looking at its back.
        let det = simd_determinant(mv)
        if abs(det) > 1e-12 {
            let cam = mv.inverse * SIMD4(0, 0, 0, 1)
            facesAway = cam.z / cam.w > 0
        } else {
            facesAway = false
        }
    }

    /// Model-view matrix (layer-local → camera space).
    var modelView: Mat4 { view.matrix * world }

    /// Scene point of a layer-local point on its plane, nil behind the camera.
    public func scenePoint(_ p: CGPoint) -> CGPoint? {
        let h = homography
        let w = h[6] * p.x + h[7] * p.y + h[8]
        guard w > View3D.near else { return nil }
        return CGPoint(x: (h[0] * p.x + h[1] * p.y + h[2]) / w, y: (h[3] * p.x + h[4] * p.y + h[5]) / w)
    }

    /// Scene point of a layer-local 3D point, nil behind the camera.
    public func scenePoint(_ p: SIMD3<Double>) -> CGPoint? {
        view.project(modelView.point(p))
    }
}

extension MotionLayer {
    /// Drawn in the scene's 3D space: `threeD` layers and models (particles and audio never are).
    public var is3D: Bool {
        type == .model || (threeD && type != .particles && type != .audio)
    }

    /// Layer-local → parent space in 3D. A 2D layer is its flat transform (z untouched) unless `force3D` (the
    /// children of a 3D group, which all live in 3D).
    func localMatrix(at t: Double, force3D: Bool = false) -> Mat4 {
        guard is3D || force3D else { return Mat4(affine: localTransform(at: t)) }
        let pos = position(at: t)
        let ax = value(.anchorX, at: t), ay = value(.anchorY, at: t)
        let s = value(.scale, at: t)
        let sx = s * value(.scaleX, at: t), sy = s * value(.scaleY, at: t), sz = s * value(.scaleZ, at: t)
        func tanDeg(_ d: Double) -> Double { tan(min(max(d, -85), 85) * .pi / 180) }
        let skew = Mat4(affine: CGAffineTransform(a: 1, b: tanDeg(value(.skewY, at: t)), c: tanDeg(value(.skewX, at: t)),
                                                  d: 1, tx: 0, ty: 0))
        // After Effects order: scale, then X, Y and Z rotation, around the anchor.
        return Mat4.translation(pos.point.x + ax, pos.point.y + ay, value(.z, at: t))
            * Mat4.rotationZ(degrees: value(.rotation, at: t) + pos.pathAngle)
            * Mat4.rotationY(degrees: value(.rotationY, at: t))
            * Mat4.rotationX(degrees: value(.rotationX, at: t))
            * skew * Mat4.scaling(sx, sy, sz) * Mat4.translation(-ax, -ay, 0)
    }
}

extension MotionScene {
    /// Default focal length of the 3D camera (px): the longer side of the frame, a moderate perspective.
    public var defaultLens: Double { Double(max(width, height)) }

    /// The camera as 3D layers see it (`fixed` layers: the default camera, which shows z 0 as drawn).
    public func view3D(fixed: Bool = false, at t: Double) -> View3D {
        let center = CGPoint(x: Double(width) / 2, y: Double(height) / 2)
        guard let cam = camera?.resolved(in: self), !fixed else {
            return View3D(target: SIMD3(center.x, center.y, 0), distance: defaultLens, focal: defaultLens,
                          orbitX: 0, orbitY: 0, roll: 0, center: center)
        }
        let lens = cam.lens.map { max(1, cam.value("lens", $0, at: t)) } ?? defaultLens
        let distance = cam.distance.map { cam.value("distance", $0, at: t) } ?? lens
        let zoom = max(0.01, cam.value("zoom", cam.zoom, at: t))
        return View3D(target: SIMD3(cam.value("x", cam.x, at: t), cam.value("y", cam.y, at: t), cam.value("z", cam.z, at: t)),
                      distance: distance, focal: lens * zoom,
                      orbitX: cam.value("orbitX", cam.orbitX, at: t), orbitY: cam.value("orbitY", cam.orbitY, at: t),
                      roll: cam.value("rotation", cam.rotation, at: t), center: center)
    }

    /// Layer-local → this scene's 3D space: own transform, a repeater step `copy`, then the chain of parents.
    func matrix3D(of layer: MotionLayer, at t: Double, copy: CGAffineTransform? = nil, force3D: Bool = false) -> Mat4 {
        var m = layer.localMatrix(at: t, force3D: force3D)
        if let copy { m = Mat4(affine: copy) * m }
        var seen: Set<String> = [layer.id]
        var next = layer.parent
        while let pid = next, !seen.contains(pid), let p = layers.first(where: { $0.id == pid }) {
            m = p.localMatrix(at: t, force3D: force3D) * m
            seen.insert(pid)
            next = p.parent
        }
        return m
    }

    /// Where a top-level 3D layer lands in the frame (nil for 2D layers).
    public func projection(of layer: MotionLayer, at t: Double) -> LayerProjection? {
        guard layer.is3D else { return nil }
        return LayerProjection(world: matrix3D(of: layer, at: t), view: view3D(fixed: layer.fixed, at: t))
    }

    /// Outline of a top-level 3D layer's box in scene px (its plane's rectangle, or a model's bounding box edges),
    /// for the canvas selection. nil for 2D layers or when the box is behind the camera.
    public func outline3D(of layer: MotionLayer, box: CGRect, depth: Double = 0, at t: Double) -> CGPath? {
        guard let p = projection(of: layer, at: t) else { return nil }
        let path = CGMutablePath()
        if depth > 0 {
            let z0 = -depth / 2, z1 = depth / 2
            let c = [(box.minX, box.minY), (box.maxX, box.minY), (box.maxX, box.maxY), (box.minX, box.maxY)]
            let front = c.map { p.scenePoint(SIMD3($0.0, $0.1, z0)) }, back = c.map { p.scenePoint(SIMD3($0.0, $0.1, z1)) }
            guard !front.contains(where: { $0 == nil }), !back.contains(where: { $0 == nil }) else { return nil }
            path.addLines(between: front.map { $0! }); path.closeSubpath()
            path.addLines(between: back.map { $0! }); path.closeSubpath()
            for i in 0..<4 { path.move(to: front[i]!); path.addLine(to: back[i]!) }
            return path
        }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                       CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].map(p.scenePoint)
        guard !corners.contains(where: { $0 == nil }) else { return nil }
        path.addLines(between: corners.map { $0! })
        path.closeSubpath()
        return path
    }
}

extension MotionLayer {
    /// A model's box in layer px (at rest) and its depth, for selection outlines. Text is measured with its font;
    /// files are taken as a cube of `width`.
    public func modelExtent(at t: Double) -> (box: CGRect, depth: Double) {
        let w = max(shapeWidth(at: t), 0), h = max(shapeHeight(at: t), 0)
        func centered(_ w: Double, _ h: Double) -> CGRect { CGRect(x: -w / 2, y: -h / 2, width: w, height: h) }
        switch model.shape {
        case .box: return (centered(w, h), model.depth ?? min(w, h))
        case .plane: return (centered(w, h), 0)
        case .sphere, .cylinder, .cone: return (centered(w, h), model.depth ?? w)
        case .torus: return (centered(w, w), (model.radius ?? 0.3) * w)
        case .path: return (pathShape(at: t).cgPath.boundingBoxOfPath, model.depth ?? 40)
        case .lathe:
            let b = pathShape(at: t).cgPath.boundingBoxOfPath
            guard !b.isNull else { return (.zero, 0) }
            let r = max(abs(b.minX), abs(b.maxX))
            return (CGRect(x: -r, y: b.minY, width: 2 * r, height: b.height), 2 * r)
        case .file:
            let s = w > 0 ? w : 400
            return (centered(s, s), s)
        case .text:
            var copy = self
            copy.type = .text
            copy.textAnimators = []
            copy.textPath = nil
            let key = "\(text)|\(fontName ?? "")|\(fontWeight)|\(fontSize)|\(align)|\(maxWidth ?? 0)|\(value(.letterSpacing, at: t))"
            let box = TextExtentCache.shared.box(key) {
                var b = CGRect.null
                for g in FrameRenderer().glyphPaths(copy, at: t) { b = b.union(g.path.boundingBoxOfPath) }
                return b.isNull ? .zero : b
            }
            return (box, model.depth ?? fontSize * 0.3)
        }
    }
}

/// Measured 3D text boxes (the canvas asks for the selected one on every redraw).
private final class TextExtentCache: @unchecked Sendable {
    static let shared = TextExtentCache()
    private let lock = NSLock()
    private var boxes: [String: CGRect] = [:]

    func box(_ key: String, measure: () -> CGRect) -> CGRect {
        if let b = lock.withLock({ boxes[key] }) { return b }
        let b = measure()
        lock.withLock {
            if boxes.count > 64 { boxes.removeAll() }
            boxes[key] = b
        }
        return b
    }
}
