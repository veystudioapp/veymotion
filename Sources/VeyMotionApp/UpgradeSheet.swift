import AppKit
import SwiftUI
import VeyMotionCore

/// The upgrade modal for the Free plan: what Pro adds, one button to buy it, and a key field for those who already
/// have one. Opened through `LicenseStore.presentUpgrade(for:)` (toolbar, Projects sidebar, locked features) and
/// shown by `ContentView`. Once a key activates it turns into a thank-you.
struct UpgradeSheet: View {
    @Bindable var store = LicenseStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showKey = false
    @State private var key = ""
    @FocusState private var keyFocused: Bool

    fileprivate static let violet = Color(red: 0.47, green: 0.36, blue: 1.0)
    fileprivate static let pink = Color(red: 0.96, green: 0.36, blue: 0.62)

    var body: some View {
        HStack(spacing: 0) {
            UpgradeHero().frame(width: 300)
            Group {
                if store.isPro { welcome } else { offer }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 800, height: 580)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.secondary.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .padding(14)
        }
        .animation(.easeOut(duration: 0.25), value: store.isPro)
        .animation(.easeOut(duration: 0.2), value: showKey)
    }

    // MARK: Offer

    private var offer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let f = store.upgradeFeature {
                Label("\(f.title) is part of Pro", systemImage: "lock.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Self.violet)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Self.violet.opacity(0.12)))
                    .padding(.bottom, 14)
            }
            Text("Everything in Free, plus")
                .font(.system(size: 24, weight: .bold))
            Text("Free keeps exports at 1080p with a small watermark. Pro lifts the limits.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, 4)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top),
                                GridItem(.flexible(), spacing: 14, alignment: .top)],
                      alignment: .leading, spacing: 10) {
                ForEach(ProPerk.all) { perk in
                    PerkTile(perk: perk, highlighted: store.upgradeFeature.map(perk.features.contains) ?? false)
                }
            }
            .padding(.top, 20)

            Spacer(minLength: 14)
            purchase
        }
        .padding(.horizontal, 34)
        .padding(.top, 40)
        .padding(.bottom, 26)
    }

    private var purchase: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { store.openCheckout() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Upgrade to Pro")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Self.violet, Self.pink], startPoint: .leading, endPoint: .trailing)))
                .shadow(color: Self.violet.opacity(0.35), radius: 12, y: 5)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .disabled(store.checkoutURL == nil)
            .opacity(store.checkoutURL == nil ? 0.5 : 1)
            // Return buys, unless the key field is open: then it activates.
            .keyboardShortcut(showKey ? nil : .defaultAction)

            if showKey {
                HStack(spacing: 8) {
                    TextField("License key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .focused($keyFocused)
                        .onSubmit(activate)
                    Button("Activate", action: activate)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
                    if store.busy { ProgressView().controlSize(.small) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Button(showKey ? "Hide the key field" : "Already bought it? Enter your license key") {
                    showKey.toggle()
                    keyFocused = showKey
                }
                Spacer()
                if store.portalURL != nil { Button("Find my key") { store.openPortal() } }
            }
            .buttonStyle(.link)
            .font(.callout)

            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 58))
                .foregroundStyle(LinearGradient(colors: [Self.violet, Self.pink], startPoint: .topLeading,
                                                endPoint: .bottomTrailing))
                .symbolEffect(.bounce, value: store.isPro)
            Text("You're Pro").font(.system(size: 30, weight: .bold))
            Text("Thank you for supporting Vey Motion. 4K and ProRes export without a watermark, the Vietnamese voices, stock video, 3D and every Pro tool are now on for this Mac.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
            Button("Start Creating") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(40)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// The modal's left half: a dark, lit panel with a few floating frames and the promise.
private struct UpgradeHero: View {
    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.05, blue: 0.11)
            RadialGradient(colors: [UpgradeSheet.violet.opacity(0.95), .clear], center: UnitPoint(x: 0.9, y: 0.05),
                           startRadius: 0, endRadius: 360)
            RadialGradient(colors: [UpgradeSheet.pink.opacity(0.7), .clear], center: UnitPoint(x: 0.05, y: 0.95),
                           startRadius: 0, endRadius: 340)
            VStack(alignment: .leading, spacing: 0) {
                FloatingFrames()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 64)
                Spacer(minLength: 20)
                HStack(spacing: 8) {
                    Text("Vey Motion").font(.system(size: 15, weight: .semibold))
                    Text("PRO")
                        .font(.system(size: 11, weight: .heavy)).tracking(0.8)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(Color(red: 0.06, green: 0.05, blue: 0.11))
                }
                Text("Make every video look finished.")
                    .font(.system(size: 30, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                Text("Export in 4K without a watermark, and open the tools behind the most polished pieces.")
                    .font(.callout).foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                Rectangle().fill(.white.opacity(0.14)).frame(height: 1).padding(.vertical, 18)
                VStack(alignment: .leading, spacing: 8) {
                    trust("lock.shield", "Secure checkout with Polar")
                    trust("key", "One key, activated on this Mac")
                    trust("wifi.slash", "Works offline, renews by itself")
                }
            }
            .padding(28)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func trust(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: symbol).font(.caption).frame(width: 16)
        }
        .foregroundStyle(.white.opacity(0.8))
    }
}

/// Three frames fanned out with a play mark, drifting slowly: the app's subject in one picture.
private struct FloatingFrames: View {
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.05 + Double(i) * 0.03))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing),
                                          lineWidth: 1.2)
                    }
                    .frame(width: 150, height: 94)
                    .rotationEffect(.degrees(Double(i - 1) * 9))
                    .offset(x: CGFloat(i - 1) * 26, y: CGFloat(1 - i) * 14)
            }
            Image(systemName: "play.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white)
                .offset(x: 26, y: -14)
                .shadow(color: UpgradeSheet.violet, radius: 12)
        }
        .phaseAnimator([false, true]) { view, up in
            view.offset(y: up ? -5 : 5).rotationEffect(.degrees(up ? 1.5 : -1.5))
        } animation: { _ in .easeInOut(duration: 2.6) }
    }
}

/// One thing Pro adds, as the modal lists it.
private struct ProPerk: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let features: [ProFeature]

    static let all: [ProPerk] = [
        ProPerk(id: "export", symbol: "4k.tv", tint: .blue, title: "4K and ProRes 4444",
                detail: "Sharp masters, and alpha for compositing.", features: [.highResExport, .proResExport]),
        ProPerk(id: "watermark", symbol: "checkmark.seal", tint: .green, title: "No watermark",
                detail: "Your brand on every frame, not ours.", features: [.noWatermark]),
        ProPerk(id: "voice", symbol: "waveform", tint: .orange, title: "Vietnamese voices",
                detail: "Natural VieNeu voice-overs from your script.", features: [.vietnameseVoice]),
        ProPerk(id: "stock", symbol: "film.stack", tint: .pink, title: "Stock video",
                detail: "Pexels and Pixabay clips, searchable in the app.", features: [.stockVideo]),
        ProPerk(id: "3d", symbol: "cube.transparent", tint: .purple, title: "3D and cut-outs",
                detail: "3D layers and models, background removal.", features: [.threeD, .backgroundRemoval]),
        ProPerk(id: "tools", symbol: "scope", tint: .teal, title: "Pro tools",
                detail: "Tracking, auto reframe, stabilize, templates, graph editor.",
                features: [.motionTracking, .autoReframe, .stabilize, .templates, .graphEditor]),
    ]
}

private struct PerkTile: View {
    let perk: ProPerk
    let highlighted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: perk.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(perk.tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(perk.title).font(.callout.weight(.semibold))
                Text(perk.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlighted ? UpgradeSheet.violet.opacity(0.1) : Color.secondary.opacity(0.06))
        }
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(UpgradeSheet.violet.opacity(0.5), lineWidth: 1.5)
            }
        }
    }
}

/// Shrinks a little while pressed.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
