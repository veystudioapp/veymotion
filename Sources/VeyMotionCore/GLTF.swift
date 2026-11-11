import CoreGraphics
import Foundation
import ImageIO
import simd

/// glTF 2.0: .glb, or .gltf with its buffers and images embedded (data URIs) or in files next to it. Every mesh of the
/// default scene is placed by its node transforms (skinned ones by their joints); a material is its base color factor
/// × base color texture. Files with animations come with a `GLTFRig` that poses the mesh at any time of a clip
/// (node translation/rotation/scale and skinning; morph targets are not played). Read here (no ModelIO), so it also
/// loads in sandboxed processes. Draco/meshopt-compressed meshes are not supported.
enum GLTFFile {
    /// The mesh in its rest pose, and the rig when the file has animations.
    static func load(_ url: URL) throws -> (mesh: Mesh3D, rig: GLTFRig?) {
        try reader(url).model()
    }

    /// The file's animation clips, in file order.
    static func animations(_ url: URL) throws -> [ModelAnimation] {
        try reader(url).clipList().map { ModelAnimation(name: $0.name, duration: Double($0.end - $0.start)) }
    }

    private static func reader(_ url: URL) throws -> Reader {
        let name = url.lastPathComponent
        let (json, bin) = try chunks(try Data(contentsOf: url, options: .mappedIfSafe), name: name)
        let doc: Doc
        do { doc = try JSONDecoder().decode(Doc.self, from: json) } catch {
            throw SceneError.invalid("Cannot read \(name): not a valid glTF file")
        }
        let compressed = (doc.extensionsRequired ?? []).filter {
            ["KHR_draco_mesh_compression", "EXT_meshopt_compression", "KHR_meshopt_compression"].contains($0)
        }
        if !compressed.isEmpty {
            throw SceneError.invalid("\(name) uses \(compressed.joined(separator: ", ")), which is not supported: export it without mesh compression")
        }
        return Reader(doc: doc, name: name, base: url.deletingLastPathComponent(), bin: bin)
    }

    /// A .glb's JSON and BIN chunks; any other file is taken as .gltf JSON.
    private static func chunks(_ data: Data, name: String) throws -> (json: Data, bin: Data?) {
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        guard data.count >= 12, u32(0) == 0x4654_6C67 else { return (data, nil) }
        guard u32(4) == 2 else { throw SceneError.invalid("\(name) is glTF version \(u32(4)); only glTF 2 is supported") }
        var json: Data?, bin: Data?
        let end = min(Int(u32(8)), data.count)
        var o = 12
        while o + 8 <= end {
            let len = Int(u32(o)), type = u32(o + 4), start = o + 8
            guard start + len <= end else { break }
            if type == 0x4E4F_534A, json == nil { json = data.subdata(in: start..<start + len) }
            if type == 0x004E_4942, bin == nil { bin = data.subdata(in: start..<start + len) }
            o = start + ((len + 3) & ~3)
        }
        guard let json else { throw SceneError.invalid("Cannot read \(name): no JSON chunk") }
        return (json, bin)
    }

    // MARK: Document

    private struct Doc: Decodable {
        var scene: Int?
        var scenes: [SceneDef]?
        var nodes: [Node]?
        var meshes: [MeshDef]?
        var skins: [SkinDef]?
        var animations: [AnimationDef]?
        var accessors: [Accessor]?
        var bufferViews: [BufferView]?
        var buffers: [Buffer]?
        var materials: [Material]?
        var textures: [Texture]?
        var images: [Image]?
        var extensionsRequired: [String]?
    }
    private struct SceneDef: Decodable { var nodes: [Int]? }
    private struct Node: Decodable {
        var children: [Int]?
        var mesh: Int?
        var skin: Int?
        var matrix: [Float]?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?

        var rest: GLTFRig.NodePose {
            var p = GLTFRig.NodePose()
            if let m = matrix, m.count == 16 {
                p.matrix = simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                         SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
            }
            if let t = translation, t.count == 3 { p.t = SIMD3(t[0], t[1], t[2]) }
            if let r = rotation, r.count == 4 {
                let q = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3])
                if simd_length(q.vector) > 0 { p.r = q.normalized }
            }
            if let s = scale, s.count == 3 { p.s = SIMD3(s[0], s[1], s[2]) }
            return p
        }
    }
    private struct MeshDef: Decodable { var primitives: [Primitive] }
    private struct Primitive: Decodable {
        var attributes: [String: Int]
        var indices: Int?
        var material: Int?
        var mode: Int?
    }
    private struct SkinDef: Decodable {
        var joints: [Int]
        var inverseBindMatrices: Int?
    }
    private struct AnimationDef: Decodable {
        struct Channel: Decodable {
            struct Target: Decodable { var node: Int?; var path: String }
            var sampler: Int
            var target: Target
        }
        struct Sampler: Decodable { var input: Int; var output: Int; var interpolation: String? }
        var name: String?
        var channels: [Channel]
        var samplers: [Sampler]
    }
    private struct Accessor: Decodable {
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var normalized: Bool?
        var count: Int
        var type: String
    }
    private struct BufferView: Decodable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
    }
    private struct Buffer: Decodable { var uri: String? }
    private struct Material: Decodable {
        var pbrMetallicRoughness: PBR?
        var alphaMode: String?
    }
    private struct PBR: Decodable {
        var baseColorFactor: [Double]?
        var baseColorTexture: TextureRef?
    }
    private struct TextureRef: Decodable {
        var index: Int
        var texCoord: Int?
    }
    private struct Texture: Decodable {
        struct Source: Decodable { var source: Int? }
        var source: Int?
        /// EXT_texture_webp and the like name their image here.
        var extensions: [String: Source]?
    }
    private struct Image: Decodable {
        var uri: String?
        var bufferView: Int?
    }

    // MARK: Reading

    private final class Reader {
        let doc: Doc
        let name: String
        let base: URL
        let bin: Data?
        var buffers: [Int: Data] = [:]
        var textures: [Int: Texture3D?] = [:]
        var slots: [Int: UInt16] = [:]
        let m = Mesh3D()
        let rig = GLTFRig()

        init(doc: Doc, name: String, base: URL, bin: Data?) {
            self.doc = doc; self.name = name; self.base = base; self.bin = bin
        }

        func broken(_ what: String) -> Error { SceneError.invalid("Cannot read \(name): broken \(what)") }

        func model() throws -> (mesh: Mesh3D, rig: GLTFRig?) {
            let nodes = doc.nodes ?? []
            rig.nodes = nodes.map(\.rest)
            rig.parents = [Int](repeating: -1, count: nodes.count)
            for (i, n) in nodes.enumerated() {
                for c in n.children ?? [] where rig.parents.indices.contains(c) && c != i { rig.parents[c] = i }
            }
            for s in doc.skins ?? [] {
                let joints = s.joints.filter { nodes.indices.contains($0) }
                var inverse = [simd_float4x4](repeating: matrix_identity_float4x4, count: joints.count)
                if joints.count == s.joints.count, let a = s.inverseBindMatrices {
                    let v = try values(a)
                    if v.n == 16, v.v.count >= joints.count * 16 {
                        for j in joints.indices {
                            let f = (0..<16).map { Float(v.v[j * 16 + $0]) }
                            inverse[j] = simd_float4x4(SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                                                       SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15]))
                        }
                    }
                }
                // A skin naming nodes that do not exist cannot be posed: its meshes stay rigid.
                rig.skins.append(joints.count == s.joints.count ? GLTFRig.Skin(joints: joints, inverseBind: inverse) : nil)
            }
            rig.clips = try clipList()

            let roots: [Int]
            if let scene = doc.scenes?[safe: doc.scene ?? 0] {
                roots = scene.nodes ?? []
            } else {
                roots = nodes.indices.filter { rig.parents[$0] < 0 }
            }
            let world = rig.worldMatrices(rig.nodes)
            var visited = Set<Int>()
            func walk(_ i: Int) throws {
                guard let node = nodes[safe: i], visited.insert(i).inserted else { return }
                if let mesh = node.mesh.flatMap({ doc.meshes?[safe: $0] }) {
                    let skin = node.skin.flatMap { rig.skins[safe: $0] ?? nil } != nil ? node.skin : nil
                    for p in mesh.primitives { try add(p, node: i, skin: skin, mirrored: skin == nil && simd_determinant(world[i].upper3) < 0) }
                }
                for c in node.children ?? [] { try walk(c) }
            }
            for r in roots { try walk(r) }

            let rest = rig.pose(nil, at: 0)
            m.positions = rest.positions
            m.normals = rest.normals
            return (m, rig.clips.isEmpty ? nil : rig)
        }

        /// Clips with their channels; a clip runs from its earliest to its latest key.
        func clipList() throws -> [GLTFRig.Clip] {
            let nodeCount = doc.nodes?.count ?? 0
            return try (doc.animations ?? []).enumerated().map { ai, a in
                var clip = GLTFRig.Clip(name: a.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Animation \(ai + 1)")
                for ch in a.channels {
                    guard let node = ch.target.node, node < nodeCount, node >= 0,
                          let path = GLTFRig.Path(rawValue: ch.target.path), let s = a.samplers[safe: ch.sampler] else { continue }
                    let times = try values(s.input).v.map { Float($0) }
                    let out = try values(s.output)
                    let interpolation: GLTFRig.Interpolation = s.interpolation == "STEP" ? .step : s.interpolation == "CUBICSPLINE" ? .cubic : .linear
                    let per = interpolation == .cubic ? 3 : 1
                    let width = path == .rotation ? 4 : 3
                    guard !times.isEmpty, out.n == width, out.v.count >= times.count * per * width else { continue }
                    var keys = (0..<(times.count * per)).map { e in
                        SIMD4(Float(out.v[e * width]), Float(out.v[e * width + 1]), Float(out.v[e * width + 2]),
                              width == 4 ? Float(out.v[e * width + 3]) : 0)
                    }
                    if path == .rotation && interpolation != .cubic {
                        keys = keys.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD4(0, 0, 0, 1) }
                    }
                    clip.channels.append(GLTFRig.Channel(node: node, path: path, interpolation: interpolation, times: times, keys: keys))
                    clip.start = min(clip.start, times.first!)
                    clip.end = max(clip.end, times.last!)
                }
                if clip.channels.isEmpty { clip.start = 0; clip.end = 0 }
                return clip
            }
        }

        /// Adds a primitive's triangles in its node's space (its skin's for skinned meshes).
        func add(_ p: Primitive, node: Int, skin: Int?, mirrored: Bool) throws {
            let mode = p.mode ?? 4
            guard (4...6).contains(mode), let pa = p.attributes["POSITION"] else { return }
            let pos = try values(pa)
            guard pos.n == 3 else { return }
            let count = pos.v.count / 3
            let material = p.material.flatMap { doc.materials?[safe: $0] }
            let nrm = try p.attributes["NORMAL"].map(values).flatMap { $0.n == 3 && $0.v.count == count * 3 ? $0.v : nil }
            let uvSet = material?.pbrMetallicRoughness?.baseColorTexture?.texCoord ?? 0
            let uv = try p.attributes["TEXCOORD_\(uvSet)"].map(values).flatMap { $0.n == 2 && $0.v.count == count * 2 ? $0.v : nil }
            var joints: [Double]?, weights: [Double]?
            if skin != nil {
                joints = try p.attributes["JOINTS_0"].map(values).flatMap { $0.n == 4 && $0.v.count == count * 4 ? $0.v : nil }
                weights = try p.attributes["WEIGHTS_0"].map(values).flatMap { $0.n == 4 && $0.v.count == count * 4 ? $0.v : nil }
            }
            let skinned = joints != nil && weights != nil
            let idx = try p.indices.map { try values($0).v.map { Int($0) } } ?? Array(0..<count)

            var tris: [(Int, Int, Int)] = []
            switch mode {
            case 5: for i in 0..<max(idx.count - 2, 0) { tris.append(i % 2 == 0 ? (idx[i], idx[i + 1], idx[i + 2]) : (idx[i], idx[i + 2], idx[i + 1])) }
            case 6: for i in 1..<max(idx.count - 1, 1) { tris.append((idx[0], idx[i], idx[i + 1])) }
            default: for i in stride(from: 0, to: idx.count - 2, by: 3) { tris.append((idx[i], idx[i + 1], idx[i + 2])) }
            }
            tris = tris.filter { a, b, c in a < count && b < count && c < count && a != b && b != c && a != c }

            func point(_ i: Int) -> SIMD3<Float> { SIMD3(Float(pos.v[i * 3]), Float(pos.v[i * 3 + 1]), Float(pos.v[i * 3 + 2])) }
            func texCoord(_ i: Int) -> SIMD2<Float> { uv.map { SIMD2(Float($0[i * 2]), Float($0[i * 2 + 1])) } ?? .zero }
            let skinCount = skin.flatMap { rig.skins[$0]?.joints.count } ?? 0
            @discardableResult
            func vertex(_ i: Int, _ n: SIMD3<Float>) -> UInt32 {
                rig.local.append(point(i))
                rig.localNormals.append(n)
                if skinned, let joints, let weights {
                    var j = SIMD4<UInt16>(repeating: 0), w = SIMD4<Float>(repeating: 0)
                    for k in 0..<4 {
                        let ji = Int(joints[i * 4 + k])
                        guard ji >= 0, ji < skinCount else { continue }
                        j[k] = UInt16(ji); w[k] = max(0, Float(weights[i * 4 + k]))
                    }
                    rig.joints.append(j); rig.weights.append(w)
                } else {
                    rig.joints.append(.zero); rig.weights.append(.zero)
                }
                return m.vertex(.zero, .zero, texCoord(i))
            }
            let slot = p.material.map(slot(for:)) ?? 0
            let first = m.positions.count

            if let nrm {
                let base = UInt32(first)
                for i in 0..<count {
                    let n = SIMD3(Float(nrm[i * 3]), Float(nrm[i * 3 + 1]), Float(nrm[i * 3 + 2]))
                    vertex(i, simd_length(n) > 0 ? simd_normalize(n) : SIMD3(0, 1, 0))
                }
                for (a, b, c) in tris {
                    let (a, b, c) = (base + UInt32(a), base + UInt32(b), base + UInt32(c))
                    // A mirroring transform turns the winding around.
                    if mirrored { m.triangle(a, c, b, slot: slot) } else { m.triangle(a, b, c, slot: slot) }
                }
            } else {
                // No normals: flat shading, as the spec asks.
                for (a, b, c) in tris {
                    var n = simd_cross(point(b) - point(a), point(c) - point(a))
                    let len = simd_length(n)
                    n = len > 0 ? n / len : SIMD3(0, 1, 0)
                    let (va, vb, vc) = (vertex(a, n), vertex(b, n), vertex(c, n))
                    if mirrored { m.triangle(va, vc, vb, slot: slot) } else { m.triangle(va, vb, vc, slot: slot) }
                }
            }
            if m.positions.count > first {
                rig.parts.append(GLTFRig.Part(range: first..<m.positions.count, node: node, skin: skinned ? skin : nil))
            }
        }

        /// An accessor's elements as doubles, `n` per element; normalized integers become 0…1 / -1…1.
        func values(_ i: Int) throws -> (v: [Double], n: Int) {
            guard let a = doc.accessors?[safe: i], a.count >= 0 else { throw broken("accessor \(i)") }
            let n = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16][a.type] ?? 1
            var out = [Double](repeating: 0, count: a.count * n)
            guard let vi = a.bufferView, a.count > 0 else { return (out, n) }
            let size: Int
            switch a.componentType {
            case 5120, 5121: size = 1
            case 5122, 5123: size = 2
            case 5125, 5126: size = 4
            default: throw broken("accessor \(i)")
            }
            let (data, start, stride) = try view(vi, offset: a.byteOffset ?? 0, elementSize: size * n)
            guard start >= 0, stride > 0, start + (a.count - 1) * stride + size * n <= data.count else { throw broken("accessor \(i)") }
            let normalized = a.normalized ?? false
            data.withUnsafeBytes { raw in
                for e in 0..<a.count {
                    for k in 0..<n {
                        let o = start + e * stride + k * size
                        let x: Double
                        switch a.componentType {
                        case 5120: let q = Double(raw.load(fromByteOffset: o, as: Int8.self)); x = normalized ? max(q / 127, -1) : q
                        case 5121: let q = Double(raw.load(fromByteOffset: o, as: UInt8.self)); x = normalized ? q / 255 : q
                        case 5122: let q = Double(raw.loadUnaligned(fromByteOffset: o, as: Int16.self)); x = normalized ? max(q / 32767, -1) : q
                        case 5123: let q = Double(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self)); x = normalized ? q / 65535 : q
                        case 5125: x = Double(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                        default: x = Double(raw.loadUnaligned(fromByteOffset: o, as: Float.self))
                        }
                        out[e * n + k] = x
                    }
                }
            }
            return (out, n)
        }

        /// A buffer view's buffer, the byte where `offset` into the view starts, and the element stride.
        func view(_ i: Int, offset: Int, elementSize: Int) throws -> (Data, Int, Int) {
            guard let v = doc.bufferViews?[safe: i] else { throw broken("buffer view \(i)") }
            let data = try buffer(v.buffer)
            let start = (v.byteOffset ?? 0) + offset
            guard (v.byteOffset ?? 0) + v.byteLength <= data.count else { throw broken("buffer view \(i)") }
            return (data, start, v.byteStride ?? elementSize)
        }

        func buffer(_ i: Int) throws -> Data {
            if let d = buffers[i] { return d }
            guard let b = doc.buffers?[safe: i] else { throw broken("buffer \(i)") }
            let d: Data
            if let uri = b.uri {
                guard let r = resource(uri) else { throw broken("buffer \(i) (\(uri.hasPrefix("data:") ? "embedded data" : uri))") }
                d = r
            } else if let bin {
                d = bin
            } else {
                throw broken("buffer \(i)")
            }
            buffers[i] = d
            return d
        }

        func resource(_ uri: String) -> Data? {
            if uri.hasPrefix("data:") {
                guard let comma = uri.firstIndex(of: ",") else { return nil }
                return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
            }
            return try? Data(contentsOf: base.appendingPathComponent(uri.removingPercentEncoding ?? uri))
        }

        func slot(for i: Int) -> UInt16 {
            if let s = slots[i] { return s }
            m.fileMaterials.append(look(doc.materials?[safe: i]))
            let s = UInt16(1 + m.fileMaterials.count)
            slots[i] = s
            return s
        }

        func look(_ mat: Material?) -> (color: RGBA, texture: Texture3D?) {
            let pbr = mat?.pbrMetallicRoughness
            let f = pbr?.baseColorFactor ?? []
            // Factors are linear; RGBA is sRGB.
            func srgb(_ k: Int) -> Double {
                let c = min(max(k < f.count ? f[k] : 1, 0), 1)
                return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            }
            let opaque = (mat?.alphaMode ?? "OPAQUE") == "OPAQUE"
            let color = RGBA(r: srgb(0), g: srgb(1), b: srgb(2), a: opaque ? 1 : min(max(f.count > 3 ? f[3] : 1, 0), 1))
            return (color, pbr?.baseColorTexture.flatMap { texture($0.index) })
        }

        func texture(_ i: Int) -> Texture3D? {
            guard let t = doc.textures?[safe: i],
                  let source = t.source ?? t.extensions?.values.compactMap(\.source).first else { return nil }
            if let cached = textures[source] { return cached }
            var out: Texture3D?
            if let image = doc.images?[safe: source] {
                var data: Data?
                if let vi = image.bufferView, let v = doc.bufferViews?[safe: vi], case let (buf, start, _)? = try? view(vi, offset: 0, elementSize: 1) {
                    data = buf.subdata(in: start..<start + v.byteLength)
                } else if let uri = image.uri {
                    data = resource(uri)
                }
                if let data, let src = CGImageSourceCreateWithData(data as CFData, nil),
                   let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    out = Texture3D(img)
                }
            }
            textures[source] = out
            return out
        }
    }
}

// MARK: - Rig

/// A glTF file's nodes, skins and clips, with every vertex in its node's space (or its skin's), so the mesh can be
/// posed at any time of a clip. Positions come out in the file's axes; `ModelFile` turns and fits them.
final class GLTFRig {
    struct NodePose {
        /// Nodes given as a matrix are not animated (the spec asks for TRS on animated nodes).
        var matrix: simd_float4x4?
        var t = SIMD3<Float>(repeating: 0)
        var r = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        var s = SIMD3<Float>(repeating: 1)

        var local: simd_float4x4 {
            if let matrix { return matrix }
            var m = simd_float4x4(r) * simd_float4x4(diagonal: SIMD4(s, 1))
            m.columns.3 = SIMD4(t, 1)
            return m
        }
    }
    struct Skin { var joints: [Int]; var inverseBind: [simd_float4x4] }
    struct Part { var range: Range<Int>; var node: Int; var skin: Int? }
    enum Path: String { case translation, rotation, scale }
    enum Interpolation { case step, linear, cubic }
    struct Channel {
        var node: Int
        var path: Path
        var interpolation: Interpolation
        var times: [Float]
        /// One per key (in-tangent, value, out-tangent for cubic); vec3s have w = 0.
        var keys: [SIMD4<Float>]

        func sample(_ t: Float) -> SIMD4<Float> {
            let cubic = interpolation == .cubic
            func value(_ k: Int) -> SIMD4<Float> { keys[cubic ? k * 3 + 1 : k] }
            guard times.count > 1, t > times[0] else { return value(0) }
            guard t < times[times.count - 1] else { return value(times.count - 1) }
            var lo = 0, hi = times.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if times[mid] <= t { lo = mid } else { hi = mid }
            }
            let td = times[lo + 1] - times[lo]
            let s = td > 0 ? (t - times[lo]) / td : 0
            switch interpolation {
            case .step:
                return value(lo)
            case .linear:
                if path == .rotation {
                    return simd_slerp(simd_quatf(vector: keys[lo]), simd_quatf(vector: keys[lo + 1]), s).vector
                }
                return keys[lo] + (keys[lo + 1] - keys[lo]) * s
            case .cubic:
                let s2 = s * s, s3 = s2 * s
                let a: SIMD4<Float> = (2 * s3 - 3 * s2 + 1) * keys[lo * 3 + 1] + td * (s3 - 2 * s2 + s) * keys[lo * 3 + 2]
                let b: SIMD4<Float> = (-2 * s3 + 3 * s2) * keys[lo * 3 + 4] + td * (s3 - s2) * keys[lo * 3 + 3]
                return a + b
            }
        }
    }
    struct Clip {
        var name: String
        var start: Float = .infinity
        var end: Float = -.infinity
        var channels: [Channel] = []

        init(name: String) { self.name = name }
    }

    var nodes: [NodePose] = []
    var parents: [Int] = []
    var skins: [Skin?] = []
    var clips: [Clip] = []
    var parts: [Part] = []
    var local: [SIMD3<Float>] = []
    var localNormals: [SIMD3<Float>] = []
    var joints: [SIMD4<UInt16>] = []
    var weights: [SIMD4<Float>] = []

    func worldMatrices(_ poses: [NodePose]) -> [simd_float4x4] {
        var world = [simd_float4x4?](repeating: nil, count: poses.count)
        for i in poses.indices where world[i] == nil {
            // Up to the first placed ancestor (a cycle stops after every node), then back down.
            var chain = [i]
            while chain.count <= poses.count, let p = parents[safe: chain.last!], p >= 0, world[p] == nil { chain.append(p) }
            let top = parents[safe: chain.last!] ?? -1
            var m = top >= 0 ? world[top] ?? matrix_identity_float4x4 : matrix_identity_float4x4
            for n in chain.reversed() {
                m = m * poses[n].local
                world[n] = m
            }
        }
        return world.map { $0 ?? matrix_identity_float4x4 }
    }

    /// Positions and normals with clip `clip` at `time` seconds into it (nil = the rest pose).
    func pose(_ clip: Int?, at time: Double) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        var poses = nodes
        if let clip, let c = clips[safe: clip] {
            let t = c.start + Float(time)
            for ch in c.channels where poses.indices.contains(ch.node) {
                let v = ch.sample(t)
                poses[ch.node].matrix = nil
                switch ch.path {
                case .translation: poses[ch.node].t = SIMD3(v.x, v.y, v.z)
                case .rotation: if simd_length(v) > 0 { poses[ch.node].r = simd_quatf(vector: simd_normalize(v)) }
                case .scale: poses[ch.node].s = SIMD3(v.x, v.y, v.z)
                }
            }
        }
        let world = worldMatrices(poses)
        var positions = local, normals = localNormals
        func unit(_ n: SIMD3<Float>) -> SIMD3<Float> {
            let len = simd_length(n)
            return len > 0 && len.isFinite ? n / len : SIMD3(0, 1, 0)
        }
        for part in parts {
            let rigid = world[safe: part.node] ?? matrix_identity_float4x4
            if let s = part.skin, let skin = skins[safe: s] ?? nil {
                let jointMatrices = skin.joints.indices.map { world[skin.joints[$0]] * skin.inverseBind[$0] }
                for v in part.range {
                    let w = weights[v], j = joints[v]
                    let sum = w.sum()
                    var m = rigid
                    if sum > 0 {
                        m = simd_float4x4()
                        for k in 0..<4 where w[k] > 0 { m += (w[k] / sum) * jointMatrices[Int(j[k])] }
                    }
                    let p = m * SIMD4(local[v], 1)
                    positions[v] = SIMD3(p.x, p.y, p.z)
                    normals[v] = unit(m.upper3 * localNormals[v])
                }
            } else {
                let nm = simd_transpose(simd_inverse(rigid.upper3))
                for v in part.range {
                    let p = rigid * SIMD4(local[v], 1)
                    positions[v] = SIMD3(p.x, p.y, p.z)
                    normals[v] = unit(nm * localNormals[v])
                }
            }
        }
        return (positions, normals)
    }
}

private extension simd_float4x4 {
    var upper3: simd_float3x3 {
        simd_float3x3(SIMD3(columns.0.x, columns.0.y, columns.0.z), SIMD3(columns.1.x, columns.1.y, columns.1.z),
                      SIMD3(columns.2.x, columns.2.y, columns.2.z))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
