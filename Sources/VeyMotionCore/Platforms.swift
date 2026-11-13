import Foundation

/// Output sizes and limits of common social video formats, for the Export sheet, `export_video` and
/// `vmotion render --preset`. Limits are guidance for warnings (platforms change them), not hard checks.
public struct PlatformPreset: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
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
        PlatformPreset(id: "tiktok", name: "TikTok", width: 1080, height: 1920,
                       maxDuration: 600, maxBytes: 4 << 30),
        PlatformPreset(id: "shorts", name: "YouTube Shorts", width: 1080, height: 1920,
                       maxDuration: 180),
        PlatformPreset(id: "reels", name: "Instagram / Facebook Reels", width: 1080, height: 1920,
                       maxDuration: 180, maxBytes: 4 << 30),
        PlatformPreset(id: "youtube", name: "YouTube", width: 1920, height: 1080),
        PlatformPreset(id: "facebook", name: "Facebook feed", width: 1080, height: 1350,
                       maxDuration: 240 * 60, maxBytes: 10 << 30),
        PlatformPreset(id: "x", name: "X (Twitter)", width: 1920, height: 1080,
                       maxDuration: 140, maxBytes: 512 << 20),
        PlatformPreset(id: "square", name: "Square post", width: 1080, height: 1080),
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

    public static func formatDuration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t)s" }
        return t % 60 == 0 ? "\(t / 60) min" : "\(t / 60)m \(t % 60)s"
    }
}

