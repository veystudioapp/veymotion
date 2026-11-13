import Foundation
import VeyMotionCore

/// Events emitted by `ClaudeCodeAgent`, decoded from Claude Code's stream-json output.
public enum AgentEvent {
    case started(sessionId: String, model: String)
    case thinking
    /// Streaming text for an assistant message.
    case textDelta(messageId: String, text: String)
    /// A complete text block (only sent when it was not already streamed).
    case text(messageId: String, text: String)
    /// The model is streaming a tool call's input (can take a while for large commands).
    case toolInputProgress(name: String, bytes: Int)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(toolUseId: String, output: String, isError: Bool, image: Data?)
    case turnFinished(isError: Bool, result: String?, costUSD: Double?, durationMs: Int?)
    case stderr(String)
    /// The saved session could not be resumed (sent before `exited`); the chat starts a fresh one.
    case resumeFailed
    case exited(code: Int32)
}

/// The coding-agent CLIs the chat can run.
public enum AgentProvider: String, CaseIterable, Codable {
    case claude, codex

    public var displayName: String { self == .claude ? "Claude" : "Codex" }
    /// The CLI's name, for setup and error messages.
    public var cliName: String { self == .claude ? "Claude Code" : "Codex CLI" }
}

/// A chat agent backed by a CLI (`ClaudeCodeAgent`, `CodexAgent`). Events arrive on a background queue.
public protocol ChatAgent: AnyObject {
    var onEvent: ((AgentEvent) -> Void)? { get set }
    /// The session the next `send` continues (nil = a new one).
    var sessionId: String? { get }
    var isRunning: Bool { get }
    func send(_ text: String, images: [ClaudeCodeAgent.ImageAttachment]) throws
    /// Interrupts the current turn. The session can be resumed.
    func stop()
    /// Forgets the session; the next `send` starts a fresh conversation.
    func reset()
}

extension ClaudeCodeAgent: ChatAgent {}

public enum AgentCLI {
    /// Added to every `claude` process's environment (e.g. the user's `ANTHROPIC_API_KEY`). Read from any thread.
    public static var extraEnvironment: [String: String] {
        get { envLock.lock(); defer { envLock.unlock() }; return _extraEnvironment }
        set { envLock.lock(); _extraEnvironment = newValue; envLock.unlock() }
    }
    private static var _extraEnvironment: [String: String] = [:]
    private static let envLock = NSLock()

    /// Finds an executable: `$envVar`, `candidates`, PATH, then a login shell (`command -v`).
    /// `$envVar=none` acts as if it were not installed (to test the setup screens).
    public static func locate(_ name: String, envVar: String, candidates: [String]) -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if env[envVar] == "none" { return nil }
        if let p = env[envVar], fm.isExecutableFile(atPath: p) { return p }
        let all = candidates + (env["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        if let found = all.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// PATH for a CLI child process: `first` folders, the inherited PATH, then Homebrew's.
    static func path(first: [String]) -> String {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return (first + [base, "/opt/homebrew/bin", "/usr/local/bin"]).joined(separator: ":")
    }
}

/// Runs Claude Code headless (`claude -p` with stream-json in/out), restricted to the `vmotion`
/// CLI and Read. The process stays alive across turns; `stop()` kills it and the next `send`
/// resumes the same session.
public final class ClaudeCodeAgent {
    public struct Config {
        public var claudePath: String
        /// Directory containing the `vmotion` binary; prepended to PATH.
        public var vmotionDirectory: String
        public var workingDirectory: URL
        public var model: String?
        /// `--effort` level (low, medium, high, xhigh, max); nil/empty uses Claude Code's default.
        public var effort: String?
        public var extraEnvironment: [String: String]
        public var systemPrompt: String
        /// Unix socket paths the agent's (possibly sandboxed) Bash may connect to.
        public var unixSockets: [String]
        /// More folders Read may open (e.g. folders of files dragged into the chat).
        public var extraReadDirectories: [String] = []
        /// Resume into a new session id instead of continuing the original (`--fork-session`), e.g. for a copied
        /// project whose conversation must not keep growing the original's session. Cleared once forked.
        public var forkSession = false

        public init(claudePath: String, vmotionDirectory: String, workingDirectory: URL, model: String? = nil,
                    extraEnvironment: [String: String] = [:], systemPrompt: String = AgentPrompt.systemPrompt,
                    unixSockets: [String] = [ControlSocket.defaultPath]) {
            self.claudePath = claudePath
            self.vmotionDirectory = vmotionDirectory
            self.workingDirectory = workingDirectory
            self.model = model
            self.extraEnvironment = extraEnvironment
            self.systemPrompt = systemPrompt
            self.unixSockets = unixSockets
        }

        /// Default working directory for the agent: `~/Library/Application Support/VeyMotion/agent`.
        public static var defaultWorkingDirectory: URL {
            ControlSocket.supportDirectory.appendingPathComponent("agent", isDirectory: true)
        }
    }

    public var config: Config
    /// Called on a background queue; hop to the main thread for UI work.
    public var onEvent: ((AgentEvent) -> Void)?
    public private(set) var sessionId: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var streamedMessages = Set<String>()
    private var currentMessageId = ""
    private var currentToolName = ""
    private var toolInputBytes = 0
    private var lastReportedBytes = 0
    private let queue = DispatchQueue(label: "veymotion.agent")

    public init(config: Config, resumeSessionId: String? = nil) {
        self.config = config
        self.sessionId = resumeSessionId
    }

    public var isRunning: Bool { process?.isRunning == true }

    public func arguments() -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--tools", "Bash,Read",
            "--allowedTools", "Bash(vmotion:*)", "Bash(vmotion *)", "Read",
            // So Read can open asset files: the shared library, the projects folder and the open project.
            "--add-dir", AssetStore.sharedDirectory.path, ProjectStore.projectsDirectory.path, AssetStore.directory.path,
        ] + config.extraReadDirectories + [
            "--strict-mcp-config",
            "--setting-sources", "",
            "--append-system-prompt", config.systemPrompt,
        ]
        // Claude Code may run Bash in its sandbox (e.g. enforced by org policy), which blocks unix
        // sockets by default. Allow exactly VeyMotion's control socket so `vmotion` can reach the app.
        if !config.unixSockets.isEmpty {
            let settings: [String: Any] = ["sandbox": ["network": ["allowUnixSockets": config.unixSockets]]]
            if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.withoutEscapingSlashes]),
               let json = String(data: data, encoding: .utf8) {
                args += ["--settings", json]
            }
        }
        if let model = config.model, !model.isEmpty { args += ["--model", model] }
        if let effort = config.effort, !effort.isEmpty { args += ["--effort", effort] }
        if let sessionId {
            args += ["--resume", sessionId]
            if config.forkSession { args.append("--fork-session") }
        }
        return args
    }

    public func start() throws {
        guard !isRunning else { return }
        try FileManager.default.createDirectory(at: config.workingDirectory, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.claudePath)
        p.arguments = arguments()
        p.currentDirectoryURL = config.workingDirectory

        var env = ProcessInfo.processInfo.environment
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = ([config.vmotionDirectory, basePath, "/opt/homebrew/bin", "/usr/local/bin"]).joined(separator: ":")
        for (k, v) in AgentCLI.extraEnvironment { env[k] = v }
        for (k, v) in config.extraEnvironment { env[k] = v }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        buffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            self?.queue.async { self?.consume(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) else { return }
            self?.onEvent?(.stderr(s))
        }
        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            self?.queue.async {
                self?.onEvent?(.exited(code: proc.terminationStatus))
            }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
    }

    /// An image sent with a user message (base64 image block).
    public struct ImageAttachment {
        public var mediaType: String
        public var data: Data
        public init(mediaType: String, data: Data) {
            self.mediaType = mediaType
            self.data = data
        }
    }

    public func send(_ text: String, images: [ImageAttachment] = []) throws {
        if !isRunning { try start() }
        var content: [[String: Any]] = [["type": "text", "text": text]]
        for image in images {
            content.append(["type": "image",
                            "source": ["type": "base64", "media_type": image.mediaType,
                                       "data": image.data.base64EncodedString()]])
        }
        let msg: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        var data = try JSONSerialization.data(withJSONObject: msg)
        data.append(0x0A)
        try stdin?.write(contentsOf: data)
    }

    /// Kills the running process (interrupting the current turn). The session can be resumed.
    public func stop() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
    }

    /// Closes stdin so the process exits after the current turn.
    public func finish() {
        try? stdin?.close()
    }

    /// Forget the session; the next `send` starts a fresh conversation.
    public func reset() {
        stop()
        sessionId = nil
    }

    // MARK: - Parsing

    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "system":
            if obj["subtype"] as? String == "init" {
                let sid = obj["session_id"] as? String ?? ""
                if !sid.isEmpty {
                    sessionId = sid
                    config.forkSession = false // forked now; a restart resumes this new session
                }
                onEvent?(.started(sessionId: sid, model: obj["model"] as? String ?? ""))
            }

        case "stream_event":
            guard let ev = obj["event"] as? [String: Any] else { return }
            switch ev["type"] as? String {
            case "message_start":
                currentMessageId = (ev["message"] as? [String: Any])?["id"] as? String ?? UUID().uuidString
            case "content_block_start":
                let block = ev["content_block"] as? [String: Any] ?? [:]
                if block["type"] as? String == "tool_use" {
                    currentToolName = block["name"] as? String ?? "tool"
                    toolInputBytes = 0
                    lastReportedBytes = 0
                    onEvent?(.toolInputProgress(name: currentToolName, bytes: 0))
                } else if block["type"] as? String == "thinking" {
                    onEvent?(.thinking)
                }
            case "content_block_delta":
                let delta = ev["delta"] as? [String: Any] ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    streamedMessages.insert(currentMessageId)
                    onEvent?(.textDelta(messageId: currentMessageId, text: delta["text"] as? String ?? ""))
                case "thinking_delta":
                    onEvent?(.thinking)
                case "input_json_delta":
                    toolInputBytes += (delta["partial_json"] as? String ?? "").utf8.count
                    if toolInputBytes - lastReportedBytes >= 512 { // throttle UI updates
                        lastReportedBytes = toolInputBytes
                        onEvent?(.toolInputProgress(name: currentToolName, bytes: toolInputBytes))
                    }
                default: break
                }
            default: break
            }

        case "assistant":
            guard let msg = obj["message"] as? [String: Any] else { return }
            let id = msg["id"] as? String ?? ""
            for block in msg["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if !streamedMessages.contains(id), let t = block["text"] as? String, !t.isEmpty {
                        onEvent?(.text(messageId: id, text: t))
                    }
                case "tool_use":
                    onEvent?(.toolUse(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                                      input: block["input"] as? [String: Any] ?? [:]))
                default: break
                }
            }

        case "user":
            guard let msg = obj["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { return }
            for block in blocks where block["type"] as? String == "tool_result" {
                var text = ""
                var image: Data?
                if let s = block["content"] as? String {
                    text = s
                } else {
                    for part in block["content"] as? [[String: Any]] ?? [] {
                        if part["type"] as? String == "text" {
                            text += (text.isEmpty ? "" : "\n") + (part["text"] as? String ?? "")
                        } else if part["type"] as? String == "image",
                                  let src = part["source"] as? [String: Any],
                                  let b64 = src["data"] as? String {
                            image = Data(base64Encoded: b64)
                        }
                    }
                }
                onEvent?(.toolResult(toolUseId: block["tool_use_id"] as? String ?? "", output: text,
                                     isError: block["is_error"] as? Bool ?? false, image: image))
            }

        case "result":
            if let sid = obj["session_id"] as? String, !sid.isEmpty { sessionId = sid }
            onEvent?(.turnFinished(isError: obj["is_error"] as? Bool ?? false,
                                   result: obj["result"] as? String,
                                   costUSD: obj["total_cost_usd"] as? Double,
                                   durationMs: obj["duration_ms"] as? Int))
        default:
            break
        }
    }

    // MARK: - Discovery

    /// A model the user's own `claude` offers (from the CLI's `initialize` control response).
    public struct ModelInfo: Equatable {
        public var value: String
        public var resolvedModel: String?
        public var displayName: String
        public var description: String
        public var efforts: [String]

        public init(value: String, resolvedModel: String?, displayName: String, description: String, efforts: [String]) {
            self.value = value
            self.resolvedModel = resolvedModel
            self.displayName = displayName
            self.description = description
            self.efforts = efforts
        }
    }

    /// Asks `claude` which models this account and CLI version offer. Costs a short-lived process
    /// and no tokens: the answer comes from the `initialize` control request, before any turn.
    /// Blocking (up to `timeout`); call it off the main thread. Returns nil on failure.
    public static func supportedModels(claudePath: String, workingDirectory: URL,
                                       timeout: TimeInterval = 15) -> [ModelInfo]? {
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--strict-mcp-config", "--setting-sources", ""]
        p.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin", "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        for (k, v) in AgentCLI.extraEnvironment { env[k] = v }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var buffer = Data()
        var result: [ModelInfo]?
        let done = DispatchSemaphore(value: 0)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock(); defer { lock.unlock() }
            if chunk.isEmpty { h.readabilityHandler = nil; done.signal(); return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                guard result == nil,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] as? String == "control_response",
                      let response = obj["response"] as? [String: Any],
                      response["request_id"] as? String == "veymotion-models" else { continue }
                let models = ((response["response"] as? [String: Any])?["models"] as? [[String: Any]]) ?? []
                result = models.compactMap { m in
                    guard let value = m["value"] as? String else { return nil }
                    let efforts = (m["supportsEffort"] as? Bool ?? false) ? (m["supportedEffortLevels"] as? [String] ?? []) : []
                    return ModelInfo(value: value, resolvedModel: m["resolvedModel"] as? String,
                                     displayName: m["displayName"] as? String ?? value,
                                     description: m["description"] as? String ?? "", efforts: efforts)
                }
                done.signal()
            }
        }
        do { try p.run() } catch { return nil }
        let request = #"{"type":"control_request","request_id":"veymotion-models","request":{"subtype":"initialize"}}"# + "\n"
        try? inPipe.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        _ = done.wait(timeout: .now() + timeout)
        outPipe.fileHandleForReading.readabilityHandler = nil
        try? inPipe.fileHandleForWriting.close()
        if p.isRunning { p.terminate() }
        lock.lock(); defer { lock.unlock() }
        return (result?.isEmpty ?? true) ? nil : result
    }

    /// One `claude -p` turn whose answer must match `schema` (JSON Schema), e.g. the design critic's scores.
    /// Tool-less unless `readsFiles`: then it may Read files in `workingDirectory` (the design critic's frames).
    /// The prompt goes in on stdin. Blocking; call it off the main thread.
    public static func structured(prompt: String, schema: [String: Any], claudePath: String, model: String? = nil,
                                  workingDirectory: URL = Config.defaultWorkingDirectory,
                                  readsFiles: Bool = false,
                                  timeout: TimeInterval = 120,
                                  isCancelled: @escaping () -> Bool = { false }) throws -> [String: Any] {
        struct Failure: LocalizedError {
            var errorDescription: String?
        }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let schemaJSON = String(data: try JSONSerialization.data(withJSONObject: schema), encoding: .utf8) ?? "{}"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        var args = ["-p", "--output-format", "json", "--tools", readsFiles ? "Read" : "", "--strict-mcp-config",
                    "--setting-sources", "", "--no-session-persistence", "--json-schema", schemaJSON]
        if readsFiles { args += ["--allowedTools", "Read"] }
        if let model, !model.isEmpty { args += ["--model", model] }
        p.arguments = args
        p.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin", "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
        for (k, v) in AgentCLI.extraEnvironment { env[k] = v }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        let lock = NSLock()
        var out = Data(), err = Data()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let c = h.availableData; lock.lock(); out.append(c); lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let c = h.availableData; lock.lock(); err.append(c); lock.unlock()
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        try? inPipe.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        try? inPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled() || Date() > deadline {
                p.terminate()
                done.wait()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                throw Failure(errorDescription: isCancelled() ? "Cancelled" : "Claude took too long to answer.")
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        let output = out, errors = String(data: err, encoding: .utf8) ?? ""
        lock.unlock()

        guard let obj = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else {
            let detail = (errors.isEmpty ? String(data: output.prefix(400), encoding: .utf8) ?? "" : errors)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(errorDescription: "Claude did not answer (exit \(p.terminationStatus)). \(detail.prefix(400))")
        }
        if obj["is_error"] as? Bool == true {
            throw Failure(errorDescription: "Claude: \(obj["result"] as? String ?? obj["subtype"] as? String ?? "error")")
        }
        if let s = obj["structured_output"] as? [String: Any] { return s }
        // Older CLIs: the JSON answer is in `result`.
        if let text = obj["result"] as? String, let data = text.data(using: .utf8),
           let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return s
        }
        throw Failure(errorDescription: "Claude's answer was not in the expected format.")
    }

    /// Finds the `claude` executable: $VEYMOTION_CLAUDE, common install paths, PATH, then a login shell.
    public static func locateClaude() -> String? {
        let home = NSHomeDirectory()
        return AgentCLI.locate("claude", envVar: "VEYMOTION_CLAUDE",
                               candidates: ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                                            "/opt/homebrew/bin/claude", "/usr/local/bin/claude"])
    }
}
