import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ModelIO
import simd

// Model layers: real 3D objects drawn by `Raster3D`. A model is a triangle mesh in layer px around the layer's center
// (x right, y down, z away from the viewer; its front faces the viewer at z = -depth/2), built from a primitive,
// extruded from text or a path, or loaded from a file with ModelIO. Meshes are cached by everything that shapes them.

public enum ModelShape: String, Codable, CaseIterable, Sendable {
    case box, sphere, cylinder, cone, torus, plane, text, path, lathe, file

    public var title: String {
        switch self {
        case .box: return "Box"
        case .sphere: return "Sphere"
        case .cylinder: return "Cylinder"
        case .cone: return "Cone"
        case .torus: return "Torus"
        case .plane: return "Plane"
        case .text: return "3D Text"
        case .path: return "Extruded Path"
        case .lathe: return "Lathe (Turned Profile)"
        case .file: return "Model File"
        }
    }

    /// Takes the layer's image (`path`) as a texture.
    public var isTexturable: Bool { [.box, .sphere, .cylinder, .plane, .lathe].contains(self) }

    /// Extruded shapes, which can have a bevel.
    public var isExtruded: Bool { self == .text || self == .path }
}

/// What a model layer shows and its material. Sizes come from the layer: width/height (box, plane, sphere,
/// cylinder, cone, torus), the text fields (text), `d` (path, lathe profile) or `path` (file, fitted into `width`).
public struct Model3D: Codable, Equatable, Sendable {
    public var shape: ModelShape
    /// Box depth / extrusion depth (px). Default: box = its smaller side, sphere/cylinder/cone = width,
    /// text = 0.3 × fontSize, path = 40.
    public var depth: Double?
    /// Roundness (segments around curved shapes, default 48).
    public var segments: Int?
    /// Torus: tube radius as a fraction of the outer radius (default 0.3). Cone: top radius as a fraction of the
    /// bottom one (default 0).
    public var radius: Double?
    /// Box sides, cylinder/cone caps and extrusion walls (nil = the fill).
    public var sideColor: RGBA?
    /// 0 = matte … 1 = glossy (default 0.3).
    public var shininess: Double?
    /// 0 = plastic … 1 = metal (reflects its own color and the sky; default 0).
    public var metallic: Double?
    /// Text/path: rounded edge size in px (default 0; kept within half the depth and the thinnest stroke).
    public var bevel: Double?
    /// Text/path: steps around the bevel (1 = a flat chamfer, default 3).
    public var bevelSteps: Int?
    /// File models with animations: the clip that plays, by name or number (0 = the first); nil = the first clip,
    /// "none" = the rest pose.
    public var animation: String?
    /// Clip playback rate (default 1; negative plays backwards).
    public var animationSpeed: Double?
    /// Seconds into the clip at the layer's start (default 0).
    public var animationOffset: Double?
    /// Start the clip over when it ends (default true); false holds its last pose.
    public var animationLoop: Bool?

    public init(shape: ModelShape = .box) {
        self.shape = shape
    }

    enum CodingKeys: String, CodingKey {
        case shape, depth, segments, radius, sideColor, shininess, metallic, bevel, bevelSteps
        case animation, animationSpeed, animationOffset, animationLoop
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decodeIfPresent(ModelShape.self, forKey: .shape) ?? .box
        depth = try c.decodeIfPresent(Double.self, forKey: .depth).map { max(0, $0) }
        segments = try c.decodeIfPresent(Int.self, forKey: .segments).map { min(max($0, 3), 256) }
        radius = try c.decodeIfPresent(Double.self, forKey: .radius).map { min(max($0, 0), 1) }
        sideColor = try c.decodeIfPresent(RGBA.self, forKey: .sideColor)
        shininess = try c.decodeIfPresent(Double.self, forKey: .shininess).map { min(max($0, 0), 1) }
        metallic = try c.decodeIfPresent(Double.self, forKey: .metallic).map { min(max($0, 0), 1) }
        bevel = try c.decodeIfPresent(Double.self, forKey: .bevel).map { max(0, $0) }
        bevelSteps = try c.decodeIfPresent(Int.self, forKey: .bevelSteps).map { min(max($0, 1), 12) }
        if let i = try? c.decodeIfPresent(Int.self, forKey: .animation) {
            animation = String(i)
        } else {
            animation = try c.decodeIfPresent(String.self, forKey: .animation)
        }
        animationSpeed = try c.decodeIfPresent(Double.self, forKey: .animationSpeed)
        animationOffset = try c.decodeIfPresent(Double.self, forKey: .animationOffset)
        animationLoop = try c.decodeIfPresent(Bool.self, forKey: .animationLoop)
    }

    public var animationLoopValue: Bool { animationLoop ?? true }

    /// The clip `animation` picks among `names`: nil/empty = the first, "none" = none, a name (exact, any case, or
    /// the part after "|" as in "Armature|Walk"), or a number.
    public func clipIndex(in names: [String]) -> Int? {
        guard !names.isEmpty else { return nil }
        guard let a = animation?.trimmingCharacters(in: .whitespaces), !a.isEmpty else { return 0 }
        let low = a.lowercased()
        if low == "none" { return nil }
        if let i = names.firstIndex(of: a) ?? names.firstIndex(where: { $0.lowercased() == low }) { return i }
        if let i = Int(a) { return names.indices.contains(i) ? i : nil }
        return names.firstIndex { $0.split(separator: "|").last.map { $0.lowercased() == low } ?? false }
    }

    public var shininessValue: Double { shininess ?? 0.3 }
    public var metallicValue: Double { metallic ?? 0 }
    public var segmentCount: Int { segments ?? 48 }
    public var bevelValue: Double { bevel ?? 0 }
    public var bevelStepCount: Int { bevelSteps ?? 3 }
}

public enum LightType: String, Codable, CaseIterable, Sendable {
    case ambient, directional, point
}

/// A light for model layers. directional: x/y/z is the direction the light travels (scene axes: y down, z away;
/// default (0.4, 0.6, 1) = from the upper left, in front). point: x/y/z is its position in scene px.
public struct Light: Codable, Equatable, Sendable {
    public var type: LightType
    public var color: RGBA
    public var intensity: AnimValue
    public var x: AnimValue
    public var y: AnimValue
    public var z: AnimValue

    public init(type: LightType, color: RGBA = .white, intensity: Double = 1, x: Double = 0.4, y: Double = 0.6, z: Double = 1) {
        self.type = type; self.color = color; self.intensity = .constant(intensity)
        self.x = .constant(x); self.y = .constant(y); self.z = .constant(z)
    }

    enum CodingKeys: String, CodingKey { case type, color, intensity, x, y, z }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(LightType.self, forKey: .type) ?? .directional
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? .white
        intensity = try c.decodeIfPresent(AnimValue.self, forKey: .intensity) ?? .constant(1)
        let def: (Double, Double, Double) = type == .point ? (960, 200, -800) : (0.4, 0.6, 1)
        x = try c.decodeIfPresent(AnimValue.self, forKey: .x) ?? .constant(def.0)
        y = try c.decodeIfPresent(AnimValue.self, forKey: .y) ?? .constant(def.1)
        z = try c.decodeIfPresent(AnimValue.self, forKey: .z) ?? .constant(def.2)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        if color != .white { try c.encode(color, forKey: .color) }
        try c.encode(intensity, forKey: .intensity)
        if type != .ambient {
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y); try c.encode(z, forKey: .z)
        }
    }

    /// Used when a scene has no lights: soft ambient, a key light from the upper left and a dim fill from the right.
    public static let defaults: [Light] = [
        Light(type: .ambient, intensity: 0.32),
        Light(type: .directional, intensity: 0.75, x: 0.45, y: 0.65, z: 1),
        Light(type: .directional, intensity: 0.25, x: -0.8, y: -0.1, z: 0.6),
    ]

    func shiftedKeys(by d: Double) -> Light {
        var l = self
        l.intensity = intensity.shifted(by: d); l.x = x.shifted(by: d); l.y = y.shifted(by: d); l.z = z.shifted(by: d)
        return l
    }
}

// MARK: - Meshes

/// A triangle mesh. Material slots: 0 = main (fill, texture), 1 = sides (`sideColor`), 2… = a file's materials.
final class Mesh3D {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []
    /// Material slot per triangle.
    var slots: [UInt16] = []
    /// A file's own materials (slot 2 + i).
    var fileMaterials: [(color: RGBA, texture: Texture3D?)] = []

    var isEmpty: Bool { indices.isEmpty }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = positions.first else { return (.zero, .zero) }
        var hi = lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    @discardableResult
    func vertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float> = .zero) -> UInt32 {
        positions.append(p); normals.append(n); uvs.append(uv)
        return UInt32(positions.count - 1)
    }

    func triangle(_ a: UInt32, _ b: UInt32, _ c: UInt32, slot: UInt16 = 0) {
        indices += [a, b, c]
        slots.append(slot)
    }

    func quad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, slot: UInt16 = 0) {
        triangle(a, b, c, slot: slot)
        triangle(a, c, d, slot: slot)
    }
}

enum MeshBuilder {
    // MARK: Primitives

    static func box(w: Float, h: Float, d: Float, sidesSlot: UInt16) -> Mesh3D {
        let m = Mesh3D()
        let x = w / 2, y = h / 2, z = d / 2
        // Each face: normal, then its corners top-left, top-right, bottom-right, bottom-left as seen from outside.
        let faces: [(SIMD3<Float>, [SIMD3<Float>], UInt16)] = [
            (SIMD3(0, 0, -1), [SIMD3(-x, -y, -z), SIMD3(x, -y, -z), SIMD3(x, y, -z), SIMD3(-x, y, -z)], 0), // front
            (SIMD3(0, 0, 1), [SIMD3(x, -y, z), SIMD3(-x, -y, z), SIMD3(-x, y, z), SIMD3(x, y, z)], 0),     // back
            (SIMD3(1, 0, 0), [SIMD3(x, -y, -z), SIMD3(x, -y, z), SIMD3(x, y, z), SIMD3(x, y, -z)], sidesSlot),   // right
            (SIMD3(-1, 0, 0), [SIMD3(-x, -y, z), SIMD3(-x, -y, -z), SIMD3(-x, y, -z), SIMD3(-x, y, z)], sidesSlot), // left
            (SIMD3(0, -1, 0), [SIMD3(-x, -y, z), SIMD3(x, -y, z), SIMD3(x, -y, -z), SIMD3(-x, -y, -z)], sidesSlot), // top
            (SIMD3(0, 1, 0), [SIMD3(-x, y, -z), SIMD3(x, y, -z), SIMD3(x, y, z), SIMD3(-x, y, z)], sidesSlot),   // bottom
        ]
        let uv: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        for (n, c, slot) in faces {
            let i = (0..<4).map { m.vertex(c[$0], n, uv[$0]) }
            m.quad(i[0], i[1], i[2], i[3], slot: slot)
        }
        return m
    }

    static func plane(w: Float, h: Float) -> Mesh3D {
        let m = Mesh3D()
        let x = w / 2, y = h / 2, n = SIMD3<Float>(0, 0, -1)
        let a = m.vertex(SIMD3(-x, -y, 0), n, SIMD2(0, 0)), b = m.vertex(SIMD3(x, -y, 0), n, SIMD2(1, 0))
        let c = m.vertex(SIMD3(x, y, 0), n, SIMD2(1, 1)), d = m.vertex(SIMD3(-x, y, 0), n, SIMD2(0, 1))
        m.quad(a, b, c, d)
        return m
    }

    /// An ellipsoid with radii rx, ry, rz; u wraps around (0.5 faces the viewer), v runs top to bottom.
    static func sphere(rx: Float, ry: Float, rz: Float, segments: Int) -> Mesh3D {
        let m = Mesh3D()
        let lon = max(segments, 8), lat = max(segments / 2, 4)
        for j in 0...lat {
            let v = Float(j) / Float(lat)
            let phi = v * .pi // 0 = top
            for i in 0...lon {
                let u = Float(i) / Float(lon)
                // theta 0 at the back, π facing the viewer (-z).
                let theta = u * 2 * .pi
                let dir = SIMD3<Float>(-sin(phi) * sin(theta), -cos(phi), sin(phi) * cos(theta))
                let p = SIMD3(dir.x * rx, dir.y * ry, dir.z * rz)
                let n = simd_normalize(SIMD3(dir.x / max(rx, 1e-3), dir.y / max(ry, 1e-3), dir.z / max(rz, 1e-3)))
                m.vertex(p, n, SIMD2(u, v))
            }
        }
        let row = UInt32(lon + 1)
        for j in 0..<lat {
            for i in 0..<lon {
                let a = UInt32(j) * row + UInt32(i), b = a + 1, c = a + row + 1, d = a + row
                if j > 0 { m.triangle(a, b, c) }
                if j < lat - 1 { m.triangle(a, c, d) }
            }
        }
        return m
    }

    /// Upright cylinder (or cone when top < bottom) of height h; radii in x and z; side = slot 0, caps = sidesSlot.
    static func cylinder(rx: Float, rz: Float, h: Float, topScale: Float, segments: Int, sidesSlot: UInt16) -> Mesh3D {
        let m = Mesh3D()
        let n = max(segments, 6)
        let y0 = -h / 2, y1 = h / 2
        // Side normals lean up by the slope of a cone.
        let slope = (1 - topScale) * max(rx, rz) / max(h, 1e-3)
        for i in 0...n {
            let u = Float(i) / Float(n)
            let a = u * 2 * .pi
            let cx = -sin(a), cz = cos(a) // u 0.5 faces the viewer
            let nrm = simd_normalize(SIMD3(cx / max(rx, 1e-3) * max(rx, rz), -slope, cz / max(rz, 1e-3) * max(rx, rz)))
            m.vertex(SIMD3(cx * rx * topScale, y0, cz * rz * topScale), nrm, SIMD2(u, 0))
            m.vertex(SIMD3(cx * rx, y1, cz * rz), nrm, SIMD2(u, 1))
        }
        for i in 0..<n {
            let a = UInt32(2 * i)
            m.quad(a, a + 2, a + 3, a + 1)
        }
        // Caps.
        for (y, ny, scale) in [(y0, Float(-1), topScale), (y1, Float(1), Float(1))] where scale > 0.001 {
            let center = m.vertex(SIMD3(0, y, 0), SIMD3(0, ny, 0), SIMD2(0.5, 0.5))
            var ring: [UInt32] = []
            for i in 0...n {
                let a = Float(i) / Float(n) * 2 * .pi
                let cx = -sin(a), cz = cos(a)
                ring.append(m.vertex(SIMD3(cx * rx * scale, y, cz * rz * scale), SIMD3(0, ny, 0), SIMD2(0.5 + cx / 2, 0.5 + cz / 2)))
            }
            for i in 0..<n { m.triangle(center, ring[i], ring[i + 1], slot: sidesSlot) }
        }
        return m
    }

    /// A ring facing the viewer (axis along z): outer radius r, tube radius tube.
    static func torus(r: Float, tube: Float, segments: Int) -> Mesh3D {
        let m = Mesh3D()
        let n = max(segments, 8), k = max(segments / 2, 6)
        let big = max(r - tube, 0)
        for i in 0...n {
            let u = Float(i) / Float(n), a = u * 2 * .pi
            let ca = cos(a), sa = sin(a)
            for j in 0...k {
                let v = Float(j) / Float(k), b = v * 2 * .pi
                let cb = cos(b), sb = sin(b)
                let nrm = SIMD3(ca * cb, sa * cb, sb)
                m.vertex(SIMD3((big + tube * cb) * ca, (big + tube * cb) * sa, tube * sb), nrm, SIMD2(u, v))
            }
        }
        let row = UInt32(k + 1)
        for i in 0..<n {
            for j in 0..<k {
                let a = UInt32(i) * row + UInt32(j)
                m.quad(a, a + row, a + row + 1, a + 1)
            }
        }
        return m
    }

    // MARK: Extrusion

    /// Extrudes a flat shape (y down, around its center) `depth` deep: caps in slot 0, walls in slot 1. A `bevel`
    /// (px, kept within half the depth and the thinnest part of the shape) rounds the edges in `bevelSteps` steps
    /// (1 = a flat chamfer); the bevel takes the cap color.
    static func extrude(_ path: CGPath, depth: Float, evenOdd: Bool = false, bevel: Float = 0, bevelSteps: Int = 3) -> Mesh3D {
        let m = Mesh3D()
        // Overlapping outlines (variable fonts, combined glyphs) become one clean outline.
        let clean = path.normalized(using: evenOdd ? .evenOdd : .winding)
        var contours = flatten(clean).filter { $0.count >= 3 && abs(signedArea($0)) > 0.01 }
        guard !contours.isEmpty else { return m }
        let z0 = -depth / 2, z1 = depth / 2
        // Nesting: a contour inside an even number of others is solid, inside an odd number a hole.
        let areas = contours.map(signedArea)
        var depthOf = [Int](repeating: 0, count: contours.count)
        var parent = [Int?](repeating: nil, count: contours.count)
        for i in contours.indices {
            let probe = contours[i][0]
            var best: Int?
            for j in contours.indices where j != i && abs(areas[j]) > abs(areas[i]) && contains(contours[j], probe) {
                depthOf[i] += 1
                if best.map({ abs(areas[j]) < abs(areas[$0]) }) ?? true { best = j }
            }
            parent[i] = best
        }
        // Solids counter-clockwise (positive area), holes clockwise: outward wall normals are then (dy, -dx).
        for i in contours.indices {
            let solid = depthOf[i] % 2 == 0
            if (areas[i] > 0) != solid { contours[i].reverse() }
        }
        let holesOf: [Int: [Int]] = Dictionary(grouping: contours.indices.filter { depthOf[$0] % 2 == 1 && parent[$0] != nil },
                                                by: { parent[$0]! })
        // Outward unit normal of each edge (k → k+1).
        let edgeNormals: [[SIMD2<Double>]] = contours.map { c in
            (0..<c.count).map { k in
                let a = c[k], b = c[(k + 1) % c.count]
                let d = SIMD2<Double>(Double(b.x - a.x), Double(b.y - a.y))
                let len = simd_length(d)
                return len > 0 ? SIMD2(d.y / len, -d.x / len) : .zero
            }
        }
        // Each solid part (with its holes) keeps the bevel thinner than itself (area / boundary length ≈ half its
        // thickness), so a small dot or accent does not flatten the bevel of the whole text.
        let b = Double(min(max(bevel, 0), depth / 2))
        var bevelOf = [Double](repeating: 0, count: contours.count)
        if b > 0 {
            func perimeter(_ c: [CGPoint]) -> Double {
                c.indices.reduce(0) { $0 + hypot(c[($1 + 1) % c.count].x - c[$1].x, c[($1 + 1) % c.count].y - c[$1].y) }
            }
            for i in contours.indices where depthOf[i] % 2 == 0 {
                let holes = holesOf[i] ?? []
                let area = abs(areas[i]) - holes.reduce(0) { $0 + abs(areas[$1]) }
                let length = perimeter(contours[i]) + holes.reduce(0) { $0 + perimeter(contours[$1]) }
                var part = length > 0 ? min(b, 0.85 * max(area, 0) / length) : 0
                // Thin strokes: insets past half their thickness would cross. Measured from each point straight
                // inward to the other side; a low percentile, so tapered tips (which collapse) do not decide it.
                if part > 0 {
                    let region = [i] + holes
                    var thickness: [Double] = []
                    for ci in region {
                        let c = contours[ci], en = edgeNormals[ci]
                        for k in c.indices {
                            var dir = -(en[(k + c.count - 1) % c.count] + en[k])
                            let len = simd_length(dir)
                            guard len > 1e-6 else { continue }
                            dir /= len
                            let o = SIMD2<Double>(Double(c[k].x), Double(c[k].y))
                            var best = Double.infinity
                            for cj in region {
                                let d = contours[cj]
                                for e in d.indices {
                                    if cj == ci && (e == k || (e + 1) % d.count == k) { continue }
                                    let a = SIMD2<Double>(Double(d[e].x), Double(d[e].y))
                                    let ed = SIMD2<Double>(Double(d[(e + 1) % d.count].x), Double(d[(e + 1) % d.count].y)) - a
                                    let denom = dir.x * ed.y - dir.y * ed.x
                                    guard abs(denom) > 1e-12 else { continue }
                                    let ao = a - o
                                    let t = (ao.x * ed.y - ao.y * ed.x) / denom
                                    let u = (ao.x * dir.y - ao.y * dir.x) / denom
                                    if t > 1e-6, u >= 0, u <= 1, t < best { best = t }
                                }
                            }
                            if best.isFinite { thickness.append(best) }
                        }
                    }
                    if !thickness.isEmpty {
                        thickness.sort()
                        part = min(part, 0.45 * thickness[thickness.count / 20])
                    }
                }
                bevelOf[i] = part
                for h in holes { bevelOf[h] = part }
            }
        }
        // Contours moved inward, one point per vertex (see `offsetContour`), memoized per contour and inset.
        let points: [[SIMD2<Double>]] = contours.map { $0.map { SIMD2<Double>(Double($0.x), Double($0.y)) } }
        var rings: [Int: [Double: [SIMD2<Double>]]] = [:]
        func ring(_ i: Int, _ o: Double) -> [SIMD2<Double>] {
            if let r = rings[i]?[o] { return r }
            let r = offsetContour(points[i], normals: edgeNormals[i], by: o)
            rings[i, default: [:]][o] = r
            return r
        }
        func inset(_ i: Int, _ k: Int, _ o: Double) -> SIMD2<Double> { o > 1e-9 ? ring(i, o)[k] : points[i][k] }
        // Caps: the inset outlines without the points that collapsed onto their neighbors.
        func capPoints(_ i: Int) -> [SIMD2<Double>] {
            var out: [SIMD2<Double>] = []
            for p in (bevelOf[i] > 0 ? ring(i, bevelOf[i]) : points[i]) where out.last.map({ simd_distance($0, p) > 1e-6 }) ?? true { out.append(p) }
            if out.count > 1, simd_distance(out[0], out[out.count - 1]) <= 1e-6 { out.removeLast() }
            return out
        }
        for i in contours.indices where depthOf[i] % 2 == 0 {
            let holes = holesOf[i] ?? []
            var flat: [Double] = []
            var holeStarts: [Int] = []
            let outer = capPoints(i)
            guard outer.count >= 3 else { continue }
            for p in outer { flat += [p.x, p.y] }
            for h in holes {
                let hole = capPoints(h)
                guard hole.count >= 3 else { continue }
                holeStarts.append(flat.count / 2)
                for p in hole { flat += [p.x, p.y] }
            }
            let tris = Earcut.triangulate(flat, holes: holeStarts)
            guard !tris.isEmpty else { continue }
            let count = flat.count / 2
            let front = (0..<count).map { k in
                m.vertex(SIMD3(Float(flat[2 * k]), Float(flat[2 * k + 1]), z0), SIMD3(0, 0, -1))
            }
            let back = (0..<count).map { k in
                m.vertex(SIMD3(Float(flat[2 * k]), Float(flat[2 * k + 1]), z1), SIMD3(0, 0, 1))
            }
            for t in stride(from: 0, to: tris.count, by: 3) {
                m.triangle(front[tris[t]], front[tris[t + 1]], front[tris[t + 2]])
                m.triangle(back[tris[t]], back[tris[t + 2]], back[tris[t + 1]])
            }
        }
        guard depth > 0 else { return m }
        // The side profile, front to back: (inset, z, normal weights outward / along z). With a bevel it goes round
        // a quarter circle at each end; the straight wall in between is the only part in the side color.
        typealias ProfilePoint = (inset: Double, z: Float, out: Float, nz: Float)
        let steps = max(bevelSteps, 1)
        func sideProfile(_ b: Double) -> [ProfilePoint] {
            guard b > 0 else { return [(0, z0, 1, 0), (0, z1, 1, 0)] }
            var profile: [ProfilePoint] = []
            for s in 0...steps {
                let a = Double(s) / Double(steps) * .pi / 2
                profile.append((b * (1 - sin(a)), z0 + Float(b * (1 - cos(a))), Float(sin(a)), Float(-cos(a))))
            }
            for s in (0...steps).reversed() {
                let a = Double(s) / Double(steps) * .pi / 2
                profile.append((b * (1 - sin(a)), z1 - Float(b * (1 - cos(a))), Float(sin(a)), Float(cos(a))))
            }
            return profile
        }
        // Walls: smooth across gentle bends, sharp at corners.
        let smoothCos = cos(35.0 * Double.pi / 180)
        for (i, c) in contours.enumerated() {
            let profile = sideProfile(bevelOf[i])
            let wallStrip = bevelOf[i] > 0 ? steps : 0
            let n = c.count
            let segN = edgeNormals[i]
            for k in 0..<n {
                let prev = segN[(k + n - 1) % n], cur = segN[k], next = segN[(k + 1) % n]
                let n0 = simd_dot(prev, cur) > smoothCos ? simd_normalize(prev + cur) : cur
                let n1 = simd_dot(cur, next) > smoothCos ? simd_normalize(cur + next) : cur
                let k1 = (k + 1) % n
                for s in 0..<(profile.count - 1) {
                    let p = profile[s], q = profile[s + 1]
                    if p.z == q.z && p.inset == q.inset { continue }
                    // A chamfer (one step) is flat: its face normal at both rows.
                    var po = p.out, pz = p.nz, qo = q.out, qz = q.nz
                    if steps == 1 && s != wallStrip {
                        let dz = Double(q.z - p.z), dOut = p.inset - q.inset
                        let len = max(hypot(dz, dOut), 1e-9)
                        po = Float(dz / len); pz = Float(-dOut / len); qo = po; qz = pz
                    }
                    func vert(_ k: Int, _ nrm: SIMD2<Double>, _ pp: ProfilePoint, _ o: Float, _ z: Float) -> UInt32 {
                        let at = inset(i, k, pp.inset)
                        return m.vertex(SIMD3(Float(at.x), Float(at.y), pp.z),
                                        simd_normalize(SIMD3(Float(nrm.x) * o, Float(nrm.y) * o, z)))
                    }
                    let v0 = vert(k, n0, p, po, pz), v1 = vert(k1, n1, p, po, pz)
                    let v2 = vert(k1, n1, q, qo, qz), v3 = vert(k, n0, q, qo, qz)
                    m.quad(v0, v1, v2, v3, slot: s == wallStrip ? 1 : 0)
                }
            }
        }
        return m
    }

    /// A closed contour (outward unit edge normals; edge k runs from point k to k + 1) moved `o` inward: each point
    /// lands where the offset lines of its two edges meet (at most 4·o from where it was, so needle tips do not
    /// spike). An edge that turns around on the way (it was shorter than the offset eats near a corner) collapses,
    /// and its two ends then share the meeting point of its neighbors, so the outline never crosses itself. One point
    /// per input point; collapsed ones coincide.
    static func offsetContour(_ pts: [SIMD2<Double>], normals: [SIMD2<Double>], by o: Double) -> [SIMD2<Double>] {
        let n = pts.count
        guard o > 0, n >= 3 else { return pts }
        var alive = normals.map { simd_length_squared($0) > 0.5 }
        guard alive.filter({ $0 }).count >= 3 else { return pts }
        let lineC = (0..<n).map { simd_dot(pts[$0], normals[$0]) - o } // edge e's offset line: dot(x, N[e]) = C[e]
        func meet(_ a: Int, _ b: Int, near v: SIMD2<Double>) -> SIMD2<Double> {
            let na = normals[a], nb = normals[b]
            let det = na.x * nb.y - na.y * nb.x
            // Nearly parallel (a straight run cut into pieces): straight in from the vertex.
            if abs(det) < 1e-6 { return v - na * (simd_dot(v, na) - lineC[a]) }
            let x = SIMD2((lineC[a] * nb.y - lineC[b] * na.y) / det, (na.x * lineC[b] - nb.x * lineC[a]) / det)
            let d = x - v, len = simd_length(d)
            return len > 4 * o ? v + d * (4 * o / len) : x
        }
        var pos = pts
        for _ in 0..<n {
            let live = (0..<n).filter { alive[$0] }
            guard live.count >= 3 else { break }
            // The points from the end of one live edge to the start of the next share their meeting point.
            for (j, e) in live.enumerated() {
                let prev = live[(j + live.count - 1) % live.count]
                let first = (prev + 1) % n
                let p = meet(prev, e, near: (pts[first] + pts[e]) / 2)
                var k = first
                while true {
                    pos[k] = p
                    if k == e { break }
                    k = (k + 1) % n
                }
            }
            // Collapse the edge that turned around the most, then place the points again.
            var worst = -1, worstRatio = -1e-9
            for e in live {
                let d0 = pts[(e + 1) % n] - pts[e], d1 = pos[(e + 1) % n] - pos[e]
                let ratio = simd_dot(d0, d1) / max(simd_length_squared(d0), 1e-12)
                if ratio < worstRatio { worstRatio = ratio; worst = e }
            }
            guard worst >= 0 else { break }
            alive[worst] = false
        }
        return pos
    }

    // MARK: Lathe

    /// Turns a profile around the vertical axis through the layer's center (x = 0 of `d`): each subpath of the path
    /// (open or closed) sweeps a surface, with radius |x| at height y. End a profile on the axis to close it.
    static func lathe(_ path: CGPath, segments: Int) -> Mesh3D {
        let m = Mesh3D()
        let n = max(segments, 3)
        let lines = polylines(path).filter { $0.points.count >= 2 }
        let profiles: [[SIMD2<Double>]] = lines.map { line in
            var pts = line.points.map { SIMD2<Double>(Double(abs($0.x)), Double($0.y)) }
            if line.closed, pts.count >= 3 { pts.append(pts[0]) }
            return pts
        }
        let total = max(profiles.reduce(0) { sum, pts in
            sum + zip(pts, pts.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
        }, 1e-6)
        let smoothCos = cos(35.0 * Double.pi / 180)
        let ring: [(x: Float, z: Float)] = (0...n).map { j in
            let a = Double(j) / Double(n) * 2 * .pi
            return (Float(-sin(a)), Float(cos(a))) // u 0.5 faces the viewer
        }
        var travelled = 0.0
        for (li, pts) in profiles.enumerated() {
            let count = pts.count - 1
            guard count > 0 else { continue }
            let closed = lines[li].closed && pts.count >= 4
            // Normal of each profile piece in (r, y).
            let segN: [SIMD2<Double>] = (0..<count).map { k in
                let d = pts[k + 1] - pts[k]
                let len = simd_length(d)
                return len > 0 ? SIMD2(d.y / len, -d.x / len) : .zero
            }
            for k in 0..<count {
                let len = simd_distance(pts[k], pts[k + 1])
                guard len > 0 else { continue }
                let cur = segN[k]
                let prev = k > 0 ? segN[k - 1] : (closed ? segN[count - 1] : cur)
                let next = k + 1 < count ? segN[k + 1] : (closed ? segN[0] : cur)
                let n0 = simd_dot(prev, cur) > smoothCos ? simd_normalize(prev + cur) : cur
                let n1 = simd_dot(cur, next) > smoothCos ? simd_normalize(cur + next) : cur
                let v0 = Float(travelled / total), v1 = Float((travelled + len) / total)
                travelled += len
                var rowA: [UInt32] = [], rowB: [UInt32] = []
                for (j, c) in ring.enumerated() {
                    let u = Float(j) / Float(n)
                    let a = pts[k], b = pts[k + 1]
                    rowA.append(m.vertex(SIMD3(Float(a.x) * c.x, Float(a.y), Float(a.x) * c.z),
                                         SIMD3(Float(n0.x) * c.x, Float(n0.y), Float(n0.x) * c.z), SIMD2(u, v0)))
                    rowB.append(m.vertex(SIMD3(Float(b.x) * c.x, Float(b.y), Float(b.x) * c.z),
                                         SIMD3(Float(n1.x) * c.x, Float(n1.y), Float(n1.x) * c.z), SIMD2(u, v1)))
                }
                for j in 0..<n { m.quad(rowA[j], rowA[j + 1], rowB[j + 1], rowB[j]) }
            }
        }
        return m
    }

    /// Closed polylines of a path (curves cut into short straight pieces).
    static func flatten(_ path: CGPath) -> [[CGPoint]] {
        polylines(path).map { line in
            var c = line.points
            if let f = c.first, let l = c.last, c.count > 1, hypot(f.x - l.x, f.y - l.y) < 0.05 { c.removeLast() }
            return c
        }.filter { $0.count >= 3 }
    }

    /// Every subpath as a polyline, and whether it was closed.
    static func polylines(_ path: CGPath) -> [(points: [CGPoint], closed: Bool)] {
        var out: [(points: [CGPoint], closed: Bool)] = []
        var cur: [CGPoint] = []
        var last = CGPoint.zero, start = CGPoint.zero
        func add(_ p: CGPoint) {
            if let l = cur.last, hypot(l.x - p.x, l.y - p.y) < 0.05 { return }
            cur.append(p)
        }
        func finish(closed: Bool) {
            if closed, let f = cur.first, let l = cur.last, cur.count > 1, hypot(f.x - l.x, f.y - l.y) < 0.05 { cur.removeLast() }
            if cur.count >= 2 { out.append((cur, closed)) }
            cur = []
        }
        func steps(_ len: Double) -> Int { min(max(Int(len / 3), 2), 24) }
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                finish(closed: false)
                last = e.points[0]; start = last
                add(last)
            case .addLineToPoint:
                last = e.points[0]
                add(last)
            case .addQuadCurveToPoint:
                let c = e.points[0], p = e.points[1]
                let n = steps(hypot(c.x - last.x, c.y - last.y) + hypot(p.x - c.x, p.y - c.y))
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    let qx: Double = u * u * last.x + 2 * u * t * c.x + t * t * p.x
                    let qy: Double = u * u * last.y + 2 * u * t * c.y + t * t * p.y
                    add(CGPoint(x: qx, y: qy))
                }
                last = p
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], p = e.points[2]
                let n = steps(hypot(c1.x - last.x, c1.y - last.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(p.x - c2.x, p.y - c2.y))
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, cc = 3 * u * t * t, d = t * t * t
                    let px: Double = a * last.x + b * c1.x + cc * c2.x + d * p.x
                    let py: Double = a * last.y + b * c1.y + cc * c2.y + d * p.y
                    add(CGPoint(x: px, y: py))
                }
                last = p
            case .closeSubpath:
                last = start
                finish(closed: true)
            @unknown default:
                break
            }
        }
        finish(closed: false)
        return out
    }

    static func signedArea(_ c: [CGPoint]) -> Double {
        var a = 0.0
        for i in c.indices {
            let p = c[i], q = c[(i + 1) % c.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    static func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: Files

    /// Loads a model file, centered and scaled so its largest side is `size` px, turned from the files' y-up axes to
    /// the scene's (y down, z away). OBJ (with its MTL colors and textures), STL and glTF (glb/gltf) are read here, so
    /// they also load in sandboxed processes; usdz, usd/usda/usdc, ply and abc go through ModelIO (the app only). Parts
    /// get their file colors (slot 2 + i). Animated glTF files come with their rig.
    static func load(_ url: URL, size: Float) throws -> ModelFile {
        let m: Mesh3D
        var rig: GLTFRig?
        switch url.pathExtension.lowercased() {
        case "obj": m = try ObjFile.load(url)
        case "stl": m = try loadSTL(url)
        case "glb", "gltf": (m, rig) = try GLTFFile.load(url)
        default: m = try loadModelIO(url)
        }
        guard !m.isEmpty else { throw SceneError.invalid("No triangles in \(url.lastPathComponent)") }
        return ModelFile(m, rig: rig, size: size)
    }

    /// STL, binary or ASCII: facets with flat normals.
    private static func loadSTL(_ url: URL) throws -> Mesh3D {
        let data = try Data(contentsOf: url)
        let m = Mesh3D()
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            n = len > 0 ? n / len : SIMD3(0, 1, 0)
            m.triangle(m.vertex(a, n), m.vertex(b, n), m.vertex(c, n))
        }
        let count = data.count >= 84 ? data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 80, as: UInt32.self)) } : -1
        if count >= 0, data.count == 84 + count * 50 {
            data.withUnsafeBytes { raw in
                for t in 0..<count {
                    let o = 84 + t * 50 + 12
                    func v(_ k: Int) -> SIMD3<Float> {
                        SIMD3(raw.loadUnaligned(fromByteOffset: o + k * 12, as: Float.self),
                              raw.loadUnaligned(fromByteOffset: o + k * 12 + 4, as: Float.self),
                              raw.loadUnaligned(fromByteOffset: o + k * 12 + 8, as: Float.self))
                    }
                    add(v(0), v(1), v(2))
                }
            }
            return m
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SceneError.invalid("Cannot read \(url.lastPathComponent)")
        }
        var corners: [SIMD3<Float>] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.first == "vertex", f.count >= 4, let x = Float(f[1]), let y = Float(f[2]), let z = Float(f[3]) else { continue }
            corners.append(SIMD3(x, y, z))
            if corners.count == 3 { add(corners[0], corners[1], corners[2]); corners = [] }
        }
        return m
    }

    private static func loadModelIO(_ url: URL) throws -> Mesh3D {
        guard MDLAsset.canImportFileExtension(url.pathExtension.lowercased()) else {
            throw SceneError.invalid("Cannot read 3D files of type .\(url.pathExtension) (use obj, stl, glb, gltf, usdz, usd or ply)")
        }
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil, preserveTopology: false, error: nil)
        asset.loadTextures()
        let m = Mesh3D()
        var materialIndex: [ObjectIdentifier: UInt16] = [:]
        func meshes(_ obj: MDLObject) -> [MDLMesh] {
            var out: [MDLMesh] = []
            if let mesh = obj as? MDLMesh { out.append(mesh) }
            for child in obj.children.objects { out += meshes(child) }
            return out
        }
        var all: [MDLMesh] = []
        for i in 0..<asset.count { all += meshes(asset.object(at: i)) }
        guard !all.isEmpty else { throw SceneError.invalid("No meshes in \(url.lastPathComponent)") }
        for mesh in all {
            if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3) == nil {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.6)
            }
            guard let pos = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { continue }
            let nrm = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3)
            let tex = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2)
            let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
            let normalMatrix = simd_transpose(simd_inverse(simd_float3x3(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                                                          SIMD3(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                                                          SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))))
            let base = UInt32(m.positions.count)
            for v in 0..<mesh.vertexCount {
                let p = (pos.dataStart + v * pos.stride).assumingMemoryBound(to: Float.self)
                let wp = world * SIMD4(p[0], p[1], p[2], 1)
                var n = SIMD3<Float>(0, 1, 0)
                if let nrm {
                    let q = (nrm.dataStart + v * nrm.stride).assumingMemoryBound(to: Float.self)
                    n = simd_normalize(normalMatrix * SIMD3(q[0], q[1], q[2]))
                    if !n.x.isFinite { n = SIMD3(0, 1, 0) }
                }
                var uv = SIMD2<Float>(0, 0)
                if let tex {
                    let q = (tex.dataStart + v * tex.stride).assumingMemoryBound(to: Float.self)
                    uv = SIMD2(q[0], 1 - q[1])
                }
                m.vertex(SIMD3(wp.x, wp.y, wp.z), n, uv)
            }
            for case let sub as MDLSubmesh in mesh.submeshes ?? [] where sub.geometryType == .triangles {
                let slot: UInt16
                if let mat = sub.material {
                    let key = ObjectIdentifier(mat)
                    if let s = materialIndex[key] {
                        slot = s
                    } else {
                        m.fileMaterials.append(materialLook(mat))
                        slot = UInt16(1 + m.fileMaterials.count)
                        materialIndex[key] = slot
                    }
                } else {
                    slot = 0
                }
                let buf = sub.indexBuffer.map()
                let count = sub.indexCount
                var idx = [UInt32](repeating: 0, count: count)
                switch sub.indexType {
                case .uInt8: let q = buf.bytes.assumingMemoryBound(to: UInt8.self); for i in 0..<count { idx[i] = UInt32(q[i]) }
                case .uInt16: let q = buf.bytes.assumingMemoryBound(to: UInt16.self); for i in 0..<count { idx[i] = UInt32(q[i]) }
                default: let q = buf.bytes.assumingMemoryBound(to: UInt32.self); for i in 0..<count { idx[i] = q[i] }
                }
                for t in stride(from: 0, to: count - 2, by: 3) {
                    m.triangle(base + idx[t], base + idx[t + 1], base + idx[t + 2], slot: slot)
                }
            }
        }
        return m
    }

    private static func materialLook(_ mat: MDLMaterial) -> (color: RGBA, texture: Texture3D?) {
        guard let p = mat.property(with: .baseColor) else { return (.white, nil) }
        switch p.type {
        case .float3:
            let c = p.float3Value
            return (RGBA(r: Double(c.x), g: Double(c.y), b: Double(c.z)), nil)
        case .float4:
            let c = p.float4Value
            return (RGBA(r: Double(c.x), g: Double(c.y), b: Double(c.z), a: Double(c.w)), nil)
        case .color:
            if let c = p.color, let rgba = RGBA(cgColor: c) { return (rgba, nil) }
        case .texture:
            if let img = p.textureSamplerValue?.texture?.imageFromTexture()?.takeUnretainedValue() { return (.white, Texture3D(img)) }
        case .string, .URL:
            if let url = p.urlValue ?? p.stringValue.map({ URL(fileURLWithPath: $0) }),
               let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return (.white, Texture3D(img))
            }
        default:
            break
        }
        return (.white, nil)
    }
}

// MARK: - Model files

/// An animation clip of a model file.
public struct ModelAnimation: Equatable, Sendable {
    public var name: String
    public var duration: Double
}

/// A loaded model file: its mesh at rest, and for animated glTF files the rig that poses it. Every pose is turned
/// and fitted like the rest pose, so the model keeps its place and size while it moves.
final class ModelFile {
    let mesh: Mesh3D
    let rig: GLTFRig?
    private let center: SIMD3<Float>
    private let k: Float

    var animations: [ModelAnimation] {
        rig?.clips.map { ModelAnimation(name: $0.name, duration: Double($0.end - $0.start)) } ?? []
    }

    init(_ m: Mesh3D, rig: GLTFRig?, size: Float) {
        // y up, z toward the viewer → y down, z away: a half turn around x (no mirroring, the winding stays).
        for i in m.positions.indices {
            m.positions[i] = Self.turned(m.positions[i])
            m.normals[i] = Self.turned(m.normals[i])
        }
        let (lo, hi) = m.bounds
        center = (lo + hi) / 2
        let extent = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
        k = extent > 0 ? size / extent : 1
        for i in m.positions.indices { m.positions[i] = (m.positions[i] - center) * k }
        mesh = m
        self.rig = rig
    }

    private static func turned(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, -v.y, -v.z) }

    /// The mesh with clip `clip` at `time` seconds into it.
    func posed(_ clip: Int, at time: Double) -> Mesh3D {
        guard let rig else { return mesh }
        let (positions, normals) = rig.pose(clip, at: time)
        let m = Mesh3D()
        m.indices = mesh.indices
        m.slots = mesh.slots
        m.uvs = mesh.uvs
        m.fileMaterials = mesh.fileMaterials
        m.positions = positions.map { (Self.turned($0) - center) * k }
        m.normals = normals.map(Self.turned)
        return m
    }

    private static let infoLock = NSLock()
    nonisolated(unsafe) private static var infoCache: [String: (modified: Double, animations: [ModelAnimation])] = [:]

    /// The animation clips of the model file at `path` (empty for files without any, or that cannot be read).
    static func animations(atPath path: String) -> [ModelAnimation] {
        let path = (path as NSString).expandingTildeInPath
        guard ["glb", "gltf"].contains((path as NSString).pathExtension.lowercased()) else { return [] }
        let modified = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        infoLock.lock()
        if let c = infoCache[path], c.modified == modified { infoLock.unlock(); return c.animations }
        infoLock.unlock()
        let list = (try? GLTFFile.animations(URL(fileURLWithPath: path))) ?? []
        infoLock.lock()
        if infoCache.count > 32 { infoCache.removeAll() }
        infoCache[path] = (modified, list)
        infoLock.unlock()
        return list
    }
}

extension MotionLayer {
    /// The animation clips of a file model's `path`.
    public var modelAnimations: [ModelAnimation] {
        guard type == .model, model.shape == .file, let path else { return [] }
        return ModelFile.animations(atPath: path)
    }

    /// The clip of a file model shown at scene time t and the seconds into it, nil for the rest pose.
    func modelClip(at t: Double, in animations: [ModelAnimation]) -> (index: Int, time: Double)? {
        guard let i = model.clipIndex(in: animations.map(\.name)) else { return nil }
        let duration = animations[i].duration
        let s = (model.animationOffset ?? 0) + max(0, t - start) * (model.animationSpeed ?? 1)
        guard duration > 0 else { return (i, 0) }
        if model.animationLoopValue {
            let r = s.truncatingRemainder(dividingBy: duration)
            return (i, r < 0 ? r + duration : r)
        }
        return (i, min(max(s, 0), duration))
    }
}

// MARK: - OBJ files

/// Wavefront OBJ with its MTL materials (Kd color, d/Tr opacity, map_Kd texture). Polygons are fanned into
/// triangles; missing normals are smoothed across faces that meet at less than 40°.
enum ObjFile {
    static func load(_ url: URL) throws -> Mesh3D {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SceneError.invalid("Cannot read \(url.lastPathComponent)")
        }
        struct Corner { var v: Int; var t: Int; var n: Int }
        var pos: [SIMD3<Float>] = [], tex: [SIMD2<Float>] = [], nrm: [SIMD3<Float>] = []
        var faces: [(corners: [Corner], slot: UInt16)] = []
        var library: [String: (color: RGBA, texture: Texture3D?)] = [:]
        var slotOf: [String: UInt16] = [:]
        let m = Mesh3D()
        var slot: UInt16 = 0
        func rest(_ line: Substring, after word: String) -> String {
            String(line.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            func num(_ i: Int) -> Float { i < f.count ? Float(f[i]) ?? 0 : 0 }
            switch f[0] {
            case "v": pos.append(SIMD3(num(1), num(2), num(3)))
            case "vt": tex.append(SIMD2(num(1), num(2)))
            case "vn": nrm.append(SIMD3(num(1), num(2), num(3)))
            case "f":
                var corners: [Corner] = []
                for item in f.dropFirst() {
                    let parts = item.split(separator: "/", omittingEmptySubsequences: false)
                    func index(_ k: Int, _ count: Int) -> Int {
                        guard k < parts.count, let i = Int(parts[k]) else { return -1 }
                        let j = i < 0 ? count + i : i - 1
                        return j >= 0 && j < count ? j : -1
                    }
                    corners.append(Corner(v: index(0, pos.count), t: index(1, tex.count), n: index(2, nrm.count)))
                }
                if corners.count >= 3, !corners.contains(where: { $0.v < 0 }) { faces.append((corners, slot)) }
            case "mtllib":
                let file = url.deletingLastPathComponent().appendingPathComponent(rest(line, after: "mtllib"))
                library.merge(materials(file), uniquingKeysWith: { $1 })
            case "usemtl":
                let name = rest(line, after: "usemtl")
                if let s = slotOf[name] {
                    slot = s
                } else {
                    m.fileMaterials.append(library[name] ?? (.white, nil))
                    slot = UInt16(1 + m.fileMaterials.count)
                    slotOf[name] = slot
                }
            default:
                break
            }
        }
        // Face normals (Newell: fine for any planar polygon), and the faces around each position.
        let faceNormals: [SIMD3<Float>] = faces.map { face in
            var n = SIMD3<Float>(repeating: 0)
            for i in face.corners.indices {
                let a = pos[face.corners[i].v], b = pos[face.corners[(i + 1) % face.corners.count].v]
                n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
            }
            let len = simd_length(n)
            return len > 0 ? n / len : SIMD3(0, 1, 0)
        }
        var around = [[Int]](repeating: [], count: pos.count)
        for (fi, face) in faces.enumerated() where face.corners.contains(where: { $0.n < 0 }) {
            for c in face.corners { around[c.v].append(fi) }
        }
        let crease = Float(cos(40.0 * Double.pi / 180))
        for (fi, face) in faces.enumerated() {
            let ids: [UInt32] = face.corners.map { c in
                var n: SIMD3<Float>
                if c.n >= 0 {
                    n = nrm[c.n]
                } else {
                    n = .zero
                    for other in around[c.v] where simd_dot(faceNormals[other], faceNormals[fi]) > crease { n += faceNormals[other] }
                    let len = simd_length(n)
                    n = len > 0 ? n / len : faceNormals[fi]
                }
                let uv = c.t >= 0 ? SIMD2(tex[c.t].x, 1 - tex[c.t].y) : SIMD2<Float>(0, 0)
                return m.vertex(pos[c.v], n, uv)
            }
            for i in 1..<(ids.count - 1) { m.triangle(ids[0], ids[i], ids[i + 1], slot: face.slot) }
        }
        return m
    }

    /// Materials of an MTL file by name.
    private static func materials(_ url: URL) -> [String: (color: RGBA, texture: Texture3D?)] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [:] }
        var out: [String: (color: RGBA, texture: Texture3D?)] = [:]
        var name: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let key = f.first else { continue }
            func num(_ i: Int) -> Double { i < f.count ? Double(f[i]) ?? 0 : 0 }
            switch key {
            case "newmtl":
                name = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if let name { out[name] = (.white, nil) }
            case "Kd":
                if let n = name {
                    let alpha = out[n]?.color.a ?? 1
                    out[n]?.color = RGBA(r: num(1), g: num(2), b: num(3), a: alpha)
                }
            case "d":
                if let n = name { out[n]?.color.a = min(max(num(1), 0), 1) }
            case "Tr":
                if let n = name { out[n]?.color.a = min(max(1 - num(1), 0), 1) }
            case "map_Kd":
                // Options (-s, -o …) come first; the file is the last word.
                if let n = name, let file = f.last, f.count > 1 {
                    let path = url.deletingLastPathComponent().appendingPathComponent(String(file))
                    if let src = CGImageSourceCreateWithURL(path as CFURL, nil),
                       let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                        out[n]?.texture = Texture3D(img)
                    }
                }
            default:
                break
            }
        }
        return out
    }
}

// MARK: - Polygon triangulation

/// Ear clipping of a polygon with holes (a port of Mapbox's earcut without its z-order hash: shapes here are
/// glyphs and icons of a few hundred points). `coords` = x, y pairs; `holes` = the point index each hole starts at.
/// Returns point indices, three per triangle.
final class Earcut {
    final class Node {
        let i: Int
        let x: Double
        let y: Double
        var prev: Node!
        var next: Node!
        var steiner = false
        init(_ i: Int, _ x: Double, _ y: Double) { self.i = i; self.x = x; self.y = y }
    }

    /// Every node made, so the rings (strong references both ways) can be broken at the end.
    private var pool: [Node] = []

    static func triangulate(_ coords: [Double], holes: [Int]) -> [Int] {
        let run = Earcut()
        defer { for n in run.pool { n.prev = nil; n.next = nil } }
        return run.run(coords, holes: holes)
    }

    private func run(_ coords: [Double], holes: [Int]) -> [Int] {
        let outerEnd = holes.first.map { $0 * 2 } ?? coords.count
        guard var outer = linkedList(coords, 0, outerEnd, clockwise: true), outer.next !== outer.prev else { return [] }
        var tris: [Int] = []
        if !holes.isEmpty { outer = eliminateHoles(coords, holes, outer) }
        earcutLinked(outer, &tris, pass: 0)
        return tris
    }

    private func linkedList(_ d: [Double], _ start: Int, _ end: Int, clockwise: Bool) -> Node? {
        var last: Node?
        if clockwise == (signedArea(d, start, end) > 0) {
            var i = start
            while i < end { last = insert(i / 2, d[i], d[i + 1], last); i += 2 }
        } else {
            var i = end - 2
            while i >= start { last = insert(i / 2, d[i], d[i + 1], last); i -= 2 }
        }
        if let l = last, equals(l, l.next) {
            remove(l)
            last = l.next
        }
        return last
    }

    private func signedArea(_ d: [Double], _ start: Int, _ end: Int) -> Double {
        var sum = 0.0
        var j = end - 2
        var i = start
        while i < end {
            sum += (d[j] - d[i]) * (d[i + 1] + d[j + 1])
            j = i
            i += 2
        }
        return sum
    }

    private func filterPoints(_ start: Node?, _ endIn: Node? = nil) -> Node? {
        guard let start else { return nil }
        var end = endIn ?? start
        var p = start
        var again: Bool
        repeat {
            again = false
            if !p.steiner && (equals(p, p.next) || area(p.prev, p, p.next) == 0) {
                remove(p)
                p = p.prev
                end = p
                if p === p.next { break }
                again = true
            } else {
                p = p.next
            }
        } while again || p !== end
        return end
    }

    private func earcutLinked(_ earIn: Node?, _ tris: inout [Int], pass: Int) {
        guard var ear = earIn else { return }
        var stop = ear
        var guardCount = 0
        while ear.prev !== ear.next {
            guardCount += 1
            if guardCount > 1_000_000 { return }
            let prev = ear.prev!, next = ear.next!
            if isEar(ear) {
                tris += [prev.i, ear.i, next.i]
                remove(ear)
                ear = next.next
                stop = next.next
                continue
            }
            ear = next
            if ear === stop {
                if pass == 0 {
                    earcutLinked(filterPoints(ear), &tris, pass: 1)
                } else if pass == 1 {
                    let cured = cureLocalIntersections(filterPoints(ear), &tris)
                    earcutLinked(cured, &tris, pass: 2)
                } else if pass == 2 {
                    splitEarcut(ear, &tris)
                }
                break
            }
        }
    }

    private func isEar(_ ear: Node) -> Bool {
        let a = ear.prev!, b = ear, c = ear.next!
        if area(a, b, c) >= 0 { return false }
        let x0 = min(a.x, b.x, c.x), y0 = min(a.y, b.y, c.y), x1 = max(a.x, b.x, c.x), y1 = max(a.y, b.y, c.y)
        var p = c.next!
        while p !== a {
            if p.x >= x0, p.x <= x1, p.y >= y0, p.y <= y1,
               pointInTriangle(a.x, a.y, b.x, b.y, c.x, c.y, p.x, p.y), area(p.prev, p, p.next) >= 0 { return false }
            p = p.next
        }
        return true
    }

    private func cureLocalIntersections(_ startIn: Node?, _ tris: inout [Int]) -> Node? {
        guard var start = startIn else { return nil }
        var p = start
        repeat {
            let a = p.prev!, b = p.next.next!
            if !equals(a, b), intersects(a, p, p.next, b), locallyInside(a, b), locallyInside(b, a) {
                tris += [a.i, p.i, b.i]
                remove(p)
                remove(p.next)
                p = b
                start = b
            }
            p = p.next
        } while p !== start
        return filterPoints(p)
    }

    private func splitEarcut(_ start: Node, _ tris: inout [Int]) {
        var a = start
        repeat {
            var b = a.next.next!
            while b !== a.prev {
                if a.i != b.i, isValidDiagonal(a, b) {
                    var c: Node? = splitPolygon(a, b)
                    let a2 = filterPoints(a, a.next)
                    c = filterPoints(c, c!.next)
                    earcutLinked(a2, &tris, pass: 0)
                    earcutLinked(c, &tris, pass: 0)
                    return
                }
                b = b.next
            }
            a = a.next
        } while a !== start
    }

    private func eliminateHoles(_ d: [Double], _ holes: [Int], _ outerIn: Node) -> Node {
        var queue: [Node] = []
        for (k, h) in holes.enumerated() {
            let start = h * 2
            let end = k < holes.count - 1 ? holes[k + 1] * 2 : d.count
            guard let list = linkedList(d, start, end, clockwise: false) else { continue }
            if list === list.next { list.steiner = true }
            queue.append(leftmost(list))
        }
        queue.sort { $0.x < $1.x }
        var outer = outerIn
        for h in queue {
            outer = eliminateHole(h, outer)
        }
        return outer
    }

    private func eliminateHole(_ hole: Node, _ outer: Node) -> Node {
        guard let bridge = findHoleBridge(hole, outer) else { return outer }
        let reverse = splitPolygon(bridge, hole)
        _ = filterPoints(reverse, reverse.next)
        return filterPoints(bridge, bridge.next) ?? outer
    }

    private func findHoleBridge(_ hole: Node, _ outer: Node) -> Node? {
        var p = outer
        let hx = hole.x, hy = hole.y
        var qx = -Double.infinity
        var m: Node?
        repeat {
            if hy <= p.y, hy >= p.next.y, p.next.y != p.y {
                let x = p.x + (hy - p.y) * (p.next.x - p.x) / (p.next.y - p.y)
                if x <= hx, x > qx {
                    qx = x
                    m = p.x < p.next.x ? p : p.next
                    if x == hx { return m }
                }
            }
            p = p.next
        } while p !== outer
        guard var best = m else { return nil }
        let stop = best, mx = best.x, my = best.y
        var tanMin = Double.infinity
        p = best
        repeat {
            if hx >= p.x, p.x >= mx, hx != p.x,
               pointInTriangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, p.x, p.y) {
                let tan = abs(hy - p.y) / (hx - p.x)
                if locallyInside(p, hole),
                   tan < tanMin || (tan == tanMin && (p.x > best.x || (p.x == best.x && sectorContainsSector(best, p)))) {
                    best = p
                    tanMin = tan
                }
            }
            p = p.next
        } while p !== stop
        return best
    }

    private func sectorContainsSector(_ m: Node, _ p: Node) -> Bool {
        area(m.prev, m, p.prev) < 0 && area(p.next, m, m.next) < 0
    }

    private func leftmost(_ start: Node) -> Node {
        var p = start, left = start
        repeat {
            if p.x < left.x || (p.x == left.x && p.y < left.y) { left = p }
            p = p.next
        } while p !== start
        return left
    }

    private func pointInTriangle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double,
                                        _ px: Double, _ py: Double) -> Bool {
        (cx - px) * (ay - py) >= (ax - px) * (cy - py)
            && (ax - px) * (by - py) >= (bx - px) * (ay - py)
            && (bx - px) * (cy - py) >= (cx - px) * (by - py)
    }

    private func isValidDiagonal(_ a: Node, _ b: Node) -> Bool {
        a.next.i != b.i && a.prev.i != b.i && !intersectsPolygon(a, b)
            && ((locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b)
                    && (area(a.prev, a, b.prev) != 0 || area(a, b.prev, b) != 0))
                || (equals(a, b) && area(a.prev, a, a.next) > 0 && area(b.prev, b, b.next) > 0))
    }

    private func area(_ p: Node, _ q: Node, _ r: Node) -> Double {
        (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
    }

    private func equals(_ a: Node, _ b: Node) -> Bool { a.x == b.x && a.y == b.y }

    private func intersects(_ p1: Node, _ q1: Node, _ p2: Node, _ q2: Node) -> Bool {
        let o1 = sign(area(p1, q1, p2)), o2 = sign(area(p1, q1, q2)), o3 = sign(area(p2, q2, p1)), o4 = sign(area(p2, q2, q1))
        if o1 != o2 && o3 != o4 { return true }
        if o1 == 0 && onSegment(p1, p2, q1) { return true }
        if o2 == 0 && onSegment(p1, q2, q1) { return true }
        if o3 == 0 && onSegment(p2, p1, q2) { return true }
        if o4 == 0 && onSegment(p2, q1, q2) { return true }
        return false
    }

    private func onSegment(_ p: Node, _ q: Node, _ r: Node) -> Bool {
        q.x <= max(p.x, r.x) && q.x >= min(p.x, r.x) && q.y <= max(p.y, r.y) && q.y >= min(p.y, r.y)
    }

    private func sign(_ v: Double) -> Int { v > 0 ? 1 : v < 0 ? -1 : 0 }

    private func intersectsPolygon(_ a: Node, _ b: Node) -> Bool {
        var p = a
        repeat {
            if p.i != a.i, p.next.i != a.i, p.i != b.i, p.next.i != b.i, intersects(p, p.next, a, b) { return true }
            p = p.next
        } while p !== a
        return false
    }

    private func locallyInside(_ a: Node, _ b: Node) -> Bool {
        area(a.prev, a, a.next) < 0
            ? area(a, b, a.next) >= 0 && area(a, a.prev, b) >= 0
            : area(a, b, a.prev) < 0 || area(a, a.next, b) < 0
    }

    private func middleInside(_ a: Node, _ b: Node) -> Bool {
        var p = a
        var inside = false
        let px = (a.x + b.x) / 2, py = (a.y + b.y) / 2
        repeat {
            if (p.y > py) != (p.next.y > py), p.next.y != p.y,
               px < (p.next.x - p.x) * (py - p.y) / (p.next.y - p.y) + p.x { inside.toggle() }
            p = p.next
        } while p !== a
        return inside
    }

    private func splitPolygon(_ a: Node, _ b: Node) -> Node {
        let a2 = Node(a.i, a.x, a.y), b2 = Node(b.i, b.x, b.y)
        pool.append(a2); pool.append(b2)
        let an = a.next!, bp = b.prev!
        a.next = b; b.prev = a
        a2.next = an; an.prev = a2
        b2.next = a2; a2.prev = b2
        bp.next = b2; b2.prev = bp
        return b2
    }

    private func insert(_ i: Int, _ x: Double, _ y: Double, _ last: Node?) -> Node {
        let p = Node(i, x, y)
        pool.append(p)
        if let last {
            p.next = last.next
            p.prev = last
            last.next.prev = p
            last.next = p
        } else {
            p.prev = p
            p.next = p
        }
        return p
    }

    private func remove(_ p: Node) {
        p.next.prev = p.prev
        p.prev.next = p.next
    }
}
