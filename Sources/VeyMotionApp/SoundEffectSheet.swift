import AVFoundation
import SwiftUI
import VeyMotionCore

/// Built-in synthesized sound effects: pick a kind, shape it, audition it, and add it so its hit lands on the playhead.
struct SoundEffectSheet: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sfx.kind") private var kind: SynthKind = .whoosh
    @State private var duration = SynthKind.whoosh.defaultDuration
    @State private var pitch = 1.0
    @State private var variant = 0
    @State private var reverb = 0.0
    @State private var direction = ""
    @State private var count = 1
    @State private var volume = 0.7
    @State private var player: AVAudioPlayer?
    @State private var error: String?

    private var settings: SynthSettings {
        SynthSettings(kind: kind, duration: usesDuration ? duration : nil, pitch: pitch, variant: variant,
                      reverb: reverb, direction: direction.isEmpty ? nil : direction,
                      count: usesCount && count > 1 ? count : nil)
    }

    private var usesDuration: Bool { kind.stretches || (kind.repeats && count > 1) }
    private var usesCount: Bool { kind.repeats || kind == .typing }
    private var usesDirection: Bool { [.whoosh, .swoosh, .riser].contains(kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sound Effect").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(SynthKind.allCases, id: \.self) { k in
                    Button { select(k) } label: {
                        Text(k.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(k == kind ? .accentColor : nil)
                }
            }
            Text(kind.use.prefix(1).uppercased() + kind.use.dropFirst())
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if usesDuration {
                row("Length") {
                    Slider(value: $duration, in: kind == .riser ? 0.5...6 : kind.stretches ? 0.1...3 : 0.2...6)
                    Text(String(format: "%.2fs", duration)).font(.caption.monospacedDigit()).frame(width: 48)
                }
            }
            if usesCount {
                row(kind == .typing ? "Keys" : "Repeat") {
                    Stepper(value: $count, in: 1...100) {
                        Text(count <= 1 ? (kind == .typing ? "Natural rhythm" : "Once") : "\(count)×")
                    }
                }
            }
            row("Pitch") {
                Slider(value: $pitch, in: 0.5...2)
                Text(String(format: "×%.2f", pitch)).font(.caption.monospacedDigit()).frame(width: 48)
            }
            if usesDirection {
                row("Direction") {
                    Picker("", selection: $direction) {
                        Text("Center").tag("")
                        Text("→ Left").tag("left")
                        Text("Right →").tag("right")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
            row("Reverb") {
                Slider(value: $reverb, in: 0...1)
                Text(String(format: "%.0f%%", reverb * 100)).font(.caption.monospacedDigit()).frame(width: 48)
            }
            row("Volume") {
                Slider(value: $volume, in: 0...1)
                Text(String(format: "%.0f%%", volume * 100)).font(.caption.monospacedDigit()).frame(width: 48)
            }
            Text(String(format: "The hit lands on the playhead (%.2fs)%@.", store.time,
                        kind == .riser ? ": the riser ends there" : kind == .whoosh || kind == .swoosh ? ": the whoosh peaks there" : ""))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button { preview() } label: { Label("Play", systemImage: "play.fill") }
                Button { variant += 1; preview() } label: { Label("Another", systemImage: "shuffle") }
                    .help("Same settings, different random detail")
                Spacer()
                Button("Cancel") { player?.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear { select(kind) }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(title).frame(width: 64, alignment: .leading)
            content()
        }
    }

    private func select(_ k: SynthKind) {
        kind = k
        duration = k.defaultDuration
        reverb = k.defaultReverb
        count = 1
        if !usesDirection { direction = "" }
        error = nil
    }

    private func preview() {
        let out = SoundSynth.render(settings)
        do {
            player?.stop()
            let p = try AVAudioPlayer(data: SoundSynth.wav(left: out.left, right: out.right))
            p.volume = Float(volume)
            p.play()
            player = p
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func add() {
        do {
            let result = try SoundSynth.generate(settings)
            player?.stop()
            store.addSoundEffect(result, title: kind.title, hitAt: store.time, volume: volume)
            AssetLibrary.shared.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
