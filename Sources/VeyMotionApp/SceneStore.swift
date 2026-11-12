import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import VeyMotionCore
import VeyMotionMCP

/// Single source of truth for the editor. UI edits and MCP edits both go through `apply`, so both are undoable.
@Observable
final class SceneStore: SceneHost {
    static let shared = SceneStore()

    var scene: MotionScene = .sample {
        didSet { sceneRevision &+= 1 }
    }
    /// Bumped on every scene change, so views can react without comparing whole scenes.
    private(set) var sceneRevision = 0
    var selection: String?
    var time: Double = 0 {
        didSet { if !isPlaying { panelTime = time } }
    }
    /// The playhead as read by inspector and timeline values: held while playing, so those panels
    /// don't re-render every frame.
    private(set) var panelTime: Double = 0
    var isPlaying = false
    var fileURL: URL?
    /// The open project folder (scene.json + assets/), or nil when editing a loose scene file.
    private(set) var project: URL?
    private(set) var recentProjects: [URL] = SceneStore.loadRecentProjects()
    var showNewProject = false
    /// The Projects screen; shown when the app starts. Playback stops while it covers the editor.
    var showProjects = true {
        didSet { if showProjects { pause() } }
    }
    /// Bumped whenever another scene replaces the open one (project switch, open, new), so views can drop
    /// state that belonged to the old document (timeline zoom, render caches…).
    private(set) var documentRevision = 0
    /// Called (on the main thread) when the open project changes; the chat keeps one conversation per project.
    @ObservationIgnored var onProjectChange: ((ProjectChange) -> Void)?
    var isDirty = false
    var mcpStatus = "Starting…"
    /// The Export sheet (options, then live progress).
    var showExport = false
    /// File > Publish Video… (publish an exported file to YouTube, TikTok, Facebook or X).
    var showPublish = false
    /// Non-nil while an export is running (0…1).
    var exportProgress: Double?
    private(set) var exportStartedAt: Date?
    /// Result of the last export, shown in the Export sheet until the next one starts.
    private(set) var exportResult: ExportResult?
    /// The export finished while its sheet was hidden: the status bar offers the result until it is opened.
    private(set) var exportResultUnseen = false
    @ObservationIgnored private var exportCancel: CancelFlag?
    var message: String?
    var lastAgentAction: String?

    private(set) var undoStack: [(label: String, scene: MotionScene)] = []
    private(set) var redoStack: [(label: String, scene: MotionScene)] = []

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var playAnchor: (date: Date, time: Double)?
    @ObservationIgnored private var mcp: MCPHTTPServer?
    @ObservationIgnored private var controlSocket: ControlSocketServer?
    var controlStatus = "Starting…"
    @ObservationIgnored let audio = AudioPreview()

    static let mcpPort: UInt16 = 19790
    var mcpEndpoint: String { "http://127.0.0.1:\(Self.mcpPort)/mcp" }
    var claudeCommand: String { "claude mcp add --transport http veymotion \(mcpEndpoint)" }

    var selectedLayer: MotionLayer? {
        guard let selection else { return nil }
        return scene.layers.first { $0.id == selection }
    }

    // MARK: - Mutations

    func apply(_ label: String, _ body: (inout MotionScene) throws -> Void) rethrows {
        // A discrete edit (e.g. from the agent) during a drag ends the drag first, so neither is lost.
        if interactiveBase != nil { endInteractive() }
        var s = scene
        try body(&s)
        guard s != scene else { return }
        undoStack.append((label, scene))
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        commit(s)
    }

    private func commit(_ s: MotionScene) {
        scene = s
        isDirty = true
        if let sel = selection, !s.layers.contains(where: { $0.id == sel }) { selection = nil }
        time = min(time, s.duration)
        scheduleAutosave()
    }

    // MARK: - Autosave

    @ObservationIgnored private var autosaveWork: DispatchWorkItem?

    /// A project has a fixed place on disk, so its edits are written shortly after they happen. Saving only on
    /// quit loses everything when the app is killed (Ctrl+C on `swift run`, a crash, a rebuild).
    private func scheduleAutosave() {
        guard project != nil else { return }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // A drag in progress reschedules from endInteractive; load/open clear isDirty, so they skip this.
            guard let self, self.project != nil, self.isDirty, !self.isInteracting else { return }
            self.saveProject(quiet: true)
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - Interactive edits (drags): live updates, one undo step per gesture

    @ObservationIgnored private var interactiveBase: MotionScene?
    @ObservationIgnored private var interactiveLabel = ""

    var isInteracting: Bool { interactiveBase != nil }

    /// Starts a gesture. Each `updateInteractive` re-applies its change to the scene as it was at the start,
    /// so drags never accumulate rounding errors.
    func beginInteractive(_ label: String) {
        guard interactiveBase == nil else { return }
        interactiveBase = scene
        interactiveLabel = label
    }

    func updateInteractive(_ body: (inout MotionScene) throws -> Void) {
        guard let base = interactiveBase else { return }
        var s = base
        do { try body(&s) } catch { return }
        if s != scene { scene = s }
    }

    func endInteractive() {
        guard let base = interactiveBase else { return }
        interactiveBase = nil
        guard scene != base else { return }
        undoStack.append((interactiveLabel, base))
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
        isDirty = true
        scheduleAutosave()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((last.label, scene))
        commit(last.scene)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((next.label, scene))
        commit(next.scene)
    }

    /// Changes one animatable property at the playhead (upserts a keyframe if the property is animated).
    func setValue(_ id: String, _ p: AnimProperty, _ v: Double) {
        try? apply("Change \(p.rawValue)") { try $0.setValue(id, property: p, value: v, at: time) }
    }

    func toggleAnimation(_ id: String, _ p: AnimProperty) { toggleAnimation(id, .number(p)) }

    /// Starts animating a track with one key at the playhead, or removes all its keys.
    func toggleAnimation(_ id: String, _ track: KeyTrack) {
        guard let layer = scene.layers.first(where: { $0.id == id }) else { return }
        let animated = layer.isAnimated(track)
        try? apply(animated ? "Remove Keyframes" : "Animate \(track.name)") {
            switch track {
            case let .number(p):
                let kfs = animated ? [] : [MotionKeyframe(t: time, v: layer[p].value(at: time))]
                try $0.setKeyframes(id, property: p, keyframes: kfs)
            case let .color(c):
                let current = layer.color(c, at: time) ?? .white
                let kfs = animated ? [] : [ColorKeyframe(t: time, v: current)]
                try $0.setColorKeyframes(id, property: c, keyframes: kfs)
            }
        }
    }

    /// Adds a key at the playhead holding the track's current value.
    func addKey(_ id: String, _ track: KeyTrack) {
        guard let layer = scene.layers.first(where: { $0.id == id }) else { return }
        switch track {
        case let .number(p): setValue(id, p, layer[p].value(at: time))
        case let .color(c): if let v = layer.color(c, at: time) { setColor(id, c, v) }
        }
    }

    func setColor(_ id: String, _ c: ColorProperty, _ v: RGBA) {
        try? apply("Change \(c.rawValue)") { try $0.setColor(id, property: c, value: v, at: time) }
    }

    func updateLayer(_ id: String, _ label: String = "Edit Layer", _ body: (inout MotionLayer) -> Void) {
        try? apply(label) { s in
            let i = try s.layerIndex(id)
            body(&s.layers[i])
        }
    }

    func addParticles(_ preset: ParticlePreset) {
        var l = MotionLayer.makeParticles(preset, sceneWidth: scene.width, sceneHeight: scene.height)
        l.start = time
        var id = ""
        apply("Add \(preset.title)") { id = $0.addLayer(l) }
        selection = id
    }

    /// Sets the selected text layer's font, or adds a text layer set in it.
    func useFont(_ family: String) {
        if let l = selectedLayer, l.type == .text {
            updateLayer(l.id, "Change Font") { $0.fontName = family }
            return
        }
        var l = MotionLayer(type: .text, x: Double(scene.width) / 2, y: Double(scene.height) / 2)
        l.text = family
        l.fontName = family
        l.fontWeight = "regular"
        l.start = time
        var id = ""
        apply("Add Text") { id = $0.addLayer(l) }
        selection = id
    }

    func addLayer(_ type: LayerType, path: String? = nil) {
        if type == .particles { return addParticles(.fire) }
        var l = MotionLayer(type: type, x: Double(scene.width) / 2, y: Double(scene.height) / 2)
        switch type {
        case .rect: l.width = 400; l.height = 240; l.cornerRadius = 24; l.fill = .constant(RGBA(hex: "#6C5CE7")!)
        case .ellipse: l.width = 240; l.height = 240; l.fill = .constant(RGBA(hex: "#00B894")!)
        case .path:
            l.name = "Star"
            l.d = (try? PathShape("star(5,160,70)")).map(PathValue.constant) ?? l.d
            l.fill = .constant(RGBA(hex: "#FDCB6E")!)
        case .text: l.text = "New Text"
        case .image: l.path = path; l.width = 600
        case .video:
            l.path = path
            l.start = time
            if let path { l.name = (path as NSString).lastPathComponent }
            try? l.loadVideoInfo(sceneFps: scene.fps)
            // Natural size, scaled down to fit the frame when larger (set explicitly so the selection box knows it).
            if let path, let info = try? VideoSource.info(of: path), info.width > 0, info.height > 0 {
                let fit = min(1, Double(scene.width) / Double(info.width), Double(scene.height) / Double(info.height))
                l.width = .constant((Double(info.width) * fit).rounded())
                l.height = .constant((Double(info.height) * fit).rounded())
            }
        case .audio:
            l.path = path
            l.start = time
            if let path { l.name = (path as NSString).lastPathComponent }
            l.sourceDuration = path.flatMap { try? AudioFileInfo.duration(of: $0) }
            l.role = (l.sourceDuration ?? 0) > 20 ? .music : .sfx
            if l.role == .music { l.duckTo = 0.3; l.fadeOut = 1.5 }
        case .particles: break
        case .generator: return addGenerator(.spectrum)
        case .model: return addModel(.box)
        case .drawing:
            l.name = "Drawing"
            l.drawing = Drawing(fps: 12, frames: [DrawingFrame(strokes: [DrawingStroke(d: "M-80 40 Q 0 -80 80 40", stroke: .white, strokeWidth: 8)])])
        case .group: l.name = "Group"
        }
        var id = ""
        apply("Add Layer") { id = $0.addLayer(l) }
        selection = id
    }

    /// Adds a 3D object at the center, turned a little so it reads as 3D.
    func addModel(_ shape: ModelShape, path: String? = nil) {
        let w = Double(scene.width), h = Double(scene.height)
        let size = (min(w, h) * 0.35).rounded()
        var l = MotionLayer(id: shape == .text ? "text3d" : shape.rawValue, name: shape.title, type: .model, x: w / 2, y: h / 2)
        l.model = Model3D(shape: shape)
        l.width = .constant(size)
        l.height = .constant(size)
        l.fill = .constant(RGBA(hex: "#6C5CE7")!)
        l[.rotationX] = .constant(-20)
        l[.rotationY] = .constant(30)
        switch shape {
        case .text:
            l.text = "3D"
            l.fontSize = (h * 0.3).rounded()
            l.fontWeight = "black"
            l.fill = .constant(RGBA(hex: "#FFD54A")!)
            l.model.sideColor = RGBA(hex: "#B7791F")
            l[.rotationX] = .constant(-10)
            l[.rotationY] = .constant(-20)
        case .sphere:
            l.fill = .constant(RGBA(hex: "#00B894")!)
            l.model.shininess = 0.6
        case .cylinder, .cone:
            l.width = .constant((size * 0.7).rounded())
            l.height = .constant((size * 1.2).rounded())
            l.fill = .constant(RGBA(hex: "#4FD1C5")!)
        case .torus:
            l.fill = .constant(RGBA(hex: "#FF6B9A")!)
            l[.rotationX] = .constant(-55)
        case .plane:
            l.width = .constant((size * 1.6).rounded())
        case .path:
            l.d = (try? PathShape("star(5,\(Int(size / 2)),\(Int(size / 4.5)))")).map(PathValue.constant) ?? l.d
            l.model.depth = (size * 0.2).rounded()
            l.fill = .constant(RGBA(hex: "#FDCB6E")!)
        case .lathe:
            // A vase: the right half of its outline, open at the top, closed on the axis at the bottom.
            let s = size
            func n(_ v: Double) -> String { String(Int((v * s).rounded())) }
            l.d = (try? PathShape("M0 \(n(0.5)) L\(n(0.2)) \(n(0.5)) C\(n(0.36)) \(n(0.42)) \(n(0.42)) \(n(0.12)) \(n(0.3)) \(n(-0.08)) "
                                  + "C\(n(0.2)) \(n(-0.24)) \(n(0.12)) \(n(-0.32)) \(n(0.16)) \(n(-0.5))")).map(PathValue.constant) ?? l.d
            l.model.segments = 64
            l.model.shininess = 0.7
            l.fill = .constant(RGBA(hex: "#E17055")!)
            l[.rotationX] = .constant(-15)
            l[.rotationY] = .constant(0)
        case .file:
            l.path = path
            l.fill = .constant(.white)
            if let path { l.name = (path as NSString).lastPathComponent }
        case .box:
            break
        }
        var id = ""
        apply("Add \(shape.title)") { id = $0.addLayer(l) }
        selection = id
    }

    /// Picks a 3D model file (OBJ, STL, GLB/glTF, USDZ, USD, PLY) and adds it as a model layer.
    func addModelLayer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.modelExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFileLayer(url.path)
    }

    static let modelExtensions = ["obj", "stl", "glb", "gltf", "usdz", "usd", "usda", "usdc", "ply", "abc"]

    func textToPath(_ id: String, letters: Bool) {
        do { try apply(letters ? "Split into Letters" : "Convert to Path") { _ = try $0.textToPath(id, letters: letters, at: time) } }
        catch { message = error.localizedDescription }
    }

    func applyLook(_ kind: LookKind) {
        var ids: [String] = []
        do { try apply("Apply \(kind.title) Look") { ids = try $0.applyLook(kind) } }
        catch { message = error.localizedDescription; return }
        selection = ids.first
    }

    func addTemplate(_ kind: TemplateKind) {
        var o = TemplateOptions()
        o.start = time
        o.duration = min(4, max(1, scene.duration - time))
        var id = ""
        do { try apply("Add \(kind.title)") { id = try $0.addTemplate(kind, id: nil, options: o) } }
        catch { message = error.localizedDescription; return }
        selection = id
    }

    /// Adds a generator sized for its kind: visualizers along the bottom, noise over the whole frame.
    func addGenerator(_ kind: GeneratorKind) {
        let w = Double(scene.width), h = Double(scene.height)
        var l = MotionLayer(id: kind.rawValue, name: kind.title, type: .generator, x: w / 2, y: h / 2)
        l.generator = Generator(kind: kind)
        switch kind {
        case .spectrum, .waveform:
            l.width = .constant((w * 0.7).rounded()); l.height = .constant((h * 0.25).rounded())
            l.y = .constant((h * 0.75).rounded())
            l.fill = .constant(RGBA(hex: "#4FD1C5")!)
            l.cornerRadius = .constant(4)
        case .noise:
            l.width = .constant(w); l.height = .constant(h)
            l.generator.colors = [RGBA(hex: "#0B1026")!, RGBA(hex: "#3B2C85")!, RGBA(hex: "#F0A6CA")!]
        case .lightning:
            l.width = .constant((w * 0.5).rounded()); l.height = .constant((h * 0.2).rounded())
            l.fill = .constant(RGBA(hex: "#CFE8FF")!)
            l.strokeWidth = .constant(3)
            l[.glow] = .constant(1.5)
            l.glowColor = RGBA(hex: "#5AA9FF")
        case .grid:
            l.width = .constant(w); l.height = .constant(h)
            l.fill = .constant(RGBA(hex: "#FF2E9A99")!)
            l.strokeWidth = .constant(2)
        case .chart:
            l.width = .constant((w * 0.5).rounded()); l.height = .constant((h * 0.45).rounded())
            l.generator.values = [12, 30, 18, 42, 27]
            l.generator.labels = ["A", "B", "C", "D", "E"]
            l.generator.colors = [RGBA(hex: "#4FD1C5")!, RGBA(hex: "#FFD93D")!, RGBA(hex: "#FF6B6B")!, RGBA(hex: "#A78BFA")!, RGBA(hex: "#60A5FA")!]
            l.fontSize = 28; l.fontWeight = "semibold"
            l.cornerRadius = .constant(6)
            l.reveal = .keyframes([MotionKeyframe(t: time, v: 0, easing: .linear), MotionKeyframe(t: time + 1.2, v: 1, easing: .easeOut)])
        case .flare:
            l.width = .constant(w); l.height = .constant(h)
            l.generator.from = PathPoint(x: -w * 0.25, y: -h * 0.2)
            l.blendMode = .add
        }
        l.start = time
        var id = ""
        apply("Add \(kind.title)") { id = $0.addLayer(l) }
        selection = id
    }

    func addAudioLayer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFileLayer(url.path)
    }

    /// Adds a generated voice-over (from the Voice-over sheet) at `start`.
    func addVoiceLayer(_ result: VoiceResult, script: String, start: Double, captions: Bool) {
        var l = MotionLayer(id: "vo", name: "Voice", type: .audio)
        l.role = .voice
        l.path = result.url.path
        l.start = start
        l.sourceDuration = result.duration
        l.transcript = script
        l.words = result.words
        var id = ""
        apply("Add Voice-over") { s in
            id = s.addLayer(l)
            let end = start + result.duration
            if end > s.duration { s.duration = (end + 0.5).rounded(.up) }
            if captions { _ = try? s.addCaptions(for: id) }
        }
        selection = id
    }

    /// Adds a synthesized sound effect (from the Sound Effect sheet) so its hit lands at `hitAt`.
    func addSoundEffect(_ result: SynthResult, title: String, hitAt: Double, volume: Double) {
        var l = MotionLayer(id: "sfx-\(title.lowercased())", name: title, type: .audio)
        l.role = .sfx
        l.path = result.url.path
        l.sourceDuration = result.duration
        l.volume = .constant(volume)
        l.start = hitAt - (result.hits.first ?? 0)
        if l.start < 0 { l.trimIn = -l.start; l.start = 0 }
        var id = ""
        apply("Add Sound Effect") { id = $0.addLayer(l) }
        selection = id
    }

    func addCaptions(for id: String) {
        do {
            try apply("Add Captions") { _ = try $0.addCaptions(for: id) }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Layers being transcribed (the inspector shows a spinner).
    private(set) var transcribing: Set<String> = []

    /// Recognizes the speech of an audio/video layer in the background and stores it on the layer.
    func transcribe(_ id: String, language: String?) {
        guard let l = scene.layers.first(where: { $0.id == id }), let path = l.path, !transcribing.contains(id) else { return }
        let range = l.playedSourceRange(sceneDuration: scene.duration)
        let revision = documentRevision
        transcribing.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Transcriber.transcribe(path: path, from: range.from, duration: range.duration, language: language) }
            DispatchQueue.main.async {
                self.transcribing.remove(id)
                // The user may have opened another document meanwhile.
                guard self.documentRevision == revision else { return }
                do {
                    let r = try result.get()
                    if r.words.isEmpty {
                        self.message = "No speech found (recognized as \(r.language))."
                        return
                    }
                    try self.apply("Transcribe") { try $0.setTranscription(id, r) }
                } catch {
                    self.message = error.localizedDescription
                }
            }
        }
    }

    /// A movie file, or a folder of numbered images (a rendered image sequence).
    func addVideoLayer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .folder]
        panel.canChooseDirectories = true
        panel.message = "Choose a movie (.mov/.mp4) or a folder of numbered images (e.g. a Blender PNG render)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFileLayer(url.path)
    }

    func addImageLayer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFileLayer(url.path)
    }

    // MARK: - Assets

    /// Adds an image, video or audio layer for a file (an asset, or a file dropped from Finder). A folder becomes an
    /// image-sequence video layer.
    func addFileLayer(_ path: String) {
        let name = (path as NSString).lastPathComponent
        if VideoSource.isSequence(path) {
            do {
                _ = try VideoSource.info(of: path)
                addLayer(.video, path: path)
            } catch {
                message = error.localizedDescription
            }
            return
        }
        var path = path
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.modelExtensions.contains(ext) {
            // OBJ and .gltf files name their materials, buffers and textures in files next to them: those stay where they are.
            let sidecar = ext == "gltf"
                || ext == "obj" && FileManager.default.fileExists(atPath: (path as NSString).deletingPathExtension + ".mtl")
            if project != nil, !AssetStore.contains(path), !sidecar {
                do {
                    path = try AssetStore.importFile(AssetStore.expand(path)).path
                    AssetLibrary.shared.refresh()
                } catch {
                    message = "Cannot copy \(name) into the project: \(error.localizedDescription)"
                    return
                }
            }
            addModel(.file, path: path)
            return
        }
        // A project keeps its own copy of every file it uses, so the folder stays complete.
        if project != nil, !AssetStore.contains(path), AssetStore.kind(of: URL(fileURLWithPath: path)) != .other {
            do {
                path = try AssetStore.importFile(AssetStore.expand(path)).path
                AssetLibrary.shared.refresh()
            } catch {
                message = "Cannot copy \(name) into the project: \(error.localizedDescription)"
                return
            }
        }
        switch AssetStore.kind(of: URL(fileURLWithPath: path)) {
        case .image:
            addLayer(.image, path: path)
        case .audio:
            guard (try? AudioFileInfo.duration(of: path)) != nil else {
                message = "Cannot read audio file \(name)"
                return
            }
            addLayer(.audio, path: path)
        case .video:
            do {
                _ = try VideoSource.info(of: path)
                addLayer(.video, path: path)
            } catch {
                message = "Cannot read video \(name): \(error.localizedDescription)"
            }
        case .font:
            FontLibrary.refresh(force: true)
            guard let family = FontLibrary.families(inFile: URL(fileURLWithPath: path)).first else {
                message = "Cannot read font \(name)"
                return
            }
            useFont(family)
        default:
            message = "\(name) is not an image, video, audio or font file"
        }
    }

    /// Adds an audio file as background music: from 0 to the end of the scene, faded in/out, quieter than
    /// narration and ducked while a voice speaks.
    func addMusicLayer(_ path: String) {
        guard let length = try? AudioFileInfo.duration(of: path) else {
            message = "Cannot read audio file \((path as NSString).lastPathComponent)"
            return
        }
        var l = MotionLayer(id: "music", name: (path as NSString).lastPathComponent, type: .audio)
        l.path = path
        l.role = .music
        l.sourceDuration = length
        l.start = 0
        if length > scene.duration { l.end = scene.duration }
        l.volume = .constant(0.6)
        l.fadeIn = 0.5
        l.fadeOut = min(1.5, scene.duration / 4)
        l.duckTo = 0.25
        var id = ""
        apply("Add Background Music") { id = $0.addLayer(l) }
        selection = id
        if length < scene.duration - 0.5 {
            message = String(format: "Music is %.1fs but the scene is %.1fs — it stops early.", length, scene.duration)
        }
    }

    /// Imports files into the library: into `folder` ("" = top level), or with nil into the type folders of a
    /// project (top level in the shared library). Files already in the library are moved there.
    func importAssets(_ urls: [URL], folder target: String? = nil) {
        let folder = target ?? ""
        var names: [String] = []
        for url in urls {
            do {
                var isDir: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if let name = AssetStore.relativeName(of: url.path) { // already in the library: move it
                    if isDir.boolValue {
                        let dest = AssetStore.join(folder, url.lastPathComponent)
                        if dest != name { renameAssetFolder(name, to: dest) }
                    } else if let a = AssetStore.info(url), a.folder != folder {
                        moveAsset(a, toFolder: folder)
                    }
                } else if isDir.boolValue {
                    message = "Folders cannot be imported yet: drop the files inside \(url.lastPathComponent) instead"
                } else {
                    names.append(try AssetStore.importFile(url, folder: target).name)
                }
            } catch {
                message = error.localizedDescription
            }
        }
        if !names.isEmpty { message = "Imported \(names.joined(separator: ", "))" }
        AssetLibrary.shared.refresh()
    }

    func importAssetsWithPanel(folder: String? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        importAssets(panel.urls, folder: folder)
    }

    /// Renames the file (keeping its folder) and repoints the layers that use it (that part is undoable).
    func renameAsset(_ asset: AssetInfo, to newName: String) {
        relocateAsset(asset, label: "Rename Asset") {
            try AssetStore.rename(asset.path, to: AssetStore.join(asset.folder, newName))
        }
    }

    /// Moves the file into `folder` ("" = top level) and repoints the layers that use it.
    func moveAsset(_ asset: AssetInfo, toFolder folder: String) {
        guard asset.folder != folder else { return }
        relocateAsset(asset, label: "Move Asset") { try AssetStore.move(asset.path, toFolder: folder) }
    }

    private func relocateAsset(_ asset: AssetInfo, label: String, _ op: () throws -> (from: String, to: String)) {
        do {
            let moved = try op()
            if !scene.layers(usingPath: moved.from).isEmpty {
                apply(label) { $0.replacePath(moved.from, with: moved.to) }
            }
        } catch {
            message = error.localizedDescription
        }
        AssetLibrary.shared.refresh()
    }

    func trashAsset(_ asset: AssetInfo) {
        do {
            try AssetStore.trash(asset.path)
            message = "Moved \(asset.fileName) to the Trash"
        } catch {
            message = error.localizedDescription
        }
        AssetLibrary.shared.refresh()
    }

    /// Creates `name` inside `parent` and returns its full name, or nil on failure.
    @discardableResult
    func createAssetFolder(_ name: String, in parent: String) -> String? {
        defer { AssetLibrary.shared.refresh() }
        do {
            let full = AssetStore.join(parent, name)
            if (try? AssetStore.existingFolder(full)) != nil {
                message = "A folder named \(name) already exists"
                return nil
            }
            return try AssetStore.createFolder(full)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Renames or moves a folder (`newName` is the full name) and repoints layers that use files inside.
    func renameAssetFolder(_ folder: String, to newName: String) {
        do {
            let moved = try AssetStore.renameFolder(folder, to: newName)
            if !scene.layers(inFolder: moved.from).isEmpty {
                apply("Move Folder") { $0.replaceFolder(moved.from, with: moved.to) }
            }
        } catch {
            message = error.localizedDescription
        }
        AssetLibrary.shared.refresh()
    }

    func trashAssetFolder(_ folder: String) {
        do {
            try AssetStore.trashFolder(folder)
            message = "Moved folder \((folder as NSString).lastPathComponent) to the Trash"
        } catch {
            message = error.localizedDescription
        }
        AssetLibrary.shared.refresh()
    }

    func deleteSelected() {
        guard let id = selection else { return }
        try? apply("Delete Layer") { try $0.removeLayerAnywhere(id) }
    }

    /// Wraps the selected layer in a group (add more layers to it with Claude, or ungroup).
    func groupSelected() {
        guard let id = selection else { return }
        var gid = ""
        try? apply("Group Layer") { gid = try $0.groupLayers([id]) }
        if !gid.isEmpty { selection = gid }
    }

    func ungroupSelected() {
        guard let id = selection, scene.layers.first(where: { $0.id == id })?.type == .group else { return }
        try? apply("Ungroup") { try $0.ungroup(id) }
        selection = nil
    }

    /// Scene-level edit (camera, format) through the undo stack.
    func editScene(_ label: String, _ body: @escaping (inout MotionScene) -> Void) {
        apply(label) { body(&$0) }
    }

    func duplicateSelected() {
        guard let id = selection else { return }
        var newId = ""
        try? apply("Duplicate Layer") { newId = try $0.duplicateLayer(id) }
        if !newId.isEmpty { selection = newId }
    }

    func move(_ id: String, by delta: Int) {
        guard let i = scene.layers.firstIndex(where: { $0.id == id }) else { return }
        try? apply("Reorder Layer") { try $0.moveLayer(id, to: i + delta) }
    }

    func applyPreset(_ preset: Preset, duration: Double = 0.6) {
        guard let id = selection else { return }
        do {
            try apply("Apply \(preset.title)") { try $0.applyPreset(preset, to: id, start: time, duration: duration) }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Applies a preset to several layers from the playhead, each `stagger` seconds after the previous.
    func applyPreset(_ preset: Preset, to ids: [String], duration: Double = 0.6, stagger: Double = 0.1) {
        do {
            try apply("Apply \(preset.title)") {
                try $0.applyPreset(preset, to: ids, start: time, duration: duration, stagger: stagger)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        if time >= scene.duration - 0.001 { time = 0 }
        isPlaying = true
        playAnchor = (Date(), time)
        audio.play(scene, from: time)
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
        panelTime = time
        audio.stop()
    }

    private func tick() {
        guard let anchor = playAnchor else { return }
        let elapsed = anchor.time + Date().timeIntervalSince(anchor.date)
        if elapsed >= scene.duration {
            // Loop: restart picture and sound together.
            playAnchor = (Date(), 0)
            time = 0
            audio.play(scene, from: 0)
        } else {
            // Whole frames only: ticks within one frame would redraw an identical canvas.
            let fps = Double(max(scene.fps, 1))
            let frame = (elapsed * fps).rounded(.down) / fps
            if frame != time { time = frame }
        }
    }

    func seek(_ t: Double) {
        time = min(max(t, 0), scene.duration)
        if isPlaying {
            playAnchor = (Date(), time)
            audio.play(scene, from: time)
        }
    }

    func step(frames: Int) {
        pause()
        let frame = (time * Double(scene.fps)).rounded() + Double(frames)
        seek(frame / Double(scene.fps))
    }

    // MARK: - Files

    func newScene() {
        let wasProject = project != nil
        leaveProject()
        // Between loose scenes New is undoable; leaving a project starts a clean history.
        replaceDocument(with: MotionScene(), fileURL: nil, undoLabel: wasProject ? nil : "New Scene")
    }

    /// Replaces the open document: stops playback and any drag, cancels a pending autosave and resets what
    /// belonged to the old one (selection, playhead). With `undoLabel` the switch is an undo step (loose scenes
    /// only); otherwise the history is cleared, so undo can never bring another project's scene back.
    private func replaceDocument(with s: MotionScene, fileURL url: URL?, undoLabel: String? = nil) {
        pause()
        interactiveBase = nil
        autosaveWork?.cancel()
        autosaveWork = nil
        if let undoLabel {
            apply(undoLabel) { $0 = s }
        } else {
            scene = s
            clearHistory()
        }
        fileURL = url
        isDirty = false
        selection = nil
        time = 0
        lastAgentAction = nil
        documentRevision &+= 1
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .folder]
        panel.canChooseDirectories = true
        panel.message = "Choose a scene file or a project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if ProjectStore.project(for: url) != nil { openProject(url); return }
        do {
            var s = try SceneJSON.decode(MotionScene.self, from: Data(contentsOf: url))
            s.resolvePaths(relativeTo: url.deletingLastPathComponent())
            let wasProject = project != nil
            leaveProject()
            load(s, from: url, undoable: !wasProject)
        } catch {
            message = "Cannot open: \(error.localizedDescription)"
        }
    }

    private func load(_ loaded: MotionScene, from url: URL, undoable: Bool) {
        var s = loaded
        let problems = s.refreshMediaInfo()
        replaceDocument(with: s, fileURL: url, undoLabel: undoable ? "Open" : nil)
        if !problems.isEmpty { message = problems.joined(separator: "; ") }
    }

    func save(as: Bool = false) {
        if let project {
            if `as` { saveProjectAs(project) } else { saveProject() }
            return
        }
        var url = fileURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.json"
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let url else { return }
        do {
            try SceneJSON.write(SceneJSON.encode(scene), to: url)
            fileURL = url
            isDirty = false
            message = "Saved \(url.lastPathComponent)"
        } catch {
            message = "Cannot save: \(error.localizedDescription)"
        }
    }

    // MARK: - Projects

    /// Creates a project folder and opens it. With `keepScene`, the current scene moves into it (its files are
    /// copied into the project); otherwise the project starts empty.
    func createProject(name: String, in directory: URL, keepScene: Bool) {
        // A loose scene moving into the project takes its chat along; a scene from another project does not.
        let adopt = keepScene && project == nil
        leaveProject()
        do {
            let url = try ProjectStore.create(name: name, in: directory)
            activate(project: url, adopting: adopt)
            if keepScene {
                collectAssets()
            } else {
                replaceDocument(with: MotionScene(), fileURL: nil)
            }
            try ProjectStore.save(scene, to: url)
            fileURL = ProjectStore.sceneURL(url)
            isDirty = false
            clearHistory()
            showProjects = false
            message = "Created project \(url.lastPathComponent) in \(url.deletingLastPathComponent().path)"
        } catch {
            message = "Cannot create the project: \(error.localizedDescription)"
        }
    }

    func openProjectWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = ProjectStore.projectsDirectory
        panel.message = "Choose a project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    /// Opens a project folder (or its scene.json).
    func openProject(_ url: URL) {
        guard let folder = ProjectStore.project(for: url) else {
            message = "\(url.lastPathComponent) is not a Vey Motion project (no scene.json inside)"
            return
        }
        guard folder != project else { return }
        do {
            let s = try ProjectStore.load(folder)
            leaveProject()
            activate(project: folder)
            load(s, from: ProjectStore.sceneURL(folder), undoable: false)
        } catch {
            message = "Cannot open the project: \(error.localizedDescription)"
        }
    }

    func closeProject() {
        guard project != nil else { return }
        newScene()
    }

    func saveProject(quiet: Bool = false) {
        guard let project else { return }
        do {
            try ProjectStore.save(scene, to: project)
            isDirty = false
            if !quiet { message = "Saved project \(project.lastPathComponent)" }
        } catch {
            message = "Cannot save: \(error.localizedDescription)"
        }
    }

    /// Copies the whole project folder to a new place and continues there.
    private func saveProjectAs(_ current: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = current.lastPathComponent + " copy"
        panel.directoryURL = current.deletingLastPathComponent()
        panel.message = "Save a copy of the project folder"
        guard panel.runModal() == .OK, let dest = panel.url?.standardizedFileURL else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                throw SceneError.invalid("\(dest.lastPathComponent) already exists; choose another name")
            }
            try FileManager.default.copyItem(at: current, to: dest)
            apply("Save Project As") { $0.replaceFolder(current.path, with: dest.path) }
            activate(project: dest)
            fileURL = ProjectStore.sceneURL(dest)
            saveProject()
        } catch {
            message = "Cannot save the project: \(error.localizedDescription)"
        }
    }

    /// Copies files the scene uses from outside the project into it and repoints those layers.
    @discardableResult
    func collectAssets() -> Int {
        guard project != nil else { return 0 }
        var moves: [(from: String, to: String)] = []
        for path in Set(scene.layers.compactMap(\.path)) where !AssetStore.contains(path) {
            let url = AssetStore.expand(path)
            guard FileManager.default.fileExists(atPath: url.path),
                  let a = try? AssetStore.importFile(url) else { continue }
            moves.append((path, a.path))
        }
        if !moves.isEmpty {
            apply("Copy Files into Project") { s in for m in moves { s.replacePath(m.from, with: m.to) } }
        }
        AssetLibrary.shared.refresh()
        return moves.count
    }

    /// Copies a shared-library file into the open project.
    func copyToProject(_ asset: AssetInfo) {
        do {
            let a = try AssetStore.importFile(URL(fileURLWithPath: asset.path))
            message = "Copied \(asset.fileName) to \(a.name)"
        } catch {
            message = error.localizedDescription
        }
        AssetLibrary.shared.refresh()
    }

    /// Renames a project folder; the open project keeps working from its new place.
    func renameProject(_ url: URL, to name: String) {
        let isOpen = url.standardizedFileURL == project
        if isOpen, isDirty { saveProject() }
        do {
            let dest = try ProjectStore.rename(url, to: name)
            if isOpen {
                // Layer paths are absolute in memory; follow the move (not an undo step: the files moved for real).
                scene.replaceFolder(url.path, with: dest.path)
                project = dest
                fileURL = ProjectStore.sceneURL(dest)
                AssetStore.setActiveLibrary(ProjectStore.assetsURL(dest))
                AssetLibrary.shared.reload()
                clearHistory()
                onProjectChange?(.moved(from: url.standardizedFileURL, to: dest))
            }
            setRecent(recentProjects.map { $0.standardizedFileURL == url.standardizedFileURL ? dest : $0 })
        } catch {
            message = "Cannot rename: \(error.localizedDescription)"
        }
    }

    func duplicateProject(_ url: URL) {
        if url.standardizedFileURL == project, isDirty { saveProject() }
        do {
            let copy = try ProjectStore.duplicate(url)
            message = "Duplicated as \(copy.lastPathComponent)"
        } catch {
            message = "Cannot duplicate: \(error.localizedDescription)"
        }
    }

    func trashProject(_ url: URL) {
        guard url.standardizedFileURL != project else {
            message = "Close the project before moving it to the Trash"
            return
        }
        do {
            try ProjectStore.trash(url)
            setRecent(recentProjects.filter { $0.standardizedFileURL != url.standardizedFileURL })
            message = "Moved \(url.lastPathComponent) to the Trash"
        } catch {
            message = "Cannot move to the Trash: \(error.localizedDescription)"
        }
    }

    private func setRecent(_ urls: [URL]) {
        recentProjects = urls
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.recentKey)
    }

    /// Undo must not bring another project's scene into this one (it would then be saved into this folder).
    private func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func clearRecentProjects() {
        recentProjects = []
        UserDefaults.standard.removeObject(forKey: Self.recentKey)
    }

    /// Saves the open project (projects have a fixed place, so switching away never loses work) and closes it.
    private func leaveProject() {
        guard project != nil else { return }
        if isDirty { saveProject() }
        activate(project: nil)
    }

    private func activate(project url: URL?, adopting: Bool = false) {
        let changed = url != project
        project = url
        AssetStore.setActiveLibrary(url.map(ProjectStore.assetsURL))
        AssetLibrary.shared.reload()
        // Before the new scene loads, so an agent still working on the old project is stopped first.
        if changed {
            if adopting, let url { onProjectChange?(.adopted(url)) } else { onProjectChange?(.opened(url)) }
        }
        guard let url else { return }
        setRecent([url] + recentProjects.filter { $0 != url }.prefix(9))
    }

    enum ProjectChange {
        /// Another project (or none: a loose scene) replaced the open one.
        case opened(URL?)
        /// The open project's folder moved (renamed); it is still the same project.
        case moved(from: URL, to: URL)
        /// The loose scene that was open became this new project, so its chat goes with it.
        case adopted(URL)
    }

    private static let recentKey = "recentProjects"

    private static func loadRecentProjects() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: recentKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter(ProjectStore.isProject)
    }

    enum ExportResult {
        case done(URL, seconds: Double)
        case failed(String)
        case cancelled
    }

    /// Opens the Export sheet (options, or progress if an export is already running).
    func exportVideo() {
        if exportProgress == nil && !exportResultUnseen { exportResult = nil }
        exportResultUnseen = false
        showExport = true
    }

    var defaultExportName: String {
        project?.lastPathComponent ?? fileURL?.deletingPathExtension().lastPathComponent ?? "VeyMotion"
    }

    /// Asks for a destination, then exports in the background; progress is published on `exportProgress`.
    func startExport(options: ExportOptions) {
        guard exportProgress == nil else { return }
        let fmt = options.format ?? .mp4
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fmt.fileExtension) ?? .movie]
        panel.nameFieldStringValue = defaultExportName + "." + fmt.fileExtension
        if let project { panel.directoryURL = project }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = scene
        let cancel = CancelFlag()
        exportCancel = cancel
        exportResult = nil
        exportResultUnseen = false
        exportProgress = 0
        exportStartedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let result: ExportResult
            do {
                try VideoExporter.export(snapshot, to: url, options: options, isCancelled: { cancel.isSet }) { p in
                    DispatchQueue.main.async { if self.exportProgress != nil { self.exportProgress = p } }
                }
                result = .done(url, seconds: Date().timeIntervalSince(started))
            } catch ExportError.cancelled {
                result = .cancelled
            } catch {
                result = .failed(error.localizedDescription)
            }
            DispatchQueue.main.async {
                self.exportProgress = nil
                self.exportStartedAt = nil
                self.exportCancel = nil
                self.exportResult = result
                switch result {
                case let .done(url, _): self.message = "Exported \(url.lastPathComponent)"
                case let .failed(msg): self.message = msg
                case .cancelled: self.message = "Export cancelled"
                }
                // Surface failures even if the sheet was closed while exporting.
                if case .failed = result { self.showExport = true }
                self.exportResultUnseen = !self.showExport
            }
        }
    }

    func cancelExport() { exportCancel?.set() }

    // MARK: - MCP

    func startMCP() {
        let server = MCPServer(host: self)
        server.log = { [weak self] line in
            DispatchQueue.main.async { self?.lastAgentAction = line }
        }
        let token = ProcessInfo.processInfo.environment["VEYMOTION_TOKEN"]
        let http = MCPHTTPServer(server: server, port: Self.mcpPort, token: token)
        http.onStateChange = { [weak self] status in
            DispatchQueue.main.async { self?.mcpStatus = status }
        }
        do {
            try http.start()
            mcp = http
        } catch {
            mcpStatus = "Failed: \(error.localizedDescription)"
        }

        // Control socket for the `vmotion` CLI (used by the embedded Claude chat). Same tool layer as MCP.
        let sock = ControlSocketServer(server: server)
        do {
            try sock.start()
            controlSocket = sock
            controlStatus = "Ready"
        } catch {
            controlStatus = "Failed: \(error.localizedDescription)"
        }
    }

    func shutdown() {
        if project != nil, isDirty { saveProject() } // a project has a fixed place, so quitting never loses work
        controlSocket?.stop()
        mcp?.stop()
    }

    // SceneHost — called from MCP worker threads.
    func currentScene() -> MotionScene { onMain { scene } }

    func mutate(_ label: String, _ body: (inout MotionScene) throws -> Void) throws {
        try onMain { try apply("Agent: \(label)", body) }
    }

    private func onMain<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }
}
