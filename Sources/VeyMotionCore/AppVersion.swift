import Foundation

/// The app's version. `marketing` is the one place to bump for a release: `scripts/bundle.sh` copies it into
/// Info.plist (`CFBundleShortVersionString`, with the git commit count as `CFBundleVersion`).
public enum AppVersion {
    public static let marketing = "0.1.0"

    /// Info.plist's version in the bundled app; `marketing` for `swift run` and the CLI.
    public static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? marketing
    }

    /// The build number in the bundled app (nil when not bundled).
    public static var build: String? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "0.1.0 (42)", or "0.1.0" without a build number.
    public static var display: String { build.map { "\(current) (\($0))" } ?? current }

    /// Compares dotted versions numerically ("0.10.0" > "0.9.2"); a leading "v" and any "-suffix" are ignored.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            var s = s.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            let core = s.split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
            return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than version: String = current) -> Bool {
        compare(candidate, version) == .orderedDescending
    }
}

/// The newest release, as served by `GET /api/app/latest` on the VeyMotion server (`BASE_API_URL`).
public struct AppRelease: Codable, Equatable, Sendable {
    public var version: String
    public var build: String?
    /// Release notes (Markdown).
    public var notes: String?
    /// A zip holding "Vey Motion.app".
    public var url: URL
    public var size: Int?
    /// Hex SHA-256 of the zip, when the server knows it.
    public var sha256: String?
    public var publishedAt: String?
    public var minimumSystemVersion: String?
    /// The release page, for people who want to download it themselves.
    public var pageUrl: URL?

    /// Whether this Mac's macOS can run it.
    public var supportsThisMac: Bool {
        guard let min = minimumSystemVersion, !min.isEmpty else { return true }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return AppVersion.compare("\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)", min) != .orderedAscending
    }

    /// Asks the server for the newest release. Blocking: do not call on the main thread.
    public static func latest(timeout: TimeInterval = 20) throws -> AppRelease {
        let base = VeyServer.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/api/app/latest") else { throw AssetError.failed("Invalid BASE_API_URL: \(base)") }
        let (data, response): (Data, HTTPURLResponse?)
        do {
            (data, response) = try HTTP.perform(HTTP.request(url, timeout: timeout))
        } catch {
            throw AssetError.failed("Cannot reach the update server at \(base). \(error.localizedDescription)")
        }
        guard let http = response, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw AssetError.failed(message ?? "The update server returned HTTP \(response?.statusCode ?? 0).")
        }
        do {
            var release = try JSONDecoder().decode(AppRelease.self, from: data)
            // A relative download URL (the server's own proxy) is resolved against the server.
            if release.url.scheme == nil, let abs = URL(string: base + "/" + release.url.relativeString.drop { $0 == "/" }) {
                release.url = abs
            }
            return release
        } catch {
            throw AssetError.failed("The update server sent an unreadable answer: \(error.localizedDescription)")
        }
    }
}
