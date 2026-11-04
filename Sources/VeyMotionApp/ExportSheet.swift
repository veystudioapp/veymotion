import AppKit
import SwiftUI
import VeyMotionCore

/// Export options (format, resolution, quality, range), then live progress with Cancel.
struct ExportSheet: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("export.format") private var format = ExportFormat.mp4
    @AppStorage("export.scale") private var scale = 1.0
    @AppStorage("export.quality") private var quality = ExportQuality.medium
    @State private var useRange = false
    @State private var start = 0.0
    @State private var end = 0.0

    private var scene: MotionScene { store.scene }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export").font(.headline)
            if let p = store.exportProgress {
                progressView(p)
            } else if let result = store.exportResult {
                resultView(result)
            } else {
                optionsView
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear {
            start = 0
            end = scene.duration
        }
    }

    // MARK: Options

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Picker("Format", selection: $format) {
                    Text("MP4 — H.264").tag(ExportFormat.mp4)
                    Text("MOV — ProRes 4444 (alpha)").tag(ExportFormat.mov)
                    Divider()
                    Text("M4A — audio only").tag(ExportFormat.m4a)
                    Text("WAV — audio only").tag(ExportFormat.wav)
                }
                if !format.isAudioOnly {
                    Picker("Resolution", selection: $scale) {
                        ForEach([0.25, 0.5, 1, 2], id: \.self) { s in
                            let size = ExportOptions(scale: s).pixelSize(for: scene)
                            Text("\(Int(s * 100))% — \(size.width)×\(size.height)").tag(s)
                        }
                    }
                }
                if format == .mp4 {
                    Picker("Quality", selection: $quality) {
                        Text("Low").tag(ExportQuality.low)
                        Text("Medium").tag(ExportQuality.medium)
                        Text("High").tag(ExportQuality.high)
                        Text("Maximum").tag(ExportQuality.max)
                    }
                }
                Toggle("Export a time range", isOn: $useRange)
                if useRange {
                    HStack {
                        TextField("From", value: $start, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 70)
                        Text("–")
                        TextField("To", value: $end, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 70)
                        Text("s").foregroundStyle(.secondary)
                        Button("Playhead → From") { start = store.time }.controlSize(.small)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Text(summary).font(.caption).foregroundStyle(.secondary)
            if format.isAudioOnly && !AudioMixer.hasAudio(scene) {
                Text("This scene has no audio layers.").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { store.startExport(options: options) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!rangeValid || (format.isAudioOnly && !AudioMixer.hasAudio(scene)))
            }
        }
    }

    private var options: ExportOptions {
        ExportOptions(format: format, scale: format.isAudioOnly ? 1 : scale, quality: quality,
                      start: useRange ? start : nil, end: useRange ? end : nil)
    }

    private var rangeValid: Bool { !useRange || (start >= 0 && end > start) }

    private var summary: String {
        let frames = options.frameRange(for: scene)
        let seconds = Double(frames.count) / Double(scene.fps)
        let length = String(format: "%.2fs", seconds)
        if format.isAudioOnly { return "\(length) of audio" }
        return "\(frames.count) frames · \(length) · \(scene.fps) fps"
            + (AudioMixer.hasAudio(scene) ? " · with audio" : "")
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
