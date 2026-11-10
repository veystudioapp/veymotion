import CoreGraphics
import Foundation
import simd

// CPU rasterizer for model layers: z-buffer, perspective-correct interpolation, near-plane clipping, supersampled
// edges and Blinn-Phong lighting with a simple sky reflection for metals. Deterministic (no GPU), so preview, CLI
// and export match, and it runs in sandboxed processes.

/// An image a model is painted with, as straight RGBA floats (0…1), sampled bilinearly with wrapping.
final class Texture3D {
    let width: Int
    let height: Int
    private let pixels: [SIMD4<Float>]

    init?(_ image: CGImage, maxSide: Int = 2048) {
        let k = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * k)), h = max(1, Int(Double(image.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var px = [SIMD4<Float>](repeating: .zero, count: w * h)
        for i in 0..<(w * h) {
            let a = Float(data[i * 4 + 3]) / 255
            if a > 0 {
                px[i] = SIMD4(Float(data[i * 4]) / 255 / a, Float(data[i * 4 + 1]) / 255 / a, Float(data[i * 4 + 2]) / 255 / a, a)
            }
        }
        width = w; height = h; pixels = px
    }

    func sample(_ uv: SIMD2<Float>) -> SIMD4<Float> {
        var u = uv.x - floor(uv.x), v = uv.y - floor(uv.y)
        u = u * Float(width) - 0.5; v = v * Float(height) - 0.5
        let x0 = Int(floor(u)), y0 = Int(floor(v))
        let fx = u - Float(x0), fy = v - Float(y0)
        func px(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let xx = (x % width + width) % width, yy = min(max(y, 0), height - 1)
            return pixels[yy * width + xx]
        }
        let top = px(x0, y0) * (1 - fx) + px(x0 + 1, y0) * fx
        let bottom = px(x0, y0 + 1) * (1 - fx) + px(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }
}

struct Material3D {
    /// Straight RGBA 0…1.
    var color: SIMD4<Float>
    var texture: Texture3D?
}

/// A light in camera space.
struct CameraLight {
    enum Kind { case ambient, directional, point }
    var kind: Kind
    var color: SIMD3<Float>
    /// directional: unit vector toward the light; point: its position.
    var vector: SIMD3<Float>
}

enum Raster3D {
    private struct Vert {
        var p: SIMD3<Float>   // camera space
        var n: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    private struct Tri {
        var v: (Vert, Vert, Vert)
        var slot: Int
    }

    /// Draws `mesh` (layer-local, transformed by `modelView` into camera space) into an image covering `box`
    /// (device px, bottom-left origin) at `ss`× supersampling. `toRaster` maps scene points to device points.
    static func render(_ mesh: Mesh3D, modelView: simd_double4x4, view: View3D, sceneToDevice: CGAffineTransform,
                       box: CGRect, materials: [Material3D], lights: [CameraLight], shininess: Float, metallic: Float,
                       ss: Int, depth: DepthTarget? = nil) -> CGImage? {
        let bw = Int(box.width), bh = Int(box.height)
        guard bw > 0, bh > 0, !mesh.isEmpty else { return nil }
        let W = bw * ss, H = bh * ss
        // Clipped a little in front of the camera: geometry nearer than that projects to huge, imprecise coordinates.
        let near = Float(max(View3D.near, 0.005 * view.focal))

        // Camera space.
        let mv = simd_float4x4(modelView.columns.0.float, modelView.columns.1.float, modelView.columns.2.float,
                               modelView.columns.3.float)
        let upper = simd_float3x3(SIMD3(mv.columns.0.x, mv.columns.0.y, mv.columns.0.z),
                                  SIMD3(mv.columns.1.x, mv.columns.1.y, mv.columns.1.z),
                                  SIMD3(mv.columns.2.x, mv.columns.2.y, mv.columns.2.z))
        let det = simd_determinant(upper)
        let normalMatrix = abs(det) > 1e-12 ? simd_transpose(simd_inverse(upper)) : upper
        let verts: [Vert] = mesh.positions.indices.map { i in
            let p = mv * SIMD4(mesh.positions[i], 1)
            var n = normalMatrix * mesh.normals[i]
            let len = simd_length(n)
            n = len > 1e-9 ? n / len : SIMD3(0, 0, -1)
            return Vert(p: SIMD3(p.x, p.y, p.z), n: n, uv: mesh.uvs[i])
        }

        // Camera space → raster px (y down from the top of the box).
        let proj = view.projection
        let toRaster = sceneToDevice.concatenating(CGAffineTransform(a: CGFloat(ss), b: 0, c: 0, d: -CGFloat(ss),
                                                                     tx: -box.minX * CGFloat(ss), ty: box.maxY * CGFloat(ss)))
        // In doubles: large triangles reaching toward the camera project far outside the box, and their edge
        // functions lose the precision that decides which of two nearly equal depths wins.
        let p0 = proj[0], p1 = proj[1], p2 = proj[2], p3 = proj[3], p4 = proj[4], p5 = proj[5]
        let ra = Double(toRaster.a), rb = Double(toRaster.b), rc = Double(toRaster.c), rd = Double(toRaster.d)
        let rtx = Double(toRaster.tx), rty = Double(toRaster.ty)
        @inline(__always) func screen(_ p: SIMD3<Float>) -> SIMD2<Double> {
            let x = Double(p.x), y = Double(p.y), z = Double(p.z)
            let sx = (p0 * x + p1 * y) / z + p2, sy = (p3 * x + p4 * y) / z + p5
            return SIMD2(ra * sx + rc * sy + rtx, rb * sx + rd * sy + rty)
        }

        // Triangles in front of the near plane (clipped where they cross it).
        var tris: [Tri] = []
        tris.reserveCapacity(mesh.slots.count)
        func lerp(_ a: Vert, _ b: Vert, _ t: Float) -> Vert {
            Vert(p: a.p + (b.p - a.p) * t, n: simd_normalize(a.n + (b.n - a.n) * t), uv: a.uv + (b.uv - a.uv) * t)
        }
        for k in mesh.slots.indices {
            let a = verts[Int(mesh.indices[3 * k])], b = verts[Int(mesh.indices[3 * k + 1])], c = verts[Int(mesh.indices[3 * k + 2])]
            let slot = Int(mesh.slots[k])
            let inA = a.p.z > near, inB = b.p.z > near, inC = c.p.z > near
            if inA && inB && inC { tris.append(Tri(v: (a, b, c), slot: slot)); continue }
            if !inA && !inB && !inC { continue }
            // Sutherland–Hodgman against z = near.
            var poly: [Vert] = []
            let input = [a, b, c]
            for i in 0..<3 {
                let cur = input[i], nxt = input[(i + 1) % 3]
                let cin = cur.p.z > near, nin = nxt.p.z > near
                if cin { poly.append(cur) }
                if cin != nin {
                    let t = (near - cur.p.z) / (nxt.p.z - cur.p.z)
                    var v = lerp(cur, nxt, t)
                    v.p.z = near + 1e-3
                    poly.append(v)
                }
            }
            if poly.count >= 3 {
                for i in 1..<(poly.count - 1) { tris.append(Tri(v: (poly[0], poly[i], poly[i + 1]), slot: slot)) }
            }
        }
        guard !tris.isEmpty else { return nil }

        // Visibility: nearest triangle per sample, with perspective-correct barycentrics of its first two corners.
        var zbuf = [Float](repeating: .infinity, count: W * H)
        var owner = [Int32](repeating: -1, count: W * H)
        var bary = [SIMD2<Float>](repeating: .zero, count: W * H)
        // What the frame's earlier 3D layers already show nearer: those samples stay empty.
        if let zb = depth?.buffer {
            let x0 = Int(box.minX), yTop = Int(box.maxY) - 1
            for y in 0..<H {
                let devY = yTop - y / ss
                guard devY >= 0, devY < zb.height else { continue }
                for x in 0..<W {
                    let devX = x0 + x / ss
                    guard devX >= 0, devX < zb.width else { continue }
                    let limit = zb.limit(at: devY * zb.width + devX)
                    if limit.isFinite { zbuf[y * W + x] = limit }
                }
            }
        }
        zbuf.withUnsafeMutableBufferPointer { z in
            owner.withUnsafeMutableBufferPointer { o in
                bary.withUnsafeMutableBufferPointer { br in
                    for (ti, tri) in tris.enumerated() {
                        let s0 = screen(tri.v.0.p), s1 = screen(tri.v.1.p), s2 = screen(tri.v.2.p)
                        let area = (s1.x - s0.x) * (s2.y - s0.y) - (s2.x - s0.x) * (s1.y - s0.y)
                        guard abs(area) > 1e-9, area.isFinite else { continue }
                        let lox = min(s0.x, s1.x, s2.x), hix = max(s0.x, s1.x, s2.x)
                        let loy = min(s0.y, s1.y, s2.y), hiy = max(s0.y, s1.y, s2.y)
                        guard hix >= 0, lox < Double(W), hiy >= 0, loy < Double(H) else { continue }
                        let minX = max(0, Int(floor(lox))), maxX = min(W - 1, Int(ceil(hix)))
                        let minY = max(0, Int(floor(loy))), maxY = min(H - 1, Int(ceil(hiy)))
                        guard minX <= maxX, minY <= maxY else { continue }
                        let iz0 = 1 / Double(tri.v.0.p.z), iz1 = 1 / Double(tri.v.1.p.z), iz2 = 1 / Double(tri.v.2.p.z)
                        let inv = 1 / area
                        let e0dx = (s1.y - s2.y) * inv, e1dx = (s2.y - s0.y) * inv
                        for y in minY...maxY {
                            let py = Double(y) + 0.5
                            let px0 = Double(minX) + 0.5
                            // Each row starts from the exact value; steps along it stay within a few thousand.
                            var w0 = ((s1.x - px0) * (s2.y - py) - (s2.x - px0) * (s1.y - py)) * inv
                            var w1 = ((s2.x - px0) * (s0.y - py) - (s0.x - px0) * (s2.y - py)) * inv
                            let row = y * W
                            for x in minX...maxX {
                                let w2 = 1 - w0 - w1
                                if w0 >= -1e-9, w1 >= -1e-9, w2 >= -1e-9 {
                                    let depth = 1 / (w0 * iz0 + w1 * iz1 + w2 * iz2)
                                    let idx = row + x
                                    if Float(depth) < z[idx] {
                                        z[idx] = Float(depth)
                                        o[idx] = Int32(ti)
                                        br[idx] = SIMD2(Float(w0 * iz0 * depth), Float(w1 * iz1 * depth))
                                    }
                                }
                                w0 += e0dx
                                w1 += e1dx
                            }
                        }
                    }
                }
            }
        }

        // Shading.
        let exponent = 2 + 220 * shininess * shininess
        let specStrength = 0.08 + 0.7 * shininess + 0.3 * metallic
        func shade(_ base: SIMD4<Float>, _ nIn: SIMD3<Float>, _ p: SIMD3<Float>) -> SIMD4<Float> {
            let v = simd_normalize(-p)
            var n = nIn
            if simd_dot(n, v) < 0 { n = -n } // both sides are lit
            let albedo = SIMD3(base.x, base.y, base.z)
            var diffuse = SIMD3<Float>(repeating: 0), spec = SIMD3<Float>(repeating: 0)
            for l in lights {
                switch l.kind {
                case .ambient:
                    diffuse += l.color
                case .directional, .point:
                    let L = l.kind == .directional ? l.vector : simd_normalize(l.vector - p)
                    let nl = simd_dot(n, L)
                    guard nl > 0 else { continue }
                    diffuse += l.color * nl
                    let h = simd_normalize(L + v)
                    spec += l.color * pow(max(0, simd_dot(n, h)), exponent)
                }
            }
            var rgb = albedo * diffuse * (1 - 0.75 * metallic)
            let specColor = SIMD3<Float>(repeating: 1) * (1 - metallic) + albedo * metallic
            rgb += spec * specColor * specStrength
            if metallic > 0 {
                // A sky above (bright) and ground below (dark), reflected.
                let r = simd_reflect(-v, n)
                let sky = 0.5 - 0.5 * r.y
                rgb += albedo * (0.12 + 0.88 * sky * sky) * metallic * 0.7
            }
            return SIMD4(simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1)), base.w)
        }

        // Resolve: shade each covered sample, average the samples of each pixel (premultiplied).
        guard let ctx = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let out = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = ctx.bytesPerRow
        let samples = Float(ss * ss)
        let zb = depth?.writes == true ? depth?.buffer : nil
        for y in 0..<bh {
            for x in 0..<bw {
                var acc = SIMD4<Float>(repeating: 0)
                var nearest = Float.infinity
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let idx = (y * ss + sy) * W + x * ss + sx
                        let ti = owner[idx]
                        guard ti >= 0 else { continue }
                        let tri = tris[Int(ti)]
                        let b = bary[idx], b2 = 1 - b.x - b.y
                        let n = tri.v.0.n * b.x + tri.v.1.n * b.y + tri.v.2.n * b2
                        let p = tri.v.0.p * b.x + tri.v.1.p * b.y + tri.v.2.p * b2
                        let mat = tri.slot < materials.count ? materials[tri.slot] : materials[0]
                        var base = mat.color
                        if let tex = mat.texture {
                            let uv = tri.v.0.uv * b.x + tri.v.1.uv * b.y + tri.v.2.uv * b2
                            base *= tex.sample(uv)
                        }
                        let c = shade(base, simd_normalize(n), p)
                        acc += SIMD4(c.x * c.w, c.y * c.w, c.z * c.w, c.w)
                        nearest = min(nearest, zbuf[idx])
                    }
                }
                guard acc.w > 0 else { continue }
                acc /= samples
                if let zb, acc.w >= 0.5 {
                    let devX = Int(box.minX) + x, devY = Int(box.maxY) - 1 - y
                    if devX >= 0, devX < zb.width, devY >= 0, devY < zb.height { zb.record(nearest, at: devY * zb.width + devX) }
                }
                let q = out + y * rowBytes + x * 4
                q[0] = UInt8(min(255, acc.x * 255 + 0.5)); q[1] = UInt8(min(255, acc.y * 255 + 0.5))
                q[2] = UInt8(min(255, acc.z * 255 + 0.5)); q[3] = UInt8(min(255, acc.w * 255 + 0.5))
            }
        }
        return ctx.makeImage()
    }
}

private extension SIMD4 where Scalar == Double {
    var float: SIMD4<Float> { SIMD4<Float>(Float(x), Float(y), Float(z), Float(w)) }
}
