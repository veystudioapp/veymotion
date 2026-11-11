import CoreGraphics
import Foundation
import Vision

// Vision-based analysis of video layers: following an object through the frames (motion tracking) and finding
// where the eye goes (saliency) to keep the subject framed in another aspect ratio (auto-reframe).

public enum VideoTracking {
    public struct Sample: Sendable {
        /// Scene time.
        public var t: Double
        /// Center in scene pixels (before the camera).
        public var center: CGPoint
        /// Size in scene pixels.
        public var size: CGSize
        public var confidence: Double

        public init(t: Double, center: CGPoint, size: CGSize, confidence: Double) {
            self.t = t; self.center = center; self.size = size; self.confidence = confidence
        }
    }

    /// Where a video layer's picture sits: its layer-local rect and the source's pixel size.
    static func placement(of layer: MotionLayer, frames: VideoFrames, at t: Double) -> CGRect {
        let iw = Double(frames.size.width), ih = Double(frames.size.height)
        let setW = layer.width.map { $0.value(at: t) }.flatMap { $0 > 0 ? $0 : nil }
        let setH = layer.height.map { $0.value(at: t) }.flatMap { $0 > 0 ? $0 : nil }
        var w = setW ?? iw, h = setH ?? ih
        if setW != nil && setH == nil { h = w * ih / iw }
        if setH != nil && setW == nil { w = h * iw / ih }
        return CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    }

    /// Scene times at which to analyze: every `step` seconds (at least one frame) from `from` to `to`.
    static func times(scene: MotionScene, layer: MotionLayer, from: Double, to: Double, step: Double) -> [Double] {
        let dt = max(step, 1 / Double(max(scene.fps, 1)))
        var out: [Double] = []
        var t = from
        let end = min(to, layer.effectiveEnd(sceneDuration: scene.duration))
        while t <= end + 1e-6 { out.append(t); t += dt }
        if let last = out.last, end - last > dt * 0.5 { out.append(end) }
        return out
    }

    /// Vision normalized rect (origin bottom-left) → scene pixels through the layer's transform at `t`.
    static func toScene(_ box: CGRect, layer: MotionLayer, scene: MotionScene, frames: VideoFrames, at t: Double) -> (CGPoint, CGSize) {
        let rect = placement(of: layer, frames: frames, at: t)
        let m = scene.sceneTransform(of: layer, at: t)
        let local = CGPoint(x: rect.minX + box.midX * rect.width, y: rect.minY + (1 - box.midY) * rect.height)
        let a = local.applying(m)
        let b = CGPoint(x: local.x + box.width * rect.width, y: local.y + box.height * rect.height).applying(m)
        return (a, CGSize(width: abs(b.x - a.x), height: abs(b.y - a.y)))
    }

    /// Follows the object inside `box` (scene pixels at `from`) through the video layer's frames.
    public static func track(layer: MotionLayer, in scene: MotionScene, box: CGRect, from: Double, to: Double,
                             step: Double = 0) throws -> [Sample] {
        try License.require(.motionTracking)
        guard layer.type == .video, let path = layer.path, let frames = VideoFramesFactory.open((path as NSString).expandingTildeInPath)
        else { throw SceneError.invalid("'\(layer.id)' is not a video layer with a readable source") }
        let rect = placement(of: layer, frames: frames, at: from)
        let inv = scene.sceneTransform(of: layer, at: from).inverted()
        // The box in Vision's normalized coordinates (origin bottom-left).
        let lo = CGPoint(x: box.minX, y: box.minY).applying(inv), hi = CGPoint(x: box.maxX, y: box.maxY).applying(inv)
        let u0 = (min(lo.x, hi.x) - rect.minX) / rect.width, u1 = (max(lo.x, hi.x) - rect.minX) / rect.width
        let v0 = (min(lo.y, hi.y) - rect.minY) / rect.height, v1 = (max(lo.y, hi.y) - rect.minY) / rect.height
        let start = CGRect(x: max(0, u0), y: max(0, 1 - v1), width: min(1, u1) - max(0, u0), height: min(1, v1) - max(0, v0))
        guard start.width > 0.005, start.height > 0.005 else { throw SceneError.invalid("The box must be inside the video") }
        let handler = VNSequenceRequestHandler()
        var observation = VNDetectedObjectObservation(boundingBox: start)
        var out: [Sample] = []
        var lost = 0
        for t in times(scene: scene, layer: layer, from: from, to: to, step: step) {
            guard let vt = layer.videoTime(at: t), let image = frames.image(at: vt, fps: layer.fps ?? Double(scene.fps)) else { continue }
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            do {
                try handler.perform([request], on: image)
            } catch {
                throw SceneError.invalid("Tracking failed at \(t)s: \(error.localizedDescription)")
            }
            guard let result = request.results?.first as? VNDetectedObjectObservation, result.confidence > 0.1 else {
                lost += 1
                if lost > 5 { break }
                continue
            }
            observation = result
            let (c, size) = toScene(result.boundingBox, layer: layer, scene: scene, frames: frames, at: t)
            out.append(Sample(t: t, center: c, size: size, confidence: Double(result.confidence)))
        }
        guard !out.isEmpty else { throw SceneError.invalid("Nothing could be tracked (no frames, or the object was lost at once)") }
        return out
    }

    /// Where attention goes in each sampled frame: the most salient region's center in scene pixels.
    public static func saliency(layer: MotionLayer, in scene: MotionScene, from: Double, to: Double, step: Double) throws -> [Sample] {
        try License.require(.autoReframe)
        guard layer.type == .video, let path = layer.path, let frames = VideoFramesFactory.open((path as NSString).expandingTildeInPath)
        else { throw SceneError.invalid("'\(layer.id)' is not a video layer with a readable source") }
        var out: [Sample] = []
        for t in times(scene: scene, layer: layer, from: from, to: to, step: step) {
            guard let vt = layer.videoTime(at: t), let image = frames.image(at: vt, fps: layer.fps ?? Double(scene.fps)) else { continue }
            let request = VNGenerateAttentionBasedSaliencyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) } catch {
                throw SceneError.invalid("Saliency failed at \(t)s: \(error.localizedDescription)")
            }
            guard let result = request.results?.first, let objects = result.salientObjects, !objects.isEmpty else { continue }
            // The union of the salient boxes, weighted toward the strongest.
            var box = objects[0].boundingBox
            for o in objects.dropFirst() where o.confidence > 0.5 { box = box.union(o.boundingBox) }
            let (c, size) = toScene(box, layer: layer, scene: scene, frames: frames, at: t)
            out.append(Sample(t: t, center: c, size: size, confidence: Double(objects[0].confidence)))
        }
        guard !out.isEmpty else { throw SceneError.invalid("No frames could be analyzed") }
        return out
    }

    /// Smooths a series of positions with a centered moving average over `window` samples.
    public static func smoothed(_ samples: [Sample], window: Int) -> [Sample] {
        guard window > 1, samples.count > 2 else { return samples }
        let half = window / 2
        return samples.indices.map { i in
            let lo = max(0, i - half), hi = min(samples.count - 1, i + half)
            let slice = samples[lo...hi]
            var s = samples[i]
            s.center = CGPoint(x: slice.map(\.center.x).reduce(0, +) / Double(slice.count),
                               y: slice.map(\.center.y).reduce(0, +) / Double(slice.count))
            return s
        }
    }
}

extension MotionScene {
    /// Keyframes `target`'s position (and optionally scale) to follow a tracked object in a video layer.
    /// `offset` keeps the target where it is relative to the object at the first sample.
    public mutating func attach(_ target: String, to samples: [VideoTracking.Sample], keepOffset: Bool, scale: Bool) throws {
        guard let first = samples.first else { return }
        let parent = parentTransform(of: try layer(target), at: first.t).inverted()
        try withLayer(target) { l in
            let p0 = l.position(at: first.t).point
            let dx = keepOffset ? p0.x - first.center.x : 0, dy = keepOffset ? p0.y - first.center.y : 0
            var xs: [MotionKeyframe] = [], ys: [MotionKeyframe] = [], ss: [MotionKeyframe] = []
            let s0 = l.scale.value(at: first.t)
            for s in samples {
                let p = CGPoint(x: s.center.x + dx, y: s.center.y + dy).applying(parent)
                xs.append(MotionKeyframe(t: s.t, v: p.x, easing: .linear))
                ys.append(MotionKeyframe(t: s.t, v: p.y, easing: .linear))
                if scale, first.size.width > 1 {
                    ss.append(MotionKeyframe(t: s.t, v: s0 * s.size.width / first.size.width, easing: .linear))
                }
            }
            l.motionPath = nil
            l.x = AnimValue.make(xs, fallback: p0.x)
            l.y = AnimValue.make(ys, fallback: p0.y)
            if scale, !ss.isEmpty { l.scale = AnimValue.make(ss, fallback: s0) }
        }
    }

    /// Moves a video layer over time so the salient point stays in the middle of a `targetWidth`:`targetHeight`
    /// crop of the scene (export with that size and fit "crop"), without ever showing the video's edges.
    public mutating func reframe(_ id: String, samples: [VideoTracking.Sample], targetWidth: Double, targetHeight: Double) throws {
        let w = Double(width), h = Double(height)
        // The crop window centered on the scene, in scene pixels.
        var cw = w, ch = h
        if targetWidth / targetHeight < w / h { cw = h * targetWidth / targetHeight } else { ch = w * targetHeight / targetWidth }
        let cx = w / 2, cy = h / 2
        try withLayer(id) { l in
            guard l.type == .video else { throw SceneError.invalid("'\(id)' is not a video layer") }
            let t0 = samples.first?.t ?? l.start
            let x0 = l.x.value(at: t0), y0 = l.y.value(at: t0)
            // The video's extent in scene pixels (its placed size times its scale).
            let sc = l.scale.value(at: t0)
            let vw = (l.width?.value(at: t0) ?? w) * sc * l.value(.scaleX, at: t0)
            let vh = (l.height?.value(at: t0) ?? h) * sc * l.value(.scaleY, at: t0)
            var xs: [MotionKeyframe] = [], ys: [MotionKeyframe] = []
            for s in samples {
                // Move the layer so the salient point lands on the crop center, within the limits that keep the
                // crop covered.
                var x = x0 + (cx - s.center.x), y = y0 + (cy - s.center.y)
                let xMin = cx + cw / 2 - vw / 2, xMax = cx - cw / 2 + vw / 2
                let yMin = cy + ch / 2 - vh / 2, yMax = cy - ch / 2 + vh / 2
                x = xMin <= xMax ? min(max(x, xMin), xMax) : cx
                y = yMin <= yMax ? min(max(y, yMin), yMax) : cy
                xs.append(MotionKeyframe(t: s.t, v: x, easing: .easeInOut))
                ys.append(MotionKeyframe(t: s.t, v: y, easing: .easeInOut))
            }
            l.motionPath = nil
            l.x = AnimValue.make(xs, fallback: x0)
            l.y = AnimValue.make(ys, fallback: y0)
        }
    }
}
