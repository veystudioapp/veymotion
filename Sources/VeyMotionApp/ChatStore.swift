import AppKit
import Foundation
import Observation
import VeyMotionCore
import VeyMotionMCP

/// State of the embedded chat, run by Claude Code or the Codex CLI (`provider`). Claude edits the scene through the
/// `vmotion` CLI, Codex through `vmotion mcp`; both reach `SceneStore` over the control socket, so every agent change
/// is live and undoable.
///
/// Each project has its own conversation (transcript, plus one session per provider), saved in the project folder
/// (`ProjectStore.chatURL`). Loose scenes share one in-memory conversation.
@Observable
final class ChatStore {
    static let shared = ChatStore(scene: .shared)

    struct ToolCall {
        var id: String
        var title: String
        var detail: String
        var isDone = false
        var isError = false
        var output = ""
    }

    enum Kind {
        case user(String, images: [Attachment])
        case assistant(String, messageId: String)
        case tool(ToolCall)
        case image(NSImage, time: Double?)
        case notice(String, isError: Bool)
        case summary(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        var kind: Kind
    }

    /// An image waiting in the composer.
    struct Attachment: Identifiable {
        let id = UUID()
        var image: NSImage
        var mediaType: String
        var data: Data
        /// Told to Claude with the message (not shown in the transcript), e.g. what an annotated frame is.
        var note: String?
        /// Scene time of a canvas frame, shown as a badge on the image.
        var time: Double?
    }

    /// Used until (or if) `claude` has answered which models it offers.
    static let fallbackModels: [ClaudeCodeAgent.ModelInfo] = [
        .init(value: "", resolvedModel: nil, displayName: "Default (recommended)", description: "", efforts: efforts),
        .init(value: "opus", resolvedModel: nil, displayName: "Opus", description: "", efforts: efforts),
        .init(value: "sonnet", resolvedModel: nil, displayName: "Sonnet", description: "", efforts: efforts),
        .init(value: "haiku", resolvedModel: nil, displayName: "Haiku", description: "", efforts: []),
    ]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    /// Used until (or if) `codex debug models` has answered.
    static let codexFallbackModels: [ClaudeCodeAgent.ModelInfo] = [
        .init(value: "", resolvedModel: nil, displayName: "Default", description: "", efforts: codexEfforts),
    ]
    static let codexEfforts = ["low", "medium", "high", "xhigh"]

    /// Which CLI runs the chat. Each keeps its own model, effort and session.
    var provider: AgentProvider = ChatStore.savedProvider {
        didSet { if provider != oldValue { providerChanged(from: oldValue) } }
    }
    private static var savedProvider: AgentProvider {
        AgentProvider(rawValue: UserDefaults.standard.string(forKey: "agent.provider") ?? "") ?? .claude
    }
    /// UserDefaults key of a per-provider setting (Claude keeps the original keys).
    private static func settingKey(_ name: String, _ provider: AgentProvider) -> String {
        provider == .claude ? "agent.\(name)" : "agent.\(provider.rawValue).\(name)"
    }

    /// The models the user's `claude` offers; the CLI's `default` is stored as "" (no `--model`).
    var claudeModels: [ClaudeCodeAgent.ModelInfo] = ChatStore.fallbackModels
    /// The models the user's `codex` lists, after "Default" (no `-m`).
    var codexModels: [ClaudeCodeAgent.ModelInfo] = ChatStore.codexFallbackModels
    var models: [ClaudeCodeAgent.ModelInfo] { provider == .claude ? claudeModels : codexModels }

    var selectedModel: ClaudeCodeAgent.ModelInfo? { models.first { $0.value == model } }

    /// Short name for the picker: "Default" resolves to the model it stands for (e.g. "Opus 5.5").
    var modelLabel: String {
        guard let m = selectedModel else { return model.isEmpty ? "Default" : model }
        if m.value.isEmpty, let r = m.resolvedModel,
           let same = models.first(where: { !$0.value.isEmpty && $0.resolvedModel == r }) {
            return same.displayName
        }
        return m.displayName
    }

    /// Effort levels the selected model accepts (all of them while the list is unknown).
    var modelEfforts: [String] { selectedModel?.efforts ?? (provider == .claude ? Self.efforts : Self.codexEfforts) }

    var items: [Item] = []
    var input = ""
    var attachments: [Attachment] = []
    var isBusy = false
    var activity: String?
    var activityStart = Date()
    var scrollToken = 0
    var model: String = UserDefaults.standard.string(forKey: ChatStore.settingKey("model", ChatStore.savedProvider)) ?? "" {
        didSet {
            UserDefaults.standard.set(model, forKey: Self.settingKey("model", provider))
            needsRestart = true // the next message restarts the process with the new model (session resumes)
        }
    }
    var effort: String = UserDefaults.standard.string(forKey: ChatStore.settingKey("effort", ChatStore.savedProvider)) ?? "" {
        didSet {
            UserDefaults.standard.set(effort, forKey: Self.settingKey("effort", provider))
            needsRestart = true
        }
    }
    private(set) var claudePath: String?
    private(set) var codexPath: String?
    private(set) var setupProblem: String?

    @ObservationIgnored private let scene: SceneStore
    @ObservationIgnored private var agent: ChatAgent?
    @ObservationIgnored private var stoppedByUser = false
    @ObservationIgnored private var stderrTail = ""
    @ObservationIgnored private var pendingRenderTime: Double?
    @ObservationIgnored private var lastSentText: String?
    @ObservationIgnored private var lastSentImages: [ClaudeCodeAgent.ImageAttachment] = []
    /// Folders of files dragged into the chat, so the agent's Read can open them.
    @ObservationIgnored private var readDirectories: [String] = []
    @ObservationIgnored private var needsRestart = false
    @ObservationIgnored private var retriedFresh = false
    @ObservationIgnored private var resumeFailed = false

    /// The scene as one prompt left it. `prompt` is nil for the scene before the first prompt.
    struct Version: Identifiable, Codable {
        var id = UUID()
        var date = Date()
        var prompt: String?
        var scene: MotionScene
    }

    static let maxVersions = 100
    /// Snapshots taken after each prompt that changed the scene, oldest first.
    private(set) var versions: [Version] = []
    /// The prompt being worked on and the scene before it.
    @ObservationIgnored private var turnStart: (prompt: String, scene: MotionScene)?

    /// One project's conversation while another project is open.
    private struct Conversation {
        var items: [Item] = []
        var input = ""
        var attachments: [Attachment] = []
        var sessionIds: [AgentProvider: String] = [:]
        var forkSessions: Set<AgentProvider> = []
        var versions: [Version] = []
    }

    /// The project the shown conversation belongs to (nil = loose scene).
    @ObservationIgnored private var project: URL?
    /// Conversations of the projects opened earlier in this run, by project path ("" = loose scene).
    @ObservationIgnored private var parked: [String: Conversation] = [:]
    /// Sessions the next agent of each provider resumes (when no process of it is running).
    @ObservationIgnored private var sessionIds: [AgentProvider: String] = [:]
    /// The conversation came from a copy of another project: these providers' first resume forks the session.
    @ObservationIgnored private var forkSessions: Set<AgentProvider> = []

    private init(scene: SceneStore) {
        self.scene = scene
        project = scene.project
        restoreConversation()
        scene.onProjectChange = { [weak self] change in self?.projectChanged(change) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.saveConversation() }
        // Back from Terminal (installing or logging in): look again at the CLIs that were not ready.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            for p in AgentProvider.allCases where ![.ready, .checking].contains(self.agentStates[p] ?? .checking) {
                self.detect(p)
            }
        }
        if let key = AnthropicKeyStore.load() { AgentCLI.extraEnvironment["ANTHROPIC_API_KEY"] = key }
        if vmotionDirectory == nil {
            setupProblem = "The `vmotion` CLI was not found next to the app. Build everything with `swift build` (or `bash scripts/bundle.sh`)."
        }
        for p in AgentProvider.allCases { detect(p) }
    }

    // MARK: - Setup

    /// Where a chat CLI stands.
    enum AgentState: Equatable {
        case checking
        /// Not found on this Mac.
        case missing
        /// Its status command says nobody is logged in: messages are not sent until that changes.
        case loggedOut
        /// A message was refused (bad or expired key/login). Sending still tries.
        case authFailed(String)
        case ready

        var canSend: Bool { self == .ready || { if case .authFailed = self { return true }; return false }() }

        /// Short status for the assistant picker (nil when ready).
        var label: String? {
            switch self {
            case .checking: return "Checking…"
            case .missing: return "Not installed"
            case .loggedOut: return "Not logged in"
            case .authFailed: return "Sign-in failed"
            case .ready: return nil
            }
        }
    }

    private(set) var agentStates: [AgentProvider: AgentState] = [.claude: .checking, .codex: .checking]
    var agentState: AgentState { agentStates[provider] ?? .checking }
    @ObservationIgnored private var detecting: Set<AgentProvider> = []

    /// Finds the CLI, asks whether it is logged in, then loads its models.
    func detect(_ p: AgentProvider) {
        guard detecting.insert(p).inserted else { return }
        agentStates[p] = .checking
        DispatchQueue.global(qos: .userInitiated).async {
            let path = p == .claude ? ClaudeCodeAgent.locateClaude() : CodexAgent.locateCodex()
            let login = path.map { AgentSetup.login(p, path: $0) }
            DispatchQueue.main.async {
                self.detecting.remove(p)
                if p == .claude { self.claudePath = path } else { self.codexPath = path }
                let state: AgentState = path == nil ? .missing : login == .loggedOut ? .loggedOut : .ready
                self.agentStates[p] = state
                guard let path, state == .ready else { return }
                // A new login or install: the running process still has the old one.
                if p == self.provider, self.agent != nil { if self.isBusy { self.needsRestart = true } else { self.restartAgent() } }
                self.loadModels(p, path: path)
            }
        }
    }

    private func loadModels(_ p: AgentProvider, path: String) {
        let work = ClaudeCodeAgent.Config.defaultWorkingDirectory
        DispatchQueue.global(qos: .utility).async {
            switch p {
            case .claude:
                guard let models = ClaudeCodeAgent.supportedModels(claudePath: path, workingDirectory: work) else { return }
                let mapped = models.map { m -> ClaudeCodeAgent.ModelInfo in
                    var m = m
                    if m.value == "default" { m.value = "" }
                    return m
                }
                DispatchQueue.main.async { self.claudeModels = mapped }
            case .codex:
                guard let models = CodexAgent.supportedModels(codexPath: path, workingDirectory: work) else { return }
                let all = Array(Set(models.flatMap(\.efforts)))
                let efforts = Self.codexEfforts + all.filter { !Self.codexEfforts.contains($0) }.sorted()
                let def = ClaudeCodeAgent.ModelInfo(value: "", resolvedModel: nil, displayName: "Default",
                                                    description: "Codex's default model", efforts: efforts)
                DispatchQueue.main.async { self.codexModels = [def] + models }
            }
        }
    }

    /// Opens Terminal to install the current CLI (and log in), or just to log in.
    func openSetupInTerminal(install: Bool) {
        let p = provider
        // An API key overrides the account login, so logging in means dropping the saved key.
        if p == .claude, !install, AnthropicKeyStore.hasKey { forgetAnthropicKey() }
        let commands = install ? AgentSetup.installScript(p) : AgentSetup.loginScript(p, path: p == .claude ? claudePath : codexPath)
        do {
            let url = try AgentSetup.terminalScript(named: install ? "Install \(p.cliName)" : "Log in to \(p.cliName)",
                                                    commands: commands)
            if !NSWorkspace.shared.open(url) { throw CocoaError(.fileReadUnknown) }
        } catch {
            append(.notice("Could not open Terminal. Run this in Terminal yourself:\n\(commands)", isError: true))
        }
    }

    /// Uses an API key instead of an account: Claude gets it as `ANTHROPIC_API_KEY` (kept in the Keychain),
    /// Codex stores it itself (`codex login --with-api-key`).
    func useAPIKey(_ raw: String) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        switch provider {
        case .claude:
            do { try AnthropicKeyStore.save(key) } catch {
                append(.notice(error.localizedDescription, isError: true))
                return
            }
            AgentCLI.extraEnvironment["ANTHROPIC_API_KEY"] = key
            detect(.claude) // restarts a running agent with the key
        case .codex:
            guard let path = codexPath else { return }
            agentStates[.codex] = .checking
            DispatchQueue.global(qos: .userInitiated).async {
                let error = AgentSetup.codexLogin(apiKey: key, path: path)
                DispatchQueue.main.async {
                    if let error { self.append(.notice("Codex did not take the key: \(error)", isError: true)) }
                    self.detect(.codex)
                }
            }
        }
    }

    func forgetAnthropicKey() {
        AnthropicKeyStore.delete()
        AgentCLI.extraEnvironment["ANTHROPIC_API_KEY"] = nil
        detect(.claude)
    }

    /// Error text from the CLI, explained when it is a login or billing problem (a refused login also brings up
    /// the setup card).
    private func explainFailure(_ text: String, details: String = "") -> String {
        switch AgentSetup.classify(text + "\n" + details) {
        case .auth?:
            agentStates[provider] = .authFailed(text)
            return "\(provider.cliName) could not sign in: its login or API key was refused or has expired.\n\(text)"
        case .limit?:
            let fix = provider == .claude
                ? "Check your Claude plan's usage, or your Anthropic API credits."
                : "Check your ChatGPT plan's usage, or your OpenAI API credits."
            return "\(provider.cliName) is out of credits or hit a usage limit. \(fix)\n\(text)"
        case nil:
            return text
        }
    }

    private var vmotionDirectory: String? {
        let fm = FileManager.default
        var dirs: [String] = []
        if let d = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().path { dirs.append(d) }
        if let d = ProcessInfo.processInfo.environment["VEYMOTION_CLI_DIR"] { dirs.insert(d, at: 0) }
        return dirs.first { fm.isExecutableFile(atPath: "\($0)/vmotion") }
    }

    private func makeAgent(resume: String?) -> ChatAgent? {
        guard let dir = vmotionDirectory else { return nil }
        let work = ClaudeCodeAgent.Config.defaultWorkingDirectory
        let a: ChatAgent
        switch provider {
        case .claude:
            guard let claudePath else { return nil }
            var cfg = ClaudeCodeAgent.Config(
                claudePath: claudePath,
                vmotionDirectory: dir,
                workingDirectory: work,
                model: model,
                extraEnvironment: [
                    "VEYMOTION_FRAMES_DIR": work.appendingPathComponent("frames").path,
                    "VEYMOTION_SOCKET": ControlSocket.defaultPath,
                ])
            cfg.effort = effort
            cfg.extraReadDirectories = readDirectories
            cfg.forkSession = forkSessions.contains(.claude)
            a = ClaudeCodeAgent(config: cfg, resumeSessionId: resume)
        case .codex:
            guard let codexPath else { return nil }
            var cfg = CodexAgent.Config(codexPath: codexPath, vmotionPath: "\(dir)/vmotion", workingDirectory: work,
                                        model: model, effort: effort)
            cfg.forkSession = forkSessions.contains(.codex)
            a = CodexAgent(config: cfg, resumeSessionId: resume)
        }
        // Events still queued from a replaced agent (another project's) must not reach this conversation.
        a.onEvent = { [weak self, weak a] ev in
            DispatchQueue.main.async {
                guard let self, let a, self.agent === a else { return }
                self.handle(ev)
            }
        }
        return a
    }

    // MARK: - Actions

    /// Not while the CLI is missing, logged out or still being checked: the setup card says what to do.
    var canSend: Bool {
        !isBusy && agentState.canSend && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send() {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if needsRestart { restartAgent() }
        if agent == nil { agent = makeAgent(resume: sessionIds[provider]) }
        guard let agent else {
            append(.notice(setupProblem ?? "\(provider.cliName) is not available.", isError: true))
            return
        }
        let sent = attachments
        if text.isEmpty { text = "(see the attached image\(sent.count == 1 ? "" : "s"))" }
        let images = sent.map { ClaudeCodeAgent.ImageAttachment(mediaType: $0.mediaType, data: $0.data) }
        let notes = sent.compactMap(\.note)
        let agentText = notes.isEmpty ? text : (notes + [text]).joined(separator: "\n")
        input = ""
        attachments = []
        append(.user(text, images: sent))
        isBusy = true
        stoppedByUser = false
        retriedFresh = false
        resumeFailed = false
        lastSentText = agentText
        lastSentImages = images
        stderrTail = ""
        setActivity("Thinking…")
        turnStart = (text, scene.scene)
        do {
            try agent.send(contextLine() + "\n" + agentText, images: images)
        } catch {
            isBusy = false
            activity = nil
            turnStart = nil
            append(.notice("Could not start \(provider.cliName): \(error.localizedDescription)", isError: true))
        }
    }

    // MARK: - Versions

    /// Keeps the scene as the finished (or stopped) prompt left it, if the prompt changed it.
    private func recordVersion() {
        guard let start = turnStart else { return }
        turnStart = nil
        let now = scene.scene
        guard now != start.scene else { return }
        if versions.isEmpty { versions.append(Version(prompt: nil, scene: start.scene)) }
        versions.append(Version(prompt: start.prompt, scene: now))
        if versions.count > Self.maxVersions { versions.removeFirst(versions.count - Self.maxVersions) }
        saveVersions()
    }

    /// Puts a version's scene back (one undo step).
    func restore(_ version: Version) {
        var s = version.scene
        _ = s.refreshMediaInfo()
        scene.apply("Restore Version") { $0 = s }
    }

    private func saveVersions() {
        guard let project else { return }
        let url = ProjectStore.versionsURL(project)
        guard !versions.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let saved = versions.map { v -> Version in
            var v = v
            v.scene = v.scene.relativizingPaths(to: project)
            return v
        }
        guard let data = try? SceneJSON.encode(saved, pretty: false) else { return }
        try? SceneJSON.write(data, to: url)
    }

    private static func loadVersions(_ project: URL) -> [Version] {
        guard let data = try? Data(contentsOf: ProjectStore.versionsURL(project)),
              let saved = try? JSONDecoder().decode([Version].self, from: data) else { return [] }
        return saved.map { v in
            var v = v
            v.scene.resolvePaths(relativeTo: project)
            return v
        }
    }

    // MARK: - Attachments

    /// Adds an image from raw bytes (pasted or picked). Formats the API does not take are re-encoded as PNG,
    /// and large images are scaled down so a message stays well under the API's size limit.
    func attachImage(data: Data) {
        guard let image = NSImage(data: data) else { return }
        let sendable = ["image/png", "image/jpeg", "image/gif", "image/webp"]
        let type = Self.mediaType(of: data)
        let px = image.representations.map { CGFloat($0.pixelsWide) }.max() ?? image.size.width
        if let type, sendable.contains(type), data.count <= 3_500_000, px <= 2000 {
            attachments.append(Attachment(image: image, mediaType: type, data: data))
        } else if let png = Self.pngData(image, maxSide: 2000) {
            attachments.append(Attachment(image: image, mediaType: "image/png", data: png))
        }
    }

    /// A canvas frame with the user's marks drawn on it (JPEG, already sized for the API).
    func attachAnnotatedFrame(_ jpeg: Data, image: NSImage, time: Double, note: String) {
        attachments.append(Attachment(image: image, mediaType: "image/jpeg", data: jpeg, note: note, time: time))
    }

    func attachImage(file url: URL) {
        if let data = try? Data(contentsOf: url) { attachImage(data: data) }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Lets the agent's Read open files dropped into the chat. Takes effect when the process
    /// next starts, so an idle agent is restarted (the session resumes).
    func allowReading(_ urls: [URL]) {
        let covered = [AssetStore.sharedDirectory.path, ProjectStore.projectsDirectory.path, AssetStore.directory.path]
            + readDirectories
        var added = false
        for url in urls {
            let dir = url.hasDirectoryPath ? url.path : url.deletingLastPathComponent().path
            if covered.contains(where: { dir == $0 || dir.hasPrefix($0 + "/") }) || readDirectories.contains(dir) { continue }
            readDirectories.append(dir)
            added = true
        }
        guard added else { return }
        if isBusy { needsRestart = true } else { restartAgent() }
    }

    /// Replaces the agent with one started with the current Read folders, resuming the same session.
    /// The old process is detached first so its exit is not reported as an error.
    private func restartAgent() {
        needsRestart = false
        guard let old = agent else { return }
        let session = old.sessionId ?? sessionIds[provider]
        old.onEvent = nil
        old.stop()
        agent = makeAgent(resume: session)
    }

    private static func mediaType(of data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return nil
    }

    private static func pngData(_ image: NSImage, maxSide: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }

    func stop() {
        guard isBusy else { return }
        stoppedByUser = true
        agent?.stop()
        recordVersion()
        isBusy = false
        activity = nil
        append(.notice("Stopped. Your next message continues the same conversation.", isError: false))
    }

    func newChat() {
        recordVersion()
        stoppedByUser = true
        agent?.reset()
        agent = nil
        sessionIds = [:]
        forkSessions = []
        items = []
        attachments = []
        isBusy = false
        activity = nil
        saveConversation()
        bump()
    }

    // MARK: - Per-project conversations

    private func projectChanged(_ change: SceneStore.ProjectChange) {
        switch change {
        case let .opened(url):
            guard url?.path != project?.path else { return }
            parkConversation()
            project = url
            restoreConversation()
        case let .moved(from, to):
            // Same conversation, new place; Read's folders changed with it.
            project = to
            for i in versions.indices { versions[i].scene.replaceFolder(from.path, with: to.path) }
            if let start = turnStart {
                var s = start.scene
                s.replaceFolder(from.path, with: to.path)
                turnStart = (start.prompt, s)
            }
            saveConversation()
            saveVersions()
            if isBusy { needsRestart = true } else { restartAgent() }
        case let .adopted(url):
            // The loose scene's conversation becomes the new project's.
            parked[""] = nil
            project = url
            saveConversation()
            saveVersions()
            if isBusy { needsRestart = true } else { restartAgent() }
        }
    }

    private static func key(_ project: URL?) -> String { project?.path ?? "" }

    /// Stops the agent (its `vmotion` calls would otherwise edit the next project's scene) and stores the
    /// conversation, in memory and in the project folder. The session resumes when the project is reopened.
    private func parkConversation() {
        let sessions = currentSessions()
        if let a = agent {
            a.onEvent = nil
            a.stop()
        }
        agent = nil
        recordVersion()
        if isBusy {
            append(.notice("Stopped because you switched projects. Your next message here continues the conversation.",
                           isError: false))
        }
        isBusy = false
        activity = nil
        pendingRenderTime = nil
        needsRestart = false
        sessionIds = sessions
        saveConversation()
        parked[Self.key(project)] = Conversation(items: items, input: input, attachments: attachments,
                                                 sessionIds: sessions, forkSessions: forkSessions, versions: versions)
    }

    /// The conversation's sessions, including the running agent's latest one.
    private func currentSessions() -> [AgentProvider: String] {
        var s = sessionIds
        if let id = agent?.sessionId { s[provider] = id }
        return s
    }

    private static let switchNoticePrefix = "Now chatting with "

    /// Switching CLIs: the old one's session is kept for when the user switches back.
    private func providerChanged(from old: AgentProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: "agent.provider")
        if let a = agent {
            if let id = a.sessionId { sessionIds[old] = id }
            a.onEvent = nil
            a.stop()
        }
        agent = nil
        model = UserDefaults.standard.string(forKey: Self.settingKey("model", provider)) ?? ""
        effort = UserDefaults.standard.string(forKey: Self.settingKey("effort", provider)) ?? ""
        needsRestart = false
        // Switching back and forth: keep only the latest of these notices.
        if case let .notice(text, _)? = items.last?.kind, text.hasPrefix(Self.switchNoticePrefix) { items.removeLast() }
        if items.contains(where: { if case .user = $0.kind { return true }; return false }) {
            append(.notice("\(Self.switchNoticePrefix)\(provider.displayName). \(old.displayName) and \(provider.displayName) keep "
                           + "separate conversations: \(provider.displayName) does not see the messages above, but it sees the scene.",
                           isError: false))
        }
        saveConversation()
    }

    /// Shows the open project's conversation: from this run if it was open before, else from its folder.
    private func restoreConversation() {
        let c = parked.removeValue(forKey: Self.key(project)) ?? project.map { p in
            var c = Self.loadConversation(p) ?? Conversation()
            c.versions = Self.loadVersions(p)
            return c
        } ?? Conversation()
        items = c.items
        versions = c.versions
        input = c.input
        attachments = c.attachments
        sessionIds = c.sessionIds
        forkSessions = c.forkSessions
        stderrTail = ""
        bump()
    }

    /// On disk: text only (images are dropped), long tool outputs shortened.
    private struct SavedChat: Codable {
        /// Where it was saved. Read from another folder that is a project too, it is a copy (duplicated, or
        /// Save As), so that copy's conversation forks the session instead of continuing the original's.
        var project: String
        /// Claude's session.
        var sessionId: String?
        var forkSession: Bool?
        var codexSessionId: String?
        var codexForkSession: Bool?
        var items: [SavedItem]
    }

    private struct SavedItem: Codable {
        var kind: String
        var text: String
        var detail: String?
        var output: String?
        var isError: Bool?
    }

    /// Writes the open project's conversation to its folder (nothing for loose scenes).
    private func saveConversation() {
        guard let project else { return }
        let url = ProjectStore.chatURL(project)
        let sessions = currentSessions()
        guard !items.isEmpty || !sessions.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let saved = items.suffix(500).compactMap { item -> SavedItem? in
            switch item.kind {
            case let .user(text, _): return SavedItem(kind: "user", text: text)
            case let .assistant(text, _): return SavedItem(kind: "assistant", text: text)
            case let .tool(c):
                return SavedItem(kind: "tool", text: c.title, detail: c.detail, output: String(c.output.prefix(4000)),
                                 isError: c.isError)
            case .image: return nil
            case let .notice(text, isError): return SavedItem(kind: "notice", text: text, isError: isError)
            case let .summary(text): return SavedItem(kind: "summary", text: text)
            }
        }
        let chat = SavedChat(project: project.path, sessionId: sessions[.claude],
                             forkSession: forkSessions.contains(.claude) ? true : nil,
                             codexSessionId: sessions[.codex],
                             codexForkSession: forkSessions.contains(.codex) ? true : nil, items: saved)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(chat) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadConversation(_ project: URL) -> Conversation? {
        guard let data = try? Data(contentsOf: ProjectStore.chatURL(project)),
              let chat = try? JSONDecoder().decode(SavedChat.self, from: data) else { return nil }
        let items = chat.items.enumerated().compactMap { i, s -> Item? in
            switch s.kind {
            case "user": return Item(kind: .user(s.text, images: []))
            case "assistant": return Item(kind: .assistant(s.text, messageId: "saved-\(i)"))
            case "tool":
                return Item(kind: .tool(ToolCall(id: "saved-\(i)", title: s.text, detail: s.detail ?? "", isDone: true,
                                                 isError: s.isError ?? false, output: s.output ?? "")))
            case "notice": return Item(kind: .notice(s.text, isError: s.isError ?? false))
            case "summary": return Item(kind: .summary(s.text))
            default: return nil
            }
        }
        let copied = chat.project != project.path && ProjectStore.isProject(URL(fileURLWithPath: chat.project))
        var sessions: [AgentProvider: String] = [:]
        sessions[.claude] = chat.sessionId
        sessions[.codex] = chat.codexSessionId
        var forks = Set<AgentProvider>()
        if chat.sessionId != nil && (copied || chat.forkSession == true) { forks.insert(.claude) }
        if chat.codexSessionId != nil && (copied || chat.codexForkSession == true) { forks.insert(.codex) }
        return Conversation(items: items, sessionIds: sessions, forkSessions: forks)
    }

    /// Prefixed to every message so "this"/"here"/"now" resolve against the editor state.
    private func contextLine() -> String {
        let s = scene.scene
        let selected = scene.selectedLayer.map { "\($0.id) (\($0.type.rawValue))" } ?? "none"
        var ids = s.layers.map(\.id)
        if ids.count > 30 { ids = Array(ids.prefix(30)) + ["…"] }
        var project = ""
        if let p = scene.project {
            var folders = AssetLibrary.shared.folders
            if folders.count > 40 { folders = Array(folders.prefix(40)) + ["…"] }
            project = "; project=\(p.lastPathComponent) (assets go in its folders: \(folders.joined(separator: ", ")))"
        }
        return String(format: "[VeyMotion context: playhead=%.2fs; selected=%@; scene=%dx%d %dfps %.2fs; layers (bottom→top)=%@%@]",
                      scene.time, selected, s.width, s.height, s.fps, s.duration, ids.joined(separator: ", "), project)
    }

    // MARK: - Events

    private func handle(_ ev: AgentEvent) {
        switch ev {
        case let .started(sessionId, _):
            // A copied project's conversation has forked by now: later restarts resume the new session.
            forkSessions.remove(provider)
            if !sessionId.isEmpty { sessionIds[provider] = sessionId }

        case .thinking:
            if isBusy && activity != "Thinking…" { setActivity("Thinking…") }

        case let .toolInputProgress(name, bytes):
            guard isBusy else { break }
            let label = name == "Bash" ? "Writing command" : "Preparing \(name)"
            let size = bytes >= 1024 ? String(format: "%.1f KB", Double(bytes) / 1024) : "\(bytes) B"
            if bytes == 0 { setActivity("\(label)…") } else { activity = "\(label) (\(size))…" }

        case let .textDelta(messageId, text):
            activity = nil
            if case let .assistant(existing, id)? = items.last?.kind, id == messageId {
                items[items.count - 1].kind = .assistant(existing + text, messageId: id)
            } else {
                items.append(Item(kind: .assistant(text, messageId: messageId)))
            }
            bump()

        case let .text(messageId, text):
            append(.assistant(text, messageId: messageId))
            // Codex sends whole messages mid-turn and nothing while it writes the next tool call: keep the spinner.
            if isBusy { setActivity("Working…") } else { activity = nil }

        case let .toolUse(id, name, input):
            let call = describe(id: id, name: name, input: input)
            setActivity("Running \(call.title)…")
            append(.tool(call))

        case let .toolResult(toolUseId, output, isError, image):
            if let i = items.lastIndex(where: { if case let .tool(c) = $0.kind { return c.id == toolUseId }; return false }),
               case var .tool(call) = items[i].kind {
                call.isDone = true
                call.isError = isError
                call.output = output
                items[i].kind = .tool(call)
            }
            if let image, let ns = NSImage(data: image) {
                append(.image(ns, time: pendingRenderTime))
                pendingRenderTime = nil
            }
            if isBusy { setActivity("Thinking…") } else { activity = nil }
            bump()

        case let .turnFinished(isError, result, cost, ms):
            if isError, stderrTail.contains("No conversation found") {
                return // handled when the process exits (fresh-session retry)
            }
            isBusy = false
            activity = nil
            retriedFresh = false
            recordVersion()
            if isError {
                append(.notice(explainFailure(result ?? "\(provider.cliName) reported an error.", details: stderrTail),
                               isError: true))
            } else if case .authFailed = agentState {
                agentStates[provider] = .ready // signed in again
            }
            var parts: [String] = []
            if let ms { parts.append(String(format: "%.1fs", Double(ms) / 1000)) }
            if let cost, cost > 0 { parts.append(String(format: "$%.3f", cost)) }
            if !parts.isEmpty { append(.summary(parts.joined(separator: " · "))) }
            saveConversation()

        case let .stderr(s):
            stderrTail = String((stderrTail + s).suffix(2000))

        case .resumeFailed:
            resumeFailed = true

        case let .exited(code):
            let wasBusy = isBusy
            isBusy = false
            activity = nil
            // Resume failed (session file missing/unwritable): start a fresh session and resend once.
            if !stoppedByUser, resumeFailed || stderrTail.contains("No conversation found"), let text = lastSentText,
               !retriedFresh {
                retriedFresh = true
                resumeFailed = false
                agent?.reset()
                sessionIds[provider] = nil
                forkSessions.remove(provider)
                append(.notice("Couldn't resume the previous conversation, so a new one was started.", isError: false))
                isBusy = true
                setActivity("Thinking…")
                stderrTail = ""
                do { try agent?.send(contextLine() + "\n" + text, images: lastSentImages) } catch {
                    isBusy = false
                    activity = nil
                    append(.notice("Could not start \(provider.cliName): \(error.localizedDescription)", isError: true))
                }
                return
            }
            recordVersion()
            if !stoppedByUser && (code != 0 || wasBusy) {
                let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                append(.notice(explainFailure("\(provider.cliName) exited (code \(code)).\(detail.isEmpty ? "" : "\n" + detail)"),
                               isError: true))
            }
        }
    }

    private func describe(id: String, name: String, input: [String: Any]) -> ToolCall {
        // Codex calls the tools directly through MCP.
        let mcpPrefix = "mcp__veymotion__"
        if name.hasPrefix(mcpPrefix) {
            let tool = String(name.dropFirst(mcpPrefix.count))
            if tool == "render_frame" { pendingRenderTime = (input["time"] as? NSNumber)?.doubleValue }
            let args = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return ToolCall(id: id, title: tool.replacingOccurrences(of: "_", with: " "), detail: args == "{}" ? "" : args)
        }
        if name == "Shell", let cmd = input["command"] as? String {
            return ToolCall(id: id, title: "Shell", detail: cmd)
        }
        if name == "Bash", let cmd = input["command"] as? String {
            let trimmed = cmd.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("vmotion ") {
                let rest = trimmed.dropFirst("vmotion ".count)
                let sub = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "vmotion"
                var detail = rest.dropFirst(sub.count).trimmingCharacters(in: .whitespaces)
                if detail.hasPrefix("'") && detail.hasSuffix("'") && detail.count >= 2 {
                    detail = String(detail.dropFirst().dropLast())
                }
                if sub == "render_frame" || sub == "render-frame",
                   let obj = try? JSONSerialization.jsonObject(with: Data(detail.utf8)) as? [String: Any] {
                    pendingRenderTime = (obj["time"] as? NSNumber)?.doubleValue
                }
                return ToolCall(id: id, title: sub.replacingOccurrences(of: "_", with: " "), detail: detail)
            }
            return ToolCall(id: id, title: "Bash", detail: cmd)
        }
        if name == "Read", let path = input["file_path"] as? String {
            return ToolCall(id: id, title: "look at frame", detail: (path as NSString).lastPathComponent)
        }
        return ToolCall(id: id, title: name, detail: "")
    }

    /// Sets a new activity phase and restarts its elapsed-time clock.
    private func setActivity(_ text: String) {
        activity = text
        activityStart = Date()
    }

    private func append(_ kind: Kind) {
        items.append(Item(kind: kind))
        bump()
    }

    private func bump() { scrollToken &+= 1 }
}
