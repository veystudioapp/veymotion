import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VeyMotionCore

/// Connected social accounts and the publish job. Uploads keep running when the sheet is closed.
@Observable
final class PublishStore {
    static let shared = PublishStore()

    enum Outcome {
        case done(PublishResult)
        case failed(String)
        case cancelled
    }

    private(set) var providers: [SocialPlatform: SocialServer.Provider] = [:]
    private(set) var providersLoaded = false
    private(set) var providersError: String?
    private(set) var accounts: [SocialPlatform: SocialAccount] = [:]
    private(set) var connecting: SocialPlatform?
    private(set) var connectError: (SocialPlatform, String)?
    private(set) var tiktokInfo: TikTokCreatorInfo?
    private(set) var tiktokInfoError: String?

    /// Non-nil while publishing (0…1).
    private(set) var progress: Double?
    private(set) var status = ""
    private(set) var publishing: SocialPlatform?
    private(set) var outcome: Outcome?
    /// The last exported video, offered by File > Publish Video….
    var lastExport: URL?

    @ObservationIgnored private var connectCancel: CancelFlag?
    @ObservationIgnored private var publishCancel: CancelFlag?

    /// Reads saved accounts from the keychain and asks the server which platforms it supports.
    func load(refresh: Bool = false) {
        for p in SocialPlatform.allCases { accounts[p] = SocialKeychain.load(p) }
        guard refresh || !providersLoaded else { return }
        providersError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SocialServer.providers(refresh: refresh) }
            DispatchQueue.main.async {
                self.providersLoaded = true
                switch result {
                case let .success(p): self.providers = p
                case let .failure(e): self.providersError = e.localizedDescription
                }
            }
        }
    }

    func isConfigured(_ p: SocialPlatform) -> Bool { providers[p]?.configured ?? false }

    /// Opens the platform's sign-in page in the browser and waits for the server to hand over the tokens.
    func connect(_ p: SocialPlatform) {
        cancelConnect()
        let cancel = CancelFlag()
        connectCancel = cancel
        connecting = p
        connectError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> SocialAccount in
                let connection = try SocialServer.beginConnect(p)
                guard !cancel.isSet else { throw PublishError("Connection cancelled") }
                let opened = DispatchQueue.main.sync { NSWorkspace.shared.open(connection.url) }
                guard opened else { throw PublishError("Could not open the browser for \(connection.url.absoluteString)") }
                return try SocialAuth.finishConnect(connection, isCancelled: { cancel.isSet })
            }
            DispatchQueue.main.async {
                guard self.connectCancel === cancel else { return }
                self.connecting = nil
                self.connectCancel = nil
                switch result {
                case let .success(a):
                    self.accounts[p] = a
                    if p == .tiktok { self.tiktokInfo = nil }
                    NSApp.activate(ignoringOtherApps: true)
                case let .failure(e):
                    if !cancel.isSet { self.connectError = (p, e.localizedDescription) }
                }
            }
        }
    }

    func cancelConnect() {
        connectCancel?.set()
        connectCancel = nil
        connecting = nil
    }

    func disconnect(_ p: SocialPlatform) {
        SocialAuth.disconnect(p)
        accounts[p] = nil
        if p == .tiktok { tiktokInfo = nil }
    }

    /// TikTok asks apps to show the creator's name and their allowed privacy options before a direct post.
    func loadTikTokInfo() {
        guard accounts[.tiktok] != nil else { return }
        tiktokInfoError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SocialPublisher.tiktokCreatorInfo() }
            DispatchQueue.main.async {
                switch result {
                case let .success(i): self.tiktokInfo = i
                case let .failure(e): self.tiktokInfoError = e.localizedDescription
                }
            }
        }
    }

    func publish(_ p: SocialPlatform, _ request: PublishRequest) {
        guard progress == nil else { return }
        let cancel = CancelFlag()
        publishCancel = cancel
        publishing = p
        outcome = nil
        progress = 0
        status = "Preparing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Outcome
            do {
                let r = try SocialPublisher.publish(p, request, isCancelled: { cancel.isSet }) { value, text in
                    DispatchQueue.main.async {
                        guard self.progress != nil else { return }
                        self.progress = value
                        self.status = text
                    }
                }
                outcome = .done(r)
            } catch {
                outcome = cancel.isSet ? .cancelled : .failed(error.localizedDescription)
            }
            DispatchQueue.main.async {
                self.progress = nil
                self.publishCancel = nil
                self.outcome = outcome
                // Tokens may have been refreshed during the upload.
                self.accounts[p] = SocialKeychain.load(p)
                switch outcome {
                case .done: SceneStore.shared.message = "Published to \(p.name)"
                case let .failed(m): SceneStore.shared.message = m
                case .cancelled: SceneStore.shared.message = "Publishing cancelled"
                }
            }
        }
    }

    func cancelPublish() { publishCancel?.set() }

    func clearOutcome() { if progress == nil { outcome = nil } }
}

/// File > Publish Video…: the publish form in its own sheet.
struct PublishSheet: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PublishView(file: PublishStore.shared.lastExport, suggested: nil, defaultTitle: store.defaultExportName,
                    onClose: { dismiss() })
            .padding(16)
            .frame(width: 500)
    }
}

/// Pick a platform, connect the account, fill in the post, and upload `file`.
struct PublishView: View {
    @State var file: URL?
    var suggested: SocialPlatform?
    var defaultTitle: String
    var onBack: (() -> Void)?
    var onClose: () -> Void

    @State private var publisher = PublishStore.shared
    @AppStorage("publish.platform") private var platform = SocialPlatform.youtube
    @AppStorage("publish.youtubePrivacy") private var youtubePrivacy = "private"
    @AppStorage("publish.tiktokMode") private var tiktokMode = PublishRequest.TikTokMode.draft
    @AppStorage("publish.facebookPage") private var facebookPage = ""
    @State private var title = ""
    @State private var caption = ""
    @State private var details = ""
    @State private var tags = ""
    @State private var tiktokPrivacy = ""
    @State private var allowComments = true
    @State private var allowDuet = true
    @State private var allowStitch = true

    init(file: URL?, suggested: SocialPlatform?, defaultTitle: String,
         onBack: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        _file = State(initialValue: file)
        self.suggested = suggested
        self.defaultTitle = defaultTitle
        self.onBack = onBack
        self.onClose = onClose
    }

    private var account: SocialAccount? { publisher.accounts[platform] }
    private var isBusy: Bool { publisher.progress != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Publish").font(.headline)
            fileRow
            platformPicker
            accountRow
            if account != nil, publisher.isConfigured(platform) {
                form
            }
            footer
        }
        .onAppear {
            publisher.load()
            publisher.clearOutcome()
            if let suggested { platform = suggested }
            if title.isEmpty { title = defaultTitle }
            if platform == .tiktok { publisher.loadTikTokInfo() }
        }
        .onChange(of: platform) { _, p in
            if p == .tiktok, publisher.tiktokInfo == nil { publisher.loadTikTokInfo() }
        }
        .onChange(of: publisher.accounts[.tiktok]?.accessToken) { _, _ in
            if platform == .tiktok { publisher.loadTikTokInfo() }
        }
    }

    // MARK: Rows

    private var fileRow: some View {
        HStack {
            Image(systemName: "film").foregroundStyle(.secondary)
            if let file {
                Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(fileSize(file)).foregroundStyle(.secondary)
            } else {
                Text("No video chosen").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") { chooseFile() }.disabled(isBusy)
        }
        .font(.callout)
    }

    private var platformPicker: some View {
        HStack(spacing: 8) {
            ForEach(SocialPlatform.allCases) { p in
                Button { platform = p } label: {
                    HStack(spacing: 6) {
                        SocialLogoView(platform: p, size: 16)
                        Text(p.name)
                        if publisher.accounts[p] != nil {
                            Circle().fill(.green).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(platform == p ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(platform == p ? Color.accentColor : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
            }
        }
    }

    /// Why Connect is unavailable for the selected platform (server unreachable / not configured), if it is.
    private var connectBlocker: String? {
        if !publisher.providersLoaded { return nil }
        if let e = publisher.providersError { return e }
        if !publisher.isConfigured(platform) {
            let key = "NITRO_SOCIAL_\(platform.rawValue.uppercased())"
            return "\(platform.name) is not set up on the VeyMotion server yet: add \(key)_CLIENT_ID and \(key)_CLIENT_SECRET to server/.env, restart the server (cd server && bun run dev), then press Retry."
        }
        return nil
    }

    @ViewBuilder
    private var accountRow: some View {
        HStack(spacing: 8) {
            if publisher.connecting == platform {
                ProgressView().controlSize(.small)
                Text("Finish signing in to \(platform.name) in your browser…")
                Spacer()
                Button("Cancel") { publisher.cancelConnect() }
            } else if let account {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Connected as \(account.displayName ?? platform.name)")
                Spacer()
                Button("Disconnect") { publisher.disconnect(platform) }.disabled(isBusy)
            } else {
                SocialLogoView(platform: platform, size: 16)
                Text("Not connected").foregroundStyle(.secondary)
                if !publisher.providersLoaded {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Connect \(platform.name)…") { publisher.connect(platform) }
                    .disabled(!publisher.providersLoaded || connectBlocker != nil)
                    .help(connectBlocker ?? "Opens the \(platform.name) sign-in page in your browser")
            }
        }
        .font(.callout)
        if account == nil, publisher.connecting != platform, let blocker = connectBlocker {
            HStack(alignment: .top) {
                Label(blocker, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Spacer()
                Button("Retry") { publisher.load(refresh: true) }.controlSize(.small)
            }
        }
        if let failure = publisher.connectError, failure.0 == platform {
            Text(failure.1).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    // MARK: Form

    @ViewBuilder
    private var form: some View {
        Form {
            switch platform {
            case .youtube:
                LimitedField("Title", text: $title, limit: platform.titleLimit)
                TextField("Description", text: $details, axis: .vertical).lineLimit(3...6)
                TextField("Tags", text: $tags, prompt: Text("comma, separated"))
                Picker("Visibility", selection: $youtubePrivacy) {
                    Text("Private").tag("private")
                    Text("Unlisted").tag("unlisted")
                    Text("Public").tag("public")
                }
                .pickerStyle(.segmented)
            case .tiktok:
                tiktokForm
            case .facebook:
                if let pages = account?.pages, !pages.isEmpty {
                    Picker("Page", selection: $facebookPage) {
                        if !pages.contains(where: { $0.id == facebookPage }) { Text("Choose a Page").tag("") }
                        ForEach(pages) { Text($0.name).tag($0.id) }
                    }
                }
                LimitedField("Title", text: $title, limit: platform.titleLimit)
                TextField("Description", text: $details, axis: .vertical).lineLimit(3...6)
            case .x:
                LimitedField("Post", text: $caption, limit: platform.titleLimit, multiline: true)
            }
        }
        .formStyle(.grouped)
        .disabled(isBusy)
        if let hint = platformHint { Text(hint).font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder
    private var tiktokForm: some View {
        let canDirect = account?.hasScope("video.publish") ?? false
        Picker("Mode", selection: $tiktokMode) {
            Text("Send to TikTok inbox").tag(PublishRequest.TikTokMode.draft)
            Text("Post directly").tag(PublishRequest.TikTokMode.direct)
        }
        .pickerStyle(.segmented)
        .onChange(of: canDirect, initial: true) { _, ok in if !ok { tiktokMode = .draft } }
        .disabled(!canDirect)
        if tiktokMode == .direct {
            if let info = publisher.tiktokInfo {
                LabeledContent("Posting as", value: info.username.map { "\(info.nickname) (@\($0))" } ?? info.nickname)
                LimitedField("Caption", text: $caption, limit: SocialPlatform.tiktok.titleLimit, multiline: true)
                Picker("Who can view", selection: $tiktokPrivacy) {
                    if !info.privacyOptions.contains(tiktokPrivacy) { Text("Choose…").tag("") }
                    ForEach(info.privacyOptions, id: \.self) { Text(tiktokPrivacyName($0)).tag($0) }
                }
                Toggle("Allow comments", isOn: $allowComments).disabled(info.commentDisabled)
                Toggle("Allow Duet", isOn: $allowDuet).disabled(info.duetDisabled)
                Toggle("Allow Stitch", isOn: $allowStitch).disabled(info.stitchDisabled)
            } else if let e = publisher.tiktokInfoError {
                Text(e).foregroundStyle(.red).font(.caption)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var platformHint: String? {
        switch platform {
        case .youtube:
            return "Vertical videos up to 3 minutes become Shorts. Apps that Google has not verified can only upload private videos."
        case .tiktok:
            if tiktokMode == .draft { return "The video goes to your TikTok inbox; open the TikTok app to add a caption and post it." }
            return "By posting, you agree to TikTok's Music Usage Confirmation. Apps TikTok has not audited can only post as Only me."
        case .facebook:
            return "Facebook only allows posting to Pages through its API, not to personal profiles."
        case .x:
            return "X accepts MP4 videos up to 2:20 and 512 MB."
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let p = publisher.progress {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: p)
                HStack {
                    Text("\(publisher.publishing?.name ?? ""): \(publisher.status)").font(.caption)
                    Spacer()
                    Text("\(Int(p * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } else if let outcome = publisher.outcome {
            switch outcome {
            case let .done(r):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Published to \(r.platform.name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    if let note = r.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            case let .failed(m):
                Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled)
            case .cancelled:
                Label("Publishing cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
            }
        }
        if let problem = fileProblem, account != nil, !isBusy {
            Text(problem).font(.caption).foregroundStyle(.orange)
        }
        HStack {
            if let onBack { Button("Back") { onBack() }.disabled(isBusy) }
            Spacer()
            if isBusy {
                Button("Hide") { onClose() }
                Button("Stop", role: .destructive) { publisher.cancelPublish() }.keyboardShortcut(.cancelAction)
            } else {
                if case let .done(r)? = publisher.outcome, let url = r.url {
                    Button("Open Post") { NSWorkspace.shared.open(url) }
                }
                Button("Close") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Publish to \(platform.name)") { publish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canPublish)
            }
        }
    }

    // MARK: Actions

    private var fileProblem: String? {
        guard let file else { return "Choose a video to publish." }
        if !platform.accepts(file) { return "\(platform.name) needs an MP4 file\(platform == .x ? "" : " or MOV"). Export as MP4 — H.264." }
        return nil
    }

    private var canPublish: Bool {
        guard account != nil, publisher.isConfigured(platform), fileProblem == nil, publisher.connecting == nil else { return false }
        switch platform {
        case .youtube: return !title.trimmingCharacters(in: .whitespaces).isEmpty && title.count <= platform.titleLimit
        case .tiktok:
            guard tiktokMode == .direct else { return true }
            return publisher.tiktokInfo?.privacyOptions.contains(tiktokPrivacy) ?? false
                && caption.count <= platform.titleLimit
        case .facebook: return account?.pages?.contains { $0.id == facebookPage } ?? false
        case .x: return caption.count <= platform.titleLimit
        }
    }

    private func publish() {
        guard let file else { return }
        var r = PublishRequest(file: file, title: platform == .tiktok || platform == .x ? caption : title)
        r.description = details
        r.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        r.youtubePrivacy = youtubePrivacy
        r.tiktokMode = tiktokMode
        r.tiktokPrivacy = tiktokPrivacy.isEmpty ? nil : tiktokPrivacy
        r.disableComments = !allowComments
        r.disableDuet = !allowDuet
        r.disableStitch = !allowStitch
        r.facebookPageId = facebookPage
        publisher.publish(platform, r)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        if let file { panel.directoryURL = file.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        file = url
        publisher.lastExport = url
        publisher.clearOutcome()
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter().string(fromByteCount: Int64(bytes))
    }

    private func tiktokPrivacyName(_ v: String) -> String {
        switch v {
        case "PUBLIC_TO_EVERYONE": return "Everyone"
        case "MUTUAL_FOLLOW_FRIENDS": return "Friends"
        case "FOLLOWER_OF_CREATOR": return "Followers"
        case "SELF_ONLY": return "Only me"
        default: return v
        }
    }
}

/// A text field with a character counter that turns red over the limit.
private struct LimitedField: View {
    var label: String
    @Binding var text: String
    var limit: Int
    var multiline = false

    init(_ label: String, text: Binding<String>, limit: Int, multiline: Bool = false) {
        self.label = label
        _text = text
        self.limit = limit
        self.multiline = multiline
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if multiline {
                TextField(label, text: $text, axis: .vertical).lineLimit(2...5)
            } else {
                TextField(label, text: $text)
            }
            Text("\(text.count)/\(limit)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(text.count > limit ? Color.red : Color.secondary)
        }
    }
}
