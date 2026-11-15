import CoreGraphics
import Foundation

// Picking and moving layers on the canvas: what a layer covers in the frame, which layer a click means, and a drag
// in frame px turned into the layer's own x/y.

extension FrameRenderer {
    /// What one content layer covers in the frame (scene px), with the top-level layer a click on it selects.
    struct Footprint {
        var top: String
        var path: CGPath
        var area: Double
    }

    /// The box a layer is picked and outlined by, in its own space: the text box for text (its drawing bounds are
    /// padded by a font size for overhang), else what it draws.
    func pickBox(_ layer: MotionLayer, scene: MotionScene, at t: Double) -> CGRect? {
        if layer.type == .model { return layer.modelExtent(at: t).box }
        if layer.type == .text, layer.textPath == nil, layer.is3D || !layer.rotationXYOrPinned {
            guard let box = textLayout(layer, at: t)?.box else { return nil }
            return CGRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height)
        }
        // A 3D layer's warp needs the renderer's per-frame state: take its flat box, projected by the caller.
        let box = layer.is3D ? flatContentBounds(layer, scene: scene, at: t) : contentBounds(layer, scene: scene, at: t)
        guard let box, !box.isNull, box.width > 0, box.height > 0 else { return nil }
        return box
    }

    /// The content layers on screen at `t`, bottom to top, each with its outline in the frame. Children of groups
    /// count for their top-level group; the look's layers, mattes and sound have none. `picking` also leaves out
    /// what a click should pass through: layers that are faded or wiped out, and particles.
    func footprints(in scene: MotionScene, at t: Double, only top: String? = nil, picking: Bool) -> [Footprint] {
        let matteSources = Set(scene.allLayers.compactMap { l in l.matte.flatMap { $0.source == l.id ? nil : $0.source } })
        var out: [Footprint] = []
        for p in scene.placedLayers() {
            let topId = p.chain.first?.group.id ?? p.layer.id
            if let top, top != topId { continue }
            guard let span = scene.span(of: p), t >= span.start, t < span.end + 1e-9,
                  !matteSources.contains(p.layer.id), !p.chain.contains(where: { matteSources.contains($0.group.id) })
            else { continue }
            let own = t - p.offset
            if p.layer.type == .particles, picking || p.layer.particles.usesWorldSpace { continue }
            if picking, scene.opacity(of: p, at: t) < 0.02 || p.layer.value(.wipe, at: own) > 0.98 { continue }
            guard let box = pickBox(p.layer, scene: scene, at: own) else { continue }
            let path: CGPath
            if p.chain.isEmpty, p.layer.is3D {
                let depth = p.layer.type == .model ? p.layer.modelExtent(at: own).depth : 0
                guard let outline = scene.outline3D(of: p.layer, box: box, depth: depth, at: own) else { continue }
                path = outline
            } else {
                var m = scene.frameTransform(of: p, at: t)
                path = CGPath(rect: box, transform: &m)
            }
            let bounds = path.boundingBoxOfPath
            out.append(Footprint(top: topId, path: path, area: Double(bounds.width * bounds.height)))
        }
        return out
    }

    /// The top-level layer a click at `point` (scene px) means at time `t`: the smallest thing under it (the topmost
    /// of near-equal ones), so a title wins over the card behind it and a glow laid over both. Layers that cover the
    /// frame (backgrounds, overlays, the look) are never picked: a click on them is a click on nothing.
    public func layerHit(in scene: MotionScene, at point: CGPoint, time t: Double) -> String? {
        let frame = CGRect(x: 0, y: 0, width: scene.width, height: scene.height)
        var best: Footprint?
        for f in footprints(in: scene, at: t, picking: true) where f.area >= 1 {
            let shown = f.path.boundingBoxOfPath.intersection(frame)
            guard shown.width * shown.height < 0.85 * frame.width * frame.height, f.path.contains(point) else { continue }
            if let b = best, f.area > b.area * 1.05 { continue }
            best = f
        }
        return best?.top
    }

    /// Outline of a top-level layer at time `t` in scene px: its box through its transform (projected for 3D
    /// layers), or for a group the rectangle around what its children show. nil while the layer is not on screen.
    public func selectionOutline(of id: String, in scene: MotionScene, at t: Double) -> CGPath? {
        guard let layer = scene.layers.first(where: { $0.id == id }), layer.type.isVisual,
              layer.isVisible(at: t, sceneDuration: scene.duration) else { return nil }
        let parts = footprints(in: scene, at: t, only: id, picking: false)
        if layer.type != .group, let own = parts.first { return own.path }
        if !parts.isEmpty {
            return CGPath(rect: parts.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }, transform: nil)
        }
        // The look's groups, empty groups, mattes: the layer's own box.
        guard !layer.is3D, let box = contentBounds(layer, scene: scene, at: t), !box.isNull else { return nil }
        var m = scene.worldTransform(of: layer, at: t)
        return CGPath(rect: box, transform: &m)
    }
}

extension MotionScene {
    /// Where a top-level layer's origin lands in the frame: after parents, bones and the camera, projected for 3D
    /// layers (nil behind the camera).
    func frameOrigin(of layer: MotionLayer, at t: Double) -> CGPoint? {
        if layer.is3D { return projection(of: layer, at: t)?.scenePoint(SIMD3<Double>(0, 0, 0)) }
        return CGPoint.zero.applying(worldTransform(of: layer, at: t))
    }

    /// Moves a top-level layer so that at `t` it lands `delta` frame px from where it is (a drag on the canvas).
    /// Its whole motion moves with it: every x/y keyframe, or every point of its motion path. The frame offset is
    /// turned into the layer's own x/y by measuring how the frame position answers to them, so parents, bones, the
    /// camera and 3D perspective need no cases of their own.
    public mutating func moveLayer(_ id: String, byFrame delta: CGVector, at t: Double) throws {
        let i = try layerIndex(id)
        let layer = layers[i]
        guard layer.type.isVisual else { throw SceneError.invalid("'\(id)' has no position to move") }
        let onPath = !(layer.motionPath?.points.isEmpty ?? true)
        if !onPath, let key = ["x", "y"].first(where: { layer.links[$0] != nil }), let link = layer.links[key] {
            throw SceneError.invalid("'\(id)' takes its \(key) from '\(link.layer)': move that layer instead")
        }
        func moved(_ dx: Double, _ dy: Double) -> MotionLayer {
            var m = layer
            if onPath {
                m.motionPath?.points = layer.motionPath!.points.map { PathPoint(x: $0.x + dx, y: $0.y + dy) }
            } else {
                m.x = layer.x.offset(by: dx)
                m.y = layer.y.offset(by: dy)
            }
            return m
        }
        guard let from = frameOrigin(of: layer, at: t) else {
            throw SceneError.invalid("'\(id)' is behind the camera at \(t)s")
        }
        let target = CGPoint(x: from.x + delta.dx, y: from.y + delta.dy)
        var dx = 0.0, dy = 0.0
        // Exact in one step for 2D layers (affine); perspective takes a few.
        for _ in 0..<(layer.is3D ? 4 : 1) {
            guard let p = frameOrigin(of: moved(dx, dy), at: t), let px = frameOrigin(of: moved(dx + 1, dy), at: t),
                  let py = frameOrigin(of: moved(dx, dy + 1), at: t) else { break }
            let a = Double(px.x - p.x), b = Double(py.x - p.x), c = Double(px.y - p.y), d = Double(py.y - p.y)
            let det = a * d - b * c
            guard abs(det) > 1e-9 else { throw SceneError.invalid("'\(id)' is scaled to nothing by what it is attached to") }
            let rx = Double(target.x - p.x), ry = Double(target.y - p.y)
            dx += (d * rx - b * ry) / det
            dy += (a * ry - c * rx) / det
        }
        layers[i] = moved((dx * 100).rounded() / 100, (dy * 100).rounded() / 100)
    }
}
