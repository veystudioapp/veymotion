import Foundation

/// Output sizes and limits of common social video formats, for the Export sheet, `export_video` and
/// `vmotion render --preset`. Limits are guidance for warnings (platforms change them), not hard checks.
public struct PlatformPreset: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// The platform it publishes to directly, if VeyMotion can upload there.
    public var platform: SocialPlatform?
    public var width: Int
    public var height: Int
    /// Longest video the platform accepts in this format, in seconds.
    public var maxDuration: Double?
    /// Largest upload in bytes.
    public var maxBytes: Int64?
    public var maxFPS: Int = 60

    public var size: PixelSize { PixelSize(width: width, height: height) }

    /// "9:16", "16:9", "1:1", "4:5".
    public var aspectLabel: String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(width, height)
        return "\(width / g):\(height / g)"
    }

    public static let all: [PlatformPreset] = [
        PlatformPreset(id: "tiktok", name: "TikTok", platform: .tiktok, width: 1080, height: 1920,
                       maxDuration: 600, maxBytes: 4 << 30),
        PlatformPreset(id: "shorts", name: "YouTube Shorts", platform: .youtube, width: 1080, height: 1920,
                       maxDuration: 180),
        PlatformPreset(id: "reels", name: "Instagram / Facebook Reels", platform: .facebook, width: 1080, height: 1920,
                       maxDuration: 180, maxBytes: 4 << 30),
        PlatformPreset(id: "youtube", name: "YouTube", platform: .youtube, width: 1920, height: 1080),
        PlatformPreset(id: "facebook", name: "Facebook feed", platform: .facebook, width: 1080, height: 1350,
                       maxDuration: 240 * 60, maxBytes: 10 << 30),
        PlatformPreset(id: "x", name: "X (Twitter)", platform: .x, width: 1920, height: 1080,
                       maxDuration: 140, maxBytes: 512 << 20),
        PlatformPreset(id: "square", name: "Square post", platform: nil, width: 1080, height: 1080),
    ]

    public static func named(_ id: String) -> PlatformPreset? {
        all.first { $0.id == id.lowercased() }
    }

    /// Problems exporting `scene` with this preset (too long, too many fps, likely too big).
    public func warnings(for scene: MotionScene, duration: Double, estimatedBytes: Int64?) -> [String] {
        var out: [String] = []
        if let maxDuration, duration > maxDuration + 0.01 {
            out.append("\(name) accepts videos up to \(Self.formatDuration(maxDuration)); this export is \(Self.formatDuration(duration)).")
        }
        if scene.fps > maxFPS { out.append("\(name) plays at most \(maxFPS) fps; the scene is \(scene.fps) fps.") }
        if let maxBytes, let estimatedBytes, estimatedBytes > maxBytes {
            let fmt = ByteCountFormatter()
            out.append("The file will be about \(fmt.string(fromByteCount: estimatedBytes)); \(name) accepts up to \(fmt.string(fromByteCount: maxBytes)). Lower the quality.")
        }
        return out
    }

    static func formatDuration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t)s" }
        return t % 60 == 0 ? "\(t / 60) min" : "\(t / 60)m \(t % 60)s"
    }
}

/// Platforms VeyMotion can publish to (see `SocialPublisher`).
public enum SocialPlatform: String, CaseIterable, Codable, Sendable, Identifiable {
    case youtube, tiktok, facebook, x

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .youtube: return "YouTube"
        case .tiktok: return "TikTok"
        case .facebook: return "Facebook"
        case .x: return "X"
        }
    }

    /// Longest caption / title the platform accepts.
    public var titleLimit: Int {
        switch self {
        case .youtube: return 100
        case .tiktok: return 2200
        case .facebook: return 255
        case .x: return 280
        }
    }

    /// Largest upload in bytes through the API.
    public var maxBytes: Int64 {
        switch self {
        case .youtube: return 256 << 30
        case .tiktok: return 4 << 30
        case .facebook: return 10 << 30
        case .x: return 512 << 20
        }
    }

    /// Containers each API accepts (X takes MP4 only).
    public func accepts(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        switch self {
        case .x: return ext == "mp4"
        default: return ["mp4", "mov"].contains(ext)
        }
    }
}
