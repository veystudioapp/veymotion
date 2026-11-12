import AppKit
import Foundation
import Observation
import VeyMotionCore
import VeyMotionMCP

/// State of the embedded chat, run by Claude Code or the Codex CLI (`provider`). Claude edits the scene through the
/// `vmotion` CLI, Codex through `vmotion mcp`; both reach the app over the agent's own control socket, so every agent
/// change to the open project is live and undoable (`AgentSceneHost`; a turn still running when another project is
/// opened finishes on its own project's file).
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

    /// One conversation: its transcript, sessions and versions, and its agent while one runs. The shown one is
    /// `current`; the others are parked. A parked conversation whose turn was still running keeps working on its
    /// own project (its agent's socket then writes to that project's scene file) and lets its agent go when done.
    @Observable
    final class Session {
        var items: [Item] = []
        var input = ""
        var attachments: [Attachment] = []
        var isBusy = false
        var activity: String?
        var activityStart = Date()
        var scrollToken = 0
        /// Snapshots taken after each prompt that changed the scene, oldest first.
        fileprivate(set) var versions: [Version] = []
        /// The project's standing brief (look + fonts).
        var style = ChatStyle()

        /// The project it belongs to (nil = loose scene).
        @ObservationIgnored fileprivate var project: URL?
        /// Sessions the next agent of each provider resumes (when no process of it is running).
        @ObservationIgnored fileprivate var sessionIds: [AgentProvider: String] = [:]
        /// The conversation came from a copy of another project: these providers' first resume forks the session.
        @ObservationIgnored fileprivate var forkSessions: Set<AgentProvider> = []
        @ObservationIgnored fileprivate var agent: ChatAgent?
        /// The CLI `agent` runs.
        @ObservationIgnored fileprivate var agentProvider: AgentProvider = .claude
        /// The agents' own control socket, and the scene it serves (this conversation's project).
        @ObservationIgnored fileprivate var socket: ControlSocketServer?
        @ObservationIgnored fileprivate var host: AgentSceneHost?
        /// The prompt being worked on and the scene before it.
        @ObservationIgnored fileprivate var turnStart: (prompt: String, scene: MotionScene)?
        /// Design checks sent back to the agent since the last user message.
        @ObservationIgnored fileprivate var autoChecks = 0
        @ObservationIgnored fileprivate var stoppedByUser = false
        @ObservationIgnored fileprivate var stderrTail = ""
        @ObservationIgnored fileprivate var pendingRenderTime: Double?
        @ObservationIgnored fileprivate var lastSentText: String?
        @ObservationIgnored fileprivate var lastSentImages: [ClaudeCodeAgent.ImageAttachment] = []
        /// The context line sent with the last message (sent again when a fresh session has to be started).
        @ObservationIgnored fileprivate var lastContext = ""
        @ObservationIgnored fileprivate var needsRestart = false
        @ObservationIgnored fileprivate var retriedFresh = false
        @ObservationIgnored fileprivate var resumeFailed = false

        fileprivate init(project: URL?) { self.project = project }

        /// The conversation's sessions, including the running agent's latest one.
        fileprivate var currentSessions: [AgentProvider: String] {
            var s = sessionIds
            if let id = agent?.sessionId { s[agentProvider] = id }
            return s
        }

        fileprivate func append(_ kind: Kind) {
            items.append(Item(kind: kind))
            bump()
        }

        fileprivate func bump() { scrollToken &+= 1 }

        /// Sets a new activity phase and restarts its elapsed-time clock.
        fileprivate func setActivity(_ text: String) {
            activity = text
            activityStart = Date()
        }
    }

    /// The conversation shown: the open project's.
    private(set) var current: Session

    var items: [Item] { current.items }
    var input: String {
        get { current.input }
        set { current.input = newValue }
    }
    var attachments: [Attachment] {
        get { current.attachments }
        set { current.attachments = newValue }
    }
    var isBusy: Bool { current.isBusy }
    var activity: String? { current.activity }
    var activityStart: Date { current.activityStart }
    var scrollToken: Int { current.scrollToken }
    var versions: [Version] { current.versions }

    var model: String = UserDefaults.standard.string(forKey: ChatStore.settingKey("model", ChatStore.savedProvider)) ?? "" {
        didSet {
            UserDefaults.standard.set(model, forKey: Self.settingKey("model", provider))
            current.needsRestart = true // the next message restarts the process with the new model (session resumes)
        }
    }
    var effort: String = UserDefaults.standard.string(forKey: ChatStore.settingKey("effort", ChatStore.savedProvider)) ?? "" {
        didSet {
            UserDefaults.standard.set(effort, forKey: Self.settingKey("effort", provider))
            current.needsRestart = true
        }
    }
    private(set) var claudePath: String?
    private(set) var codexPath: String?
    private(set) var setupProblem: String?

    @ObservationIgnored private let scene: SceneStore
    /// Folders of files dragged into the chat, so the agent's Read can open them.
    @ObservationIgnored private var readDirectories: [String] = []

    /// The scene as one prompt left it. `prompt` is nil for the scene before the first prompt.
    struct Version: Identifiable, Codable {
        var id = UUID()
        var date = Date()
        var prompt: String?
        var scene: MotionScene
    }

    static let maxVersions = 100
    /// The project's standing brief: a look and a font pairing the agent follows without being told each time.
    struct ChatStyle: Codable, Equatable {
        /// `LookKind` raw value, nil = let the agent (or set_scene's auto look) choose.
        var look: String?
        /// A `fontPairings` title, nil = let the agent choose.
        var fonts: String?

        var isEmpty: Bool { look == nil && fonts == nil }
        var lookKind: LookKind? { look.flatMap(LookKind.init(rawValue:)) }
    }

    /// Title font + text font, with the mood they suit.
    struct FontPairing: Identifiable {
        var title: String
        var body: String
        var mood: String
        var id: String { "\(title) + \(body)" }
    }

    static let fontPairings: [FontPairing] = [
        FontPairing(title: "Be Vietnam Pro", body: "Inter", mood: "Modern, Vietnamese-ready"),
        FontPairing(title: "Playfair Display", body: "Inter", mood: "Elegant, editorial"),
        FontPairing(title: "Space Grotesk", body: "IBM Plex Sans", mood: "Tech, product"),
        FontPairing(title: "Montserrat", body: "Open Sans", mood: "Corporate, clean"),
        FontPairing(title: "Bebas Neue", body: "Roboto", mood: "Bold, poster, sport"),
        FontPairing(title: "Lora", body: "Source Sans 3", mood: "Warm, storytelling"),
    ]

    /// The shown conversation's brief, saved with it.
    var style: ChatStyle {
        get { current.style }
        set {
            guard newValue != current.style else { return }
            current.style = newValue
            saveConversation(current)
        }
    }

    /// After a turn that changed the scene, the design lint runs and (once per message) the findings are sent
    /// back to the agent to fix.
    var designCheckEnabled: Bool = UserDefaults.standard.object(forKey: "agent.designCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(designCheckEnabled, forKey: "agent.designCheck") }
    }

    /// Conversations of the projects opened earlier in this run, by project path ("" = loose scene).
    @ObservationIgnored private var parked: [String: Session] = [:]

    private init(scene: SceneStore) {
        self.scene = scene
        current = Session(project: scene.project)
        Self.removeStaleSockets()
        restoreConversation()
        scene.onProjectChange = { [weak self] change in self?.projectChanged(change) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.shutdown() }
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
                let s = self.current
                if p == self.provider, s.agent != nil { if s.isBusy { s.needsRestart = true } else { self.restartAgent(s) } }
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
            current.append(.notice("Could not open Terminal. Run this in Terminal yourself:\n\(commands)", isError: true))
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
                current.append(.notice(error.localizedDescription, isError: true))
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
                    if let error { self.current.append(.notice("Codex did not take the key: \(error)", isError: true)) }
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
    private func explainFailure(_ text: String, details: String = "", _ p: AgentProvider) -> String {
        switch AgentSetup.classify(text + "\n" + details) {
        case .auth?:
            agentStates[p] = .authFailed(text)
            return "\(p.cliName) could not sign in: its login or API key was refused or has expired.\n\(text)"
        case .limit?:
            let fix = p == .claude
                ? "Check your Claude plan's usage, or your Anthropic API credits."
                : "Check your ChatGPT plan's usage, or your OpenAI API credits."
            return "\(p.cliName) is out of credits or hit a usage limit. \(fix)\n\(text)"
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

    private func makeAgent(for s: Session, resume: String?) -> ChatAgent? {
        guard let dir = vmotionDirectory else { return nil }
        let work = ClaudeCodeAgent.Config.defaultWorkingDirectory
        let socket = socketPath(for: s)
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
                    "VEYMOTION_SOCKET": socket,
                ],
                unixSockets: [socket])
            cfg.effort = effort
            cfg.extraReadDirectories = readDirectories
            cfg.forkSession = s.forkSessions.contains(.claude)
            a = ClaudeCodeAgent(config: cfg, resumeSessionId: resume)
        case .codex:
            guard let codexPath else { return nil }
            var cfg = CodexAgent.Config(codexPath: codexPath, vmotionPath: "\(dir)/vmotion", workingDirectory: work,
                                        model: model, effort: effort, socketPath: socket)
            cfg.forkSession = s.forkSessions.contains(.codex)
            a = CodexAgent(config: cfg, resumeSessionId: resume)
        }
        s.agentProvider = provider
        // Events still queued from a replaced agent must not reach the conversation.
        a.onEvent = { [weak self, weak s, weak a] ev in
            DispatchQueue.main.async {
                guard let self, let s, let a, s.agent === a else { return }
                self.handle(ev, s)
            }
        }
        return a
    }

    /// Each conversation's agent reaches the app through a control socket of its own, whose host is bound to the
    /// conversation's project: when the user opens another project mid-turn, the agent keeps editing its own.
    /// Falls back to the app's socket (which follows the open document) if it cannot be opened.
    private func socketPath(for s: Session) -> String {
        if let sock = s.socket { return sock.path }
        let host = AgentSceneHost(store: scene, project: s.project)
        let server = MCPServer(host: host)
        server.log = { [weak self, weak s] line in
            DispatchQueue.main.async {
                guard let self, let s, s === self.current else { return }
                self.scene.lastAgentAction = line
            }
        }
        let path = Self.socketDirectory.appendingPathComponent("agent-\(UUID().uuidString.prefix(8)).sock").path
        let sock = ControlSocketServer(server: server, path: path)
        do { try sock.start() } catch { return ControlSocket.defaultPath }
        s.socket = sock
        s.host = host
        return path
    }

    private static var socketDirectory: URL { ControlSocket.supportDirectory }

    /// Agent sockets left behind by a run that did not quit normally.
    private static func removeStaleSockets() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: socketDirectory.path) else { return }
        for n in names where n.hasPrefix("agent-") && n.hasSuffix(".sock") {
            try? fm.removeItem(at: socketDirectory.appendingPathComponent(n))
        }
    }

    /// Ends the conversation's agent and its socket. The sessions stay, so the next message resumes them.
    private func dropAgent(_ s: Session) {
        s.sessionIds = s.currentSessions
        if let a = s.agent {
            a.onEvent = nil
            a.stop()
        }
        s.agent = nil
        s.socket?.stop()
        s.socket = nil
        s.host = nil
        s.needsRestart = false
    }

    private func shutdown() {
        for s in [current] + parked.values {
            saveConversation(s)
            dropAgent(s)
        }
    }

    // MARK: - Actions

    /// Not while the CLI is missing, logged out or still being checked: the setup card says what to do.
    var canSend: Bool {
        !isBusy && agentState.canSend && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send() {
        let s = current
        var text = s.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if s.needsRestart { restartAgent(s) }
        if s.agent == nil { s.agent = makeAgent(for: s, resume: s.sessionIds[provider]) }
        guard let agent = s.agent else {
            s.append(.notice(setupProblem ?? "\(provider.cliName) is not available.", isError: true))
            return
        }
        let sent = s.attachments
        if text.isEmpty { text = "(see the attached image\(sent.count == 1 ? "" : "s"))" }
        let images = sent.map { ClaudeCodeAgent.ImageAttachment(mediaType: $0.mediaType, data: $0.data) }
        let notes = sent.compactMap(\.note)
        let agentText = notes.isEmpty ? text : (notes + [text]).joined(separator: "\n")
        s.input = ""
        s.attachments = []
        s.append(.user(text, images: sent))
        s.isBusy = true
        s.stoppedByUser = false
        s.retriedFresh = false
        s.resumeFailed = false
        s.lastSentText = agentText
        s.lastSentImages = images
        s.lastContext = contextLine()
        s.stderrTail = ""
        s.autoChecks = 0
        s.setActivity("Thinking…")
        s.turnStart = (text, scene.scene)
        do {
            try agent.send(s.lastContext + "\n" + agentText, images: images)
        } catch {
            s.isBusy = false
            s.activity = nil
            s.turnStart = nil
            s.append(.notice("Could not start \(provider.cliName): \(error.localizedDescription)", isError: true))
        }
    }

    // MARK: - Versions

    /// Keeps the scene as the finished (or stopped) prompt left it, if the prompt changed it. `now` defaults to
    /// the conversation's scene: the open one, or its project's file once another project is open.
    private func recordVersion(_ s: Session, scene now: MotionScene? = nil) {
        guard let start = s.turnStart else { return }
        s.turnStart = nil
        guard let now = now ?? sceneNow(s), now != start.scene else { return }
        if s.versions.isEmpty { s.versions.append(Version(prompt: nil, scene: start.scene)) }
        s.versions.append(Version(prompt: start.prompt, scene: now))
        if s.versions.count > Self.maxVersions { s.versions.removeFirst(s.versions.count - Self.maxVersions) }
        saveVersions(s)
    }

    private func isOpen(_ s: Session) -> Bool { s.project?.standardizedFileURL.path == scene.project?.standardizedFileURL.path }

    private func sceneNow(_ s: Session) -> MotionScene? {
        if isOpen(s) { return scene.scene }
        return s.project.flatMap { try? ProjectStore.load($0) }
    }

    /// Puts a version's scene back (one undo step).
    func restore(_ version: Version) {
        var s = version.scene
        _ = s.refreshMediaInfo()
        scene.apply("Restore Version") { $0 = s }
    }

    private func saveVersions(_ s: Session) {
        guard let project = s.project else { return }
        let url = ProjectStore.versionsURL(project)
        guard !s.versions.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let saved = s.versions.map { v -> Version in
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
        if current.isBusy { current.needsRestart = true } else { restartAgent(current) }
    }

    /// Replaces the agent with one started with the current Read folders, resuming the same session (its socket
    /// stays). The old process is detached first so its exit is not reported as an error.
    private func restartAgent(_ s: Session) {
        s.needsRestart = false
        guard let old = s.agent else { return }
        let session = old.sessionId ?? s.sessionIds[s.agentProvider]
        old.onEvent = nil
        old.stop()
        s.agent = nil
        s.agent = makeAgent(for: s, resume: session)
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
        let s = current
        guard s.isBusy else { return }
        s.stoppedByUser = true
        s.agent?.stop()
        recordVersion(s)
        s.isBusy = false
        s.activity = nil
        s.append(.notice("Stopped. Your next message continues the same conversation.", isError: false))
    }

    func newChat() {
        let s = current
        recordVersion(s)
        s.stoppedByUser = true
        s.agent?.reset()
        s.agent = nil
        s.sessionIds = [:]
        s.forkSessions = []
        s.items = []
        s.attachments = []
        s.isBusy = false
        s.activity = nil
        saveConversation(s)
        s.bump()
    }

    // MARK: - Per-project conversations

    private func projectChanged(_ change: SceneStore.ProjectChange) {
        let s = current
        switch change {
        case let .opened(url):
            guard url?.path != s.project?.path else { return }
            parkConversation()
            current = Session(project: url)
            restoreConversation()
        case let .moved(from, to):
            // Same conversation, new place; Read's folders changed with it.
            s.project = to
            s.host?.project = to
            for i in s.versions.indices { s.versions[i].scene.replaceFolder(from.path, with: to.path) }
            if let start = s.turnStart {
                var scene = start.scene
                scene.replaceFolder(from.path, with: to.path)
                s.turnStart = (start.prompt, scene)
            }
            saveConversation(s)
            saveVersions(s)
            if s.isBusy { s.needsRestart = true } else { restartAgent(s) }
        case let .adopted(url):
            // The loose scene's conversation becomes the new project's.
            parked[""] = nil
            s.project = url
            s.host?.project = url
            saveConversation(s)
            saveVersions(s)
            if s.isBusy { s.needsRestart = true } else { restartAgent(s) }
        }
    }

    private static func key(_ project: URL?) -> String { project?.path ?? "" }

    /// Stores the shown conversation, in memory and in the project folder, before another project opens.
    /// A project's turn that is still running keeps going: its agent's socket now edits the project's scene file
    /// (SceneStore saved it just before), and the agent is let go when the turn ends. Otherwise the agent is
    /// stopped; the session resumes when the project is reopened. A loose scene's turn is stopped, since that
    /// scene exists only in the editor.
    private func parkConversation() {
        let s = current
        if s.isBusy, let project = s.project, s.agent != nil, s.host != nil {
            scene.message = "\(s.agentProvider.displayName) keeps working on \(project.lastPathComponent) in the background"
        } else {
            let wasBusy = s.isBusy
            dropAgent(s)
            recordVersion(s, scene: scene.scene) // the old document is still loaded
            if wasBusy {
                s.append(.notice("Stopped because you switched projects. Your next message here continues the conversation.",
                                 isError: false))
            }
            s.isBusy = false
            s.activity = nil
            s.pendingRenderTime = nil
        }
        saveConversation(s)
        parked[Self.key(s.project)] = s
    }

    /// A parked conversation's turn ended: keep the result and let its agent go.
    private func finishedInBackground(_ s: Session) {
        saveConversation(s)
        dropAgent(s)
        guard !s.stoppedByUser, let project = s.project else { return }
        scene.message = "\(s.agentProvider.displayName) finished working on \(project.lastPathComponent)"
    }

    private static let switchNoticePrefix = "Now chatting with "

    /// Switching CLIs: the old one's session is kept for when the user switches back.
    private func providerChanged(from old: AgentProvider) {
        let s = current
        UserDefaults.standard.set(provider.rawValue, forKey: "agent.provider")
        if let a = s.agent {
            if let id = a.sessionId { s.sessionIds[old] = id }
            a.onEvent = nil
            a.stop()
        }
        s.agent = nil
        model = UserDefaults.standard.string(forKey: Self.settingKey("model", provider)) ?? ""
        effort = UserDefaults.standard.string(forKey: Self.settingKey("effort", provider)) ?? ""
        s.needsRestart = false
        // Switching back and forth: keep only the latest of these notices.
        if case let .notice(text, _)? = s.items.last?.kind, text.hasPrefix(Self.switchNoticePrefix) { s.items.removeLast() }
        if s.items.contains(where: { if case .user = $0.kind { return true }; return false }) {
            s.append(.notice("\(Self.switchNoticePrefix)\(provider.displayName). \(old.displayName) and \(provider.displayName) keep "
                             + "separate conversations: \(provider.displayName) does not see the messages above, but it sees the scene.",
                             isError: false))
        }
        saveConversation(s)
    }

    /// Shows the open project's conversation (`current.project`): from this run if it was open before (still
    /// working, maybe), else from its folder.
    private func restoreConversation() {
        let project = current.project
        if let s = parked.removeValue(forKey: Self.key(project)) {
            current = s
        } else if let project {
            let s = Self.loadConversation(project) ?? Session(project: project)
            s.versions = Self.loadVersions(project)
            current = s
        }
        current.bump()
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
        var style: ChatStyle?
    }

    private struct SavedItem: Codable {
        var kind: String
        var text: String
        var detail: String?
        var output: String?
        var isError: Bool?
    }

    /// Writes a project's conversation to its folder (nothing for loose scenes).
    private func saveConversation(_ s: Session) {
        guard let project = s.project else { return }
        let url = ProjectStore.chatURL(project)
        let sessions = s.currentSessions
        guard !s.items.isEmpty || !sessions.isEmpty || !s.style.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let saved = s.items.suffix(500).compactMap { item -> SavedItem? in
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
                             forkSession: s.forkSessions.contains(.claude) ? true : nil,
                             codexSessionId: sessions[.codex],
                             codexForkSession: s.forkSessions.contains(.codex) ? true : nil, items: saved,
                             style: s.style.isEmpty ? nil : s.style)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(chat) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func loadConversation(_ project: URL) -> Session? {
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
        let s = Session(project: project)
        s.items = items
        s.sessionIds = sessions
        s.forkSessions = forks
        s.style = chat.style ?? ChatStyle()
        return s
    }

    /// The standing brief for the context line, or nil when nothing is set.
    private var styleLine: String? {
        var parts: [String] = []
        if let k = style.lookKind { parts.append("look \(k.rawValue) (apply_look \(k.rawValue) on a new scene; \(k.isLight ? "dark text" : "light text"))") }
        if let id = style.fonts, let p = Self.fontPairings.first(where: { $0.id == id }) {
            parts.append("fonts \"\(p.title)\" for titles + \"\(p.body)\" for the rest (import from Google Fonts with search_stock kind font + import_stock when not installed)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
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
        let design = s.layers.isEmpty ? "empty scene" : MotionScene.designSummary(s.designIssues(renderer: FrameRenderer()))
        let style = styleLine.map { "; style=\($0)" } ?? ""
        return String(format: "[VeyMotion context: playhead=%.2fs; selected=%@; scene=%dx%d %dfps %.2fs; layers (bottom→top)=%@%@; design=%@%@]",
                      scene.time, selected, s.width, s.height, s.fps, s.duration, ids.joined(separator: ", "), project, design, style)
    }

    /// After a turn that changed the scene: lint it and, once per user message, hand the findings back.
    /// Returns true when a follow-up was sent (the turn goes on). Only for the shown conversation: the context line
    /// describes the open editor.
    private func autoDesignCheck(_ s: Session) -> Bool {
        guard designCheckEnabled, s === current, s.autoChecks < 1, let start = s.turnStart, let agent = s.agent,
              !s.stoppedByUser else { return false }
        let now = scene.scene
        guard now != start.scene, !now.layers.isEmpty else { return false }
        let issues = now.designIssues(renderer: FrameRenderer()).filter { $0.severity >= .warning }
        guard !issues.isEmpty else { return false }
        s.autoChecks += 1
        let codes = issues.map(\.code).joined(separator: ", ")
        s.append(.notice("Design check: \(issues.count) finding\(issues.count == 1 ? "" : "s") (\(codes)). Asking \(s.agentProvider.displayName) to fix them.",
                         isError: false))
        let text = "[Design check after your changes]\n" + MotionScene.designReport(issues)
            + "\nFix these now (or say in one line why a finding is intended for this piece), render a frame to confirm, then reply briefly."
        s.isBusy = true
        s.setActivity("Fixing design…")
        s.lastSentText = text
        s.lastSentImages = []
        s.lastContext = contextLine()
        s.stderrTail = ""
        do { try agent.send(s.lastContext + "\n" + text, images: []) } catch {
            s.isBusy = false
            s.activity = nil
            s.append(.notice("Could not send the design check: \(error.localizedDescription)", isError: true))
            return false
        }
        return true
    }

    // MARK: - Events

    /// An event of `s`'s agent: `s` is the shown conversation, or a parked one still finishing its turn.
    private func handle(_ ev: AgentEvent, _ s: Session) {
        let p = s.agentProvider
        switch ev {
        case let .started(sessionId, _):
            // A copied project's conversation has forked by now: later restarts resume the new session.
            s.forkSessions.remove(p)
            if !sessionId.isEmpty { s.sessionIds[p] = sessionId }

        case .thinking:
            if s.isBusy && s.activity != "Thinking…" { s.setActivity("Thinking…") }

        case let .toolInputProgress(name, bytes):
            guard s.isBusy else { break }
            let label = name == "Bash" ? "Writing command" : "Preparing \(name)"
            let size = bytes >= 1024 ? String(format: "%.1f KB", Double(bytes) / 1024) : "\(bytes) B"
            if bytes == 0 { s.setActivity("\(label)…") } else { s.activity = "\(label) (\(size))…" }

        case let .textDelta(messageId, text):
            s.activity = nil
            if case let .assistant(existing, id)? = s.items.last?.kind, id == messageId {
                s.items[s.items.count - 1].kind = .assistant(existing + text, messageId: id)
            } else {
                s.items.append(Item(kind: .assistant(text, messageId: messageId)))
            }
            s.bump()

        case let .text(messageId, text):
            s.append(.assistant(text, messageId: messageId))
            // Codex sends whole messages mid-turn and nothing while it writes the next tool call: keep the spinner.
            if s.isBusy { s.setActivity("Working…") } else { s.activity = nil }

        case let .toolUse(id, name, input):
            let call = describe(id: id, name: name, input: input, s)
            s.setActivity("Running \(call.title)…")
            s.append(.tool(call))

        case let .toolResult(toolUseId, output, isError, image):
            if let i = s.items.lastIndex(where: { if case let .tool(c) = $0.kind { return c.id == toolUseId }; return false }),
               case var .tool(call) = s.items[i].kind {
                call.isDone = true
                call.isError = isError
                call.output = output
                s.items[i].kind = .tool(call)
            }
            if let image, let ns = NSImage(data: image) {
                s.append(.image(ns, time: s.pendingRenderTime))
                s.pendingRenderTime = nil
            }
            if s.isBusy { s.setActivity("Thinking…") } else { s.activity = nil }
            s.bump()

        case let .turnFinished(isError, result, cost, ms):
            if isError, s.stderrTail.contains("No conversation found") {
                return // handled when the process exits (fresh-session retry)
            }
            s.isBusy = false
            s.activity = nil
            s.retriedFresh = false
            if !isError, autoDesignCheck(s) { return }
            recordVersion(s)
            if isError {
                s.append(.notice(explainFailure(result ?? "\(p.cliName) reported an error.", details: s.stderrTail, p),
                                 isError: true))
            } else if case .authFailed = agentStates[p] {
                agentStates[p] = .ready // signed in again
            }
            var parts: [String] = []
            if let ms { parts.append(String(format: "%.1fs", Double(ms) / 1000)) }
            if let cost, cost > 0 { parts.append(String(format: "$%.3f", cost)) }
            if !parts.isEmpty { s.append(.summary(parts.joined(separator: " · "))) }
            saveConversation(s)
            if s !== current { finishedInBackground(s) }

        case let .stderr(text):
            s.stderrTail = String((s.stderrTail + text).suffix(2000))

        case .resumeFailed:
            s.resumeFailed = true

        case let .exited(code):
            let wasBusy = s.isBusy
            s.isBusy = false
            s.activity = nil
            // Resume failed (session file missing/unwritable): start a fresh session and resend once.
            if !s.stoppedByUser, s.resumeFailed || s.stderrTail.contains("No conversation found"), let text = s.lastSentText,
               !s.retriedFresh {
                s.retriedFresh = true
                s.resumeFailed = false
                s.agent?.reset()
                s.sessionIds[p] = nil
                s.forkSessions.remove(p)
                s.append(.notice("Couldn't resume the previous conversation, so a new one was started.", isError: false))
                s.isBusy = true
                s.setActivity("Thinking…")
                s.stderrTail = ""
                do { try s.agent?.send(s.lastContext + "\n" + text, images: s.lastSentImages) } catch {
                    s.isBusy = false
                    s.activity = nil
                    s.append(.notice("Could not start \(p.cliName): \(error.localizedDescription)", isError: true))
                    if s !== current { finishedInBackground(s) }
                }
                return
            }
            recordVersion(s)
            if !s.stoppedByUser && (code != 0 || wasBusy) {
                let detail = s.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                s.append(.notice(explainFailure("\(p.cliName) exited (code \(code)).\(detail.isEmpty ? "" : "\n" + detail)", p),
                                 isError: true))
            }
            if s !== current { finishedInBackground(s) }
        }
    }

    private func describe(id: String, name: String, input: [String: Any], _ s: Session) -> ToolCall {
        // Codex calls the tools directly through MCP.
        let mcpPrefix = "mcp__veymotion__"
        if name.hasPrefix(mcpPrefix) {
            let tool = String(name.dropFirst(mcpPrefix.count))
            if tool == "render_frame" { s.pendingRenderTime = (input["time"] as? NSNumber)?.doubleValue }
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
                    s.pendingRenderTime = (obj["time"] as? NSNumber)?.doubleValue
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

}
