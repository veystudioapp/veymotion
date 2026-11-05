import SwiftUI
import VeyMotionCore

/// Type a script, pick a voice (macOS or VieNeu), and add the narration at the playhead.
struct VoiceOverSheet: View {
    enum Engine: String, CaseIterable, Identifiable {
        case macos, vieneu
        var id: String { rawValue }
        var title: String { self == .macos ? "macOS" : "VieNeu (Vietnamese)" }
    }

    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var script = ""
    @State private var voices: [VoiceInfo] = []
    @State private var voiceId = ""
    @State private var vieneuVoices: [VieNeu.Voice] = []
    @State private var vieneuVoiceId = ""
    @State private var vieneuLoading = false
    @State private var vieneuError: String?
    @State private var rate = 1.0
    @State private var captions = true
    @State private var working = false
    @State private var error: String?
    @AppStorage("voice.engine") private var engine: Engine = .macos
    @AppStorage("voice.lastId") private var lastVoiceId = ""
    @AppStorage("voice.lastVieNeuId") private var lastVieNeuId = ""

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
                Text("Engine").frame(width: 60, alignment: .leading)
                Picker("", selection: $engine) {
                    ForEach(Engine.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Text("Voice").frame(width: 60, alignment: .leading)
                if engine == .macos {
                    Picker("", selection: $voiceId) {
                        Text("Auto (by language)").tag("")
                        ForEach(voices, id: \.id) { v in
                            Text("\(v.name) — \(v.language)\(v.quality == "default" ? "" : " · \(v.quality)")").tag(v.id)
                        }
                    }
                    .labelsHidden()
                } else {
                    Picker("", selection: $vieneuVoiceId) {
                        Text("Default voice").tag("")
                        ForEach(vieneuVoices, id: \.id) { v in Text(v.label).tag(v.id) }
                    }
                    .labelsHidden()
                    .disabled(vieneuLoading)
                    if vieneuLoading { ProgressView().controlSize(.small) }
                    Button { loadVieNeuVoices(refresh: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Reload VieNeu voices")
                        .disabled(vieneuLoading)
                }
            }
            HStack {
                Text("Speed").frame(width: 60, alignment: .leading)
                Slider(value: $rate, in: 0.6...1.6, step: 0.05)
                Text(String(format: "×%.2f", rate)).font(.caption.monospacedDigit()).frame(width: 44)
            }
            Toggle("Add captions", isOn: $captions)
            Group {
                if engine == .macos {
                    Text(String(format: "Starts at the playhead (%.2fs). Better voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.", store.time))
                } else {
                    Text(String(format: "Starts at the playhead (%.2fs). Uses the TTS server at %@ (BASE_API_URL). Caption timing is estimated.", store.time, VieNeu.baseURL.absoluteString))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if engine == .vieneu, let vieneuError { Text(vieneuError).font(.caption).foregroundStyle(.orange) }
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
            vieneuVoiceId = lastVieNeuId
            if engine == .vieneu { loadVieNeuVoices() }
        }
        .onChange(of: engine) { _, e in
            error = nil
            if e == .vieneu && vieneuVoices.isEmpty { loadVieNeuVoices() }
        }
    }

    private func loadVieNeuVoices(refresh: Bool = false) {
        vieneuLoading = true
        vieneuError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try VieNeu.voices(refresh: refresh) }
            DispatchQueue.main.async {
                vieneuLoading = false
                switch result {
                case let .success(v):
                    vieneuVoices = v
                    if !vieneuVoiceId.isEmpty && !v.contains(where: { $0.id == vieneuVoiceId }) { vieneuVoiceId = "" }
                case let .failure(e):
                    vieneuError = e.localizedDescription
                }
            }
        }
    }

    private func generate() {
        let text = script
        let engine = engine
        let voice = engine == .macos ? voiceId : vieneuVoiceId
        let speed = rate
        let start = store.time
        let addCaptions = captions
        working = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let folder = AssetStore.routed(nil, default: "voice")
                let result: VoiceResult
                switch engine {
                case .macos:
                    let url = try AssetStore.newFile(prefix: "voice", ext: "caf", folder: folder)
                    result = try VoiceSynth.synthesize(text, voiceId: voice.isEmpty ? nil : voice, rate: speed, to: url)
                case .vieneu:
                    result = try VieNeu.synthesize(text, voice: voice, speed: speed, folder: folder)
                }
                DispatchQueue.main.async {
                    store.addVoiceLayer(result, script: text, start: start, captions: addCaptions)
                    if engine == .macos { lastVoiceId = voice } else { lastVieNeuId = voice }
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
