import AppKit
import CryptoKit
import Observation
import VeyMotionCore

/// Keeps the app up to date from the releases the VeyMotion server lists (`GET /api/app/latest`).
///
/// It checks shortly after launch and then every few hours. A newer version is downloaded (a zip of
/// "Vey Motion.app"), unpacked under Application Support and checked (bundle id, version, signature, SHA-256)
/// before it is offered. A ready update is installed when the app quits — or right away with "Restart to Update" —
/// by a small shell script that waits for this process to exit, swaps the bundle and (on restart) reopens it.
/// Swapping needs a bundled app in a folder the user can write to; otherwise the update is only offered as a
/// download.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        case downloading(AppRelease, progress: Double)
        /// Downloaded and verified; installs on quit.
        case ready(AppRelease)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date

    var autoCheck: Bool = UserDefaults.standard.object(forKey: Keys.autoCheck) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: Keys.autoCheck)
            scheduleChecks()
        }
    }

    /// Download new versions in the background and install them when the app quits.
    var autoInstall: Bool = UserDefaults.standard.object(forKey: Keys.autoInstall) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoInstall, forKey: Keys.autoInstall)
            if autoInstall, case let .available(r) = state, installBlockedReason == nil { download(r) }
        }
    }

    var release: AppRelease? {
        switch state {
        case let .available(r), let .downloading(r, _), let .ready(r): r
        default: nil
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading: true
        default: false
        }
    }

    /// Why this copy cannot replace itself, or nil when it can.
    let installBlockedReason: String? = Updater.blockedReason()

    private enum Keys {
        static let autoCheck = "update.autoCheck"
        static let autoInstall = "update.autoInstall"
        static let lastChecked = "update.lastChecked"
    }

    private static let checkInterval: TimeInterval = 6 * 3600
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var stagedApp: URL?
    @ObservationIgnored private var relaunchAfterInstall = false

    private init() {}

    // MARK: - Checking

    /// Called once at launch.
    func start() {
        // Whatever is left in the staging folder was installed already or abandoned.
        try? FileManager.default.removeItem(at: Self.stagingRoot)
        scheduleChecks()
    }

    private func scheduleChecks() {
        timer?.invalidate()
        timer = nil
        guard autoCheck else { return }
        let due = lastChecked.map { max(5, Self.checkInterval - Date().timeIntervalSince($0)) } ?? 5
        timer = Timer.scheduledTimer(withTimeInterval: due, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.check(userInitiated: false)
                self?.scheduleChecks()
            }
        }
    }

    /// Asks the server for the newest version. A user-initiated check reports its result in an alert.
    func check(userInitiated: Bool) {
        switch state {
        case .checking: return
        case .downloading, .ready:
            if userInitiated { presentAlert() }
            return
        default: break
        }
        state = .checking
        Task {
            let result = await Task.detached(priority: .utility) { Result { try AppRelease.latest() } }.value
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
            switch result {
            case let .failure(error):
                state = .failed(error.localizedDescription)
            case let .success(r):
                if AppVersion.isNewer(r.version), r.supportsThisMac {
                    state = .available(r)
                    if autoInstall, installBlockedReason == nil { download(r) }
                } else {
                    state = .upToDate
                }
            }
            if userInitiated { presentAlert() }
        }
    }

    // MARK: - Downloading

    func download(_ r: AppRelease) {
        guard downloadTask == nil else { return }
        state = .downloading(r, progress: 0)
        downloadTask = Task {
            defer { downloadTask = nil }
            do {
                let zip = try await Downloader.download(r.url) { p in
                    Task { @MainActor in
                        if case .downloading(let cur, _) = self.state, cur == r { self.state = .downloading(r, progress: p) }
                    }
                }
                let app = try await Task.detached(priority: .utility) { try Self.stage(zip, release: r) }.value
                stagedApp = app
                state = .ready(r)
            } catch is CancellationError {
                state = .available(r)
            } catch {
                state = .failed("Could not download \(r.version): \(error.localizedDescription)")
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Unzips into the staging folder and checks that it is a sound copy of this app at the promised version.
    nonisolated private static func stage(_ zip: URL, release r: AppRelease) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: zip) }
        if let expected = r.sha256?.lowercased(), !expected.isEmpty {
            let digest = try SHA256.hash(data: Data(contentsOf: zip, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw UpdateError("The download is damaged (checksum mismatch).") }
        }
        let dir = stagingRoot.appendingPathComponent(r.version, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path], "Could not unpack the update")

        guard let app = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
            let info = Bundle(url: app)?.infoDictionary
        else { throw UpdateError("The download does not contain the app.") }
        let id = info["CFBundleIdentifier"] as? String
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        guard id == Bundle.main.bundleIdentifier else { throw UpdateError("The download is a different app (\(id ?? "unknown")).") }
        guard AppVersion.compare(version, r.version) == .orderedSame else {
            throw UpdateError("The download is version \(version), not \(r.version).")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], "The update's signature is invalid")
        return app
    }

    // MARK: - Installing

    /// Quits now and installs; the new version opens when done.
    func restartToUpdate() {
        guard case .ready = state else { return }
        let store = SceneStore.shared
        if store.exportProgress != nil, !confirm("An export is running.", "Restarting stops it. Restart anyway?") { return }
        if store.project == nil, store.isDirty,
           !confirm("The scene has unsaved changes.", "Save it first, or the changes are lost when the app restarts. Restart anyway?") {
            return
        }
        relaunchAfterInstall = true
        NSApp.terminate(nil)
    }

    /// Called from `applicationWillTerminate`: hands a ready update to a script that swaps the bundle once this
    /// process has exited.
    func installOnQuit() {
        guard case .ready = state, let staged = stagedApp, installBlockedReason == nil,
              FileManager.default.fileExists(atPath: staged.path) else { return }
        let dest = Bundle.main.bundleURL.standardizedFileURL
        let script = """
        pid="$1"; new="$2"; dest="$3"; relaunch="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        old="$dest.old-$$"
        if mv "$dest" "$old"; then
          if mv "$new" "$dest"; then
            rm -rf "$old"
            xattr -dr com.apple.quarantine "$dest" 2>/dev/null
          else
            mv "$old" "$dest"
          fi
        fi
        [ "$relaunch" = 1 ] && open "$dest"
        exit 0
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "vey-update", "\(ProcessInfo.processInfo.processIdentifier)",
                       staged.path, dest.path, relaunchAfterInstall ? "1" : "0"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Opens the release page (or the zip) for copies that cannot update themselves.
    func openDownloadPage() {
        guard let r = release else { return }
        NSWorkspace.shared.open(r.pageUrl ?? r.url)
    }

    // MARK: - UI helpers

    var statusText: String {
        switch state {
        case .idle: "Not checked yet"
        case .checking: "Checking for updates…"
        case .upToDate: "Vey Motion is up to date."
        case let .available(r): "Version \(r.version) is available."
        case let .downloading(r, p): "Downloading \(r.version)… \(Int(p * 100))%"
        case let .ready(r): "Version \(r.version) is ready. It installs when you quit or restart."
        case let .failed(m): m
        }
    }

    private func presentAlert() {
        let alert = NSAlert()
        switch state {
        case .upToDate:
            alert.messageText = "You’re up to date"
            alert.informativeText = "Vey Motion \(AppVersion.current) is the newest version."
        case let .failed(m):
            alert.alertStyle = .warning
            alert.messageText = "Could not check for updates"
            alert.informativeText = m
        case let .available(r), let .downloading(r, _), let .ready(r):
            alert.messageText = "Vey Motion \(r.version) is available"
            alert.informativeText = "You have \(AppVersion.current).\n\n" + (r.notes.map(Self.plainNotes) ?? "")
            if case .ready = state {
                alert.addButton(withTitle: "Restart to Update")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { restartToUpdate() }
            } else if installBlockedReason == nil {
                alert.addButton(withTitle: isBusy ? "OK" : "Download and Install")
                if !isBusy { alert.addButton(withTitle: "Later") }
                if alert.runModal() == .alertFirstButtonReturn, case let .available(r) = state { download(r) }
            } else {
                alert.informativeText += "\n\n\(installBlockedReason!)"
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { openDownloadPage() }
            }
            return
        default:
            return
        }
        alert.runModal()
    }

    /// Release notes without the Markdown heading/emphasis marks, for an alert.
    static func plainNotes(_ md: String) -> String {
        let text = md.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            while l.hasPrefix("#") { l.removeFirst() }
            if l.hasPrefix("* ") || l.hasPrefix("- ") { l = "• " + l.dropFirst(2) }
            return l.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
        return text.count > 1200 ? String(text.prefix(1200)) + "…" : text
    }

    private func confirm(_ title: String, _ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Environment

    nonisolated static var stagingRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VeyMotion/updates", isDirectory: true)
    }

    nonisolated private static func blockedReason() -> String? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", Bundle.main.bundleIdentifier != nil else {
            return "This is a development build (not an app bundle), so it cannot update itself."
        }
        if bundle.path.contains("/AppTranslocation/") {
            return "macOS is running Vey Motion from a temporary location. Move it to Applications, open it from there, and it can update itself."
        }
        if bundle.path.hasPrefix("/Volumes/") {
            return "Vey Motion is running from a disk image. Copy it to Applications to get automatic updates."
        }
        guard FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) else {
            return "You cannot write to the folder that holds Vey Motion, so it cannot replace itself."
        }
        return nil
    }

    nonisolated private static func run(_ tool: String, _ args: [String], _ failure: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let output = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let detail = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError(detail.isEmpty ? failure + "." : "\(failure): \(detail)")
        }
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One file download with progress, into the staging folder (not the system temp folder).
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastReported = -1.0

    private init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let d = Downloader(progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue("VeyMotion/\(AppVersion.current) (macOS motion graphics editor)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                d.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if p - lastReported >= 0.01 { lastReported = p; progress(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so move it now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw UpdateError("The server returned HTTP \(http.statusCode).")
            }
            let fm = FileManager.default
            try fm.createDirectory(at: Updater.stagingRoot, withIntermediateDirectories: true)
            let dest = Updater.stagingRoot.appendingPathComponent("download-\(UUID().uuidString).zip")
            try fm.moveItem(at: location, to: dest)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
    }
}
