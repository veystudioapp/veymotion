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

/// Zoom/scroll/expansion state of the timeline. Horizontal scrolling is a custom offset so the ruler,
/// every track and the playhead stay in sync without nested scroll views.
@Observable
final class TimelineState {
    var zoom: Double = 1            // 1 = whole duration fits the track width
    var scrollX: Double = 0         // px
    var trackWidth: Double = 600
    var duration: Double = 5
    var mouseX: Double?
    var collapsed: Set<String> = []
    var expanded: Set<String> = []
    var selectedKey: KeySelection?
    var graphFocus: AnimProperty?
    var graphHidden: Set<AnimProperty> = []
    @ObservationIgnored var hovering = false
    @ObservationIgnored var monitor: Any?
    @ObservationIgnored var zoomBase: Double?
    /// Value captured at the start of a drag (keyframe time, layer start/end).
    @ObservationIgnored var dragOrigin: Double?

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
        collapsed = []
        expanded = []
        selectedKey = nil
        graphFocus = nil
        graphHidden = []
        dragOrigin = nil
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

enum TimelineRow: Identifiable {
    case group(name: String, ids: [String])
    case layer(MotionLayer, indent: Bool)
    case property(MotionLayer, KeyTrack, indent: Bool)

    var id: String {
        switch self {
        case let .group(n, _): return "g:\(n)"
        case let .layer(l, _): return "l:\(l.id)"
        case let .property(l, p, _): return "p:\(l.id).\(p.name)"
        }
    }

    var height: CGFloat {
        switch self {
        case .group: return 24
        case .layer: return 34
        case .property: return 22
        }
    }

    var layerId: String? {
        switch self {
        case .group: return nil
        case let .layer(l, _), let .property(l, _, _): return l.id
        }
    }

    /// Rows top → bottom. Layers whose ids share a prefix before "-" (e.g. s1-title, s1-card) are grouped.
    static func build(_ scene: MotionScene, _ tl: TimelineState) -> [TimelineRow] {
        enum Entry { case group(String), single(MotionLayer) }
        let top = Array(scene.layers.reversed())
        func prefix(_ id: String) -> String? {
            guard let dash = id.firstIndex(of: "-"), dash != id.startIndex else { return nil }
            return String(id[..<dash])
        }
        var counts: [String: Int] = [:]
        for l in top { if let p = prefix(l.id) { counts[p, default: 0] += 1 } }
        var entries: [Entry] = []
        var members: [String: [MotionLayer]] = [:]
        for l in top {
            if let p = prefix(l.id), counts[p, default: 0] >= 2 {
                if members[p] == nil { entries.append(.group(p)) }
                members[p, default: []].append(l)
            } else {
                entries.append(.single(l))
            }
        }
        var rows: [TimelineRow] = []
        func addLayer(_ l: MotionLayer, indent: Bool) {
            rows.append(.layer(l, indent: indent))
            if tl.expanded.contains(l.id) {
                for p in l.animatedTracks { rows.append(.property(l, p, indent: indent)) }
            }
        }
        for e in entries {
            switch e {
            case let .group(p):
                let ls = members[p] ?? []
                rows.append(.group(name: p, ids: ls.map(\.id)))
                if !tl.collapsed.contains(p) { ls.forEach { addLayer($0, indent: true) } }
            case let .single(l):
                addLayer(l, indent: false)
            }
        }
        return rows
    }
}

extension MotionLayer {
    /// One color per kind of layer (like clip colors in iMovie), so the timeline reads at a glance.
    var timelineColor: Color {
        let hex: UInt32
        switch type {
        case .text: hex = 0x8B5CF6            // purple
        case .rect, .ellipse, .path: hex = 0x3B82F6  // blue
        case .image: hex = 0xEC4899           // pink
        case .video: hex = 0xE11D48           // rose
        case .particles: hex = 0xF59E0B       // amber
        case .generator: hex = 0x14B8A6       // teal
        case .group: hex = 0x64748B           // slate
        case .model: hex = 0x0EA5E9           // sky
        case .audio:
            switch role {
            case .voice: hex = 0x06B6D4       // cyan
            case .music: hex = 0x22C55E       // green
            case .sfx: hex = 0xF97316         // orange
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

struct TimelinePanel: View {
    @Environment(SceneStore.self) private var store
    @State private var tl = TimelineState()
    @AppStorage("timelineShowKeys") private var showKeys = true
    @AppStorage("timelineSnapBeats") private var snapBeats = true
    @AppStorage("timelineGraph") private var graphMode = false
    private let nameWidth: CGFloat = 200

    var body: some View {
        let scene = store.scene
        GeometryReader { geo in
            let trackW = max(Double(geo.size.width - nameWidth), 50)
            let rows = TimelineRow.build(scene, tl)
            VStack(spacing: 0) {
                header(scene, rows: rows)
                Divider()
                HStack(spacing: 0) {
                    Color.clear.frame(width: nameWidth, height: 22)
                    TimeRuler(tl: tl) { scrub(to: $0) }
                        .frame(width: trackW, height: 22)
                        .clipped()
                }
                Divider()
                Group {
                    if graphMode {
                        graphArea(scene, trackW: trackW)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(rows) { row in
                                    HStack(spacing: 0) {
                                        nameCell(row)
                                            .padding(.horizontal, 8)
                                            .frame(width: nameWidth, height: row.height, alignment: .leading)
                                        trackCell(row, scene: scene)
                                            .frame(width: trackW, height: row.height, alignment: .topLeading)
                                            .clipped()
                                    }
                                    .background(rowBackground(row))
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(Color.secondary.opacity(0.08)).frame(height: 1)
                                    }
                                }
                            }
                        }
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
            .overlay(alignment: .topLeading) {
                TimelinePlayhead(tl: tl, trackW: trackW, nameWidth: nameWidth) { scrub(to: $0) }
            }
            .coordinateSpace(name: "timeline")
            .onAppear {
                tl.trackWidth = trackW
                tl.duration = scene.duration
                installMonitor()
            }
            .onChange(of: trackW) { _, w in tl.trackWidth = w; tl.clamp() }
            .onChange(of: scene.duration) { _, d in tl.duration = d; tl.clamp() }
            .onChange(of: store.documentRevision) { tl.resetForNewDocument() }
            .onHover { tl.hovering = $0 }
            .onContinuousHover { phase in
                if case let .active(p) = phase { tl.mouseX = Double(p.x - nameWidth) } else { tl.mouseX = nil }
            }
            .onDisappear { removeMonitor() }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    // MARK: Header

    private func header(_ scene: MotionScene, rows: [TimelineRow]) -> some View {
        let groups = rows.compactMap { row -> String? in if case let .group(n, _) = row { return n }; return nil }
        let allCollapsed = !groups.isEmpty && groups.allSatisfy { tl.collapsed.contains($0) }
        return HStack(spacing: 10) {
            Text("Timeline").font(.caption.weight(.semibold))
            Text("\(scene.layers.count) layers").font(.caption).foregroundStyle(.secondary)
            if !groups.isEmpty {
                Button(allCollapsed ? "Expand groups" : "Collapse groups") {
                    tl.collapsed = allCollapsed ? [] : Set(groups)
                }
                .font(.caption)
            }
            Button { graphMode.toggle() } label: {
                Label("Graph", systemImage: "chart.xyaxis.line").font(.caption)
            }
            .foregroundStyle(graphMode ? Color.accentColor : .primary)
            .help(graphMode ? "Back to the layer timeline" : "Edit the selected layer's animation curves")
            if graphMode {
                let keys = selectedNumberKeys()
                ForEach(GraphEase.allCases, id: \.self) { e in
                    Button { if let k = keys { e.apply(store, layer: k.layer, properties: k.properties, at: k.t) } } label: {
                        Image(systemName: e.icon)
                    }
                    .keyboardShortcut(e.shortcut)
                    .disabled(keys == nil)
                    .help(e.title + (e.shortcutLabel.map { " (\($0))" } ?? "") + " on the selected keyframe")
                }
            } else if !tl.expanded.isEmpty {
                Button("Hide properties") { tl.expanded = [] }.font(.caption)
            }
            Button { showKeys.toggle() } label: {
                Label("Keyframes", systemImage: showKeys ? "diamond.fill" : "diamond").font(.caption)
            }
            .help(showKeys ? "Hide keyframes on the selected clip" : "Show keyframes on the selected clip")
            if scene.audioLayers.contains(where: { $0.role != .voice }) {
                Button { snapBeats.toggle() } label: {
                    Label("Beats", systemImage: snapBeats ? "metronome.fill" : "metronome").font(.caption)
                }
                .help(snapBeats ? "Hide the music's beats and stop snapping to them" : "Show the music's beats and snap to them")
            }
            Spacer()
            Text("⌘-scroll or pinch to zoom").font(.caption2).foregroundStyle(.tertiary)
            Button { tl.setZoom(tl.zoom / 1.5, anchorX: playheadAnchor) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(tl.zoom <= 1)
            Text(String(format: "×%.1f", tl.zoom)).font(.caption.monospacedDigit()).frame(width: 40)
            Button { tl.setZoom(tl.zoom * 1.5, anchorX: playheadAnchor) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(tl.zoom >= TimelineState.maxZoom)
            Button("Fit") { tl.setZoom(1) }.font(.caption).disabled(tl.zoom == 1)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 26)
    }

    /// Number keys the ease buttons act on: the selected key, or every number key at that time for a layer-row diamond.
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

    @ViewBuilder private func graphArea(_ scene: MotionScene, trackW: Double) -> some View {
        let layer = scene.layers.first { $0.id == store.selection }
        HStack(spacing: 0) {
            GraphTrackList(tl: tl, layer: layer)
                .frame(width: nameWidth)
                .frame(maxHeight: .infinity, alignment: .top)
            Group {
                if let l = layer, !l.animatedProperties.isEmpty {
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
        let x = tl.x(store.time)
        return (0...tl.trackWidth).contains(x) ? x : tl.trackWidth / 2
    }

    /// Moves the playhead to `t`, snapped to the nearest frame.
    private func scrub(to t: Double) {
        let fps = Double(max(store.scene.fps, 1))
        store.seek((t * fps).rounded() / fps)
    }

    private func rowBackground(_ row: TimelineRow) -> Color {
        if case .group = row { return Color.secondary.opacity(0.08) }
        if let id = row.layerId, id == store.selection {
            if case .property = row { return Color.accentColor.opacity(0.04) }
            return Color.accentColor.opacity(0.10)
        }
        return .clear
    }

    // MARK: Name column

    @ViewBuilder private func nameCell(_ row: TimelineRow) -> some View {
        switch row {
        case let .group(name, ids):
            HStack(spacing: 5) {
                Button {
                    if tl.collapsed.contains(name) { tl.collapsed.remove(name) } else { tl.collapsed.insert(name) }
                } label: {
                    Image(systemName: tl.collapsed.contains(name) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold)).frame(width: 12)
                }
                .buttonStyle(.borderless)
                Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
                Text(name).font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(ids.count)").font(.caption2).foregroundStyle(.secondary)
            }
        case let .layer(l, indent):
            HStack(spacing: 5) {
                if indent { Spacer().frame(width: 14) }
                if l.animatedTracks.isEmpty {
                    Spacer().frame(width: 12)
                } else {
                    Button {
                        if tl.expanded.contains(l.id) { tl.expanded.remove(l.id) } else { tl.expanded.insert(l.id) }
                    } label: {
                        Image(systemName: tl.expanded.contains(l.id) ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold)).frame(width: 12)
                    }
                    .buttonStyle(.borderless)
                    .help("Show animated properties")
                }
                Image(systemName: icon(l)).font(.caption).foregroundStyle(l.timelineColor)
                Text(l.name).font(.callout).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { store.selection = l.id }
        case let .property(l, p, indent):
            HStack(spacing: 4) {
                Spacer().frame(width: indent ? 46 : 32)
                Text(p.title).font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                Text(format(l, p, at: store.panelTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(_ l: MotionLayer) -> String {
        switch l.type {
        case .rect: return "rectangle.fill"
        case .ellipse: return "circle.fill"
        case .path: return "scribble.variable"
        case .text: return "textformat"
        case .image: return "photo"
        case .video: return "film"
        case .particles: return "sparkles"
        case .generator: return "waveform.path.ecg"
        case .group: return "folder"
        case .model: return "cube.fill"
        case .audio:
            switch l.role {
            case .voice: return "person.wave.2.fill"
            case .music: return "music.note"
            case .sfx: return "speaker.wave.2.fill"
            }
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

    // MARK: Tracks

    @ViewBuilder private func trackCell(_ row: TimelineRow, scene: MotionScene) -> some View {
        ZStack(alignment: .topLeading) {
            // Empty track area: click/drag to scrub (and select the row's layer).
            Rectangle()
                .fill(Color.white.opacity(0.0001))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    store.seek(tl.time(atX: g.location.x))
                    if let id = row.layerId { store.selection = id }
                    tl.selectedKey = nil
                })

            switch row {
            case let .group(name, ids):
                groupTrack(name: name, ids: ids, scene: scene, height: row.height)
            case let .layer(l, _):
                layerTrack(l, scene: scene, height: row.height)
            case let .property(l, p, _):
                propertyTrack(l, p, height: row.height)
            }
        }
    }

    private func groupTrack(name: String, ids: [String], scene: MotionScene, height: CGFloat) -> some View {
        let ls = scene.layers.filter { ids.contains($0.id) }
        let start = ls.map(\.start).min() ?? 0
        let end = ls.map { $0.effectiveEnd(sceneDuration: scene.duration) }.max() ?? scene.duration
        return TimelineBar(x0: tl.x(start), x1: tl.x(end), height: height - 8, color: .secondary,
                           label: name, selected: false, showHandles: false,
                           onTap: { store.seek(start) },
                           onMove: { dx, ended in shift(ids, dx: dx, ended: ended, label: "Move Group") },
                           onTrimStart: nil, onTrimEnd: nil)
            .offset(y: 4)
            .contextMenu {
                Button("Move group start to playhead") {
                    try? store.apply("Move Group") { try $0.shiftLayers(ids, by: store.time - start) }
                }
                Button(tl.collapsed.contains(name) ? "Expand" : "Collapse") {
                    if tl.collapsed.contains(name) { tl.collapsed.remove(name) } else { tl.collapsed.insert(name) }
                }
            }
    }

    private func layerTrack(_ l: MotionLayer, scene: MotionScene, height: CGFloat) -> some View {
        let end = l.effectiveEnd(sceneDuration: scene.duration)
        let times = l.keyframeTimes
        return ZStack(alignment: .topLeading) {
            TimelineBar(x0: tl.x(l.start), x1: tl.x(end), height: height - 6, color: l.timelineColor,
                        label: l.name, selected: store.selection == l.id, showHandles: true,
                        clip: clipInfo(l, end: end, scene: scene),
                        onTap: { store.selection = l.id; tl.selectedKey = nil },
                        onMove: { dx, ended in shift([l.id], dx: dx, ended: ended, label: "Move Layer") },
                        onTrimStart: { dx, ended in trim(l, start: true, dx: dx, ended: ended) },
                        onTrimEnd: { dx, ended in trim(l, start: false, dx: dx, ended: ended) })
                .offset(y: 3)
                .contextMenu { layerMenu(l) }
            if l.type == .audio, let path = l.path, let peaks = WaveformCache.shared.peaks(for: path), !peaks.isEmpty {
                WaveformStrip(peaks: peaks, x0: tl.x(l.start), x1: tl.x(end), sourceStart: l.trimIn,
                              pps: tl.pps, color: .white.opacity(0.45))
                    .frame(height: height - 10)
                    .offset(y: 5)
                    .allowsHitTesting(false)
            }
            if snapBeats, l.type == .audio, l.role != .voice, let path = l.path, let grid = BeatCache.shared.grid(for: path) {
                BeatStrip(marks: beatMarks(grid, layer: l, end: end))
                    .frame(height: height - 6)
                    .offset(y: 3)
                    .allowsHitTesting(false)
            }
            // Like CapCut: keyframes only on the selected clip, so the other clips stay clean.
            ForEach(Array((showKeys && store.selection == l.id ? times : []).enumerated()), id: \.offset) { _, t in
                let tracks = l.animatedTracks.filter { l.hasKey($0, at: t, tolerance: MotionScene.keyTimeTolerance) }
                KeyDiamond(x: tl.x(t), y: height - 9, easing: commonEasing(l, at: t), onClip: true,
                           selected: atPlayhead(t) || tl.selectedKey == KeySelection(layerId: l.id, property: nil, t: t),
                           onTap: { selectKey(l.id, nil, t) },
                           onDrag: { dx, ended in dragKey(l.id, nil, t, dx: dx, ended: ended) },
                           onEasing: { e in try? store.apply("Change Easing") { try $0.setEasing(l.id, track: nil, at: t, easing: e) } },
                           onDelete: { try? store.apply("Delete Keyframes") { try $0.deleteKeyframes(l.id, track: nil, at: t) } })
                    .help(String(format: "%.2fs: %@", t, tracks.map(\.title).joined(separator: ", ")))
            }
        }
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
        return ClipInfo(icon: icon(l), detail: l.timelineDetail, duration: end - l.start, swatch: l.timelineSwatch,
                        hidden: hidden, thumbnail: l.type == .image ? l.path.flatMap(TimelineThumbs.shared.image) : nil,
                        visible: visible)
    }

    private func propertyTrack(_ l: MotionLayer, _ p: KeyTrack, height: CGFloat) -> some View {
        let kfs = l.keys(p)
        return ZStack(alignment: .topLeading) {
            // Easing curves between keyframes (rising or falling with the value).
            ForEach(Array(kfs.indices.dropFirst()), id: \.self) { i in
                let a = kfs[i - 1], b = kfs[i]
                let x0 = tl.x(a.t), x1 = tl.x(b.t)
                EasingCurve(easing: b.easing, rising: b.rising)
                    .stroke(l.timelineColor.opacity(0.85), lineWidth: 1.3)
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
        Button("Move start to playhead") {
            try? store.apply("Move Layer") { try $0.shiftLayers([l.id], by: store.time - l.start) }
        }
        Button("Trim start to playhead") { try? store.apply("Trim Layer") { try $0.setTiming(l.id, start: store.time, end: nil) } }
        Button("Trim end to playhead") { try? store.apply("Trim Layer") { try $0.setTiming(l.id, start: nil, end: store.time) } }
        Divider()
        if !l.animatedTracks.isEmpty {
            Button(tl.expanded.contains(l.id) ? "Hide properties" : "Show properties") {
                if tl.expanded.contains(l.id) { tl.expanded.remove(l.id) } else { tl.expanded.insert(l.id) }
            }
        }
        Button("Delete layer", role: .destructive) { try? store.apply("Delete Layer") { try $0.removeLayer(l.id) } }
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

    /// Rounds to whole frames and snaps to the playhead or a beat of the music when within 6px
    /// (`moving`: layers being dragged, whose own beats move with them).
    private func snap(_ t: Double, moving: Set<String> = []) -> Double {
        let fps = Double(max(store.scene.fps, 1))
        var s = (t * fps).rounded() / fps
        var best = 6.0
        var targets = [store.time]
        if snapBeats {
            targets += BeatCache.shared.sceneBeats(store.scene, excluding: moving).beats.map { ($0 * fps).rounded() / fps }
        }
        for target in targets {
            let d = abs(tl.x(t) - tl.x(target))
            if d < best { best = d; s = target }
        }
        return min(max(s, 0), store.scene.duration)
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
        let newT = snap(origin + dx / tl.pps)
        store.updateInteractive { try $0.moveKeyframes(id, track: p, from: origin, to: newT) }
        store.seek(newT)
        if ended {
            store.endInteractive()
            tl.dragOrigin = nil
            tl.selectedKey = KeySelection(layerId: id, property: p, t: newT)
        }
    }

    private func shift(_ ids: [String], dx: Double, ended: Bool, label: String) {
        if tl.dragOrigin == nil {
            // The earliest start among the moved layers: it is what snaps to the playhead or a beat.
            tl.dragOrigin = store.scene.layers.filter { ids.contains($0.id) }.map(\.start).min() ?? 0
            store.beginInteractive(label)
            if ids.count == 1 { store.selection = ids[0] }
        }
        let origin = tl.dragOrigin ?? 0
        let dt = snap(origin + dx / tl.pps, moving: Set(ids)) - origin
        store.updateInteractive { try $0.shiftLayers(ids, by: dt) }
        if ended {
            store.endInteractive()
            tl.dragOrigin = nil
        }
    }

    private func trim(_ l: MotionLayer, start: Bool, dx: Double, ended: Bool) {
        if tl.dragOrigin == nil {
            tl.dragOrigin = start ? l.start : l.effectiveEnd(sceneDuration: store.scene.duration)
            store.beginInteractive("Trim Layer")
            store.selection = l.id
        }
        let t = snap((tl.dragOrigin ?? 0) + dx / tl.pps)
        store.updateInteractive { try $0.setTiming(l.id, start: start ? t : nil, end: start ? nil : t) }
        store.seek(t)
        if ended {
            store.endInteractive()
            tl.dragOrigin = nil
        }
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

/// A layer (or group) bar: drag to move, drag the edges to trim.
/// The playhead line and handle, in its own view so only it re-renders while playing.
struct TimelinePlayhead: View {
    @Environment(SceneStore.self) private var store
    let tl: TimelineState
    let trackW: Double
    let nameWidth: CGFloat
    let scrub: (Double) -> Void

    var body: some View {
        let x = tl.x(store.time)
        // Always present (even with the playhead scrolled out of view), so following it keeps working.
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 0, height: 0)
            if x >= -1 && x <= trackW + 1 {
                ZStack(alignment: .top) {
                    // The line lets clicks through, so keyframes under the playhead stay editable.
                    Rectangle().fill(Color.red).frame(width: 1.5).allowsHitTesting(false)
                    PlayheadHandle()
                        .fill(Color.red)
                        .frame(width: 13, height: 15)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                        .contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                            .onChanged { g in scrub(tl.time(atX: Double(g.location.x - nameWidth))) })
                        .help("Drag to move the playhead")
                }
                .frame(width: 25)
                .offset(x: nameWidth + x - 12.5, y: 27)
            }
        }
        .onChange(of: store.time) { _, t in if store.isPlaying { tl.reveal(t) } }
    }
}

struct TimelineBar: View {
    let x0: Double
    let x1: Double
    let height: CGFloat
    let color: Color
    let label: String
    let selected: Bool
    let showHandles: Bool
    var clip: ClipInfo? = nil
    let onTap: () -> Void
    let onMove: (Double, Bool) -> Void
    let onTrimStart: ((Double, Bool) -> Void)?
    let onTrimEnd: ((Double, Bool) -> Void)?

    var body: some View {
        let w = max(x1 - x0, 4)
        ZStack(alignment: .leading) {
            if let clip {
                clipBody(clip, width: w)
            } else {
                RoundedRectangle(cornerRadius: 5).fill(color.opacity(selected ? 0.42 : 0.24))
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(selected ? Color.accentColor : color.opacity(0.55), lineWidth: selected ? 1.5 : 1)
                Text(label)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(width: w, alignment: .leading)
                    .clipped()
            }
        }
        .frame(width: w, height: height)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { onMove($0.translation.width, false) }
            .onEnded { onMove($0.translation.width, true) })
        .overlay(alignment: .leading) {
            if showHandles, let onTrimStart { TrimHandle(shown: selected && clip != nil, onDrag: onTrimStart) }
        }
        .overlay(alignment: .trailing) {
            if showHandles, let onTrimEnd { TrimHandle(shown: selected && clip != nil, onDrag: onTrimEnd) }
        }
        .offset(x: x0)
    }
}

extension TimelineBar {
    /// CapCut-style clip: muted color, one label line at the top (keyframes sit below it), optional filmstrip,
    /// striped where the layer cannot be seen, white outline and edge handles when selected.
    @ViewBuilder func clipBody(_ clip: ClipInfo, width w: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        ZStack(alignment: .topLeading) {
            // A dark base under the layer color gives a muted tone that keeps white text readable.
            shape.fill(Color.black.opacity(0.45))
            shape.fill(color.opacity(0.62))
            if let thumb = clip.thumbnail {
                ThumbStrip(image: thumb, height: height, visible: clip.visible).opacity(0.7)
                LinearGradient(colors: [Color.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
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
                Image(systemName: clip.icon).font(.system(size: 9, weight: .semibold))
                if let swatch = clip.swatch {
                    Circle().fill(swatch).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                }
                Text(label).font(.caption2.weight(.semibold)).lineLimit(1)
                if let detail = clip.detail {
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
            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            .padding(.leading, 7 + lead)
            .padding(.trailing, 10)
            .padding(.top, 3)
            .frame(width: w, alignment: .leading)
            shape.strokeBorder(selected ? Color.white : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1)
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
    var thumbnail: NSImage?
    /// The part of the clip inside the visible track (thumbnails and stripes are drawn only there).
    var visible: ClosedRange<Double>
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

/// Repeated thumbnails of an image layer (a filmstrip), drawn only over the visible part of the clip.
struct ThumbStrip: View {
    let image: NSImage
    let height: CGFloat
    let visible: ClosedRange<Double>

    var body: some View {
        let tileW = max(20, Double(height) * image.size.width / max(image.size.height, 1))
        let first = floor(visible.lowerBound / tileW)
        let count = max(0, min(Int(ceil(visible.upperBound / tileW) - first), 300))
        HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { _ in
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: tileW - 1, height: height).clipped()
            }
        }
        .offset(x: first * tileW)
    }
}

/// Small cached thumbnails for image clips (reloaded when the file changes).
final class TimelineThumbs {
    static let shared = TimelineThumbs()
    private var cache: [String: (modified: Date?, image: NSImage?)] = [:]

    func image(_ path: String) -> NSImage? {
        let expanded = (path as NSString).expandingTildeInPath
        let modified = (try? FileManager.default.attributesOfItem(atPath: expanded))?[.modificationDate] as? Date
        if let c = cache[expanded], c.modified == modified { return c.image }
        let img = AssetStore.thumbnail(URL(fileURLWithPath: expanded), maxPixels: 120)
            .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        cache[expanded] = (modified, img)
        return img
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
                .fill(shown ? Color.white : Color.primary.opacity(hovering ? 0.35 : 0.0001))
            if shown {
                Capsule().fill(Color.black.opacity(0.45)).frame(width: 1.5).padding(.vertical, 8)
            }
        }
            .frame(width: 6)
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

struct TimeRuler: View {
    let tl: TimelineState
    let onSeek: (Double) -> Void

    var body: some View {
        // Read observed values here so the Canvas redraws when they change.
        let pps = tl.pps, scrollX = tl.scrollX, duration = tl.duration
        Canvas { ctx, size in
            let candidates: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60]
            let step = candidates.first { $0 * pps >= 70 } ?? 60
            let minor = step / 5
            var t = max(0, floor(scrollX / pps / minor) * minor)
            let tEnd = min(duration, (scrollX + Double(size.width)) / pps)
            while t <= tEnd + 1e-9 {
                let x = t * pps - scrollX
                let isMajor = abs((t / step).rounded() * step - t) < 1e-6
                let h: CGFloat = isMajor ? 8 : 4
                ctx.fill(Path(CGRect(x: x, y: size.height - h, width: 1, height: h)),
                         with: .color(.secondary.opacity(isMajor ? 0.8 : 0.4)))
                if isMajor {
                    ctx.draw(Text(Self.label(t, step)).font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: x + 3, y: 7), anchor: .leading)
                }
                t += minor
            }
            // End of scene.
            let endX = duration * pps - scrollX
            if endX < size.width {
                ctx.fill(Path(CGRect(x: endX, y: 0, width: size.width - endX, height: size.height)),
                         with: .color(.secondary.opacity(0.12)))
            }
        }
        // RAM preview cache, along the top edge (its own view, so filling doesn't redraw the ticks).
        .overlay(alignment: .top) { CachedFramesStrip(pointsPerSecond: pps, offset: scrollX) }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            onSeek(tl.time(atX: g.location.x))
        })
    }

    static func label(_ t: Double, _ step: Double) -> String {
        if step < 1 { return String(format: "%.1fs", t) }
        if t >= 60 { return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        return "\(Int(t.rounded()))s"
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
                    .fill(Color.secondary.opacity(0.45))
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
