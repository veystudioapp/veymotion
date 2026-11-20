import AppKit
import SwiftUI
import VeyMotionCore

/// Export options (format, platform size, resolution, quality, range), then live progress with Cancel.
@MainActor
struct ExportSheet: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("export.format") private var format = ExportFormat.mp4
    @AppStorage("export.scale") private var scale = 1.0
    @AppStorage("export.quality") private var quality = ExportQuality.medium
    /// A `PlatformPreset` id, or "" for the scene's own size.
    @AppStorage("export.preset") private var presetId = ""
    @AppStorage("export.fit") private var fit = ExportFit.fit
    @State private var useRange = false
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var upgrading = false
    private var license: LicenseStore { LicenseStore.shared }

    private var scene: MotionScene { store.scene }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Text("Export").font(.title2.weight(.semibold))
                if license.isPro { ProBadge() }
            }
            exportContent
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            start = 0
            end = scene.duration
        }
        .sheet(isPresented: $upgrading) { UpgradeSheet() }
    }

    /// Opens the upgrade modal over this sheet, naming the locked feature.
    private func upgrade(_ feature: ProFeature?) {
        license.prepareUpgrade(for: feature)
        upgrading = true
    }

    @ViewBuilder
    private var exportContent: some View {
            if let p = store.exportProgress {
                progressView(p)
            } else if let result = store.exportResult {
                resultView(result)
            } else {
                optionsView
            }
    }

    private var preset: PlatformPreset? { PlatformPreset.named(presetId) }

    // MARK: Options

    private struct FormatChoice: Identifiable {
        let format: ExportFormat
        let title: String
        let detail: String
        let symbol: String
        var id: String { format.rawValue }
    }

    private static let formats = [
        FormatChoice(format: .mp4, title: "MP4", detail: "H.264 · universal", symbol: "play.rectangle"),
        FormatChoice(format: .mov, title: "MOV", detail: "ProRes 4444 · alpha", symbol: "film.stack"),
        FormatChoice(format: .m4a, title: "M4A", detail: "Audio only", symbol: "music.note"),
        FormatChoice(format: .wav, title: "WAV", detail: "Audio, lossless", symbol: "waveform"),
    ]

    private static let qualities: [(ExportQuality, String)] = [
        (.low, "Low"), (.medium, "Medium"), (.high, "High"), (.max, "Maximum"),
    ]

    /// Whether a size goes past what the Free plan exports (it would be fitted into 1080p).
    private func beyondFree(_ w: Int, _ h: Int) -> Bool {
        !license.isPro && (max(w, h) > License.freeMaxLongSide || min(w, h) > License.freeMaxShortSide)
    }

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Format") {
                HStack(spacing: 8) {
                    ForEach(Self.formats) { f in
                        let locked = f.format == .mov && !license.isPro
                        Button { locked ? upgrade(.proResExport) : (format = f.format) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: f.symbol).font(.title3).frame(height: 24)
                                    .foregroundStyle(format == f.format ? Color.accentColor : .secondary)
                                Text(f.title).fontWeight(.semibold)
                                Text(f.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10).padding(.horizontal, 4)
                            .overlay(alignment: .topTrailing) { if locked { ProBadge().padding(6) } }
                        }
                        .buttonStyle(ChoiceTileStyle(selected: format == f.format))
                        .help(locked ? "ProRes 4444 export is part of Pro" : f.detail)
                    }
                }
            }

            if !format.isAudioOnly {
                section("Size") {
                    HStack(spacing: 10) {
                        Picker("Size", selection: $presetId) {
                            Text("Scene — \(scene.width)×\(scene.height)").tag("")
                            Divider()
                            ForEach(PlatformPreset.all) { p in
                                Text("\(p.name) — \(p.width)×\(p.height) (\(p.aspectLabel))").tag(p.id)
                            }
                        }
                        .labelsHidden()
                        if preset != nil, options.isReframed(for: scene) {
                            Picker("Framing", selection: $fit) {
                                Text("Fit").tag(ExportFit.fit)
                                Text("Fill").tag(ExportFit.fill)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .fixedSize()
                            .help("Fit shows the whole scene with bars; Fill crops the edges.")
                        }
                    }
                    if preset == nil {
                        HStack(spacing: 6) {
                            ForEach([0.25, 0.5, 1, 2], id: \.self) { s in
                                let size = ExportOptions(scale: s).pixelSize(for: scene)
                                let locked = beyondFree(size.width, size.height)
                                Button { locked ? upgrade(.highResExport) : (scale = s) } label: {
                                    VStack(spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text("\(Int(s * 100))%").fontWeight(.medium)
                                            if locked { ProBadge() }
                                        }
                                        Text("\(size.width)×\(size.height)")
                                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                }
                                .buttonStyle(ChoiceTileStyle(selected: scale == s))
                                .help(locked ? "Exports above 1080p are part of Pro" : "\(size.width)×\(size.height)")
                            }
                        }
                    }
                }
            }

            if format == .mp4 {
                section("Quality") {
                    HStack(spacing: 6) {
                        ForEach(Self.qualities, id: \.0) { q, title in
                            Button(title) { quality = q }
                                .buttonStyle(ChoiceTileStyle(selected: quality == q, capsule: true))
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Export only part of the scene", isOn: $useRange)
                if useRange {
                    HStack(spacing: 6) {
                        TextField("From", value: $start, format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden().frame(width: 64)
                        Text("to").foregroundStyle(.secondary)
                        TextField("To", value: $end, format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden().frame(width: 64)
                        Text("seconds").foregroundStyle(.secondary)
                        Spacer()
                        Button("From playhead") { start = store.time }.controlSize(.small)
                    }
                }
            }

            summaryStrip

            ForEach(presetWarnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if format.isAudioOnly && !AudioMixer.hasAudio(scene) {
                Label("This scene has no audio layers.", systemImage: "speaker.slash")
                    .font(.caption).foregroundStyle(.red)
            }
            if let notice = freePlanNotice { freePlanCard(notice) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Export…") { store.startExport(options: options) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!rangeValid || (format.isAudioOnly && !AudioMixer.hasAudio(scene))
                              || freePlanNotice?.blocking == true)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    /// What the file will be: size, length, frames, sound and an estimated file size.
    private var summaryStrip: some View {
        let o = effectiveOptions
        let frames = o.frameRange(for: scene)
        let seconds = Double(frames.count) / Double(scene.fps)
        let (w, h) = o.pixelSize(for: scene)
        var items: [(String, String)] = []
        if !format.isAudioOnly { items.append(("aspectratio", "\(w)×\(h)")) }
        items.append(("timer", String(format: "%.1f s", seconds)))
        if !format.isAudioOnly { items.append(("film", "\(frames.count) frames · \(scene.fps) fps")) }
        if !format.isAudioOnly, AudioMixer.hasAudio(scene) { items.append(("speaker.wave.2", "Audio")) }
        if let bytes = o.estimatedBytes(for: scene) {
            items.append(("internaldrive", "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        return HStack(spacing: 14) {
            ForEach(items, id: \.1) { symbol, text in
                Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    /// The Free plan's limits on this export, what Pro adds, and the way to it.
    private func freePlanCard(_ notice: (text: String, blocking: Bool)) -> some View {
        let violet = Color(red: 0.47, green: 0.36, blue: 1.0), pink = Color(red: 0.96, green: 0.36, blue: 0.62)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(notice.blocking ? "Needs Pro to export" : "Free plan", systemImage: notice.blocking ? "lock.fill" : "info.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(notice.blocking ? Color.red : Color.primary)
                Spacer()
                Button { upgrade(notice.blocking ? blockingFeature : nil) } label: {
                    Label("Upgrade to Pro", systemImage: "sparkles")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(LinearGradient(colors: [violet, pink], startPoint: .leading,
                                                                  endPoint: .trailing)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Text(notice.text)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("With Pro you also get").font(.caption.weight(.semibold)).padding(.top, 2)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow { perk("4k.tv", "Up to 4K, no 1080p cap"); perk("checkmark.seal", "No watermark") }
                GridRow { perk("film.stack", "ProRes 4444 with alpha"); perk("cube.transparent", "3D and cutouts in exports") }
                GridRow { perk("play.square.stack", "Stock video in the app"); perk("scope", "Tracking, stabilize, templates") }
            }
        }
        .padding(14)
        .background(shape.fill(LinearGradient(colors: [violet.opacity(0.09), pink.opacity(0.06)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(shape.strokeBorder(LinearGradient(colors: [violet.opacity(0.5), pink.opacity(0.4)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private func perk(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: symbol).font(.caption).foregroundStyle(Color(red: 0.47, green: 0.36, blue: 1.0))
                .frame(width: 16)
        }
    }

    /// The feature that blocks a Free export, to highlight in the upgrade modal.
    private var blockingFeature: ProFeature? {
        if format == .mov { return .proResExport }
        return License.proContent(of: scene).first
    }

    private var options: ExportOptions {
        ExportOptions(format: format, scale: format.isAudioOnly ? 1 : scale,
                      size: format.isAudioOnly ? nil : preset?.size, fit: fit, quality: quality,
                      start: useRange ? start : nil, end: useRange ? end : nil)
    }

    private var presetWarnings: [String] {
        guard let preset, !format.isAudioOnly else { return [] }
        let o = options
        var out = preset.warnings(for: scene, duration: Double(o.frameRange(for: scene).count) / Double(scene.fps),
                                  estimatedBytes: o.estimatedBytes(for: scene))
        if o.isReframed(for: scene) {
            out.append("The scene is \(scene.width)×\(scene.height); it will be \(fit == .fit ? "letterboxed" : "cropped") to \(preset.aspectLabel). For the best result, make the scene \(preset.width)×\(preset.height).")
        }
        if format == .mov {
            out.append("Platforms re-encode ProRes uploads and X does not accept MOV; MP4 is smaller and faster to upload.")
        }
        return out
    }

    private var rangeValid: Bool { !useRange || (start >= 0 && end > start) }

    /// What the Free plan changes or refuses for this export (nil on Pro and for audio).
    private var freePlanNotice: (text: String, blocking: Bool)? {
        guard !LicenseStore.shared.isPro, !format.isAudioOnly else { return nil }
        var o = options
        do {
            _ = try License.prepareExport(scene, options: &o, format: format)
        } catch {
            return (error.localizedDescription, true)
        }
        let (w, h) = o.pixelSize(for: scene), (fw, fh) = options.pixelSize(for: scene)
        let size = w != fw || h != fh ? "\(w)×\(h) (fitted down from \(fw)×\(fh))" : "\(w)×\(h)"
        return ("This export will be \(size), with a small “Made with Vey Motion” watermark in the corner.", false)
    }

    /// The options the export will really use (the Free plan fits the size into 1080p).
    private var effectiveOptions: ExportOptions {
        var o = options
        if !LicenseStore.shared.isPro, !format.isAudioOnly { _ = try? License.prepareExport(scene, options: &o, format: format) }
        return o
    }

    // MARK: Progress

    private func progressView(_ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: p)
            HStack {
                Text(p == 0 ? "Preparing…" : "Exporting \(Int(p * 100))%")
                Spacer()
                if let eta = eta(p) { Text(eta).foregroundStyle(.secondary) }
            }
            .font(.caption.monospacedDigit())
            HStack {
                Text("You can close this window; the export keeps running.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Hide") { dismiss() }
                Button("Stop Export", role: .destructive) { store.cancelExport() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func eta(_ p: Double) -> String? {
        guard let startedAt = store.exportStartedAt, p > 0.02 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = Int((elapsed / p - elapsed).rounded())
        return remaining < 60 ? "about \(remaining)s left" : "about \(remaining / 60)m \(remaining % 60)s left"
    }

    // MARK: Result

    @ViewBuilder
    private func resultView(_ result: SceneStore.ExportResult) -> some View {
        switch result {
        case let .done(url, seconds):
            Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(String(format: "Finished in %.1fs.", seconds)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        case let .failed(msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Back to Options") { store.exportVideo() }.keyboardShortcut(.defaultAction)
            }
        case .cancelled:
            Label("Export cancelled", systemImage: "xmark.circle").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Back to Options") { store.exportVideo() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
