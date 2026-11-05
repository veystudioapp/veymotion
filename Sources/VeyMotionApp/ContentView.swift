import AppKit
import SwiftUI
import VeyMotionCore

struct ContentView: View {
    @Environment(SceneStore.self) private var store
    @State private var showJSON = false
    @State private var showVoice = false
    @AppStorage("rightPanelTab") private var rightTab: RightPanelTab = .inspector
    @AppStorage("leftPanelTab") private var leftTab: LeftPanelTab = .layers
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("timelineHeight") private var timelineHeight: Double = 240
    /// Hidden by default: most editing goes through Claude, so the canvas gets the space.
    /// The transport bar shows a compact scrubber instead.
    @AppStorage("showTimeline") private var showTimeline = false

    /// The window shows either the Projects screen (at launch, ⇧⌘P) or the editor.
    var body: some View {
        Group {
            if store.showProjects {
                ProjectsScreen()
            } else {
                editor
            }
        }
        .sheet(isPresented: Bindable(store).showNewProject) { NewProjectSheet() }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HSplitView {
                if showSidebar {
                    VStack(spacing: 0) {
                        PanelTabBar(selection: $leftTab)
                        Divider()
                        switch leftTab {
                        case .layers: LayerListView()
                        case .assets: AssetsPanel()
                        }
                    }
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 400)
                }
                VStack(spacing: 0) {
                    CanvasView()
                    TransportBar()
                }
                .frame(minWidth: 420, maxWidth: .infinity)
                if showInspector {
                    VStack(spacing: 0) {
                        PanelTabBar(selection: $rightTab)
                        Divider()
                        // Keep both alive so switching tabs does not reset the chat's scroll position or draft.
                        ZStack {
                            InspectorView().opacity(rightTab == .inspector ? 1 : 0)
                                .allowsHitTesting(rightTab == .inspector)
                            ChatPanel().opacity(rightTab == .claude ? 1 : 0)
                                .allowsHitTesting(rightTab == .claude)
                        }
                    }
                    .frame(minWidth: 290, idealWidth: 340, maxWidth: 560)
                }
            }
            if showTimeline {
                ResizeHandle(height: $timelineHeight, range: 140...700)
                TimelinePanel().frame(height: timelineHeight)
            }
            Divider()
            StatusBar()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { store.showProjects = true } label: { Label("Projects", systemImage: "square.grid.2x2") }
                    .help("All projects (⇧⌘P)")
            }
            ToolbarItem(placement: .navigation) {
                Button { withAnimation(.easeOut(duration: 0.2)) { showSidebar.toggle() } } label: {
                    Label("Layers & Assets", systemImage: "sidebar.left")
                }
                .help("Show or hide Layers & Assets (⌃⌘S)")
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            ToolbarItem(placement: .principal) {
                ControlGroup {
                    Button { store.addLayer(.rect) } label: { Label("Rectangle", systemImage: "rectangle") }
                        .help("Add rectangle")
                    Button { store.addLayer(.ellipse) } label: { Label("Ellipse", systemImage: "circle") }
                        .help("Add ellipse")
                    Button { store.addLayer(.text) } label: { Label("Text", systemImage: "textformat") }
                        .help("Add text (⇧⌘T)")
                    Button { store.addImageLayer() } label: { Label("Image", systemImage: "photo") }
                        .help("Add image from a file")
                    Button { store.addVideoLayer() } label: { Label("Video", systemImage: "film") }
                        .help("Add a movie or an image sequence (e.g. a 3D render from Blender)")
                    Button { store.addAudioLayer() } label: { Label("Audio", systemImage: "music.note") }
                        .help("Add audio file")
                    Button { showVoice = true } label: { Label("Voice-over", systemImage: "mic") }
                        .help("Generate a voice-over")
                }
                .controlGroupStyle(.navigation)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { withAnimation(.easeOut(duration: 0.2)) { showTimeline.toggle() } } label: {
                    Label("Timeline", systemImage: showTimeline ? "rectangle.bottomthird.inset.filled" : "rectangle")
                }
                .help("Show or hide the Timeline (⌃⌘T)")
                .keyboardShortcut("t", modifiers: [.control, .command])
                Button { showJSON = true } label: { Label("Scene JSON", systemImage: "curlybraces") }
                    .help("View or edit the scene JSON")
                Button {
                    if showInspector && rightTab == .claude {
                        rightTab = .inspector
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { showInspector = true }
                        rightTab = .claude
                    }
                } label: {
                    Label { Text("Claude") } icon: { ClaudeLogo(size: 16) }
                }
                .help("Chat with Claude (⌘L)")
                .keyboardShortcut("l")
                Button { store.exportVideo() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export video (⌘E)")
                Button { withAnimation(.easeOut(duration: 0.2)) { showInspector.toggle() } } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the Inspector (⌥⌘I)")
                .keyboardShortcut("i", modifiers: [.option, .command])
            }
        }
        .navigationTitle(store.project?.lastPathComponent ?? store.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
        .navigationSubtitle([store.project != nil ? "Project" : nil, store.isDirty ? "Edited" : nil]
            .compactMap { $0 }.joined(separator: " — "))
        .sheet(isPresented: $showJSON) { JSONEditorSheet() }
        .sheet(isPresented: $showVoice) { VoiceOverSheet() }
        .sheet(isPresented: Bindable(store).showExport) { ExportSheet() }
    }
}

/// Horizontal divider that can be dragged to resize the panel below it.
struct ResizeHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    @State private var startHeight: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if startHeight == nil { startHeight = height }
                    height = min(max((startHeight ?? height) - Double(v.translation.height), range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startHeight = nil })
    }
}

// MARK: - Canvas

/// Renders canvas frames on a background queue. Requests made while a frame is rendering are coalesced:
/// only the latest one is drawn next, so a slow scene drops frames instead of stalling the UI.
@Observable
final class PreviewRenderer {
    private(set) var image: CGImage?
    @ObservationIgnored private let queue = DispatchQueue(label: "VeyMotion.preview", qos: .userInteractive)
    @ObservationIgnored private let renderer = FrameRenderer() // only used on `queue`
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var pending: (scene: MotionScene, time: Double, scale: Double)?

    /// Call on the main thread.
    func request(_ scene: MotionScene, at time: Double, scale: Double) {
        pending = (scene, time, scale)
        renderNext()
    }

    /// Frees the previous document's images and video decoders. Call on the main thread.
    func clearCaches() {
        queue.async { [renderer] in renderer.clearCaches() }
    }

    private func renderNext() {
        guard !busy, let job = pending else { return }
        pending = nil
        busy = true
        queue.async { [renderer] in
            let img = renderer.makeImage(job.scene, at: job.time, scale: job.scale)
            DispatchQueue.main.async {
                self.image = img
                self.busy = false
                self.renderNext()
            }
        }
    }
}

struct CanvasView: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    @State private var preview = PreviewRenderer()

    private struct FrameKey: Equatable {
        var revision: Int
        var time: Double
        var scale: Double
    }

    var body: some View {
        GeometryReader { geo in
            let scene = store.scene
            let aspect = Double(scene.width) / Double(scene.height)
            let avail = CGSize(width: max(geo.size.width - 40, 10), height: max(geo.size.height - 40, 10))
            let fit = avail.width / avail.height > aspect
                ? CGSize(width: avail.height * aspect, height: avail.height)
                : CGSize(width: avail.width, height: avail.width / aspect)
            // Render at the canvas's real pixel size (not capped at the scene size, so vector content stays sharp
            // when the canvas is larger than the scene); while playing, at most 1.5 px/pt to keep frames cheap.
            let density = store.isPlaying ? min(displayScale, 1.5) : displayScale
            let scale = fit.width * density / Double(scene.width)
            let key = FrameKey(revision: store.sceneRevision, time: store.time, scale: scale)
            ZStack {
                if let img = preview.image {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                }
                if let layer = store.selectedLayer, layer.type.isVisual, layer.type != .text,
                   layer.isVisible(at: store.time, sceneDuration: scene.duration) {
                    SelectionBox(layer: layer, scene: scene, time: store.time, unit: fit.width / Double(scene.width))
                        .frame(width: fit.width, height: fit.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Before the new document's first frame (declared first, so it runs first; the queue is serial).
            .onChange(of: store.documentRevision) { preview.clearCaches() }
            .onChange(of: key, initial: true) { _, k in preview.request(store.scene, at: k.time, scale: k.scale) }
            // An image file overwritten in place (e.g. by write_asset) leaves the scene unchanged.
            .onChange(of: AssetLibrary.shared.assets) { preview.request(store.scene, at: key.time, scale: key.scale) }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        // Drop images/audio from the Assets panel or Finder to add them as layers.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            files.forEach { store.addFileLayer($0.path) }
            return !files.isEmpty
        }
    }
}

/// Outline of the selected shape/image layer, following its animated transform (parents, skew, anchor, path).
struct SelectionBox: View {
    let layer: MotionLayer
    let scene: MotionScene
    let time: Double
    let unit: Double

    var body: some View {
        let size = { (v: AnimValue?, fallback: Double) -> Double in
            let x = v?.value(at: time) ?? 0
            return x > 0 ? x : fallback
        }
        let w = layer.type.hasNaturalSize ? size(layer.width, 400) : layer.shapeWidth(at: time)
        let h = layer.type.hasNaturalSize ? size(layer.height, 240) : layer.shapeHeight(at: time)
        let screen = scene.worldTransform(of: layer, at: time)
        Path(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
            .applying(screen.concatenating(CGAffineTransform(scaleX: unit, y: unit)))
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .allowsHitTesting(false)
    }
}

/// Playback controls under the canvas: timecode on the left, transport centered, format on the right.
/// With the timeline hidden, a compact scrubber sits above the controls.
struct TransportBar: View {
    @Environment(SceneStore.self) private var store
    @AppStorage("showTimeline") private var showTimeline = false

    var body: some View {
        VStack(spacing: 0) {
            if !showTimeline {
                MiniScrubber()
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            controls
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var controls: some View {
        let s = store.scene
        return ZStack {
            HStack(spacing: 6) {
                Text(timecode(store.time, fps: s.fps))
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                Text("/ \(timecode(s.duration, fps: s.fps))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(s.width)×\(s.height) · \(s.fps) fps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { withAnimation(.easeOut(duration: 0.2)) { showTimeline.toggle() } } label: {
                    Image(systemName: showTimeline ? "chevron.down" : "chevron.up")
                }
                .help(showTimeline ? "Hide the Timeline (⌃⌘T)" : "Show the Timeline (⌃⌘T)")
            }
            HStack(spacing: 16) {
                Button { store.seek(0) } label: { Image(systemName: "backward.end.fill") }
                    .help("Go to start (⇧⌘←)")
                Button { store.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("Previous frame (⌘←)")
                Button { store.togglePlay() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 22)
                }
                .help("Play / pause (⌘↩)")
                Button { store.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("Next frame (⌘→)")
                Button { store.seek(s.duration) } label: { Image(systemName: "forward.end.fill") }
                    .help("Go to end")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    /// mm:ss:ff
    private func timecode(_ t: Double, fps: Int) -> String {
        let frames = Int((t * Double(fps)).rounded())
        let f = max(fps, 1)
        return String(format: "%02d:%02d:%02d", frames / f / 60, frames / f % 60, frames % f)
    }
}

/// Thin click/drag scrubber over the whole scene, used while the full timeline is hidden.
struct MiniScrubber: View {
    @Environment(SceneStore.self) private var store

    var body: some View {
        GeometryReader { geo in
            let w = max(Double(geo.size.width), 1)
            let d = max(store.scene.duration, 0.001)
            let x = min(max(store.time / d, 0), 1) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: x, height: 4)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: 10, height: 10)
                    .offset(x: x - 5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let fps = Double(max(store.scene.fps, 1))
                    let t = min(max(Double(g.location.x) / w, 0), 1) * d
                    store.seek((t * fps).rounded() / fps)
                })
        }
        .frame(height: 12)
        .help("Drag to scrub")
    }
}

// MARK: - Layers

struct LayerListView: View {
    @Environment(SceneStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            List(selection: $store.selection) {
                ForEach(store.scene.layers.reversed()) { layer in
                    HStack(spacing: 8) {
                        Image(systemName: layer.type.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(layer.timelineColor)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(layer.timelineColor.opacity(0.15)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(layer.name).lineLimit(1)
                            if !layer.animatedTracks.isEmpty {
                                Text(layer.animatedTracks.map(\.name).joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if !layer.animatedTracks.isEmpty {
                            Image(systemName: "diamond.fill").font(.system(size: 7)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 1)
                    .tag(layer.id)
                    .contextMenu {
                        Button("Bring Forward") { store.move(layer.id, by: 1) }
                        Button("Send Backward") { store.move(layer.id, by: -1) }
                        Divider()
                        Button("Duplicate") { store.selection = layer.id; store.duplicateSelected() }
                        Button("Delete", role: .destructive) { store.selection = layer.id; store.deleteSelected() }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if store.scene.layers.isEmpty {
                    Text("No layers yet.\nAdd one from the toolbar or ask Claude.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("\(store.scene.layers.count) layers").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let id = store.selection {
                    Button { store.move(id, by: 1) } label: { Image(systemName: "arrow.up") }
                        .help("Bring forward")
                    Button { store.move(id, by: -1) } label: { Image(systemName: "arrow.down") }
                        .help("Send backward")
                    Button { store.duplicateSelected() } label: { Image(systemName: "plus.square.on.square") }
                        .help("Duplicate (⌘D)")
                    Button { store.deleteSelected() } label: { Image(systemName: "trash") }
                        .help("Delete (⌘⌫)")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 30)
        }
    }
}

// MARK: - Status

struct StatusBar: View {
    @Environment(SceneStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            AgentStatusButton()
            if let action = store.lastAgentAction {
                Text(action).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let p = store.exportProgress {
                Button { store.exportVideo() } label: {
                    HStack(spacing: 6) {
                        ProgressView(value: p).frame(width: 140).controlSize(.small)
                        Text("Exporting \(Int(p * 100))%").monospacedDigit()
                    }
                }
                .buttonStyle(.plain)
                .help("Show export progress")
            } else if let m = store.message {
                Text(m).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

// MARK: - JSON editor

struct JSONEditorSheet: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scene JSON").font(.headline)
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 720, minHeight: 520)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft, forType: .string)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { applyDraft() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { draft = SceneJSON.string(store.scene) }
    }

    private func applyDraft() {
        do {
            var s = try SceneJSON.decode(MotionScene.self, from: Data(draft.utf8))
            s.refreshMediaInfo()
            store.apply("Edit JSON") { $0 = s }
            dismiss()
        } catch let e {
            error = e.localizedDescription
        }
    }
}
