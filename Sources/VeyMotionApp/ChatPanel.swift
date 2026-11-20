import AppKit
import SwiftUI
import VeyMotionMCP

/// The chat column's toolbar items (it has no header bar of its own; who you talk to shows in the composer's model
/// picker): Versions, then New conversation.
struct ChatToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { VersionsToolbarButton() }
        ToolbarItem(placement: .primaryAction) { NewChatToolbarButton() }
    }
}

/// On macOS 26 a scroll view runs on under the toolbar, its items floating over the messages; a hard edge stops
/// the messages at the toolbar instead.
private struct HardTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        // Needs the macOS 26 SDK (SwiftUI 7); older SDKs (Command Line Tools 14.4) build without it.
        #if canImport(SwiftUI, _version: 7.0)
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct VersionsToolbarButton: View {
    @State private var showVersions = false

    var body: some View {
        Button { showVersions.toggle() } label: { Label("Versions", systemImage: "clock.arrow.circlepath") }
            .help("The scene after each prompt")
            .popover(isPresented: $showVersions, arrowEdge: .bottom) { VersionsPopover() }
    }
}

private struct NewChatToolbarButton: View {
    @Environment(ChatStore.self) private var chat

    var body: some View {
        Button { chat.newChat() } label: { Label("New Conversation", systemImage: "square.and.pencil") }
            .help("New conversation")
    }
}

struct ChatPanel: View {
    @Environment(ChatStore.self) private var chat

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.items.isEmpty { EmptyChatHint() }
                        if let problem = chat.setupProblem { NoticeView(text: problem, isError: true) }
                        ForEach(chat.items) { item in ChatItemView(item: item) }
                        if let activity = chat.activity {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(activity).font(.caption).foregroundStyle(.secondary)
                                // Elapsed time for the current phase, so long steps never look frozen.
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    let s = Int(ctx.date.timeIntervalSince(chat.activityStart))
                                    if s >= 3 {
                                        Text(s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .modifier(HardTopEdge())
                .onChange(of: chat.scrollToken) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                // The editor (and this panel) is created after the project's transcript loads, so its scroll
                // request is missed; start at the latest message. The lazy stack only estimates rows it has not
                // drawn, so the first jump lands short: repeat once the rows near the bottom are measured.
                .task {
                    for ms in [0, 60, 200] {
                        guard (try? await Task.sleep(for: .milliseconds(ms))) != nil else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            Divider()
            if chat.agentState != .ready {
                AgentSetupCard()
                Divider()
            }
            ChatComposer()
        }
    }
}

/// What to do when the chat's CLI is missing, logged out or was refused: install or log in through Terminal,
/// paste an API key, check again, or switch to the other CLI.
private struct AgentSetupCard: View {
    @Environment(ChatStore.self) private var chat
    @State private var enteringKey = false
    @State private var key = ""

    private var provider: AgentProvider { chat.provider }
    private var other: AgentProvider { provider == .claude ? .codex : .claude }

    var body: some View {
        Group {
            switch chat.agentState {
            case .ready:
                EmptyView()
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking \(provider.cliName)…").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            case .missing:
                card(title: "\(provider.cliName) isn't installed",
                     text: provider == .claude
                        ? "The chat runs on Claude Code, with your Claude plan (Pro, Max, Ultra, Team, Enterprise), a Claude Console account or an Anthropic API key."
                        : "The chat runs on the Codex CLI, with your ChatGPT plan or an OpenAI API key.",
                     command: AgentSetup.installCommand(provider)) {
                    Button("Install in Terminal") { chat.openSetupInTerminal(install: true) }
                        .buttonStyle(.borderedProminent)
                    checkAgain
                }
            case .loggedOut:
                card(title: "Log in to \(provider.cliName)",
                     text: "\(provider.cliName) is installed but not logged in. Log in with your "
                        + (provider == .claude ? "Claude account" : "ChatGPT account") + ", or use an API key.") {
                    loginButtons
                }
            case let .authFailed(detail):
                card(title: "\(provider.cliName) couldn't sign in",
                     text: "Its login or API key was refused or has expired. Log in again or use another API key.",
                     detail: detail) {
                    loginButtons
                }
            }
        }
        .padding(12)
        .onChange(of: provider) { enteringKey = false; key = "" }
    }

    private func card<Buttons: View>(title: String, text: String, command: String? = nil, detail: String? = nil,
                                     @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AgentLogo(provider: provider, size: 14)
                Text(title).font(.callout.weight(.semibold))
            }
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.isEmpty {
                Text(detail.prefix(300)).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(3).textSelection(.enabled)
            }
            if let command {
                Text(command).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            }
            if enteringKey {
                keyField
            } else {
                HStack(spacing: 8) { buttons() }.controlSize(.small)
            }
            if chat.agentStates[other] == .ready {
                Button("Use \(other.displayName) instead") { chat.provider = other }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25)))
    }

    @ViewBuilder private var loginButtons: some View {
        Button("Log In in Terminal") { chat.openSetupInTerminal(install: false) }
            .buttonStyle(.borderedProminent)
        Button("Use API Key…") { enteringKey = true }
        checkAgain
        if provider == .claude, AnthropicKeyStore.hasKey {
            Button("Forget Key") { chat.forgetAnthropicKey() }
                .help("Remove the Anthropic API key saved in VeyMotion")
        }
    }

    private var checkAgain: some View {
        Button("Check Again") { chat.detect(provider) }
            .help("VeyMotion also checks again when you come back from Terminal")
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(provider == .claude ? "Anthropic API key (sk-ant-…)" : "OpenAI API key (sk-…)", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack(spacing: 8) {
                Button("Save", action: save).buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { enteringKey = false; key = "" }
                Spacer(minLength: 0)
                Link("Get a key", destination: URL(string: provider == .claude
                    ? "https://platform.claude.com/settings/keys"
                    : "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            }
            .controlSize(.small)
            Text(provider == .claude
                 ? "Kept in your Keychain and used instead of your Claude account login."
                 : "Saved by the Codex CLI (`codex login --with-api-key`).")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func save() {
        chat.useAPIKey(key)
        key = ""
        enteringKey = false
    }
}

private struct EmptyChatHint: View {
    @Environment(ChatStore.self) private var chat

    @Environment(SceneStore.self) private var store

    /// Prompts to click: the first ones build something from nothing, the last ones change what is there.
    private var examples: [String] {
        let w = store.scene.width, h = store.scene.height
        let vertical = h > w
        return store.scene.layers.isEmpty
            ? [vertical ? "Make a 15-second TikTok ad for a coffee brand: three selling points, one per beat, price at the end"
                        : "Make a 6-second logo intro for a coffee brand called Nắng Coffee, warm and premium",
               "A 20-second explainer with three statistics that count up, then a bar chart comparing them",
               "A lyric video section: four lines, each on screen about 4 seconds, dreamy night-city mood"]
            : ["Add a lower third with my name and title at 1 s",
               "Make the title arrive with more weight and add a whoosh on it",
               "Make everything 20% faster and end on a clean hold"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.scene.layers.isEmpty ? "Describe the video you want, or try one of these:" : "Describe a change, or try one of these:")
                .font(.callout)
            ForEach(examples, id: \.self) { prompt in
                Button {
                    chat.input = prompt
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right").font(.caption2).padding(.top, 2)
                        Text(prompt).multilineTextAlignment(.leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Puts this in the composer; press Return to send it")
            }
            if !store.scene.layers.isEmpty {
                Text("Click something in the preview first, and “this” in your message means that layer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            Text(chat.provider == .claude
                 ? "Claude uses your Claude Code login and can only run `vmotion` commands."
                 : "Codex uses your Codex CLI login, edits only through VeyMotion's tools, and its shell is read-only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}

private struct ChatItemView: View {
    @Environment(SceneStore.self) private var store
    let item: ChatStore.Item

    var body: some View {
        switch item.kind {
        case let .user(text, images):
            VStack(alignment: .trailing, spacing: 4) {
                if !images.isEmpty {
                    HStack(spacing: 4) {
                        Spacer(minLength: 30)
                        ForEach(images.indices, id: \.self) { i in
                            Image(nsImage: images[i].image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: images.count == 1 ? 200 : 90, maxHeight: images.count == 1 ? 160 : 90)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .bottomLeading) {
                                    if let t = images[i].time { FrameTimeBadge(time: t).padding(4) }
                                }
                        }
                    }
                }
                HStack {
                    Spacer(minLength: 30)
                    Text(text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        case let .assistant(text, _):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .text(t):
                        Text(markdown(t)).textSelection(.enabled)
                    case let .table(header, rows):
                        ChatTable(header: header, rows: rows, markdown: markdown)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .tool(call):
            ToolCallView(call: call)
        case let .image(image, time):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .overlay(alignment: .bottomTrailing) {
                    if let time {
                        Text(String(format: "%.2fs", time))
                            .font(.caption2.monospaced())
                            .padding(3)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                }
                .onTapGesture { if let time { store.seek(time) } }
                .help(time == nil ? "" : "Jump to this frame")
        case let .notice(text, isError):
            NoticeView(text: text, isError: isError)
        case let .summary(text):
            Text(text).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Assistant text split into plain runs and GitHub-style tables, which inline-only Markdown prints as raw pipes.
enum ChatMarkdown {
    enum Block: Equatable {
        case text(String)
        case table(header: [String], rows: [[String]])
    }

    static func blocks(_ s: String) -> [Block] {
        let lines = s.components(separatedBy: "\n")
        var out: [Block] = []
        var text: [String] = []
        func flushText() {
            let t = text.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !t.isEmpty { out.append(.text(t)) }
            text = []
        }
        var i = 0
        while i < lines.count {
            if i + 1 < lines.count, lines[i].contains("|"), isSeparator(lines[i + 1]) {
                let header = cells(lines[i])
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    var r = cells(lines[i])
                    if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                    rows.append(Array(r.prefix(header.count)))
                    i += 1
                }
                flushText()
                out.append(.table(header: header, rows: rows))
            } else {
                text.append(lines[i])
                i += 1
            }
        }
        flushText()
        return out
    }

    /// `|---|:--:|` (outer pipes optional).
    static func isSeparator(_ line: String) -> Bool {
        let parts = cells(line)
        return !parts.isEmpty && parts.allSatisfy { p in
            let core = p.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private struct ChatTable: View {
    let header: [String]
    let rows: [[String]]
    let markdown: (String) -> AttributedString

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(header.indices, id: \.self) { c in
                    cell(header[c]).fontWeight(.semibold)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(Color.primary.opacity(0.06))
                }
            }
            ForEach(rows.indices, id: \.self) { r in
                Divider()
                GridRow {
                    ForEach(rows[r].indices, id: \.self) { c in cell(rows[r][c]) }
                }
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    private func cell(_ s: String) -> some View {
        Text(markdown(s))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolCallView: View {
    let call: ChatStore.ToolCall
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Group {
                        if !call.isDone {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: call.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(call.isError ? Color.red : Color.green)
                        }
                    }
                    .frame(width: 14)
                    Text(call.title).font(.caption.weight(.medium))
                    Text(call.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if !call.detail.isEmpty {
                        Text(call.detail).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !call.output.isEmpty {
                        Divider()
                        Text(call.output.prefix(4000))
                            .font(.caption.monospaced())
                            .foregroundStyle(call.isError ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct NoticeView: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? Color.orange : Color.secondary)
            Text(text).font(.caption).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.orange : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
