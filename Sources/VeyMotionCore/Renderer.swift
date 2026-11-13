import AppKit
import CoreGraphics
import Accelerate
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// Deterministic CoreGraphics renderer. Preview and export both use this, so what you see is what you export.
/// Not thread-safe: use one instance per thread.
public final class FrameRenderer {
    private var imageCache: [String: (image: CGImage, size: CGSize, modified: Double?)] = [:]
    /// Alpha of image sprites as grayscale masks (for tinted particles), keyed like `imageCache`.
    private var maskCache: [String: (mask: CGImage, modified: Double?)] = [:]
    /// Text outlines particles are emitted from, keyed by everything that changes the outline.
    private var drawingPathCache: [String: PathShape] = [:]
    private var glyphCache: [String: GlyphOutline] = [:]
    /// Particles of the layer being drawn (simulated once per layer and frame).
    private var currentParticles: [Particle] = []
    /// Open video decoders by path, reopened when the file (or sequence folder) changes. nil = unreadable.
    private var videoCache: [String: (frames: VideoFrames?, modified: Double?)] = [:]
    /// Pictures with their background removed, by mode + source + frame.
    private var cutoutCache: [String: CGImage] = [:]
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Fewest sub-frame renders averaged for a layer with motion blur (lower it for a faster preview).
    public var motionBlurSamples = 8
    /// Most sub-frame renders: fast moves get more samples (about one per 1.5 device px of travel), so they smear
    /// instead of showing separate copies.
    public var motionBlurMaxSamples = 64
    /// Set while rendering motion-blur samples, so samples are not blurred again.
    private var inMotionSample = false
    /// Supersampling of model layers per axis (3 = 9 samples a pixel; lower it for a faster preview).
    public var modelSupersampling = 3

    /// Set while a 3D group draws its children in its parent's 3D space (see `drawGroup3D`).
    private struct Space3DContext { var view: View3D; var prefix: Mat4; var lookup: MotionScene }
    private var space3D: Space3DContext?
    /// Where each 3D layer was last placed: its projection, the affine stand-in used as its transform (a translation
    /// to its projected origin and a uniform scale), and its plane's homography in that stand-in's space.
    private struct Placed3D { var t: Double; var proj: LayerProjection; var affine: CGAffineTransform; var local: [Double] }
    private var placed3D: [String: Placed3D] = [:]
    private var meshCache: [String: Mesh3D] = [:]
    private var modelFileCache: [String: ModelFile?] = [:]
    /// The last pose of each animated file model (layer id + file key).
    private var poseCache: [String: (clip: Int, time: Double, mesh: Mesh3D)] = [:]
    /// The frame's depth buffer while its 3D layers draw straight into `depthContext` (nil inside flat groups,
    /// offscreen bitmaps and between runs of 3D layers separated by 2D ones).
    private var depthBuffer: DepthBuffer?
    private var depthContext: CGContext?
    /// The layer being drawn is opaque with a normal blend, so it may hide what is behind it.
    private var depthWrites = false
    private var textureCache: [String: (texture: Texture3D, modified: Double?)] = [:]

    public init() {}

    /// Drops every cached image and open video decoder (e.g. when another project is opened).
    public func clearCaches() {
        imageCache.removeAll()
        maskCache.removeAll()
        glyphCache.removeAll()
        videoCache.removeAll()
        cutoutCache.removeAll()
        meshCache.removeAll()
        modelFileCache.removeAll()
        poseCache.removeAll()
        textureCache.removeAll()
        placed3D.removeAll()
    }

    /// Device pixels per scene pixel for the frame being drawn (shadow and blur sizes are in device pixels).
    private var pixelScale: Double = 1
    private var pixelSize = (w: 0, h: 0)

    /// Draws the scene at time `t` into a context of the given pixel size (native bottom-left CG coordinates).
    public func draw(_ scene: MotionScene, at t: Double, in ctx: CGContext, pixelWidth: Int, pixelHeight: Int) {
        pixelScale = Double(pixelWidth) / Double(max(scene.width, 1))
        pixelSize = (pixelWidth, pixelHeight)
        ctx.saveGState()
        ctx.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        Self.unquantizeText(ctx)
        // Switch to scene coordinates: origin top-left, y down, 1 unit = 1 scene pixel.
        Self.applySceneSpace(ctx, scene: scene, pixelWidth: pixelWidth, pixelHeight: pixelHeight)

        ctx.setFillColor(scene.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: scene.width, height: scene.height))

        // A layer used as another's track matte is only drawn through that layer.
        let matteSources = Set(scene.layers.compactMap { l in l.matte.flatMap { $0.source == l.id ? nil : $0.source } })
        let visible = scene.layers.filter { $0.type.isVisual && !matteSources.contains($0.id) }
        let order = drawOrder(visible, scene: scene, at: t)
        if order.contains(where: { renders3D($0) }) {
            if depthBuffer?.width != pixelWidth || depthBuffer?.height != pixelHeight {
                depthBuffer = DepthBuffer(width: pixelWidth, height: pixelHeight)
            } else {
                depthBuffer?.reset()
            }
            depthContext = ctx
        }
        defer { depthContext = nil }
        // Like After Effects, 3D layers on either side of a 2D layer do not hide each other.
        var fresh = true
        for layer in order {
            if renders3D(layer) {
                if !fresh { depthBuffer?.reset(); fresh = true }
            } else if depthContext != nil {
                fresh = false
            }
            renderLayer(layer, scene: scene, at: t, in: ctx)
        }
        ctx.restoreGState()
    }

    private static func applySceneSpace(_ ctx: CGContext, scene: MotionScene, pixelWidth: Int, pixelHeight: Int) {
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: CGFloat(pixelWidth) / CGFloat(scene.width), y: -CGFloat(pixelHeight) / CGFloat(scene.height))
    }

    public func makeImage(_ scene: MotionScene, at t: Double, scale: Double = 1) -> CGImage? {
        let w = max(1, Int((Double(scene.width) * scale).rounded()))
        let h = max(1, Int((Double(scene.height) * scale).rounded()))
        guard let ctx = Self.bitmap(w, h) else { return nil }
        draw(scene, at: t, in: ctx, pixelWidth: w, pixelHeight: h)
        return ctx.makeImage()
    }

    private static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        if let ctx { unquantizeText(ctx) }
        return ctx
    }

    /// Glyphs at their exact positions: CoreText otherwise snaps them to the pixel grid, so slowly moving or zooming
    /// text steps a pixel at a time and its letters wobble against each other.
    private static func unquantizeText(_ ctx: CGContext) {
        ctx.setAllowsFontSubpixelPositioning(true)
        ctx.setShouldSubpixelPositionFonts(true)
        ctx.setAllowsFontSubpixelQuantization(false)
        ctx.setShouldSubpixelQuantizeFonts(false)
    }

    public func pngData(_ scene: MotionScene, at t: Double, scale: Double = 1) -> Data? {
        guard let img = makeImage(scene, at: t, scale: scale) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Layers

    /// Draws a layer with its track matte and repeater copies. `depth` limits mattes of mattes.
    private func renderLayer(_ layer: MotionLayer, scene: MotionScene, at time: Double, in ctx: CGContext, depth: Int = 0) {
        // Posterize time: the layer only changes `posterizeTime` times a second.
        let t = layer.posterizeTime.map { fps in floor(time * fps + 1e-6) / fps } ?? time
        let rep = layer.repeater
        let n = rep.map { min(max($0.count, 1), Repeater.maxCount) } ?? 1
        let delay = rep?.delay ?? 0
        // Each copy lags `delay` behind the previous one, start time included.
        let copies = (0..<n).filter { layer.isVisible(at: t - Double($0) * delay, sceneDuration: scene.duration) }
        guard !copies.isEmpty else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let matte = layer.matte, matte.source != layer.id, depth < 4,
           let src = scene.layers.first(where: { $0.id == matte.source }) {
            guard let mask = matteMask(src, mode: matte.mode, scene: scene, at: t, depth: depth) else { return }
            // The mask covers the frame in device pixels: clip with y pointing up, then return to scene space.
            let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(scene.height))
            ctx.concatenate(flip)
            ctx.clip(to: CGRect(x: 0, y: 0, width: scene.width, height: scene.height), mask: mask)
            ctx.concatenate(flip)
        }
        // The original (copy 0) is on top.
        for i in copies.reversed() {
            let ti = t - Double(i) * delay
            if let rep {
                let c = rep.copy(i, at: t, position: layer.position(at: ti).point)
                var li = layer
                if !rep.colors.isEmpty {
                    let col = rep.colors[i % rep.colors.count]
                    if layer.type == .text { li.color = .constant(col) } else { li.fill = .constant(col) }
                }
                drawCopy(li, scene: scene, at: ti, in: ctx, copy: c.transform, alphaScale: c.opacity)
            } else {
                drawCopy(layer, scene: scene, at: ti, in: ctx, copy: nil, alphaScale: 1)
            }
        }
    }

    /// Gray mask of the frame (white = show) from a matte layer, or nil when nothing can show through.
    private func matteMask(_ src: MotionLayer, mode: MatteMode, scene: MotionScene, at t: Double, depth: Int) -> CGImage? {
        let (w, h) = pixelSize
        guard let off = offscreen(CGRect(x: 0, y: 0, width: w, height: h), scene: scene) else { return nil }
        renderLayer(src, scene: scene, at: t, in: off, depth: depth + 1)
        let luma = mode == .luma || mode == .lumaInverted
        let invert = mode == .alphaInverted || mode == .lumaInverted
        return Self.grayMask(off, luma: luma, invert: invert)
    }

    /// One pixel per pixel of `ctx`: alpha (or brightness over black), optionally inverted.
    private static func grayMask(_ ctx: CGContext, luma: Bool, invert: Bool) -> CGImage? {
        let w = ctx.width, h = ctx.height, rb = ctx.bytesPerRow
        guard let src = ctx.data?.assumingMemoryBound(to: UInt8.self),
              let gray = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let dst = gray.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in 0..<h {
            let row = y * rb, out = y * w
            for x in 0..<w {
                let p = row + x * 4
                var v: Int
                if luma {
                    // Premultiplied RGB = the matte composited over black.
                    v = (54 * Int(src[p]) + 183 * Int(src[p + 1]) + 19 * Int(src[p + 2]) + 128) >> 8
                } else {
                    v = Int(src[p + 3])
                }
                if invert { v = 255 - v }
                dst[out + x] = UInt8(min(v, 255))
            }
        }
        return gray.makeImage()
    }

    /// Bitmap covering `area` (device pixels, bottom-left origin) of the frame, set up in scene coordinates.
    /// `downsample` k > 1 makes the bitmap 1/k the size (each bitmap pixel covers k × k device pixels); it is still
    /// drawn in scene coordinates, so callers draw it back into `area` scaled up.
    private func offscreen(_ area: CGRect, scene: MotionScene, downsample k: Int = 1) -> CGContext? {
        let bw = max(1, Int((area.width / Double(k)).rounded(.up))), bh = max(1, Int((area.height / Double(k)).rounded(.up)))
        guard let off = Self.bitmap(bw, bh) else { return nil }
        off.setShouldAntialias(true)
        off.interpolationQuality = .high
        if k > 1 { off.scaleBy(x: 1 / CGFloat(k), y: 1 / CGFloat(k)) }
        off.translateBy(x: -area.minX, y: -area.minY)
        Self.applySceneSpace(off, scene: scene, pixelWidth: pixelSize.w, pixelHeight: pixelSize.h)
        return off
    }

    /// Draws a device-pixel image of part of the frame at its place (ctx in scene coordinates), at `alpha`.
    ///
    /// CoreGraphics composites a full-frame image in under a millisecond, but takes 13–17 ms when the CTM is
    /// flipped or the context alpha is below 1, and 9 ms to scale one up: so the alpha is multiplied into the
    /// pixels, a small bitmap is scaled through a BGRA context first, and the draw itself happens with the CTM
    /// reset to device space.
    private func drawDeviceImage(_ image: CGImage, rect r: CGRect, scene: MotionScene, in ctx: CGContext, alpha: Double = 1) {
        let sx = Double(scene.width) / Double(pixelSize.w), sy = Double(scene.height) / Double(pixelSize.h)
        var image = image
        if alpha < 0.999 {
            guard alpha > 0.001, let faded = Self.withAlpha(image, alpha) else { return }
            image = faded
        }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(scene.height))
        ctx.scaleBy(x: 1, y: -1)
        let place = CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
        // Where that lands in the bitmap (inside a group under a camera zoom, scaled), drawn there with an
        // identity CTM (upright: the two flips cancel) on whole pixels: a fractional offset is the slow path too.
        let landed = place.applying(ctx.ctm).standardized
        let dw = max(1, Int(landed.width.rounded())), dh = max(1, Int(landed.height.rounded()))
        let device = CGRect(x: landed.minX.rounded(), y: landed.minY.rounded(), width: Double(dw), height: Double(dh))
        if dw != image.width || dh != image.height, let fitted = Self.scaled(image, to: dw, dh) { image = fitted }
        ctx.concatenate(ctx.ctm.inverted())
        ctx.draw(image, in: device)
        ctx.restoreGState()
    }

    /// `image` (premultiplied RGBA, as `bitmap` makes them) with every channel multiplied by `alpha`.
    private static func withAlpha(_ image: CGImage, _ alpha: Double) -> CGImage? {
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: Unmanaged.passUnretained(colorSpace),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                          version: 0, decode: nil, renderingIntent: .defaultIntent)
        var buf = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buf, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(buf.data) }
        let a = Int16(min(max(alpha, 0), 1) * 256)
        var matrix: [Int16] = [a, 0, 0, 0, 0, a, 0, 0, 0, 0, a, 0, 0, 0, 0, a]
        guard vImageMatrixMultiply_ARGB8888(&buf, &buf, &matrix, 256, nil, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        var error = kvImageNoError
        let out = vImageCreateCGImageFromBuffer(&buf, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)
        guard error == kvImageNoError else { return nil }
        return out?.takeRetainedValue()
    }

    /// `image` resampled to w × h pixels (through a BGRA bitmap, CoreGraphics' fast path for scaling).
    private static func scaled(_ image: CGImage, to w: Int, _ h: Int) -> CGImage? {
        guard w > 0, h > 0,
              let tmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        tmp.interpolationQuality = .high
        tmp.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return tmp.makeImage()
    }

    /// Scene transform of a layer (or of one of its repeater copies, `copy` being the step in its parent's space).
    private func transform(of layer: MotionLayer, scene: MotionScene, at t: Double, copy: CGAffineTransform?) -> CGAffineTransform {
        if renders3D(layer) { return place3D(layer, scene: scene, at: t, copy: copy).affine }
        guard let copy else { return scene.worldTransform(of: layer, at: t) }
        return layer.localTransform(at: t).concatenating(copy).concatenating(scene.parentTransform(of: layer, at: t))
    }

    /// One copy of a layer, averaged over the shutter time when it has motion blur.
    private func drawCopy(_ layer: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext,
                          copy: CGAffineTransform?, alphaScale: Double) {
        let frameTime = 1 / Double(max(scene.fps, 1))
        let shutter = layer.motionBlur / 360 * frameTime
        guard shutter > 0, motionBlurSamples > 1, !inMotionSample else {
            drawLayer(layer, scene: scene, at: t, in: ctx, copy: copy, alphaScale: alphaScale)
            return
        }
        let open = t + (layer.motionBlurPhase ?? -layer.motionBlur / 2) / 360 * frameTime
        let n = motionBlurSampleCount(layer, scene: scene, from: open, to: open + shutter, copy: copy)
        let nd = Double(n)
        let times: [Double] = (0..<n).map { i in open + shutter * (Double(i) + 0.5) / nd }
        let (w, h) = pixelSize
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        let area = (motionBounds(layer, scene: scene, times: times, copy: copy) ?? frame).integral.intersection(frame)
        guard !area.isNull, area.width >= 1, area.height >= 1, let off = offscreen(area, scene: scene),
              let data = off.data?.assumingMemoryBound(to: UInt8.self) else { return }
        // Average the samples in float, vectorized (vDSP): a byte loop here cost more than the drawing. The
        // buffers include the rows' padding bytes; they are never read back.
        let bytes = off.bytesPerRow * off.height
        var acc = [Float](repeating: 0, count: bytes)
        var sample = [Float](repeating: 0, count: bytes)
        inMotionSample = true
        for tk in times {
            memset(data, 0, bytes)
            drawLayer(layer, scene: scene, at: tk, in: off, copy: copy, alphaScale: alphaScale)
            vDSP_vfltu8(data, 1, &sample, 1, vDSP_Length(bytes))
            vDSP_vadd(acc, 1, sample, 1, &acc, 1, vDSP_Length(bytes))
        }
        inMotionSample = false
        var inv = Float(1) / Float(n)
        vDSP_vsmul(acc, 1, &inv, &acc, 1, vDSP_Length(bytes))
        vDSP_vfixru8(acc, 1, data, 1, vDSP_Length(bytes))
        guard let image = off.makeImage() else { return }
        ctx.saveGState()
        ctx.setBlendMode(layer.blendMode.cgBlendMode)
        drawDeviceImage(image, rect: area, scene: scene, in: ctx)
        ctx.restoreGState()
    }

    /// Samples for a shutter interval: enough that the layer's corners move at most ~1.5 device px between two.
    private func motionBlurSampleCount(_ layer: MotionLayer, scene: MotionScene, from t0: Double, to t1: Double,
                                       copy: CGAffineTransform?) -> Int {
        let lo = motionBlurSamples, hi = max(motionBlurMaxSamples, lo)
        guard hi > lo, layer.type != .particles,
              let local = contentBounds(layer, scene: scene, at: (t0 + t1) / 2), !local.isNull, !local.isInfinite
        else { return lo }
        let (w, h) = pixelSize
        let sx = Double(w) / Double(scene.width), sy = Double(h) / Double(scene.height)
        let corners = [CGPoint(x: local.minX, y: local.minY), CGPoint(x: local.maxX, y: local.minY),
                       CGPoint(x: local.minX, y: local.maxY), CGPoint(x: local.maxX, y: local.maxY)]
        let steps = 8
        var travel = 0.0
        var prev: [CGPoint] = []
        for k in 0...steps {
            let m = transform(of: layer, scene: scene, at: t0 + (t1 - t0) * Double(k) / Double(steps), copy: copy)
            let pts = corners.map { $0.applying(m) }
            if !prev.isEmpty {
                travel += zip(pts, prev).map { hypot(($0.x - $1.x) * sx, ($0.y - $1.y) * sy) }.max() ?? 0
            }
            prev = pts
        }
        guard travel.isFinite else { return hi }
        return min(max(Int((travel / 1.5).rounded(.up)), lo), hi)
    }

    /// Device-pixel area a layer covers over several times (with blur, shadow and glow), or nil when unknown.
    private func motionBounds(_ layer: MotionLayer, scene: MotionScene, times: [Double], copy: CGAffineTransform?) -> CGRect? {
        guard layer.type != .particles else { return nil }
        let (w, h) = pixelSize
        let toDevice = CGAffineTransform(a: Double(w) / Double(scene.width), b: 0, c: 0,
                                         d: -Double(h) / Double(scene.height), tx: 0, ty: Double(h))
        var union = CGRect.null
        for tk in times {
            // The transform first: it places a 3D layer, which its bounds depend on.
            let m = transform(of: layer, scene: scene, at: tk, copy: copy)
            guard let local = contentBounds(layer, scene: scene, at: tk) else { return nil }
            var pad = 3 * (max(0, layer.value(.blur, at: tk)) + focusBlur(layer, scene: scene, at: tk)) + 4
            if layer.value(.shadowOpacity, at: tk) > 0.001 {
                pad += abs(layer.value(.shadowX, at: tk)) + abs(layer.value(.shadowY, at: tk)) + 2 * layer.value(.shadowBlur, at: tk)
            }
            if layer.value(.glow, at: tk) > 0.001 { pad += 3 * layer.value(.glowRadius, at: tk) }
            pad += max(0, layer.value(.outline, at: tk)) + PathOps(layer, at: tk).reach
            pad += 3 * max(0, layer.value(.goo, at: tk)) + max(0, layer.value(.longShadow, at: tk))
            let r = local.applying(m).insetBy(dx: -pad, dy: -pad).applying(toDevice)
            union = union.union(r)
        }
        return union
    }

    private func drawLayer(_ layer: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext,
                           copy: CGAffineTransform? = nil, alphaScale: Double = 1) {
        let opacity = min(max(layer.value(.opacity, at: t), 0), 1) * alphaScale
        guard opacity > 0.001 else { return }
        if keepsChildren3D(layer) {
            drawGroup3D(layer, scene: scene, at: t, in: ctx, copy: copy, opacity: opacity)
            return
        }
        let threeD = renders3D(layer)
        depthWrites = threeD && opacity >= 0.999 && layer.blendMode == .normal
        var m = transform(of: layer, scene: scene, at: t, copy: copy)
        if threeD, layer.hideBackface, layer.type != .model, placed3D[layer.id]?.proj.facesAway == true { return }
        let wipe = layer.value(.wipe, at: t)
        guard wipe < 0.9999 else { return }
        // The wipe is in the layer's own space, also for world-space particles.
        let wipeTransform = m
        if layer.type == .particles {
            currentParticles = scene.particles(of: layer, at: t) { [unowned self] src, tb, r1, r2, edge in
                self.emitPoint(on: src, at: tb, r1, r2, edge)
            }
            guard !currentParticles.isEmpty else { return }
            // World-space particles are already in scene pixels.
            if layer.particles.usesWorldSpace { m = (copy ?? .identity).concatenating(scene.cameraTransform(for: layer, at: t)) }
        }
        guard abs(m.a * m.d - m.b * m.c) > 1e-8 else { return } // scaled to nothing
        // Goo blurs the layer before its alpha is re-sharpened (see PixelEffects), so it adds to the blur radius.
        let blur = max(max(0, layer.value(.blur, at: t)) + focusBlur(layer, scene: scene, at: t), max(0, layer.value(.goo, at: t)))
        let fx = PixelEffects(layer, at: t, fps: scene.fps)

        // The wipe clips everything the layer draws: shadow, blur and glow included.
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // 3D layers are wiped on their plane, before the projection (see `drawWarped`).
        if wipe > 0.0001, !threeD {
            guard clipToWipe(layer, progress: wipe, scene: scene, transform: wipeTransform, at: t, copy: copy, in: ctx)
            else { return }
        }

        if layer.value(.longShadow, at: t) >= 1, !threeD, layer.type != .particles {
            drawLongShadow(layer, scene: scene, transform: m, opacity: opacity, at: t, in: ctx)
        }
        ctx.saveGState()
        ctx.setBlendMode(layer.blendMode.cgBlendMode)
        let shadowReach = applyShadow(layer, at: t, in: ctx)
        if blur * pixelScale > 0.25 || fx.isActive {
            // The blurred or processed layer is a device-pixel image of part of the frame: draw it 1:1 at its place.
            if let blurred = blurredLayer(layer, scene: scene, transform: m, radius: blur, fx: fx, at: t) {
                drawDeviceImage(blurred.image, rect: blurred.rect, scene: scene, in: ctx, alpha: opacity)
            }
        } else {
            ctx.setAlpha(opacity)
            // Shadow and partial opacity apply to the layer as a whole, through an offscreen layer that costs
            // a pass over its area: skip it when neither is set, and bound it to what the layer can reach.
            // Particles take the opacity one by one instead, so they keep blending with each other and the background.
            let grouped = shadowReach != nil || (opacity < 1 && layer.type != .particles)
            if grouped {
                if let local = contentBounds(layer, scene: scene, at: t) {
                    let pad = (shadowReach ?? 0) + 2
                    ctx.beginTransparencyLayer(in: local.applying(m).insetBy(dx: -pad, dy: -pad), auxiliaryInfo: nil)
                } else {
                    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                }
            }
            ctx.concatenate(m)
            drawContent(layer, scene: scene, at: t, in: ctx, alpha: grouped ? 1 : opacity)
            if grouped { ctx.endTransparencyLayer() }
        }
        ctx.restoreGState()
        drawGlow(layer, scene: scene, transform: m, opacity: opacity, fx: fx.isActive ? fx : nil, at: t, in: ctx)
    }

    /// A long, hard-edged shadow cast from the layer along `longShadowAngle` (the flat-design look): the layer's
    /// alpha swept over `longShadow` px in `longShadowColor`, drawn under the layer.
    private func drawLongShadow(_ layer: MotionLayer, scene: MotionScene, transform m: CGAffineTransform, opacity: Double,
                                at t: Double, in ctx: CGContext) {
        let length = layer.value(.longShadow, at: t)
        guard length >= 1, let local = contentBounds(layer, scene: scene, at: t) else { return }
        let angle = layer.value(.longShadowAngle, at: t) * .pi / 180
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        let (w, h) = pixelSize
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        let toDevice = CGAffineTransform(a: Double(w) / Double(scene.width), b: 0, c: 0,
                                         d: -Double(h) / Double(scene.height), tx: 0, ty: Double(h))
        let sceneBox = local.applying(m)
        let reach = sceneBox.union(sceneBox.offsetBy(dx: dir.x * length, dy: dir.y * length)).insetBy(dx: -2, dy: -2)
        let area = reach.applying(toDevice).integral.intersection(frame)
        guard !area.isNull, area.width >= 1, area.height >= 1, let off = offscreen(area, scene: scene) else { return }
        off.saveGState()
        off.concatenate(m)
        drawContent(layer, scene: scene, at: t, in: off, alpha: 1)
        off.restoreGState()
        guard let buf = PixelBuffer(off) else { return }
        // Bitmap rows run top to bottom like scene y, so the scene direction is the memory direction.
        buf.smear(dx: dir.x, dy: dir.y, length: length * pixelScale,
                  color: layer.longShadowColor ?? RGBA(r: 0, g: 0, b: 0, a: 0.35))
        guard let img = off.makeImage() else { return }
        ctx.saveGState()
        ctx.setBlendMode(layer.blendMode.cgBlendMode)
        drawDeviceImage(img, rect: area, scene: scene, in: ctx, alpha: opacity)
        ctx.restoreGState()
    }

    /// Marker bands behind words (`textHighlights`), swept in from the left over their duration.
    private func drawTextHighlights(_ layer: MotionLayer, _ layout: (setter: CTFramesetter, box: CGSize, shownUTF16: Int),
                                    at t: Double, in ctx: CGContext) {
        let (bw, bh) = (layout.box.width, layout.box.height)
        ctx.saveGState()
        ctx.translateBy(x: -bw / 2, y: bh / 2)
        ctx.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: bw, height: bh), transform: nil)
        let frame = CTFramesetterCreateFrame(layout.setter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let text = Self.displayText(layer, at: t) as NSString
        for hl in layer.textHighlights where !hl.word.isEmpty {
            var progress = 1.0
            if let s = hl.start {
                let p = min(max((t - s) / max(hl.duration, 0.001), 0), 1)
                progress = 1 - pow(1 - p, 3)
            }
            guard progress > 0.001 else { continue }
            var ranges: [NSRange] = []
            var search = NSRange(location: 0, length: text.length)
            while search.length > 0 {
                let r = text.range(of: hl.word, options: [.caseInsensitive], range: search)
                guard r.location != NSNotFound else { break }
                ranges.append(r)
                if !hl.all { break }
                let next = r.location + r.length
                search = NSRange(location: next, length: text.length - next)
            }
            for r in ranges {
                for (li, line) in lines.enumerated() {
                    let lr = CTLineGetStringRange(line)
                    let lo = max(r.location, lr.location), hi = min(r.location + r.length, lr.location + lr.length)
                    guard hi > lo else { continue }
                    var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                    _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                    let x0 = CTLineGetOffsetForStringIndex(line, lo, nil), x1 = CTLineGetOffsetForStringIndex(line, hi, nil)
                    let o = origins[li]
                    let rect = CGRect(x: o.x + x0 - hl.padding, y: o.y - descent - hl.padding,
                                      width: (x1 - x0) * progress + 2 * hl.padding, height: ascent + descent + 2 * hl.padding)
                    guard rect.width > 0 else { continue }
                    ctx.saveGState()
                    if hl.skew != 0 {
                        ctx.translateBy(x: rect.midX, y: rect.midY)
                        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: tan(hl.skew * .pi / 180), d: 1, tx: 0, ty: 0))
                        ctx.translateBy(x: -rect.midX, y: -rect.midY)
                    }
                    let rad = min(hl.radius, rect.width / 2, rect.height / 2)
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rad, cornerHeight: rad, transform: nil))
                    ctx.setFillColor(hl.color.cgColor)
                    ctx.fillPath()
                    ctx.restoreGState()
                }
            }
        }
        ctx.restoreGState()
    }

    /// Clips `ctx` (in scene space) to what the layer's wipe leaves visible. Returns false when nothing is.
    private func clipToWipe(_ layer: MotionLayer, progress: Double, scene: MotionScene, transform m: CGAffineTransform,
                            at t: Double, copy: CGAffineTransform?, in ctx: CGContext) -> Bool {
        let style = layer.wipeStyle ?? WipeStyle()
        var toScene = m
        guard let region = style.visibleRegion(progress: progress, box: wipeBox(layer, scene: scene, at: t))?
            .copy(using: &toScene) else { return false }
        // Scene px per layer px, to turn the feather into a blur radius.
        let scale = abs(m.a * m.d - m.b * m.c).squareRoot()
        let sigma = style.feather * scale * pixelScale / 2
        guard Self.boxSize(sigma) != nil else {
            ctx.addPath(region)
            ctx.clip(using: .evenOdd)
            return true
        }
        // Soft edge: the region as a blurred gray mask over the area the layer can reach.
        let (w, h) = pixelSize
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        let reach = Double(Self.blurReach(sigma))
        let area = (motionBounds(layer, scene: scene, times: [t], copy: copy) ?? frame)
            .insetBy(dx: -reach, dy: -reach).integral.intersection(frame)
        guard !area.isNull, area.width >= 1, area.height >= 1, let off = offscreen(area, scene: scene) else { return false }
        off.addPath(region)
        off.setFillColor(CGColor(gray: 1, alpha: 1))
        off.fillPath(using: .evenOdd)
        Self.boxBlur(off, sigma: sigma)
        guard let mask = Self.grayMask(off, luma: false, invert: false) else { return false }
        // Same flip as for mattes: the mask is in device pixels with y pointing up.
        let sx = Double(scene.width) / Double(w), sy = Double(scene.height) / Double(h)
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(scene.height))
        ctx.concatenate(flip)
        ctx.clip(to: CGRect(x: area.minX * sx, y: area.minY * sy, width: area.width * sx, height: area.height * sy), mask: mask)
        ctx.concatenate(flip)
        return true
    }

    /// Layer-local box a wipe sweeps across: what the layer shows, without the padding `contentBounds` adds.
    private func wipeBox(_ layer: MotionLayer, scene: MotionScene, at t: Double) -> CGRect {
        switch layer.type {
        case .group:
            return flatContentBounds(layer, scene: scene, at: t) ?? .zero
        case .rect, .ellipse, .particles, .generator:
            let w = max(layer.shapeWidth(at: t), 0), h = max(layer.shapeHeight(at: t), 0)
            if layer.type == .particles, w < 1 || h < 1 { return particleBounds(layer) }
            return CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        case .path:
            return layer.pathShape(at: t).cgPath.boundingBoxOfPath
        case .image, .video:
            return imageFrame(layer, at: t).rect
        case .text:
            if let box = textLayout(layer, at: t)?.box {
                return CGRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height)
            }
        case .model:
            let w = max(layer.shapeWidth(at: t), 0), h = max(layer.shapeHeight(at: t), 0)
            return CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        case .drawing:
            return drawingBounds(layer)
        case .audio:
            break
        }
        return CGRect(x: -Double(scene.width) / 2, y: -Double(scene.height) / 2,
                      width: Double(scene.width), height: Double(scene.height))
    }

    /// Light added on top of the layer: its blurred copy (or that shape in `glowColor`), `glow` times over.
    private func drawGlow(_ layer: MotionLayer, scene: MotionScene, transform m: CGAffineTransform, opacity: Double,
                          fx: PixelEffects?, at t: Double, in ctx: CGContext) {
        let strength = min(max(layer.value(.glow, at: t), 0), 4)
        guard strength > 0.001,
              let g = blurredLayer(layer, scene: scene, transform: m, radius: max(1, layer.value(.glowRadius, at: t)),
                                   fx: fx, at: t)
        else { return }
        var image = g.image
        if let tint = layer.glowColor, let off = Self.bitmap(image.width, image.height) {
            let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            off.draw(image, in: r)
            off.setBlendMode(.sourceIn)
            off.setFillColor(tint.cgColor)
            off.fill(r)
            image = off.makeImage() ?? image
        }
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        var left = strength
        while left > 0.001 {
            drawDeviceImage(image, rect: g.rect, scene: scene, in: ctx, alpha: min(left, 1) * opacity)
            left -= 1
        }
        ctx.restoreGState()
    }

    /// Bar, line, area, pie or donut chart in the box; `reveal` grows it in (bars one after another, lines drawn on,
    /// pies swept). Series colors come from `generator.colors` (else the fill), labels use the layer's font and
    /// text color.
    private func drawChart(_ layer: MotionLayer, in box: CGRect, at t: Double, in ctx: CGContext) {
        let g = layer.generator
        let values = g.valuesValue
        let n = values.count
        guard n > 0 else { return }
        let reveal = min(max(layer.value(.reveal, at: t), 0), 1)
        let colors = g.colors ?? [layer.color(.fill, at: t) ?? .white]
        func color(_ i: Int) -> CGColor {
            if let grad = layer.gradient { return grad.stops[min(i, grad.stops.count - 1)].color.cgColor }
            return colors[i % colors.count].cgColor
        }
        let labels = g.labels ?? []
        let font = Self.font(for: layer)
        let labelColor = (layer.color(.color, at: t) ?? .white).cgColor
        let labelH = labels.isEmpty ? 0.0 : layer.fontSize * 1.4
        let maxV = max(values.max() ?? 1, 1e-9)
        func drawLabel(_ s: String, at p: CGPoint, align: TextAlign = .center) {
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): labelColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            let w = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.saveGState()
            ctx.translateBy(x: p.x, y: p.y)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            let x: Double
            switch align {
            case .left: x = 0
            case .center: x = -w / 2
            case .right: x = -w
            }
            ctx.textPosition = CGPoint(x: x, y: 0)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        switch g.chartValue {
        case .bar:
            let plot = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height - labelH)
            let slot = plot.width / Double(n), bw = slot * 0.64
            let r = max(0, layer.value(.cornerRadius, at: t))
            for (i, v) in values.enumerated() {
                // Bars grow one after another, overlapping a little.
                let k = min(max(reveal * Double(n) * 0.7 - Double(i) * 0.7 + 0.3, 0), 1)
                let ease = 1 - pow(1 - k, 3)
                let hgt = max(0, v / maxV) * plot.height * ease
                let x = plot.minX + slot * (Double(i) + 0.5)
                let rect = CGRect(x: x - bw / 2, y: plot.maxY - hgt, width: bw, height: hgt)
                ctx.setFillColor(color(i))
                if hgt > 0 { ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(r, bw / 2, hgt / 2), cornerHeight: min(r, bw / 2, hgt / 2), transform: nil)); ctx.fillPath() }
                if i < labels.count { drawLabel(labels[i], at: CGPoint(x: x, y: box.maxY - layer.fontSize * 0.25)) }
            }
        case .line, .area:
            let plot = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height - labelH).insetBy(dx: 0, dy: 4)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: plot.minX + plot.width * (n == 1 ? 0.5 : Double(i) / Double(n - 1)),
                        y: plot.maxY - max(0, v / maxV) * plot.height)
            }
            let curve = Generator.smooth(pts, closed: false)
            ctx.saveGState()
            // Drawn on from the left.
            ctx.clip(to: CGRect(x: plot.minX - 10, y: box.minY - 10, width: (plot.width + 20) * reveal, height: box.height + 20))
            if g.chartValue == .area {
                let area = CGMutablePath()
                area.addPath(curve)
                area.addLine(to: CGPoint(x: pts.last!.x, y: plot.maxY))
                area.addLine(to: CGPoint(x: pts[0].x, y: plot.maxY))
                area.closeSubpath()
                if let c = RGBA(cgColor: color(0)) {
                    var faint = c
                    faint.a = c.a * 0.3
                    ctx.setFillColor(faint.cgColor)
                    ctx.addPath(area)
                    ctx.fillPath()
                }
            }
            ctx.setStrokeColor(color(0))
            let lw = layer.value(.strokeWidth, at: t)
            ctx.setLineWidth(lw > 0 ? lw : 6)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(curve)
            ctx.strokePath()
            for p in pts {
                let dot = max(3, (lw > 0 ? lw : 6) * 0.9)
                ctx.setFillColor(color(0))
                ctx.fillEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: 2 * dot, height: 2 * dot))
            }
            ctx.restoreGState()
            for (i, p) in pts.enumerated() where i < labels.count {
                drawLabel(labels[i], at: CGPoint(x: p.x, y: box.maxY - layer.fontSize * 0.25))
            }
        case .pie, .donut:
            let total = max(values.reduce(0, +), 1e-9)
            let c = CGPoint(x: box.midX, y: box.midY)
            let radius = min(box.width, box.height) / 2 - (labels.isEmpty ? 0 : layer.fontSize * 1.2)
            let inner = g.chartValue == .donut ? radius * 0.55 : 0
            var a0 = -Double.pi / 2
            let sweepAll = 2 * Double.pi * reveal
            var used = 0.0
            for (i, v) in values.enumerated() {
                let sweep = v / total * 2 * .pi
                let shown = min(sweep, max(0, sweepAll - used))
                used += sweep
                if shown > 0 {
                    let path = CGMutablePath()
                    path.addArc(center: c, radius: radius, startAngle: a0, endAngle: a0 + shown, clockwise: false)
                    if inner > 0 {
                        path.addArc(center: c, radius: inner, startAngle: a0 + shown, endAngle: a0, clockwise: true)
                    } else {
                        path.addLine(to: c)
                    }
                    path.closeSubpath()
                    ctx.setFillColor(color(i))
                    ctx.addPath(path)
                    ctx.fillPath()
                }
                if i < labels.count, reveal > 0.999 || used <= sweepAll {
                    let mid = a0 + sweep / 2, lr = radius + layer.fontSize * 0.7
                    drawLabel(labels[i], at: CGPoint(x: c.x + cos(mid) * lr, y: c.y + sin(mid) * lr + layer.fontSize * 0.35))
                }
                a0 += sweep
            }
        }
    }

    /// Where a flare's parts go: the source, the box center its ghosts mirror across, and its size.
    struct FlareLayout {
        var src: CGPoint, center: CGPoint, size: Double

        init(_ g: Generator, box: CGRect) {
            src = g.from.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: box.midX, y: box.midY)
            center = CGPoint(x: box.midX, y: box.midY)
            size = g.scale ?? Double(min(box.width, box.height)) * 0.25
        }

        /// Ghosts sit at `src` mirrored through the center by these factors (0 = center, -1 = mirror image).
        static let ghostReach = (near: -0.3, far: -1.75)
        var streakLength: Double { size * 4 }
        var haloRadius: Double { size * 2.2 }
        var ringRadius: Double { hypot(src.x - center.x, src.y - center.y) + size }

        func point(_ f: Double) -> CGPoint {
            CGPoint(x: center.x + (src.x - center.x) * f, y: center.y + (src.y - center.y) * f)
        }

        /// Everything the flare lights, in layer space (the streak and halo reach well past the layer's box).
        var bounds: CGRect {
            var r = CGRect(x: src.x - streakLength, y: src.y - haloRadius, width: streakLength * 2, height: haloRadius * 2)
            r = r.union(CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
            for f in [Self.ghostReach.near, Self.ghostReach.far] {
                let p = point(f)
                r = r.union(CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2))
            }
            return r
        }
    }

    /// Lens flare: a bright source at `from` (default the box center) with a halo, an anamorphic streak and ghost
    /// discs mirrored across the center of the box, all adding light. Every part falls off along a smooth curve
    /// (many gradient stops): straight 2-stop gradients add up to a flat white disc with a visible edge.
    private func drawFlare(_ layer: MotionLayer, in box: CGRect, at t: Double, in ctx: CGContext) {
        let g = layer.generator
        let fl = FlareLayout(g, box: box)
        let src = fl.src, size = fl.size
        let colors = g.colorsValue
        let core = colors.first ?? .white
        let ghost = colors.count > 1 ? colors[1] : RGBA(r: 0.6, g: 0.8, b: 1, a: 1)
        let halo = RGBA.lerp(core, ghost, 0.55)
        let strength = g.gainValue
        /// A radial falloff: `profile` maps 0…1 (center → radius) to 0…1. Stops are packed toward the center,
        /// where the sharp profiles change fastest.
        func glow(_ color: RGBA, at p: CGPoint, radius: Double, alpha: Double, _ profile: (Double) -> Double) {
            guard radius > 0, alpha > 0 else { return }
            let n = 28
            var cols: [CGColor] = [], locs: [CGFloat] = []
            for i in 0...n {
                let x = pow(Double(i) / Double(n), 1.7)
                var c = color
                c.a = color.a * alpha * max(0, min(1, profile(x)))
                cols.append(c.cgColor); locs.append(CGFloat(x))
            }
            guard let grad = CGGradient(colorsSpace: Self.colorSpace, colors: cols as CFArray, locations: locs) else { return }
            ctx.drawRadialGradient(grad, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
        }
        /// Bright point with long soft tails (≈ 1/r²), reaching 0 at the radius.
        func hot(_ k: Double) -> (Double) -> Double {
            { x in let w = 1 - x * x; return w * w / (1 + k * k * x * x) }
        }
        /// A thin bright circle at `at` of the radius.
        func ring(_ at: Double, _ width: Double) -> (Double) -> Double {
            { x in exp(-pow((x - at) / width, 2)) }
        }
        /// An aperture ghost: an even disc, a little brighter toward its rim, with a soft edge.
        let disc: (Double) -> Double = { x in
            let edge = x < 0.75 ? 1 : max(0, 1 - (x - 0.75) / 0.25)
            return (0.55 + 0.45 * x * x * x * x) * edge * edge * (3 - 2 * edge)
        }
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        // Tinted halo, then the hot core: only a small point saturates to white.
        glow(halo, at: src, radius: fl.haloRadius, alpha: 0.32 * strength, hot(3))
        glow(core, at: src, radius: size * 0.9, alpha: min(1, strength), hot(7))
        // Anamorphic streak: a thin bright line inside a faint wider band, both fading along their length.
        let streak = RGBA.lerp(core, ghost, 0.35)
        for (squash, alpha, k) in [(0.08, 0.16, 2.5), (0.022, 0.6, 4.0)] {
            ctx.saveGState()
            ctx.translateBy(x: src.x, y: src.y)
            ctx.scaleBy(x: 1, y: squash)
            glow(streak, at: .zero, radius: fl.streakLength, alpha: alpha * strength, hot(k))
            ctx.restoreGState()
        }
        // Ghosts along the line through the center, on the far side, each tinted a little differently. A source at
        // the center has no axis to mirror along: its ghosts would stack on it as a bullseye, so they fade out.
        let axis = min(1, hypot(src.x - fl.center.x, src.y - fl.center.y) / (size * 0.75))
        let salt = Noise.mix(Noise.hash("flare.\(layer.id)") ^ UInt64(bitPattern: Int64(g.seedValue)))
        let count = g.detail ?? 5
        let (near, far) = FlareLayout.ghostReach
        for i in 0..<count {
            let f = near - Double(i) * ((near - far - 0.15) / Double(max(count, 1))) - Noise.unit(i, salt) * 0.15
            let r = size * (0.15 + Noise.unit(i + 50, salt) * 0.5)
            let tint = RGBA.lerp(ghost, core, Noise.unit(i + 90, salt) * 0.5)
            if i % 2 == 0 {
                glow(tint, at: fl.point(f), radius: r, alpha: 0.13 * strength * axis, disc)
            } else {
                glow(tint, at: fl.point(f), radius: r, alpha: 0.2 * strength * axis, ring(0.8, 0.07))
            }
        }
        // Big faint ring around the center (an anamorphic halo).
        glow(ghost, at: fl.center, radius: fl.ringRadius, alpha: 0.12 * strength, ring(0.93, 0.03))
        ctx.restoreGState()
    }

    /// `alpha`: opacity particles apply themselves (the context's alpha is replaced per particle).
    /// Layers with a mesh warp (2.5D rotation, corner pin, puppet pins) are drawn flat, then warped.
    /// 3D layers are drawn flat and projected by their plane's homography; models are rasterized.
    private func drawContent(_ layer: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext, alpha: Double = 1) {
        if layer.type == .model {
            drawModel(layer, scene: scene, at: t, in: ctx)
            return
        }
        if let (warp, flat) = meshWarp(layer, scene: scene, at: t) {
            if warp.hideBackface && warp.facesAway { return }
            drawWarped(layer, scene: scene, warp: warp, flat: flat, at: t, in: ctx)
            return
        }
        drawFlatContent(layer, scene: scene, at: t, in: ctx, alpha: alpha)
    }

    /// The warp of a 2.5D, pinned or 3D layer with the flat box it applies to (nil = drawn as is).
    private func meshWarp(_ layer: MotionLayer, scene: MotionScene, at t: Double) -> (MeshWarp, CGRect)? {
        guard layer.type != .particles, layer.type != .model else { return nil }
        let p3 = renders3D(layer) ? placed(layer, scene: scene, at: t) : nil
        guard p3 != nil || layer.rotationXYOrPinned else { return nil }
        // Text whose letters can go anywhere (animators on a path) gets the frame's size as its box in 3D.
        let fallback = CGRect(x: -Double(scene.width) / 2, y: -Double(scene.height) / 2,
                              width: Double(scene.width), height: Double(scene.height))
        guard let flat = flatContentBounds(layer, scene: scene, at: t) ?? (p3 != nil ? fallback : nil),
              let warp = MeshWarp(layer, box: meshBox(layer, scene: scene, flat: flat, at: t), at: t,
                                  projective: p3?.local, facesAway: p3?.proj.facesAway ?? false) else { return nil }
        return (warp, flat)
    }

    /// The box a corner pin maps from: the layer's own box (not its padded drawing bounds).
    private func meshBox(_ layer: MotionLayer, scene: MotionScene, flat: CGRect, at t: Double) -> CGRect {
        let b = wipeBox(layer, scene: scene, at: t)
        return b.width > 0 && b.height > 0 ? b : flat
    }

    /// Draws the layer flat into a bitmap at twice the device resolution, then warps it: per pixel through one
    /// homography for rotation/corner pin, or for puppet pins each cell of a grid as two triangles mapped by an
    /// affine transform onto the warped grid.
    private func drawWarped(_ layer: MotionLayer, scene: MotionScene, warp: MeshWarp, flat: CGRect, at t: Double,
                            in ctx: CGContext) {
        // Taken now: drawing the content (a group's children) changes the renderer's per-layer state.
        let depth = depthTarget(for: layer, in: ctx)
        let m = ctx.ctm
        let scale = max(0.05, abs(m.a * m.d - m.b * m.c).squareRoot())
        // A transparent margin of a couple of device px, so the picture's own edges (a rect or image filling its
        // box) are antialiased by the resampling instead of cut by the bitmap's edge or a triangle clip.
        let flat = flat.insetBy(dx: -2 / scale, dy: -2 / scale)
        // Twice the device resolution keeps text crisp where perspective magnifies it and gives the resampling
        // something to average where it shrinks. Never more than 4096 px a side (a corner pin can blow a small layer
        // up a lot; the cap keeps memory sane).
        let k = min(scale * 2, 4096 / max(flat.width, 1), 4096 / max(flat.height, 1))
        let pw = max(1, Int((flat.width * k).rounded(.up))), ph = max(1, Int((flat.height * k).rounded(.up)))
        // Layer space (y down) → bitmap with row 0 at flat.minY.
        func toBitmap(_ c: CGContext) {
            c.translateBy(x: 0, y: Double(ph))
            c.scaleBy(x: Double(pw) / flat.width, y: -Double(ph) / flat.height)
            c.translateBy(x: -flat.minX, y: -flat.minY)
        }
        // A 3D layer's wipe cuts its plane before the projection, so the edge lies on the layer.
        var wipeMask: CGImage?
        if renders3D(layer) {
            let wipe = layer.value(.wipe, at: t)
            if wipe > 0.0001 {
                let style = layer.wipeStyle ?? WipeStyle()
                guard let region = style.visibleRegion(progress: wipe, box: wipeBox(layer, scene: scene, at: t)),
                      let mask = Self.bitmap(pw, ph) else { return }
                toBitmap(mask)
                mask.addPath(region)
                mask.setFillColor(CGColor(gray: 1, alpha: 1))
                mask.fillPath(using: .evenOdd)
                Self.boxBlur(mask, sigma: style.feather * Double(pw) / flat.width / 2)
                wipeMask = Self.grayMask(mask, luma: false, invert: false)
            }
        }
        guard let off = Self.bitmap(pw, ph) else { return }
        if let wipeMask { off.clip(to: CGRect(x: 0, y: 0, width: pw, height: ph), mask: wipeMask) }
        off.setShouldAntialias(true)
        off.interpolationQuality = .high
        toBitmap(off)
        drawFlatContent(layer, scene: scene, at: t, in: off)
        if let h = warp.projectiveMap(over: flat) {
            MeshWarp.drawProjective(off, flat: flat, homography: h, in: ctx, depth: depth)
            return
        }
        guard let image = off.makeImage() else { return }
        let n = warp.cells
        var grid = [[CGPoint]](repeating: [], count: n + 1)
        for j in 0...n {
            for i in 0...n {
                let p = CGPoint(x: flat.minX + flat.width * Double(i) / Double(n), y: flat.minY + flat.height * Double(j) / Double(n))
                grid[j].append(warp.map(p))
            }
        }
        // Triangles are clipped without antialiasing, so neighbors share their edge pixels exactly: each pixel is
        // drawn once. (Antialiased clips either leave hairline seams or, grown to overlap, draw the seams twice,
        // which notches every glyph edge along the grid lines.)
        func drawTriangle(_ s: [CGPoint], _ d: [CGPoint]) {
            // Affine taking source (flat layer px) to destination (warped layer px).
            let (s0, s1, s2) = (s[0], s[1], s[2]), (d0, d1, d2) = (d[0], d[1], d[2])
            let det = (s1.x - s0.x) * (s2.y - s0.y) - (s2.x - s0.x) * (s1.y - s0.y)
            guard abs(det) > 1e-9 else { return }
            let ia = (s2.y - s0.y) / det, ib = -(s2.x - s0.x) / det, ic = -(s1.y - s0.y) / det, id = (s1.x - s0.x) / det
            let ux = d1.x - d0.x, uy = d1.y - d0.y, vx = d2.x - d0.x, vy = d2.y - d0.y
            let a = ux * ia + vx * ic, b = uy * ia + vy * ic, c = ux * ib + vx * id, dd = uy * ib + vy * id
            let tx = d0.x - a * s0.x - c * s0.y, ty = d0.y - b * s0.x - dd * s0.y
            let path = CGMutablePath()
            path.addLines(between: d)
            path.closeSubpath()
            ctx.saveGState()
            ctx.setShouldAntialias(false)
            ctx.addPath(path)
            ctx.clip()
            ctx.concatenate(CGAffineTransform(a: a, b: b, c: c, d: dd, tx: tx, ty: ty))
            ctx.translateBy(x: flat.minX, y: flat.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: flat.width, height: flat.height))
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        for j in 0..<n {
            for i in 0..<n {
                let s00 = CGPoint(x: flat.minX + flat.width * Double(i) / Double(n), y: flat.minY + flat.height * Double(j) / Double(n))
                let s11 = CGPoint(x: flat.minX + flat.width * Double(i + 1) / Double(n), y: flat.minY + flat.height * Double(j + 1) / Double(n))
                let s10 = CGPoint(x: s11.x, y: s00.y), s01 = CGPoint(x: s00.x, y: s11.y)
                drawTriangle([s00, s10, s11], [grid[j][i], grid[j][i + 1], grid[j + 1][i + 1]])
                drawTriangle([s00, s11, s01], [grid[j][i], grid[j + 1][i + 1], grid[j + 1][i]])
            }
        }
        ctx.restoreGState()
    }

    private func drawFlatContent(_ layer: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext, alpha: Double = 1) {
        switch layer.type {
        case .rect, .ellipse, .path: drawShape(layer, at: t, in: ctx)
        case .text: drawText(layer, at: t, in: ctx)
        case .image, .video: drawImage(layer, at: t, in: ctx)
        case .particles: drawParticles(layer, alpha: alpha, in: ctx)
        case .generator: drawGenerator(layer, at: t, in: ctx)
        case .group: drawGroup(layer, scene: scene, at: t, in: ctx)
        case .model: drawModel(layer, scene: scene, at: t, in: ctx)
        case .drawing: drawDrawing(layer, at: t, in: ctx)
        case .audio: break
        }
    }

    /// A drawing layer: the strokes of the frame showing at t (layer px, like a path layer's d).
    private func drawDrawing(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        guard let i = layer.drawing.frameIndex(at: t - layer.start), i < layer.drawing.frames.count else { return }
        for s in layer.drawing.frames[i].strokes {
            guard let shape = drawingPath(s.d) else { continue }
            let path = shape.cgPath
            if let f = s.fill, f.a > 0 {
                ctx.addPath(path)
                ctx.setFillColor(f.cgColor)
                ctx.fillPath()
            }
            if let c = s.stroke, c.a > 0, s.strokeWidth > 0 {
                ctx.addPath(path)
                ctx.setStrokeColor(c.cgColor)
                ctx.setLineWidth(s.strokeWidth)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }
        }
    }

    private func drawingPath(_ d: String) -> PathShape? {
        if let p = drawingPathCache[d] { return p }
        guard let p = try? PathShape(d) else { return nil }
        if drawingPathCache.count > 2048 { drawingPathCache.removeAll() }
        drawingPathCache[d] = p
        return p
    }

    /// Bounds of every frame of a drawing (so the box does not jump between frames), with the stroke width.
    private func drawingBounds(_ layer: MotionLayer) -> CGRect {
        var box = CGRect.null
        var pad = 0.0
        for f in layer.drawing.frames {
            for s in f.strokes {
                if let p = drawingPath(s.d) { box = box.union(p.cgPath.boundingBoxOfPath) }
                pad = max(pad, s.strokeWidth)
            }
        }
        return box.isNull ? .zero : box.insetBy(dx: -pad, dy: -pad)
    }

    /// A group's children, drawn in its box (a scene of its own: origin at the box's top-left, no camera).
    private func drawGroup(_ layer: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext) {
        // Local time: the children's clock starts when the group does.
        let t = layer.localTime ? t - layer.start : t
        let sub = scene.subscene(of: layer, at: t)
        let w = Double(sub.width), h = Double(sub.height)
        ctx.saveGState()
        ctx.translateBy(x: -w / 2, y: -h / 2)
        // Clip to the group's box, unless it covers the whole bitmap anyway (a full-frame group under a camera
        // zoom lands on fractional pixels, and every image drawn inside a soft clip takes CoreGraphics' slow path).
        let box = CGRect(x: 0, y: 0, width: w, height: h)
        let m = ctx.ctm
        let coversAll = m.b == 0 && m.c == 0
            && box.applying(m).insetBy(dx: -0.01, dy: -0.01).contains(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        if !coversAll { ctx.clip(to: box) }
        // Drawn flat, the group is a world of its own: its 3D children see its default camera.
        let saved = space3D, savedDepth = depthContext
        space3D = nil
        depthContext = nil
        defer { space3D = saved; depthContext = savedDepth }
        let matteSources = Set(sub.layers.compactMap { l in l.matte.flatMap { $0.source == l.id ? nil : $0.source } })
        let visible = sub.layers.filter { $0.type.isVisual && !matteSources.contains($0.id) }
        for child in drawOrder(visible, scene: sub, at: t) {
            renderLayer(child, scene: sub, at: t, in: ctx)
        }
        ctx.restoreGState()
    }

    /// Generator layers: a filled outline (spectrum, waveform, lightning, grid) or a noise image, in the layer's box.
    private func drawGenerator(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        let g = layer.generator
        let w = max(layer.shapeWidth(at: t), 0), h = max(layer.shapeHeight(at: t), 0)
        guard w > 0, h > 0 else { return }
        let box = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        if g.kind == .chart {
            drawChart(layer, in: box, at: t, in: ctx)
            return
        }
        if g.kind == .flare {
            drawFlare(layer, in: box, at: t, in: ctx)
            return
        }
        if g.kind == .noise {
            // About one sample per 3 device pixels: noise is smooth, so it is drawn scaled up with interpolation.
            let scale = abs(ctx.ctm.a * ctx.ctm.d - ctx.ctm.b * ctx.ctm.c).squareRoot()
            let step = 3.0
            let iw = min(max(Int((w * scale / step).rounded(.up)), 2), 1024)
            let ih = min(max(Int((h * scale / step).rounded(.up)), 2), 1024)
            guard let img = g.noiseImage(width: iw, height: ih, box: box, at: t, layerId: layer.id) else { return }
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.translateBy(x: box.minX, y: box.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: box.size))
            ctx.restoreGState()
            return
        }
        let width = layer.value(.strokeWidth, at: t)
        let line = width > 0 ? width : (g.kind == .grid ? 2 : 4)
        guard let path = g.path(in: box, at: t, line: line, radius: max(0, layer.value(.cornerRadius, at: t)),
                                layerId: layer.id), !path.isEmpty else { return }
        if let grad = layer.gradient {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            drawGradient(grad, in: box, at: t, in: ctx)
            ctx.restoreGState()
        } else if let fill = layer.color(.fill, at: t), fill.a > 0 {
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
    }

    /// Drop shadow of the whole layer. Offsets are in scene pixels (y down), independent of rotation.
    /// Returns how far the shadow reaches beyond the layer, in scene pixels, or nil when there is none.
    private func applyShadow(_ layer: MotionLayer, at t: Double, in ctx: CGContext) -> Double? {
        let amount = min(max(layer.value(.shadowOpacity, at: t), 0), 1)
        guard amount > 0.001 else { return nil }
        var c = layer.shadowColor
        c.a *= amount
        let x = layer.value(.shadowX, at: t), y = layer.value(.shadowY, at: t)
        let blur = max(0, layer.value(.shadowBlur, at: t))
        ctx.setShadow(offset: CGSize(width: x * pixelScale, height: -y * pixelScale), blur: blur * pixelScale,
                      color: c.cgColor)
        return max(abs(x), abs(y)) + 2 * blur
    }

    /// Renders the layer alone, applies its pixel effects and a gaussian blur (radius in scene pixels, 0 = none).
    /// Returns the image and the device-pixel rect of the frame it covers (bottom-left origin), or nil if nothing of
    /// it is in frame.
    private func blurredLayer(_ layer: MotionLayer, scene: MotionScene, transform m: CGAffineTransform,
                              radius: Double, fx: PixelEffects? = nil, at t: Double) -> (image: CGImage, rect: CGRect)? {
        let (w, h) = pixelSize
        let sigma = radius * pixelScale / 2
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        let toDevice = m.concatenating(CGAffineTransform(a: Double(w) / Double(scene.width), b: 0, c: 0,
                                                         d: -Double(h) / Double(scene.height), tx: 0, ty: Double(h)))
        // Device pixels per layer px.
        let scale = abs(m.a * m.d - m.b * m.c).squareRoot() * pixelScale
        // Only the area the layer can reach once blurred and processed, rather than the whole frame.
        var area = frame
        if let local = contentBounds(layer, scene: scene, at: t) {
            var box = local
            if let fx {
                let r = fx.reach(width: local.width)
                box = box.insetBy(dx: -r, dy: -r)
                // Twirl and bulge pull pixels around anywhere inside their radius.
                if fx.twirl != 0 || fx.bulge != 0 {
                    box = box.union(CGRect(x: -fx.radius, y: -fx.radius, width: 2 * fx.radius, height: 2 * fx.radius))
                }
                // Zoom blur smears outward from the origin, up to 1 / (1 - amount) times as far.
                if fx.zoomBlur > 0.001 {
                    let k = 1 / (1 - fx.zoomBlur)
                    box = box.union(box.applying(CGAffineTransform(scaleX: k, y: k)))
                }
            }
            let reach = Double(Self.blurReach(sigma))
            area = box.applying(toDevice).insetBy(dx: -reach, dy: -reach).integral.intersection(frame)
        }
        // A wide blur (big soft blobs, glows) is rendered and blurred at a fraction of the resolution and scaled
        // back up: with sigma ≥ 8 bitmap pixels the result is the same to the eye, for a fraction of the work.
        // Pixel effects work in device pixels, so they keep the full size.
        let plain = !(fx?.isActive ?? false) && (fx?.shine ?? 0) <= 0.001
        let k = plain && sigma >= 16 ? min(8, Int(sigma / 8)) : 1
        guard !area.isNull, area.width >= 1, area.height >= 1, let off = offscreen(area, scene: scene, downsample: k) else { return nil }
        off.saveGState()
        off.concatenate(m)
        // Particles add up among themselves before the blurred result is blended with the frame.
        if layer.type == .particles { off.setBlendMode(layer.blendMode.cgBlendMode) }
        drawContent(layer, scene: scene, at: t, in: off)
        off.restoreGState()
        // The layer's origin in bitmap pixels (y down).
        let o = CGPoint.zero.applying(toDevice)
        let center = CGPoint(x: o.x - area.minX, y: area.maxY - o.y)
        fx?.applyBeforeBlur(off, center: center, scale: scale)
        Self.boxBlur(off, sigma: sigma / Double(k))
        fx?.applyAfterBlur(off, center: center, scale: scale, pixelScale: pixelScale)
        if let fx, fx.shine > 0.001 { drawShine(layer, scene: scene, transform: m, strength: fx.shine, at: t, in: off) }
        guard let image = off.makeImage() else { return nil }
        // The bitmap was rounded up to whole pixels: the rect it covers grows the same way.
        return (image, CGRect(x: area.minX, y: area.minY, width: Double(off.width * k), height: Double(off.height * k)))
    }

    /// A soft bright band across the layer's box, only where the layer has pixels (light sweep / shine).
    private func drawShine(_ layer: MotionLayer, scene: MotionScene, transform m: CGAffineTransform, strength: Double,
                           at t: Double, in ctx: CGContext) {
        let box = wipeBox(layer, scene: scene, at: t)
        guard box.width > 0, box.height > 0 else { return }
        let pos = layer.value(.shinePosition, at: t)
        let angle = layer.value(.shineAngle, at: t) * .pi / 180
        let width = max(1, layer.value(.shineWidth, at: t))
        let color = layer.shineColor ?? RGBA(r: 1, g: 1, b: 1, a: 0.8)
        var mid = color
        mid.a = min(1, color.a * min(strength, 1))
        var clear = color
        clear.a = 0
        guard let gradient = CGGradient(colorsSpace: Self.colorSpace, colors: [clear.cgColor, mid.cgColor, clear.cgColor] as CFArray,
                                        locations: [0, 0.5, 1]) else { return }
        ctx.saveGState()
        ctx.concatenate(m)
        ctx.setBlendMode(.sourceAtop)
        // The band's center travels along the box's width (turned by the angle), from before its left edge to past
        // its right one.
        let dx = cos(angle), dy = sin(angle)
        let span = abs(dx) * box.width + abs(dy) * box.height
        let c = CGPoint(x: box.midX + dx * (pos - 0.5) * (span + width), y: box.midY + dy * (pos - 0.5) * (span + width))
        var left = strength
        while left > 0.001 {
            ctx.setAlpha(min(left, 1))
            ctx.drawLinearGradient(gradient, start: CGPoint(x: c.x - dx * width / 2, y: c.y - dy * width / 2),
                                   end: CGPoint(x: c.x + dx * width / 2, y: c.y + dy * width / 2), options: [])
            left -= 1
        }
        ctx.restoreGState()
    }

    /// Layer-local bounds of what `drawContent` paints, or nil when unknown (text animators move glyphs anywhere).
    /// Layer-local bounds of what `drawContent` paints (after any mesh warp), or nil when unknown.
    private func contentBounds(_ layer: MotionLayer, scene: MotionScene, at t: Double) -> CGRect? {
        if layer.type == .model { return modelBounds(layer, scene: scene, at: t) }
        guard let (warp, flat) = meshWarp(layer, scene: scene, at: t) else { return flatContentBounds(layer, scene: scene, at: t) }
        // The warped outline, sampled along the edges (bends and perspective push the middle of edges out).
        var out = CGRect.null
        let steps = 8
        for k in 0...steps {
            let f = Double(k) / Double(steps)
            for p in [CGPoint(x: flat.minX + flat.width * f, y: flat.minY), CGPoint(x: flat.minX + flat.width * f, y: flat.maxY),
                      CGPoint(x: flat.minX, y: flat.minY + flat.height * f), CGPoint(x: flat.maxX, y: flat.minY + flat.height * f)] {
                // Part of a 3D layer behind the camera: its projection reaches anywhere in the frame.
                guard let q = warp.mapChecked(p) else { return nil }
                out = out.union(CGRect(x: q.x, y: q.y, width: 0, height: 0))
            }
        }
        return out.insetBy(dx: -2, dy: -2)
    }

    /// Bounds of the layer as drawn flat (before a mesh warp); text with animators gets a generous box.
    private func flatContentBounds(_ layer: MotionLayer, scene: MotionScene, at t: Double) -> CGRect? {
        if layer.type == .text, layer.textPath == nil, !layer.textAnimators.isEmpty, let box = textLayout(layer, at: t)?.box,
           layer.rotationXYOrPinned || renders3D(layer) {
            let pad = max(layer.fontSize, 1) * 2 + layer.textAnimators.map { abs($0.x) + abs($0.y) }.max()!
            return CGRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height).insetBy(dx: -pad, dy: -pad)
        }
        switch layer.type {
        case .rect, .ellipse:
            let w = max(layer.shapeWidth(at: t), 0), h = max(layer.shapeHeight(at: t), 0)
            let stroke = max(layer.value(.strokeWidth, at: t), 0) // covers half the line plus miter corners
            return CGRect(x: -w / 2, y: -h / 2, width: w, height: h).insetBy(dx: -stroke, dy: -stroke)
        case .path:
            let shape = layer.pathShape(at: t)
            guard !shape.isEmpty else { return .zero }
            // Miter joins on sharp corners reach up to 5 line widths out (miter limit 10).
            let stroke = max(layer.value(.strokeWidth, at: t), 0) * (layer.lineJoin == .miter ? 5 : 1)
            return shape.cgPath.boundingBoxOfPath.insetBy(dx: -stroke - 1, dy: -stroke - 1)
        case .image, .video:
            return imageFrame(layer, at: t).rect.insetBy(dx: -4, dy: -4) // placeholder outline
        case .text:
            if let mp = layer.textPath {
                guard layer.textAnimators.isEmpty else { return nil }
                let pts = mp.polyline()
                guard let first = pts.first else { return nil }
                var box = CGRect(origin: first, size: .zero)
                for p in pts { box = box.union(CGRect(origin: p, size: .zero)) }
                let pad = max(layer.fontSize, 1) * 1.5 + layer.value(.strokeWidth, at: t)
                return box.insetBy(dx: -pad, dy: -pad)
            }
            guard layer.textAnimators.isEmpty, let box = textLayout(layer, at: t)?.box else { return nil }
            let pad = max(layer.fontSize, 1) // glyph overhang outside the line box (italics, accents)
            return CGRect(x: -box.width / 2, y: -box.height / 2, width: box.width, height: box.height)
                .insetBy(dx: -pad, dy: -pad)
        case .particles:
            return particleBounds(layer)
        case .generator:
            let w = max(layer.shapeWidth(at: t), 0), h = max(layer.shapeHeight(at: t), 0)
            var box = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            let g = layer.generator
            if g.kind == .flare { return FlareLayout(g, box: box).bounds.union(box) }
            if g.kind == .lightning {
                // The bolt strays up to about twice `scale` from the line between its ends, which may lie outside.
                for p in [g.from, g.to].compactMap({ $0 }) { box = box.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
                let pad = 2 * g.spread(length: max(box.width, box.height))
                box = box.insetBy(dx: -pad, dy: -pad)
            }
            return box.insetBy(dx: -max(layer.value(.strokeWidth, at: t), 4), dy: -max(layer.value(.strokeWidth, at: t), 4))
        case .group:
            let w = layer.width.map { $0.value(at: t) } ?? Double(scene.width)
            let h = layer.height.map { $0.value(at: t) } ?? Double(scene.height)
            return CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        case .model:
            return modelBounds(layer, scene: scene, at: t)
        case .drawing:
            return drawingBounds(layer)
        case .audio:
            return nil
        }
    }

    /// Box size of each of the three passes approximating a gaussian of `sigma` pixels, or nil for no blur.
    private static func boxSize(_ sigma: Double) -> Int? {
        guard sigma > 0.1 else { return nil }
        var size = Int((12 * sigma * sigma / 3 + 1).squareRoot().rounded())
        if size % 2 == 0 { size += 1 }
        return size >= 3 ? size : nil
    }

    /// How far, in pixels, the blur spreads a pixel.
    private static func blurReach(_ sigma: Double) -> Int {
        boxSize(sigma).map { 3 * ($0 / 2) + 1 } ?? 0
    }

    /// Gaussian blur approximated by three box blurs (vImage, CPU, deterministic). Works on premultiplied pixels.
    private static func boxBlur(_ ctx: CGContext, sigma: Double) {
        guard let size = boxSize(sigma), let data = ctx.data else { return }
        let w = ctx.width, h = ctx.height, rowBytes = ctx.bytesPerRow
        guard let tmp = malloc(rowBytes * h) else { return }
        defer { free(tmp) }
        var src = vImage_Buffer(data: data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
        var dst = vImage_Buffer(data: tmp, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: rowBytes)
        let k = UInt32(size)
        for pass in 0..<3 {
            let flags = vImage_Flags(kvImageEdgeExtend)
            if pass % 2 == 0 {
                vImageBoxConvolve_ARGB8888(&src, &dst, nil, 0, 0, k, k, nil, flags)
            } else {
                vImageBoxConvolve_ARGB8888(&dst, &src, nil, 0, 0, k, k, nil, flags)
            }
        }
        // Three passes end in tmp: copy back.
        memcpy(data, tmp, rowBytes * h)
    }

    private func drawShape(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        var fillPath: CGPath
        var pieces: [(path: CGPath, length: Double)]
        var box: CGRect
        var subpaths: [Subpath] = []
        let ops = PathOps(layer, at: t)
        let taper = max(0, layer.value(.taperStart, at: t)) + max(0, layer.value(.taperEnd, at: t)) > 0.001
        if layer.type == .path {
            var shape = layer.pathShape(at: t)
            guard !shape.isEmpty else { return }
            if ops.isActive { shape = ops.apply(to: shape) }
            fillPath = shape.cgPath
            pieces = shape.strokePieces
            subpaths = shape.subpaths
            box = fillPath.boundingBoxOfPath
        } else {
            let w = max(layer.shapeWidth(at: t), 0), h = max(layer.shapeHeight(at: t), 0)
            guard w > 0, h > 0 else { return }
            box = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            let length: Double
            if layer.type == .ellipse {
                fillPath = CGPath(ellipseIn: box, transform: nil)
                let a = w / 2, b = h / 2 // Ramanujan's perimeter approximation
                length = .pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot())
            } else {
                let r = max(0, min(layer.value(.cornerRadius, at: t), w / 2, h / 2))
                fillPath = CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil)
                length = 2 * (w + h) - (8 - 2 * .pi) * r
            }
            pieces = [(fillPath, length)]
            if ops.isActive || taper {
                let shape = ops.apply(to: PathShape(subpaths: PathParser.subpaths(of: fillPath)))
                fillPath = shape.cgPath
                pieces = shape.strokePieces
                subpaths = shape.subpaths
                box = fillPath.boundingBoxOfPath
            }
        }
        let rule: CGPathFillRule = layer.fillRule == .evenodd ? .evenOdd : .winding
        if let g = layer.gradient {
            ctx.saveGState()
            ctx.addPath(fillPath)
            ctx.clip(using: rule)
            drawGradient(g, in: box, at: t, in: ctx)
            ctx.restoreGState()
        } else if let fill = layer.color(.fill, at: t), fill.a > 0 {
            ctx.addPath(fillPath)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath(using: rule)
        }
        if taper {
            strokeTapered(layer, subpaths, at: t, in: ctx)
        } else {
            strokeTrimmed(layer, pieces, at: t, in: ctx)
        }
    }

    /// Stroke thinning to a point at its ends (taperStart/taperEnd), honoring trim like `strokeTrimmed`.
    private func strokeTapered(_ layer: MotionLayer, _ subpaths: [Subpath], at t: Double, in ctx: CGContext) {
        let lineWidth = layer.value(.strokeWidth, at: t)
        guard let stroke = layer.color(.stroke, at: t), lineWidth > 0 else { return }
        var s = min(max(layer.value(.trimStart, at: t), 0), 1), e = min(max(layer.value(.trim, at: t), 0), 1)
        if s > e { swap(&s, &e) }
        guard e - s > 0.0005 else { return }
        let offset = layer.value(.trimOffset, at: t)
        let ts = min(max(layer.value(.taperStart, at: t), 0), 1), te = min(max(layer.value(.taperEnd, at: t), 0), 1)
        ctx.saveGState()
        ctx.setFillColor(stroke.cgColor)
        for sp in subpaths where !sp.segments.isEmpty {
            var from = s + offset, to = e + offset
            if !sp.closed { from = min(max(from, 0), 1); to = min(max(to, 0), 1) }
            ctx.addPath(PathOps.taperedStroke(sp, width: lineWidth, from: from, to: to, taperStart: ts, taperEnd: te))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Strokes each piece between trimStart and trim (end), moved along by trimOffset; trims wrap around.
    private func strokeTrimmed(_ layer: MotionLayer, _ pieces: [(path: CGPath, length: Double)], at t: Double, in ctx: CGContext) {
        let lineWidth = layer.value(.strokeWidth, at: t)
        guard let stroke = layer.color(.stroke, at: t), lineWidth > 0 else { return }
        var s = min(max(layer.value(.trimStart, at: t), 0), 1), e = min(max(layer.value(.trim, at: t), 0), 1)
        if s > e { swap(&s, &e) }
        let visible = e - s
        guard visible > 0.0005 else { return }
        let trimmed = visible < 0.9995
        let offset = s + layer.value(.trimOffset, at: t)
        let start = offset - floor(offset)
        ctx.saveGState()
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(lineWidth)
        let isPath = layer.type == .path
        ctx.setLineCap((layer.lineCap ?? (isPath || trimmed ? .round : .butt)).cgLineCap)
        ctx.setLineJoin((layer.lineJoin ?? (isPath ? .round : .miter)).cgLineJoin)
        if !trimmed, !layer.dash.isEmpty, layer.dash.contains(where: { $0 > 0 }) {
            ctx.setLineDash(phase: layer.value(.dashOffset, at: t), lengths: layer.dash.map { max($0, 0.01) })
        }
        if trimmed && layer.trimSequential && pieces.count > 1 {
            // One window over all pieces laid end to end, so letters write one after another.
            let total = pieces.reduce(0) { $0 + $1.length }
            let shift = layer.value(.trimOffset, at: t) * total
            let from = s * total + shift, to = e * total + shift
            var at = 0.0
            for piece in pieces where piece.length > 0 {
                defer { at += piece.length }
                let a = max(from - at, 0), b = min(to - at, piece.length)
                guard b - a > 0.01 else { continue }
                ctx.addPath(piece.path)
                let period = (b - a) + 3 * piece.length
                ctx.setLineDash(phase: a > 0 ? period - a : 0, lengths: [b - a, period - (b - a)])
                ctx.strokePath()
            }
            ctx.restoreGState()
            return
        }
        for piece in pieces where piece.length > 0 {
            ctx.addPath(piece.path)
            if trimmed {
                let on = visible * piece.length
                // Wrapping past the end needs a pattern that repeats every path length; otherwise a long gap keeps
                // a slightly underestimated length from showing a sliver at the end.
                let wraps = start + visible > 1 + 1e-9
                let period = wraps ? piece.length : on + 2 * piece.length
                ctx.setLineDash(phase: start > 0 ? period - start * piece.length : 0,
                                lengths: [on, period - on])
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Fills the current clip with a gradient laid out over `box` (layer-local px).
    private func drawGradient(_ g: Gradient, in box: CGRect, at t: Double, in ctx: CGContext) {
        var locations = g.stops.map { CGFloat(min(max($0.offset, 0), 1)) }
        guard let gradient = CGGradient(colorsSpace: Self.colorSpace, colors: g.stops.map(\.color.cgColor) as CFArray,
                                        locations: &locations) else { return }
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        let shift = g.shift.value(at: t)
        switch g.type {
        case .linear:
            let a = g.angle.value(at: t) * .pi / 180, dx = cos(a), dy = sin(a)
            let half = max((abs(dx) * box.width + abs(dy) * box.height) / 2, 0.5)
            let cx = box.midX + dx * 2 * half * shift, cy = box.midY + dy * 2 * half * shift
            ctx.drawLinearGradient(gradient, start: CGPoint(x: cx - dx * half, y: cy - dy * half),
                                   end: CGPoint(x: cx + dx * half, y: cy + dy * half), options: options)
        case .radial:
            let c = CGPoint(x: box.minX + g.cx * box.width, y: box.minY + g.cy * box.height)
            let r = max(0.5, g.radius.value(at: t) * hypot(box.width, box.height) / 2)
            let out = max(0, shift) * r
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: out, endCenter: c, endRadius: r + out, options: options)
        case .conic:
            // Wedges around the center, colors from the stops; `angle` is where the first stop starts, `shift` turns them.
            let c = CGPoint(x: box.minX + g.cx * box.width, y: box.minY + g.cy * box.height)
            let r = hypot(box.width, box.height) + 2
            let n = 256
            let start = (g.angle.value(at: t) / 360 + shift) * 2 * .pi
            ctx.saveGState()
            ctx.setShouldAntialias(false)
            for i in 0..<n {
                let f0 = Double(i) / Double(n), f1 = Double(i + 1) / Double(n)
                let a0 = start + f0 * 2 * .pi, a1 = start + f1 * 2 * .pi + 0.004
                ctx.move(to: c)
                ctx.addLine(to: CGPoint(x: c.x + r * cos(a0), y: c.y + r * sin(a0)))
                ctx.addLine(to: CGPoint(x: c.x + r * cos(a1), y: c.y + r * sin(a1)))
                ctx.closePath()
                ctx.setFillColor(g.color(at: (f0 + f1) / 2).cgColor)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
    }

    private func drawText(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        if layer.textPath != nil {
            drawTextOnPath(layer, at: t, in: ctx)
            return
        }
        guard let layout = textLayout(layer, at: t) else { return }
        let (bw, bh) = (layout.box.width, layout.box.height)
        if !layer.textHighlights.isEmpty { drawTextHighlights(layer, layout, at: t, in: ctx) }
        if let g = layer.gradient {
            // Draw the letters, then paint the gradient only where they are.
            let box = CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh)
            if layer.textAnimators.isEmpty {
                ctx.beginTransparencyLayer(in: box.insetBy(dx: -layer.fontSize, dy: -layer.fontSize), auxiliaryInfo: nil)
            } else {
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            drawTextBody(layer, layout, at: t, in: ctx)
            ctx.saveGState()
            ctx.setBlendMode(.sourceIn)
            drawGradient(g, in: box, at: t, in: ctx)
            ctx.restoreGState()
            ctx.endTransparencyLayer()
        } else {
            drawTextBody(layer, layout, at: t, in: ctx)
        }
    }

    private func drawTextBody(_ layer: MotionLayer, _ layout: (setter: CTFramesetter, box: CGSize, shownUTF16: Int),
                              at t: Double, in ctx: CGContext) {
        let (bw, bh) = (layout.box.width, layout.box.height)
        ctx.saveGState()
        // Local y-up space with origin at the text box's bottom-left.
        ctx.translateBy(x: -bw / 2, y: bh / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: bw, height: bh), transform: nil)
        let frame = CTFramesetterCreateFrame(layout.setter, CFRange(location: 0, length: 0), path, nil)
        if !layer.textAnimators.isEmpty {
            drawAnimatedGlyphs(frame, layer: layer, shownUTF16: layout.shownUTF16, at: t, in: ctx)
        } else {
            // Outline behind the letters (twice as wide, half shows): stroking on top would show the inner edges
            // of glyphs built from overlapping contours (SF, variable fonts). Outline-only text (clear fill)
            // instead cuts the letters out of the stroke.
            let strokeW = layer.value(.strokeWidth, at: t)
            let hollow = (layer.color(.color, at: t)?.a ?? 1) <= 0.001
            if let sc = layer.color(.stroke, at: t), strokeW > 0, sc.a > 0 {
                if hollow { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
                ctx.saveGState()
                ctx.setTextDrawingMode(.stroke)
                ctx.setStrokeColor(sc.cgColor)
                ctx.setLineWidth(strokeW * 2)
                ctx.setLineJoin(.round)
                CTFrameDraw(frame, ctx)
                ctx.restoreGState()
                if hollow {
                    ctx.saveGState()
                    ctx.setBlendMode(.destinationOut)
                    ctx.setTextDrawingMode(.fill)
                    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                    CTFrameDraw(frame, ctx)
                    ctx.restoreGState()
                    ctx.endTransparencyLayer()
                    ctx.restoreGState()
                    return
                }
            }
            CTFrameDraw(frame, ctx)
        }
        ctx.restoreGState()
    }

    /// The text as shown at time t: "{n}" replaced by the counter's number, and scrambled letters.
    static func displayText(_ layer: MotionLayer, at t: Double) -> String {
        var s = layer.text
        if s.contains("{n}") {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.minimumFractionDigits = layer.counterDecimals
            f.maximumFractionDigits = layer.counterDecimals
            f.usesGroupingSeparator = layer.counterGrouping
            f.groupingSeparator = ","
            f.decimalSeparator = "."
            let n = f.string(from: NSNumber(value: layer.value(.counter, at: t))) ?? "0"
            s = s.replacingOccurrences(of: "{n}", with: n)
        }
        let scramble = min(max(layer.value(.scramble, at: t), 0), 1)
        if scramble > 0.001 {
            // The letters resolve from the start; the rest flicker through random characters ~15 times a second.
            let chars = Array(s)
            let letters = chars.indices.filter { !chars[$0].isWhitespace }
            let keep = Int((Double(letters.count) * (1 - scramble)).rounded(.down))
            let pool = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#$%&@*+=<>?")
            let tick = UInt64(max(0, Int(t * 15)))
            let salt = Noise.mix(Noise.hash("scramble.\(layer.id)") ^ (tick &* 0x9E3779B97F4A7C15))
            var out = chars
            for (rank, i) in letters.enumerated() where rank >= keep {
                let c = chars[i]
                let r = pool[Int(Noise.unit(i, salt) * Double(pool.count)) % pool.count]
                out[i] = c.isLowercase ? Character(r.lowercased()) : r
            }
            s = String(out)
        }
        return s
    }

    /// Typesets the layer's text: the framesetter, the text box size, and how many UTF-16 units the reveal shows.
    private func textLayout(_ layer: MotionLayer, at t: Double) -> (setter: CTFramesetter, box: CGSize, shownUTF16: Int)? {
        let full = Self.displayText(layer, at: t)
        guard !full.isEmpty else { return nil }
        let font = Self.font(for: layer, at: t)

        var alignment: CTTextAlignment
        switch layer.align {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        let para: CTParagraphStyle = withUnsafePointer(to: &alignment) { ptr in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ptr)
            return CTParagraphStyleCreate(&setting, 1)
        }

        let textColor = layer.color(.color, at: t) ?? .white
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
        ]
        let spacing = layer.value(.letterSpacing, at: t)
        if abs(spacing) > 0.001 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = spacing }
        let str = NSMutableAttributedString(string: full, attributes: attrs)

        // Typewriter: hide trailing characters but keep layout stable.
        let reveal = min(max(layer.value(.reveal, at: t), 0), 1)
        let shown = Int((Double(full.count) * reveal).rounded(.down))
        let shownUTF16 = full.index(full.startIndex, offsetBy: shown).utf16Offset(in: full)
        let animated = !layer.textAnimators.isEmpty
        if shown < full.count && !animated {
            let idx = full.index(full.startIndex, offsetBy: shown)
            str.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                             value: RGBA.clear.cgColor, range: NSRange(idx..<full.endIndex, in: full))
        }

        let setter = CTFramesetterCreateWithAttributedString(str)
        let constraintW = layer.maxWidth ?? 100_000
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: constraintW, height: .greatestFiniteMagnitude), nil)
        let bw = ceil(layer.maxWidth ?? suggested.width) + 2
        let bh = ceil(suggested.height) + 2
        return (setter, CGSize(width: bw, height: bh), shownUTF16)
    }

    /// Draws each glyph with the transform/opacity of its character, word or line (text animators).
    private func drawAnimatedGlyphs(_ frame: CTFrame, layer: MotionLayer, shownUTF16: Int, at t: Double, in ctx: CGContext) {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        let shownText = Self.displayText(layer, at: t)
        let charMap = TextUnits.map(shownText, unit: .char)
        let wordMap = TextUnits.map(shownText, unit: .word)
        let charStates = layer.glyphStates(unit: .char, count: charMap.count, at: t)
        let wordStates = layer.glyphStates(unit: .word, count: wordMap.count, at: t)
        let lineStates = layer.glyphStates(unit: .line, count: lines.count, at: t)
        let strokeW = layer.value(.strokeWidth, at: t)
        let strokeColor = strokeW > 0 ? layer.color(.stroke, at: t).flatMap { $0.a > 0 ? $0 : nil } : nil

        for (li, line) in lines.enumerated() {
            let origin = origins[li]
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let midY = origin.y + (ascent - descent) / 2
            let lineMidX = origin.x + CGFloat(lineWidth) / 2
            let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
            for run in runs {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: n)
                var positions = [CGPoint](repeating: .zero, count: n)
                var advances = [CGSize](repeating: .zero, count: n)
                var indices = [CFIndex](repeating: 0, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                let runAttrs = CTRunGetAttributes(run) as NSDictionary
                let runFont = runAttrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? Self.font(for: layer)
                let color = runAttrs[kCTForegroundColorAttributeName as String].map { $0 as! CGColor }
                    ?? (layer.color(.color, at: t) ?? .white).cgColor
                for g in 0..<n {
                    let si = indices[g]
                    guard si < shownUTF16 else { continue }
                    var st = GlyphState.rest
                    // Pivot: the glyph's own center for characters, the word/line center is approximated by the glyph
                    // for words, and the line center for lines.
                    var pivotX = origin.x + positions[g].x + advances[g].width / 2
                    if si < charMap.indices.count, charMap.indices[si] >= 0 { combine(&st, charStates[charMap.indices[si]]) }
                    if si < wordMap.indices.count, wordMap.indices[si] >= 0 { combine(&st, wordStates[wordMap.indices[si]]) }
                    if li < lineStates.count, !lineStates[li].isRest {
                        combine(&st, lineStates[li])
                        if layer.textAnimators.allSatisfy({ $0.unit == .line }) { pivotX = lineMidX }
                    }
                    guard st.opacity > 0.001, abs(st.scale) > 0.0001 else { continue }
                    ctx.saveGState()
                    ctx.setAlpha(st.opacity)
                    var fill = color
                    if let tint = st.tint, let base = RGBA(cgColor: color) {
                        var mixed = RGBA.lerp(base, RGBA(r: tint.r, g: tint.g, b: tint.b, a: base.a), tint.a)
                        mixed.a = base.a
                        fill = mixed.cgColor
                    }
                    // Local space is y-up here, so a positive (downward) dy moves the glyph down.
                    ctx.translateBy(x: pivotX + st.dx, y: midY - st.dy)
                    ctx.rotate(by: -st.rotation * .pi / 180)
                    ctx.scaleBy(x: st.scale, y: st.scale)
                    ctx.translateBy(x: -pivotX, y: -midY)
                    let pos = CGPoint(x: origin.x + positions[g].x, y: origin.y + positions[g].y)
                    let glyphFont = st.weightAxis != nil || st.widthAxis != nil
                        ? Self.variant(runFont, wght: st.weightAxis, wdth: st.widthAxis) : runFont
                    drawGlyph(glyphs[g], font: glyphFont, at: pos, fill: fill, stroke: strokeColor, strokeWidth: strokeW,
                              blur: st.blur, in: ctx)
                    ctx.restoreGState()
                }
            }
        }
    }

    private func combine(_ a: inout GlyphState, _ b: GlyphState) {
        a.opacity *= b.opacity
        a.dx += b.dx
        a.dy += b.dy
        a.scale *= b.scale
        a.rotation += b.rotation
        a.blur += b.blur
        if let t = b.tint { a.tint = a.tint.map { RGBA.lerp($0, t, 0.5) } ?? t }
        if let w = b.weightAxis { a.weightAxis = w }
        if let w = b.widthAxis { a.widthAxis = w }
    }

    /// One glyph (y-up text space), filled and optionally outlined, blurred through a small bitmap when asked.
    private func drawGlyph(_ glyph: CGGlyph, font: CTFont, at pos: CGPoint, fill: CGColor, stroke: RGBA?,
                           strokeWidth: Double, blur: Double, in ctx: CGContext) {
        var g = glyph
        func paint(_ c: CGContext, at p: CGPoint) {
            var p = p
            // Outline behind the glyph (twice as wide, half shows), then the fill: see drawTextBody.
            let hollow = fill.alpha <= 0.001
            if let stroke {
                c.setStrokeColor(stroke.cgColor)
                c.setLineWidth(strokeWidth * 2)
                c.setLineJoin(.round)
                c.setTextDrawingMode(.stroke)
                CTFontDrawGlyphs(font, &g, &p, 1, c)
                if hollow {
                    // Cut the letter out of its own outline (within this glyph's transparency layer).
                    c.setBlendMode(.destinationOut)
                    c.setFillColor(CGColor(gray: 0, alpha: 1))
                    c.setTextDrawingMode(.fill)
                    CTFontDrawGlyphs(font, &g, &p, 1, c)
                    c.setBlendMode(.normal)
                    return
                }
            }
            c.setFillColor(fill)
            c.setTextDrawingMode(.fill)
            CTFontDrawGlyphs(font, &g, &p, 1, c)
        }
        let m = ctx.ctm
        let scale = abs(m.a * m.d - m.b * m.c).squareRoot()
        let sigma = blur * scale / 2
        let hollow = stroke != nil && fill.alpha <= 0.001
        guard let size = Self.boxSize(sigma) else {
            if hollow { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
            paint(ctx, at: pos)
            if hollow { ctx.endTransparencyLayer() }
            return
        }
        // The glyph alone in a bitmap at device resolution, blurred, then drawn back at its place.
        var box = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, nil, 1).insetBy(dx: -strokeWidth, dy: -strokeWidth)
        let reach = Double(3 * (size / 2) + 1) / scale
        box = box.insetBy(dx: -reach, dy: -reach).offsetBy(dx: pos.x, dy: pos.y)
        let pw = max(1, Int((box.width * scale).rounded(.up))), ph = max(1, Int((box.height * scale).rounded(.up)))
        guard pw * ph < 4_000_000, let off = Self.bitmap(pw, ph) else {
            paint(ctx, at: pos)
            return
        }
        off.scaleBy(x: Double(pw) / box.width, y: Double(ph) / box.height)
        off.translateBy(x: -box.minX, y: -box.minY)
        off.setShouldAntialias(true)
        paint(off, at: pos)
        Self.boxBlur(off, sigma: sigma)
        guard let image = off.makeImage() else { return }
        ctx.draw(image, in: box)
    }

    /// Text laid along `textPath`: each glyph sits on the curve, turned to its direction, from the path's start
    /// (plus `textOffset`; centered/right-aligned texts start later). Text animators still apply per character.
    private func drawTextOnPath(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        guard let mp = layer.textPath, let layout = textLayout(layer, at: t) else { return }
        let poly = mp.polyline()
        guard poly.count >= 2 else { return }
        var lengths: [Double] = [0]
        for i in 1..<poly.count { lengths.append(lengths[i - 1] + hypot(poly[i].x - poly[i - 1].x, poly[i].y - poly[i - 1].y)) }
        let total = lengths.last ?? 0
        guard total > 1 else { return }
        func at(_ d: Double) -> (CGPoint, Double) {
            var dist = d
            if mp.closed { dist = dist - floor(dist / total) * total } else { dist = min(max(dist, 0), total) }
            var lo = 0, hi = lengths.count - 1
            while hi - lo > 1 { let mid = (lo + hi) / 2; if lengths[mid] <= dist { lo = mid } else { hi = mid } }
            let a = poly[lo], b = poly[hi], seg = lengths[hi] - lengths[lo]
            let f = seg > 0 ? (dist - lengths[lo]) / seg : 0
            return (CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), atan2(b.y - a.y, b.x - a.x))
        }
        // One line of the attributed text (line breaks are ignored on a path).
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: 100_000, height: layout.box.height), transform: nil)
        let frame = CTFramesetterCreateFrame(layout.setter, CFRange(location: 0, length: 0), path, nil)
        guard let line = (CTFrameGetLines(frame) as? [CTLine])?.first else { return }
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        var startD = layer.value(.textOffset, at: t)
        switch layer.align {
        case .left: break
        case .center: startD += (total - lineWidth) / 2
        case .right: startD += total - lineWidth
        }
        let shownText = Self.displayText(layer, at: t)
        let charMap = TextUnits.map(shownText, unit: .char)
        let wordMap = TextUnits.map(shownText, unit: .word)
        let charStates = layer.glyphStates(unit: .char, count: charMap.count, at: t)
        let wordStates = layer.glyphStates(unit: .word, count: wordMap.count, at: t)
        let strokeW = layer.value(.strokeWidth, at: t)
        let strokeColor = strokeW > 0 ? layer.color(.stroke, at: t).flatMap { $0.a > 0 ? $0 : nil } : nil
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        // The line's first glyph starts at x = 0 of the line (alignment was applied through startD).
        var lineOrigin = 0.0
        if let first = runs.first, CTRunGetGlyphCount(first) > 0 {
            var p = CGPoint.zero
            CTRunGetPositions(first, CFRange(location: 0, length: 1), &p)
            lineOrigin = p.x
        }
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            var advances = [CGSize](repeating: .zero, count: n)
            var indices = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = runAttrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? Self.font(for: layer)
            let color = runAttrs[kCTForegroundColorAttributeName as String].map { $0 as! CGColor }
                ?? (layer.color(.color, at: t) ?? .white).cgColor
            for g in 0..<n {
                let si = indices[g]
                guard si < layout.shownUTF16 else { continue }
                var st = GlyphState.rest
                if si < charMap.indices.count, charMap.indices[si] >= 0 { combine(&st, charStates[charMap.indices[si]]) }
                if si < wordMap.indices.count, wordMap.indices[si] >= 0 { combine(&st, wordStates[wordMap.indices[si]]) }
                guard st.opacity > 0.001, abs(st.scale) > 0.0001 else { continue }
                let half = advances[g].width / 2
                let d = startD + positions[g].x - lineOrigin + half
                if !mp.closed, d < -half || d > total + half { continue }
                let (p, angle) = at(d)
                var fill = color
                if let tint = st.tint, let base = RGBA(cgColor: color) {
                    var mixed = RGBA.lerp(base, RGBA(r: tint.r, g: tint.g, b: tint.b, a: base.a), tint.a)
                    mixed.a = base.a
                    fill = mixed.cgColor
                }
                ctx.saveGState()
                ctx.setAlpha(st.opacity)
                // Layer space is y-down: move to the point on the path, turn along it, then flip for CoreText.
                ctx.translateBy(x: p.x + st.dx, y: p.y + st.dy)
                ctx.rotate(by: angle + st.rotation * .pi / 180)
                ctx.scaleBy(x: st.scale, y: -st.scale)
                ctx.textMatrix = .identity
                drawGlyph(glyphs[g], font: runFont, at: CGPoint(x: -half, y: positions[g].y), fill: fill,
                          stroke: strokeColor, strokeWidth: strokeW, blur: st.blur, in: ctx)
                ctx.restoreGState()
            }
        }
    }

    private func drawImage(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        let (img, rect) = imageFrame(layer, at: t)
        guard let img else {
            drawPlaceholder(rect, in: ctx)
            return
        }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// The image or video frame (nil if missing) and its layer-local rect: natural size unless width/height are set.
    private func imageFrame(_ layer: MotionLayer, at t: Double) -> (image: CGImage?, rect: CGRect) {
        let setW = layer.width.map { $0.value(at: t) }.flatMap { $0 > 0 ? $0 : nil }
        let setH = layer.height.map { $0.value(at: t) }.flatMap { $0 > 0 ? $0 : nil }
        var img: CGImage?
        var w = setW ?? 400, h = setH ?? 240
        var source: (CGImage?, CGSize)?
        if layer.type == .video {
            source = layer.path.flatMap(videoFrames).map { frames in
                (layer.videoTime(at: t).flatMap { videoFrame(layer, frames, at: $0) }, frames.size)
            }
        } else {
            source = layer.path.flatMap(loadImage).map { ($0.0, $0.1) }
        }
        if let mode = layer.removeBackground, let loaded = source, let picture = loaded.0 {
            source = (cutOut(picture, mode: mode, key: "\(layer.path ?? "")|\(layer.videoTime(at: t) ?? -1)"), loaded.1)
        }
        if let loaded = source, loaded.1.width > 0, loaded.1.height > 0 {
            img = loaded.0
            let iw = Double(loaded.1.width), ih = Double(loaded.1.height)
            w = setW ?? iw; h = setH ?? ih
            if setW != nil && setH == nil { h = w * ih / iw }
            if setH != nil && setW == nil { w = h * iw / ih }
        }
        return (img, CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    }

    /// The source frame at `seconds`, or an in-between of the two nearest frames (frameBlend) for slow motion.
    private func videoFrame(_ layer: MotionLayer, _ frames: VideoFrames, at seconds: Double) -> CGImage? {
        let fps = layer.fps ?? 30
        guard layer.frameBlend != .off else { return frames.image(at: seconds, fps: fps) }
        let fd = frames.frameDuration ?? 1 / max(fps, 1)
        let k = floor(seconds / fd + 1e-6), f = seconds / fd - k
        guard f > 0.02, f < 0.98, let a = frames.image(at: k * fd + fd * 0.01, fps: fps),
              let b = frames.image(at: (k + 1) * fd + fd * 0.01, fps: fps) else { return frames.image(at: seconds, fps: fps) }
        return PictureML.inBetween(a, b, f, flow: layer.frameBlend == .flow) ?? a
    }

    /// Background removal, cached per picture (a still image, or one video frame).
    private func cutOut(_ image: CGImage, mode: BackgroundRemoval, key: String) -> CGImage {
        let k = "\(mode.rawValue)|\(key)|\(image.width)x\(image.height)"
        if let hit = cutoutCache[k] { return hit }
        let result = PictureML.removeBackground(image, mode: mode) ?? image
        if cutoutCache.count > 8 { cutoutCache.removeAll() }
        cutoutCache[k] = result
        return result
    }

    private func drawPlaceholder(_ rect: CGRect, in ctx: CGContext) {
        ctx.setFillColor(RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.25).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(RGBA(r: 1, g: 0.3, b: 0.3).cgColor)
        ctx.setLineWidth(4)
        ctx.stroke(rect)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.move(to: CGPoint(x: rect.maxX, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.strokePath()
    }

    /// Modification time of a file or folder (a folder changes when images are added or removed).
    /// Checked every frame, so a bare stat(2) rather than FileManager's attribute dictionary.
    private static func modificationTime(_ path: String) -> Double? {
        var info = stat()
        return stat(path, &info) == 0 ? Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9 : nil
    }

    private func videoFrames(_ path: String) -> VideoFrames? {
        let expanded = (path as NSString).expandingTildeInPath
        let modified = Self.modificationTime(expanded)
        if let cached = videoCache[expanded], cached.modified == modified { return cached.frames }
        let frames = modified == nil ? nil : VideoFramesFactory.open(expanded)
        videoCache[expanded] = (frames, modified)
        return frames
    }

    private func loadImage(_ path: String) -> (CGImage, CGSize)? {
        let expanded = (path as NSString).expandingTildeInPath
        // Keyed by modification date too, so a file that is overwritten (e.g. by write_asset) reloads.
        let modified = Self.modificationTime(expanded)
        if let cached = imageCache[expanded], cached.modified == modified { return (cached.image, cached.size) }
        guard let loaded = AssetStore.loadImage(URL(fileURLWithPath: expanded)) else { return nil }
        imageCache[expanded] = (loaded.image, loaded.size, modified)
        return (loaded.image, loaded.size)
    }

    static func font(for layer: MotionLayer) -> CTFont { font(for: layer, at: layer.start) }

    /// The layer's font at time t: its face, plus variable-font axes (fontWeightAxis, fontWidth, fontVariations).
    static func font(for layer: MotionLayer, at t: Double) -> CTFont {
        let size = CGFloat(max(layer.fontSize, 1))
        var base: CTFont
        if let name = layer.fontName, let ps = FontLibrary.resolve(name, weight: layer.fontWeight) {
            base = CTFontCreateWithName(ps as CFString, size, nil)
        } else {
            base = FontLibrary.systemFont(layer.fontWeight, size: size)
        }
        let wght = layer.value(.fontWeightAxis, at: t), wdth = layer.value(.fontWidth, at: t)
        return variant(base, wght: wght > 0 ? wght : nil, wdth: wdth > 0 ? wdth : nil, extra: layer.fontVariations)
    }

    /// A copy of a font with variation axes set (no effect on static fonts). Tags are four letters ("wght").
    static func variant(_ font: CTFont, wght: Double?, wdth: Double?, extra: [String: Double] = [:]) -> CTFont {
        var vars: [NSNumber: NSNumber] = [:]
        func tag(_ s: String) -> NSNumber {
            var v: UInt32 = 0
            for c in s.utf8.prefix(4) { v = v << 8 | UInt32(c) }
            return NSNumber(value: v)
        }
        for (k, v) in extra where k.count == 4 { vars[tag(k)] = NSNumber(value: v) }
        if let w = wght { vars[tag("wght")] = NSNumber(value: w) }
        if let w = wdth { vars[tag("wdth")] = NSNumber(value: w) }
        guard !vars.isEmpty else { return font }
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: vars] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, desc)
    }
}

// MARK: - Particles

extension LineCap {
    var cgLineCap: CGLineCap {
        switch self {
        case .butt: return .butt
        case .round: return .round
        case .square: return .square
        }
    }
}

extension LineJoin {
    var cgLineJoin: CGLineJoin {
        switch self {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}

extension BlendMode {
    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: return .normal
        case .add: return .plusLighter
        case .screen: return .screen
        case .multiply: return .multiply
        case .overlay: return .overlay
        case .lighten: return .lighten
        case .darken: return .darken
        }
    }
}

/// A text's letters as a path plus its flattened outline, for emitting particles from text.
struct GlyphOutline {
    let path: CGPath
    let bounds: CGRect
    let segments: [(a: CGPoint, b: CGPoint)]
    /// Running length at the end of each segment.
    let lengths: [Double]

    init(path: CGPath) {
        self.path = path
        bounds = path.boundingBoxOfPath
        var segs: [(a: CGPoint, b: CGPoint)] = []
        var start = CGPoint.zero, cur = CGPoint.zero
        path.applyWithBlock { (el: UnsafePointer<CGPathElement>) in
            let e: CGPathElement = el.pointee
            let p: UnsafeMutablePointer<CGPoint> = e.points
            func curve(_ n: Int, _ at: (CGFloat) -> CGPoint) {
                var last: CGPoint = cur
                for i in 1...n {
                    let q: CGPoint = at(CGFloat(i) / CGFloat(n))
                    segs.append((last, q)); last = q
                }
                cur = last
            }
            switch e.type {
            case .moveToPoint: start = p[0]; cur = p[0]
            case .addLineToPoint: segs.append((cur, p[0])); cur = p[0]
            case .addQuadCurveToPoint:
                let p0: CGPoint = cur, c: CGPoint = p[0], p1: CGPoint = p[1]
                curve(6) { t in GlyphOutline.quad(p0, c, p1, t) }
            case .addCurveToPoint:
                let p0: CGPoint = cur, c1: CGPoint = p[0], c2: CGPoint = p[1], p1: CGPoint = p[2]
                curve(8) { t in GlyphOutline.cubic(p0, c1, c2, p1, t) }
            case .closeSubpath: segs.append((cur, start)); cur = start
            @unknown default: break
            }
        }
        segments = segs
        var total = 0.0
        lengths = segs.map { s in total += hypot(s.b.x - s.a.x, s.b.y - s.a.y); return total }
    }

    private static func quad(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let u: CGFloat = 1 - t
        let a: CGFloat = u * u, b: CGFloat = 2 * u * t, d: CGFloat = t * t
        let x: CGFloat = a * p0.x + b * c.x + d * p1.x
        let y: CGFloat = a * p0.y + b * c.y + d * p1.y
        return CGPoint(x: x, y: y)
    }

    private static func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let u: CGFloat = 1 - t
        let a: CGFloat = u * u * u, b: CGFloat = 3 * u * u * t
        let c: CGFloat = 3 * u * t * t, d: CGFloat = t * t * t
        let x: CGFloat = a * p0.x + b * c1.x + c * c2.x + d * p1.x
        let y: CGFloat = a * p0.y + b * c1.y + c * c2.y + d * p1.y
        return CGPoint(x: x, y: y)
    }

    func pointOnOutline(_ r: Double) -> CGPoint? {
        guard let total = lengths.last, total > 0 else { return nil }
        let target = r * total
        var lo = 0, hi = lengths.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if lengths[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        let s = segments[lo]
        let segStart = lo > 0 ? lengths[lo - 1] : 0
        let len = lengths[lo] - segStart
        let f = len > 0 ? (target - segStart) / len : 0
        return CGPoint(x: s.a.x + (s.b.x - s.a.x) * f, y: s.a.y + (s.b.y - s.a.y) * f)
    }
}

extension FrameRenderer {
    /// White-centered disc fading to black at its edge, used as a mask for soft particles.
    static let softMask: CGImage = {
        let n = 64
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let c = Double(n - 1) / 2
        for y in 0..<n {
            for x in 0..<n {
                let dx = (Double(x) - c) / c, dy = (Double(y) - c) / c
                let f = max(0, 1 - (dx * dx + dy * dy))
                px[y * n + x] = UInt8((f * f * 255).rounded())
            }
        }
        return ctx.makeImage()!
    }()

    /// A paper piece's color as it tumbles: darker edge-on, a little darker on its back, a glint when it faces you.
    /// `facing` is the cosine of the flip (negative = back side).
    static func paperShade(_ c: RGBA, facing: Double) -> CGColor {
        let f = abs(facing)
        let k = (0.5 + 0.5 * f) * (facing < 0 ? 0.85 : 1)
        let glint = 0.35 * pow(f, 14)
        func ch(_ v: Double) -> Double { v * k * (1 - glint) + glint }
        return CGColor(srgbRed: ch(c.r), green: ch(c.g), blue: ch(c.b), alpha: 1)
    }

    fileprivate func drawParticles(_ layer: MotionLayer, alpha: Double, in ctx: CGContext) {
        let sys = layer.particles
        let sprite = sys.shape == .image ? layer.path.flatMap(loadImage) : nil
        let mask = sys.shape == .image && sys.tint ? layer.path.flatMap(imageMask) : nil
        if sys.shape == .spark { ctx.setLineCap(.round) }
        for p in currentParticles {
            let a = alpha * p.color.a
            guard a > 0.002 else { continue }
            let color = CGColor(srgbRed: p.color.r, green: p.color.g, blue: p.color.b, alpha: 1)
            let s = p.size
            if !p.trail.isEmpty {
                // A ribbon thinning and fading toward its tail.
                var prev = CGPoint(x: p.x, y: p.y)
                ctx.setLineCap(.round)
                ctx.setStrokeColor(color)
                for (k, q) in p.trail.enumerated() {
                    let f = 1 - Double(k + 1) / Double(p.trail.count + 1)
                    ctx.setAlpha(a * f * 0.8)
                    ctx.setLineWidth(max(0.5, s * (0.3 + 0.7 * f)))
                    ctx.move(to: prev)
                    ctx.addLine(to: q)
                    ctx.strokePath()
                    prev = q
                }
                if sys.shape == .spark { ctx.setLineCap(.round) } else { ctx.setLineCap(.butt) }
            }
            ctx.setAlpha(a)
            switch sys.shape {
            case .circle:
                ctx.setFillColor(color)
                ctx.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
            case .soft:
                let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
                ctx.saveGState()
                ctx.clip(to: r, mask: Self.softMask)
                ctx.setFillColor(color)
                ctx.fill(r)
                ctx.restoreGState()
            case .square, .confetti:
                ctx.saveGState()
                ctx.translateBy(x: p.x, y: p.y)
                ctx.rotate(by: p.rotation * .pi / 180)
                var fill = color
                if sys.flutter > 0 {
                    // Flip around an axis of its own (a parallelogram, not just a squash), never thinner than a
                    // sliver, lit by how much it faces the viewer.
                    let axis = (p.variant * 7.31).truncatingRemainder(dividingBy: 1) * .pi
                    let c = p.scaleY
                    ctx.rotate(by: axis)
                    ctx.scaleBy(x: 1, y: (c < 0 ? -1 : 1) * max(abs(c), 0.14))
                    ctx.rotate(by: -axis)
                    fill = Self.paperShade(p.color, facing: c)
                }
                ctx.setFillColor(fill)
                if sys.shape == .square {
                    ctx.fill(CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
                } else if p.variant < 0.62 {
                    let h = s * (0.32 + 0.18 * (p.variant * 13.7).truncatingRemainder(dividingBy: 1))
                    ctx.fill(CGRect(x: -s / 2, y: -h / 2, width: s, height: h))
                } else if p.variant < 0.85 {
                    ctx.fill(CGRect(x: -s * 0.35, y: -s * 0.35, width: s * 0.7, height: s * 0.7))
                } else {
                    ctx.fillEllipse(in: CGRect(x: -s * 0.31, y: -s * 0.31, width: s * 0.62, height: s * 0.62))
                }
                ctx.restoreGState()
            case .spark:
                let v = hypot(p.vx, p.vy)
                let len = max(v * sys.streak, 0.01)
                let (ux, uy) = v > 1e-6 ? (p.vx / v, p.vy / v) : (0.0, -1.0)
                ctx.setStrokeColor(color)
                // A streak that is hot at its head and thins and fades toward its tail (three strokes, each
                // shorter and wider than the last). A halo needs a blur: that is the layer's `glow`.
                let passes: [(from: Double, width: Double, alpha: Double)] =
                    [(1, 0.55, 0.5), (0.6, 0.8, 0.75), (0.25, 1, 1)]
                for pass in passes {
                    ctx.setAlpha(a * pass.alpha)
                    ctx.setLineWidth(s * pass.width)
                    ctx.move(to: CGPoint(x: p.x - ux * len * pass.from, y: p.y - uy * len * pass.from))
                    ctx.addLine(to: CGPoint(x: p.x, y: p.y))
                    ctx.strokePath()
                }
            case .image:
                guard let (img, size) = sprite, size.width > 0 else { continue }
                let h = s * size.height / size.width
                let r = CGRect(x: -s / 2, y: -h / 2, width: s, height: h)
                ctx.saveGState()
                ctx.translateBy(x: p.x, y: p.y)
                ctx.rotate(by: p.rotation * .pi / 180)
                ctx.scaleBy(x: 1, y: -p.scaleY) // images are drawn y-up
                if let mask {
                    ctx.clip(to: r, mask: mask)
                    ctx.setFillColor(color)
                    ctx.fill(r)
                } else {
                    ctx.draw(img, in: r)
                }
                ctx.restoreGState()
            }
        }
    }

    /// Area the current particles cover, in the space they are drawn in.
    fileprivate func particleBounds(_ layer: MotionLayer) -> CGRect {
        let sys = layer.particles
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        let k = sys.shape == .image ? 1.5 : 0.75
        for p in currentParticles {
            let r = p.size * k
            var x0 = p.x, x1 = p.x, y0 = p.y, y1 = p.y
            if sys.shape == .spark {
                let tx = p.x - p.vx * sys.streak, ty = p.y - p.vy * sys.streak
                x0 = min(x0, tx); x1 = max(x1, tx); y0 = min(y0, ty); y1 = max(y1, ty)
            }
            minX = min(minX, x0 - r); maxX = max(maxX, x1 + r)
            minY = min(minY, y0 - r); maxY = max(maxY, y1 + r)
        }
        guard minX <= maxX else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Birth point on a text (its letters) or an image/video (its frame); nil for shapes (Core samples those).
    fileprivate func emitPoint(on src: MotionLayer, at t: Double, _ r1: Double, _ r2: Double, _ edge: Bool) -> CGPoint? {
        switch src.type {
        case .text:
            guard let outline = glyphOutline(src, at: t) else { return nil }
            if !edge {
                let seed = Noise.mix(UInt64(r1 * 9_007_199_254_740_992) ^ (UInt64(r2 * 9_007_199_254_740_992) << 1))
                let b = outline.bounds
                for i in 0..<24 {
                    let q = CGPoint(x: b.minX + Noise.unit(2 * i, seed) * b.width, y: b.minY + Noise.unit(2 * i + 1, seed) * b.height)
                    if outline.path.contains(q, using: .winding) { return q }
                }
            }
            return outline.pointOnOutline(r1)
        case .image, .video:
            let r = imageFrame(src, at: t).rect
            return MotionScene.rectPoint(r.width, r.height, r1, r2, edge)
        case .path:
            let shape = src.pathShape(at: t)
            guard !shape.isEmpty else { return nil }
            let key = "path|\(shape.hashValue)"
            let outline: GlyphOutline
            if let cached = glyphCache[key] { outline = cached } else {
                if glyphCache.count > 64 { glyphCache.removeAll() }
                outline = GlyphOutline(path: shape.cgPath)
                glyphCache[key] = outline
            }
            if !edge, shape.subpaths.contains(where: \.closed) {
                let seed = Noise.mix(UInt64(r1 * 9_007_199_254_740_992) ^ (UInt64(r2 * 9_007_199_254_740_992) << 1))
                let b = outline.bounds
                for i in 0..<24 {
                    let q = CGPoint(x: b.minX + Noise.unit(2 * i, seed) * b.width, y: b.minY + Noise.unit(2 * i + 1, seed) * b.height)
                    if outline.path.contains(q, using: src.fillRule == .evenodd ? .evenOdd : .winding) { return q }
                }
            }
            return outline.pointOnOutline(r1)
        default:
            return nil
        }
    }

    /// Outline of a text layer's letters in layer-local px (centered, y down), as `drawText` lays them out.
    private func glyphOutline(_ layer: MotionLayer, at t: Double) -> GlyphOutline? {
        let spacing = layer.value(.letterSpacing, at: t)
        let key = [Self.displayText(layer, at: t), "\(layer.fontSize)", layer.fontWeight, layer.fontName ?? "", "\(layer.maxWidth ?? -1)",
                   layer.align.rawValue, String(format: "%.2f", spacing),
                   String(format: "%.1f/%.1f", layer.value(.fontWeightAxis, at: t), layer.value(.fontWidth, at: t))].joined(separator: "|")
        if let cached = glyphCache[key] { return cached }
        guard let layout = textLayout(layer, at: t) else { return nil }
        let (bw, bh) = (layout.box.width, layout.box.height)
        let frame = CTFramesetterCreateFrame(layout.setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: bw, height: bh), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let path = CGMutablePath()
        for (li, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: n)
                var positions = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let font = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? Self.font(for: layer)
                for g in 0..<n {
                    // Glyph space is y-up from the text box's bottom-left; layer space is y-down from its center.
                    var m = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origins[li].x + positions[g].x - bw / 2,
                                              ty: bh / 2 - origins[li].y - positions[g].y)
                    if let gp = CTFontCreatePathForGlyph(font, glyphs[g], &m) { path.addPath(gp) }
                }
            }
        }
        guard !path.isEmpty else { return nil }
        if glyphCache.count > 64 { glyphCache.removeAll() }
        let outline = GlyphOutline(path: path)
        glyphCache[key] = outline
        return outline
    }

    /// The box a text layer is laid out in (maxWidth, or the width of its longest line), centered on its origin.
    public func textBoxSize(_ layer: MotionLayer, at t: Double) -> CGSize? {
        guard layer.type == .text else { return nil }
        return textLayout(layer, at: t)?.box
    }

    /// A text layer's glyphs as outlines in layer px (around its center, y down), one path per glyph with its
    /// center, in reading order. Used to turn text into paths.
    public func glyphPaths(_ layer: MotionLayer, at t: Double) -> [(path: CGPath, center: CGPoint)] {
        guard layer.type == .text, let layout = textLayout(layer, at: t) else { return [] }
        let (bw, bh) = (layout.box.width, layout.box.height)
        let frame = CTFramesetterCreateFrame(layout.setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: bw, height: bh), transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var out: [(CGPath, CGPoint)] = []
        for (li, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: n)
                var positions = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let font = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? Self.font(for: layer)
                for g in 0..<n {
                    var m = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origins[li].x + positions[g].x - bw / 2,
                                              ty: bh / 2 - origins[li].y - positions[g].y)
                    guard let gp = CTFontCreatePathForGlyph(font, glyphs[g], &m), !gp.isEmpty else { continue }
                    let b = gp.boundingBoxOfPath
                    out.append((gp, CGPoint(x: b.midX, y: b.midY)))
                }
            }
        }
        return out
    }

    /// The image's alpha as a grayscale mask (at most 256 px), so it can be painted in any color.
    private func imageMask(_ path: String) -> CGImage? {
        let expanded = (path as NSString).expandingTildeInPath
        let modified = Self.modificationTime(expanded)
        if let cached = maskCache[expanded], cached.modified == modified { return cached.mask }
        guard let (img, size) = loadImage(path), size.width > 0, size.height > 0 else { return nil }
        let k = min(1, 256 / max(size.width, size.height))
        let w = max(1, Int(size.width * k)), h = max(1, Int(size.height * k))
        guard let rgba = Self.bitmap(w, h),
              let gray = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let src = rgba.data?.assumingMemoryBound(to: UInt8.self),
              let dst = gray.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        rgba.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rowBytes = rgba.bytesPerRow
        for y in 0..<h {
            for x in 0..<w { dst[y * w + x] = src[y * rowBytes + x * 4 + 3] }
        }
        guard let mask = gray.makeImage() else { return nil }
        maskCache[expanded] = (mask, modified)
        return mask
    }
}

// MARK: - 3D

extension FrameRenderer {
    /// Drawn in 3D: `threeD` layers and models, and every visual layer inside a 3D group that keeps its children in 3D.
    private func renders3D(_ layer: MotionLayer) -> Bool {
        guard layer.type != .particles, layer.type != .audio else { return false }
        return layer.is3D || space3D != nil
    }

    /// A 3D group with 3D children: they are drawn in the group's 3D space rather than flat in its box.
    private func keepsChildren3D(_ layer: MotionLayer) -> Bool {
        layer.type == .group && renders3D(layer) && layer.children.contains { $0.is3D }
    }

    /// The frame's depth buffer for a 3D layer drawn straight into the frame (nil otherwise: blurred and processed
    /// layers go through bitmaps of their own and keep the far-to-near order only).
    private func depthTarget(for layer: MotionLayer, in ctx: CGContext) -> DepthTarget? {
        guard let depthBuffer, let depthContext, ctx === depthContext, renders3D(layer) else { return nil }
        return DepthTarget(buffer: depthBuffer, writes: depthWrites)
    }

    /// Places a 3D layer (or a repeater copy of it) and remembers it for its bounds and content.
    @discardableResult
    private func place3D(_ layer: MotionLayer, scene: MotionScene, at t: Double, copy: CGAffineTransform?) -> Placed3D {
        let lookup = space3D?.lookup ?? scene
        var world = lookup.matrix3D(of: layer, at: t, copy: copy, force3D: space3D != nil)
        if let s = space3D { world = s.prefix * world }
        let view = space3D?.view ?? scene.view3D(fixed: layer.fixed, at: t)
        let proj = LayerProjection(world: world, view: view)
        let h = proj.homography
        // The stand-in transform: the projected origin, scaled like the layer is around it (so effects measured in
        // layer px keep about their size), not turned. Behind the camera: the frame's center.
        var a = CGAffineTransform(translationX: Double(scene.width) / 2, y: Double(scene.height) / 2)
        if h[8] > View3D.near {
            let ox = h[2] / h[8], oy = h[5] / h[8]
            let j00 = (h[0] - ox * h[6]) / h[8], j01 = (h[1] - ox * h[7]) / h[8]
            let j10 = (h[3] - oy * h[6]) / h[8], j11 = (h[4] - oy * h[7]) / h[8]
            let s = min(max(abs(j00 * j11 - j01 * j10).squareRoot(), 0.01), 100)
            a = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: ox, ty: oy)
        }
        // Layer-local → stand-in space: A⁻¹ · H (w stays the camera depth).
        let s = Double(a.a), ox = Double(a.tx), oy = Double(a.ty)
        let local = [(h[0] - ox * h[6]) / s, (h[1] - ox * h[7]) / s, (h[2] - ox * h[8]) / s,
                     (h[3] - oy * h[6]) / s, (h[4] - oy * h[7]) / s, (h[5] - oy * h[8]) / s,
                     h[6], h[7], h[8]]
        let placed = Placed3D(t: t, proj: proj, affine: a, local: local)
        placed3D[layer.id] = placed
        return placed
    }

    /// The placement made by the layer's transform at time t (or a fresh one without repeater copy).
    private func placed(_ layer: MotionLayer, scene: MotionScene, at t: Double) -> Placed3D {
        if let p = placed3D[layer.id], p.t == t { return p }
        return place3D(layer, scene: scene, at: t, copy: nil)
    }

    /// Depth-of-field blur: 2D layers by their `depth`; 3D layers by their distance from the camera, in the same unit
    /// (0 = at the camera's distance, 1 = twice as far).
    private func focusBlur(_ layer: MotionLayer, scene: MotionScene, at t: Double) -> Double {
        guard renders3D(layer) else { return scene.focusBlur(for: layer, at: t) }
        guard let camera = scene.camera, !layer.fixed else { return 0 }
        let a = camera.aperture.value(at: t)
        guard a > 0 else { return 0 }
        let p = placed(layer, scene: scene, at: t).proj
        return a * abs(p.depth / max(p.view.distance, 1) - 1 - camera.focus.value(at: t))
    }

    /// Layers in draw order, each run of consecutive 3D layers sorted far to near by the depth of their origin.
    private func drawOrder(_ layers: [MotionLayer], scene: MotionScene, at t: Double) -> [MotionLayer] {
        guard layers.contains(where: { renders3D($0) }) else { return layers }
        var out: [MotionLayer] = []
        var run: [(layer: MotionLayer, depth: Double)] = []
        func flush() {
            out += run.enumerated().sorted { a, b in
                a.element.depth != b.element.depth ? a.element.depth > b.element.depth : a.offset < b.offset
            }.map(\.element.layer)
            run = []
        }
        for l in layers {
            if renders3D(l) {
                run.append((l, place3D(l, scene: scene, at: t, copy: nil).proj.depth))
            } else {
                flush()
                out.append(l)
            }
        }
        flush()
        return out
    }

    /// A 3D group whose children stay in 3D: each child is placed in the group's space and sorted by depth with its
    /// siblings. The group's opacity and blend mode apply to them together; its other effects do not.
    private func drawGroup3D(_ group: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext,
                             copy: CGAffineTransform?, opacity: Double) {
        let lookup = space3D?.lookup ?? scene
        var world = lookup.matrix3D(of: group, at: t, copy: copy, force3D: true)
        if let s = space3D { world = s.prefix * world }
        let view = space3D?.view ?? scene.view3D(fixed: group.fixed, at: t)
        let sub = lookup.subscene(of: group, at: t)
        let t = group.localTime ? t - group.start : t
        let saved = space3D
        // Children use coordinates in the group's box, whose center is the group's origin.
        space3D = Space3DContext(view: view, prefix: world * Mat4.translation(-Double(sub.width) / 2, -Double(sub.height) / 2, 0),
                                 lookup: sub)
        defer { space3D = saved }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let grouped = opacity < 0.999 || group.blendMode != .normal
        if grouped {
            ctx.setBlendMode(group.blendMode.cgBlendMode)
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        let matteSources = Set(sub.layers.compactMap { l in l.matte.flatMap { $0.source == l.id ? nil : $0.source } })
        let visible = sub.layers.filter { $0.type.isVisual && $0.type != .particles && !matteSources.contains($0.id) }
        for child in drawOrder(visible, scene: scene, at: t) {
            renderLayer(child, scene: scene, at: t, in: ctx)
        }
        if grouped { ctx.endTransparencyLayer() }
    }

    // MARK: Models

    /// A model's projected bounding box in its stand-in space, nil when part of it is behind the camera.
    private func modelBounds(_ layer: MotionLayer, scene: MotionScene, at t: Double) -> CGRect? {
        guard let mesh = mesh(for: layer, at: t), !mesh.isEmpty else { return .zero }
        let p = placed(layer, scene: scene, at: t)
        let (lo, hi) = mesh.bounds
        let mv = p.proj.modelView
        let inv = p.affine.inverted()
        var out = CGRect.null
        for i in 0..<8 {
            let c = SIMD3(Double(i & 1 == 0 ? lo.x : hi.x), Double(i & 2 == 0 ? lo.y : hi.y), Double(i & 4 == 0 ? lo.z : hi.z))
            guard let s = p.proj.view.project(mv.point(c)) else { return nil }
            out = out.union(CGRect(origin: s.applying(inv), size: .zero))
        }
        return out.insetBy(dx: -2, dy: -2)
    }

    private func drawModel(_ layer: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext) {
        guard let mesh = mesh(for: layer, at: t), !mesh.isEmpty else { return }
        let p = placed(layer, scene: scene, at: t)
        let ctm = ctx.ctm
        let clip = ctx.boundingBoxOfClipPath.applying(ctm)
        var box = (modelBounds(layer, scene: scene, at: t)?.applying(ctm) ?? clip).intersection(clip).integral
        box = box.intersection(clip.integral)
        guard !box.isNull, box.width >= 1, box.height >= 1, box.width * box.height <= 8192 * 8192 else { return }
        let fill = layer.color(.fill, at: t) ?? .white
        let side = layer.model.sideColor ?? fill
        var materials = [Material3D(color: fill.simd, texture: layer.model.shape.isTexturable ? layer.path.flatMap(texture) : nil),
                         Material3D(color: side.simd, texture: nil)]
        for m in mesh.fileMaterials { materials.append(Material3D(color: m.color.simd, texture: m.texture)) }
        guard let image = Raster3D.render(mesh, modelView: p.proj.modelView, view: p.proj.view,
                                          sceneToDevice: p.affine.inverted().concatenating(ctm), box: box,
                                          materials: materials, lights: cameraLights(scene, view: p.proj.view, at: t),
                                          shininess: Float(layer.model.shininessValue), metallic: Float(layer.model.metallicValue),
                                          ss: max(1, min(modelSupersampling, 4)), depth: depthTarget(for: layer, in: ctx))
        else { return }
        ctx.saveGState()
        ctx.concatenate(ctm.inverted()) // device space: the image lands on whole pixels
        ctx.draw(image, in: box)
        ctx.restoreGState()
    }

    /// The scene's lights (or the default ones) in the camera's space at time t.
    private func cameraLights(_ scene: MotionScene, view: View3D, at t: Double) -> [CameraLight] {
        let vm = view.matrix
        return (scene.lights.isEmpty ? Light.defaults : scene.lights).map { l in
            let k = Float(max(0, l.intensity.value(at: t)) * l.color.a)
            let c = SIMD3<Float>(Float(l.color.r), Float(l.color.g), Float(l.color.b)) * k
            switch l.type {
            case .ambient:
                return CameraLight(kind: .ambient, color: c, vector: .zero)
            case .directional:
                let d = SIMD3(l.x.value(at: t), l.y.value(at: t), l.z.value(at: t))
                let len = simd_length(d)
                let toLight = len > 0 ? -d / len : SIMD3(0, 0, -1)
                let r = vm * SIMD4(toLight, 0)
                return CameraLight(kind: .directional, color: c,
                                   vector: simd_normalize(SIMD3<Float>(Float(r.x), Float(r.y), Float(r.z))))
            case .point:
                let q = vm * SIMD4(l.x.value(at: t), l.y.value(at: t), l.z.value(at: t), 1)
                return CameraLight(kind: .point, color: c, vector: SIMD3<Float>(Float(q.x), Float(q.y), Float(q.z)))
            }
        }
    }

    /// An image file as a model texture (cached by path and modification time).
    private func texture(_ path: String) -> Texture3D? {
        let expanded = (path as NSString).expandingTildeInPath
        let modified = Self.modificationTime(expanded)
        if let c = textureCache[expanded], c.modified == modified { return c.texture }
        guard let (img, _) = loadImage(path), let tex = Texture3D(img) else { return nil }
        if textureCache.count > 16 { textureCache.removeAll() }
        textureCache[expanded] = (tex, modified)
        return tex
    }

    /// The model's mesh at time t, built once per shape (key = everything that changes it).
    private func mesh(for layer: MotionLayer, at t: Double) -> Mesh3D? {
        let mdl = layer.model
        let w = max(layer.shapeWidth(at: t), 0), h = max(layer.shapeHeight(at: t), 0)
        let sidesSlot: UInt16 = mdl.sideColor != nil ? 1 : 0
        var key = "\(mdl.shape.rawValue)|\(mdl.segmentCount)|\(mdl.radius ?? -1)|\(mdl.depth ?? -1)|\(sidesSlot)"
            + "|\(mdl.bevelValue)|\(mdl.bevelStepCount)"
        switch mdl.shape {
        case .text:
            key += "|\(layer.text)|\(layer.fontName ?? "")|\(layer.fontWeight)|\(layer.fontSize)|\(layer.align)|\(layer.maxWidth ?? 0)"
                + "|\(layer.value(.letterSpacing, at: t))"
        case .path:
            key += "|\(layer.pathShape(at: t).svg)|\(layer.fillRule)"
        case .lathe:
            key += "|\(layer.pathShape(at: t).svg)"
        case .file:
            let p = layer.path.map { ($0 as NSString).expandingTildeInPath } ?? ""
            key += "|\(p)|\(Self.modificationTime(p) ?? 0)|\(w)"
        default:
            key += "|\(w)|\(h)"
        }
        if mdl.shape == .file {
            let file: ModelFile?
            if let f = modelFileCache[key] {
                file = f
            } else {
                // Unreadable files are remembered too, so they are not reloaded every frame.
                file = layer.path.flatMap { try? MeshBuilder.load(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath),
                                                                  size: Float(w > 0 ? w : 400)) }
                if modelFileCache.count > 16 { modelFileCache.removeAll() }
                modelFileCache[key] = file
            }
            guard let file else { return nil }
            guard let (clip, time) = layer.modelClip(at: t, in: file.animations) else { return file.mesh }
            let poseKey = "\(layer.id)|\(key)"
            if let p = poseCache[poseKey], p.clip == clip, p.time == time { return p.mesh }
            let posed = file.posed(clip, at: time)
            if poseCache.count > 32 { poseCache.removeAll() }
            poseCache[poseKey] = (clip, time, posed)
            return posed
        }
        if let m = meshCache[key] { return m }
        let fw = Float(w), fh = Float(h)
        let mesh: Mesh3D
        switch mdl.shape {
        case .box:
            mesh = MeshBuilder.box(w: fw, h: fh, d: Float(mdl.depth ?? min(w, h)), sidesSlot: sidesSlot)
        case .plane:
            mesh = MeshBuilder.plane(w: fw, h: fh)
        case .sphere:
            mesh = MeshBuilder.sphere(rx: fw / 2, ry: fh / 2, rz: Float(mdl.depth ?? w) / 2, segments: mdl.segmentCount)
        case .cylinder, .cone:
            mesh = MeshBuilder.cylinder(rx: fw / 2, rz: Float(mdl.depth ?? w) / 2, h: fh,
                                        topScale: mdl.shape == .cone ? Float(mdl.radius ?? 0) : 1,
                                        segments: mdl.segmentCount, sidesSlot: sidesSlot)
        case .torus:
            mesh = MeshBuilder.torus(r: fw / 2, tube: Float(mdl.radius ?? 0.3) * fw / 2, segments: mdl.segmentCount)
        case .text:
            var text = layer
            text.type = .text
            text.textAnimators = []
            text.textPath = nil
            let outline = CGMutablePath()
            for g in glyphPaths(text, at: t) { outline.addPath(g.path) }
            mesh = MeshBuilder.extrude(outline, depth: Float(mdl.depth ?? layer.fontSize * 0.3),
                                       bevel: Float(mdl.bevelValue), bevelSteps: mdl.bevelStepCount)
        case .path:
            mesh = MeshBuilder.extrude(layer.pathShape(at: t).cgPath, depth: Float(mdl.depth ?? 40), evenOdd: layer.fillRule == .evenodd,
                                       bevel: Float(mdl.bevelValue), bevelSteps: mdl.bevelStepCount)
        case .lathe:
            mesh = MeshBuilder.lathe(layer.pathShape(at: t).cgPath, segments: mdl.segmentCount)
        case .file:
            return nil
        }
        if meshCache.count > 48 { meshCache.removeAll() }
        meshCache[key] = mesh
        return mesh
    }
}

private extension RGBA {
    var simd: SIMD4<Float> { SIMD4(Float(r), Float(g), Float(b), Float(a)) }
}
