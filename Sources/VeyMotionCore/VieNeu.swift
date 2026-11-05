import Foundation

/// Vietnamese text-to-speech with VieNeu (https://vieneu.io), through the VeyMotion server in `server/`
/// (`/api/tts/*`), which holds the VieNeu API key. The server address is `BASE_API_URL`.
public enum VieNeu {
    public struct Voice: Codable, Sendable, Hashable {
        public var id: String
        public var name: String?
        public var description: String?
        public var gender: String?
        public var region: String?
        public var kind: String?

        /// "Ngọc Lan — Nữ · Bắc · …" style label for pickers and tool output.
        public var label: String {
            let d = description ?? [gender, region].compactMap { $0 }.joined(separator: ", ")
            return d.isEmpty ? id : "\(id) — \(d)"
        }
    }

    /// Text longer than this goes through an async job (`/api/tts/jobs`) instead of `/api/tts/speech`.
    static let syncLimit = 1500

    // MARK: Configuration

    /// `BASE_API_URL` from the environment, else from a `.env` file (working directory, next to the
    /// executable, or ~/Library/Application Support/VeyMotion/.env), else http://localhost:3000.
    public static var baseURL: URL {
        let raw = ProcessInfo.processInfo.environment["BASE_API_URL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? DotEnv.value("BASE_API_URL")
            ?? "http://localhost:3000"
        let trimmed = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: trimmed) ?? URL(string: "http://localhost:3000")!
    }

    // MARK: Voices

    nonisolated(unsafe) private static var cachedVoices: [Voice]?
    private static let cacheLock = NSLock()

    /// The VieNeu voice catalogue (cached after the first successful call). Blocking; not on the main thread.
    public static func voices(refresh: Bool = false) throws -> [Voice] {
        cacheLock.lock()
        if !refresh, let v = cachedVoices { cacheLock.unlock(); return v }
        cacheLock.unlock()

        struct List: Decodable { var voices: [Voice]; var error: String? }
        let data = try call("GET", "/api/tts/voices", timeout: 20)
        let list = try JSONDecoder().decode(List.self, from: data)
        if list.voices.isEmpty, let e = list.error { throw AudioError.failed("VieNeu voice list unavailable: \(e)") }
        cacheLock.lock(); cachedVoices = list.voices; cacheLock.unlock()
        return list.voices
    }

    // MARK: Synthesis

    /// Synthesizes `text` into a new file in `folder` of the asset library. `speed` is 0.5–2 (1 = normal).
    /// VieNeu returns no word timings, so they are estimated from the text (`exactTimings` = false).
    /// Blocking; call off the main thread.
    public static func synthesize(_ text: String, voice: String? = nil, speed: Double = 1,
                                  folder: String? = nil) throws -> VoiceResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AudioError.failed("text is empty") }
        let speed = min(max(speed, 0.5), 2)
        let voice = voice.flatMap { $0.isEmpty ? nil : $0 }

        let url: URL
        if trimmed.count <= syncLimit {
            // WAV decodes everywhere (MP3 cannot be decoded in sandboxed processes); 24 kHz keeps files small.
            var body: [String: Any] = ["text": trimmed, "format": "wav", "sampleRate": 24000, "speed": speed]
            if let voice { body["voice"] = voice }
            let audio = try call("POST", "/api/tts/speech", json: body, timeout: 60 + Double(trimmed.count) * 0.1)
            guard !audio.isEmpty else { throw AudioError.failed("VieNeu returned no audio") }
            url = try AssetStore.newFile(prefix: "voice", ext: "wav", folder: folder)
            try audio.write(to: url)
        } else {
            url = try synthesizeJob(trimmed, voice: voice, speed: speed, folder: folder)
        }

        let duration: Double
        do {
            duration = try AudioFileInfo.duration(of: url.path)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw AudioError.failed("VieNeu audio could not be read (\(url.lastPathComponent))")
        }
        return VoiceResult(url: url, duration: duration,
                           words: VoiceSynth.estimateTimings(trimmed, duration: duration), exactTimings: false)
    }

    /// Long text: submit a job, poll until it completes, then download the audio.
    private static func synthesizeJob(_ text: String, voice: String?, speed: Double, folder: String?) throws -> URL {
        var body: [String: Any] = ["text": text, "speed": speed]
        if let voice { body["voiceId"] = voice }
        let idempotencyKey = UUID().uuidString
        var job = try jsonObject(call("POST", "/api/tts/jobs", json: body,
                                      headers: ["Idempotency-Key": idempotencyKey], timeout: 60))
        guard let jobId = job["jobId"] as? String else { throw AudioError.failed("VieNeu did not return a job id") }

        let deadline = Date().addingTimeInterval(120 + Double(text.count) * 0.05)
        while (job["status"] as? String) != "completed" {
            switch job["status"] as? String {
            case "failed":
                throw AudioError.failed("VieNeu job failed: \(job["error"] as? String ?? "unknown error")")
            case "queued", "processing", nil:
                break
            case let other?:
                throw AudioError.failed("VieNeu job has unexpected status '\(other)'")
            }
            guard Date() < deadline else { throw AudioError.failed("VieNeu job \(jobId) did not finish in time") }
            Thread.sleep(forTimeInterval: 1.5)
            job = try jsonObject(call("GET", "/api/tts/jobs/\(jobId)", timeout: 30))
        }

        guard let s = job["audioUrl"] as? String, let audioURL = URL(string: s) else {
            throw AudioError.failed("VieNeu job finished without an audio URL")
        }
        let data = try HTTP.get(audioURL, timeout: 120)
        let ext = ["mp3", "wav", "opus", "ogg", "m4a"].contains(audioURL.pathExtension.lowercased())
            ? audioURL.pathExtension.lowercased() : "mp3"
        let url = try AssetStore.newFile(prefix: "voice", ext: ext, folder: folder)
        try data.write(to: url)
        return url
    }

    // MARK: HTTP

    private static func call(_ method: String, _ path: String, json: [String: Any]? = nil,
                             headers: [String: String] = [:], timeout: TimeInterval) throws -> Data {
        let base = baseURL
        guard let url = URL(string: base.absoluteString + path) else { throw AudioError.failed("Invalid BASE_API_URL: \(base)") }
        var req = HTTP.request(url, timeout: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let result: (data: Data, response: HTTPURLResponse?)
        do {
            result = try HTTP.perform(req)
        } catch {
            throw AudioError.failed("Cannot reach the VeyMotion TTS server at \(base.absoluteString) "
                + "(start it with `cd server && bun run dev`, or set BASE_API_URL). \(error.localizedDescription)")
        }
        let status = result.response?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AudioError.failed("VieNeu TTS failed (HTTP \(status)): \(errorMessage(result.data))")
        }
        return result.data
    }

    /// The server returns `{ status, message, data: { code, traceId } }` on errors.
    private static func errorMessage(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8) ?? "no details"
        }
        var msg = obj["message"] as? String ?? "no details"
        if let trace = (obj["data"] as? [String: Any])?["traceId"] as? String { msg += " (trace \(trace))" }
        return msg
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioError.failed("Unexpected response from the TTS server")
        }
        return obj
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
        return urls
    }
}
