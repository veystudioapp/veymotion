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

    var isAudioOnly: Bool { self == .m4a || self == .wav }
    /// MOV masters and WAV carry PCM; MP4/M4A carry AAC.
    var usesPCMAudio: Bool { self == .mov || self == .wav }
}

public enum ExportError: LocalizedError {
    case setup(String)
    case writing(String)

    public var errorDescription: String? {
        switch self {
        case let .setup(m): return "Export setup failed: \(m)"
        case let .writing(m): return "Export failed: \(m)"
        }
    }
}

public enum VideoExporter {
    /// Renders every frame with `FrameRenderer`, mixes audio with `AudioMixer`, and encodes both.
    /// Blocking; call off the main thread.
    public static func export(_ scene: MotionScene, to url: URL, format: ExportFormat? = nil,
                              progress: ((Double) -> Void)? = nil) throws {
        let fmt = format ?? ExportFormat.infer(from: url)
        let wantsVideo = !fmt.isAudioOnly
        let hasAudio = AudioMixer.hasAudio(scene)
        if !wantsVideo && !hasAudio { throw ExportError.setup("the scene has no audio layers") }

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
        let w = scene.width & ~1, h = scene.height & ~1 // encoders want even sizes

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
                    AVVideoAverageBitRateKey: Int(Double(w * h * scene.fps) * 0.15),
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
            let source = try PCMSampleSource(AudioMixer.render(scene))
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
        let total = scene.frameCount

        if let videoInput, let adaptor {
            group.enter()
            let renderer = FrameRenderer()
            var frame = 0
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
                    renderer.draw(scene, at: Double(frame) / Double(scene.fps), in: ctx, pixelWidth: w, pixelHeight: h)
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
            throw ExportError.writing(msg)
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(total), timescale: CMTimeScale(scene.fps)))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw ExportError.writing(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

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

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var msg: String?
    func set(_ m: String) { lock.lock(); if msg == nil { msg = m }; lock.unlock() }
    var message: String? { lock.lock(); defer { lock.unlock() }; return msg }
    var isSet: Bool { message != nil }
}
