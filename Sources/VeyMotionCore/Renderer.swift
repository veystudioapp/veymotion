import AppKit
import CoreGraphics
import Accelerate
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic CoreGraphics renderer. Preview and export both use this, so what you see is what you export.
/// Not thread-safe: use one instance per thread.
public final class FrameRenderer {
    private var imageCache: [String: (image: CGImage, size: CGSize, modified: Double?)] = [:]
    /// Alpha of image sprites as grayscale masks (for tinted particles), keyed like `imageCache`.
    private var maskCache: [String: (mask: CGImage, modified: Double?)] = [:]
    /// Text outlines particles are emitted from, keyed by everything that changes the outline.
    private var glyphCache: [String: GlyphOutline] = [:]
    /// Particles of the layer being drawn (simulated once per layer and frame).
    private var currentParticles: [Particle] = []
    /// Open video decoders by path, reopened when the file (or sequence folder) changes. nil = unreadable.
    private var videoCache: [String: (frames: VideoFrames?, modified: Double?)] = [:]
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Sub-frame renders averaged for a layer with motion blur (lower it for a faster preview).
    public var motionBlurSamples = 8
    /// Set while rendering motion-blur samples, so samples are not blurred again.
    private var inMotionSample = false

    public init() {}

    /// Drops every cached image and open video decoder (e.g. when another project is opened).
    public func clearCaches() {
        imageCache.removeAll()
        maskCache.removeAll()
        glyphCache.removeAll()
        videoCache.removeAll()
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
        // Switch to scene coordinates: origin top-left, y down, 1 unit = 1 scene pixel.
        Self.applySceneSpace(ctx, scene: scene, pixelWidth: pixelWidth, pixelHeight: pixelHeight)

        ctx.setFillColor(scene.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: scene.width, height: scene.height))

        // A layer used as another's track matte is only drawn through that layer.
        let matteSources = Set(scene.layers.compactMap { l in l.matte.flatMap { $0.source == l.id ? nil : $0.source } })
        for layer in scene.layers where layer.type.isVisual && !matteSources.contains(layer.id) {
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
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
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
                drawCopy(layer, scene: scene, at: ti, in: ctx, copy: c.transform, alphaScale: c.opacity)
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
    private func offscreen(_ area: CGRect, scene: MotionScene) -> CGContext? {
        guard let off = Self.bitmap(Int(area.width), Int(area.height)) else { return nil }
        off.setShouldAntialias(true)
        off.interpolationQuality = .high
        off.translateBy(x: -area.minX, y: -area.minY)
        Self.applySceneSpace(off, scene: scene, pixelWidth: pixelSize.w, pixelHeight: pixelSize.h)
        return off
    }

    /// Draws a device-pixel image of part of the frame at its place (ctx in scene coordinates).
    private func drawDeviceImage(_ image: CGImage, rect r: CGRect, scene: MotionScene, in ctx: CGContext) {
        let sx = Double(scene.width) / Double(pixelSize.w), sy = Double(scene.height) / Double(pixelSize.h)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(scene.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy))
        ctx.restoreGState()
    }

    /// Scene transform of a layer (or of one of its repeater copies, `copy` being the step in its parent's space).
    private func transform(of layer: MotionLayer, scene: MotionScene, at t: Double, copy: CGAffineTransform?) -> CGAffineTransform {
        guard let copy else { return scene.worldTransform(of: layer, at: t) }
        return layer.localTransform(at: t).concatenating(copy).concatenating(scene.parentTransform(of: layer, at: t))
    }

    /// One copy of a layer, averaged over the shutter time when it has motion blur.
    private func drawCopy(_ layer: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext,
                          copy: CGAffineTransform?, alphaScale: Double) {
        let shutter = layer.motionBlur / 360 / Double(max(scene.fps, 1))
        let n = motionBlurSamples
        guard shutter > 0, n > 1, !inMotionSample else {
            drawLayer(layer, scene: scene, at: t, in: ctx, copy: copy, alphaScale: alphaScale)
            return
        }
        let nd = Double(n)
        let times: [Double] = (0..<n).map { i -> Double in
            let frac: Double = (Double(i) + 0.5) / nd - 0.5
            return t + shutter * frac
        }
        let (w, h) = pixelSize
        let frame = CGRect(x: 0, y: 0, width: w, height: h)
        let area = (motionBounds(layer, scene: scene, times: times, copy: copy) ?? frame).integral.intersection(frame)
        guard !area.isNull, area.width >= 1, area.height >= 1, let off = offscreen(area, scene: scene),
              let data = off.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let rb = off.bytesPerRow, ah = off.height, rowLen = off.width * 4
        var acc = [UInt32](repeating: 0, count: rowLen * ah)
        inMotionSample = true
        for tk in times {
            memset(data, 0, rb * ah)
            drawLayer(layer, scene: scene, at: tk, in: off, copy: copy, alphaScale: alphaScale)
            acc.withUnsafeMutableBufferPointer { a in
                for y in 0..<ah {
                    let row = y * rb, ar = y * rowLen
                    for x in 0..<rowLen { a[ar + x] &+= UInt32(data[row + x]) }
                }
            }
        }
        inMotionSample = false
        let half = UInt32(n / 2), count = UInt32(n)
        acc.withUnsafeBufferPointer { a in
            for y in 0..<ah {
                let row = y * rb, ar = y * rowLen
                for x in 0..<rowLen { data[row + x] = UInt8((a[ar + x] + half) / count) }
            }
        }
        guard let image = off.makeImage() else { return }
        ctx.saveGState()
        ctx.setBlendMode(layer.blendMode.cgBlendMode)
        drawDeviceImage(image, rect: area, scene: scene, in: ctx)
        ctx.restoreGState()
    }

    /// Device-pixel area a layer covers over several times (with blur, shadow and glow), or nil when unknown.
    private func motionBounds(_ layer: MotionLayer, scene: MotionScene, times: [Double], copy: CGAffineTransform?) -> CGRect? {
        guard layer.type != .particles else { return nil }
        let (w, h) = pixelSize
        let toDevice = CGAffineTransform(a: Double(w) / Double(scene.width), b: 0, c: 0,
                                         d: -Double(h) / Double(scene.height), tx: 0, ty: Double(h))
        var union = CGRect.null
        for tk in times {
            guard let local = contentBounds(layer, scene: scene, at: tk) else { return nil }
            var pad = 3 * max(0, layer.value(.blur, at: tk)) + 4
            if layer.value(.shadowOpacity, at: tk) > 0.001 {
                pad += abs(layer.value(.shadowX, at: tk)) + abs(layer.value(.shadowY, at: tk)) + 2 * layer.value(.shadowBlur, at: tk)
            }
            if layer.value(.glow, at: tk) > 0.001 { pad += 3 * layer.value(.glowRadius, at: tk) }
            pad += max(0, layer.value(.outline, at: tk)) + PathOps(layer, at: tk).reach
            let m = transform(of: layer, scene: scene, at: tk, copy: copy)
            let r = local.applying(m).insetBy(dx: -pad, dy: -pad).applying(toDevice)
            union = union.union(r)
        }
        return union
    }

    private func drawLayer(_ layer: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext,
                           copy: CGAffineTransform? = nil, alphaScale: Double = 1) {
        let opacity = min(max(layer.value(.opacity, at: t), 0), 1) * alphaScale
        guard opacity > 0.001 else { return }
        var m = transform(of: layer, scene: scene, at: t, copy: copy)
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
        let blur = max(0, layer.value(.blur, at: t))
        let fx = PixelEffects(layer, at: t, fps: scene.fps)

        // The wipe clips everything the layer draws: shadow, blur and glow included.
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if wipe > 0.0001 {
            guard clipToWipe(layer, progress: wipe, scene: scene, transform: wipeTransform, at: t, copy: copy, in: ctx)
            else { return }
        }

        ctx.saveGState()
        ctx.setBlendMode(layer.blendMode.cgBlendMode)
        let shadowReach = applyShadow(layer, at: t, in: ctx)
        ctx.setAlpha(opacity)
        if blur * pixelScale > 0.25 || fx.isActive {
            // The blurred or processed layer is a device-pixel image of part of the frame: draw it 1:1 at its place.
            if let blurred = blurredLayer(layer, scene: scene, transform: m, radius: blur, fx: fx, at: t) {
                drawDeviceImage(blurred.image, rect: blurred.rect, scene: scene, in: ctx)
            }
        } else {
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
            return contentBounds(layer, scene: scene, at: t) ?? .zero
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
            ctx.setAlpha(min(left, 1) * opacity)
            drawDeviceImage(image, rect: g.rect, scene: scene, in: ctx)
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

    /// Lens flare: a bright source at `from` (default the box center) with a halo and ghost discs mirrored across
    /// the center of the box, all adding light.
    private func drawFlare(_ layer: MotionLayer, in box: CGRect, at t: Double, in ctx: CGContext) {
        let g = layer.generator
        let src = g.from.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: box.midX, y: box.midY)
        let c = CGPoint(x: box.midX, y: box.midY)
        let colors = g.colorsValue
        let core = colors.first ?? .white
        let ghost = colors.count > 1 ? colors[1] : RGBA(r: 0.6, g: 0.8, b: 1, a: 1)
        let size: Double = g.scale ?? Double(min(box.width, box.height)) * 0.25
        let strength = g.gainValue
        func radial(_ color: RGBA, at p: CGPoint, radius: Double, alpha: Double, hollow: Double = 0) {
            var a = color, b = color
            a.a = color.a * alpha; b.a = 0
            var cols: [CGColor] = [a.cgColor, b.cgColor], locs: [CGFloat] = [0, 1]
            if hollow > 0 {
                // A ring: clear inside, peaking at `hollow` of the radius, clear at the edge.
                var mid = color
                mid.a = color.a * alpha
                cols = [b.cgColor, b.cgColor, mid.cgColor, b.cgColor]
                locs = [0, CGFloat(max(0, hollow - 0.12)), CGFloat(hollow), 1]
            }
            guard let grad = CGGradient(colorsSpace: Self.colorSpace, colors: cols as CFArray, locations: locs) else { return }
            ctx.drawRadialGradient(grad, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
        }
        ctx.saveGState()
        ctx.setBlendMode(.plusLighter)
        // Core and glow.
        radial(core, at: src, radius: size * 0.35, alpha: min(1, strength))
        radial(core, at: src, radius: size * 1.6, alpha: 0.35 * strength)
        // Streak across the source.
        ctx.saveGState()
        ctx.translateBy(x: src.x, y: src.y)
        ctx.scaleBy(x: 1, y: 0.06)
        radial(core, at: .zero, radius: size * 4, alpha: 0.6 * strength)
        ctx.restoreGState()
        // Ghosts along the line through the center, on the far side.
        let salt = Noise.mix(Noise.hash("flare.\(layer.id)") ^ UInt64(bitPattern: Int64(g.seedValue)))
        let count = g.detail ?? 5
        for i in 0..<count {
            let f = -0.3 - Double(i) * (1.3 / Double(max(count, 1))) - Noise.unit(i, salt) * 0.15
            let p = CGPoint(x: c.x + (src.x - c.x) * f, y: c.y + (src.y - c.y) * f)
            let r = size * (0.15 + Noise.unit(i + 50, salt) * 0.5)
            let hollow = i % 2 == 0 ? 0.0 : 0.75
            radial(ghost, at: p, radius: r, alpha: 0.25 * strength, hollow: hollow)
        }
        // Big faint ring around the center (an anamorphic halo).
        radial(ghost, at: c, radius: hypot(src.x - c.x, src.y - c.y) + size, alpha: 0.18 * strength, hollow: 0.92)
        ctx.restoreGState()
    }

    /// `alpha`: opacity particles apply themselves (the context's alpha is replaced per particle).
    private func drawContent(_ layer: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext, alpha: Double = 1) {
        switch layer.type {
        case .rect, .ellipse, .path: drawShape(layer, at: t, in: ctx)
        case .text: drawText(layer, at: t, in: ctx)
        case .image, .video: drawImage(layer, at: t, in: ctx)
        case .particles: drawParticles(layer, alpha: alpha, in: ctx)
        case .generator: drawGenerator(layer, at: t, in: ctx)
        case .group: drawGroup(layer, scene: scene, at: t, in: ctx)
        case .audio: break
        }
    }

    /// A group's children, drawn in its box (a scene of its own: origin at the box's top-left, no camera).
    private func drawGroup(_ layer: MotionLayer, scene: MotionScene, at t: Double, in ctx: CGContext) {
        let sub = scene.subscene(of: layer, at: t)
        let w = Double(sub.width), h = Double(sub.height)
        ctx.saveGState()
        ctx.translateBy(x: -w / 2, y: -h / 2)
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h))
        let matteSources = Set(sub.layers.compactMap { l in l.matte.flatMap { $0.source == l.id ? nil : $0.source } })
        for child in sub.layers where child.type.isVisual && !matteSources.contains(child.id) {
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
        guard !area.isNull, area.width >= 1, area.height >= 1, let off = offscreen(area, scene: scene) else { return nil }
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
        Self.boxBlur(off, sigma: sigma)
        fx?.applyAfterBlur(off, center: center, scale: scale, pixelScale: pixelScale)
        if let fx, fx.shine > 0.001 { drawShine(layer, scene: scene, transform: m, strength: fx.shine, at: t, in: off) }
        guard let image = off.makeImage() else { return nil }
        return (image, area)
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
    private func contentBounds(_ layer: MotionLayer, scene: MotionScene, at t: Double) -> CGRect? {
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
        }
    }

    private func drawText(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        if layer.textPath != nil {
            drawTextOnPath(layer, at: t, in: ctx)
            return
        }
        guard let layout = textLayout(layer, at: t) else { return }
        let (bw, bh) = (layout.box.width, layout.box.height)
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
        let font = Self.font(for: layer)

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
                    drawGlyph(glyphs[g], font: runFont, at: pos, fill: fill, stroke: strokeColor, strokeWidth: strokeW,
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
        let source: (CGImage?, CGSize)?
        if layer.type == .video {
            source = layer.path.flatMap(videoFrames).map { frames in
                (layer.videoTime(at: t).flatMap { frames.image(at: $0, fps: layer.fps ?? 30) }, frames.size)
            }
        } else {
            source = layer.path.flatMap(loadImage).map { ($0.0, $0.1) }
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

    static func font(for layer: MotionLayer) -> CTFont {
        let size = CGFloat(max(layer.fontSize, 1))
        if let name = layer.fontName, let ps = FontLibrary.resolve(name, weight: layer.fontWeight) {
            return CTFontCreateWithName(ps as CFString, size, nil)
        }
        return FontLibrary.systemFont(layer.fontWeight, size: size)
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

    fileprivate func drawParticles(_ layer: MotionLayer, alpha: Double, in ctx: CGContext) {
        let sys = layer.particles
        let sprite = sys.shape == .image ? layer.path.flatMap(loadImage) : nil
        let mask = sys.shape == .image && sys.tint ? layer.path.flatMap(imageMask) : nil
        if sys.shape == .spark { ctx.setLineCap(.round) }
        for p in currentParticles {
            let a = alpha * p.color.a
            guard a > 0.002 else { continue }
            ctx.setAlpha(a)
            let color = CGColor(srgbRed: p.color.r, green: p.color.g, blue: p.color.b, alpha: 1)
            let s = p.size
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
            case .square:
                ctx.saveGState()
                ctx.translateBy(x: p.x, y: p.y)
                ctx.rotate(by: p.rotation * .pi / 180)
                ctx.scaleBy(x: 1, y: p.scaleY)
                ctx.setFillColor(color)
                ctx.fill(CGRect(x: -s / 2, y: -s / 2, width: s, height: s))
                ctx.restoreGState()
            case .spark:
                let v = hypot(p.vx, p.vy)
                let len = max(v * sys.streak, 0.01)
                let (ux, uy) = v > 1e-6 ? (p.vx / v, p.vy / v) : (0.0, -1.0)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(s)
                ctx.move(to: CGPoint(x: p.x - ux * len, y: p.y - uy * len))
                ctx.addLine(to: CGPoint(x: p.x, y: p.y))
                ctx.strokePath()
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
                   layer.align.rawValue, String(format: "%.2f", spacing)].joined(separator: "|")
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
