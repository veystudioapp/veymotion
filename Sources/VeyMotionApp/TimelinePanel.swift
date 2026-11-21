import AVFoundation
import AppKit
import Observation
import SwiftUI
import VeyMotionCore

// MARK: - View state

struct KeySelection: Equatable {
    var layerId: String
    var property: KeyTrack?
    var t: Double
}

/// A clip being dragged and how far it has been pulled up or down (px), so it follows the pointer between tracks.
struct ClipLift: Equatable {
    var id: String
    var dy: Double
}

/// Zoom/scroll/expansion state of the timeline. Horizontal scrolling is a custom offset so the ruler,
/// every track and the playhead stay in sync without nested scroll views.
@Observable
final class TimelineState {
    var zoom: Double = 1            // 1 = whole duration fits the track width
    var scrollX: Double = 0         // px
    var trackWidth: Double = 600
    var duration: Double = 5
    var fps = 30
    var mouseX: Double?
    var expanded: Set<String> = []
    /// Layers whose clips can't be moved or trimmed (the track header's lock; view state, not saved).
    var locked: Set<String> = []
    var selectedKey: KeySelection?
    var graphFocus: AnimProperty?
    var graphHidden: Set<AnimProperty> = []
    /// Time a dragged clip edge or key snapped to, drawn as a guide line while dragging.
    var snapGuide: Double?
    var lift: ClipLift?
    @ObservationIgnored var hovering = false
    @ObservationIgnored var monitor: Any?
    @ObservationIgnored var zoomBase: Double?
    /// Value captured at the start of a drag (keyframe time, layer start/end).
    @ObservationIgnored var dragOrigin: Double?
    /// Track of each layer as last laid out, and the layout held while a clip is dragged (so clips don't jump
    /// between tracks under the pointer; it is packed again when the drag ends).
    @ObservationIgnored var lastSlots: [String: TrackSlot] = [:]
    @ObservationIgnored var frozenSlots: [String: TrackSlot]?

    static let maxZoom = 80.0

    var pps: Double { max(trackWidth, 1) / max(duration, 0.001) * zoom }
    var contentWidth: Double { duration * pps }
    func x(_ t: Double) -> Double { t * pps - scrollX }
    func time(atX x: Double) -> Double { (x + scrollX) / pps }

    func clamp() {
        scrollX = min(max(scrollX, 0), max(0, contentWidth - trackWidth))
    }

    func setZoom(_ z: Double, anchorX: Double? = nil) {
        let ax = min(max(anchorX ?? trackWidth / 2, 0), trackWidth)
        let t = time(atX: ax)
        zoom = min(max(z, 1), Self.maxZoom)
        scrollX = t * pps - ax
        clamp()
    }

    /// Forgets view state that belonged to the previous document (zoom, scroll, expanded rows, selected key).
    func resetForNewDocument() {
        zoom = 1
        scrollX = 0
        expanded = []
        locked = []
        selectedKey = nil
        graphFocus = nil
        graphHidden = []
        snapGuide = nil
        lift = nil
        dragOrigin = nil
        frozenSlots = nil
        zoomBase = nil
    }

    /// Scrolls so time t is visible (used to follow the playhead).
    func reveal(_ t: Double) {
        let px = x(t)
        if px < 0 || px > trackWidth - 20 {
            scrollX = t * pps - trackWidth * 0.1
            clamp()
        }
    }
}

// MARK: - Tracks

/// A row of clips. Visual tracks are numbered from the top (0 = drawn over everything below it), audio tracks
/// follow them.
struct TrackSlot: Hashable {
    var audio: Bool
    var index: Int
}

struct TimelineTrack: Identifiable {
    let slot: TrackSlot
    /// In draw order (bottom first).
    let layers: [MotionLayer]
    let firstAudio: Bool

    var id: String { (slot.audio ? "a" : "v") + "\(slot.index)" }
    static let visualHeight: CGFloat = 46
    static let audioHeight: CGFloat = 38
    var height: CGFloat { slot.audio ? Self.audioHeight : Self.visualHeight }
}

enum TimelineRow: Identifiable {
    case track(TimelineTrack)
    case property(MotionLayer, KeyTrack)

    var id: String {
        switch self {
        case let .track(t): return t.id
        case let .property(l, p): return "p:\(l.id).\(p.name)"
        }
    }

    var height: CGFloat {
        switch self {
        case let .track(t): return t.height
        case .property: return 22
        }
    }

    func holds(_ id: String?) -> Bool {
        guard let id, case let .track(t) = self else { return false }
        return t.layers.contains { $0.id == id }
    }
}

/// CapCut-style layout: the scene's top-level layers packed into as few tracks as the stacking order allows.
/// Layers that don't overlap in time share a track; a track higher up always draws over the ones below it, so
/// the picture reads like the render. Sound sits on its own tracks at the bottom.
struct TimelineLayout {
    var rows: [TimelineRow]
    var slots: [String: TrackSlot]
    var visualTracks: Int

    static func overlaps(_ a: MotionLayer, _ b: MotionLayer, duration: Double) -> Bool {
        a.start < b.effectiveEnd(sceneDuration: duration) - 1e-6 && b.start < a.effectiveEnd(sceneDuration: duration) - 1e-6
    }

    static func pack(_ scene: MotionScene) -> [String: TrackSlot] {
        let d = scene.duration
        var slots: [String: TrackSlot] = [:]
        // Top of the draw order first: each layer goes right under the lowest track holding a layer drawn over it
        // that it overlaps in time.
        var placed: [MotionLayer] = []
        for l in scene.layers.reversed() where l.type.isVisual {
            let k = placed.filter { overlaps($0, l, duration: d) }.compactMap { slots[$0.id].map { $0.index + 1 } }.max() ?? 0
            slots[l.id] = TrackSlot(audio: false, index: k)
            placed.append(l)
        }
        // Sound has no stacking order: the first track with room.
        var audio: [[MotionLayer]] = []
        for l in scene.layers where !l.type.isVisual {
            let k = audio.firstIndex { track in !track.contains { overlaps($0, l, duration: d) } } ?? audio.count
            if k == audio.count { audio.append([]) }
            audio[k].append(l)
            slots[l.id] = TrackSlot(audio: true, index: k)
        }
        return slots
    }

    static func build(_ scene: MotionScene, _ tl: TimelineState) -> TimelineLayout {
        let slots: [String: TrackSlot]
        if let frozen = tl.frozenSlots, scene.layers.allSatisfy({ frozen[$0.id] != nil }) {
            slots = frozen
        } else {
            slots = pack(scene)
            tl.lastSlots = slots
        }
        var byTrack: [TrackSlot: [MotionLayer]] = [:]
        for l in scene.layers { if let s = slots[l.id] { byTrack[s, default: []].append(l) } }
        let order = byTrack.keys.sorted { a, b in a.audio != b.audio ? !a.audio : a.index < b.index }
        let visual = order.filter { !$0.audio }.count
        var rows: [TimelineRow] = []
        for s in order {
            let ls = byTrack[s] ?? []
            rows.append(.track(TimelineTrack(slot: s, layers: ls, firstAudio: s.audio && s.index == 0 && visual > 0)))
            for l in ls.reversed() where tl.expanded.contains(l.id) {
                for p in l.animatedTracks { rows.append(.property(l, p)) }
            }
        }
        return TimelineLayout(rows: rows, slots: slots, visualTracks: visual)
    }

    /// Draw-order index that moves visual layer `id` from track `cur` to track `k`: just above every layer it
    /// overlaps on tracks k..<cur (moving up), or just below every one on cur+1...k (moving down). nil = no change.
    static func reorderIndex(_ id: String, from cur: Int, to k: Int, slots: [String: TrackSlot], scene: MotionScene) -> Int? {
        guard k != cur, let i = scene.layers.firstIndex(where: { $0.id == id }) else { return nil }
        let l = scene.layers[i]
        let crossed = scene.layers.indices.filter { j in
            guard j != i, scene.layers[j].type.isVisual, let s = slots[scene.layers[j].id], !s.audio,
                  overlaps(scene.layers[j], l, duration: scene.duration) else { return false }
            return k < cur ? (k..<cur).contains(s.index) : (cur + 1...k).contains(s.index)
        }
        if k < cur {
            guard let top = crossed.max() else { return nil }
            return top > i ? top : top + 1
        }
        guard let bottom = crossed.min() else { return nil }
        return bottom < i ? bottom : bottom - 1
    }
}

extension MotionLayer {
    /// One color per kind of layer (like clip colors in CapCut), so the timeline reads at a glance.
    var timelineColor: Color {
        let hex: UInt32
        switch type {
        case .text: hex = 0xC0843A            // amber-brown, CapCut's text clips
        case .rect, .ellipse, .path: hex = 0x3B82F6  // blue
        case .image: hex = 0xEC4899           // pink
        case .video: hex = 0x2E6F86           // teal-blue, under the filmstrip
        case .particles: hex = 0xF59E0B       // amber
        case .generator: hex = 0x8B5CF6       // purple, like effects
        case .group: hex = 0x64748B           // slate
        case .model: hex = 0x0EA5E9           // sky
        case .drawing: hex = 0xF97316         // orange
        case .audio:
            switch role {
            case .voice: hex = 0x06B6D4       // cyan
            case .music: hex = 0x1F9D72       // green
            case .sfx: hex = 0x3F7FBF         // blue
            }
        }
        return Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }

    /// Second line on the clip: what the layer shows or plays.
    var timelineDetail: String? {
        switch type {
        case .text: return text.split(separator: "\n").first.map(String.init)
        case .image, .video: return path.map { ($0 as NSString).lastPathComponent }
        case .audio: return transcript ?? path.map { ($0 as NSString).lastPathComponent }
        case .particles: return particles.preset?.title ?? "Custom"
        case .generator: return generator.kind.title
        case .group: return "\(children.count) layers"
        case .model:
            if model.shape == .text { return text.split(separator: "\n").first.map(String.init) }
            if model.shape == .file { return path.map { ($0 as NSString).lastPathComponent } }
            return model.shape.title
        case .rect, .ellipse: return nil
        case .path: return d.isAnimated ? "Morph" : nil
        case .drawing: return "\(drawing.frames.count) frames · \(Int(drawing.fps)) fps"
        }
    }

    /// The layer's own color, shown as a swatch on shape/text clips.
    var timelineSwatch: Color? {
        switch type {
        case .rect, .ellipse, .path: return (gradient?.stops.first?.color ?? fill.value(at: 0)).color
        case .text: return (gradient?.stops.first?.color ?? color.value(at: 0)).color
        case .model: return fill.value(at: 0).color
        default: return nil
        }
    }

    /// SF Symbol for the kind of layer.
    var timelineIcon: String {
        switch type {
        case .rect: return "rectangle.fill"
        case .ellipse: return "circle.fill"
        case .path: return "scribble.variable"
        case .text: return "textformat"
        case .image: return "photo"
        case .video: return "film"
        case .particles: return "sparkles"
        case .generator: return "waveform.path.ecg"
        case .group: return "square.stack.3d.up.fill"
        case .model: return "cube.fill"
        case .drawing: return "scribble"
        case .audio:
            switch role {
            case .voice: return "person.wave.2.fill"
            case .music: return "music.note"
            case .sfx: return "speaker.wave.2.fill"
            }
        }
    }

    /// Parts of the layer's span where it is on the timeline but cannot be seen
    /// (opacity or scale at 0, or a text reveal at 0), e.g. before an entrance animation starts.
    func hiddenRanges(end: Double, fps: Int) -> [ClosedRange<Double>] {
        guard type.isVisual, end > start else { return [] }
        func hidden(_ t: Double) -> Bool {
            self[.opacity].value(at: t) <= 0.01 || abs(self[.scale].value(at: t)) <= 0.01
                || (type == .text && self[.reveal].value(at: t) <= 0.001)
        }
        let animated = self[.opacity].isAnimated || self[.scale].isAnimated || (type == .text && self[.reveal].isAnimated)
        if !animated { return hidden(start) ? [start...end] : [] }
        let n = max(1, min(Int((end - start) * Double(max(fps, 1))), 600))
        var result: [ClosedRange<Double>] = []
        var runStart: Double?
        for i in 0...n {
            let t = start + (end - start) * Double(i) / Double(n)
            if hidden(t) {
                if runStart == nil { runStart = t }
            } else if let s = runStart {
                result.append(s...t)
                runStart = nil
            }
        }
        if let s = runStart { result.append(s...end) }
        return result
    }
}

// MARK: - Panel

/// The timeline, laid out like CapCut's: a toolbar (split, delete, duplicate, snapping, zoom), a timecode ruler,
/// and packed tracks of clips with a small header (hide/mute, lock) instead of one named row per layer. It is
/// always dark, like the canvas stage above it.
@MainActor
struct TimelinePanel: View {
    @Environment(SceneStore.self) private var store
    @State private var tl = TimelineState()
    @AppStorage("timelineShowKeys") private var showKeys = true
    @AppStorage("timelineSnapBeats") private var snapBeats = true
    @AppStorage("timelineSnap") private var snapping = true
    @AppStorage("timelineGraph") private var graphMode = false

    static let toolbarHeight: CGFloat = 34
    static let rulerHeight: CGFloat = 24
    static let background = Color(white: 0.105)
    static let headerBackground = Color(white: 0.135)
    static let rulerBackground = Color(white: 0.125)
    static let separator = Color.black.opacity(0.45)

    private var headerWidth: CGFloat { graphMode ? 200 : 96 }

    var body: some View {
        let scene = store.scene
        GeometryReader { geo in
            let headerW = headerWidth
            let trackW = max(Double(geo.size.width - headerW), 50)
            let layout = TimelineLayout.build(scene, tl)
            VStack(spacing: 0) {
                toolbar(scene)
                    .frame(height: Self.toolbarHeight)
                Rectangle().fill(Self.separator).frame(height: 1)
                HStack(spacing: 0) {
                    Self.headerBackground.frame(width: headerW)
                    TimeRuler(tl: tl) { scrub(to: $0) }
                        .frame(width: trackW)
                        .clipped()
                }
                .frame(height: Self.rulerHeight)
                .background(Self.rulerBackground)
                Rectangle().fill(Self.separator).frame(height: 1)
                Group {
                    if graphMode {
                        graphArea(scene, trackW: trackW, headerW: headerW)
                    } else {
                        tracksArea(layout, scene: scene, trackW: trackW, headerW: headerW)
                    }
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            if tl.zoomBase == nil { tl.zoomBase = tl.zoom }
                            tl.setZoom((tl.zoomBase ?? 1) * v.magnification, anchorX: tl.mouseX)
                        }
                        .onEnded { _ in tl.zoomBase = nil }
                )
                HScrollBar(tl: tl)
                    .frame(width: trackW, height: 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .overlay(alignment: .topLeading) { snapGuide(headerW: headerW, trackW: trackW) }
            .overlay(alignment: .topLeading) {
                TimelinePlayhead(tl: tl, trackW: trackW, headerWidth: headerW, top: Self.toolbarHeight + 1) { scrub(to: $0) }
            }
            .coordinateSpace(name: "timeline")
            .onAppear {
                tl.trackWidth = trackW
                tl.duration = scene.duration
                tl.fps = scene.fps
                installMonitor()
            }
            .onChange(of: trackW) { _, w in tl.trackWidth = w; tl.clamp() }
            .onChange(of: scene.duration) { _, d in tl.duration = d; tl.clamp() }
            .onChange(of: scene.fps) { _, f in tl.fps = f }
            .onChange(of: store.documentRevision) { tl.resetForNewDocument() }
            .onHover { tl.hovering = $0 }
            .onContinuousHover { phase in
                if case let .active(p) = phase { tl.mouseX = Double(p.x - headerW) } else { tl.mouseX = nil }
            }
            .onDisappear { removeMonitor() }
        }
        .background(Self.background)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Toolbar

    private var selectedLayer: MotionLayer? {
        store.selection.flatMap { id in store.scene.layers.first { $0.id == id } }
    }

    private func toolbar(_ scene: MotionScene) -> some View {
        let sel = selectedLayer
        return HStack(spacing: 2) {
            TimelineToolButton(icon: "scissors", help: "Split at the playhead (⌘B)") { store.splitSelected() }
                .disabled(!store.canSplitSelected(at: store.panelTime))
            TimelineToolButton(icon: "trash", help: "Delete (⌫)") { store.deleteSelected() }
                .disabled(store.selection == nil)
            TimelineToolButton(icon: "plus.square.on.square", help: "Duplicate (⌘D)") { store.duplicateSelected() }
                .disabled(store.selection == nil)
            TimelineToolButton(icon: sel?.hidden == true ? "eye" : "eye.slash",
                               help: sel?.hidden == true ? "Show the clip" : "Hide the clip (not drawn, not heard)") {
                if let l = sel { setHidden([l.id], !l.hidden) }
            }
            .disabled(sel == nil)
            toolbarDivider
            TimelineToolButton(icon: "list.bullet.indent", on: sel.map { tl.expanded.contains($0.id) } ?? false,
                               help: "Show the selected clip's animated properties") {
                if let l = sel { toggleExpanded(l.id) }
            }
            .disabled(graphMode || sel?.animatedTracks.isEmpty != false)
            TimelineToolButton(icon: showKeys ? "diamond.fill" : "diamond", on: showKeys,
                               help: showKeys ? "Hide keyframes on the selected clip" : "Show keyframes on the selected clip") {
                showKeys.toggle()
            }
            TimelineToolButton(icon: "chart.xyaxis.line", on: graphMode,
                               help: graphMode ? "Back to the tracks" : "Edit the selected layer's animation curves") {
                graphMode.toggle()
            }
            if graphMode {
                let keys = selectedNumberKeys()
                ForEach(GraphEase.allCases, id: \.self) { e in
                    TimelineToolButton(icon: e.icon, help: e.title + (e.shortcutLabel.map { " (\($0))" } ?? "") + " on the selected keyframe") {
                        if let k = keys { e.apply(store, layer: k.layer, properties: k.properties, at: k.t) }
                    }
                    .keyboardShortcut(e.shortcut)
                    .disabled(keys == nil)
                }
            }
            Spacer(minLength: 8)
            TimelineToolButton(icon: "point.3.connected.trianglepath.dotted", on: snapping,
                               help: snapping ? "Snapping on: clips and keys snap to clip edges and the playhead" : "Snapping off") {
                snapping.toggle()
            }
            if scene.audioLayers.contains(where: { $0.role != .voice }) {
                TimelineToolButton(icon: snapBeats ? "metronome.fill" : "metronome", on: snapBeats,
                                   help: snapBeats ? "Hide the music's beats and stop snapping to them" : "Show the music's beats and snap to them") {
                    snapBeats.toggle()
                }
            }
            toolbarDivider
            TimelineToolButton(icon: "minus.magnifyingglass", help: "Zoom out (⌘-scroll or pinch)") {
                tl.setZoom(tl.zoom / 1.5, anchorX: playheadAnchor)
            }
            .disabled(tl.zoom <= 1)
            Slider(value: Binding(get: { log(tl.zoom) / log(TimelineState.maxZoom) },
                                  set: { tl.setZoom(exp($0 * log(TimelineState.maxZoom)), anchorX: playheadAnchor) }),
                   in: 0...1)
                .controlSize(.mini)
                .frame(width: 96)
                .help("Zoom")
            TimelineToolButton(icon: "plus.magnifyingglass", help: "Zoom in (⌘-scroll or pinch)") {
                tl.setZoom(tl.zoom * 1.5, anchorX: playheadAnchor)
            }
            .disabled(tl.zoom >= TimelineState.maxZoom)
            TimelineToolButton(icon: "arrow.left.and.right.square", help: "Fit the whole scene") { tl.setZoom(1) }
                .disabled(tl.zoom == 1)
        }
        .padding(.horizontal, 8)
    }

    private var toolbarDivider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16).padding(.horizontal, 5)
    }

    /// Number keys the ease buttons act on: the selected key, or every number key at that time for a clip diamond.
    private func selectedNumberKeys() -> (layer: String, properties: [AnimProperty], t: Double)? {
        guard let k = tl.selectedKey, let l = store.scene.layers.first(where: { $0.id == k.layerId }) else { return nil }
        let props: [AnimProperty]
        switch k.property {
        case let .number(p)?: props = [p]
        case .color?: props = []
        case nil: props = l.animatedProperties.filter { l[$0].hasKey(at: k.t, tolerance: MotionScene.keyTimeTolerance) }
        }
        return props.isEmpty ? nil : (l.id, props, k.t)
    }

    @ViewBuilder private func graphArea(_ scene: MotionScene, trackW: Double, headerW: CGFloat) -> some View {
        let layer = scene.layers.first { $0.id == store.selection }
        HStack(spacing: 0) {
            GraphTrackList(tl: tl, layer: layer)
                .frame(width: headerW)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Self.headerBackground)
            Group {
                if !LicenseStore.shared.isPro {
                    ProLockedView(feature: .graphEditor)
                } else if let l = layer, !l.animatedProperties.isEmpty {
                    GraphEditor(tl: tl, layer: l, snap: { snap($0) })
                } else {
                    Text(layer.map { "\($0.name) has no keyframed numbers" } ?? "Select a layer to edit its animation curves")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: trackW)
            .frame(maxHeight: .infinity)
            .clipped()
        }
        .frame(maxHeight: .infinity)
    }

    private var playheadAnchor: Double {
        let x = tl.x(store.panelTime)
        return (0...tl.trackWidth).contains(x) ? x : tl.trackWidth / 2
    }

    /// Moves the playhead to `t`, snapped to the nearest frame.
    private func scrub(to t: Double) {
        let fps = Double(max(store.scene.fps, 1))
        store.seek((t * fps).rounded() / fps)
    }

    @ViewBuilder private func snapGuide(headerW: CGFloat, trackW: Double) -> some View {
        if let t = tl.snapGuide {
            let x = tl.x(t)
            if x >= 0 && x <= trackW {
                Rectangle().fill(Color.yellow.opacity(0.9))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.top, Self.toolbarHeight + 1)
                    .offset(x: headerW + x)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Tracks

    @ViewBuilder private func tracksArea(_ layout: TimelineLayout, scene: MotionScene, trackW: Double, headerW: CGFloat) -> some View {
        if layout.rows.isEmpty {
            HStack(spacing: 0) {
                Self.headerBackground.frame(width: headerW)
                Text("No clips yet: add a layer from the Edit menu, or ask the assistant.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(layout.rows) { row in
                        let firstAudio: Bool = { if case let .track(t) = row { return t.firstAudio }; return false }()
                        VStack(spacing: 0) {
                            if firstAudio {
                                // A gap between the picture tracks and the sound tracks, like CapCut's main track.
                                HStack(spacing: 0) {
                                    Self.headerBackground.frame(width: headerW)
                                    Color.clear
                                }
                                .frame(height: 8)
                            }
                            HStack(spacing: 0) {
                                rowHeader(row)
                                    .frame(width: headerW, height: row.height)
                                    .background(Self.headerBackground)
                                    .overlay(alignment: .trailing) { Rectangle().fill(Self.separator).frame(width: 1) }
                                rowTrack(row, layout: layout, scene: scene)
                                    .frame(width: trackW, height: row.height, alignment: .topLeading)
                                    .clipShape(HorizontalClip())
                            }
                        }
                        .zIndex(row.holds(tl.lift?.id) ? 1 : 0)
                    }
                    // Room to drop a clip below the last track, and to click off a selection.
                    HStack(spacing: 0) {
                        Self.headerBackground.frame(width: headerW)
                        emptyArea(height: 24)
                    }
                    .frame(height: 24)
                }
                .padding(.top, 4)
            }
            .scrollIndicators(.never)
            .background(alignment: .leading) { Self.headerBackground.frame(width: headerW) }
        }
    }

    @ViewBuilder private func rowHeader(_ row: TimelineRow) -> some View {
        switch row {
        case let .track(track):
            let ids = track.layers.map(\.id)
            let allHidden = track.layers.allSatisfy(\.hidden)
            let allLocked = ids.allSatisfy(tl.locked.contains)
            HStack(spacing: 3) {
                Spacer(minLength: 0)
                TrackToggle(icon: track.slot.audio ? (allHidden ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                                   : (allHidden ? "eye.slash.fill" : "eye.fill"),
                            on: allHidden,
                            help: allHidden ? "Show this track's clips" : (track.slot.audio ? "Mute this track" : "Hide this track")) {
                    setHidden(ids, !allHidden)
                }
                TrackToggle(icon: allLocked ? "lock.fill" : "lock.open.fill", on: allLocked,
                            help: allLocked ? "Unlock: clips can be moved and trimmed" : "Lock: clips can't be moved or trimmed") {
                    if allLocked { tl.locked.subtract(ids) } else { tl.locked.formUnion(ids) }
                }
            }
            .padding(.horizontal, 6)
        case let .property(l, p):
            HStack(spacing: 4) {
                Circle().fill(l.timelineColor).frame(width: 5, height: 5)
                Text(p.title).font(.system(size: 10)).lineLimit(1)
                Spacer(minLength: 2)
                Text(format(l, p, at: store.panelTime))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .help("\(l.name): \(p.title)")
        }
    }

    private func format(_ l: MotionLayer, _ k: KeyTrack, at t: Double) -> String {
        switch k {
        case let .number(p):
            return String(format: p.isFractional ? "%.2f" : "%.0f", l.value(p, at: t))
        case let .color(c):
            return l.color(c, at: t)?.hex ?? "—"
        }
    }

    /// Empty track: click or drag to scrub; a click also drops the selection.
    private func emptyArea(height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.0001))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if g.translation == .zero {
                    if store.selection != nil { store.selection = nil }
                    tl.selectedKey = nil
                }
                scrub(to: tl.time(atX: g.location.x))
            })
    }

    @ViewBuilder private func rowTrack(_ row: TimelineRow, layout: TimelineLayout, scene: MotionScene) -> some View {
        ZStack(alignment: .topLeading) {
            switch row {
            case let .track(track):
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.025))
                    .padding(.vertical, 1.5)
                    .allowsHitTesting(false)
                emptyArea(height: row.height)
                ForEach(track.layers) { l in
                    clip(l, track: track, layout: layout, scene: scene, height: row.height)
                }
            case let .property(l, p):
                Color.white.opacity(0.012).allowsHitTesting(false)
                emptyArea(height: row.height)
                propertyTrack(l, p, height: row.height)
            }
        }
    }

    private func clip(_ l: MotionLayer, track: TimelineTrack, layout: TimelineLayout, scene: MotionScene,
                      height: CGFloat) -> some View {
        let end = l.effectiveEnd(sceneDuration: scene.duration)
        let selected = store.selection == l.id
        let locked = tl.locked.contains(l.id)
        let tol = MotionScene.keyTimeTolerance
        // Keys outside the clip (a split keeps them on both halves) belong to the other part.
        let times = showKeys && selected ? l.keyframeTimes.filter { $0 >= l.start - tol && $0 <= end + tol } : []
        let lift = tl.lift?.id == l.id ? tl.lift?.dy ?? 0 : 0
        return ZStack(alignment: .topLeading) {
            TimelineBar(x0: tl.x(l.start), x1: tl.x(end), height: height - 6, color: l.timelineColor,
                        label: l.name, selected: selected, locked: locked, hidden: l.hidden,
                        clip: clipInfo(l, end: end, scene: scene),
                        onTap: { store.selection = l.id; tl.selectedKey = nil },
                        onMove: locked ? nil : { d, ended in move(l, by: d, ended: ended, track: track, layout: layout) },
                        onTrimStart: locked ? nil : { dx, ended in trim(l, start: true, dx: dx, ended: ended) },
                        onTrimEnd: locked ? nil : { dx, ended in trim(l, start: false, dx: dx, ended: ended) })
                .offset(y: 3)
                .contextMenu { layerMenu(l) }
            if l.type == .audio, let path = l.path, let peaks = WaveformCache.shared.peaks(for: path), !peaks.isEmpty {
                WaveformStrip(peaks: peaks, x0: tl.x(l.start), x1: tl.x(end), sourceStart: l.trimIn,
                              pps: tl.pps, color: .white.opacity(0.5))
                    .frame(height: height - 20)
                    .offset(y: 16)
                    .allowsHitTesting(false)
            }
            if snapBeats, l.type == .audio, l.role != .voice, let path = l.path, let grid = BeatCache.shared.grid(for: path) {
                BeatStrip(marks: beatMarks(grid, layer: l, end: end))
                    .frame(height: height - 6)
                    .offset(y: 3)
                    .allowsHitTesting(false)
            }
            // Like CapCut: keyframes only on the selected clip, so the other clips stay clean.
            ForEach(Array(times.enumerated()), id: \.offset) { _, t in
                let tracks = l.animatedTracks.filter { l.hasKey($0, at: t, tolerance: tol) }
                KeyDiamond(x: tl.x(t), y: height - 10, easing: commonEasing(l, at: t), onClip: true,
                           selected: atPlayhead(t) || tl.selectedKey == KeySelection(layerId: l.id, property: nil, t: t),
                           onTap: { selectKey(l.id, nil, t) },
                           onDrag: { dx, ended in dragKey(l.id, nil, t, dx: dx, ended: ended) },
                           onEasing: { e in try? store.apply("Change Easing") { try $0.setEasing(l.id, track: nil, at: t, easing: e) } },
                           onDelete: { try? store.apply("Delete Keyframes") { try $0.deleteKeyframes(l.id, track: nil, at: t) } })
                    .help(String(format: "%.2fs: %@", t, tracks.map(\.title).joined(separator: ", ")))
            }
        }
        .offset(y: lift)
        .shadow(color: lift == 0 ? .clear : .black.opacity(0.5), radius: lift == 0 ? 0 : 6, y: lift == 0 ? 0 : 2)
    }

    /// x positions of an audio layer's beats inside the visible track (only downbeats when beats would crowd).
    private func beatMarks(_ grid: BeatGrid, layer l: MotionLayer, end: Double) -> [BeatStrip.Mark] {
        let interval = grid.beats.count > 1 ? (grid.beats.last! - grid.beats.first!) / Double(grid.beats.count - 1) : 1
        let downs = Set(grid.downbeats)
        let source = interval * tl.pps < 6 ? grid.downbeats : grid.beats
        return source.compactMap { b in
            let t = l.start + b - l.trimIn
            guard t >= l.start - 0.01, t < end else { return nil }
            let x = tl.x(t)
            return (-2...tl.trackWidth + 2).contains(x) ? BeatStrip.Mark(x: x, downbeat: downs.contains(b)) : nil
        }
    }

    private func clipInfo(_ l: MotionLayer, end: Double, scene: MotionScene) -> ClipInfo {
        let x0 = tl.x(l.start)
        // Only the part of the clip inside the track is drawn in detail.
        let visible = max(0, -x0)...max(max(0, -x0), min(tl.x(end), tl.trackWidth) - x0)
        let hidden = l.hiddenRanges(end: end, fps: scene.fps).compactMap { r -> ClosedRange<Double>? in
            let a = max(tl.x(r.lowerBound) - x0, visible.lowerBound), b = min(tl.x(r.upperBound) - x0, visible.upperBound)
            return b > a ? a...b : nil
        }
        var info = ClipInfo(icon: l.timelineIcon, detail: l.timelineDetail, duration: end - l.start, swatch: l.timelineSwatch,
                            hidden: hidden, visible: visible)
        let thumbs = TimelineThumbs.shared
        switch l.type {
        case .image:
            if let img = l.path.flatMap(thumbs.image) {
                info.thumbnail = { _ in img }
                info.thumbAspect = img.size.width / max(img.size.height, 1)
            }
        case .video:
            if let path = l.path {
                let pps = tl.pps
                info.thumbnail = { x in l.videoTime(at: l.start + x / pps).flatMap { thumbs.frame(path, at: $0) } }
                info.thumbAspect = thumbs.aspect(path) ?? 16.0 / 9
            }
        default:
            break
        }
        return info
    }

    private func propertyTrack(_ l: MotionLayer, _ p: KeyTrack, height: CGFloat) -> some View {
        let kfs = l.keys(p)
        return ZStack(alignment: .topLeading) {
            // Easing curves between keyframes (rising or falling with the value).
            ForEach(Array(kfs.indices.dropFirst()), id: \.self) { i in
                let a = kfs[i - 1], b = kfs[i]
                let x0 = tl.x(a.t), x1 = tl.x(b.t)
                EasingCurve(easing: b.easing, rising: b.rising)
                    .stroke(l.timelineColor.opacity(0.9), lineWidth: 1.3)
                    .frame(width: max(x1 - x0, 0.5), height: height - 8)
                    .offset(x: x0, y: 4)
                    .allowsHitTesting(false)
            }
            ForEach(Array(kfs.enumerated()), id: \.offset) { _, k in
                KeyDiamond(x: tl.x(k.t), y: height / 2, easing: k.easing,
                           selected: atPlayhead(k.t) || tl.selectedKey == KeySelection(layerId: l.id, property: p, t: k.t),
                           onTap: { selectKey(l.id, p, k.t) },
                           onDrag: { dx, ended in dragKey(l.id, p, k.t, dx: dx, ended: ended) },
                           onEasing: { e in try? store.apply("Change Easing") { try $0.setEasing(l.id, track: p, at: k.t, easing: e) } },
                           onDelete: { try? store.apply("Delete Keyframe") { try $0.deleteKeyframes(l.id, track: p, at: k.t) } })
                    .help(String(format: "%@ = %@ at %.2fs (%@)", p.title, format(l, p, at: k.t), k.t, k.easing.title))
            }
        }
    }

    @ViewBuilder private func layerMenu(_ l: MotionLayer) -> some View {
        let locked = tl.locked.contains(l.id)
        Button("Split at Playhead") { store.selection = l.id; store.splitSelected() }
            .disabled(!(store.selection == l.id ? store.canSplitSelected(at: store.time) : splittable(l)))
        Button("Duplicate") { store.selection = l.id; store.duplicateSelected() }
        Divider()
        Button("Move Start to Playhead") {
            try? store.apply("Move Layer") { try $0.shiftLayers([l.id], by: store.time - l.start) }
        }
        .disabled(locked)
        Button("Trim Start to Playhead") { try? store.apply("Trim Layer") { try $0.setTiming(l.id, start: store.time, end: nil) } }
            .disabled(locked)
        Button("Trim End to Playhead") { try? store.apply("Trim Layer") { try $0.setTiming(l.id, start: nil, end: store.time) } }
            .disabled(locked)
        Divider()
        Button("Bring Forward") { store.move(l.id, by: 1) }
        Button("Send Backward") { store.move(l.id, by: -1) }
        Divider()
        Button(l.hidden ? (l.type.isVisual ? "Show Clip" : "Unmute Clip") : (l.type.isVisual ? "Hide Clip" : "Mute Clip")) {
            setHidden([l.id], !l.hidden)
        }
        Button(locked ? "Unlock Clip" : "Lock Clip") {
            if locked { tl.locked.remove(l.id) } else { tl.locked.insert(l.id) }
        }
        if !l.animatedTracks.isEmpty {
            Button(tl.expanded.contains(l.id) ? "Hide Properties" : "Show Properties") { toggleExpanded(l.id) }
        }
        Divider()
        Button("Delete", role: .destructive) { try? store.apply("Delete Layer") { try $0.removeLayer(l.id) } }
    }

    private func splittable(_ l: MotionLayer) -> Bool {
        let frame = 1.0 / Double(max(store.scene.fps, 1))
        return store.time >= l.start + frame && store.time <= l.effectiveEnd(sceneDuration: store.scene.duration) - frame
    }

    private func toggleExpanded(_ id: String) {
        if tl.expanded.contains(id) { tl.expanded.remove(id) } else { tl.expanded.insert(id) }
    }

    private func setHidden(_ ids: [String], _ hidden: Bool) {
        try? store.apply(hidden ? "Hide Layers" : "Show Layers") { try $0.setHidden(ids, hidden) }
    }

    /// A key within half a frame of the playhead (held while playing, so rows don't redraw every frame).
    private func atPlayhead(_ t: Double) -> Bool {
        abs(t - store.panelTime) < 0.5 / Double(max(store.scene.fps, 1))
    }

    private func commonEasing(_ l: MotionLayer, at t: Double) -> Easing? {
        let es = KeyTrack.all.compactMap { l.easing($0, at: t, tolerance: MotionScene.keyTimeTolerance) }
        guard let first = es.first, es.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    // MARK: Interactions

    /// The nearest snap target within 8 px of `t` (the playhead, other clips' edges, the music's beats), with its
    /// distance in px; `moving` are the layers being dragged, whose own edges and beats move with them.
    private func snapTarget(_ t: Double, moving: Set<String>) -> (t: Double, d: Double)? {
        guard snapping else { return nil }
        let fps = Double(max(store.scene.fps, 1))
        var targets = [store.time]
        for l in store.scene.layers where !moving.contains(l.id) {
            targets.append(l.start)
            targets.append(l.effectiveEnd(sceneDuration: store.scene.duration))
        }
        if snapBeats {
            targets += BeatCache.shared.sceneBeats(store.scene, excluding: moving).beats.map { ($0 * fps).rounded() / fps }
        }
        var best: (t: Double, d: Double)?
        for target in targets {
            let d = abs(tl.x(t) - tl.x(target))
            if d < (best?.d ?? 8) { best = (target, d) }
        }
        return best
    }

    /// Rounds to whole frames and snaps to the nearest target; `guide` shows the snap line while dragging.
    private func snap(_ t: Double, moving: Set<String> = [], guide: Bool = false) -> Double {
        let fps = Double(max(store.scene.fps, 1))
        var s = (t * fps).rounded() / fps
        let hit = snapTarget(t, moving: moving)
        if let hit { s = hit.t }
        if guide { tl.snapGuide = hit?.t }
        return min(max(s, 0), store.scene.duration)
    }

    private func endDrag() {
        store.endInteractive()
        tl.dragOrigin = nil
        tl.snapGuide = nil
        tl.lift = nil
        tl.frozenSlots = nil
    }

    private func selectKey(_ id: String, _ p: KeyTrack?, _ t: Double) {
        store.selection = id
        tl.selectedKey = KeySelection(layerId: id, property: p, t: t)
        store.seek(t)
    }

    private func dragKey(_ id: String, _ p: KeyTrack?, _ t: Double, dx: Double, ended: Bool) {
        if tl.dragOrigin == nil {
            tl.dragOrigin = t
            store.beginInteractive(p == nil ? "Move Keyframes" : "Move Keyframe")
            store.selection = id
        }
        let origin = tl.dragOrigin ?? t
        let newT = snap(origin + dx / tl.pps, guide: true)
        store.updateInteractive { try $0.moveKeyframes(id, track: p, from: origin, to: newT) }
        store.seek(newT)
        if ended {
            endDrag()
            tl.selectedKey = KeySelection(layerId: id, property: p, t: newT)
        }
    }

    /// Drags a clip: sideways in time (either edge snaps), up or down to another track (which changes the draw
    /// order: over the clips it now overlaps above, or under the ones below), applied when it is dropped.
    private func move(_ l: MotionLayer, by d: CGSize, ended: Bool, track: TimelineTrack, layout: TimelineLayout) {
        if tl.dragOrigin == nil {
            tl.dragOrigin = l.start
            tl.frozenSlots = layout.slots
            store.beginInteractive("Move Layer")
            store.selection = l.id
        }
        let origin = tl.dragOrigin ?? l.start
        let length = l.effectiveEnd(sceneDuration: store.scene.duration) - l.start
        let raw = origin + Double(d.width) / tl.pps
        let fps = Double(max(store.scene.fps, 1))
        var start = (raw * fps).rounded() / fps
        let a = snapTarget(raw, moving: [l.id]), b = snapTarget(raw + length, moving: [l.id])
        if let a, a.d <= (b?.d ?? .infinity) {
            start = a.t
            tl.snapGuide = a.t
        } else if let b {
            start = b.t - length
            tl.snapGuide = b.t
        } else {
            tl.snapGuide = nil
        }
        let dt = max(start, 0) - origin
        let id = l.id
        let visual = l.type.isVisual
        tl.lift = visual ? ClipLift(id: id, dy: Double(d.height)) : nil
        guard ended else {
            store.updateInteractive { try $0.shiftLayers([id], by: dt) }
            return
        }
        let steps = Int((Double(d.height) / Double(TimelineTrack.visualHeight)).rounded())
        let target = min(max(track.slot.index + steps, 0), max(layout.visualTracks - 1, 0))
        let slots = layout.slots
        store.updateInteractive { s in
            try s.shiftLayers([id], by: dt)
            if visual, let to = TimelineLayout.reorderIndex(id, from: track.slot.index, to: target, slots: slots, scene: s) {
                try s.moveLayer(id, to: to)
            }
        }
        endDrag()
    }

    private func trim(_ l: MotionLayer, start: Bool, dx: Double, ended: Bool) {
        if tl.dragOrigin == nil {
            tl.dragOrigin = start ? l.start : l.effectiveEnd(sceneDuration: store.scene.duration)
            tl.frozenSlots = tl.lastSlots
            store.beginInteractive("Trim Layer")
            store.selection = l.id
        }
        let t = snap((tl.dragOrigin ?? 0) + dx / tl.pps, moving: [l.id], guide: true)
        store.updateInteractive { try $0.setTiming(l.id, start: start ? t : nil, end: start ? nil : t) }
        store.seek(t)
        if ended { endDrag() }
    }

    // MARK: Scroll wheel (⌘ = zoom, horizontal/shift = scroll)

    private func installMonitor() {
        guard tl.monitor == nil else { return }
        let state = tl
        tl.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard state.hovering else { return e }
            let precise = e.hasPreciseScrollingDeltas
            if e.modifierFlags.contains(.command) {
                let factor = exp(Double(e.scrollingDeltaY) * (precise ? 0.01 : 0.1))
                state.setZoom(state.zoom * factor, anchorX: state.mouseX)
                return nil
            }
            var dx = Double(e.scrollingDeltaX)
            if e.modifierFlags.contains(.shift) && dx == 0 { dx = Double(e.scrollingDeltaY) }
            if !precise { dx *= 10 }
            if dx != 0 && abs(dx) >= abs(Double(e.scrollingDeltaY)) && state.zoom > 1 {
                state.scrollX -= dx
                state.clamp()
                return nil
            }
            return e
        }
    }

    private func removeMonitor() {
        if let m = tl.monitor { NSEvent.removeMonitor(m) }
        tl.monitor = nil
    }
}

// MARK: - Pieces

/// Clips only left and right, so a clip dragged to another track can be seen leaving its row.
struct HorizontalClip: Shape {
    func path(in r: CGRect) -> Path {
        Path(CGRect(x: r.minX, y: r.minY - 4000, width: r.width, height: r.height + 8000))
    }
}

/// An icon button in the timeline's toolbar.
struct TimelineToolButton: View {
    let icon: String
    var on = false
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(on ? Color.accentColor : Color.white.opacity(enabled ? (hovering ? 1 : 0.78) : 0.25))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(enabled && hovering ? 0.1 : on ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Hide/mute and lock toggles in a track's header.
struct TrackToggle: View {
    let icon: String
    let on: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(on ? Color.white : Color.white.opacity(hovering ? 0.85 : 0.45))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(on ? 0.14 : hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The playhead line and handle, in its own view so only it re-renders while playing.
struct TimelinePlayhead: View {
    @Environment(SceneStore.self) private var store
    let tl: TimelineState
    let trackW: Double
    let headerWidth: CGFloat
    /// y of the ruler's top edge.
    let top: CGFloat
    let scrub: (Double) -> Void

    var body: some View {
        let x = tl.x(store.time)
        // Always present (even with the playhead scrolled out of view), so following it keeps working.
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 0, height: 0)
            if x >= -1 && x <= trackW + 1 {
                ZStack(alignment: .top) {
                    // The line lets clicks through, so keyframes under the playhead stay editable.
                    Rectangle().fill(Color.white).frame(width: 1.5)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .allowsHitTesting(false)
                    PlayheadHandle()
                        .fill(Color.white)
                        .frame(width: 11, height: 16)
                        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
                        .padding(.horizontal, 7)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                            .onChanged { g in scrub(tl.time(atX: Double(g.location.x - headerWidth))) })
                        .help("Drag to move the playhead")
                }
                .frame(width: 25)
                .offset(x: headerWidth + x - 12.5, y: top)
            }
        }
        .onChange(of: store.time) { _, t in if store.isPlaying { tl.reveal(t) } }
    }
}

/// A layer's clip: drag to move (sideways in time, up/down to another track), drag the edges to trim.
struct TimelineBar: View {
    let x0: Double
    let x1: Double
    let height: CGFloat
    let color: Color
    let label: String
    let selected: Bool
    var locked = false
    var hidden = false
    let clip: ClipInfo
    let onTap: () -> Void
    let onMove: ((CGSize, Bool) -> Void)?
    let onTrimStart: ((Double, Bool) -> Void)?
    let onTrimEnd: ((Double, Bool) -> Void)?

    var body: some View {
        let w = max(x1 - x0, 4)
        clipBody(width: w)
            .opacity(hidden ? 0.4 : 1)
            .frame(width: w, height: height)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { onMove?($0.translation, false) }
                .onEnded { onMove?($0.translation, true) },
                     including: onMove == nil ? .subviews : .all)
            .overlay(alignment: .leading) {
                if let onTrimStart { TrimHandle(shown: selected, onDrag: onTrimStart) }
            }
            .overlay(alignment: .trailing) {
                if let onTrimEnd { TrimHandle(shown: selected, onDrag: onTrimEnd) }
            }
            .offset(x: x0)
    }

    /// CapCut-style clip: muted color, one label line at the top (keyframes sit below it), a filmstrip for
    /// pictures, striped where the layer cannot be seen, white outline and edge handles when selected.
    @ViewBuilder private func clipBody(width w: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        ZStack(alignment: .topLeading) {
            // A dark base under the layer color gives a muted tone that keeps white text readable.
            shape.fill(Color.black.opacity(0.45))
            shape.fill(color.opacity(0.7))
            if let thumb = clip.thumbnail {
                ThumbStrip(tile: thumb, aspect: clip.thumbAspect, height: height, visible: clip.visible).opacity(0.85)
                LinearGradient(colors: [Color.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
            }
            ForEach(Array(clip.hidden.enumerated()), id: \.offset) { _, r in
                HiddenSpan()
                    .frame(width: r.upperBound - r.lowerBound, height: height)
                    .offset(x: r.lowerBound)
                    .help("On the timeline but not visible yet (opacity, scale or reveal is 0)")
            }
            // Keep the label in view when the clip starts left of the visible area.
            let lead = min(clip.visible.lowerBound, max(0, w - 80))
            HStack(spacing: 5) {
                if hidden { Image(systemName: "eye.slash.fill").font(.system(size: 9, weight: .semibold)) }
                if locked { Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)) }
                Image(systemName: clip.icon).font(.system(size: 9, weight: .semibold))
                if let swatch = clip.swatch {
                    Circle().fill(swatch).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                }
                Text(label).font(.caption2.weight(.semibold)).lineLimit(1)
                if let detail = clip.detail, detail != label {
                    Text(detail).font(.caption2).lineLimit(1).opacity(0.7)
                }
                Spacer(minLength: 4)
                if selected, w - lead > 120 {
                    Text(String(format: "%.1fs", clip.duration))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
            .padding(.leading, 8 + lead)
            .padding(.trailing, 10)
            .padding(.top, 4)
            .frame(width: w, alignment: .leading)
            shape.strokeBorder(selected ? Color.white : Color.white.opacity(0.1), lineWidth: selected ? 2 : 1)
        }
        .clipShape(shape)
    }
}

/// What a layer clip shows; positions are in px from the clip's left edge.
struct ClipInfo {
    var icon: String
    var detail: String?
    var duration: Double
    var swatch: Color?
    var hidden: [ClosedRange<Double>]
    /// The part of the clip inside the visible track (thumbnails and stripes are drawn only there).
    var visible: ClosedRange<Double>
    /// Filmstrip picture for the tile centered at a clip-local x (an image layer's picture, a video's frame there).
    var thumbnail: ((Double) -> NSImage?)? = nil
    /// Width / height of a filmstrip tile.
    var thumbAspect: Double = 16.0 / 9
}

/// Dark diagonal stripes over the part of a clip where the layer cannot be seen.
struct HiddenSpan: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.35)))
            var p = Path()
            var x = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            ctx.stroke(p, with: .color(.white.opacity(0.18)), lineWidth: 2)
        }
    }
}

/// A filmstrip of thumbnails, drawn only over the visible part of the clip.
struct ThumbStrip: View {
    let tile: (Double) -> NSImage?
    let aspect: Double
    let height: CGFloat
    let visible: ClosedRange<Double>

    var body: some View {
        // Redraw as video frames arrive.
        let _ = TimelineThumbs.shared.revision
        let tileW = max(24, Double(height) * aspect)
        let first = floor(visible.lowerBound / tileW)
        let count = max(0, min(Int(ceil(visible.upperBound / tileW) - first), 300))
        HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { i in
                if let img = tile((first + Double(i) + 0.5) * tileW) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: tileW - 1, height: height).clipped()
                } else {
                    Color.black.opacity(0.2).frame(width: tileW - 1, height: height)
                }
            }
        }
        .offset(x: first * tileW)
    }
}

/// Small cached thumbnails for image clips (reloaded when the file changes) and video frames for filmstrips
/// (made in the background, one per second of the source).
@Observable
final class TimelineThumbs: @unchecked Sendable {
    static let shared = TimelineThumbs()
    /// Bumped when a video frame arrives.
    private(set) var revision = 0
    @ObservationIgnored private var cache: [String: (modified: Date?, image: NSImage?)] = [:]
    @ObservationIgnored private var frames: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private var aspects: [String: Double] = [:]
    @ObservationIgnored private var generators: [String: AVAssetImageGenerator] = [:]
    @ObservationIgnored private var firstImages: [String: String?] = [:]

    func image(_ path: String) -> NSImage? {
        let expanded = (path as NSString).expandingTildeInPath
        let modified = (try? FileManager.default.attributesOfItem(atPath: expanded))?[.modificationDate] as? Date
        if let c = cache[expanded], c.modified == modified { return c.image }
        let img = AssetStore.thumbnail(URL(fileURLWithPath: expanded), maxPixels: 120)
            .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        cache[expanded] = (modified, img)
        return img
    }

    /// Width / height of a video's frames, once one has been made.
    func aspect(_ path: String) -> Double? {
        aspects[(path as NSString).expandingTildeInPath]
    }

    /// The frame of a video layer's source at `seconds` (rounded down to whole seconds), nil until it is made.
    /// Image sequences show their first image and Lottie files their thumbnail.
    func frame(_ path: String, at seconds: Double) -> NSImage? {
        let expanded = (path as NSString).expandingTildeInPath
        if LottieSource.isLottie(expanded) { return image(expanded) }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            if firstImages[expanded] == nil {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: expanded)) ?? []
                firstImages[expanded] = names.filter { !$0.hasPrefix(".") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }.first
                    .map { (expanded as NSString).appendingPathComponent($0) }
            }
            return firstImages[expanded].flatMap { $0 }.flatMap(image)
        }
        let second = max(0, Int(seconds))
        let key = "\(expanded)#\(second)"
        if let img = frames[key] { return img }
        guard !requested.contains(key) else { return nil } // being made, or failed (not retried)
        if frames.count > 600 { frames.removeAll() }
        requested.insert(key)
        let generator = generators[expanded] ?? {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: expanded)))
            g.appliesPreferredTrackTransform = true
            g.maximumSize = CGSize(width: 180, height: 180)
            g.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            g.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            generators[expanded] = g
            return g
        }()
        generator.generateCGImageAsynchronously(for: CMTime(seconds: Double(second), preferredTimescale: 600)) { cg, _, _ in
            guard let cg else { return }
            DispatchQueue.main.async {
                self.frames[key] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.requested.remove(key)
                if self.aspects[expanded] == nil { self.aspects[expanded] = Double(cg.width) / Double(max(cg.height, 1)) }
                self.revision += 1
            }
        }
        return nil
    }
}

struct TrimHandle: View {
    /// Selected clip: a white grip bar on the edge, always visible.
    var shown = false
    let onDrag: (Double, Bool) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(shown ? Color.white : Color.white.opacity(hovering ? 0.35 : 0.0001))
            if shown {
                Capsule().fill(Color.black.opacity(0.45)).frame(width: 1.5).padding(.vertical, 10)
            }
        }
            .frame(width: 7)
            .padding(.vertical, shown ? 0 : 3)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { onDrag($0.translation.width, false) }
                .onEnded { onDrag($0.translation.width, true) })
    }
}

struct KeyDiamond: View {
    let x: Double
    let y: CGFloat
    let easing: Easing?
    /// Drawn on a layer clip: smaller and white, so it reads as a marker rather than the clip's start.
    var onClip = false
    /// On the playhead or clicked: drawn in the accent color, slightly larger.
    let selected: Bool
    let onTap: () -> Void
    let onDrag: (Double, Bool) -> Void
    let onEasing: (Easing) -> Void
    let onDelete: () -> Void
    @State private var editingBezier = false

    var body: some View {
        let hold = easing == .hold
        let size: CGFloat = onClip ? (hold ? 7 : 10) : (hold ? 8 : 11)
        let shape = KeyShape(square: hold)
        // Accent with a white edge when on the playhead (or selected), like the filled diamond in the inspector.
        shape.fill(selected ? Color.accentColor : onClip ? Color.white : Color.yellow)
            .overlay(shape.stroke(Color.white, lineWidth: selected ? 1.5 : 0))
            .frame(width: size, height: size)
            .scaleEffect(selected ? 1.25 : 1)
            .shadow(color: .black.opacity(0.35), radius: 0.5, y: 0.5)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { onDrag($0.translation.width, false) }
                .onEnded { onDrag($0.translation.width, true) })
            .contextMenu {
                Menu("Easing (into this keyframe)") {
                    EasingMenuItems(current: easing, onPick: onEasing)
                }
                Button("Custom Bezier…") { editingBezier = true }
                Divider()
                Button("Delete keyframe", role: .destructive, action: onDelete)
            }
            .popover(isPresented: $editingBezier, arrowEdge: .bottom) {
                BezierEditor(initial: easing ?? .easeInOut) { e in
                    onEasing(e)
                    editingBezier = false
                }
            }
            .offset(x: x - 7, y: y - 7)
    }
}

/// A keyframe marker: a diamond, or a square for `hold` keys.
struct KeyShape: Shape {
    let square: Bool

    func path(in r: CGRect) -> Path {
        if square { return Path(r) }
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.closeSubpath()
        return p
    }
}

/// Audio peaks drawn inside an audio layer's bar (only the visible part is drawn).
struct WaveformStrip: View {
    let peaks: [Float]
    let x0: Double
    let x1: Double
    let sourceStart: Double
    let pps: Double
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let from = max(0, x0), to = min(Double(size.width), x1)
            guard to > from else { return }
            let mid = size.height / 2
            var path = Path()
            var px = from
            while px < to {
                let t = sourceStart + (px - x0) / pps
                let i = Int(t * Waveform.binsPerSecond)
                if i >= 0 && i < peaks.count {
                    let h = max(1, CGFloat(peaks[i]) * size.height)
                    path.addRect(CGRect(x: px, y: mid - h / 2, width: 1.2, height: h))
                }
                px += 2
            }
            ctx.fill(path, with: .color(color.opacity(0.75)))
        }
    }
}

/// The music's beats over an audio clip: thin ticks, with taller, brighter ones on downbeats (bar starts).
struct BeatStrip: View {
    struct Mark { let x: Double; let downbeat: Bool }
    let marks: [Mark]

    var body: some View {
        Canvas { ctx, size in
            var beats = Path(), bars = Path()
            for m in marks {
                if m.downbeat {
                    bars.addRect(CGRect(x: m.x - 0.75, y: 0, width: 1.5, height: size.height))
                } else {
                    beats.addRect(CGRect(x: m.x - 0.5, y: size.height * 0.55, width: 1, height: size.height * 0.45))
                }
            }
            ctx.fill(beats, with: .color(.yellow.opacity(0.55)))
            ctx.fill(bars, with: .color(.yellow.opacity(0.9)))
        }
    }
}

/// Plot of an easing curve, drawn between two keyframes.
struct EasingCurve: Shape {
    let easing: Easing
    let rising: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        guard r.width > 1 else { return p }
        let n = max(8, Int(r.width / 3))
        for i in 0...n {
            let t = Double(i) / Double(n)
            let v = min(max(easing.apply(t), -0.25), 1.25)
            let y = rising ? r.maxY - r.height * v : r.minY + r.height * v
            let pt = CGPoint(x: r.minX + r.width * t, y: y)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// Timecode ruler like CapCut's: mm:ss on whole seconds, frame numbers ("15f") in between when zoomed in.
struct TimeRuler: View {
    let tl: TimelineState
    let onSeek: (Double) -> Void

    var body: some View {
        // Read observed values here so the Canvas redraws when they change.
        let pps = tl.pps, scrollX = tl.scrollX, duration = tl.duration, fps = max(tl.fps, 1)
        Canvas { ctx, size in
            let frame = 1 / Double(fps)
            let frameSteps = [1, 2, 5, 10, 15].filter { $0 < fps }.map { Double($0) * frame }
            let step = (frameSteps + [1, 2, 5, 10, 15, 30, 60, 120]).first { $0 * pps >= 64 } ?? 120
            // Minor ticks: a division of the step that falls on whole frames and leaves room between ticks.
            let divs = [5, 4, 3, 2, 1].first { d in
                let m = step / Double(d)
                return m * pps >= 9 && abs((m * Double(fps)).rounded() - m * Double(fps)) < 1e-6
            } ?? 1
            let minor = step / Double(divs)
            let first = max(0, Int(floor(scrollX / pps / minor)))
            let tEnd = min(duration, (scrollX + Double(size.width)) / pps)
            var i = first
            while Double(i) * minor <= tEnd + 1e-9 {
                let t = Double(i) * minor
                let x = t * pps - scrollX
                let isMajor = i % divs == 0
                let h: CGFloat = isMajor ? 7 : 3
                ctx.fill(Path(CGRect(x: x, y: size.height - h, width: 1, height: h)),
                         with: .color(.white.opacity(isMajor ? 0.45 : 0.22)))
                if isMajor {
                    ctx.draw(Text(Self.label(t, fps: fps)).font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.55)),
                             at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                }
                i += 1
            }
            // End of scene.
            let endX = duration * pps - scrollX
            if endX < size.width {
                ctx.fill(Path(CGRect(x: endX, y: 0, width: size.width - endX, height: size.height)),
                         with: .color(.black.opacity(0.3)))
            }
        }
        // RAM preview cache, along the top edge (its own view, so filling doesn't redraw the ticks).
        .overlay(alignment: .top) { CachedFramesStrip(pointsPerSecond: pps, offset: scrollX) }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            onSeek(tl.time(atX: g.location.x))
        })
    }

    static func label(_ t: Double, fps: Int) -> String {
        let frames = Int((t * Double(fps)).rounded())
        let s = frames / fps, f = frames % fps
        if f != 0 { return "\(f)f" }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct HScrollBar: View {
    let tl: TimelineState
    @State private var startScroll: Double?

    var body: some View {
        GeometryReader { g in
            let w = Double(g.size.width)
            let content = tl.contentWidth
            if content > tl.trackWidth + 1 {
                let thumbW = max(30, w * tl.trackWidth / content)
                let maxScroll = content - tl.trackWidth
                let thumbX = (w - thumbW) * tl.scrollX / maxScroll
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: thumbW, height: 6)
                    .offset(x: thumbX, y: 2)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if startScroll == nil { startScroll = tl.scrollX }
                            tl.scrollX = (startScroll ?? 0) + Double(v.translation.width) * maxScroll / max(w - thumbW, 1)
                            tl.clamp()
                        }
                        .onEnded { _ in startScroll = nil })
            }
        }
    }
}

/// Playhead grab handle: a small tab pointing down at the current time.
struct PlayheadHandle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let shoulder = r.minY + r.height * 0.6
        p.move(to: CGPoint(x: r.minX + 2, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + 2), control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: shoulder))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: shoulder))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 2))
        p.addQuadCurve(to: CGPoint(x: r.minX + 2, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}
