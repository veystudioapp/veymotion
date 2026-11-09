import Foundation

/// Runs the Codex CLI headless for the chat: one `codex exec --json` process per message, continuing the thread
/// with `codex exec resume <id>`. Codex edits the scene through the `veymotion` MCP server (`vmotion mcp`, bridged to
/// the app's control socket), so its tool calls are not sandboxed and every edit is undoable; its own shell runs in a
/// read-only sandbox without approvals. The user's `~/.codex/config.toml` is loaded (custom providers, base URLs,
/// default model), but the `-c` overrides below win over it; execpolicy rules are ignored.
public final class CodexAgent: ChatAgent {
    public struct Config {
        public var codexPath: String
        /// The `vmotion` binary, started by Codex as its MCP server.
        public var vmotionPath: String
        public var workingDirectory: URL
        public var model: String?
        /// `model_reasoning_effort` (low, medium, high, xhigh…); nil/empty uses the model's default.
        public var effort: String?
        public var systemPrompt: String
        public var socketPath: String
        /// The first message forks the session (`codex exec fork`) instead of resuming it. Cleared once forked.
        public var forkSession = false

        public init(codexPath: String, vmotionPath: String, workingDirectory: URL, model: String? = nil,
                    effort: String? = nil, systemPrompt: String = AgentPrompt.codexPrompt,
                    socketPath: String = ControlSocket.defaultPath) {
            self.codexPath = codexPath
            self.vmotionPath = vmotionPath
            self.workingDirectory = workingDirectory
            self.model = model
            self.effort = effort
            self.systemPrompt = systemPrompt
            self.socketPath = socketPath
        }
    }

    /// State of one `codex exec` process. Events of a run that was replaced are dropped.
    private final class Run {
        let tag = String(UUID().uuidString.prefix(8))
        let started = Date()
        let resuming: Bool
        var buffer = Data()
        /// Bytes of `buffer` already searched for a newline (frames make lines of several MB).
        var scanned = 0
        var threadStarted = false
        var turnEnded = false
        var errors = ""
        var announcedTools = Set<String>()
        var files: [URL] = []
        init(resuming: Bool) { self.resuming = resuming }
        var elapsedMs: Int { Int(Date().timeIntervalSince(started) * 1000) }
    }

    public var config: Config
    public var onEvent: ((AgentEvent) -> Void)?
    public private(set) var sessionId: String?

    private var process: Process?
    private var current: Run?
    private let queue = DispatchQueue(label: "veymotion.codex")

    public init(config: Config, resumeSessionId: String? = nil) {
        self.config = config
        self.sessionId = resumeSessionId
    }

    public var isRunning: Bool { process?.isRunning == true }

    /// `-c key=value` overrides. Values are TOML; a JSON string is a valid TOML basic string.
    private func overrides() -> [String] {
        func str(_ s: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        var kv = [
            "sandbox_mode": str("read-only"),
            "approval_policy": str("never"),
            "developer_instructions": str(config.systemPrompt),
            "mcp_servers.veymotion.command": str(config.vmotionPath),
            "mcp_servers.veymotion.args": "[\"mcp\"]",
            "mcp_servers.veymotion.env": "{ VEYMOTION_SOCKET = \(str(config.socketPath)) }",
            "mcp_servers.veymotion.default_tools_approval_mode": str("approve"),
            "mcp_servers.veymotion.startup_timeout_sec": "30",
            // Voice-overs, transcription and stock downloads can take minutes.
            "mcp_servers.veymotion.tool_timeout_sec": "900",
        ]
        if let effort = config.effort, !effort.isEmpty { kv["model_reasoning_effort"] = str(effort) }
        return kv.sorted { $0.key < $1.key }.flatMap { ["-c", "\($0.key)=\($0.value)"] }
    }

    public func arguments(images: [URL] = []) -> [String] {
        var args = ["exec"]
        if sessionId != nil { args.append(config.forkSession ? "fork" : "resume") }
        // Not --ignore-user-config: it would drop a custom `model_provider` / `base_url` (proxies) and send the
        // key to api.openai.com.
        args += ["--skip-git-repo-check", "--ignore-rules"] + overrides()
        if let model = config.model, !model.isEmpty { args += ["-m", model] }
        for url in images { args += ["-i", url.path] }
        args.append("--json") // a plain flag, so `-` below is not taken as one more image
        if let sessionId { args.append(sessionId) }
        args.append("-") // the prompt comes on stdin
        return args
    }

    public func send(_ text: String, images: [ClaudeCodeAgent.ImageAttachment] = []) throws {
        if let old = process, old.isRunning { // still shutting down after stop(); its events are dropped
            old.terminate()
            old.waitUntilExit()
        }
        let fm = FileManager.default
        try fm.createDirectory(at: config.workingDirectory, withIntermediateDirectories: true)

        let run = Run(resuming: sessionId != nil)
        if !images.isEmpty {
            let dir = config.workingDirectory.appendingPathComponent("attachments", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for image in images {
                let ext = image.mediaType.split(separator: "/").last.map(String.init) ?? "png"
                let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext == "jpeg" ? "jpg" : ext)")
                try image.data.write(to: url) // not .atomic: that stages in the system temp folder
                run.files.append(url)
            }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.codexPath)
        p.arguments = arguments(images: run.files)
        p.currentDirectoryURL = config.workingDirectory
        var env = ProcessInfo.processInfo.environment
        // The CLI's own folder first: an npm install needs the `node` that sits next to it.
        env["PATH"] = AgentCLI.path(first: [URL(fileURLWithPath: config.codexPath).deletingLastPathComponent().path])
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            self?.queue.async { self?.consume(chunk, run) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) else { return }
            self?.queue.async {
                guard let self else { return }
                run.errors = String((run.errors + s).suffix(4000))
                if self.current === run { self.onEvent?(.stderr(s)) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
            self?.queue.async { self?.finished(run, code: proc.terminationStatus, rest: rest) }
        }
        queue.sync { current = run }
        try p.run()
        process = p
        try? inPipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try? inPipe.fileHandleForWriting.close()
    }

    public func stop() {
        guard let p = process, p.isRunning else { return }
        p.terminate()
    }

    public func reset() {
        queue.sync { current = nil } // the stopped run's events must not reach a fresh conversation
        stop()
        sessionId = nil
    }

    // MARK: - Parsing (on `queue`)

    /// Splits stdout into JSON lines. Only the new bytes are searched (memchr): an event carrying rendered frames is
    /// several MB, and rescanning the whole buffer for every 16–64 KB chunk stalled the chat for minutes.
    private func consume(_ chunk: Data, _ run: Run) {
        guard !chunk.isEmpty else { return }
        run.buffer.append(chunk)
        var lines: [Data] = []
        var consumed = 0
        run.buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var from = run.scanned
            while from < raw.count, let hit = memchr(base + from, 0x0A, raw.count - from) {
                let nl = base.distance(to: UnsafeRawPointer(hit))
                if nl > consumed { lines.append(Data(bytes: base + consumed, count: nl - consumed)) }
                consumed = nl + 1
                from = nl + 1
            }
        }
        if consumed > 0 { run.buffer = run.buffer.subdata(in: consumed..<run.buffer.count) }
        run.scanned = run.buffer.count
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj, run)
        }
    }

    private func finished(_ run: Run, code: Int32, rest: Data) {
        consume(rest + Data([0x0A]), run)
        for url in run.files { try? FileManager.default.removeItem(at: url) }
        guard current === run else { return }
        if run.resuming, !run.threadStarted, code != 0, Self.isMissingSession(run.errors) {
            onEvent?(.resumeFailed)
        }
        // A failed turn was already reported; its non-zero exit code would only repeat it.
        onEvent?(.exited(code: run.turnEnded ? 0 : code))
    }

    static func isMissingSession(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["no rollout found", "no saved session found", "thread not found", "session not found",
                "failed to locate thread"].contains { t.contains($0) }
    }

    private func emit(_ ev: AgentEvent, _ run: Run) {
        guard current === run else { return }
        onEvent?(ev)
    }

    private func handle(_ obj: [String: Any], _ run: Run) {
        switch obj["type"] as? String {
        case "thread.started":
            let id = obj["thread_id"] as? String ?? ""
            run.threadStarted = true
            if !id.isEmpty, current === run {
                sessionId = id
                config.forkSession = false // forked now; later messages resume this thread
            }
            emit(.started(sessionId: id, model: config.model ?? ""), run)

        case "turn.started":
            emit(.thinking, run)

        case "item.started", "item.updated", "item.completed":
            guard let item = obj["item"] as? [String: Any] else { return }
            handleItem(item, completed: obj["type"] as? String == "item.completed", run)

        case "turn.completed":
            run.turnEnded = true
            emit(.turnFinished(isError: false, result: nil, costUSD: nil, durationMs: run.elapsedMs), run)

        case "turn.failed":
            run.turnEnded = true
            let message = (obj["error"] as? [String: Any])?["message"] as? String
            emit(.turnFinished(isError: true, result: message ?? "Codex reported an error.", costUSD: nil,
                               durationMs: run.elapsedMs), run)

        case "error":
            let message = obj["message"] as? String ?? ""
            run.errors += message + "\n"
            emit(.stderr(message + "\n"), run)

        default:
            break
        }
    }

    private func handleItem(_ item: [String: Any], completed: Bool, _ run: Run) {
        let id = "\(run.tag)-\(item["id"] as? String ?? "")"
        switch item["type"] as? String {
        case "agent_message":
            if completed, let text = item["text"] as? String, !text.isEmpty { emit(.text(messageId: id, text: text), run) }

        case "reasoning":
            emit(.thinking, run)

        case "mcp_tool_call":
            let server = item["server"] as? String ?? "mcp"
            let tool = item["tool"] as? String ?? "tool"
            announce(id, name: "mcp__\(server)__\(tool)", input: Self.arguments(item["arguments"]), run)
            guard completed else { return }
            var text = (item["error"] as? [String: Any])?["message"] as? String ?? ""
            var image: Data?
            let result = item["result"] as? [String: Any] ?? [:]
            func collect(_ parts: [[String: Any]]) {
                for part in parts {
                    switch part["type"] as? String {
                    case "text":
                        let t = part["text"] as? String ?? ""
                        // Calls made from Codex's code mode come back as the MCP result serialized into one text part.
                        if t.hasPrefix("{\"content\""), let data = t.data(using: .utf8),
                           let inner = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                           let innerParts = inner["content"] as? [[String: Any]] {
                            collect(innerParts)
                        } else {
                            text += (text.isEmpty ? "" : "\n") + t
                        }
                    case "image":
                        if image == nil, let b64 = part["data"] as? String { image = Data(base64Encoded: b64) }
                    default: break
                    }
                }
            }
            collect(result["content"] as? [[String: Any]] ?? [])
            let isError = item["status"] as? String == "failed" || item["error"] is [String: Any]
                || result["is_error"] as? Bool == true || result["isError"] as? Bool == true
            emit(.toolResult(toolUseId: id, output: text, isError: isError, image: image), run)

        case "command_execution":
            announce(id, name: "Shell", input: ["command": item["command"] as? String ?? ""], run)
            guard completed else { return }
            let exit = item["exit_code"] as? Int
            emit(.toolResult(toolUseId: id, output: item["aggregated_output"] as? String ?? "",
                             isError: item["status"] as? String != "completed" || (exit ?? 0) != 0, image: nil), run)

        case "web_search":
            announce(id, name: "Web search", input: ["query": item["query"] as? String ?? ""], run)
            if completed { emit(.toolResult(toolUseId: id, output: "", isError: false, image: nil), run) }

        case "error":
            let message = item["message"] as? String ?? ""
            run.errors += message + "\n"
            emit(.stderr(message + "\n"), run)

        default:
            break
        }
    }

    /// Reports a tool call once (items can complete without a `started` event).
    private func announce(_ id: String, name: String, input: [String: Any], _ run: Run) {
        guard run.announcedTools.insert(id).inserted else { return }
        emit(.toolUse(id: id, name: name, input: input), run)
    }

    private static func arguments(_ value: Any?) -> [String: Any] {
        if let obj = value as? [String: Any] { return obj }
        if let s = value as? String, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
            return obj
        }
        return [:]
    }

    // MARK: - Discovery

    /// The models this Codex CLI lists (`codex debug models`), best first. Blocking; call it off the main thread.
    public static func supportedModels(codexPath: String, workingDirectory: URL,
                                       timeout: TimeInterval = 20) -> [ClaudeCodeAgent.ModelInfo]? {
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: codexPath)
        p.arguments = ["debug", "models"]
        p.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = AgentCLI.path(first: [URL(fileURLWithPath: codexPath).deletingLastPathComponent().path])
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var data = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let c = h.availableData; lock.lock(); data.append(c); lock.unlock()
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            out.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        out.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        data.append(out.fileHandleForReading.readDataToEndOfFile())
        let output = data
        lock.unlock()

        guard let obj = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let list = obj["models"] as? [[String: Any]] else { return nil }
        let models = list
            .filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { m -> ClaudeCodeAgent.ModelInfo? in
                guard let slug = m["slug"] as? String else { return nil }
                let efforts = (m["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
                return ClaudeCodeAgent.ModelInfo(value: slug, resolvedModel: slug,
                                                 displayName: m["display_name"] as? String ?? slug,
                                                 description: m["description"] as? String ?? "", efforts: efforts)
            }
        return models.isEmpty ? nil : models
    }

    /// Finds the `codex` executable: $VEYMOTION_CODEX, common install paths, PATH, then a login shell.
    public static func locateCodex() -> String? {
        let home = NSHomeDirectory()
        // The official installer honors CODEX_INSTALL_DIR (default ~/.local/bin).
        let custom = ProcessInfo.processInfo.environment["CODEX_INSTALL_DIR"].map { ["\($0)/codex"] } ?? []
        return AgentCLI.locate("codex", envVar: "VEYMOTION_CODEX",
                               candidates: custom + ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex",
                                            "/usr/local/bin/codex", "\(home)/.npm-global/bin/codex"])
    }
}
