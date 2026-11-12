import AppKit
import Observation
import SwiftUI
import VeyMotionCore

/// The app's view of `License` (VeyMotion Pro): activation, daily refresh, and the links to buy/manage it.
@MainActor @Observable
final class LicenseStore {
    static let shared = LicenseStore()

    /// The stored license (may need a refresh); nil = Free.
    private(set) var info: LicenseInfo? = License.stored
    private(set) var isPro = License.isPro
    private(set) var busy = false
    var error: String?
    private(set) var checkoutURL: URL?
    private(set) var portalURL: URL?
    /// Why buying/activating cannot work right now (server unreachable or licensing not set up), if known.
    private(set) var setupProblem: String?

    private init() {
        NotificationCenter.default.addObserver(forName: License.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfDue() }
        }
    }

    /// Called at launch: refresh a day-old license and learn the purchase links.
    func start() {
        refreshIfDue()
        loadLinks()
    }

    func reload() {
        info = License.stored
        isPro = License.isPro
    }

    func refreshIfDue() {
        Task.detached {
            License.refreshIfDue()
            await MainActor.run { LicenseStore.shared.reload() }
        }
    }

    func loadLinks() {
        Task.detached {
            var problem: String?
            var links: License.ServerInfo?
            if License.publicKeyBase64.isEmpty {
                problem = "Licensing is not set up in this build of Vey Motion yet."
            }
            do {
                links = try License.serverInfo()
                if links?.configured == false { problem = problem ?? "Licensing is not set up on the VeyMotion server yet." }
                else if links?.checkoutURL == nil { problem = problem ?? "The VeyMotion server has no checkout link (NITRO_LICENSE_CHECKOUT_URL)." }
            } catch {
                problem = problem ?? "Cannot reach the VeyMotion server at \(VieNeu.baseURL.absoluteString) to buy or activate Pro."
            }
            let found = links, why = problem
            await MainActor.run {
                let s = LicenseStore.shared
                s.checkoutURL = found?.checkoutURL
                s.portalURL = found?.portalURL
                s.setupProblem = why
            }
        }
    }

    func activate(_ key: String) { run { _ = try License.activate(key: key) } }
    func refresh() { run { _ = try License.refresh() } }
    func deactivate() { run { try License.deactivate() } }

    private func run(_ work: @escaping @Sendable () throws -> Void) {
        busy = true
        error = nil
        Task.detached {
            let message: String?
            do { try work(); message = nil } catch { message = error.localizedDescription }
            await MainActor.run {
                let s = LicenseStore.shared
                s.busy = false
                s.error = message
                s.reload()
            }
        }
    }

    func openCheckout() { if let u = checkoutURL { NSWorkspace.shared.open(u) } }
    func openPortal() { if let u = portalURL { NSWorkspace.shared.open(u) } }
}

/// Settings → Account.
struct AccountPanel: View {
    @Bindable var store = LicenseStore.shared
    @State private var key = ""
    @State private var confirmDeactivate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info = store.info {
                proSection(info)
            } else {
                freeSection
            }
            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if store.checkoutURL == nil { store.loadLinks() } }
    }

    private func proSection(_ info: LicenseInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("VeyMotion Pro").font(.headline)
                ProBadge()
            }
            VStack(alignment: .leading, spacing: 3) {
                if let email = info.email { Text(info.name.map { "\($0) · \(email)" } ?? email) }
                Text("License key \(info.keyHint)").foregroundStyle(.secondary)
                if let end = info.licenseExpiresAt {
                    Text("License ends \(end.formatted(date: .long, time: .omitted)).").foregroundStyle(.secondary)
                }
                if info.isValid {
                    Text("Works offline until \(info.validUntil.formatted(date: .abbreviated, time: .shortened)); renewed automatically while online.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("This Mac has not reached the VeyMotion server for a while: Pro is paused until it does.",
                          systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            HStack {
                Button("Check Now") { store.refresh() }.disabled(store.busy)
                if store.portalURL != nil { Button("Manage License…") { store.openPortal() } }
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button("Deactivate This Mac…") { confirmDeactivate = true }.disabled(store.busy)
            }
            .confirmationDialog("Deactivate VeyMotion Pro on this Mac?", isPresented: $confirmDeactivate) {
                Button("Deactivate", role: .destructive) { store.deactivate() }
            } message: {
                Text("This frees one of the key's Macs, so you can use it on another one. You can activate this Mac again later with the same key.")
            }
        }
    }

    private var freeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Free plan").font(.headline)
            Text("Everything you need to make motion graphics, with exports up to 1080p and a small watermark. Pro adds:")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Self.highlights, id: \.self) { line in
                    Label(line, systemImage: "checkmark").font(.callout)
                }
            }
            HStack {
                TextField("License key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { activate() }
                Button("Activate") { activate() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
                    .keyboardShortcut(.defaultAction)
            }
            HStack {
                Button("Buy VeyMotion Pro…") { store.openCheckout() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.checkoutURL == nil)
                if store.portalURL != nil { Button("Find My Key…") { store.openPortal() } }
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
            }
            if let problem = store.setupProblem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                    Button("Retry") { store.loadLinks() }.controlSize(.small)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func activate() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty, !store.busy else { return }
        store.activate(key)
    }

    static let highlights = [
        "Export in 4K and ProRes 4444 with alpha, no watermark",
        "Vietnamese voices (VieNeu), stock video, publishing to YouTube, TikTok, Facebook and X",
        "3D layers and models, background removal",
        "Motion tracking, auto reframe, stabilize, templates, graph editor",
    ]
}

/// Toolbar button that opens the Account panel in a popover: "Upgrade to Pro" on the Free plan (enter a key or buy
/// Pro), a PRO tag once activated (the panel then shows the license, so a successful activation is visible in place).
struct UpgradeToolbarButton: View {
    @Bindable var store = LicenseStore.shared
    @State private var showPanel = false

    var body: some View {
        Button { showPanel.toggle() } label: {
            if store.isPro {
                ProBadge()
            } else {
                Label("Upgrade to Pro", systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .help(store.isPro ? "VeyMotion Pro is active on this Mac"
              : store.info != nil ? "VeyMotion Pro is paused: this Mac needs to reach the server"
              : "Unlock 4K export without watermark, VieNeu voices, stock video, 3D and more")
        .popover(isPresented: $showPanel, arrowEdge: .bottom) {
            AccountPanel().padding(16).frame(width: 400)
        }
    }
}

/// A small "PRO" tag for Pro features.
struct ProBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .foregroundStyle(.white)
            .background(Capsule().fill(Color.accentColor))
            .accessibilityLabel("VeyMotion Pro")
    }
}

/// Shown instead of a Pro-only panel on the Free plan.
struct ProLockedView: View {
    let feature: ProFeature
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                Text(feature.title).font(.headline)
                ProBadge()
            }
            Text("Available with VeyMotion Pro.").font(.callout).foregroundStyle(.secondary)
            Button("Upgrade…") { openSettings() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
