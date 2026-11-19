import AppKit
import SwiftUI
import VeyMotionCore

@MainActor
struct ContentView: View {
    @Environment(SceneStore.self) private var store
    @State private var showVoice = false
    @State private var showSoundEffect = false
    // Simple layout by default: canvas + chat. The left panel (Layers/Assets, with the Inspector under the layer
    // list) and the timeline are one click away; together with the canvas they are the workspace, and the chat is a
    // column of its own beside it, so it keeps its height whatever is open.
    // (`ui.` keys are newer ones, so existing installs got each new default once.)
    @AppStorage("ui.showSidebar") private var showSidebar = false
    @AppStorage("ui.showChat") private var showChat = true
    @AppStorage("timelineHeight") private var timelineHeight: Double = 240
    /// Hidden by default: most editing goes through Claude, so the canvas gets the space.
    /// The transport bar shows a compact scrubber instead.
    @AppStorage("showTimeline") private var showTimeline = false

    private static let editPanelMinWidth: CGFloat = 290
    private static let canvasMinWidth: CGFloat = 420

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

    /// The Layers/Inspector column, as the split view's sidebar (its own toggle and ⌃⌘S both drive `showSidebar`).
    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { showSidebar ? .all : .detailOnly },
                set: { v in showSidebar = v != .detailOnly })
    }

    /// Same frame as the Projects screen: Layers/Inspector as the (on macOS 26 floating, glass) sidebar, the canvas
    /// with transport and timeline as the detail, and the chat as the inspector column on the right.
    private var editor: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            EditPanel()
                .navigationSplitViewColumnWidth(min: Self.editPanelMinWidth, ideal: 320, max: 480)
        } detail: {
            VStack(spacing: 0) {
                CanvasView()
                    .overlay(alignment: .bottom) { CanvasToast().padding(.bottom, 10) }
                TransportBar()
                if showTimeline {
                    ResizeHandle(height: $timelineHeight, range: 140...700)
                    TimelinePanel().frame(height: timelineHeight)
                }
            }
            .frame(minWidth: Self.canvasMinWidth, maxWidth: .infinity)
            .inspector(isPresented: $showChat) {
                VStack(spacing: 0) {
                    ChatHeader()
                    Divider()
                    ChatPanel()
                }
                .inspectorColumnWidth(min: 290, ideal: 340, max: 560)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { store.showProjects = true } label: {
                    Label("Projects", systemImage: "square.grid.2x2")
                }
                .help("Back to Projects (⇧⌘P)")
            }
            // Left to right: make something, talk about a frame, then what the app wants to tell you, and the way
            // out (Export) as the one filled button, next to the toggle of the column under it.
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
                UpdateToolbarButton()
                UpgradeToolbarButton()
                Button { store.exportVideo() } label: {
                    Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .help("Export the video (⌘E)")
                Button { withAnimation(.easeOut(duration: 0.2)) { showChat.toggle() } } label: {
                    Label("Chat", systemImage: "sidebar.right")
                }
                .help("Show or hide the chat (⌘L)")
            }
        }
        .navigationTitle(store.project?.lastPathComponent ?? store.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
        .navigationSubtitle([store.project != nil ? "Project" : nil, store.isDirty ? "Edited" : nil]
            .compactMap { $0 }.joined(separator: " — "))
        .sheet(isPresented: $showVoice) { VoiceOverSheet() }
        .sheet(isPresented: $showSoundEffect) { SoundEffectSheet() }
        .sheet(isPresented: Bindable(store).showExport) { ExportSheet() }
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
            Menu("3D") {
                ForEach(ModelShape.allCases.filter { $0 != .file }, id: \.self) { s in Button(s.title) { store.addModel(s) } }
                Divider()
                Button("Model File (OBJ, STL, USDZ)…") { store.addModelLayer() }
            }
            Menu("Template") {
                ForEach(TemplateKind.allCases, id: \.self) { k in Button(k.title) { store.addTemplate(k) } }
            }
            Menu("Look") {
                ForEach(LookKind.allCases, id: \.self) { k in Button(k.title) { store.applyLook(k) } }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Add text, shapes, media, particles, generators, 3D objects or templates")
    }
}

/// Horizontal divider that can be dragged to resize the panel below it (or, with `growsDown`, the one above).
struct ResizeHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    var growsDown = false
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
                    let moved = Double(v.translation.height) * (growsDown ? 1 : -1)
                    height = min(max((startHeight ?? height) + moved, range.lowerBound), range.upperBound)
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
            renderer.motionBlurMaxSamples = job.fast ? 8 : 32
            renderer.modelSupersampling = job.fast ? 2 : 3
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

/// The canvas's zoom and pan: how the preview is looked at, never part of the scene. `zoom` is relative to the frame
/// fitted in the canvas (1 = Fit, the least); `pan` is the frame center's offset from the canvas center in points,
/// and stays zero on an axis where the whole frame fits. Shared, so the View menu and the transport bar can drive it.
@Observable
final class CanvasViewport {
    static let shared = CanvasViewport()
    static let maxZoom = 16.0
    /// Room kept around the fitted frame, each side.
    static let margin: CGFloat = 20

    private(set) var zoom = 1.0
    private(set) var pan = CGSize.zero
    /// Reported by the canvas: its size, the fitted frame's size (points) and the scene's width (px).
    private(set) var canvas = CGSize.zero
    private(set) var fit = CGSize(width: 1, height: 1)
    private(set) var sceneWidth = 1.0
    @ObservationIgnored var hovering = false
    /// The pointer over the canvas, in its coordinates: what ⌘-scroll zooms around.
    @ObservationIgnored var mouse: CGPoint?
    @ObservationIgnored var pinchBase: Double?
    @ObservationIgnored var monitor: Any?

    var isFit: Bool { zoom <= 1.0001 }
    /// Points per scene px.
    var unit: Double { Double(fit.width) * zoom / max(sceneWidth, 1) }
    /// The scale as people read it: 100% = one scene px per point.
    var percent: Int { Int((unit * 100).rounded()) }

    func layout(canvas: CGSize, fit: CGSize, sceneWidth: Double) {
        self.canvas = canvas; self.fit = fit; self.sceneWidth = sceneWidth
        clamp()
    }

    /// Zooms keeping the point under `anchor` (canvas coordinates; nil = the canvas center) where it is.
    func setZoom(_ z: Double, anchor: CGPoint? = nil) {
        let new = min(max(z, 1), Self.maxZoom)
        guard new != zoom else { return }
        let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        let a = anchor ?? center
        let k = new / zoom
        let frame = CGPoint(x: center.x + pan.width, y: center.y + pan.height)
        pan = CGSize(width: a.x - (a.x - frame.x) * k - center.x, height: a.y - (a.y - frame.y) * k - center.y)
        zoom = new
        clamp()
    }

    func setPercent(_ percent: Double) {
        setZoom(percent / 100 * max(sceneWidth, 1) / max(Double(fit.width), 1))
    }

    func zoomIn() { setZoom(zoom * 1.5) }
    func zoomOut() { setZoom(zoom / 1.5) }

    func scroll(dx: Double, dy: Double) {
        pan = CGSize(width: pan.width + dx, height: pan.height + dy)
        clamp()
    }

    func reset() {
        zoom = 1
        pan = .zero
    }

    /// The frame never leaves a gap wider than the margin on a side it reaches past.
    private func clamp() {
        let roomX = max(0, (fit.width * zoom - (canvas.width - 2 * Self.margin)) / 2)
        let roomY = max(0, (fit.height * zoom - (canvas.height - 2 * Self.margin)) / 2)
        let clamped = CGSize(width: min(max(pan.width, -roomX), roomX), height: min(max(pan.height, -roomY), roomY))
        if clamped != pan { pan = clamped }
    }
}

struct CanvasView: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.displayScale) private var displayScale
    @State private var preview = PreviewRenderer()
    @State private var drag: CanvasDrag?
    @State private var dropTargeted = false
    private let annotations = AnnotationStore.shared
    private let viewport = CanvasViewport.shared
    /// Measures layers for clicks and the selection outline. Main thread only (the preview has its own renderer).
    private static let picker = FrameRenderer()

    /// A press on the canvas: the layer under it, and whether it has turned into a move.
    private struct CanvasDrag {
        var layer: String?
        var moving = false
    }

    private struct FrameKey: Equatable {
        var revision: Int
        var time: Double
        var scale: Double
    }

    private struct CacheSource: Equatable {
        var revision: Int
        var pixelWidth: Int
    }

    private struct Layout: Equatable {
        var canvas: CGSize
        var fit: CGSize
        var sceneWidth: Int
    }

    var body: some View {
        GeometryReader { geo in
            let scene = store.scene
            let aspect = Double(scene.width) / Double(scene.height)
            let avail = CGSize(width: max(geo.size.width - 2 * CanvasViewport.margin, 10),
                               height: max(geo.size.height - 2 * CanvasViewport.margin, 10))
            let fit = avail.width / avail.height > aspect
                ? CGSize(width: avail.height * aspect, height: avail.height)
                : CGSize(width: avail.width, height: avail.width / aspect)
            // Render at the canvas's real pixel size (not capped at the scene size, so vector content stays sharp
            // when the canvas is larger than the scene); while playing, at most 1.5 px/pt to keep frames cheap.
            // The RAM preview cache holds frames at the playback density.
            let playDensity = min(displayScale, 1.5)
            // Zoomed in (and paused), the frame is rendered larger so the detail looked at is real, up to twice the
            // scene's size (4096 px at most): past that the picture is enlarged. Playing always renders at the
            // fitted size, the one the RAM preview holds.
            let zoom = viewport.zoom, pan = viewport.pan
            let fitScale = fit.width * displayScale / Double(scene.width)
            let sharpest = max(fitScale, min(2, 4096 / Double(max(scene.width, scene.height))))
            let scale = store.isPlaying ? fit.width * playDensity / Double(scene.width) : min(fitScale * zoom, sharpest)
            let shown = CGSize(width: fit.width * zoom, height: fit.height * zoom)
            let unit = shown.width / Double(scene.width) // points per scene px
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2 + pan.width,
                                 y: (geo.size.height - shown.height) / 2 + pan.height)
            let key = FrameKey(revision: store.sceneRevision, time: store.time, scale: scale)
            let cacheSource = CacheSource(revision: store.sceneRevision,
                                          pixelWidth: FrameCache.pixelWidth(scene, scale: fit.width * playDensity / Double(scene.width)))
            ZStack {
                if let img = preview.image {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: shown.width, height: shown.height)
                        // A hairline just outside the picture, so a dark scene still has an edge on the dark stage.
                        .overlay(Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1).padding(-0.5))
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                }
                if scene.layers.isEmpty, !annotations.isActive {
                    EmptySceneHint(onLight: scene.background.r * 0.2126 + scene.background.g * 0.7152
                        + scene.background.b * 0.0722 > 0.5)
                        .frame(width: shown.width, height: shown.height)
                        .allowsHitTesting(false)
                }
                // Not while playing: the preview stays clean and nothing is measured per frame.
                if !annotations.isActive, !store.isPlaying, let id = store.selection,
                   let outline = Self.picker.selectionOutline(of: id, in: scene, at: store.time) {
                    Path(outline)
                        .applying(CGAffineTransform(scaleX: unit, y: unit))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: shown.width, height: shown.height)
                        .allowsHitTesting(false)
                }
                if annotations.isActive {
                    AnnotationOverlay(annotations: annotations, unit: unit)
                        .frame(width: shown.width, height: shown.height)
                }
            }
            .offset(pan)
            // A fixed frame, not a flexible one: zoomed in, the picture is larger than the canvas and must hang
            // over its edges (cut off there) instead of making the canvas as large as itself.
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            // While marking up a frame the presses belong to the marks.
            .gesture(pickAndMove(origin: origin, unit: unit), including: annotations.isActive ? .subviews : .all)
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    if viewport.pinchBase == nil { viewport.pinchBase = viewport.zoom }
                    viewport.setZoom((viewport.pinchBase ?? 1) * Double(v.magnification), anchor: v.startLocation)
                }
                .onEnded { _ in viewport.pinchBase = nil })
            .onHover { viewport.hovering = $0 }
            .onContinuousHover { phase in
                if case let .active(p) = phase { viewport.mouse = p } else { viewport.mouse = nil }
            }
            .onChange(of: Layout(canvas: geo.size, fit: fit, sceneWidth: scene.width), initial: true) { _, l in
                viewport.layout(canvas: l.canvas, fit: l.fit, sceneWidth: Double(l.sceneWidth))
            }
            // Another document is looked at from the start: fitted.
            .onChange(of: store.documentRevision) { viewport.reset() }
            .overlay(alignment: .top) {
                if annotations.isActive {
                    AnnotationToolbar(annotations: annotations, unit: unit)
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
                FrameCache.shared.follow(k.time, playing: store.isPlaying)
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
        .background(Color.stage)
        .onAppear(perform: installScrollMonitor)
        .onDisappear(perform: removeScrollMonitor)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        // Drop images/audio from the Assets panel or Finder to add them as layers.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            files.forEach { store.addFileLayer($0.path) }
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }
}

extension Color {
    /// The surround of the preview: dark and neutral in both appearances, like a viewing room, so the picture's own
    /// colors and brightness are judged against nothing brighter than it.
    static let stage = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.07 : 0.15, alpha: 1)
    })
}

/// Over the frame of a scene with no layers: the two ways to start.
private struct EmptySceneHint: View {
    /// The scene's background is light, so the hint is written dark.
    let onLight: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles").font(.title2)
            Text("Describe the video you want in the chat").font(.callout.weight(.medium))
            Text("or drop images, video and audio here").font(.caption)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle((onLight ? Color.black : Color.white).opacity(0.55))
        .padding(12)
    }
}

extension CanvasView {
    /// Over the canvas: ⌘-scroll zooms around the pointer, and once zoomed in a plain scroll (two fingers, or the
    /// wheel, ⇧ for sideways) moves the picture. Fitted, scrolling is left alone.
    private func installScrollMonitor() {
        let viewport = viewport
        guard viewport.monitor == nil else { return }
        viewport.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard viewport.hovering, e.window?.attachedSheet == nil else { return e }
            let precise = e.hasPreciseScrollingDeltas
            if e.modifierFlags.contains(.command) {
                viewport.setZoom(viewport.zoom * exp(Double(e.scrollingDeltaY) * (precise ? 0.01 : 0.1)), anchor: viewport.mouse)
                return nil
            }
            guard !viewport.isFit else { return e }
            var dx = Double(e.scrollingDeltaX), dy = Double(e.scrollingDeltaY)
            if e.modifierFlags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
            if !precise { dx *= 10; dy *= 10 }
            viewport.scroll(dx: dx, dy: dy)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let m = viewport.monitor { NSEvent.removeMonitor(m) }
        viewport.monitor = nil
    }

    /// The layer a press at `p` (scene px) is on. Outside the frame there is nothing to see, so nothing to pick.
    private func layer(at p: CGPoint) -> String? {
        let scene = store.scene
        guard CGRect(x: 0, y: 0, width: scene.width, height: scene.height).contains(p) else { return nil }
        return Self.picker.layerHit(in: scene, at: p, time: store.time)
    }

    /// Click: select the layer under the pointer, or nothing. Drag: move that layer (one undo step; ⇧ keeps it on
    /// one axis). A layer that fills the frame is only dragged once it is selected (from the Layers list), so a
    /// drag on the backdrop moves nothing by accident.
    private func pickAndMove(origin: CGPoint, unit: Double) -> some Gesture {
        func scenePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / unit, y: (p.y - origin.y) / unit) }
        return DragGesture(minimumDistance: 0)
            .onChanged { g in
                if drag == nil {
                    let p = scenePoint(g.startLocation)
                    var target = layer(at: p)
                    if target == nil, let id = store.selection,
                       Self.picker.selectionOutline(of: id, in: store.scene, at: store.time)?.contains(p) == true {
                        target = id
                    }
                    drag = CanvasDrag(layer: target)
                }
                guard let id = drag?.layer, !store.isPlaying else { return }
                if drag?.moving != true {
                    guard hypot(g.translation.width, g.translation.height) >= 3 else { return }
                    // Say why a layer cannot be moved (its position is linked…) instead of ignoring the drag.
                    var probe = store.scene
                    do {
                        try probe.moveLayer(id, byFrame: .zero, at: store.time)
                    } catch {
                        store.message = error.localizedDescription
                        drag?.layer = nil
                        return
                    }
                    store.selection = id
                    store.beginInteractive("Move Layer")
                    drag?.moving = true
                }
                var dx = Double(g.translation.width) / unit, dy = Double(g.translation.height) / unit
                if NSEvent.modifierFlags.contains(.shift) {
                    if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
                }
                let t = store.time
                store.updateInteractive { try $0.moveLayer(id, byFrame: CGVector(dx: dx, dy: dy), at: t) }
            }
            .onEnded { g in
                defer { drag = nil }
                if drag?.moving == true {
                    store.endInteractive()
                } else {
                    store.selection = layer(at: scenePoint(g.startLocation))
                }
            }
    }
}

/// Playback controls under the canvas, on the window's own background so they read as a bar and not as part of the
/// stage: timecode on the left, transport centered, the scene's format and the Timeline switch on the right.
/// With the timeline hidden, a compact scrubber sits above the controls.
struct TransportBar: View {
    @Environment(SceneStore.self) private var store
    @AppStorage("showTimeline") private var showTimeline = false
    @AppStorage("ui.showSidebar") private var showSidebar = false
    @AppStorage("leftPanelTab") private var leftTab: LeftPanelTab = .layers

    var body: some View {
        VStack(spacing: 0) {
            if !showTimeline {
                MiniScrubber()
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            // As the canvas column narrows: the format goes first, then the duration and the Timeline switch's title.
            GeometryReader { geo in controls(showsFormat: geo.size.width >= 700, compact: geo.size.width < 520) }
                .frame(height: 44)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func controls(showsFormat: Bool, compact: Bool) -> some View {
        let s = store.scene
        return ZStack {
            HStack(spacing: 6) {
                Text(timecode(store.time, fps: s.fps))
                    .font(.system(.callout, design: .monospaced).weight(.medium))
                if !compact {
                    Text("/ \(timecode(s.duration, fps: s.fps))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ZoomMenu().padding(.trailing, 4)
                if showsFormat {
                    // The scene's settings are what the Inspector shows with nothing selected.
                    Button {
                        store.selection = nil
                        leftTab = .layers
                        withAnimation(.easeOut(duration: 0.2)) { showSidebar = true }
                    } label: {
                        Text("\(s.width)×\(s.height) · \(s.fps) fps")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .help("Scene size and frame rate. Click to change them.")
                    .padding(.trailing, 8)
                }
                Button { withAnimation(.easeOut(duration: 0.2)) { showTimeline.toggle() } } label: {
                    Label("Timeline", systemImage: "rectangle.bottomthird.inset.filled")
                        .labelStyle(TimelineLabelStyle(iconOnly: compact))
                        .font(.callout)
                        .foregroundStyle(showTimeline ? Color.accentColor : Color.secondary)
                }
                .help(showTimeline ? "Hide the Timeline (⌃⌘T)" : "Show the Timeline: layers in time, keyframes and curves (⌃⌘T)")
            }
            // Frame stepping stays on ⌘← / ⌘→ (Playback menu).
            HStack(spacing: 12) {
                Button { store.seek(0) } label: {
                    Image(systemName: "backward.end.fill").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .help("Go to start (⇧⌘←)")
                Button { store.togglePlay() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                        .contentShape(Circle())
                }
                .help("Play / pause (Space)")
                // Keeps Play on the bar's center line.
                Color.clear.frame(width: 28, height: 28)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    /// mm:ss:ff
    private func timecode(_ t: Double, fps: Int) -> String {
        let frames = Int((t * Double(fps)).rounded())
        let f = max(fps, 1)
        return String(format: "%02d:%02d:%02d", frames / f / 60, frames / f % 60, frames % f)
    }
}

/// Title and icon, or the icon alone where the bar is short of room.
private struct TimelineLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            if !iconOnly { configuration.title }
        }
    }
}

/// "Fit ⌄" / "150% ⌄" in the transport bar: how large the preview is shown, and the ways to change it.
private struct ZoomMenu: View {
    private let viewport = CanvasViewport.shared

    var body: some View {
        Menu {
            Button("Zoom In") { viewport.zoomIn() }.disabled(viewport.zoom >= CanvasViewport.maxZoom)
            Button("Zoom Out") { viewport.zoomOut() }.disabled(viewport.isFit)
            Divider()
            Button("Fit") { viewport.reset() }
            // Sizes smaller than the fitted frame would only add empty stage.
            ForEach([100, 200, 400], id: \.self) { p in
                if Double(p) / 100 * viewport.sceneWidth > Double(viewport.fit.width) * 1.02 {
                    Button("\(p)%") { viewport.setPercent(Double(p)) }
                }
            }
        } label: {
            Text(viewport.isFit ? "Fit" : "\(viewport.percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(viewport.isFit ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Preview size. Pinch or ⌘-scroll over the preview to zoom, scroll to move around, ⌘0 to fit.")
    }
}

/// Thin click/drag scrubber over the whole scene, used while the full timeline is hidden. It thickens under the
/// pointer, and the whole 16 pt strip takes the press, not only the 4 pt line.
struct MiniScrubber: View {
    @Environment(SceneStore.self) private var store
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(Double(geo.size.width), 1)
            let d = max(store.scene.duration, 0.001)
            let x = min(max(store.time / d, 0), 1) * w
            let active = hovering || dragging
            let track: CGFloat = active ? 6 : 4, thumb: CGFloat = active ? 14 : 10
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: track)
                // Frames held in the RAM preview cache, just under the track.
                CachedFramesStrip(pointsPerSecond: w / d).offset(y: track / 2 + 2)
                Capsule().fill(Color.accentColor).frame(width: x, height: track)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .frame(width: thumb, height: thumb)
                    .offset(x: x - thumb / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: active)
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    let fps = Double(max(store.scene.fps, 1))
                    let t = min(max(Double(g.location.x) / w, 0), 1) * d
                    store.seek((t * fps).rounded() / fps)
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 16)
        .help("Drag to scrub")
    }
}

// MARK: - Layers

/// The left panel: everything edited by hand. Layers, with the Inspector of the selected one under the list (the
/// scene's own settings when nothing is selected), or the Assets library.
struct EditPanel: View {
    @AppStorage("leftPanelTab") private var tab: LeftPanelTab = .layers
    @AppStorage("ui.layerListHeight") private var listHeight: Double = 220

    var body: some View {
        VStack(spacing: 0) {
            PanelTabBar(selection: $tab)
            Divider()
            switch tab {
            case .layers:
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        // The list never takes more than 60% of the panel: the Inspector is the reason to open it.
                        LayerListView()
                            .frame(height: min(max(listHeight, 90), max(Double(geo.size.height) * 0.6, 90)))
                        ResizeHandle(height: $listHeight, range: 90...600, growsDown: true)
                        InspectorView()
                    }
                }
            case .assets:
                AssetsPanel()
            }
        }
    }
}

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

/// What the store has to say, floating over the bottom of the canvas so it takes no room and moves nothing: a running
/// export, a finished one, an error or note (`store.message`, gone after a few seconds or on a click), and a failed
/// agent connection.
struct CanvasToast: View {
    @Environment(SceneStore.self) private var store

    private var agentsFailed: Bool { store.controlStatus.hasPrefix("Failed") || store.mcpStatus.hasPrefix("Failed") }

    private var exportDone: URL? {
        guard store.exportProgress == nil, store.exportResultUnseen, case let .done(url, _)? = store.exportResult else { return nil }
        return url
    }

    private var isEmpty: Bool {
        !agentsFailed && store.exportProgress == nil && exportDone == nil && store.message == nil
    }

    var body: some View {
        // A container that is there while empty, so the pill animates in and out.
        ZStack {
            if !isEmpty {
                HStack(spacing: 10) { content }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 30)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: isEmpty)
        .task(id: store.message) {
            guard let m = store.message else { return }
            try? await Task.sleep(for: .seconds(6))
            if store.message == m { store.message = nil }
        }
    }

    @ViewBuilder private var content: some View {
        if agentsFailed { AgentStatusButton() }
        if let p = store.exportProgress {
            Button { store.exportVideo() } label: {
                HStack(spacing: 6) {
                    ProgressView(value: p).frame(width: 120).controlSize(.small)
                    Text("Exporting \(Int(p * 100))%").monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .help("Show export progress")
        } else if let url = exportDone {
            Button { store.exportVideo() } label: {
                Label("Exported \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help("Show the export result")
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(.link)
        } else if let m = store.message {
            Button { store.message = nil } label: {
                Text(m).lineLimit(2).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .help("Click to dismiss")
        }
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
