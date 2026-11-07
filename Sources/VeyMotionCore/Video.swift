import AVFoundation
import CoreGraphics
import Foundation

/// What a video layer does once its source has played to the end.
public enum VideoPlayback: String, Codable, CaseIterable, Sendable {
    /// The layer ends with the source (like an audio layer).
    case once
    /// The last frame stays until the layer ends.
    case hold
    /// The source starts over (turntables, cycles).
    case loop
}

/// Sources of a video layer: a movie file (.mov/.mp4/.m4v, ProRes 4444 keeps alpha) or a folder of numbered images
/// (an image sequence such as a Blender render, sorted by file name; PNG keeps alpha).
public enum VideoSource {
    static let sequenceExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "exr", "webp", "heic", "bmp", "tga"]

    public struct Info: Sendable {
        /// Seconds (movies) — nil for image sequences, whose length depends on the layer's fps.
        public var duration: Double?
        /// Number of images (image sequences).
        public var frameCount: Int?
        public var width: Int
        public var height: Int
    }

    public static func isSequence(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: expand(path), isDirectory: &dir) && dir.boolValue
    }

    /// The images of a sequence folder in frame order (natural sort, so frame2 comes before frame10).
    public static func sequenceFiles(_ path: String) -> [URL] {
        let dir = URL(fileURLWithPath: expand(path), isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return files.filter { sequenceExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func info(of path: String) throws -> Info {
        let p = expand(path)
        guard FileManager.default.fileExists(atPath: p) else { throw SceneError.invalid("File not found: \(path)") }
        if isSequence(p) {
            let files = sequenceFiles(p)
            guard let first = files.first else { throw SceneError.invalid("No images (png, jpg, tiff, exr…) in folder \(path)") }
            guard let img = AssetStore.loadImage(first) else { throw SceneError.invalid("Cannot read \(first.path)") }
            return Info(duration: nil, frameCount: files.count, width: Int(img.size.width), height: Int(img.size.height))
        }
        let movie = try MovieInfo.load(URL(fileURLWithPath: p))
        return Info(duration: movie.duration, frameCount: nil,
                    width: Int(movie.displaySize.width.rounded()), height: Int(movie.displaySize.height.rounded()))
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

extension MotionLayer {
    /// Seconds into the source shown at scene time t (after trimIn, speed and playback), or nil if nothing is shown.
    public func videoTime(at t: Double) -> Double? {
        guard type == .video else { return nil }
        if timeRemap != nil {
            // Keyframed source time: hold before the first key, after the last, and clamp to the clip.
            var s = max(0, value(.timeRemap, at: t))
            if let total = sourceDuration, total > 0 { s = min(s, max(0, total - 1e-4)) }
            return s
        }
        var s = trimIn + max(0, t - start) * speed
        guard let total = sourceDuration, total > 0 else { return s }
        let lastFrame = max(0, total - 1e-4)
        switch playback {
        case .once, .hold:
            s = min(s, lastFrame)
        case .loop:
            let span = total - trimIn
            if span > 1e-6 && s >= total { s = trimIn + (s - trimIn).truncatingRemainder(dividingBy: span) }
            s = min(s, lastFrame)
        }
        return s
    }

    /// Reads the source length (and gives an image sequence the scene fps when it has none).
    public mutating func loadVideoInfo(sceneFps: Int) throws {
        guard type == .video, let path else { return }
        let info = try VideoSource.info(of: path)
        if let n = info.frameCount {
            if fps == nil { fps = Double(sceneFps) }
            sourceDuration = Double(n) / max(fps ?? Double(sceneFps), 1)
        } else {
            sourceDuration = info.duration
        }
    }
}

// MARK: - Decoding (used by FrameRenderer, one instance per renderer)

/// Gives the frame of a video source at a time. Not thread-safe (owned by one FrameRenderer).
protocol VideoFrames: AnyObject {
    var size: CGSize { get }
    /// Seconds per source frame for movies (sequences use the layer's fps).
    var frameDuration: Double? { get }
    func image(at seconds: Double, fps: Double) -> CGImage?
}

extension SequenceFrames { var frameDuration: Double? { nil } }
extension MovieFrames { var frameDuration: Double? { info.frameDuration } }

enum VideoFramesFactory {
    static func open(_ path: String) -> VideoFrames? {
        VideoSource.isSequence(path) ? SequenceFrames(path: path) : MovieFrames(url: URL(fileURLWithPath: VideoSource.expand(path)))
    }
}

/// A folder of images; frame i is shown from i/fps to (i+1)/fps.
final class SequenceFrames: VideoFrames {
    let files: [URL]
    let size: CGSize
    private var cached: (index: Int, image: CGImage)?

    init?(path: String) {
        files = VideoSource.sequenceFiles(path)
        guard let first = files.first, let img = AssetStore.loadImage(first) else { return nil }
        size = img.size
        cached = (0, img.image)
    }

    func image(at seconds: Double, fps: Double) -> CGImage? {
        let i = min(max(Int((seconds * fps + 1e-6).rounded(.down)), 0), files.count - 1)
        if let cached, cached.index == i { return cached.image }
        guard let img = AssetStore.loadImage(files[i]) else { return cached?.image }
        cached = (i, img.image)
        return img.image
    }
}

struct MovieInfo: @unchecked Sendable {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let duration: Double
    let naturalSize: CGSize
    let transform: CGAffineTransform
    let frameDuration: Double

    var displaySize: CGSize {
        let r = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    static func load(_ url: URL) throws -> MovieInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        return try blocking {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw SceneError.invalid("No video track in \(url.lastPathComponent)")
            }
            let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let duration = try await asset.load(.duration).seconds
            return MovieInfo(asset: asset, track: track, duration: duration.isFinite ? duration : 0,
                             naturalSize: size, transform: transform, frameDuration: 1 / Double(max(rate, 1)))
        }
    }
}

/// Decodes a movie with AVAssetReader, reading forward while the requested times move forward (export, playback)
/// and restarting the reader at the new time on a seek (scrubbing).
final class MovieFrames: VideoFrames {
    fileprivate let info: MovieInfo
    var size: CGSize { info.displaySize }
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// Latest decoded frame at or before the last requested time, and the one after it (read ahead).
    private var current: (pts: Double, image: CGImage)?
    private var next: (pts: Double, image: CGImage)?

    init?(url: URL) {
        guard let info = try? MovieInfo.load(url) else { return nil }
        self.info = info
    }

    func image(at seconds: Double, fps: Double) -> CGImage? {
        let t = seconds
        // Seek when going back, or jumping far ahead (cheaper than decoding everything in between).
        let needsSeek = reader == nil || current.map { t < $0.pts - 1e-6 || t > $0.pts + 2 } ?? true
        if needsSeek { seek(to: t) }
        while true {
            if next == nil { next = readFrame() }
            guard let n = next, n.pts <= t + 1e-6 else { break }
            current = n
            next = nil
        }
        return current?.image ?? next?.image
    }

    private func seek(to t: Double) {
        reader?.cancelReading()
        reader = nil; output = nil; current = nil; next = nil
        guard let r = try? AVAssetReader(asset: info.asset) else { return }
        let o = AVAssetReaderTrackOutput(track: info.track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { return }
        r.add(o)
        // Start a little early so the frame showing at t (which began before t) is included.
        let from = max(0, t - 2 * info.frameDuration)
        r.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), duration: .positiveInfinity)
        guard r.startReading() else { return }
        reader = r; output = o
    }

    private func readFrame() -> (pts: Double, image: CGImage)? {
        guard let output, reader?.status == .reading else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let image = makeImage(buffer) else { continue }
            return (pts, image)
        }
        return nil
    }

    private func makeImage(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        // Premultiplied BGRA: what the exporter writes, so a ProRes 4444 render round-trips with its alpha.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // Copy the pixels: the decoder reuses its buffers once the sample is released.
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let provider = CGDataProvider(data: Data(bytes: base, count: rowBytes * h) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: FrameRenderer.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let m = info.transform
        guard !m.isIdentity else { return image }
        // Rotated recordings (phones): draw upright.
        let size = info.displaySize
        guard let dst = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: FrameRenderer.colorSpace, bitmapInfo: bitmapInfo) else { return image }
        // preferredTransform is in y-down video space; CG is y-up, so flip around it.
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        let natFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: info.naturalSize.height)
        let bounds = CGRect(origin: .zero, size: info.naturalSize).applying(m)
        let place = m.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        dst.concatenate(natFlip.concatenating(place).concatenating(flip))
        dst.draw(image, in: CGRect(origin: .zero, size: info.naturalSize))
        return dst.makeImage() ?? image
    }
}

/// Runs async work from synchronous code (renderer, scene ops). Not to be called from the cooperative pool.
private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

func blocking<T>(_ op: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await op()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}
