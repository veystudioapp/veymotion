import AppKit
import CryptoKit
import Observation
import SwiftUI
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
    /// Every connected account (YouTube channel, TikTok / X / Facebook user) per platform.
    private(set) var accounts: [SocialPlatform: [SocialAccount]] = [:]
    /// The account each platform posts with (`SocialAccount.key`), remembered across launches.
    private(set) var activeKeys: [SocialPlatform: String] = Dictionary(uniqueKeysWithValues: SocialPlatform.allCases.compactMap { p in
        UserDefaults.standard.string(forKey: "publish.account.\(p.rawValue)").map { (p, $0) }
    })
    private(set) var connecting: SocialPlatform?
    private(set) var connectError: (SocialPlatform, String)?
    private(set) var tiktokInfo: TikTokCreatorInfo?
    private(set) var tiktokInfoError: String?

    /// Non-nil while the preview video renders (0…1).
    private(set) var preparing: Double?
    /// The rendered video for the preview and upload.
    private(set) var prepared: URL?
    private(set) var prepareError: String?
    /// Non-nil while publishing (0…1).
    private(set) var progress: Double?
    private(set) var status = ""
    private(set) var publishing: SocialPlatform?
    private(set) var outcome: Outcome?

    @ObservationIgnored private var connectCancel: CancelFlag?
    @ObservationIgnored private var publishCancel: CancelFlag?
    @ObservationIgnored private var prepareCancel: CancelFlag?
    /// The last scene render, reused while the scene (and its media files) are unchanged, e.g. to publish
    /// the same video to several platforms in a row.
    @ObservationIgnored private var rendered: (key: String, url: URL)?

    /// Reads saved accounts from the keychain and asks the server which platforms it supports.
    func load(refresh: Bool = false) {
        for p in SocialPlatform.allCases { reloadAccounts(p) }
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

    /// The account `p` posts with: the one chosen last, else the first connected.
    func account(_ p: SocialPlatform) -> SocialAccount? {
        let list = accounts[p] ?? []
        return list.first { $0.key == activeKeys[p] } ?? list.first
    }

    /// Switches the posting account (no sign-in needed: its tokens are in the keychain).
    func select(_ account: SocialAccount) {
        activeKeys[account.platform] = account.key
        UserDefaults.standard.set(account.key, forKey: "publish.account.\(account.platform.rawValue)")
        if account.platform == .tiktok { tiktokInfo = nil; loadTikTokInfo() }
    }

    private func reloadAccounts(_ p: SocialPlatform) {
        accounts[p] = SocialKeychain.accounts(p)
    }

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
                    self.reloadAccounts(p)
                    self.select(a) // a newly added account becomes the one to post with
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

    func disconnect(_ account: SocialAccount) {
        let p = account.platform
        SocialAuth.disconnect(account)
        reloadAccounts(p)
        if activeKeys[p] == account.key {
            activeKeys[p] = nil
            UserDefaults.standard.removeObject(forKey: "publish.account.\(p.rawValue)")
        }
        if p == .tiktok { tiktokInfo = nil; loadTikTokInfo() }
    }

    /// TikTok asks apps to show the creator's name and their allowed privacy options before a direct post.
    func loadTikTokInfo() {
        guard let key = account(.tiktok)?.key else { return }
        tiktokInfoError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SocialPublisher.tiktokCreatorInfo(account: key) }
            DispatchQueue.main.async {
                switch result {
                case let .success(i): self.tiktokInfo = i
                case let .failure(e): self.tiktokInfoError = e.localizedDescription
                }
            }
        }
    }

    /// Renders `scene` to an MP4 for the preview (and then the upload), or reuses the last render when the
    /// scene and its media are unchanged. Progress is on `preparing`; the file ends up in `prepared`.
    func prepare(scene: MotionScene, options: ExportOptions, name: String) {
        cancelPrepare()
        prepareError = nil
        let key = try? Self.renderKey(scene, options: options)
        if let key, let r = rendered, r.key == key, FileManager.default.fileExists(atPath: r.url.path) {
            prepared = r.url
            return
        }
        prepared = nil
        preparing = 0
        let cancel = CancelFlag()
        prepareCancel = cancel
        let clearing = rendered == nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> URL in
                let url = try Self.renderURL(name, clearing: clearing)
                try VideoExporter.export(scene, to: url, options: options, isCancelled: { cancel.isSet }) { v in
                    DispatchQueue.main.async { if self.prepareCancel === cancel { self.preparing = v } }
                }
                return url
            }
            DispatchQueue.main.async {
                guard self.prepareCancel === cancel else {
                    if case let .success(url) = result { try? FileManager.default.removeItem(at: url) }
                    return
                }
                self.preparing = nil
                self.prepareCancel = nil
                switch result {
                case let .success(url):
                    if let old = self.rendered?.url, old != url { try? FileManager.default.removeItem(at: old) }
                    self.rendered = (key ?? UUID().uuidString, url)
                    self.prepared = url
                case let .failure(e):
                    self.prepareError = cancel.isSet ? nil : e.localizedDescription
                }
            }
        }
    }

    func cancelPrepare() {
        prepareCancel?.set()
        prepareCancel = nil
        preparing = nil
    }

    /// Uploads `request.file` (an export, or the render from `prepare`) with the platform's active account.
    func publish(_ p: SocialPlatform, _ request: PublishRequest) {
        guard progress == nil, let accountKey = account(p)?.key else { return }
        let cancel = CancelFlag()
        publishCancel = cancel
        publishing = p
        outcome = nil
        progress = 0
        status = "Preparing…"
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Outcome
            do {
                let r = try SocialPublisher.publish(p, account: accountKey, request, isCancelled: { cancel.isSet }) { value, text in
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
                self.reloadAccounts(p)
                switch outcome {
                case .done: SceneStore.shared.message = "Published to \(p.name)"
                case let .failed(m): SceneStore.shared.message = m
                case .cancelled: SceneStore.shared.message = "Publishing cancelled"
                }
            }
        }
    }

    func cancelPublish() { publishCancel?.set() }

    /// "Auto" quality: the best that keeps the file under the platform's limit.
    static func autoQuality(_ base: ExportOptions, scene: MotionScene, platform: SocialPlatform) -> ExportOptions {
        var o = base
        for q in [ExportQuality.high, .medium, .low] {
            o.quality = q
            if (o.estimatedBytes(for: scene) ?? 0) < platform.maxBytes * 9 / 10 { break }
        }
        return o
    }

    /// Identifies a render: the scene JSON, the media files' modification dates, and the render options.
    private static func renderKey(_ scene: MotionScene, options o: ExportOptions) throws -> String {
        var data = try SceneJSON.encode(scene, pretty: false)
        for path in Set(scene.layers.compactMap(\.path)).sorted() {
            let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
            data.append(Data("\(path)|\(date?.timeIntervalSince1970 ?? 0)".utf8))
        }
        let size = o.pixelSize(for: scene)
        data.append(Data("\(size.width)x\(size.height)|\(o.fit.rawValue)|\(o.quality.rawValue)|\(o.start ?? -1)|\(o.end ?? -1)".utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// ~/Library/Caches/VeyMotion/publish/<name>.mp4 (platforms show the file name in some places).
    /// `clearing` removes renders left over from earlier sessions.
    private static func renderURL(_ name: String, clearing: Bool) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VeyMotion/publish", isDirectory: true)
        if clearing { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return dir.appendingPathComponent("\(safe.isEmpty ? "VeyMotion" : safe)-\(UUID().uuidString.prefix(6)).mp4")
    }

    func clearOutcome() { if progress == nil { outcome = nil } }
}

/// File > Publish Video…: the publish form in its own sheet.
struct PublishSheet: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PublishView(file: nil, suggested: nil, defaultTitle: store.defaultExportName, onClose: { dismiss() })
            .padding(16)
            .frame(width: 560)
    }
}

/// Pick a platform, connect the account, fill in the post, and upload: `file` when given (right after an
/// export), otherwise the current scene, rendered to MP4 when you press Publish.
struct PublishView: View {
    @Environment(SceneStore.self) private var store
    var file: URL?
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
    @State private var claudeNotes = ""
    @State private var claudeWriting = false
    @State private var claudeError: String?
    /// Showing the rendered video and the post mock-up, with the final Publish button.
    @State private var previewing = false
    /// Thumbnail / TikTok cover: a frame (seconds into the video), or a custom image for YouTube / Facebook.
    @State private var thumbTime = 0.0
    @State private var thumbFile: URL?
    @State private var thumbImage: CGImage?
    @State private var thumbGeneration = 0
    // Render options (rendering the scene only; an exported file is uploaded as it is).
    /// A `PlatformPreset` id, or "" for the scene's own size.
    @AppStorage("publish.preset") private var presetId = ""
    @AppStorage("publish.fit") private var fit = ExportFit.fit
    /// An `ExportQuality` raw value, or "auto" (the best that fits the platform's size limit).
    @AppStorage("publish.quality") private var qualityRaw = "auto"
    @State private var useRange = false
    @State private var rangeStart = 0.0
    @State private var rangeEnd = 0.0
    private static let thumbQueue = DispatchQueue(label: "veymotion.publish.thumbnail", qos: .userInitiated)

    init(file: URL?, suggested: SocialPlatform?, defaultTitle: String,
         onBack: (() -> Void)? = nil, onClose: @escaping () -> Void) {
        self.file = file
        self.suggested = suggested
        self.defaultTitle = defaultTitle
        self.onBack = onBack
        self.onClose = onClose
    }

    private var account: SocialAccount? { publisher.account(platform) }
    private var isBusy: Bool { publisher.progress != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if previewing {
                Text("Preview — \(platform.name)").font(.headline)
                PostPreview(post: previewPost, video: file ?? publisher.prepared, preparing: publisher.preparing,
                            error: publisher.prepareError, thumbnail: platform == .x ? nil : thumbImage,
                            aspect: outputAspect, duration: outputDuration)
            } else {
                Text("Publish").font(.headline)
                fileRow
                platformPicker
                accountRow
                if account != nil, publisher.isConfigured(platform) {
                    form
                }
            }
            footer
        }
        .onAppear {
            publisher.load()
            publisher.clearOutcome()
            if let suggested { platform = suggested }
            if title.isEmpty { title = defaultTitle }
            if platform == .tiktok { publisher.loadTikTokInfo() }
            rangeEnd = store.scene.duration
            if file == nil { thumbTime = min(store.time, store.scene.duration) }
            refreshThumbnail()
        }
        .onChange(of: thumbTime) { _, _ in refreshThumbnail() }
        .onChange(of: thumbFile) { _, _ in refreshThumbnail() }
        .onChange(of: presetId) { _, _ in refreshThumbnail() }
        .onChange(of: fit) { _, _ in refreshThumbnail() }
        .onChange(of: useRange) { _, _ in clampThumbTime() }
        .onChange(of: rangeStart) { _, _ in clampThumbTime() }
        .onChange(of: rangeEnd) { _, _ in clampThumbTime() }
        .onChange(of: platform) { _, p in
            if p == .tiktok, publisher.tiktokInfo == nil { publisher.loadTikTokInfo() }
        }
        .onChange(of: publisher.account(.tiktok)?.key) { _, _ in
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
                let (w, h) = videoOptions.pixelSize(for: store.scene)
                Text(defaultTitle).lineLimit(1).truncationMode(.middle)
                Text("\(w)×\(h) · \(PlatformPreset.formatDuration(outputDuration)) · rendered when you preview")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
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
                        if !(publisher.accounts[p] ?? []).isEmpty {
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
                Text("Post as").foregroundStyle(.secondary)
                accountMenu(account)
                Spacer()
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

    /// Pick which connected account / channel posts, add another, or disconnect one.
    private func accountMenu(_ current: SocialAccount) -> some View {
        let all = publisher.accounts[platform] ?? []
        return Menu {
            Section(platform == .youtube ? "Channels" : "Accounts") {
                ForEach(all, id: \.key) { a in
                    Button { publisher.select(a) } label: {
                        if a.key == current.key {
                            Label(accountLabel(a), systemImage: "checkmark")
                        } else {
                            Text(accountLabel(a))
                        }
                    }
                }
            }
            Divider()
            Button(platform == .youtube ? "Add Channel…" : "Add Account…") { publisher.connect(platform) }
                .disabled(connectBlocker != nil)
            Menu("Disconnect") {
                ForEach(all, id: \.key) { a in
                    Button(accountLabel(a)) { publisher.disconnect(a) }
                }
            }
        } label: {
            Text(accountLabel(current)).fontWeight(.medium)
        }
        .fixedSize()
        .disabled(isBusy)
        .help(platform == .youtube
              ? "Switch channels without signing in again. Add Channel… lets you pick another channel or Brand Account in Google's chooser."
              : "Switch accounts without signing in again, or add another one.")
    }

    private func accountLabel(_ a: SocialAccount) -> String {
        let name = a.displayName ?? a.userId ?? platform.name
        if platform == .facebook, let pages = a.pages, !pages.isEmpty {
            return "\(name) (\(pages.count) Page\(pages.count == 1 ? "" : "s"))"
        }
        return name
    }

    // MARK: Form

    @ViewBuilder
    private var form: some View {
        Form {
            claudeRow
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
                thumbnailRow
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
                thumbnailRow
            case .x:
                LimitedField("Post", text: $caption, limit: platform.titleLimit, multiline: true)
            }
            if file == nil { videoSection }
        }
        .formStyle(.grouped)
        .disabled(isBusy)
        if let hint = platformHint { Text(hint).font(.caption).foregroundStyle(.secondary) }
    }

    /// Drafts the fields below with Claude, from the scene's text, voice-over and media names.
    @ViewBuilder
    private var claudeRow: some View {
        HStack(spacing: 8) {
            ClaudeLogo(size: 14)
            TextField("Write with Claude", text: $claudeNotes,
                      prompt: Text("Notes for Claude (optional), e.g. “mention the release on Friday”"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit { writeWithClaude() }
            if claudeWriting {
                ProgressView().controlSize(.small)
            } else {
                Button(hasCopy ? "Rewrite" : "Write with Claude") { writeWithClaude() }
                    .help("Claude drafts the \(platform == .tiktok || platform == .x ? "caption" : "title, description and tags") from the video's text, voice-over and media")
            }
        }
        if let claudeError {
            Text(claudeError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    /// Whether the fields Claude would fill already have the user's own text.
    private var hasCopy: Bool {
        switch platform {
        case .youtube, .facebook: return !details.isEmpty || (title != defaultTitle && !title.isEmpty)
        case .tiktok, .x: return !caption.isEmpty
        }
    }

    private func writeWithClaude() {
        guard !claudeWriting else { return }
        claudeWriting = true
        claudeError = nil
        let scene = store.scene, name = defaultTitle, p = platform, notes = claudeNotes
        let draft = PublishCopy(title: title, description: details,
                                tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                                caption: caption)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try PublishCopywriter.write(scene: scene, name: name, platform: p, draft: draft, notes: notes) }
            DispatchQueue.main.async {
                claudeWriting = false
                switch result {
                case let .success(c):
                    switch p {
                    case .youtube, .facebook:
                        if !c.title.isEmpty { title = c.title }
                        if !c.description.isEmpty { details = c.description }
                        if p == .youtube, !c.tags.isEmpty { tags = c.tags.joined(separator: ", ") }
                    case .tiktok, .x:
                        if !c.caption.isEmpty { caption = c.caption }
                    }
                case let .failure(e):
                    claudeError = e.localizedDescription
                }
            }
        }
    }

    /// Size, framing, quality and time range of the render, as in the Export sheet.
    @ViewBuilder
    private var videoSection: some View {
        let scene = store.scene
        Section("Video") {
            Picker("Size", selection: $presetId) {
                Text("Scene — \(scene.width)×\(scene.height)").tag("")
                Divider()
                ForEach(PlatformPreset.all) { p in
                    Text("\(p.name) — \(p.width)×\(p.height) (\(p.aspectLabel))").tag(p.id)
                }
            }
            if videoOptions.isReframed(for: scene) {
                Picker("Framing", selection: $fit) {
                    Text("Fit — whole scene, with bars").tag(ExportFit.fit)
                    Text("Fill — crop the edges").tag(ExportFit.fill)
                }
            }
            Picker("Quality", selection: $qualityRaw) {
                Text("Auto — best under \(platform.name)'s size limit").tag("auto")
                Divider()
                Text("Low").tag(ExportQuality.low.rawValue)
                Text("Medium").tag(ExportQuality.medium.rawValue)
                Text("High").tag(ExportQuality.high.rawValue)
                Text("Maximum").tag(ExportQuality.max.rawValue)
            }
            Toggle("Only part of the scene", isOn: $useRange)
            if useRange {
                HStack {
                    TextField("From", value: $rangeStart, format: .number.precision(.fractionLength(0...2))).frame(width: 70)
                    Text("–")
                    TextField("To", value: $rangeEnd, format: .number.precision(.fractionLength(0...2))).frame(width: 70)
                    Text("s").foregroundStyle(.secondary)
                    Spacer()
                    Button("Playhead → From") { rangeStart = store.time }.controlSize(.small)
                }
            }
        }
    }

    /// What the scene is rendered with: MP4 at the chosen size / framing / quality / range.
    private var videoOptions: ExportOptions {
        let scene = store.scene
        var o = ExportOptions(format: .mp4, size: PlatformPreset.named(presetId)?.size, fit: fit, quality: .high,
                              start: useRange ? rangeStart : nil, end: useRange ? rangeEnd : nil)
        if let q = ExportQuality(rawValue: qualityRaw) {
            o.quality = q
        } else {
            o = PublishStore.autoQuality(o, scene: scene, platform: platform)
        }
        return o
    }

    private var rangeValid: Bool { file != nil || !useRange || (rangeStart >= 0 && rangeEnd > rangeStart) }

    /// Scene seconds where the video starts (the range start).
    private var videoStart: Double { file == nil && useRange ? max(0, rangeStart) : 0 }

    private var outputDuration: Double {
        guard file == nil else { return store.scene.duration }
        return Double(videoOptions.frameRange(for: store.scene).count) / Double(store.scene.fps)
    }

    private var outputAspect: Double {
        let (w, h) = file == nil ? videoOptions.pixelSize(for: store.scene) : (store.scene.width, store.scene.height)
        return Double(w) / Double(max(h, 1))
    }

    private func clampThumbTime() {
        let lo = videoStart, hi = videoStart + outputDuration
        if thumbTime < lo || thumbTime > hi { thumbTime = lo } else { refreshThumbnail() }
    }

    /// Thumbnail (YouTube, Facebook) or cover frame (TikTok direct posts): a frame picked with the slider,
    /// or (not TikTok) an image file.
    @ViewBuilder
    private var thumbnailRow: some View {
        let cover = platform == .tiktok
        LabeledContent(cover ? "Cover" : "Thumbnail") {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if let thumbFile, !cover {
                        Text(thumbFile.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                    } else {
                        Slider(value: $thumbTime, in: videoStart...max(videoStart + outputDuration, videoStart + 0.1))
                        Text("Frame at \(String(format: "%.1f", thumbTime))s").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Button("Playhead") { thumbFile = nil; thumbTime = min(max(store.time, videoStart), videoStart + outputDuration) }
                            .help("Use the frame at the playhead")
                        if !cover {
                            Button("Image…") { chooseThumbnail() }.help("Use an image file (JPEG or PNG, 1280×720 works best)")
                            if thumbFile != nil { Button("Use Frame") { thumbFile = nil } }
                        }
                    }
                    .controlSize(.small)
                }
                thumbBox.frame(width: 120, height: 68)
            }
        }
    }

    private var thumbBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.black)
            if let thumbImage {
                Image(decorative: thumbImage, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Renders the thumbnail off the main thread; only the latest request is shown.
    private func refreshThumbnail() {
        thumbGeneration += 1
        let generation = thumbGeneration
        let scene = store.scene, t = thumbTime, custom = thumbFile, video = file, options = videoOptions
        Self.thumbQueue.async {
            let image = custom.flatMap { PublishThumbnail.image(at: $0) }
                ?? (video.map { PublishThumbnail.frame(ofVideo: $0, at: t) }
                    ?? PublishThumbnail.frame(of: scene, at: t, options: options))
            DispatchQueue.main.async {
                if generation == thumbGeneration { thumbImage = image }
            }
        }
    }

    private func chooseThumbnail() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        thumbFile = url
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
                thumbnailRow
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
            return "X accepts MP4 videos up to 2:20 and 512 MB. X does not let apps set a thumbnail."
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
        if account != nil, !isBusy {
            ForEach([fileProblem].compactMap { $0 } + limitWarnings, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        HStack {
            if previewing {
                Button("Edit") {
                    publisher.cancelPrepare()
                    publisher.clearOutcome()
                    previewing = false
                }
                .disabled(isBusy)
            } else if let onBack {
                Button("Back") { onBack() }.disabled(isBusy)
            }
            Spacer()
            if isBusy {
                Button("Hide") { onClose() }
                Button("Stop", role: .destructive) { publisher.cancelPublish() }.keyboardShortcut(.cancelAction)
            } else {
                if case let .done(r)? = publisher.outcome, let url = r.url {
                    Button("Open Post") { NSWorkspace.shared.open(url) }
                }
                Button("Close") { publisher.cancelPrepare(); onClose() }.keyboardShortcut(.cancelAction)
                if !previewing {
                    Button("Preview…") { startPreview() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canPublish)
                } else if !published {
                    Button("Publish to \(platform.name)") { publish() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canPublish || (file ?? publisher.prepared) == nil)
                }
            }
        }
    }

    // MARK: Actions

    private var fileProblem: String? {
        if let file, !platform.accepts(file) {
            return "\(platform.name) needs an MP4 file\(platform == .x ? "" : " or MOV"). Export as MP4 — H.264."
        }
        return nil
    }

    /// Platform limits the video breaks (too long, too big), from the scene or the file.
    private var limitWarnings: [String] {
        let scene = store.scene
        guard let preset = PlatformPreset.matching(platform, scene: scene) else { return [] }
        if file != nil { return [] }
        var out = preset.warnings(for: scene, duration: outputDuration, estimatedBytes: nil)
        if !rangeValid { out.append("The time range is empty: “To” must be after “From”.") }
        // Auto quality already lowers the quality to fit; warn only if the chosen (or lowest) one is too big.
        let bytes = videoOptions.estimatedBytes(for: scene) ?? 0
        if bytes > platform.maxBytes {
            let fmt = ByteCountFormatter()
            out.append("The video will be about \(fmt.string(fromByteCount: bytes)); \(platform.name) accepts up to \(fmt.string(fromByteCount: platform.maxBytes)).")
        }
        return out
    }

    private var canPublish: Bool {
        guard account != nil, publisher.isConfigured(platform), fileProblem == nil, publisher.connecting == nil,
              rangeValid else { return false }
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

    /// The post was just published from this preview (hide Publish so it is not posted twice by accident).
    private var published: Bool {
        if case let .done(r)? = publisher.outcome { return r.platform == platform }
        return false
    }

    private func startPreview() {
        publisher.clearOutcome()
        previewing = true
        if file == nil { publisher.prepare(scene: store.scene, options: videoOptions, name: defaultTitle) }
    }

    private var previewPost: PostPreview.Post {
        let name = account?.displayName ?? platform.name
        let audience: String
        switch platform {
        case .youtube: audience = youtubePrivacy.capitalized
        case .tiktok: audience = tiktokMode == .draft ? "Draft" : tiktokPrivacyName(tiktokPrivacy)
        case .facebook: audience = account?.pages?.first { $0.id == facebookPage }?.name ?? ""
        case .x: audience = "Everyone"
        }
        let page = account?.pages?.first { $0.id == facebookPage }?.name
        return PostPreview.Post(
            platform: platform,
            account: platform == .facebook ? (page ?? name) : platform == .tiktok ? (publisher.tiktokInfo?.username ?? name) : name,
            audience: audience, title: title, description: details,
            tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            caption: caption, tiktokDraft: platform == .tiktok && tiktokMode == .draft)
    }

    private func publish() {
        guard let video = file ?? publisher.prepared else { return }
        var r = PublishRequest(file: video, title: platform == .tiktok || platform == .x ? caption : title)
        switch platform {
        case .youtube, .facebook: r.thumbnail = thumbImage.flatMap(PublishThumbnail.jpeg)
        case .tiktok: r.coverTime = tiktokMode == .direct ? max(0, thumbTime - videoStart) : nil
        case .x: break
        }
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
