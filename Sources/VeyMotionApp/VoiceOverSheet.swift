import SwiftUI
import VeyMotionCore

/// Type a script, pick a macOS voice, and add the narration at the playhead.
struct VoiceOverSheet: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var script = ""
    @State private var voices: [VoiceInfo] = []
    @State private var voiceId = ""
    @State private var rate = 1.0
    @State private var captions = true
    @State private var working = false
    @State private var error: String?
    @AppStorage("voice.lastId") private var lastVoiceId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Voice-over").font(.headline)
            TextEditor(text: $script)
                .font(.body)
                .frame(minWidth: 520, minHeight: 160)
                .overlay(alignment: .topLeading) {
                    if script.isEmpty {
                        Text("Type the narration… Punctuation adds natural pauses.")
                            .foregroundStyle(.tertiary).padding(6).allowsHitTesting(false)
                    }
                }
            HStack {
                Text("Voice").frame(width: 60, alignment: .leading)
                Picker("", selection: $voiceId) {
                    Text("Auto (by language)").tag("")
                    ForEach(voices, id: \.id) { v in
                        Text("\(v.name) — \(v.language)\(v.quality == "default" ? "" : " · \(v.quality)")").tag(v.id)
                    }
                }
                .labelsHidden()
            }
            HStack {
                Text("Speed").frame(width: 60, alignment: .leading)
                Slider(value: $rate, in: 0.6...1.6, step: 0.05)
                Text(String(format: "×%.2f", rate)).font(.caption.monospacedDigit()).frame(width: 44)
            }
            Toggle("Add captions", isOn: $captions)
            Text(String(format: "Starts at the playhead (%.2fs). Better voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.", store.time))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Generating…").font(.caption) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Generate") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .onAppear {
            voices = VoiceSynth.voices()
            if voices.contains(where: { $0.id == lastVoiceId }) { voiceId = lastVoiceId }
        }
    }

    private func generate() {
        let text = script
        let voice = voiceId.isEmpty ? nil : voiceId
        let speed = rate
        let start = store.time
        let addCaptions = captions
        working = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try AssetStore.newFile(prefix: "voice", ext: "caf", folder: AssetStore.routed(nil, default: "voice"))
                let result = try VoiceSynth.synthesize(text, voiceId: voice, rate: speed, to: url)
                DispatchQueue.main.async {
                    store.addVoiceLayer(result, script: text, start: start, captions: addCaptions)
                    lastVoiceId = voiceId
                    working = false
                    dismiss()
                }
            } catch let e {
                DispatchQueue.main.async {
                    error = e.localizedDescription
                    working = false
                }
            }
        }
    }
}
