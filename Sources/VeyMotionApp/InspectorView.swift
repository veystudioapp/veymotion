import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeyMotionCore

struct InspectorView: View {
    @Environment(SceneStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let layer = store.selectedLayer {
                    LayerInspector(layer: layer)
                } else {
                    SceneInspector()
                }
            }
        }
    }
}

// MARK: - Scene

struct SceneInspector: View {
    @Environment(SceneStore.self) private var store

    var body: some View {
        let s = store.scene
        InspectorHeader(symbol: "film", tint: .accentColor, subtitle: "\(s.layers.count) layers") {
            Text("Scene").font(.headline)
        }
        InspectorSection("Format") {
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    NumberField("W", Double(s.width), unit: "px", digits: 0) { v in edit { $0.width = Int(v) } }
                    NumberField("H", Double(s.height), unit: "px", digits: 0) { v in edit { $0.height = Int(v) } }
                }
                GridRow {
                    NumberField("FPS", Double(s.fps), digits: 0) { v in edit { $0.fps = Int(v) } }
                    NumberField("Length", s.duration, unit: "s") { v in edit { $0.duration = v } }
                }
            }
            ColorField("Background", s.background) { c in edit { $0.background = c } }
        }
        Text("Select a layer to edit it. Claude and other agents edit the same scene; their changes show up live and can be undone with ⌘Z.")
            .font(.caption).foregroundStyle(.secondary)
            .padding(12)
    }

    private func edit(_ body: (inout MotionScene) -> Void) {
        do {
            try store.apply("Edit Scene") { s in
                body(&s)
                try s.validate()
            }
        } catch {
            store.message = error.localizedDescription
        }
    }
}

// MARK: - Layer

/// Icon tile + title block at the top of the inspector.
struct InspectorHeader<Title: View>: View {
    let symbol: String
    let tint: Color
    let subtitle: String
    @ViewBuilder var title: Title

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                title
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
        Divider()
    }
}

struct LayerInspector: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        InspectorHeader(symbol: layer.type.symbol, tint: layer.timelineColor,
                        subtitle: "\(layer.type.rawValue.capitalized) · id \(id)") {
            CommitTextField(placeholder: "Name", value: layer.name, font: .headline) { v in
                store.updateLayer(id, "Rename") { $0.name = v }
            }
        }
        InspectorSection("Timing") {
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    NumberField("Start", layer.start, unit: "s") { v in store.updateLayer(id) { $0.start = max(0, v) } }
                    NumberField("End", layer.effectiveEnd(sceneDuration: store.scene.duration), unit: "s") { v in
                        try? store.apply("Trim Layer") { try $0.setTiming(id, start: nil, end: v) }
                    }
                }
            }
        }
        if layer.type == .audio {
            AudioInspector(layer: layer)
        } else {
            InspectorSection("Transform") {
                Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        AnimField(layer: layer, property: .x, label: "X")
                        AnimField(layer: layer, property: .y, label: "Y")
                    }
                    GridRow {
                        AnimField(layer: layer, property: .scale, label: "Scale")
                        AnimField(layer: layer, property: .rotation, label: "Rotate", unit: "°")
                    }
                    GridRow {
                        AnimField(layer: layer, property: .scaleX, label: "Scale X")
                        AnimField(layer: layer, property: .scaleY, label: "Scale Y")
                    }
                    GridRow {
                        AnimField(layer: layer, property: .skewX, label: "Skew X", unit: "°")
                        AnimField(layer: layer, property: .skewY, label: "Skew Y", unit: "°")
                    }
                    GridRow {
                        AnimField(layer: layer, property: .anchorX, label: "Anchor X")
                        AnimField(layer: layer, property: .anchorY, label: "Anchor Y")
                    }
                }
                AnimSlider(layer: layer, property: .opacity, label: "Opacity")
                if layer.type == .text { AnimSlider(layer: layer, property: .reveal, label: "Reveal") }
                ParentRow(layer: layer)
            }
            InspectorSection(appearanceTitle) { appearance }
            if layer.type == .video, layer.path.map(MediaAudio.hasAudioTrack) ?? false { SpeechSection(layer: layer) }
            EffectsSection(layer: layer)
            MotionSection(layer: layer)
            if layer.type == .text { TextAnimatorSection(layer: layer) }
            PresetSection(layer: layer)
        }
    }

    private var appearanceTitle: String {
        switch layer.type {
        case .text: return "Text"
        case .image: return "Image"
        case .video: return "Video"
        case .particles: return "Particles"
        default: return "Shape"
        }
    }

    @ViewBuilder private var appearance: some View {
        let id = layer.id
        switch layer.type {
        case .rect, .ellipse:
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    AnimField(layer: layer, property: .width, label: "W")
                    AnimField(layer: layer, property: .height, label: "H")
                }
                GridRow {
                    if layer.type == .rect {
                        AnimField(layer: layer, property: .cornerRadius, label: "Radius")
                    } else {
                        Color.clear.frame(height: 1)
                    }
                    AnimField(layer: layer, property: .strokeWidth, label: "Stroke")
                }
            }
            AnimColorField(layer: layer, property: .fill, label: "Fill")
            AnimColorField(layer: layer, property: .stroke, label: "Stroke")
            AnimSlider(layer: layer, property: .trim, label: "Trim")
                .help("Part of the stroke that is drawn (animate 0 → 100% to draw the outline)")
        case .text:
            TextField("Text", text: Binding(get: { layer.text },
                                            set: { v in store.updateLayer(id, "Edit Text") { $0.text = v } }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    NumberField("Size", layer.fontSize, digits: 0) { v in store.updateLayer(id) { $0.fontSize = max(1, v) } }
                    Picker("", selection: Binding(get: { layer.fontWeight },
                                                  set: { v in store.updateLayer(id) { $0.fontWeight = v } })) {
                        ForEach(["thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"], id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                GridRow {
                    NumberField("Wrap", layer.maxWidth ?? 0, unit: layer.maxWidth == nil ? "off" : "px", digits: 0) { v in
                        store.updateLayer(id) { $0.maxWidth = v > 0 ? v : nil }
                    }
                    Picker("", selection: Binding(get: { layer.align },
                                                  set: { v in store.updateLayer(id) { $0.align = v } })) {
                        Image(systemName: "text.alignleft").tag(TextAlign.left)
                        Image(systemName: "text.aligncenter").tag(TextAlign.center)
                        Image(systemName: "text.alignright").tag(TextAlign.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                }
                GridRow {
                    AnimField(layer: layer, property: .letterSpacing, label: "Spacing")
                    Color.clear.frame(height: 1)
                }
            }
            AnimColorField(layer: layer, property: .color, label: "Color")
        case .image:
            FileRow(path: layer.path, kind: .image) { p in store.updateLayer(id, "Change Image") { $0.path = p } }
            sizeFields
        case .video:
            let fps = store.scene.fps
            FileRow(path: layer.path, kind: .video) { p in
                store.updateLayer(id, "Change Video") { l in
                    l.path = p; l.trimIn = 0; l.fps = nil
                    try? l.loadVideoInfo(sceneFps: fps)
                }
            }
            let sequence = layer.path.map(VideoSource.isSequence) ?? false
            if let d = layer.sourceDuration {
                Text(String(format: "%@ length %.2fs", sequence ? "Sequence" : "Clip", d))
                    .font(.caption).foregroundStyle(.secondary)
            }
            sizeFields
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    NumberField("Trim in", layer.trimIn, unit: "s") { v in store.updateLayer(id, "Trim Video") { $0.trimIn = max(0, v) } }
                    NumberField("Speed", layer.speed, unit: "×") { v in store.updateLayer(id, "Video Speed") { $0.speed = max(0.05, v) } }
                }
                if sequence {
                    GridRow {
                        NumberField("FPS", layer.fps ?? Double(fps), digits: 0) { v in
                            store.updateLayer(id, "Sequence FPS") { l in
                                l.fps = max(1, v)
                                try? l.loadVideoInfo(sceneFps: fps)
                            }
                        }
                        .help("Frame rate the images were rendered at (Blender's default is 24)")
                        Color.clear.frame(height: 1)
                    }
                }
            }
            HStack(spacing: 6) {
                RowLabel("At end")
                Picker("", selection: Binding(get: { layer.playback },
                                              set: { v in store.updateLayer(id, "Video Playback") { $0.playback = v } })) {
                    Text("Stop").tag(VideoPlayback.once)
                    Text("Hold").tag(VideoPlayback.hold)
                    Text("Loop").tag(VideoPlayback.loop)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            .help("Stop: the layer ends with the clip. Hold: the last frame stays. Loop: the clip starts over.")
            if layer.path.map(MediaAudio.hasAudioTrack) ?? false {
                AnimSlider(layer: layer, property: .volume, label: "Volume", range: 0...2)
                    .help(layer.speed == 1 ? "Level of the clip's own sound (0 = mute)" : "The clip's sound only plays at speed 1×")
            }
        case .particles:
            ParticlesEditor(layer: layer)
        case .audio:
            EmptyView()
        }
    }

    /// Width/height of an image or video ("auto" = natural size; one side set keeps the aspect).
    @ViewBuilder private var sizeFields: some View {
        let id = layer.id
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                let w = layer.width?.value(at: store.panelTime) ?? 0
                let h = layer.height?.value(at: store.panelTime) ?? 0
                HStack(spacing: 2) {
                    NumberField("W", w, unit: layer.width == nil ? "auto" : nil, digits: 0) { v in
                        store.setValue(id, .width, max(0, v))
                    }
                    if layer.width != nil { KeyframeButton(layer: layer, property: .width) }
                }
                HStack(spacing: 2) {
                    NumberField("H", h, unit: layer.height == nil ? "auto" : nil, digits: 0) { v in
                        store.setValue(id, .height, max(0, v))
                    }
                    if layer.height != nil { KeyframeButton(layer: layer, property: .height) }
                }
            }
        }
    }
}


/// Parent picker: the layer follows another layer's transform.
struct ParentRow: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let scene = store.scene
        let candidates = scene.layers.filter { $0.type.isVisual && $0.id != layer.id && !scene.isAncestor(layer.id, of: $0.id) }
        HStack(spacing: 6) {
            RowLabel("Parent")
            Picker("", selection: Binding(get: { layer.parent ?? "" }, set: { v in
                do {
                    try store.apply("Set Parent") { try $0.setParent(layer.id, to: v.isEmpty ? nil : v, at: store.time) }
                } catch {
                    store.message = error.localizedDescription
                }
            })) {
                Text("None").tag("")
                ForEach(candidates.reversed()) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .help("Follow another layer's position, rotation and scale")
    }
}

/// Blur and drop shadow.
struct EffectsSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        InspectorSection("Effects") {
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    AnimField(layer: layer, property: .blur, label: "Blur")
                    Color.clear.frame(height: 1)
                }
            }
            HStack(spacing: 6) {
                RowLabel("Blend")
                Picker("", selection: Binding(get: { layer.blendMode },
                                              set: { v in store.updateLayer(layer.id, "Blend Mode") { $0.blendMode = v } })) {
                    ForEach(BlendMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            .help("Add and Screen brighten what is below and drop dark areas (fire, glows, footage shot on black)")
            AnimSlider(layer: layer, property: .shadowOpacity, label: "Shadow")
            if layer.value(.shadowOpacity, at: store.panelTime) > 0 || layer[.shadowOpacity].isAnimated {
                Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        AnimField(layer: layer, property: .shadowX, label: "X")
                        AnimField(layer: layer, property: .shadowY, label: "Y")
                    }
                    GridRow {
                        AnimField(layer: layer, property: .shadowBlur, label: "Soft")
                        Color.clear.frame(height: 1)
                    }
                }
                ColorField("Shadow", layer.shadowColor) { c in store.updateLayer(layer.id, "Shadow Color") { $0.shadowColor = c } }
            }
        }
    }
}

/// Motion path, loops and wiggle.
struct MotionSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        InspectorSection("Motion") {
            if let mp = layer.motionPath {
                HStack {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(.secondary)
                    Text("Path · \(mp.points.count) points").font(.callout)
                    Spacer()
                    Button("Remove") {
                        store.updateLayer(id, "Remove Motion Path") { l in
                            let p = l.position(at: store.time).point
                            l.motionPath = nil
                            l.x = .constant(p.x); l.y = .constant(p.y)
                            l[.pathProgress] = .constant(0)
                        }
                    }
                    .controlSize(.small)
                }
                AnimSlider(layer: layer, property: .pathProgress, label: "Progress")
                HStack(spacing: 12) {
                    Toggle("Smooth", isOn: pathBinding(\.smooth))
                    Toggle("Closed", isOn: pathBinding(\.closed))
                    Toggle("Orient", isOn: pathBinding(\.orient))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            } else {
                Button("Add Motion Path") { addPath() }
                    .controlSize(.small)
                    .help("Make the layer travel along a curve (edit the points via JSON or ask Claude)")
            }
            let loopable = layer.animatedTracks
            if !loopable.isEmpty {
                Text("Loop after last key").font(.caption).foregroundStyle(.secondary)
                ForEach(loopable, id: \.self) { k in
                    HStack(spacing: 6) {
                        RowLabel(k.title)
                        Picker("", selection: Binding(get: { layer.loop[k.name] }, set: { m in
                            store.updateLayer(id, "Loop") { $0.loop[k.name] = m }
                        })) {
                            Text("None").tag(LoopMode?.none)
                            ForEach(LoopMode.allCases, id: \.self) { Text($0.title).tag(LoopMode?.some($0)) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }
            }
            ForEach(layer.wiggle.keys.sorted(), id: \.self) { key in
                if let w = layer.wiggle[key], let p = AnimProperty(rawValue: key) {
                    HStack(spacing: 6) {
                        Text("Wiggle \(p.title)").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            .lineLimit(1)
                        NumberField("Amt", w.amount, digits: 1) { v in store.updateLayer(id, "Wiggle") { $0.wiggle[key]?.amount = v } }
                        NumberField("Hz", w.frequency, digits: 1) { v in
                            store.updateLayer(id, "Wiggle") { $0.wiggle[key]?.frequency = max(0, v) }
                        }
                        Button { store.updateLayer(id, "Remove Wiggle") { $0.wiggle[key] = nil } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Menu("Add Wiggle") {
                ForEach(layer.applicableProperties.filter { layer.wiggle[$0.rawValue] == nil }, id: \.self) { p in
                    Button(p.title) {
                        let amount: Double = p.isFractional ? 0.1 : (p == .rotation || p == .skewX || p == .skewY) ? 5 : 20
                        store.updateLayer(id, "Add Wiggle") { $0.wiggle[p.rawValue] = Wiggle(amount: amount) }
                    }
                }
            }
            .controlSize(.small)
            .fixedSize()
            audioReactRows
        }
    }

    /// Properties driven by the music (audioReact).
    @ViewBuilder private var audioReactRows: some View {
        let id = layer.id
        let audio = store.scene.audioLayers
        ForEach(layer.audioReact.keys.sorted(), id: \.self) { key in
            if let r = layer.audioReact[key], let p = AnimProperty(rawValue: key) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("♪ \(p.title)").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            .lineLimit(1)
                        Picker("", selection: Binding(get: { r.band }, set: { b in
                            store.updateLayer(id, "Audio React") { $0.audioReact[key]?.band = b }
                        })) {
                            ForEach(AudioBand.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .help("What the property follows: loudness (overall or a band), or a pulse on every beat / bar")
                        if audio.count > 1 {
                            Picker("", selection: Binding(get: { r.source }, set: { s in
                                store.updateLayer(id, "Audio React") { $0.audioReact[key]?.source = s }
                            })) {
                                Text("Music").tag(String?.none)
                                ForEach(audio) { Text($0.name).tag(String?.some($0.id)) }
                            }
                            .labelsHidden()
                            .help("Audio layer to follow")
                        }
                        Button { store.updateLayer(id, "Remove Audio React") { $0.audioReact[key] = nil } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .controlSize(.small)
                    HStack(spacing: 6) {
                        Color.clear.frame(width: 64, height: 1)
                        NumberField("Amt", r.amount, digits: p.isFractional ? 2 : 1) { v in
                            store.updateLayer(id, "Audio React") { $0.audioReact[key]?.amount = v }
                        }
                        .help("Added at full level, in the property's unit (negative = the other way)")
                        NumberField("Release", r.release, unit: "s", digits: 2) { v in
                            store.updateLayer(id, "Audio React") { $0.audioReact[key]?.release = max(0.01, v) }
                        }
                        .help("How long it takes to fall back after a peak")
                    }
                }
            }
        }
        Menu("Add Audio React") {
            ForEach(layer.applicableProperties.filter { layer.audioReact[$0.rawValue] == nil }, id: \.self) { p in
                Button(p.title) {
                    let amount: Double = p.isFractional ? 0.15 : (p == .rotation || p == .skewX || p == .skewY) ? 5 : 20
                    let band: AudioBand = [.scale, .scaleX, .scaleY].contains(p) ? .bass : p.isFractional ? .level : .beat
                    store.updateLayer(id, "Add Audio React") { $0.audioReact[p.rawValue] = AudioReact(amount: amount, band: band) }
                }
            }
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(audio.isEmpty)
        .help(audio.isEmpty ? "Add music (an audio layer) first" : "Make a property move with the music")
    }

    private func pathBinding(_ kp: WritableKeyPath<MotionPath, Bool>) -> Binding<Bool> {
        Binding(get: { layer.motionPath?[keyPath: kp] ?? false },
                set: { v in store.updateLayer(layer.id, "Motion Path") { $0.motionPath?[keyPath: kp] = v } })
    }

    /// A gentle arc through the layer's current position, traveled over 2 seconds from the playhead.
    private func addPath() {
        let t = store.time
        let end = min(t + 2, store.scene.duration)
        store.updateLayer(layer.id, "Add Motion Path") { l in
            let c = l.position(at: t).point
            l.motionPath = MotionPath(points: [PathPoint(x: c.x - 300, y: c.y + 120), PathPoint(x: c.x, y: c.y - 80),
                                               PathPoint(x: c.x + 300, y: c.y + 120)])
            l[.pathProgress] = .keyframes([MotionKeyframe(t: t, v: 0, easing: .linear),
                                           MotionKeyframe(t: max(end, t + 0.1), v: 1, easing: .easeInOut)])
        }
    }
}

/// Per-character / word / line animations of a text layer.
struct TextAnimatorSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        InspectorSection("Text Animators") {
            ForEach(Array(layer.textAnimators.enumerated()), id: \.offset) { i, a in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Picker("", selection: bind(i, \.unit)) {
                            ForEach(TextUnit.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Picker("", selection: bind(i, \.mode)) {
                            Text("In").tag(AnimatorMode.in)
                            Text("Out").tag(AnimatorMode.out)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 80)
                        Button { store.updateLayer(id, "Remove Animator") { $0.textAnimators.remove(at: i) } } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .controlSize(.small)
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        GridRow {
                            NumberField("Start", a.start, unit: "s") { v in edit(i) { $0.start = max(0, v) } }
                            NumberField("Each", a.duration, unit: "s") { v in edit(i) { $0.duration = max(0.01, v) } }
                        }
                        GridRow {
                            NumberField("Stagger", a.stagger, unit: "s", digits: 3) { v in edit(i) { $0.stagger = max(0, v) } }
                            Picker("", selection: bind(i, \.order)) {
                                ForEach(StaggerOrder.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                            }
                            .labelsHidden().controlSize(.small)
                        }
                        GridRow {
                            NumberField("X", a.x, digits: 0) { v in edit(i) { $0.x = v } }
                            NumberField("Y", a.y, digits: 0) { v in edit(i) { $0.y = v } }
                        }
                        GridRow {
                            NumberField("Scale", a.scale) { v in edit(i) { $0.scale = v } }
                            NumberField("Rotate", a.rotation, unit: "°", digits: 0) { v in edit(i) { $0.rotation = v } }
                        }
                        GridRow {
                            NumberField("Opacity", a.opacity * 100, unit: "%", digits: 0) { v in
                                edit(i) { $0.opacity = min(max(v / 100, 0), 1) }
                            }
                            Menu(a.easing.title) {
                                EasingMenuItems(current: a.easing) { e in edit(i) { $0.easing = e } }
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("Values are the \(a.mode == .in ? "starting" : "ending") state of each \(a.unit.rawValue).")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.bottom, 4)
                Divider()
            }
            Button("Add Animator") {
                let t = store.time
                store.updateLayer(id, "Add Animator") {
                    $0.textAnimators.append(TextAnimator(start: t, easing: .curve(.cubic, .out), y: 40))
                }
            }
            .controlSize(.small)
        }
    }

    private func edit(_ i: Int, _ body: @escaping (inout TextAnimator) -> Void) {
        store.updateLayer(layer.id, "Edit Animator") { l in
            guard l.textAnimators.indices.contains(i) else { return }
            body(&l.textAnimators[i])
        }
    }

    private func bind<V>(_ i: Int, _ kp: WritableKeyPath<TextAnimator, V>) -> Binding<V> {
        Binding(get: { layer.textAnimators[i][keyPath: kp] }, set: { v in edit(i) { $0[keyPath: kp] = v } })
    }
}

/// Animation presets applied from the playhead, grouped by kind.
struct PresetSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer
    @AppStorage("presetDuration") private var duration = 0.6

    var body: some View {
        InspectorSection("Animate") {
            HStack(spacing: 6) {
                NumberField("Duration", duration, unit: "s") { duration = max($0, 0.05) }
                    .frame(width: 130)
                Text("from the playhead").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Preset.Group.allCases, id: \.self) { g in
                let presets = Preset.allCases.filter { $0.group == g && $0.applies(to: layer.type) }
                if !presets.isEmpty {
                    Text(g.rawValue).font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(presets, id: \.self) { p in
                            Button { store.applyPreset(p, duration: duration) } label: {
                                Text(p.title).font(.caption).frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

/// File name + a menu to pick another file, from the asset library or from disk.
struct FileRow: View {
    let path: String?
    let kind: AssetKind
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind == .image ? "photo" : kind == .video ? "film" : "waveform").foregroundStyle(.secondary)
            Text((path as NSString?)?.lastPathComponent ?? "No file")
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(path == nil ? .secondary : .primary)
                .help(path ?? "")
            Spacer(minLength: 4)
            Menu("Replace") {
                let assets = AssetLibrary.shared.assets.filter { $0.kind == kind }
                if !assets.isEmpty {
                    Section("Assets") {
                        ForEach(assets) { a in Button(a.name) { onPick(a.path) } }
                    }
                }
                Button("Other File…") {
                    let panel = NSOpenPanel()
                    switch kind {
                    case .image: panel.allowedContentTypes = [.image]
                    case .video:
                        panel.allowedContentTypes = [.movie, .folder] // a folder = image sequence
                        panel.canChooseDirectories = true
                    default: panel.allowedContentTypes = [.audio]
                    }
                    if panel.runModal() == .OK, let url = panel.url { onPick(url.path) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.callout)
        .fieldBackground()
    }
}

// MARK: - Audio

struct AudioInspector: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        InspectorSection("Audio") {
            FileRow(path: layer.path, kind: .audio) { p in
                let d = try? AudioFileInfo.duration(of: p)
                store.updateLayer(id, "Change Audio") { $0.path = p; $0.sourceDuration = d; $0.trimIn = 0 }
            }
            if let d = layer.sourceDuration {
                Text(String(format: "File length %.2fs", d)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                RowLabel("Role")
                Picker("", selection: Binding(get: { layer.role }, set: { v in store.updateLayer(id, "Audio Role") { $0.role = v } })) {
                    ForEach(AudioRole.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            AnimSlider(layer: layer, property: .volume, label: "Volume", range: 0...2)
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    NumberField("Trim in", layer.trimIn, unit: "s") { v in store.updateLayer(id, "Trim Audio") { $0.trimIn = max(0, v) } }
                    if layer.role == .music {
                        NumberField("Duck to", (layer.duckTo ?? 1) * 100, unit: "%", digits: 0) { v in
                            store.updateLayer(id, "Ducking") { $0.duckTo = v >= 100 ? nil : max(0, v / 100) }
                        }
                        .help("Music level while a voice is speaking (100% = no ducking)")
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
                GridRow {
                    NumberField("Fade in", layer.fadeIn, unit: "s") { v in store.updateLayer(id, "Fade In") { $0.fadeIn = max(0, v) } }
                    NumberField("Fade out", layer.fadeOut, unit: "s") { v in store.updateLayer(id, "Fade Out") { $0.fadeOut = max(0, v) } }
                }
            }
        }
        SpeechSection(layer: layer)
    }
}

/// Transcript and captions of an audio or video layer: a generated voice-over already has its words; other sound
/// is transcribed with Apple speech recognition.
struct SpeechSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer
    @AppStorage("transcribeLanguage") private var language = ""
    @State private var languages: [String] = []

    private var isGeneratedVoice: Bool { layer.type == .audio && layer.role == .voice && layer.words?.contains { $0.d != nil } == false }

    var body: some View {
        let id = layer.id
        InspectorSection(isGeneratedVoice ? "Narration" : "Speech") {
            if let t = layer.transcript, !t.isEmpty {
                ScrollView {
                    Text(t).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            if !isGeneratedVoice {
                HStack(spacing: 6) {
                    RowLabel("Language")
                    Picker("", selection: $language) {
                        Text("System").tag("")
                        ForEach(languages, id: \.self) { code in
                            Text(Locale.current.localizedString(forIdentifier: code).map { "\($0) (\(code))" } ?? code).tag(code)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                .help("The language spoken in the clip")
            }
            HStack(spacing: 8) {
                if !isGeneratedVoice {
                    Button(layer.words == nil ? "Transcribe" : "Transcribe Again") {
                        store.transcribe(id, language: language.isEmpty ? nil : language)
                    }
                    .disabled(store.transcribing.contains(id))
                    if store.transcribing.contains(id) { ProgressView().controlSize(.small) }
                }
                Button(store.scene.layers.contains { $0.id.hasPrefix("cap-\(id)-") } ? "Rebuild Captions" : "Add Captions") {
                    store.addCaptions(for: id)
                }
                .disabled(layer.words?.isEmpty ?? true)
            }
            .controlSize(.small)
            if !isGeneratedVoice && layer.words == nil {
                Text("Recognizes the speech with Apple speech recognition, then makes timed captions. Ask Claude to translate them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            if languages.isEmpty {
                languages = await Task.detached { Transcriber.supportedLanguages() }.value
            }
        }
    }
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent),
                  a: Double(ns.alphaComponent))
    }
}
