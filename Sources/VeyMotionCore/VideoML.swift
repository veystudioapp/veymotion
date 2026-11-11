import CoreGraphics
import CoreVideo
import Foundation
import Vision

// Vision-powered picture work on image and video layers: background removal (person or main subject), video
// stabilization (frame-to-frame registration), and slow-motion frames in between source frames (blend or optical
// flow). Vision's neural requests need the app's process (sandboxed tools lack the entitlement); every function
// falls back to the untouched picture when Vision fails.

public enum BackgroundRemoval: String, Codable, CaseIterable, Sendable {
    case person, subject
}

public enum FrameBlend: String, Codable, CaseIterable, Sendable {
    case off, blend, flow
}

public enum PictureML {
    /// Last failure message (shown by tools so agents know why nothing was cut out).
    nonisolated(unsafe) public static var lastError: String?

    /// Tries the layer's background removal on its picture (first frame for videos): nil when it works, else why not.
    public static func probe(_ layer: MotionLayer) -> String? {
        guard let mode = layer.removeBackground, let path = layer.path else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        var picture: CGImage?
        if layer.type == .video {
            if let frames = VideoFramesFactory.open(expanded) { picture = frames.image(at: layer.trimIn, fps: layer.fps ?? 30) }
        } else {
            picture = AssetStore.loadImage(URL(fileURLWithPath: expanded))?.image
        }
        guard let picture else { return "the picture could not be read" }
        return removeBackground(picture, mode: mode) == nil ? (lastError ?? "Vision failed") : nil
    }

    /// The image with everything but the person / main subject made transparent, or nil on failure.
    static func removeBackground(_ image: CGImage, mode: BackgroundRemoval) -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        var maskImage: CGImage?
        do {
            switch mode {
            case .person:
                let request = VNGeneratePersonSegmentationRequest()
                request.qualityLevel = .accurate
                request.outputPixelFormat = kCVPixelFormatType_OneComponent8
                try handler.perform([request])
                if let buffer = request.results?.first?.pixelBuffer { maskImage = grayImage(buffer) }
            case .subject:
                let request = VNGenerateForegroundInstanceMaskRequest()
                try handler.perform([request])
                if let result = request.results?.first {
                    let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
                    maskImage = grayImage(buffer)
                }
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        guard let mask = maskImage else { lastError = "Vision found nothing to keep"; return nil }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.clip(to: r, mask: mask)
        ctx.draw(image, in: r)
        lastError = nil
        return ctx.makeImage()
    }

    /// A one-channel mask (8-bit or float) as a gray CGImage.
    static func grayImage(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), rb = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h { memcpy(&bytes[y * w], base + y * rb, w) }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let row = (base + y * rb).assumingMemoryBound(to: Float.self)
                for x in 0..<w { bytes[y * w + x] = UInt8(min(max(row[x], 0), 1) * 255) }
            }
        default:
            return nil
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The frame between `a` and `b` at fraction f: a cross-fade, or both warped along the optical flow first.
    static func inBetween(_ a: CGImage, _ b: CGImage, _ f: Double, flow: Bool) -> CGImage? {
        let w = a.width, h = a.height
        guard b.width == w, b.height == h,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        if flow, let field = opticalFlow(from: a, to: b) {
            // Each output pixel takes a at p - f·flow and b at p + (1 - f)·flow, mixed by f.
            guard let ca = rgba(a), let cb = rgba(b), let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let rb = ctx.bytesPerRow
            for y in 0..<h {
                for x in 0..<w {
                    let fi = 2 * ((field.h - 1 - min(field.h - 1, y * field.h / h)) * field.w + min(field.w - 1, x * field.w / w))
                    let dx = Double(field.v[fi]) * Double(w) / Double(field.w)
                    let dy = -Double(field.v[fi + 1]) * Double(h) / Double(field.h)
                    let pa = sample(ca, w, h, Double(x) - f * dx, Double(y) - f * dy)
                    let pb = sample(cb, w, h, Double(x) + (1 - f) * dx, Double(y) + (1 - f) * dy)
                    let o = (h - 1 - y) * rb + 4 * x
                    for k in 0..<4 { data[o + k] = UInt8(min(255, pa[k] * (1 - f) + pb[k] * f + 0.5)) }
                }
            }
            return ctx.makeImage()
        }
        ctx.draw(a, in: r)
        ctx.setAlpha(f)
        ctx.draw(b, in: r)
        return ctx.makeImage()
    }

    /// Flow from a to b (pixels, x right and y up in Vision's convention), at Vision's output size.
    static func opticalFlow(from a: CGImage, to b: CGImage) -> (v: [Float], w: Int, h: Int)? {
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: b, options: [:])
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cgImage: a, options: [:])
        do { try handler.perform([request]) } catch { lastError = error.localizedDescription; return nil }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), rb = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var v = [Float](repeating: 0, count: w * h * 2)
        // Rows are stored top to bottom; keep them bottom-up to match Vision's y-up flow vectors.
        for y in 0..<h {
            let row = (base + (h - 1 - y) * rb).assumingMemoryBound(to: Float.self)
            for x in 0..<(2 * w) { v[y * 2 * w + x] = row[x] }
        }
        return (v, w, h)
    }

    /// RGBA bytes of an image, top row first.
    static func rgba(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? bytes : nil
    }

    @inline(__always)
    static func sample(_ c: [UInt8], _ w: Int, _ h: Int, _ x: Double, _ y: Double) -> [Double] {
        let xi = min(max(Int(x.rounded()), 0), w - 1), yi = min(max(Int(y.rounded()), 0), h - 1)
        let i = 4 * (yi * w + xi)
        return [Double(c[i]), Double(c[i + 1]), Double(c[i + 2]), Double(c[i + 3])]
    }
}

// MARK: - Stabilization

extension VideoTracking {
    /// Camera drift of each sampled frame relative to the first, in scene pixels (translation only), from
    /// frame-to-frame registration.
    public static func shake(layer: MotionLayer, in scene: MotionScene, from: Double, to: Double, step: Double) throws -> [Sample] {
        try License.require(.stabilize)
        guard layer.type == .video, let path = layer.path, let frames = VideoFramesFactory.open((path as NSString).expandingTildeInPath)
        else { throw SceneError.invalid("'\(layer.id)' is not a video layer with a readable source") }
        var out: [Sample] = []
        var prev: CGImage?
        var acc = CGPoint.zero
        let rect = placement(of: layer, frames: frames, at: from)
        let sx = rect.width / max(frames.size.width, 1), sy = rect.height / max(frames.size.height, 1)
        let k = layer.scale.value(at: from)
        let handler = VNSequenceRequestHandler()
        for t in times(scene: scene, layer: layer, from: from, to: to, step: step) {
            guard let vt = layer.videoTime(at: t), let image = frames.image(at: vt, fps: layer.fps ?? Double(scene.fps)) else { continue }
            if let prev {
                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: image, options: [:])
                do { try handler.perform([request], on: prev) } catch {
                    throw SceneError.invalid("Registration failed at \(t)s: \(error.localizedDescription)")
                }
                if let obs = request.results?.first as? VNImageTranslationAlignmentObservation {
                    // How far this frame's content moved since the previous one (image px, y up).
                    acc.x -= obs.alignmentTransform.tx
                    acc.y -= obs.alignmentTransform.ty
                }
            }
            prev = image
            out.append(Sample(t: t, center: CGPoint(x: acc.x * sx * k, y: -acc.y * sy * k), size: .zero, confidence: 1))
        }
        guard out.count >= 2 else { throw SceneError.invalid("Not enough frames to stabilize") }
        return out
    }
}

extension MotionScene {
    /// Moves a video layer against its camera shake: `lock` cancels all motion, `smooth` only the jitter around a
    /// smoothed path (keeps intended pans). Scales it up by `zoom` so the moving edges stay out of frame.
    public mutating func stabilize(_ id: String, drift: [VideoTracking.Sample], lock: Bool, window: Int, zoom: Double) throws {
        let smooth = VideoTracking.smoothed(drift, window: max(3, window))
        try withLayer(id) { l in
            guard l.type == .video else { throw SceneError.invalid("'\(id)' is not a video layer") }
            let t0 = drift.first?.t ?? l.start
            let x0 = l.x.value(at: t0), y0 = l.y.value(at: t0), s0 = l.scale.value(at: t0)
            var xs: [MotionKeyframe] = [], ys: [MotionKeyframe] = []
            for (d, sm) in zip(drift, smooth) {
                let ox = lock ? d.center.x : d.center.x - sm.center.x
                let oy = lock ? d.center.y : d.center.y - sm.center.y
                xs.append(MotionKeyframe(t: d.t, v: x0 - ox * zoom, easing: .linear))
                ys.append(MotionKeyframe(t: d.t, v: y0 - oy * zoom, easing: .linear))
            }
            l.motionPath = nil
            l.x = AnimValue.make(xs, fallback: x0)
            l.y = AnimValue.make(ys, fallback: y0)
            if abs(zoom - 1) > 1e-6 { l.scale = .constant(s0 * zoom) }
        }
    }
}
