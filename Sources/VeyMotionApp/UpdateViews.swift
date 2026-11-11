import SwiftUI
import VeyMotionCore

/// Version, update status and update settings (Settings window and the toolbar's update popover).
struct UpdatePanel: View {
    @Bindable var updater = Updater.shared
    var showsSettings = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vey Motion").font(.headline)
                    Text("Version \(AppVersion.display)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            status

            if let notes = updater.release?.notes, !notes.isEmpty {
                ScrollView {
                    Text((try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(notes))
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }

            if let reason = updater.installBlockedReason, updater.release != nil {
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            actions

            if showsSettings {
                Divider()
                Toggle("Check for updates automatically", isOn: $updater.autoCheck)
                Toggle("Download updates and install them when Vey Motion quits", isOn: $updater.autoInstall)
                    .disabled(!updater.autoCheck || updater.installBlockedReason != nil)
                if let date = updater.lastChecked {
                    Text("Last checked \(date.formatted(.relative(presentation: .named))).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(updater.statusText) }
        case let .downloading(_, p):
            VStack(alignment: .leading, spacing: 4) {
                Text(updater.statusText).monospacedDigit()
                ProgressView(value: p)
            }
        case .failed:
            Label(updater.statusText, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .ready, .available:
            Label(updater.statusText, systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
        case .upToDate:
            Label(updater.statusText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .idle:
            Text(updater.statusText).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            switch updater.state {
            case .ready:
                Button("Restart to Update") { updater.restartToUpdate() }.buttonStyle(.borderedProminent)
            case let .available(r):
                if updater.installBlockedReason == nil {
                    Button("Download and Install") { updater.download(r) }.buttonStyle(.borderedProminent)
                } else {
                    Button("Download…") { updater.openDownloadPage() }.buttonStyle(.borderedProminent)
                }
            case .downloading:
                Button("Cancel") { updater.cancelDownload() }
            default:
                EmptyView()
            }
            Spacer()
            Button("Check Now") { updater.check(userInitiated: false) }.disabled(updater.isBusy)
        }
    }
}

/// Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            Form { AccountPanel() }
                .padding(20)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            Form { UpdatePanel() }
                .padding(20)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 460)
    }
}

/// Toolbar button that only shows up while there is an update to get or install.
struct UpdateToolbarButton: View {
    @Bindable var updater = Updater.shared
    @State private var showDetails = false

    var body: some View {
        if let r = updater.release {
            Button { showDetails.toggle() } label: {
                switch updater.state {
                case let .downloading(_, p):
                    Label("Downloading \(Int(p * 100))%", systemImage: "arrow.down.circle")
                case .ready:
                    Label("Restart to Update", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                default:
                    Label("Update to \(r.version)", systemImage: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            .help(updater.statusText)
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                UpdatePanel(showsSettings: false).padding(16).frame(width: 360)
            }
        }
    }
}
