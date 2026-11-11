import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    /// H.264 + AAC in MP4.
    case mp4
    /// ProRes 4444 (+ AAC) in MOV — keeps alpha when the background is transparent.
    case mov
    /// Audio only (AAC).
    case m4a
    /// Audio only (uncompressed PCM).
    case wav

    public static func infer(from url: URL) -> ExportFormat {
        switch url.pathExtension.lowercased() {
        case "mov": return .mov
        case "m4a": return .m4a
        case "wav": return .wav
        default: return .mp4
        }
    }

    public var fileExtension: String { rawValue }
    public var isAudioOnly: Bool { self == .m4a || self == .wav }
    /// MOV masters and WAV carry PCM; MP4/M4A carry AAC.
    var usesPCMAudio: Bool { self == .mov || self == .wav }
}

public enum ExportError: LocalizedError {
    case setup(String)
    case writing(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .setup(m): return "Export setup failed: \(m)"
        case let .writing(m): return "Export failed: \(m)"
        case .cancelled: return "Export cancelled"
        }
    }
}

/// H.264 bitrate presets (bits per pixel per frame). Ignored for ProRes and audio-only formats.
public enum ExportQuality: String, Codable, CaseIterable, Sendable {
    case low, medium, high, max

    var bitsPerPixel: Double {
        switch self {
        case .low: return 0.07
        case .medium: return 0.15
        case .high: return 0.3
        case .max: return 0.6
        }
    }
}

public struct PixelSize: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// How the scene is placed in an output frame of a different aspect ratio.
public enum ExportFit: String, Codable, CaseIterable, Sendable {
    /// Whole scene visible, bars (scene background) on the sides.
    case fit
    /// Fills the frame, cropping the scene's edges (centered).
    case fill
}

public struct ExportOptions: Sendable {
    /// nil = infer from the file extension.
    public var format: ExportFormat?
    /// Output size relative to the scene size (0.5 = half resolution). Ignored when `size` is set.
    public var scale: Double = 1
    /// Exact output size (e.g. a platform preset); the scene is fitted or cropped into it per `fit`.
    public var size: PixelSize?
    public var fit: ExportFit = .fit
    public var quality: ExportQuality = .medium
    /// Time range in scene seconds; nil = whole scene.
    public var start: Double?
    public var end: Double?

    public init(format: ExportFormat? = nil, scale: Double = 1, size: PixelSize? = nil, fit: ExportFit = .fit,
                quality: ExportQuality = .medium, start: Double? = nil, end: Double? = nil) {
        self.format = format
        self.scale = scale
        self.size = size
        self.fit = fit
        self.quality = quality
        self.start = start
        self.end = end
    }

    /// True when the output frame has a different aspect ratio than the scene (bars or cropping).
    public func isReframed(for scene: MotionScene) -> Bool {
        guard size != nil else { return false }
        let (w, h) = pixelSize(for: scene)
        let out = Double(w) / Double(h), src = Double(scene.width) / Double(max(scene.height, 1))
        return abs(out / src - 1) > 0.005
    }

    /// Where the scene lands in the output frame, in output pixels. Larger than the frame with `.fill`.
    public func contentRect(for scene: MotionScene) -> CGRect {
        let (w, h) = pixelSize(for: scene)
        guard isReframed(for: scene) else { return CGRect(x: 0, y: 0, width: w, height: h) }
        let sx = Double(w) / Double(scene.width), sy = Double(h) / Double(scene.height)
        let s = fit == .fit ? min(sx, sy) : max(sx, sy)
        let cw = (Double(scene.width) * s).rounded(), ch = (Double(scene.height) * s).rounded()
        return CGRect(x: ((Double(w) - cw) / 2).rounded(), y: ((Double(h) - ch) / 2).rounded(), width: cw, height: ch)
    }

    /// Rough H.264 file size (video bitrate + 192 kbps audio), for platform size warnings. nil for ProRes / audio.
    public func estimatedBytes(for scene: MotionScene) -> Int64? {
        guard (format ?? .mp4) == .mp4 else { return nil }
        let (w, h) = pixelSize(for: scene)
        let seconds = Double(frameRange(for: scene).count) / Double(scene.fps)
        let bps = Double(w * h * scene.fps) * quality.bitsPerPixel + (AudioMixer.hasAudio(scene) ? 192_000 : 0)
        return Int64(bps * seconds / 8)
    }

    /// Clamped frame range `[first, last)` for the scene.
    public func frameRange(for scene: MotionScene) -> Range<Int> {
        let fps = Double(scene.fps), total = scene.frameCount
        let first = min(max(0, Int(((start ?? 0) * fps).rounded())), total - 1)
        let last = min(total, max(first + 1, end.map { Int(($0 * fps).rounded()) } ?? total))
        return first..<last
    }

    /// Even pixel size of the output video.
    public func pixelSize(for scene: MotionScene) -> (width: Int, height: Int) {
        if let size { return (max(2, size.width & ~1), max(2, size.height & ~1)) }
        let s = scale > 0 ? scale : 1
        return (max(2, Int((Double(scene.width) * s).rounded()) & ~1),
                max(2, Int((Double(scene.height) * s).rounded()) & ~1))
    }
}

public enum VideoExporter {
    /// Renders every frame with `FrameRenderer`, mixes audio with `AudioMixer`, and encodes both.
    /// Blocking; call off the main thread. `isCancelled` is polled between frames/samples;
    /// a cancelled export deletes the partial file and throws `ExportError.cancelled`.
    public static func export(_ scene: MotionScene, to url: URL, format: ExportFormat? = nil,
                              progress: ((Double) -> Void)? = nil) throws {
        try export(scene, to: url, options: ExportOptions(format: format), progress: progress)
    }

    public static func export(_ scene: MotionScene, to url: URL, options: ExportOptions,
                              isCancelled: (@Sendable () -> Bool)? = nil,
                              progress: ((Double) -> Void)? = nil) throws {
        let fmt = options.format ?? ExportFormat.infer(from: url)
        // Free plan: no Pro content or ProRes, at most 1080p, with a watermark (License.prepareExport).
        var options = options
        let watermark = try License.prepareExport(scene, options: &options, format: fmt)
        let wantsVideo = !fmt.isAudioOnly
        let hasAudio = AudioMixer.hasAudio(scene)
        if !wantsVideo && !hasAudio { throw ExportError.setup("the scene has no audio layers") }
        let range = options.frameRange(for: scene)
        let fps = Double(scene.fps)
        let t0 = Double(range.lowerBound) / fps, t1 = Double(range.upperBound) / fps
        let cancelled = { isCancelled?() ?? false }

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fileType: AVFileType
        switch fmt {
        case .mov: fileType = .mov
        case .m4a: fileType = .m4a
        case .wav: fileType = .wav
        case .mp4: fileType = .mp4
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let (w, h) = options.pixelSize(for: scene) // encoders want even sizes

        // Video input
        var videoInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if wantsVideo {
            var settings: [String: Any] = [
                AVVideoCodecKey: fmt == .mov ? AVVideoCodecType.proRes4444 : AVVideoCodecType.h264,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
            ]
            if fmt == .mp4 {
                settings[AVVideoCompressionPropertiesKey] = [
                    AVVideoAverageBitRateKey: Int(Double(w * h * scene.fps) * options.quality.bitsPerPixel),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ]
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            // No source attributes: we allocate buffers ourselves instead of using the adaptor's
            // IOSurface-backed pool, which is unavailable in sandboxed/headless processes.
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            guard writer.canAdd(input) else { throw ExportError.setup("cannot add video input") }
            writer.add(input)
            videoInput = input
        }

        // Audio input: the mix is rendered in memory and fed as PCM sample buffers.
        var audioInput: AVAssetWriterInput?
        var audioSource: PCMSampleSource?
        if hasAudio {
            let source = try PCMSampleSource(AudioMixer.render(scene, from: t0, to: t1))
            audioSource = source
            let settings: [String: Any] = fmt.usesPCMAudio
                ? [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: AudioMixer.sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                : [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: AudioMixer.sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings,
                                           sourceFormatHint: source.formatDescription)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw ExportError.setup(fmt.usesPCMAudio ? "cannot add audio input"
                                                         : "the AAC audio encoder is unavailable (try .mov or .wav)")
            }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else {
            throw ExportError.setup(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // Both inputs are fed concurrently; the writer interleaves them.
        let group = DispatchGroup()
        let failure = ErrorBox()
        let total = range.count

        // A different output aspect: render the scene at its own aspect, then place it (bars or crop).
        let content = options.contentRect(for: scene)
        let reframed = options.isReframed(for: scene)
        let sceneBitmap: CGContext? = reframed
            ? CGContext(data: nil, width: Int(content.width), height: Int(content.height), bitsPerComponent: 8,
                        bytesPerRow: 0, space: FrameRenderer.colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            : nil
        if wantsVideo, reframed, sceneBitmap == nil { throw ExportError.setup("cannot allocate the reframing buffer") }

        if let videoInput, let adaptor {
            group.enter()
            let renderer = FrameRenderer()
            var frame = 0 // output frame index; scene frame = range.lowerBound + frame
            var finished = false
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "veymotion.export.video")) {
                guard !finished else { return }
                func finish(_ error: String? = nil) {
                    if let error { failure.set(error) }
                    finished = true
                    videoInput.markAsFinished()
                    group.leave()
                }
                while videoInput.isReadyForMoreMediaData {
                    if cancelled() { failure.set(Self.cancelMarker) }
                    if frame >= total || failure.isSet { return finish() }
                    var pb: CVPixelBuffer?
                    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                        [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
                    guard let buffer = pb else { return finish("cannot allocate frame \(frame)") }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    guard let ctx = CGContext(
                        data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: FrameRenderer.colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                    else {
                        CVPixelBufferUnlockBaseAddress(buffer, [])
                        return finish("cannot create bitmap context")
                    }
                    let t = Double(range.lowerBound + frame) / fps
                    if let sceneBitmap {
                        renderer.draw(scene, at: t, in: sceneBitmap, pixelWidth: sceneBitmap.width, pixelHeight: sceneBitmap.height)
                        let frameRect = CGRect(x: 0, y: 0, width: w, height: h)
                        ctx.clear(frameRect) // keeps alpha for ProRes 4444 with a transparent background
                        ctx.setFillColor(scene.background.cgColor)
                        ctx.fill(frameRect)
                        ctx.interpolationQuality = .high
                        if let image = sceneBitmap.makeImage() { ctx.draw(image, in: content) }
                    } else {
                        renderer.draw(scene, at: t, in: ctx, pixelWidth: w, pixelHeight: h)
                    }
                    if watermark { Watermark.draw(in: ctx, width: w, height: h) }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(scene.fps))
                    guard adaptor.append(buffer, withPresentationTime: time) else {
                        return finish(writer.error?.localizedDescription ?? "append failed at frame \(frame)")
                    }
                    frame += 1
                    progress?(Double(frame) / Double(total))
                }
            }
        }

        if let audioInput, let audioSource {
            group.enter()
            var finished = false
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "veymotion.export.audio")) {
                guard !finished else { return }
                func finish(_ error: String? = nil) {
                    if let error { failure.set(error) }
                    finished = true
                    audioInput.markAsFinished()
                    group.leave()
                }
                while audioInput.isReadyForMoreMediaData {
                    if cancelled() { failure.set(Self.cancelMarker) }
                    if failure.isSet { return finish() }
                    let sample: CMSampleBuffer?
                    do { sample = try audioSource.next() } catch { return finish(error.localizedDescription) }
                    guard let sample else {
                        if !wantsVideo { progress?(1) }
                        return finish()
                    }
                    if !wantsVideo { progress?(audioSource.progress) }
                    guard audioInput.append(sample) else {
                        return finish(writer.error?.localizedDescription ?? "audio append failed")
                    }
                }
            }
        }

        group.wait()
        if let msg = failure.message {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw msg == Self.cancelMarker ? ExportError.cancelled : ExportError.writing(msg)
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(total), timescale: CMTimeScale(scene.fps)))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw ExportError.writing(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    private static let cancelMarker = "\u{0}cancelled"

}

/// Slices a float stereo buffer into 16-bit interleaved PCM sample buffers for AVAssetWriter.
final class PCMSampleSource {
    let formatDescription: CMAudioFormatDescription
    private let buffer: AVAudioPCMBuffer
    private var position = 0
    private let chunk = 4096

    init(_ buffer: AVAudioPCMBuffer) throws {
        self.buffer = buffer
        var asbd = AudioStreamBasicDescription(
            mSampleRate: buffer.format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var desc: CMAudioFormatDescription?
        let st = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                formatDescriptionOut: &desc)
        guard st == noErr, let desc else { throw ExportError.setup("cannot describe audio format (\(st))") }
        formatDescription = desc
    }

    var progress: Double { Double(position) / Double(max(buffer.frameLength, 1)) }

    func next() throws -> CMSampleBuffer? {
        let total = Int(buffer.frameLength)
        guard position < total, let ch = buffer.floatChannelData else { return nil }
        let n = min(chunk, total - position)
        let channels = Int(buffer.format.channelCount)
        var pcm = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            for c in 0..<2 {
                let v = ch[min(c, channels - 1)][position + i]
                pcm[i * 2 + c] = Int16(max(-1, min(1, v)) * 32767)
            }
        }
        let bytes = n * 4
        var block: CMBlockBuffer?
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                    offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard st == noErr, let block else { throw ExportError.writing("cannot allocate audio block (\(st))") }
        st = pcm.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard st == noErr else { throw ExportError.writing("cannot fill audio block (\(st))") }
        var sample: CMSampleBuffer?
        st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription, sampleCount: n,
            presentationTimeStamp: CMTime(value: CMTimeValue(position), timescale: CMTimeScale(buffer.format.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard st == noErr, let sample else { throw ExportError.writing("cannot create audio sample (\(st))") }
        position += n
        return sample
    }
}

/// Thread-safe one-way flag, e.g. to cancel an export from the UI.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func set() { lock.lock(); value = true; lock.unlock() }
    public var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var msg: String?
    func set(_ m: String) { lock.lock(); if msg == nil { msg = m }; lock.unlock() }
    var message: String? { lock.lock(); defer { lock.unlock() }; return msg }
    var isSet: Bool { message != nil }
}
