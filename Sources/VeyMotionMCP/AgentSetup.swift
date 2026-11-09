import Foundation
import Security

/// Whether a chat CLI can be used: installed, logged in (or given an API key), and what to tell the user if not.
public enum AgentSetup {
    /// What the CLI's own status command says about its login.
    public enum Login: Equatable {
        case loggedIn
        case loggedOut
        /// The status command failed or is too old to have one; the first message will tell.
        case unknown
    }

    /// Asks the CLI whether it is logged in (`claude auth status`, `codex login status`). Blocking (≤ `timeout`).
    public static func login(_ provider: AgentProvider, path: String, timeout: TimeInterval = 10) -> Login {
        switch provider {
        case .claude:
            // An API key we pass in the environment is not something `auth status` knows about.
            if AgentCLI.extraEnvironment["ANTHROPIC_API_KEY"] != nil { return .unknown }
            guard let out = run(path, ["auth", "status", "--json"], timeout: timeout),
                  let start = out.output.firstIndex(of: "{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(out.output[start...].utf8)) as? [String: Any],
                  let loggedIn = obj["loggedIn"] as? Bool else { return .unknown }
            return loggedIn ? .loggedIn : .loggedOut
        case .codex:
            guard let out = run(path, ["login", "status"], timeout: timeout) else { return .unknown }
            let text = out.output.lowercased()
            if text.contains("not logged in") {
                // A custom provider in config.toml (proxy, Azure, local model) has its own key: no login needed.
                return codexUsesCustomProvider ? .unknown : .loggedOut
            }
            if text.contains("logged in") || text.contains("api key configured") { return .loggedIn }
            return .unknown
        }
    }

    /// `model_provider` in `~/.codex/config.toml` (or `$CODEX_HOME`) names a provider other than OpenAI's.
    static var codexUsesCustomProvider: Bool {
        let env = ProcessInfo.processInfo.environment
        let home = env["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        guard let toml = try? String(contentsOfFile: home + "/config.toml", encoding: .utf8) else { return false }
        for line in toml.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { break } // only the top-level key counts
            guard l.hasPrefix("model_provider"), let eq = l.firstIndex(of: "=") else { continue }
            let value = l[l.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return !value.isEmpty && value != "openai"
        }
        return false
    }

    /// Gives Codex an OpenAI API key (`codex login --with-api-key`, key on stdin). Blocking.
    public static func codexLogin(apiKey: String, path: String) -> String? {
        guard let out = run(path, ["login", "--with-api-key"], input: apiKey + "\n", timeout: 20) else {
            return "Codex did not answer."
        }
        return out.status == 0 ? nil : out.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Errors

    public enum Failure: Equatable {
        /// The key or login was refused or has expired.
        case auth
        /// Out of credits, quota or the plan's usage limit.
        case limit
    }

    /// Recognizes login and billing problems in a CLI's error text.
    public static func classify(_ text: String) -> Failure? {
        let t = text.lowercased()
        let auth = ["invalid api key", "please run /login", "not logged in", "authentication_error", "oauth token has expired",
                    "token has expired", "unauthorized", "missing bearer", "could not be refreshed", "invalid_api_key",
                    "incorrect api key", "token_expired", "login required", "please log in", "api key not valid"]
        let limit = ["credit balance is too low", "usage limit", "hit your limit", "exceeded your current quota",
                     "insufficient_quota", "usage_limit_reached", "billing", "rate limit", "rate_limit"]
        if auth.contains(where: t.contains) || t.range(of: #"\b401\b"#, options: .regularExpression) != nil { return .auth }
        if limit.contains(where: t.contains) || t.range(of: #"\b(402|429)\b"#, options: .regularExpression) != nil {
            return .limit
        }
        return nil
    }

    // MARK: - Terminal scripts

    /// Shell commands that install the CLI and then log in. Both official installers put a standalone binary in
    /// `~/.local/bin` (no Node.js): https://code.claude.com/docs/en/quickstart, https://learn.chatgpt.com/docs/codex/cli
    public static func installScript(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude:
            return """
            \(installCommand(.claude)) && "$HOME/.local/bin/claude" auth login
            """
        case .codex:
            // The installer may offer to start Codex: answer no, the login below follows.
            return """
            \(installCommand(.codex)) && "${CODEX_INSTALL_DIR:-$HOME/.local/bin}/codex" login
            """
        }
    }

    public static func loginScript(_ provider: AgentProvider, path: String?) -> String {
        let cli = path.map { "'\($0)'" } ?? (provider == .claude ? "claude" : "codex")
        return provider == .claude ? "\(cli) auth login" : "\(cli) login"
    }

    /// The official install command, shown to the user (copyable).
    public static func installCommand(_ provider: AgentProvider) -> String {
        provider == .claude ? "curl -fsSL https://claude.ai/install.sh | bash"
            : "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
    }

    /// Writes `commands` to a `.command` file that Terminal runs when opened. Returns its URL.
    public static func terminalScript(named name: String, commands: String) throws -> URL {
        let dir = ControlSocket.supportDirectory.appendingPathComponent("setup", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).command")
        // Terminal does not inherit the app's environment: carry over where the CLIs keep their login.
        let env = ProcessInfo.processInfo.environment
        let exports = ["CLAUDE_CONFIG_DIR", "CODEX_HOME"].compactMap { k in
            env[k].map { "export \(k)='\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
        }.joined(separator: "\n")
        let script = """
        #!/bin/zsh -l
        clear
        echo "Vey Motion setup: \(name)"
        echo
        \(exports)
        \(commands)
        echo
        echo "Done. You can close this window and go back to Vey Motion."

        """
        try? FileManager.default.removeItem(at: url)
        // Not `.atomic`: that stages in the system temp folder.
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8),
                                             attributes: [.posixPermissions: 0o755]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    // MARK: - Process

    private struct Output {
        var status: Int32
        var output: String
    }

    /// Runs `path args` with the agents' environment; stdout + stderr. Nil if it can't start or times out.
    private static func run(_ path: String, _ args: [String], input: String? = nil, timeout: TimeInterval) -> Output? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = AgentCLI.path(first: [URL(fileURLWithPath: path).deletingLastPathComponent().path])
        for (k, v) in AgentCLI.extraEnvironment { env[k] = v }
        p.environment = env
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        let lock = NSLock()
        var data = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let c = h.availableData; lock.lock(); data.append(c); lock.unlock()
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if let input {
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            out.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        out.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        data.append(out.fileHandleForReading.readDataToEndOfFile())
        return Output(status: p.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
    }
}

/// The Anthropic API key the user gave VeyMotion for Claude Code (Keychain). Passed as `ANTHROPIC_API_KEY`.
public enum AnthropicKeyStore {
    private static let service = "VeyMotion"
    private static let account = "anthropic-api-key"
    /// Set when a key is saved, so launches without one never touch the Keychain.
    private static let flag = "agent.claude.hasAPIKey"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static var hasKey: Bool { UserDefaults.standard.bool(forKey: flag) }

    public static func load() -> String? {
        guard hasKey else { return nil }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func save(_ key: String) throws {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not save the key in the Keychain (\(status))."])
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    public static func delete() {
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: flag)
    }
}
