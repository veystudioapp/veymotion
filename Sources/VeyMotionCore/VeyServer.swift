import Foundation

/// The VeyMotion server in `server/` (Nitro): licenses, stock video and app updates. Its address is `BASE_API_URL`.
public enum VeyServer {
    /// `BASE_API_URL` from the environment, else from a `.env` file (working directory, next to the
    /// executable, or ~/Library/Application Support/VeyMotion/.env), else http://localhost:3000.
    public static var baseURL: URL {
        let raw = ProcessInfo.processInfo.environment["BASE_API_URL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? DotEnv.value("BASE_API_URL")
            ?? "http://localhost:3000"
        let trimmed = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: trimmed) ?? URL(string: "http://localhost:3000")!
    }
}

/// Minimal `.env` reader (KEY=value lines, optional quotes, # comments) for app configuration.
enum DotEnv {
    static func value(_ key: String) -> String? {
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                var s = line.trimmingCharacters(in: .whitespaces)
                if s.hasPrefix("#") { continue }
                if s.hasPrefix("export ") { s.removeFirst(7) }
                guard let eq = s.firstIndex(of: "=") else { continue }
                guard s[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
                var v = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    private static var candidates: [URL] {
        let fm = FileManager.default
        var urls = [URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".env")]
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(exe.appendingPathComponent(".env"))
        }
        urls.append(fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VeyMotion/.env"))
        // Bundled default written by scripts/bundle.sh (Contents/Resources/.env; also found by the vmotion next to the
        // app binary). Checked last, so any .env above overrides it.
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            urls.append(exe.deletingLastPathComponent().appendingPathComponent("Resources/.env"))
        }
        return urls
    }
}
