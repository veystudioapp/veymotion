import CoreGraphics
import Foundation
import Lottie
import QuartzCore

/// Lottie animations (Bodymovin .json exported from After Effects, or .lottie archives) as the source of a video
/// layer, so trimIn, speed, playback, timeRemap and the timeline work on them as on a movie.
///
/// Drawn by lottie-ios's main-thread engine, whose layers draw themselves with CoreGraphics: `CALayer.render(in:)`
/// then draws a frame offscreen on any thread, as vectors. Two things make it match lottie-ios's own snapshots:
/// the root layer is geometry-flipped and the context is y-down (flipping only the context turns images and text
/// upside down), and `LottieAnimationLayer` alone does not center its animation layer (the view does), so `LottieFrames`
/// does. Not supported by `render(in:)`: Lottie drop-shadow effects (cut to boxes).
public enum LottieSource {
    public static let fileExtensions: Set<String> = ["json", "lottie"]

    /// A .lottie archive, or a .json file that looks like a Lottie animation: the in/out point keys plus the frame
    /// rate, layers or assets key, looked for at both ends of the file (exporters that sort keys put `assets`, often
    /// megabytes of base64 images, first).
    public static func isLottie(_ path: String) -> Bool {
        let p = VideoSource.expand(path)
        switch (p as NSString).pathExtension.lowercased() {
        case "lottie": return FileManager.default.fileExists(atPath: p)
        case "json": break
        default: return false
        }
        guard let h = FileHandle(forReadingAtPath: p) else { return false }
        defer { try? h.close() }
        let window = 65536
        guard var data = try? h.read(upToCount: window) else { return false }
        if data.count == window, let end = try? h.seekToEnd(), end > UInt64(window * 2) {
            try? h.seek(toOffset: end - UInt64(window))
            data.append((try? h.read(upToCount: window)) ?? Data())
        }
        let s = String(decoding: data, as: UTF8.self)
        guard s.drop(while: \.isWhitespace).first == "{" else { return false }
        func has(_ key: String) -> Bool { s.range(of: "\"\(key)\"\\s*:", options: .regularExpression) != nil }
        return has("ip") && has("op") && (has("fr") || has("layers") || has("assets"))
    }

    public static func info(of path: String) throws -> VideoSource.Info {
        guard let loaded = load(path) else { throw SceneError.invalid("Cannot read the Lottie animation \(path)") }
        let b = loaded.animation.bounds
        return VideoSource.Info(duration: loaded.animation.duration, frameCount: nil,
                                width: Int(b.width.rounded()), height: Int(b.height.rounded()))
    }

    /// A picture of the animation halfway through, at most `maxPixels` on its longer side (asset thumbnails).
    public static func thumbnail(_ path: String, maxPixels: Int) -> CGImage? {
        guard let frames = LottieFrames(path: path) else { return nil }
        let k = Double(maxPixels) / max(frames.size.width, frames.size.height, 1)
        return frames.image(at: frames.duration / 2, scale: min(k, 4))
    }

    struct Loaded {
        let animation: LottieAnimation
        let images: AnimationImageProvider
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (modified: Double?, loaded: Loaded?)] = [:]

    /// The parsed animation, shared by every renderer (each builds its own layers from it) and reloaded when the
    /// file changes.
    static func load(_ path: String) -> Loaded? {
        _ = quietLogs
        let p = VideoSource.expand(path)
        var info = stat()
        let modified = stat(p, &info) == 0 ? Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9 : nil
        lock.lock()
        if let hit = cache[p], hit.modified == modified { lock.unlock(); return hit.loaded }
        lock.unlock()
        var loaded: Loaded?
        let url = URL(fileURLWithPath: p)
        let folder = url.deletingLastPathComponent()
        if modified == nil {
            loaded = nil
        } else if url.pathExtension.lowercased() == "lottie" {
            // Unzipped into the system temp folder by lottie-ios (so not in sandboxed processes).
            if case .success(let file) = DotLottieFile.SynchronouslyBlockingCurrentThread.loadedFrom(filepath: p, dotLottieCache: nil),
               let first = file.animations.first {
                loaded = Loaded(animation: first.animation,
                                images: first.configuration.imageProvider ?? FilepathImageProvider(filepath: folder))
            }
        } else if let data = try? Data(contentsOf: url), let animation = try? LottieAnimation.from(data: data) {
            // External images (`u`/`p` in assets) are looked up next to the file.
            loaded = Loaded(animation: animation, images: FilepathImageProvider(filepath: folder))
        }
        lock.lock()
        cache[p] = (modified, loaded)
        lock.unlock()
        return loaded
    }

    /// lottie-ios asserts (crashing debug builds) when a .lottie is loaded on the main thread, and prints warnings.
    private static let quietLogs: Void = {
        LottieLogger.shared = LottieLogger(assert: { _, _, _, _ in }, assertionFailure: { _, _, _ in },
                                           warn: { _, _, _ in }, info: { _ in })
    }()
}

/// One renderer's instance of a Lottie animation (its own layer tree: not thread-safe, like the other `VideoFrames`).
final class LottieFrames: VideoFrames {
    private let animation: LottieAnimation
    private let layer: LottieAnimationLayer

    var size: CGSize { animation.bounds.size }
    var frameDuration: Double? { 1 / max(animation.framerate, 1) }
    var duration: Double { animation.duration }

    init?(path: String) {
        guard let loaded = LottieSource.load(path) else { return nil }
        animation = loaded.animation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer = LottieAnimationLayer(animation: loaded.animation, imageProvider: loaded.images,
                                     configuration: LottieConfiguration(renderingEngine: .mainThread))
        let b = loaded.animation.bounds
        layer.frame = b
        layer.isGeometryFlipped = true
        layer.sublayers?.first?.position = CGPoint(x: b.midX, y: b.midY)
        CATransaction.commit()
    }

    /// Draws the frame `seconds` into the animation into `rect` of a y-down context (stretched to it), as vectors.
    func draw(at seconds: Double, in rect: CGRect, of ctx: CGContext) {
        let b = animation.bounds
        guard b.width > 0, b.height > 0, rect.width > 0, rect.height > 0 else { return }
        let sx = rect.width / b.width, sy = rect.height / b.height
        // Device pixels per animation unit: what images and text inside the animation are rasterized at.
        let m = ctx.ctm
        let scale = min(max(sqrt(abs(m.a * m.d - m.b * m.c)) * max(sx, sy), 0.25), 8)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if abs(layer.screenScale - scale) > 0.05 * scale { layer.screenScale = scale }
        let frame = animation.startFrame + seconds * animation.framerate
        layer.currentFrame = min(max(frame, animation.startFrame), animation.endFrame)
        layer.forceDisplayUpdate()
        CATransaction.commit()
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: sx, y: sy)
        layer.render(in: ctx)
        ctx.restoreGState()
    }

    /// The frame as a bitmap at `scale` × the animation's size (tracking, background removal, frame blending).
    func image(at seconds: Double, scale: Double) -> CGImage? {
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: Double(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(at: seconds, in: CGRect(x: 0, y: 0, width: w, height: h), of: ctx)
        return ctx.makeImage()
    }

    func image(at seconds: Double, fps: Double) -> CGImage? { image(at: seconds, scale: 1) }
}
