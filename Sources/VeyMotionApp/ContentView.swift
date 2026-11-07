import AppKit
import SwiftUI
import VeyMotionCore

struct ContentView: View {
    @Environment(SceneStore.self) private var store
    @State private var showVoice = false
    @State private var showSoundEffect = false
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
                Button { withAnimation(.easeOut(duration: 0.2)) { showSidebar.toggle() } } label: {
                    Label("Layers & Assets", systemImage: "sidebar.left")
                }
                .help("Show or hide Layers & Assets (⌃⌘S)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                addMenu
                Button {
                    let a = AnnotationStore.shared
                    withAnimation(.easeOut(duration: 0.15)) { a.isActive ? a.close() : a.begin() }
                } label: {
                    Label("Annotate", systemImage: "pencil.tip.crop.circle")
                        .foregroundStyle(AnnotationStore.shared.isActive ? Color.accentColor : Color.primary)
                }
                .help("Pause and mark up this frame, then send it to Claude (⇧⌘A)")
                .keyboardShortcut("a", modifiers: [.command, .shift])
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
                Menu {
                    Button("Export Video…") { store.exportVideo() }
                    Button("Publish…") { store.showPublish = true }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export or publish the video (⌘E)")
                Button { withAnimation(.easeOut(duration: 0.2)) { showInspector.toggle() } } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the Inspector (⌥⌘I)")
            }
        }
        .navigationTitle(store.project?.lastPathComponent ?? store.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
        .navigationSubtitle([store.project != nil ? "Project" : nil, store.isDirty ? "Edited" : nil]
            .compactMap { $0 }.joined(separator: " — "))
        .sheet(isPresented: $showVoice) { VoiceOverSheet() }
        .sheet(isPresented: $showSoundEffect) { SoundEffectSheet() }
        .sheet(isPresented: Bindable(store).showExport) { ExportSheet() }
        .sheet(isPresented: Bindable(store).showPublish) { PublishSheet() }
    }
}

extension ContentView {
    /// One menu for everything that can be added to the scene.
    fileprivate var addMenu: some View {
        Menu {
            Button { store.addLayer(.text) } label: { Label("Text", systemImage: "textformat") }
            Button { store.addLayer(.rect) } label: { Label("Rectangle", systemImage: "rectangle") }
            Button { store.addLayer(.ellipse) } label: { Label("Ellipse", systemImage: "circle") }
            Button { store.addLayer(.path) } label: { Label("Path", systemImage: "scribble.variable") }
            Divider()
            Button { store.addImageLayer() } label: { Label("Image…", systemImage: "photo") }
            Button { store.addVideoLayer() } label: { Label("Video or Image Sequence…", systemImage: "film") }
            Button { store.addAudioLayer() } label: { Label("Audio…", systemImage: "music.note") }
            Button { showVoice = true } label: { Label("Voice-over…", systemImage: "mic") }
            Button { showSoundEffect = true } label: { Label("Sound Effect…", systemImage: "waveform") }
            Divider()
            Menu("Particles") {
                ForEach(ParticlePreset.allCases, id: \.self) { p in Button(p.title) { store.addParticles(p) } }
            }
            Menu("Generator") {
                ForEach(GeneratorKind.allCases, id: \.self) { k in Button(k.title) { store.addGenerator(k) } }
            }
            Menu("Template") {
                ForEach(TemplateKind.allCases, id: \.self) { k in Button(k.title) { store.addTemplate(k) } }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Add text, shapes, media, particles, generators or templates")
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
/// Frames in the `FrameCache` (RAM preview) are shown at once; rendered frames are added to it.
@Observable
final class PreviewRenderer {
    private(set) var image: CGImage?
    @ObservationIgnored private let queue = DispatchQueue(label: "VeyMotion.preview", qos: .userInteractive)
    @ObservationIgnored private let renderer = FrameRenderer() // only used on `queue`
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var pending: Job?
    /// Requests are numbered so a slow render finishing late never replaces a newer frame shown from the cache.
    @ObservationIgnored private var lastRequest = 0
    @ObservationIgnored private var shownRequest = 0

    private struct Job {
        var scene: MotionScene
        var time: Double
        var scale: Double
        var fast: Bool
        var id: Int
        var cacheKey: FrameCache.Key?
    }

    /// Call on the main thread. `fast` (while playing) renders motion blur with fewer samples. With `cacheKey`
    /// a cached frame is shown immediately (and, when it already has the requested size, nothing is rendered).
    func request(_ scene: MotionScene, at time: Double, scale: Double, fast: Bool = false,
                 cacheKey: FrameCache.Key? = nil) {
        lastRequest += 1
        if let cacheKey, let img = FrameCache.shared.image(at: time, fps: scene.fps, key: cacheKey) {
            image = img
            shownRequest = lastRequest
            // Playing, or the cached frame is the canvas's size: nothing sharper to render.
            if fast || img.width == FrameCache.pixelWidth(scene, scale: scale) {
                pending = nil
                return
            }
        }
        pending = Job(scene: scene, time: time, scale: scale, fast: fast, id: lastRequest, cacheKey: cacheKey)
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
            renderer.motionBlurSamples = job.fast ? 4 : 8
            // Opening a project with music-reactive layers must not hold the canvas until the song is analyzed.
            let img = AudioAnalysisCache.withoutWaiting {
                renderer.makeImage(job.scene, at: job.time, scale: job.scale)
            }
            // Kept only at the playback size (the cache checks); frames drawn before an audio analysis was ready
            // are dropped by the `invalidate()` that follows `didAnalyze`.
            if let img, let key = job.cacheKey {
                FrameCache.shared.insert(img, at: job.time, fps: job.scene.fps, key: key)
            }
            DispatchQueue.main.async {
                if job.id >= self.shownRequest {
                    self.image = img
                    self.shownRequest = job.id
                }
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
    private let annotations = AnnotationStore.shared

    private struct FrameKey: Equatable {
        var revision: Int
        var time: Double
        var scale: Double
    }

    private struct CacheSource: Equatable {
        var revision: Int
        var pixelWidth: Int
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
            // The RAM preview cache holds frames at the playback density.
            let playDensity = min(displayScale, 1.5)
            let density = store.isPlaying ? playDensity : displayScale
            let scale = fit.width * density / Double(scene.width)
            let key = FrameKey(revision: store.sceneRevision, time: store.time, scale: scale)
            let cacheSource = CacheSource(revision: store.sceneRevision,
                                          pixelWidth: FrameCache.pixelWidth(scene, scale: fit.width * playDensity / Double(scene.width)))
            ZStack {
                if let img = preview.image {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                }
                if !annotations.isActive, let layer = store.selectedLayer, layer.type.isVisual, layer.type != .text,
                   layer.isVisible(at: store.time, sceneDuration: scene.duration) {
                    SelectionBox(layer: layer, scene: scene, time: store.time, unit: fit.width / Double(scene.width))
                        .frame(width: fit.width, height: fit.height)
                }
                if annotations.isActive {
                    AnnotationOverlay(annotations: annotations, unit: fit.width / Double(scene.width))
                        .frame(width: fit.width, height: fit.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if annotations.isActive {
                    AnnotationToolbar(annotations: annotations, unit: fit.width / Double(scene.width))
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            // Marks belong to the frame they were drawn on: leaving it (playing, another document) drops them.
            .onChange(of: store.documentRevision) { annotations.close() }
            .onChange(of: store.isPlaying) { _, playing in if playing { annotations.close() } }
            // Before the new document's first frame (declared first, so it runs first; the queue is serial).
            .onChange(of: store.documentRevision) {
                preview.clearCaches()
                FrameCache.shared.purge(dropRenderers: true)
            }
            // Before `key` (same update, declared first), so the request below already sees the new cache key.
            .onChange(of: cacheSource, initial: true) { _, s in
                FrameCache.shared.setSource(store.scene, revision: s.revision, pixelWidth: s.pixelWidth, playhead: store.time)
            }
            .onChange(of: key, initial: true) { _, k in
                preview.request(store.scene, at: k.time, scale: k.scale, fast: store.isPlaying, cacheKey: FrameCache.shared.key)
            }
            // An image file overwritten in place (e.g. by write_asset) leaves the scene unchanged.
            .onChange(of: AssetLibrary.shared.assets) {
                FrameCache.shared.invalidate()
                preview.request(store.scene, at: key.time, scale: key.scale, cacheKey: FrameCache.shared.key)
            }
            .onReceive(NotificationCenter.default.publisher(for: AudioAnalysisCache.didAnalyze)) { _ in
                FrameCache.shared.invalidate()
                preview.request(store.scene, at: key.time, scale: key.scale, fast: store.isPlaying,
                                cacheKey: FrameCache.shared.key)
            }
            .onChange(of: store.exportProgress != nil, initial: true) { _, exporting in
                FrameCache.shared.isSuspended = exporting
            }
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
        let screen = scene.worldTransform(of: layer, at: time)
        Path(box)
            .applying(screen.concatenating(CGAffineTransform(scaleX: unit, y: unit)))
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .allowsHitTesting(false)
    }

    private var box: CGRect {
        if layer.type == .path {
            let b = layer.pathShape(at: time).cgPath.boundingBoxOfPath
            return b.isNull ? .zero : b
        }
        let (w, h) = boxSize
        return CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    }

    private var boxSize: (Double, Double) {
        if layer.type == .particles && layer.particles.emitter == .point && layer.particles.from == nil { return (24, 24) }
        let size = { (v: AnimValue?, fallback: Double) -> Double in
            let x = v?.value(at: time) ?? 0
            return x > 0 ? x : fallback
        }
        return (layer.type.hasNaturalSize ? size(layer.width, 400) : layer.shapeWidth(at: time),
                layer.type.hasNaturalSize ? size(layer.height, 240) : layer.shapeHeight(at: time))
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
                // Frames held in the RAM preview cache, just under the track.
                CachedFramesStrip(pointsPerSecond: w / d).offset(y: 4)
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
            } else if store.exportResultUnseen, case let .done(url, _)? = store.exportResult {
                Button { store.exportVideo() } label: {
                    Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Show the export result (Show in Finder, Publish)")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
            } else if let m = store.message {
                Text(m).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

// MARK: - Versions

/// The scene after each prompt to Claude, newest first; any of them can be put back.
struct VersionsPopover: View {
    @Environment(SceneStore.self) private var store
    @Environment(ChatStore.self) private var chat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Versions").font(.headline).padding(12)
            Divider()
            if chat.versions.isEmpty {
                Text("Each prompt to Claude that changes the scene is kept here, so you can go back to it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(chat.versions.enumerated().reversed()), id: \.element.id) { i, v in
                            VersionRow(version: v, number: i, isCurrent: v.scene == store.scene) { chat.restore(v) }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 520)
            }
        }
        .frame(width: 380)
    }
}

private struct VersionRow: View {
    let version: ChatStore.Version
    let number: Int
    let isCurrent: Bool
    let restore: () -> Void
    @State private var thumb: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12))
                if let thumb { Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit) }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(isCurrent ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isCurrent ? 2 : 1))
            VStack(alignment: .leading, spacing: 3) {
                Text(version.prompt ?? "Before Claude's changes")
                    .font(.callout).lineLimit(3)
                    .foregroundStyle(version.prompt == nil ? .secondary : .primary)
                HStack(spacing: 4) {
                    if version.prompt != nil { Text("v\(number)") }
                    Text(version.date, format: .relative(presentation: .named))
                    Text("·")
                    Text(String(format: "%.1fs · %d layers", version.scene.duration, version.scene.layers.count))
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Text("Current").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Restore", action: restore).controlSize(.small)
                    .help("Put this version back (undo with ⌘Z)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .help(version.prompt ?? "")
        .onAppear(perform: loadThumb)
    }

    private static var cache: [UUID: NSImage] = [:]
    private static let queue = DispatchQueue(label: "VeyMotion.versionThumbnails", qos: .userInitiated)
    private static let renderer = FrameRenderer()

    private func loadThumb() {
        let id = version.id
        if let cached = Self.cache[id] { thumb = cached; return }
        let scene = version.scene
        Self.queue.async {
            let scale = 192 / Double(max(scene.width, 1))
            let cg = Self.renderer.makeImage(scene, at: scene.duration / 2, scale: scale)
            DispatchQueue.main.async {
                let image = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                if let image { Self.cache[id] = image }
                thumb = image
            }
        }
    }
}
