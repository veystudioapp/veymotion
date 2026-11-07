import CoreGraphics
import Foundation

// Path operators on shape layers (After Effects' Offset Paths, Zig Zag, Wiggle Paths, Pucker & Bloat) and
// tapered strokes. They work on flattened polylines and give back a PathShape, so trim paths, gradients and
// morph keyframes keep working on the result.

struct PathOps {
    var offset = 0.0, zigzag = 0.0, wiggle = 0.0, pucker = 0.0
    var spacing = 60.0, speed = 1.0, time = 0.0
    var seed: UInt64 = 0

    init(_ layer: MotionLayer, at t: Double) {
        offset = layer.value(.offsetPath, at: t)
        zigzag = layer.value(.zigzag, at: t)
        wiggle = layer.value(.wigglePath, at: t)
        pucker = min(max(layer.value(.pucker, at: t), -1), 1)
        spacing = max(4, layer.value(.waveLength, at: t) / 2)
        speed = layer.value(.waveSpeed, at: t)
        time = t
        seed = Noise.hash("pathops.\(layer.id)")
    }

    var isActive: Bool { abs(offset) > 0.01 || abs(zigzag) > 0.01 || abs(wiggle) > 0.01 || abs(pucker) > 0.001 }

    /// How far the operators can move the outline, in layer px.
    var reach: Double { abs(offset) + abs(zigzag) + abs(wiggle) }

    func apply(to shape: PathShape) -> PathShape {
        var subs = shape.subpaths.filter { !$0.segments.isEmpty }
        if abs(pucker) > 0.001 { subs = subs.map { Self.pucker($0, pucker) } }
        guard abs(offset) > 0.01 || abs(zigzag) > 0.01 || abs(wiggle) > 0.01 else { return PathShape(subpaths: subs) }
        return PathShape(subpaths: subs.enumerated().map { i, s in
            var pts = Self.flatten(s)
            if abs(offset) > 0.01 { pts = Self.offset(pts, by: offset, closed: s.closed) }
            var smooth = true
            if abs(zigzag) > 0.01 { pts = Self.zigzag(pts, amplitude: zigzag, spacing: spacing, closed: s.closed); smooth = false }
            if abs(wiggle) > 0.01 {
                pts = Self.wiggle(pts, amplitude: wiggle, spacing: spacing, closed: s.closed,
                                  z: time * speed, seed: seed &+ UInt64(i))
                smooth = true
            }
            return Self.subpath(pts, closed: s.closed, smooth: smooth && abs(zigzag) < 0.01)
        })
    }

    // MARK: Pucker & bloat: anchor points move toward (or away from) the center, control points stay.

    static func pucker(_ s: Subpath, _ k: Double) -> Subpath {
        let pts = [s.start] + s.segments.map(\.p)
        let c = PathPoint(x: pts.map(\.x).reduce(0, +) / Double(pts.count), y: pts.map(\.y).reduce(0, +) / Double(pts.count))
        func move(_ p: PathPoint) -> PathPoint { PathPoint(x: p.x + (c.x - p.x) * k, y: p.y + (c.y - p.y) * k) }
        func push(_ q: PathPoint) -> PathPoint { PathPoint(x: q.x - (c.x - q.x) * k * 0.6, y: q.y - (c.y - q.y) * k * 0.6) }
        var out = s
        out.start = move(s.start)
        for i in out.segments.indices {
            out.segments[i].p = move(s.segments[i].p)
            // Control points go the other way, so the sides bulge between the pulled-in corners.
            out.segments[i].c1 = push(s.segments[i].c1)
            out.segments[i].c2 = push(s.segments[i].c2)
        }
        return out
    }

    // MARK: Polylines

    /// Points along the subpath about every 3 px (closed paths do not repeat the start).
    static func flatten(_ s: Subpath, step: Double = 3) -> [CGPoint] {
        var out = [CGPoint(x: s.start.x, y: s.start.y)]
        var from = s.start
        for seg in s.segments {
            let n = max(1, Int((Subpath.length(from, seg, steps: 8) / step).rounded(.up)))
            for k in 1...n {
                let p = Subpath.point(from, seg, Double(k) / Double(n))
                out.append(CGPoint(x: p.x, y: p.y))
            }
            from = seg.p
        }
        if s.closed, out.count > 1, hypot(out[0].x - out.last!.x, out[0].y - out.last!.y) < 1e-6 { out.removeLast() }
        return out
    }

    /// Outward normal at each point (for closed paths; the left-hand normal for open ones).
    static func normals(_ pts: [CGPoint], closed: Bool) -> [CGPoint] {
        let n = pts.count
        guard n >= 2 else { return pts.map { _ in CGPoint(x: 0, y: -1) } }
        // Orientation: positive area in y-down coordinates means clockwise on screen.
        var area = 0.0
        if closed { for i in 0..<n { let a = pts[i], b = pts[(i + 1) % n]; area += a.x * b.y - b.x * a.y } }
        let sign: Double = closed && area > 0 ? 1 : -1
        return (0..<n).map { i in
            let prev = pts[closed ? (i + n - 1) % n : max(i - 1, 0)], next = pts[closed ? (i + 1) % n : min(i + 1, n - 1)]
            var dx = next.x - prev.x, dy = next.y - prev.y
            let len = hypot(dx, dy)
            if len < 1e-9 { dx = 1; dy = 0 } else { dx /= len; dy /= len }
            // Left-hand normal of the direction, flipped to point outward for clockwise loops.
            return CGPoint(x: dy * sign, y: -dx * sign)
        }
    }

    static func offset(_ pts: [CGPoint], by d: Double, closed: Bool) -> [CGPoint] {
        let ns = normals(pts, closed: closed)
        return zip(pts, ns).map { CGPoint(x: $0.x + $1.x * d, y: $0.y + $1.y * d) }
    }

    /// Resamples the polyline every `spacing` px (the last point kept for open paths).
    static func resample(_ pts: [CGPoint], spacing: Double, closed: Bool) -> [CGPoint] {
        guard pts.count >= 2 else { return pts }
        var loop = pts
        if closed { loop.append(pts[0]) }
        var lengths = [0.0]
        for i in 1..<loop.count { lengths.append(lengths[i - 1] + hypot(loop[i].x - loop[i - 1].x, loop[i].y - loop[i - 1].y)) }
        let total = lengths.last ?? 0
        guard total > spacing else { return pts }
        let count = max(2, Int((total / spacing).rounded()))
        let step = total / Double(count)
        var out: [CGPoint] = []
        var j = 0
        for k in 0..<(closed ? count : count + 1) {
            let d = min(Double(k) * step, total)
            while j < lengths.count - 2 && lengths[j + 1] < d { j += 1 }
            let seg = lengths[j + 1] - lengths[j]
            let f = seg > 0 ? (d - lengths[j]) / seg : 0
            out.append(CGPoint(x: loop[j].x + (loop[j + 1].x - loop[j].x) * f, y: loop[j].y + (loop[j + 1].y - loop[j].y) * f))
        }
        return out
    }

    static func zigzag(_ pts: [CGPoint], amplitude: Double, spacing: Double, closed: Bool) -> [CGPoint] {
        var re = resample(pts, spacing: spacing, closed: closed)
        if closed, re.count % 2 == 1 { re = resample(pts, spacing: spacing * Double(re.count) / Double(re.count + 1), closed: true) }
        let ns = normals(re, closed: closed)
        return re.indices.map { i in
            let s: Double = i % 2 == 0 ? 1 : -1
            return CGPoint(x: re[i].x + ns[i].x * amplitude * s, y: re[i].y + ns[i].y * amplitude * s)
        }
    }

    static func wiggle(_ pts: [CGPoint], amplitude: Double, spacing: Double, closed: Bool, z: Double, seed: UInt64) -> [CGPoint] {
        let re = resample(pts, spacing: spacing, closed: closed)
        let ns = normals(re, closed: closed)
        return re.indices.map { i in
            let k = Noise.value3(Double(i) * 0.37, z, 0, seed: seed).v
            return CGPoint(x: re[i].x + ns[i].x * amplitude * k, y: re[i].y + ns[i].y * amplitude * k)
        }
    }

    /// Polyline back to a subpath: straight segments, or a Catmull-Rom curve through the points.
    static func subpath(_ pts: [CGPoint], closed: Bool, smooth: Bool) -> Subpath {
        guard let first = pts.first else { return Subpath(start: PathPoint(x: 0, y: 0), segments: [], closed: closed) }
        func pp(_ c: CGPoint) -> PathPoint { PathPoint(x: c.x, y: c.y) }
        let n = pts.count
        var segs: [CubicSegment] = []
        let count = closed ? n : n - 1
        for i in 0..<count {
            let p1 = pts[i], p2 = pts[(i + 1) % n]
            if smooth {
                let p0 = pts[closed ? (i + n - 1) % n : max(i - 1, 0)], p3 = pts[closed ? (i + 2) % n : min(i + 2, n - 1)]
                segs.append(CubicSegment(c1: PathPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                                         c2: PathPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6), p: pp(p2)))
            } else {
                segs.append(.line(pp(p1), pp(p2)))
            }
        }
        return Subpath(start: pp(first), segments: segs, closed: closed)
    }

    // MARK: Tapered strokes

    /// A stroke that thins to a point over the first `taperStart` and last `taperEnd` of what is drawn, as a filled
    /// polygon. `from`/`to` (0…1 of the piece's length, `to` may exceed 1 to wrap) select the drawn part.
    static func taperedStroke(_ s: Subpath, width: Double, from: Double, to: Double, taperStart: Double, taperEnd: Double) -> CGPath {
        let path = CGMutablePath()
        var pts = flatten(s, step: 2)
        if s.closed, let f = pts.first { pts.append(f) }
        guard pts.count >= 2 else { return path }
        var lengths = [0.0]
        for i in 1..<pts.count { lengths.append(lengths[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let total = lengths.last ?? 0
        guard total > 0 else { return path }
        func point(_ d: Double) -> CGPoint {
            var dd = d
            if s.closed { dd = dd - floor(dd / total) * total } else { dd = min(max(dd, 0), total) }
            var lo = 0, hi = lengths.count - 1
            while hi - lo > 1 { let mid = (lo + hi) / 2; if lengths[mid] <= dd { lo = mid } else { hi = mid } }
            let seg = lengths[hi] - lengths[lo], f = seg > 0 ? (dd - lengths[lo]) / seg : 0
            return CGPoint(x: pts[lo].x + (pts[hi].x - pts[lo].x) * f, y: pts[lo].y + (pts[hi].y - pts[lo].y) * f)
        }
        let a = from * total, b = to * total
        guard b > a + 0.5 else { return path }
        let n = max(2, Int((b - a) / 2))
        var left: [CGPoint] = [], right: [CGPoint] = []
        for k in 0...n {
            let u = Double(k) / Double(n)
            let d = a + (b - a) * u
            let p = point(d), q = point(d + 1), r = point(d - 1)
            var dx = q.x - r.x, dy = q.y - r.y
            let len = hypot(dx, dy)
            if len < 1e-9 { dx = 1; dy = 0 } else { dx /= len; dy /= len }
            var w = 1.0
            if taperStart > 0.001 { w = min(w, u / taperStart) }
            if taperEnd > 0.001 { w = min(w, (1 - u) / taperEnd) }
            let h = max(0, w) * width / 2
            left.append(CGPoint(x: p.x - dy * h, y: p.y + dx * h))
            right.append(CGPoint(x: p.x + dy * h, y: p.y - dx * h))
        }
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        return path
    }
}

// MARK: - Text to paths, boolean combinations

public enum PathCombine: String, CaseIterable, Codable, Sendable {
    case union, subtract, intersect, exclude
}

extension MotionScene {
    /// Replaces a text layer by a path layer of its letters (or, with `letters`, a group with one path per letter,
    /// each centered on its letter so it can move and turn on its own). Fill keeps the text color; trim, morph,
    /// zigzag and every path tool then work on the text.
    @discardableResult
    public mutating func textToPath(_ id: String, letters: Bool, at t: Double) throws -> String {
        let i = try layerIndex(id)
        let text = layers[i]
        guard text.type == .text else { throw SceneError.invalid("'\(id)' is not a text layer") }
        let glyphs = FrameRenderer().glyphPaths(text, at: t)
        guard !glyphs.isEmpty else { throw SceneError.invalid("'\(id)' has no visible letters") }
        func pathLayer(_ path: CGPath, id: String, name: String) -> MotionLayer {
            var l = text
            l.type = .path
            l.id = id
            l.name = name
            l.d = .constant(PathShape(subpaths: PathParser.subpaths(of: path)))
            l.fill = text.color
            l.stroke = text.stroke
            if text.stroke == nil { l.strokeWidth = .constant(0) }
            l.fillRule = .nonzero
            l.textAnimators = []
            l.textPath = nil
            return l
        }
        if !letters {
            let all = CGMutablePath()
            for g in glyphs { all.addPath(g.path) }
            layers[i] = pathLayer(all, id: text.id, name: text.name)
            return text.id
        }
        var group = text
        group.type = .group
        group.width = nil; group.height = nil
        group.textAnimators = []
        let cx = Double(width) / 2, cy = Double(height) / 2
        var children: [MotionLayer] = []
        var seen = Set(allLayers.map(\.id))
        for (k, g) in glyphs.enumerated() {
            var m = CGAffineTransform(translationX: -g.center.x, y: -g.center.y)
            guard let centered = g.path.copy(using: &m) else { continue }
            var c = MotionLayer(type: .path)
            c.d = .constant(PathShape(subpaths: PathParser.subpaths(of: centered)))
            c.fill = text.color
            c.stroke = text.stroke
            c.strokeWidth = text.stroke == nil ? .constant(0) : text.strokeWidth
            c.gradient = text.gradient
            c.x = .constant(cx + g.center.x)
            c.y = .constant(cy + g.center.y)
            c.start = text.start
            c.end = text.end
            var cid = "\(text.id)-\(k + 1)"
            var n = 2
            while seen.contains(cid) { cid = "\(text.id)-\(k + 1)-\(n)"; n += 1 }
            seen.insert(cid)
            c.id = cid
            c.name = "Letter \(k + 1)"
            children.append(c)
        }
        group.children = children
        // Effects stay on the group; the letters only carry their shapes.
        group.gradient = nil
        layers[i] = group
        return text.id
    }

    /// Combines the outlines of shapes, paths and texts (union, the first minus the rest, intersection, or
    /// exclusion) into a new path layer placed where they are. The sources are removed unless `keep`.
    @discardableResult
    public mutating func combinePaths(_ ids: [String], op: PathCombine, id newId: String?, keep: Bool, at t: Double) throws -> String {
        guard ids.count >= 2 else { throw SceneError.invalid("Give at least two layer ids") }
        let renderer = FrameRenderer()
        var outlines: [CGPath] = []
        for lid in ids {
            let l = try layer(lid)
            let local: CGPath
            switch l.type {
            case .rect:
                let w = l.shapeWidth(at: t), h = l.shapeHeight(at: t), r = max(0, min(l.value(.cornerRadius, at: t), w / 2, h / 2))
                local = CGPath(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
            case .ellipse:
                let w = l.shapeWidth(at: t), h = l.shapeHeight(at: t)
                local = CGPath(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), transform: nil)
            case .path:
                local = l.pathShape(at: t).cgPath
            case .text:
                let all = CGMutablePath()
                for g in renderer.glyphPaths(l, at: t) { all.addPath(g.path) }
                local = all
            default:
                throw SceneError.invalid("'\(lid)' is a \(l.type.rawValue) layer: combine rect, ellipse, path or text layers")
            }
            var m = sceneTransform(of: l, at: t)
            guard let world = local.copy(using: &m) else { continue }
            outlines.append(world)
        }
        guard var result = outlines.first else { throw SceneError.invalid("Nothing to combine") }
        for other in outlines.dropFirst() {
            switch op {
            case .union: result = result.union(other)
            case .subtract: result = result.subtracting(other)
            case .intersect: result = result.intersection(other)
            case .exclude: result = result.symmetricDifference(other)
            }
        }
        let box = result.boundingBoxOfPath
        guard !box.isNull, box.width > 0 || box.height > 0 else { throw SceneError.invalid("The result is empty") }
        var center = CGAffineTransform(translationX: -box.midX, y: -box.midY)
        guard let local = result.copy(using: &center) else { throw SceneError.invalid("The result is empty") }
        let first = try layer(ids[0])
        var l = MotionLayer(id: newId ?? "\(ids[0])-\(op.rawValue)", name: newId ?? "Combined", type: .path, x: box.midX, y: box.midY)
        l.d = .constant(PathShape(subpaths: PathParser.subpaths(of: local)))
        l.fill = first.type == .text ? first.color : first.fill
        l.stroke = first.stroke
        l.strokeWidth = first.stroke == nil ? .constant(0) : first.strokeWidth
        l.gradient = first.gradient
        l.start = first.start
        l.end = first.end
        let index = layers.firstIndex { $0.id == ids[0] }
        if !keep { for lid in ids where layers.contains(where: { $0.id == lid }) { try removeLayer(lid) } }
        return addLayer(l, at: index.map { min($0, layers.count) })
    }
}
