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
    private var imageCache: [String: (image: CGImage, size: CGSize, modified: Date?)] = [:]
    public static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {}

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

        // Farthest first; layers at the same depth keep their order in the list (all z = 0: plain list order).
        let camera = scene.camera(at: t)
        let visible = scene.layers.enumerated()
            .filter { $0.element.type.isVisual && $0.element.isVisible(at: t, sceneDuration: scene.duration) }
            .map { (index: $0.offset, layer: $0.element, depth: scene.depth(of: $0.element, at: t)) }
            .sorted { $0.depth != $1.depth ? $0.depth > $1.depth : $0.index < $1.index }
        for item in visible {
            drawLayer(item.layer, depth: item.depth, camera: camera, scene: scene, at: t, in: ctx)
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

    private func drawLayer(_ layer: MotionLayer, depth: Double, camera: CameraView, scene: MotionScene,
                           at t: Double, in ctx: CGContext) {
        let opacity = min(max(layer.value(.opacity, at: t), 0), 1)
        guard opacity > 0.001 else { return }
        guard let projection = camera.projection(depth: depth) else { return } // behind the camera
        let m = scene.worldTransform(of: layer, at: t).concatenating(projection)
        guard abs(m.a * m.d - m.b * m.c) > 1e-8 else { return } // scaled to nothing
        let blur = max(0, layer.value(.blur, at: t)) + camera.depthBlur(depth)

        ctx.saveGState()
        applyShadow(layer, at: t, in: ctx)
        ctx.setAlpha(opacity)
        if blur * pixelScale > 0.25, let img = blurredLayer(layer, scene: scene, transform: m, radius: blur, at: t) {
            // The blurred layer is a full-frame device-pixel image: draw it 1:1 over the scene.
            ctx.translateBy(x: 0, y: CGFloat(scene.height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: scene.width, height: scene.height))
        } else {
            ctx.concatenate(m)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawContent(layer, at: t, in: ctx)
            ctx.endTransparencyLayer()
        }
        ctx.restoreGState()
    }

    private func drawContent(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        switch layer.type {
        case .rect, .ellipse: drawShape(layer, at: t, in: ctx)
        case .text: drawText(layer, at: t, in: ctx)
        case .image: drawImage(layer, at: t, in: ctx)
        case .audio, .camera: break
        }
    }

    /// Drop shadow of the whole layer. Offsets are in scene pixels (y down), independent of rotation.
    private func applyShadow(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        let amount = min(max(layer.value(.shadowOpacity, at: t), 0), 1)
        guard amount > 0.001 else { return }
        var c = layer.shadowColor
        c.a *= amount
        let dx = layer.value(.shadowX, at: t) * pixelScale
        let dy = layer.value(.shadowY, at: t) * pixelScale
        ctx.setShadow(offset: CGSize(width: dx, height: -dy), blur: max(0, layer.value(.shadowBlur, at: t)) * pixelScale,
                      color: c.cgColor)
    }

    /// Renders the layer alone into a frame-sized bitmap and applies a gaussian blur (radius in scene pixels).
    private func blurredLayer(_ layer: MotionLayer, scene: MotionScene, transform m: CGAffineTransform,
                              radius: Double, at t: Double) -> CGImage? {
        let (w, h) = pixelSize
        guard w > 0, h > 0, let off = Self.bitmap(w, h) else { return nil }
        off.setShouldAntialias(true)
        off.interpolationQuality = .high
        Self.applySceneSpace(off, scene: scene, pixelWidth: w, pixelHeight: h)
        off.concatenate(m)
        drawContent(layer, at: t, in: off)
        Self.boxBlur(off, sigma: radius * pixelScale / 2)
        return off.makeImage()
    }

    /// Gaussian blur approximated by three box blurs (vImage, CPU, deterministic). Works on premultiplied pixels.
    private static func boxBlur(_ ctx: CGContext, sigma: Double) {
        guard sigma > 0.1, let data = ctx.data else { return }
        var size = Int((12 * sigma * sigma / 3 + 1).squareRoot().rounded())
        if size % 2 == 0 { size += 1 }
        guard size >= 3 else { return }
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
        let w = max(layer.shapeWidth(at: t), 0), h = max(layer.shapeHeight(at: t), 0)
        guard w > 0, h > 0 else { return }
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        let path: CGPath
        let length: Double
        if layer.type == .ellipse {
            path = CGPath(ellipseIn: rect, transform: nil)
            let a = w / 2, b = h / 2 // Ramanujan's perimeter approximation
            length = .pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot())
        } else {
            let r = max(0, min(layer.value(.cornerRadius, at: t), w / 2, h / 2))
            path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
            length = 2 * (w + h) - (8 - 2 * .pi) * r
        }
        if let fill = layer.color(.fill, at: t), fill.a > 0 {
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        let lineWidth = layer.value(.strokeWidth, at: t)
        let trim = min(max(layer.value(.trim, at: t), 0), 1)
        if let stroke = layer.color(.stroke, at: t), lineWidth > 0, trim > 0.0005 {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(lineWidth)
            if trim < 0.9995 {
                ctx.setLineCap(.round)
                ctx.setLineDash(phase: 0, lengths: [length * trim, length * 2])
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func drawText(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        let full = layer.text
        guard !full.isEmpty else { return }
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

        ctx.saveGState()
        // Local y-up space with origin at the text box's bottom-left.
        ctx.translateBy(x: -bw / 2, y: bh / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: bw, height: bh), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        if animated {
            drawAnimatedGlyphs(frame, layer: layer, shownUTF16: shownUTF16, at: t, in: ctx)
        } else {
            CTFrameDraw(frame, ctx)
        }
        ctx.restoreGState()
    }

    /// Draws each glyph with the transform/opacity of its character, word or line (text animators).
    private func drawAnimatedGlyphs(_ frame: CTFrame, layer: MotionLayer, shownUTF16: Int, at t: Double, in ctx: CGContext) {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        let charMap = TextUnits.map(layer.text, unit: .char)
        let wordMap = TextUnits.map(layer.text, unit: .word)
        let charStates = layer.glyphStates(unit: .char, count: charMap.count, at: t)
        let wordStates = layer.glyphStates(unit: .word, count: wordMap.count, at: t)
        let lineStates = layer.glyphStates(unit: .line, count: lines.count, at: t)

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
                    ctx.setFillColor(color)
                    // Local space is y-up here, so a positive (downward) dy moves the glyph down.
                    ctx.translateBy(x: pivotX + st.dx, y: midY - st.dy)
                    ctx.rotate(by: -st.rotation * .pi / 180)
                    ctx.scaleBy(x: st.scale, y: st.scale)
                    ctx.translateBy(x: -pivotX, y: -midY)
                    var glyph = glyphs[g]
                    var pos = CGPoint(x: origin.x + positions[g].x, y: origin.y + positions[g].y)
                    CTFontDrawGlyphs(runFont, &glyph, &pos, 1, ctx)
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
    }

    private func drawImage(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        guard let path = layer.path, let loaded = loadImage(path) else {
            drawPlaceholder(layer, at: t, in: ctx)
            return
        }
        let (img, natural) = loaded
        let iw = Double(natural.width), ih = Double(natural.height)
        let setW = layer.width.map { $0.value(at: t) }.flatMap { $0 > 0 ? $0 : nil }
        let setH = layer.height.map { $0.value(at: t) }.flatMap { $0 > 0 ? $0 : nil }
        var w = setW ?? iw, h = setH ?? ih
        if setW != nil && setH == nil { h = w * ih / iw }
        if setH != nil && setW == nil { w = h * iw / ih }
        ctx.saveGState()
        ctx.translateBy(x: -w / 2, y: h / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    private func drawPlaceholder(_ layer: MotionLayer, at t: Double, in ctx: CGContext) {
        let w = layer.width.map { $0.value(at: t) }.flatMap { $0 > 0 ? $0 : nil } ?? 400
        let h = layer.height.map { $0.value(at: t) }.flatMap { $0 > 0 ? $0 : nil } ?? 240
        let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        ctx.setFillColor(RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.25).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(RGBA(r: 1, g: 0.3, b: 0.3).cgColor)
        ctx.setLineWidth(4)
        ctx.stroke(rect)
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.move(to: CGPoint(x: rect.maxX, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.strokePath()
    }

    private func loadImage(_ path: String) -> (CGImage, CGSize)? {
        let expanded = (path as NSString).expandingTildeInPath
        // Keyed by modification date too, so a file that is overwritten (e.g. by write_asset) reloads.
        let modified = (try? FileManager.default.attributesOfItem(atPath: expanded))?[.modificationDate] as? Date
        if let cached = imageCache[expanded], cached.modified == modified { return (cached.image, cached.size) }
        guard let loaded = AssetStore.loadImage(URL(fileURLWithPath: expanded)) else { return nil }
        imageCache[expanded] = (loaded.image, loaded.size, modified)
        return (loaded.image, loaded.size)
    }

    static func font(for layer: MotionLayer) -> CTFont {
        let size = CGFloat(max(layer.fontSize, 1))
        if let name = layer.fontName, let f = NSFont(name: name, size: size) { return f }
        let weight: NSFont.Weight
        switch layer.fontWeight.lowercased() {
        case "ultralight": weight = .ultraLight
        case "thin": weight = .thin
        case "light": weight = .light
        case "regular", "normal": weight = .regular
        case "medium": weight = .medium
        case "semibold": weight = .semibold
        case "heavy": weight = .heavy
        case "black": weight = .black
        default: weight = .bold
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
}
