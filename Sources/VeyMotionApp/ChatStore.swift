import AppKit
import Foundation
import Observation
import VeyMotionCore
import VeyMotionMCP

/// State of the embedded Claude Code chat. Claude edits the scene through the `vmotion` CLI,
/// which reaches `SceneStore` over the control socket, so every agent change is live and undoable.
@Observable
final class ChatStore {
    struct ToolCall {
        var id: String
        var title: String
        var detail: String
        var isDone = false
        var isError = false
        var output = ""
    }

    enum Kind {
        case user(String, images: [NSImage])
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
    }

    /// Used until (or if) `claude` has answered which models it offers.
    static let fallbackModels: [ClaudeCodeAgent.ModelInfo] = [
        .init(value: "", resolvedModel: nil, displayName: "Default (recommended)", description: "", efforts: efforts),
        .init(value: "opus", resolvedModel: nil, displayName: "Opus", description: "", efforts: efforts),
        .init(value: "sonnet", resolvedModel: nil, displayName: "Sonnet", description: "", efforts: efforts),
        .init(value: "haiku", resolvedModel: nil, displayName: "Haiku", description: "", efforts: []),
    ]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// The models the user's `claude` offers; the CLI's `default` is stored as "" (no `--model`).
    var models: [ClaudeCodeAgent.ModelInfo] = ChatStore.fallbackModels

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
    var modelEfforts: [String] { selectedModel?.efforts ?? Self.efforts }

    var items: [Item] = []
    var input = ""
    var attachments: [Attachment] = []
    var isBusy = false
    var activity: String?
    var activityStart = Date()
    var scrollToken = 0
    var model: String = UserDefaults.standard.string(forKey: "agent.model") ?? "" {
        didSet {
            UserDefaults.standard.set(model, forKey: "agent.model")
            needsRestart = true // the next message restarts the process with the new model (session resumes)
        }
    }
    var effort: String = UserDefaults.standard.string(forKey: "agent.effort") ?? "" {
        didSet {
            UserDefaults.standard.set(effort, forKey: "agent.effort")
            needsRestart = true
        }
    }
    private(set) var claudePath: String?
    private(set) var setupProblem: String?

    @ObservationIgnored private let scene: SceneStore
    @ObservationIgnored private var agent: ClaudeCodeAgent?
    @ObservationIgnored private var stoppedByUser = false
    @ObservationIgnored private var stderrTail = ""
    @ObservationIgnored private var pendingRenderTime: Double?
    @ObservationIgnored private var lastSentText: String?
    @ObservationIgnored private var lastSentImages: [ClaudeCodeAgent.ImageAttachment] = []
    /// Folders of files dragged into the chat, so the agent's Read can open them.
    @ObservationIgnored private var readDirectories: [String] = []
    @ObservationIgnored private var needsRestart = false
    @ObservationIgnored private var retriedFresh = false

    init(scene: SceneStore) {
        self.scene = scene
        DispatchQueue.global(qos: .utility).async {
            let path = ClaudeCodeAgent.locateClaude()
            DispatchQueue.main.async { self.claudePath = path; self.checkSetup() }
            guard let path, let models = ClaudeCodeAgent.supportedModels(
                claudePath: path, workingDirectory: ClaudeCodeAgent.Config.defaultWorkingDirectory) else { return }
            let mapped = models.map { m -> ClaudeCodeAgent.ModelInfo in
                var m = m
                if m.value == "default" { m.value = "" }
                return m
            }
            DispatchQueue.main.async { self.models = mapped }
        }
    }

    // MARK: - Setup

    private var vmotionDirectory: String? {
        let fm = FileManager.default
        var dirs: [String] = []
        if let d = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent().path { dirs.append(d) }
        if let d = ProcessInfo.processInfo.environment["VEYMOTION_CLI_DIR"] { dirs.insert(d, at: 0) }
        return dirs.first { fm.isExecutableFile(atPath: "\($0)/vmotion") }
    }

    private func checkSetup() {
        if claudePath == nil {
            setupProblem = "Claude Code (`claude`) was not found. Install it, run `claude` once in Terminal to log in, then reopen VeyMotion."
        } else if vmotionDirectory == nil {
            setupProblem = "The `vmotion` CLI was not found next to the app. Build everything with `swift build` (or `bash scripts/bundle.sh`)."
        } else {
            setupProblem = nil
        }
    }

    private func makeAgent() -> ClaudeCodeAgent? {
        checkSetup()
        guard let claudePath, let dir = vmotionDirectory else { return nil }
        let work = ClaudeCodeAgent.Config.defaultWorkingDirectory
        let config = ClaudeCodeAgent.Config(
            claudePath: claudePath,
            vmotionDirectory: dir,
            workingDirectory: work,
            model: model,
            extraEnvironment: [
                "VEYMOTION_FRAMES_DIR": work.appendingPathComponent("frames").path,
                "VEYMOTION_SOCKET": ControlSocket.defaultPath,
            ])
        var cfg = config
        cfg.effort = effort
        cfg.extraReadDirectories = readDirectories
        let a = ClaudeCodeAgent(config: cfg)
        a.onEvent = { [weak self] ev in DispatchQueue.main.async { self?.handle(ev) } }
        return a
    }

    // MARK: - Actions

    var canSend: Bool {
        !isBusy && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send() {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        if needsRestart { restartAgent() }
        if agent == nil { agent = makeAgent() }
        guard let agent else {
            append(.notice(setupProblem ?? "Claude Code is not available.", isError: true))
            return
        }
        let sent = attachments
        if text.isEmpty { text = "(see the attached image\(sent.count == 1 ? "" : "s"))" }
        let images = sent.map { ClaudeCodeAgent.ImageAttachment(mediaType: $0.mediaType, data: $0.data) }
        input = ""
        attachments = []
        append(.user(text, images: sent.map(\.image)))
        isBusy = true
        stoppedByUser = false
        retriedFresh = false
        lastSentText = text
        lastSentImages = images
        stderrTail = ""
        setActivity("Thinking…")
        do {
            try agent.send(contextLine() + "\n" + text, images: images)
        } catch {
            isBusy = false
            activity = nil
            append(.notice("Could not start Claude Code: \(error.localizedDescription)", isError: true))
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
        let session = old.sessionId
        old.onEvent = nil
        old.stop()
        agent = makeAgent()
        if let session, let fresh = agent {
            agent = ClaudeCodeAgent(config: fresh.config, resumeSessionId: session)
            agent?.onEvent = fresh.onEvent
        }
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
        isBusy = false
        activity = nil
        append(.notice("Stopped. Your next message continues the same conversation.", isError: false))
    }

    func newChat() {
        stoppedByUser = true
        agent?.reset()
        agent = nil
        items = []
        attachments = []
        isBusy = false
        activity = nil
        bump()
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
        case .started:
            break

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
            activity = nil
            append(.assistant(text, messageId: messageId))

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
            if isError {
                append(.notice(result ?? "Claude Code reported an error.", isError: true))
            }
            var parts: [String] = []
            if let ms { parts.append(String(format: "%.1fs", Double(ms) / 1000)) }
            if let cost, cost > 0 { parts.append(String(format: "$%.3f", cost)) }
            if !parts.isEmpty { append(.summary(parts.joined(separator: " · "))) }

        case let .stderr(s):
            stderrTail = String((stderrTail + s).suffix(2000))

        case let .exited(code):
            let wasBusy = isBusy
            isBusy = false
            activity = nil
            // Resume failed (session file missing/unwritable): start a fresh session and resend once.
            if !stoppedByUser, stderrTail.contains("No conversation found"), let text = lastSentText, !retriedFresh {
                retriedFresh = true
                agent?.reset()
                append(.notice("Couldn't resume the previous conversation, so a new one was started.", isError: false))
                isBusy = true
                setActivity("Thinking…")
                stderrTail = ""
                do { try agent?.send(contextLine() + "\n" + text, images: lastSentImages) } catch {
                    isBusy = false
                    activity = nil
                    append(.notice("Could not start Claude Code: \(error.localizedDescription)", isError: true))
                }
                return
            }
            if !stoppedByUser && (code != 0 || wasBusy) {
                let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                append(.notice("Claude Code exited (code \(code)).\(detail.isEmpty ? "" : "\n" + detail)", isError: true))
            }
        }
    }

    private func describe(id: String, name: String, input: [String: Any]) -> ToolCall {
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
