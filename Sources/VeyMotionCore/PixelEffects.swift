import Accelerate
import CoreGraphics
import Foundation

// Pixel effects of a layer (keying, distortions, stylize, directional and zoom blur), run on the CPU over the bitmap
// the renderer draws the layer into. Every amount is an animatable property; 0 turns an effect off. Nothing is
// carried between frames: random looks (grain, glitch) are seeded by the layer id and the frame number.

/// The effects of one layer at one time.
struct PixelEffects {
    var keyColor: RGBA?
    var keyTolerance = 0.0, keySoftness = 0.0
    var wave = 0.0, ripple = 0.0, waveLength = 120.0, waveSpeed = 1.0
    var twirl = 0.0, bulge = 0.0, radius = 300.0, turbulence = 0.0
    var colors: ColorMatrix?
    var posterize = 0.0, pixelate = 0.0
    var directionalBlur = 0.0, blurAngle = 0.0, zoomBlur = 0.0
    var rgbSplit = 0.0, glitch = 0.0, grain = 0.0, scanlines = 0.0, vignette = 0.0
    var rays = 0.0, raysLength = 0.6, outline = 0.0, innerGlow = 0.0, innerGlowRadius = 20.0
    var outlineColor = RGBA.white, innerGlowColor = RGBA.white
    var shine = 0.0
    var goo = 0.0, halftone = 0.0
    var grading: Grading?
    var time = 0.0
    var frame = 0
    var seed: UInt64 = 0

    init(_ layer: MotionLayer, at t: Double, fps: Int) {
        func v(_ p: AnimProperty) -> Double { layer.value(p, at: t) }
        keyColor = layer.keyColor
        keyTolerance = max(0, v(.keyTolerance)); keySoftness = max(0, v(.keySoftness))
        wave = v(.waveWarp); ripple = v(.ripple)
        waveLength = max(4, v(.waveLength)); waveSpeed = v(.waveSpeed)
        twirl = v(.twirl); bulge = min(max(v(.bulge), -0.95), 0.95)
        radius = max(1, v(.distortRadius)); turbulence = v(.turbulence)
        colors = layer.colorMatrix(at: t)
        posterize = v(.posterize); pixelate = max(0, v(.pixelate))
        directionalBlur = max(0, v(.directionalBlur)); blurAngle = v(.blurAngle)
        zoomBlur = min(max(v(.zoomBlur), 0), 0.95)
        rgbSplit = v(.rgbSplit); glitch = min(max(v(.glitch), 0), 1)
        grain = min(max(v(.grain), 0), 1); scanlines = min(max(v(.scanlines), 0), 1)
        vignette = min(max(v(.vignette), 0), 1)
        rays = min(max(v(.rays), 0), 4); raysLength = min(max(v(.raysLength), 0), 0.95)
        outline = max(0, v(.outline)); outlineColor = layer.outlineColor ?? .white
        innerGlow = min(max(v(.innerGlow), 0), 4); innerGlowRadius = max(1, v(.innerGlowRadius))
        innerGlowColor = layer.innerGlowColor ?? .white
        shine = min(max(v(.shine), 0), 4)
        goo = max(0, v(.goo)); halftone = max(0, v(.halftone))
        grading = Grading(layer, at: t)
        time = t
        frame = Int(floor(t * Double(max(fps, 1)) + 1e-6))
        seed = Noise.hash(layer.id)
    }

    var distorts: Bool { wave != 0 || ripple != 0 || twirl != 0 || bulge != 0 || turbulence != 0 }

    /// Whether the layer has to go through a bitmap at all.
    var isActive: Bool {
        keyColor != nil || distorts || colors != nil || posterize >= 2 || pixelate >= 1 || directionalBlur >= 1
            || zoomBlur > 0.001 || rgbSplit != 0 || glitch > 0.001 || grain > 0.001 || scanlines > 0.001
            || vignette > 0.001 || rays > 0.001 || outline >= 0.5 || innerGlow > 0.001 || shine > 0.001 || grading != nil
            || goo > 0.001 || halftone >= 2
    }


    /// How far, in layer px, the effects can move pixels outside the layer (`width` = the area's width in layer px).
    func reach(width: Double) -> Double {
        var r = abs(wave) + abs(ripple) + abs(turbulence) + directionalBlur / 2 + abs(rgbSplit) + outline + 2
        if glitch > 0 { r += glitch * 0.12 * width + 6 * glitch }
        return r
    }

    /// Effects before the gaussian blur. `center` = the layer's origin in bitmap pixels (y down);
    /// `scale` = bitmap pixels per layer px; `pixelScale` = bitmap pixels per scene px.
    func applyBeforeBlur(_ ctx: CGContext, center: CGPoint, scale: Double) {
        guard var buf = PixelBuffer(ctx) else { return }
        if let keyColor { buf.key(keyColor, tolerance: keyTolerance, softness: keySoftness) }
        if distorts { distort(&buf, center: center, scale: scale) }
        if let colors { FrameRendererPixels.applyColors(ctx, colors) }
        grading?.apply(buf)
        if posterize >= 2 { buf.posterize(levels: min(posterize, 64)) }
        if pixelate * scale >= 1.5 { buf.pixelate(size: pixelate * scale, center: center) }
        if halftone * scale >= 2 { buf.halftone(cell: halftone * scale, center: center) }
        if innerGlow > 0.001 { buf.innerGlow(innerGlow, radius: innerGlowRadius * scale, color: innerGlowColor) }
        if outline * scale >= 0.5 { buf.outline(radius: outline * scale, color: outlineColor) }
    }

    /// Effects after the gaussian blur.
    func applyAfterBlur(_ ctx: CGContext, center: CGPoint, scale: Double, pixelScale: Double) {
        guard let buf = PixelBuffer(ctx) else { return }
        if directionalBlur * scale >= 1 { buf.directionalBlur(length: directionalBlur * scale, degrees: blurAngle) }
        if zoomBlur > 0.001 { buf.zoomBlur(amount: zoomBlur, center: center) }
        if rays > 0.001 { buf.lightRays(rays, length: raysLength, center: center) }
        if rgbSplit != 0 { buf.rgbSplit(Int((rgbSplit * scale).rounded())) }
        if glitch > 0.001 { buf.glitch(glitch, frame: frame, seed: seed, pixelScale: pixelScale) }
        if grain > 0.001 { buf.grain(grain, frame: frame, seed: seed) }
        if scanlines > 0.001 { buf.scanlines(scanlines, period: max(2, Int((3 * pixelScale).rounded()))) }
        if vignette > 0.001 { buf.vignette(vignette) }
        if goo > 0.001 { buf.alphaContrast(8) }
    }

    /// Wave warp, ripple, twirl, bulge and turbulent displacement, as one inverse mapping (where each output
    /// pixel takes its color from), sampled bilinearly.
    private func distort(_ buf: inout PixelBuffer, center c: CGPoint, scale: Double) {
        let amp = wave * scale, rip = ripple * scale, turb = turbulence * scale
        let lambda = waveLength * scale, phase = 2 * Double.pi * waveSpeed * time
        let r0 = radius * scale, twist = twirl * .pi / 180
        // Turbulence is smooth: evaluate the noise on a coarse grid and interpolate.
        let cell = 8
        let gw = buf.w / cell + 2, gh = buf.h / cell + 2
        var field = [Double]()
        if turb != 0 {
            field = [Double](repeating: 0, count: gw * gh * 2)
            let z = time * waveSpeed * 0.5
            for gy in 0..<gh {
                for gx in 0..<gw {
                    let x = (Double(gx * cell) - c.x) / lambda, y = (Double(gy * cell) - c.y) / lambda
                    let i = 2 * (gy * gw + gx)
                    field[i] = turb * Noise.value3(x, y, z, seed: seed).v
                    field[i + 1] = turb * Noise.value3(x + 31.7, y - 12.9, z, seed: seed &+ 7).v
                }
            }
        }
        buf.remap { x, y in
            var px = x, py = y
            if twist != 0 || bulge != 0 {
                let dx = px - c.x, dy = py - c.y
                let r = (dx * dx + dy * dy).squareRoot()
                if r < r0 {
                    let k = 1 - r / r0
                    var sx = dx, sy = dy
                    if bulge != 0 {
                        let f = 1 - bulge * k * k
                        sx *= f; sy *= f
                    }
                    if twist != 0 {
                        let a = -twist * k * k, ca = cos(a), sa = sin(a)
                        (sx, sy) = (sx * ca - sy * sa, sx * sa + sy * ca)
                    }
                    px = c.x + sx; py = c.y + sy
                }
            }
            if rip != 0 {
                let dx = px - c.x, dy = py - c.y
                let r = (dx * dx + dy * dy).squareRoot()
                if r > 0.5 {
                    let d = rip * sin(2 * .pi * r / lambda - phase)
                    px += dx / r * d; py += dy / r * d
                }
            }
            if amp != 0 { py += amp * sin(2 * .pi * (x - c.x) / lambda - phase) }
            if turb != 0 {
                let fx = min(max(x / Double(cell), 0), Double(gw - 2)), fy = min(max(y / Double(cell), 0), Double(gh - 2))
                let ix = Int(fx), iy = Int(fy), tx = fx - Double(ix), ty = fy - Double(iy)
                for k in 0..<2 {
                    let a = field[2 * (iy * gw + ix) + k], b = field[2 * (iy * gw + ix + 1) + k]
                    let cc = field[2 * ((iy + 1) * gw + ix) + k], d = field[2 * ((iy + 1) * gw + ix + 1) + k]
                    let v = (a + (b - a) * tx) * (1 - ty) + (cc + (d - cc) * tx) * ty
                    if k == 0 { px += v } else { py += v }
                }
            }
            return (px, py)
        }
    }
}

/// Premultiplied RGBA8 pixels of a bitmap context; row 0 is the top.
struct PixelBuffer {
    let p: UnsafeMutablePointer<UInt8>
    let w: Int, h: Int, rb: Int

    init?(_ ctx: CGContext) {
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self), ctx.bitsPerPixel == 32 else { return nil }
        p = d; w = ctx.width; h = ctx.height; rb = ctx.bytesPerRow
    }

    init(p: UnsafeMutablePointer<UInt8>, w: Int, h: Int, rb: Int) { self.p = p; self.w = w; self.h = h; self.rb = rb }

    private func copy() -> [UInt8] { Array(UnsafeBufferPointer(start: p, count: rb * h)) }

    /// The alpha channel as a plane.
    private func alphaPlane() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = p + y * rb
            for x in 0..<w { out[y * w + x] = row[4 * x + 3] }
        }
        return out
    }

    /// Box-blurs a plane in place (three passes ≈ gaussian).
    private static func blurPlane(_ plane: inout [UInt8], w: Int, h: Int, sigma: Double) {
        var size = Int((12 * sigma * sigma / 3 + 1).squareRoot().rounded())
        if size % 2 == 0 { size += 1 }
        guard size >= 3 else { return }
        var tmp = [UInt8](repeating: 0, count: w * h)
        plane.withUnsafeMutableBufferPointer { a in
            tmp.withUnsafeMutableBufferPointer { b in
                var src = vImage_Buffer(data: a.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var dst = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                for pass in 0..<3 {
                    if pass % 2 == 0 {
                        vImageBoxConvolve_Planar8(&src, &dst, nil, 0, 0, UInt32(size), UInt32(size), 0, vImage_Flags(kvImageEdgeExtend))
                    } else {
                        vImageBoxConvolve_Planar8(&dst, &src, nil, 0, 0, UInt32(size), UInt32(size), 0, vImage_Flags(kvImageEdgeExtend))
                    }
                }
            }
        }
        plane = tmp
    }

    /// A colored band around the layer's shape: the alpha dilated by `radius`, drawn behind the pixels.
    func outline(radius: Double, color: RGBA) {
        let k = max(1, Int((radius * 2).rounded()) | 1)
        var alpha = alphaPlane()
        var dil = [UInt8](repeating: 0, count: w * h)
        alpha.withUnsafeMutableBufferPointer { a in
            dil.withUnsafeMutableBufferPointer { d in
                var src = vImage_Buffer(data: a.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageMax_Planar8(&src, &dst, nil, 0, 0, vImagePixelCount(k), vImagePixelCount(k), vImage_Flags(kvImageNoFlags))
            }
        }
        // Soften the band's outer edge by a pixel so it is not jagged.
        Self.blurPlane(&dil, w: w, h: h, sigma: 0.7)
        let cr = color.r * color.a, cg = color.g * color.a, cb = color.b * color.a
        for y in 0..<h {
            let row = p + y * rb
            for x in 0..<w {
                let m = Double(dil[y * w + x]) / 255 * color.a
                guard m > 0 else { continue }
                let q = row + 4 * x
                let inv = 1 - Double(q[3]) / 255 // behind the layer
                q[0] = UInt8(min(255, Double(q[0]) + cr * m * inv * 255))
                q[1] = UInt8(min(255, Double(q[1]) + cg * m * inv * 255))
                q[2] = UInt8(min(255, Double(q[2]) + cb * m * inv * 255))
                q[3] = UInt8(min(255, Double(q[3]) + m * inv * 255))
            }
        }
    }

    /// Light inside the layer's edges: the blurred outside, masked by the layer, added over it.
    func innerGlow(_ strength: Double, radius: Double, color: RGBA) {
        let alpha = alphaPlane()
        var outside = alpha.map { 255 - $0 }
        Self.blurPlane(&outside, w: w, h: h, sigma: radius / 2)
        let cr = color.r, cg = color.g, cb = color.b
        for y in 0..<h {
            let row = p + y * rb
            for x in 0..<w {
                let i = y * w + x
                let a = Double(alpha[i]) / 255
                guard a > 0 else { continue }
                let m = min(1, Double(outside[i]) / 255 * strength * color.a) * a
                let q = row + 4 * x
                // Normal blend of the glow color (premultiplied by m) over the pixel.
                q[0] = UInt8(min(255, Double(q[0]) * (1 - m) + cr * m * 255))
                q[1] = UInt8(min(255, Double(q[1]) * (1 - m) + cg * m * 255))
                q[2] = UInt8(min(255, Double(q[2]) * (1 - m) + cb * m * 255))
            }
        }
    }

    /// Rays streaking out of the bright parts: a copy keeps only bright pixels, is zoom-blurred from `center`
    /// and added on top.
    func lightRays(_ strength: Double, length: Double, center: CGPoint) {
        var scratch = copy()
        scratch.withUnsafeMutableBufferPointer { s in
            let buf = PixelBuffer(p: s.baseAddress!, w: w, h: h, rb: rb)
            // Threshold: luma above 0.45 (of alpha) stays, scaled up.
            for y in 0..<h {
                let row = buf.p + y * rb
                for x in 0..<w {
                    let q = row + 4 * x
                    let a = Double(q[3])
                    guard a > 0 else { continue }
                    let luma = (0.2126 * Double(q[0]) + 0.7152 * Double(q[1]) + 0.0722 * Double(q[2])) / a
                    let k = min(max((luma - 0.45) / 0.4, 0), 1)
                    q[0] = UInt8(Double(q[0]) * k); q[1] = UInt8(Double(q[1]) * k); q[2] = UInt8(Double(q[2]) * k)
                    q[3] = UInt8(a * k)
                }
            }
            buf.zoomBlur(amount: length, center: center)
            for y in 0..<h {
                let row = p + y * rb, srow = buf.p + y * rb
                for x in 0..<w {
                    let q = row + 4 * x, r = srow + 4 * x
                    for k in 0..<4 { q[k] = UInt8(min(255, Int(q[k]) + Int(Double(r[k]) * strength))) }
                }
            }
        }
    }

    // MARK: Per pixel

    /// Removes pixels close to `color` in chroma (green/blue screen) and its spill on the edges.
    func key(_ color: RGBA, tolerance: Double, softness: Double) {
        let lr = 0.2126, lg = 0.7152, lb = 0.0722
        func ycc(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
            // Chroma relative to brightness: a shadow on the screen has the same color as its lit part.
            let y = lr * r + lg * g + lb * b, n = 1 / (y + 0.15)
            return (y, (b - y) * n, (r - y) * n)
        }
        let (ky, kcb, kcr) = ycc(color.r, color.g, color.b)
        // Spill only matters for a colored screen (green, blue), not for keying out black or white.
        let spill = (kcb * kcb + kcr * kcr).squareRoot() > 0.25
        // The key's main channel (green for a green screen).
        let dom = color.g >= color.r && color.g >= color.b ? 1 : color.b >= color.r ? 2 : 0
        let lo = tolerance, hi = tolerance + max(softness, 0.001)
        for y in 0..<h {
            let row = p + y * rb
            for x in 0..<w {
                let q = row + 4 * x
                let a = Double(q[3])
                guard a > 0 else { continue }
                var r = Double(q[0]) / a, g = Double(q[1]) / a, b = Double(q[2]) / a
                let (yy, cb, cr) = ycc(r, g, b)
                // Mostly chroma (shadows on the screen still key out), with some brightness so a neutral key
                // (black, white) does not take every gray with it.
                let dl = 0.5 * (yy - ky)
                let dist = ((cb - kcb) * (cb - kcb) + (cr - kcr) * (cr - kcr) + dl * dl).squareRoot()
                let t = min(max((dist - lo) / (hi - lo), 0), 1)
                let keep = t * t * (3 - 2 * t)
                // Spill: the key's main channel may not exceed the larger of the other two.
                if spill { switch dom {
                case 0: r = min(r, max(g, b))
                case 1: g = min(g, max(r, b))
                default: b = min(b, max(r, g))
                } }
                let na = a * keep
                q[0] = UInt8(min(max(r * na, 0), na).rounded())
                q[1] = UInt8(min(max(g * na, 0), na).rounded())
                q[2] = UInt8(min(max(b * na, 0), na).rounded())
                q[3] = UInt8(na.rounded())
            }
        }
    }

    /// Re-sharpens a blurred alpha around 50% (the "gooey" filter): blobs that overlap fuse into one shape.
    func alphaContrast(_ k: Double) {
        for y in 0..<h {
            let row = p + y * rb
            for x in 0..<w {
                let q = row + 4 * x
                let a = Double(q[3])
                guard a > 0 else { continue }
                let na = min(max((a - 128) * k + 128, 0), 255)
                let f = na / a
                for c in 0..<3 { q[c] = UInt8(min(Double(q[c]) * f, na).rounded()) }
                q[3] = UInt8(na.rounded())
            }
        }
    }

    /// Classic print halftone: each cell becomes one dot of the cell's average color, bigger where the cell is
    /// darker and more opaque (white areas vanish, as ink on paper).
    func halftone(cell: Double, center: CGPoint) {
        let s = max(2, Int(cell.rounded()))
        let ox = ((Int(center.x.rounded()) % s) + s) % s - s, oy = ((Int(center.y.rounded()) % s) + s) % s - s
        let src = copy()
        var by = oy
        while by < h {
            let y0 = max(by, 0), y1 = min(by + s, h)
            var bx = ox
            while bx < w {
                let x0 = max(bx, 0), x1 = min(bx + s, w)
                var sr = 0, sg = 0, sb = 0, sa = 0
                for y in y0..<y1 {
                    let row = y * rb
                    for x in x0..<x1 {
                        let q = row + 4 * x
                        sr += Int(src[q]); sg += Int(src[q + 1]); sb += Int(src[q + 2]); sa += Int(src[q + 3])
                    }
                }
                let n = (x1 - x0) * (y1 - y0)
                let cx = Double(bx) + Double(s) / 2 - 0.5, cy = Double(by) + Double(s) / 2 - 0.5
                var radius = 0.0
                var cr = 0.0, cg = 0.0, cb = 0.0
                if sa > 0 {
                    // Un-premultiply the average color; dot size from coverage × darkness.
                    cr = Double(sr) / Double(sa); cg = Double(sg) / Double(sa); cb = Double(sb) / Double(sa)
                    let lum = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb
                    let cover = Double(sa) / Double(n * 255) * (1 - 0.85 * lum)
                    radius = Double(s) / 2 * cover.squareRoot() * 1.15
                }
                for y in y0..<y1 {
                    let row = p + y * rb
                    for x in x0..<x1 {
                        let q = row + 4 * x
                        let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot()
                        let inside = radius <= 0 ? 0 : d <= radius - 0.5 ? 1.0 : d >= radius + 0.5 ? 0.0 : radius + 0.5 - d
                        let a = inside * 255
                        q[0] = UInt8((cr * a).rounded()); q[1] = UInt8((cg * a).rounded()); q[2] = UInt8((cb * a).rounded())
                        q[3] = UInt8(a.rounded())
                    }
                }
                bx += s
            }
            by += s
        }
    }

    /// Replaces the picture with its alpha swept along (dx, dy) for `length` px, in `color` (a long shadow).
    /// The sweep is a union of shifted copies, built by doubling (log2(length) passes).
    func smear(dx: Double, dy: Double, length: Double, color: RGBA) {
        var alpha = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = p + y * rb
            for x in 0..<w { alpha[y * w + x] = row[4 * x + 3] }
        }
        var tmp = alpha
        var covered = 0.0
        while covered < length - 0.5 {
            let s = min(max(covered, 1), length - covered)
            let ox = Int((dx * s).rounded()), oy = Int((dy * s).rounded())
            if ox == 0 && oy == 0 { covered += s; continue }
            for y in 0..<h {
                let sy = y - oy
                for x in 0..<w {
                    let sx = x - ox
                    var v = alpha[y * w + x]
                    if sx >= 0, sx < w, sy >= 0, sy < h { v = max(v, alpha[sy * w + sx]) }
                    tmp[y * w + x] = v
                }
            }
            swap(&alpha, &tmp)
            covered += s
        }
        let cr = color.r * color.a, cg = color.g * color.a, cb = color.b * color.a
        for y in 0..<h {
            let row = p + y * rb
            for x in 0..<w {
                let a = Double(alpha[y * w + x]) * color.a
                let q = row + 4 * x
                q[0] = UInt8((cr * Double(alpha[y * w + x])).rounded())
                q[1] = UInt8((cg * Double(alpha[y * w + x])).rounded())
                q[2] = UInt8((cb * Double(alpha[y * w + x])).rounded())
                q[3] = UInt8(a.rounded())
            }
        }
    }

    func posterize(levels: Double) {
        let n = Double(Int(levels)) - 1
        for y in 0..<h {
            let row = p + y * rb
            for x in 0..<w {
                let q = row + 4 * x
                let a = Double(q[3])
                guard a > 0 else { continue }
                for k in 0..<3 {
                    let c = (Double(q[k]) / a * n).rounded() / n
                    q[k] = UInt8(min(c * a, a).rounded())
                }
            }
        }
    }

    /// Averages square blocks of `size` pixels, the grid anchored on `center` so it moves with the layer.
    func pixelate(size: Double, center: CGPoint) {
        let s = max(2, Int(size.rounded()))
        let ox = ((Int(center.x.rounded()) % s) + s) % s - s, oy = ((Int(center.y.rounded()) % s) + s) % s - s
        var by = oy
        while by < h {
            let y0 = max(by, 0), y1 = min(by + s, h)
            var bx = ox
            while bx < w {
                let x0 = max(bx, 0), x1 = min(bx + s, w)
                var sum = (0, 0, 0, 0)
                for y in y0..<y1 {
                    let row = p + y * rb
                    for x in x0..<x1 {
                        let q = row + 4 * x
                        sum.0 += Int(q[0]); sum.1 += Int(q[1]); sum.2 += Int(q[2]); sum.3 += Int(q[3])
                    }
                }
                let n = max(1, (y1 - y0) * (x1 - x0))
                let avg = [UInt8(sum.0 / n), UInt8(sum.1 / n), UInt8(sum.2 / n), UInt8(sum.3 / n)]
                for y in y0..<y1 {
                    let row = p + y * rb
                    for x in x0..<x1 {
                        let q = row + 4 * x
                        q[0] = avg[0]; q[1] = avg[1]; q[2] = avg[2]; q[3] = avg[3]
                    }
                }
                bx += s
            }
            by += s
        }
    }

    // MARK: Resampling

    /// Moves pixels: each output pixel takes the bilinear sample at `source(x, y)` (pixel centers, y down).
    func remap(_ source: (Double, Double) -> (Double, Double)) {
        let src = copy()
        src.withUnsafeBufferPointer { s in
            for y in 0..<h {
                let row = p + y * rb
                for x in 0..<w {
                    let (sx, sy) = source(Double(x), Double(y))
                    let q = row + 4 * x
                    sample(s, sx, sy, into: q)
                }
            }
        }
    }

    /// Bilinear sample of `s` (a copy of this buffer); outside is transparent.
    @inline(__always)
    private func sample(_ s: UnsafeBufferPointer<UInt8>, _ x: Double, _ y: Double, into q: UnsafeMutablePointer<UInt8>) {
        let fx = floor(x), fy = floor(y)
        let ix = Int(fx), iy = Int(fy)
        let tx = x - fx, ty = y - fy
        var a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0
        @inline(__always) func add(_ xx: Int, _ yy: Int, _ wgt: Double) {
            guard wgt > 0, xx >= 0, yy >= 0, xx < w, yy < h else { return }
            let i = yy * rb + 4 * xx
            a0 += Double(s[i]) * wgt; a1 += Double(s[i + 1]) * wgt
            a2 += Double(s[i + 2]) * wgt; a3 += Double(s[i + 3]) * wgt
        }
        add(ix, iy, (1 - tx) * (1 - ty)); add(ix + 1, iy, tx * (1 - ty))
        add(ix, iy + 1, (1 - tx) * ty); add(ix + 1, iy + 1, tx * ty)
        q[0] = UInt8(min(a0 + 0.5, 255)); q[1] = UInt8(min(a1 + 0.5, 255))
        q[2] = UInt8(min(a2 + 0.5, 255)); q[3] = UInt8(min(a3 + 0.5, 255))
    }

    /// Motion-style blur along a line: averaging with shifted copies of itself at halving distances gives a box of
    /// 2^k evenly spaced taps in k passes.
    func directionalBlur(length: Double, degrees: Double) {
        let a = degrees * .pi / 180
        let ux = cos(a), uy = sin(a)
        var step = length / 2
        while step >= 0.75 {
            let src = copy()
            let dx = Int((ux * step).rounded()), dy = Int((uy * step).rounded())
            // Centered: the two copies sit half a step either side.
            let hx = dx / 2, hy = dy / 2
            src.withUnsafeBufferPointer { s in
                for y in 0..<h {
                    let row = p + y * rb
                    for x in 0..<w {
                        let q = row + 4 * x
                        let ax = x - hx, ay = y - hy, bx = x - hx + dx, by = y - hy + dy
                        let aIn = ax >= 0 && ay >= 0 && ax < w && ay < h
                        let bIn = bx >= 0 && by >= 0 && bx < w && by < h
                        for k in 0..<4 {
                            let va = aIn ? Int(s[ay * rb + 4 * ax + k]) : 0
                            let vb = bIn ? Int(s[by * rb + 4 * bx + k]) : 0
                            q[k] = UInt8((va + vb + 1) / 2)
                        }
                    }
                }
            }
            step /= 2
        }
    }

    /// Radial (zoom) blur toward `center`: averaging with copies scaled toward it, halving the zoom each pass.
    func zoomBlur(amount: Double, center c: CGPoint) {
        var s = 1 - amount // the farthest sample is at this fraction of the distance to the center
        for _ in 0..<6 {
            let src = copy()
            let f = s
            src.withUnsafeBufferPointer { buf in
                for y in 0..<h {
                    let row = p + y * rb
                    for x in 0..<w {
                        let q = row + 4 * x
                        let i = y * rb + 4 * x
                        let a = (buf[i], buf[i + 1], buf[i + 2], buf[i + 3])
                        sample(buf, c.x + (Double(x) - c.x) * f, c.y + (Double(y) - c.y) * f, into: q)
                        q[0] = UInt8((Int(q[0]) + Int(a.0) + 1) / 2); q[1] = UInt8((Int(q[1]) + Int(a.1) + 1) / 2)
                        q[2] = UInt8((Int(q[2]) + Int(a.2) + 1) / 2); q[3] = UInt8((Int(q[3]) + Int(a.3) + 1) / 2)
                    }
                }
            }
            s = s.squareRoot()
            if s > 0.999 { break }
        }
    }

    // MARK: Stylize

    /// Red shifted right by `d` pixels, blue left (negative d swaps them).
    func rgbSplit(_ d: Int) {
        guard d != 0 else { return }
        let src = copy()
        src.withUnsafeBufferPointer { s in
            for y in 0..<h {
                let row = p + y * rb, base = y * rb
                for x in 0..<w {
                    let q = row + 4 * x
                    let xr = x - d, xb = x + d
                    let r = xr >= 0 && xr < w ? (Int(s[base + 4 * xr]), Int(s[base + 4 * xr + 3])) : (0, 0)
                    let b = xb >= 0 && xb < w ? (Int(s[base + 4 * xb + 2]), Int(s[base + 4 * xb + 3])) : (0, 0)
                    let g = (Int(s[base + 4 * x + 1]), Int(s[base + 4 * x + 3]))
                    q[0] = UInt8(r.0); q[1] = UInt8(g.0); q[2] = UInt8(b.0)
                    q[3] = UInt8(max(r.1, g.1, b.1))
                }
            }
        }
    }

    /// Digital glitch: random horizontal bands jump sideways with their colors split, changing ~12 times a second.
    func glitch(_ amount: Double, frame: Int, seed: UInt64, pixelScale: Double) {
        let src = copy()
        let tick = UInt64(frame / 2) // hold each glitch for two frames
        let salt = Noise.mix(seed ^ (tick &* 0x9E3779B97F4A7C15))
        var y = 0, band = 0
        src.withUnsafeBufferPointer { s in
            while y < h {
                let height = max(2, Int((4 + 36 * Noise.unit(band * 3, salt)) * pixelScale))
                let hit = Noise.unit(band * 3 + 1, salt) < amount * 0.6
                let shift = hit ? Int(((Noise.unit(band * 3 + 2, salt) * 2 - 1) * amount * 0.12 * Double(w)).rounded()) : 0
                let split = hit ? max(1, Int(6 * amount * pixelScale)) : 0
                for yy in y..<min(y + height, h) where hit {
                    let row = p + yy * rb, base = yy * rb
                    for x in 0..<w {
                        let q = row + 4 * x
                        func px(_ sx: Int, _ k: Int) -> Int { sx >= 0 && sx < w ? Int(s[base + 4 * sx + k]) : 0 }
                        let xs = x - shift
                        let ar = px(xs - split, 3), ag = px(xs, 3), ab = px(xs + split, 3)
                        q[0] = UInt8(px(xs - split, 0)); q[1] = UInt8(px(xs, 1)); q[2] = UInt8(px(xs + split, 2))
                        q[3] = UInt8(max(ar, ag, ab))
                    }
                }
                y += height
                band += 1
            }
        }
    }

    /// Film grain: monochrome noise, new every frame, only where the layer is.
    func grain(_ amount: Double, frame: Int, seed: UInt64) {
        let salt = Noise.mix(seed ^ UInt64(frame) &* 0xD1B54A32D192ED03)
        // Integer math: this runs over every pixel of a full-frame layer each frame.
        let strength = Int(amount * 0.35 * 256) // × 256
        for y in 0..<h {
            let row = p + y * rb
            var hsh = Noise.mix(salt ^ UInt64(y) &* 0x9E3779B97F4A7C15)
            for x in 0..<w {
                let q = row + 4 * x
                hsh = hsh &* 6364136223846793005 &+ 1442695040888963407
                let a = Int(q[3])
                guard a > 0 else { continue }
                let n = Int(hsh >> 56) - 128 // -128…127, about -1…1 in 128ths
                let d = (n * strength * a) >> 15 // n/128 · strength · a
                for k in 0..<3 { q[k] = UInt8(min(max(Int(q[k]) + d, 0), a)) }
            }
        }
    }

    /// Darker every other band of `period / 2` rows, like a CRT.
    func scanlines(_ amount: Double, period: Int) {
        let f = 1 - amount * 0.6
        for y in 0..<h where y % period < period / 2 {
            let row = p + y * rb
            for x in 0..<w {
                let q = row + 4 * x
                for k in 0..<3 { q[k] = UInt8(Double(q[k]) * f) }
            }
        }
    }

    /// Darkens toward the edges of the bitmap (the layer's area).
    func vignette(_ amount: Double) {
        let cx = Double(w) / 2, cy = Double(h) / 2
        for y in 0..<h {
            let row = p + y * rb
            let ny = (Double(y) + 0.5 - cy) / cy
            for x in 0..<w {
                let nx = (Double(x) + 0.5 - cx) / cx
                let r = (nx * nx + ny * ny).squareRoot() / 1.414
                let t = min(max((r - 0.35) / 0.65, 0), 1)
                let f = 1 - amount * t * t * (3 - 2 * t)
                let q = row + 4 * x
                for k in 0..<3 { q[k] = UInt8(Double(q[k]) * f) }
            }
        }
    }
}

/// Color matrix on premultiplied RGBA (vImage), shared by the renderer and the pixel effects.
enum FrameRendererPixels {
    /// Offsets scale with alpha, so the see-through parts of the layer stay see-through.
    static func applyColors(_ ctx: CGContext, _ cm: ColorMatrix) {
        guard let data = ctx.data else { return }
        let w = ctx.width, h = ctx.height, rowBytes = ctx.bytesPerRow
        guard let tmp = malloc(rowBytes * h) else { return }
        defer { free(tmp) }
        let divisor: Int32 = 1024
        func q(_ v: Double) -> Int16 { Int16(max(-32767, min(32767, (v * Double(divisor)).rounded()))) }
        // vImage multiplies row vectors: matrix[4 * in + out]. Channels are R, G, B, A.
        var matrix = [Int16](repeating: 0, count: 16)
        for o in 0..<3 {
            for i in 0..<3 { matrix[4 * i + o] = q(cm.m[3 * o + i]) }
            matrix[4 * 3 + o] = q(cm.b[o]) // premultiplied: the offset is times alpha
        }
        matrix[4 * 3 + 3] = Int16(divisor)
        let round: [Int32] = [divisor / 2, divisor / 2, divisor / 2, divisor / 2]
        var src = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
        var dst = vImage_Buffer(data: tmp, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
        vImageMatrixMultiply_ARGB8888(&src, &dst, matrix, divisor, nil, round, vImage_Flags(kvImageNoFlags))
        // Keep the pixels valid premultiplied colors (no channel above alpha).
        vImageClipToAlpha_RGBA8888(&dst, &src, vImage_Flags(kvImageNoFlags))
    }
}
