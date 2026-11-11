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
        CameraSection()
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
                if layer.type != .particles { PerspectiveRows(layer: layer) }
                if store.scene.camera != nil {
                    HStack(spacing: 8) {
                        if !layer.is3D {
                            NumberField("Depth", layer.depth) { v in store.updateLayer(layer.id, "Depth") { $0.depth = max(-0.9, v) } }
                                .help("Parallax: 0 moves with the camera, 1 half as much (far), -0.5 twice as much (close)")
                        }
                        Toggle("Fixed", isOn: Binding(get: { layer.fixed }, set: { v in store.updateLayer(layer.id, "Fixed") { $0.fixed = v } }))
                            .toggleStyle(.checkbox).controlSize(.small)
                            .help("Ignore the camera (captions, logos)")
                    }
                }
            }
            InspectorSection(appearanceTitle) { appearance }
            if layer.type == .video, layer.path.map(MediaAudio.hasAudioTrack) ?? false { SpeechSection(layer: layer) }
            EffectsSection(layer: layer)
            ColorSection(layer: layer)
            WipeSection(layer: layer)
            StylizeSection(layer: layer)
            DistortSection(layer: layer)
            KeyingSection(layer: layer)
            MotionSection(layer: layer)
            RepeaterSection(layer: layer)
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
        case .generator: return "Generator"
        case .model: return "3D Object"
        case .group: return "Group"
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
            GradientRows(layer: layer)
            AnimColorField(layer: layer, property: .stroke, label: "Stroke")
            StrokeTrimRows(layer: layer)
        case .path:
            PathShapeField(layer: layer)
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    AnimField(layer: layer, property: .strokeWidth, label: "Stroke")
                    Picker("", selection: Binding(get: { layer.fillRule },
                                                  set: { v in store.updateLayer(id, "Fill Rule") { $0.fillRule = v } })) {
                        Text("Nonzero").tag(FillRule.nonzero)
                        Text("Even-odd").tag(FillRule.evenodd)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .help("Even-odd turns shapes inside other shapes into holes")
                }
            }
            AnimColorField(layer: layer, property: .fill, label: "Fill")
            GradientRows(layer: layer)
            AnimColorField(layer: layer, property: .stroke, label: "Stroke")
            StrokeTrimRows(layer: layer)
        case .text:
            TextField("Text", text: Binding(get: { layer.text },
                                            set: { v in store.updateLayer(id, "Edit Text") { $0.text = v } }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            FontFamilyRow(layer: layer)
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
                    AnimField(layer: layer, property: .strokeWidth, label: "Outline")
                }
                if layer.text.contains("{n}") {
                    GridRow {
                        AnimField(layer: layer, property: .counter, label: "Count")
                        HStack(spacing: 4) {
                            NumberField("Dec.", Double(layer.counterDecimals), digits: 0) { v in
                                store.updateLayer(id, "Counter Format") { $0.counterDecimals = min(max(Int(v), 0), 6) }
                            }
                            Toggle("1,000", isOn: Binding(get: { layer.counterGrouping }, set: { v in
                                store.updateLayer(id, "Counter Format") { $0.counterGrouping = v }
                            }))
                            .toggleStyle(.checkbox).controlSize(.small)
                        }
                    }
                }
            }
            if !layer.text.contains("{n}") {
                Text("Tip: write {n} in the text to show an animated number (Count).").font(.caption2).foregroundStyle(.tertiary)
            }
            AnimSlider(layer: layer, property: .scramble, label: "Scramble")
                .help("Share of the letters shown as random characters; keyframe 100% → 0 for a decode effect")
            AnimColorField(layer: layer, property: .color, label: "Color")
            AnimColorField(layer: layer, property: .stroke, label: "Outline")
            GradientRows(layer: layer)
            if let mp = layer.textPath {
                HStack {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(.secondary)
                    Text("On a path · \(mp.points.count) points").font(.callout)
                    Spacer()
                    Button("Remove") { store.updateLayer(id, "Remove Text Path") { $0.textPath = nil } }.controlSize(.small)
                }
                AnimField(layer: layer, property: .textOffset, label: "Offset")
            } else {
                Button("Put on an Arc") {
                    store.updateLayer(id, "Text on Path") { l in
                        let w = max(l.fontSize * Double(max(l.text.count, 4)) * 0.3, 200)
                        l.textPath = MotionPath(points: [PathPoint(x: -w, y: w * 0.3), PathPoint(x: 0, y: -w * 0.2),
                                                         PathPoint(x: w, y: w * 0.3)], smooth: true)
                    }
                }
                .controlSize(.small)
                .help("Lay the text along a curve (edit the points in JSON or with Claude)")
            }
            HStack {
                Button("Convert to Path") { store.textToPath(id, letters: false) }
                    .help("Turn the letters into a vector path (trim, morph, Write On preset)")
                Button("Split into Letters") { store.textToPath(id, letters: true) }
                    .help("A group with one path per letter, each animatable on its own")
            }
            .controlSize(.small)
        case .image:
            FileRow(path: layer.path, kind: .image) { p in store.updateLayer(id, "Change Image") { $0.path = p } }
            sizeFields
            BackgroundRow(layer: layer)
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
            BackgroundRow(layer: layer)
            HStack(spacing: 6) {
                RowLabel("Slow-mo")
                Picker("", selection: Binding(get: { layer.frameBlend }, set: { v in store.updateLayer(id, "Frame Blending") { $0.frameBlend = v } })) {
                    Text("Nearest frame").tag(FrameBlend.off)
                    Text("Blend frames").tag(FrameBlend.blend)
                    Text("Optical flow").tag(FrameBlend.flow)
                }
                .labelsHidden().controlSize(.small)
            }
            .help("How in-between source times look when the clip is slowed down (speed < 1 or time remap)")
            if layer.timeRemap != nil {
                HStack {
                    AnimField(layer: layer, property: .timeRemap, label: "Source", unit: "s")
                    Button("Off") { store.updateLayer(id, "Remove Time Remap") { $0.timeRemap = nil } }.controlSize(.small)
                }
                .help("Time remap: the source second shown at the playhead; keyframe it for speed ramps, freezes and reverse")
            } else {
                Button("Time remap") {
                    store.updateLayer(id, "Time Remap") { l in
                        let now = l.videoTime(at: store.time) ?? 0
                        l.timeRemap = .keyframes([MotionKeyframe(t: store.time, v: now, easing: .linear)])
                    }
                }
                .controlSize(.small)
                .help("Keyframe the source time: speed ramps, freeze frames, reverse (replaces speed and trim)")
            }
            if layer.path.map(MediaAudio.hasAudioTrack) ?? false {
                AnimSlider(layer: layer, property: .volume, label: "Volume", range: 0...2)
                    .help(layer.speed == 1 ? "Level of the clip's own sound (0 = mute)" : "The clip's sound only plays at speed 1×")
            }
        case .particles:
            ParticlesEditor(layer: layer)
        case .generator:
            GeneratorEditor(layer: layer)
        case .model:
            ModelEditor(layer: layer)
        case .group:
            Text("\(layer.children.count) layers inside · \(layer.children.map(\.name).joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    let w = layer.width?.value(at: store.panelTime) ?? Double(store.scene.width)
                    let h = layer.height?.value(at: store.panelTime) ?? Double(store.scene.height)
                    NumberField("W", w, unit: layer.width == nil ? "scene" : nil, digits: 0) { v in store.setValue(id, .width, max(0, v)) }
                    NumberField("H", h, unit: layer.height == nil ? "scene" : nil, digits: 0) { v in store.setValue(id, .height, max(0, v)) }
                }
            }
            Button("Ungroup") { store.ungroupSelected() }.controlSize(.small)
            Text("Edit the layers inside with Claude (they keep their ids) or ungroup.").font(.caption).foregroundStyle(.secondary)
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
            AnimSlider(layer: layer, property: .glow, label: "Glow", range: 0...2)
            if layer.value(.glow, at: store.panelTime) > 0 || layer[.glow].isAnimated {
                Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        AnimField(layer: layer, property: .glowRadius, label: "Radius")
                        Toggle("Tint", isOn: Binding(get: { layer.glowColor != nil }, set: { on in
                            store.updateLayer(layer.id, "Glow Tint") { $0.glowColor = on ? RGBA(hex: "#FFD27A") : nil }
                        }))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                    }
                }
                if let tint = layer.glowColor {
                    ColorField("Glow", tint) { c in store.updateLayer(layer.id, "Glow Color") { $0.glowColor = c } }
                }
            }
            LightRows(layer: layer)
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    NumberField("Motion blur", layer.motionBlur, unit: "°", digits: 0) { v in
                        store.updateLayer(layer.id, "Motion Blur") { $0.motionBlur = min(max(v, 0), 720) }
                    }
                    .help("Shutter angle: 180° = natural film blur on fast moves, 0 = off")
                    Color.clear.frame(height: 1)
                }
            }
            MatteRow(layer: layer)
        }
    }
}

/// Color correction: brightness, contrast, saturation, hue and tint.
struct ColorSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        InspectorSection("Color") {
            AnimSlider(layer: layer, property: .brightness, label: "Brightness", range: -1...1)
            AnimSlider(layer: layer, property: .contrast, label: "Contrast", range: -1...1)
            AnimSlider(layer: layer, property: .saturation, label: "Saturation", range: -1...1)
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    AnimField(layer: layer, property: .hue, label: "Hue", unit: "°")
                    AnimField(layer: layer, property: .levelsGamma, label: "Gamma")
                }
                GridRow {
                    AnimField(layer: layer, property: .levelsBlack, label: "Black pt")
                    AnimField(layer: layer, property: .levelsWhite, label: "White pt")
                }
            }
            .help("Levels: input black/white points (0…1) and gamma")
            AnimSlider(layer: layer, property: .tint, label: "Tint")
            if layer.value(.tint, at: store.panelTime) > 0 || layer[.tint].isAnimated {
                ColorField("Tint", layer.tintColor ?? .white) { c in
                    store.updateLayer(id, "Tint Color") { $0.tintColor = c }
                }
                .help("White maps to this color, black stays black")
            }
            GradingRows(layer: layer)
            let touched: [AnimProperty] = [.brightness, .contrast, .saturation, .hue, .tint, .levelsBlack, .levelsWhite,
                                           .levelsGamma, .gradientMapAmount, .lutAmount]
            if touched.contains(where: { layer.extra[$0] != nil }) || !layer.curves.isEmpty || !layer.gradientMap.isEmpty || layer.lut != nil {
                Button("Reset Color") {
                    store.updateLayer(id, "Reset Color") { l in
                        for p in touched { l[p] = .constant(p.defaultValue) }
                        l.tintColor = nil
                        l.curves = []; l.gradientMap = []; l.lut = nil
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

/// Vision background removal on an image or video layer.
struct BackgroundRow: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        HStack(spacing: 6) {
            RowLabel("Cut out")
            Picker("", selection: Binding(get: { layer.removeBackground?.rawValue ?? "" }, set: { v in
                store.updateLayer(layer.id, "Remove Background") { $0.removeBackground = BackgroundRemoval(rawValue: v) }
            })) {
                Text("Keep background").tag("")
                Text("Person").tag(BackgroundRemoval.person.rawValue)
                Text("Main subject").tag(BackgroundRemoval.subject.rawValue)
            }
            .labelsHidden().controlSize(.small)
        }
        .help("Remove the background with Vision (no green screen needed). Slow on video: each frame is analyzed.")
    }
}

/// 2.5D: rotation around X/Y with perspective, card-flip backface, and corner pin / puppet pin status.
struct PerspectiveRows: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        if layer.type != .model {
            Toggle("3D layer", isOn: Binding(get: { layer.threeD }, set: { v in
                store.updateLayer(id, v ? "Make 3D" : "Make 2D") { $0.threeD = v }
            }))
            .toggleStyle(.checkbox).controlSize(.small)
            .help("Place the layer in the scene's 3D space: a Z depth, rotations seen through the camera (orbit, distance, lens), drawn by depth")
        }
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            if layer.is3D {
                GridRow {
                    AnimField(layer: layer, property: .z, label: "Z")
                    if layer.type == .model {
                        AnimField(layer: layer, property: .scaleZ, label: "Scale Z")
                    } else {
                        Toggle("Hide back", isOn: Binding(get: { layer.hideBackface }, set: { v in
                            store.updateLayer(id, "Backface") { $0.hideBackface = v }
                        }))
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help("Hide the layer while it is turned away (two layers = the two faces of a card)")
                    }
                }
            }
            GridRow {
                AnimField(layer: layer, property: .rotationX, label: "Rot X", unit: "°")
                AnimField(layer: layer, property: .rotationY, label: "Rot Y", unit: "°")
            }
            if !layer.is3D, layer.value(.rotationX, at: store.panelTime) != 0 || layer.value(.rotationY, at: store.panelTime) != 0
                || layer[.rotationX].isAnimated || layer[.rotationY].isAnimated {
                GridRow {
                    AnimField(layer: layer, property: .perspective, label: "Persp.")
                    Toggle("Hide back", isOn: Binding(get: { layer.hideBackface }, set: { v in
                        store.updateLayer(id, "Backface") { $0.hideBackface = v }
                    }))
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("Hide the layer while it is turned away (two layers = the two faces of a card)")
                }
            }
        }
        .help(layer.is3D ? "3D: Z = depth (+ is away), X tips the top back, Y turns the right side back"
              : "2.5D rotation: X tips the top back, Y turns the right side back; perspective = viewing distance in px")
        if layer.cornerPin != nil || !layer.pins.isEmpty {
            HStack {
                Image(systemName: "pin").foregroundStyle(.secondary)
                Text(layer.cornerPin != nil ? "Corner pinned" : "\(layer.pins.count) puppet pins").font(.caption)
                Spacer()
                Button("Remove") { store.updateLayer(id, "Remove Pins") { $0.cornerPin = nil; $0.pins = [] } }.controlSize(.small)
            }
            .help("Edit the pin positions in JSON or ask Claude")
        }
    }
}

/// Curves, gradient map and LUT.
struct GradingRows: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        HStack(spacing: 6) {
            RowLabel("Curve")
            Picker("", selection: Binding(get: { Self.curveName(layer.curves) }, set: { v in
                store.updateLayer(id, "Curves") { $0.curves = Self.curves[v] ?? [] }
            })) {
                ForEach(Self.curveOrder, id: \.self) { Text($0).tag($0) }
                if Self.curveName(layer.curves) == "Custom" { Text("Custom").tag("Custom") }
            }
            .labelsHidden().controlSize(.small)
        }
        .help("Tone curve presets (custom points in JSON or with Claude)")
        if layer.gradientMap.isEmpty {
            Button("Add gradient map") {
                store.updateLayer(id, "Gradient Map") { $0.gradientMap = [RGBA(hex: "#1B0F3A")!, RGBA(hex: "#E8436A")!, RGBA(hex: "#FFE7A8")!] }
            }
            .controlSize(.small)
            .help("Map brightness onto colors (duotone / tritone)")
        } else {
            ForEach(Array(layer.gradientMap.enumerated()), id: \.offset) { i, c in
                ColorField(i == 0 ? "Shadows" : i == layer.gradientMap.count - 1 ? "Highlights" : "Mids", c) { nc in
                    store.updateLayer(id, "Gradient Map") { $0.gradientMap[i] = nc }
                }
            }
            HStack {
                AnimSlider(layer: layer, property: .gradientMapAmount, label: "Map")
                Button { store.updateLayer(id, "Remove Gradient Map") { $0.gradientMap = [] } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        FileRow(path: layer.lut, kind: .other) { p in store.updateLayer(id, "LUT") { $0.lut = p } }
            .help("A .cube color lookup table (film looks, camera LUTs)")
        if layer.lut != nil {
            HStack {
                AnimSlider(layer: layer, property: .lutAmount, label: "LUT")
                Button { store.updateLayer(id, "Remove LUT") { $0.lut = nil } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
    }

    static let curveOrder = ["None", "S-curve", "Soft", "Fade", "Crush"]
    static let curves: [String: [PathPoint]] = [
        "None": [],
        "S-curve": [PathPoint(x: 0, y: 0), PathPoint(x: 0.25, y: 0.18), PathPoint(x: 0.75, y: 0.85), PathPoint(x: 1, y: 1)],
        "Soft": [PathPoint(x: 0, y: 0.04), PathPoint(x: 0.5, y: 0.52), PathPoint(x: 1, y: 0.96)],
        "Fade": [PathPoint(x: 0, y: 0.12), PathPoint(x: 0.5, y: 0.5), PathPoint(x: 1, y: 0.92)],
        "Crush": [PathPoint(x: 0, y: 0), PathPoint(x: 0.2, y: 0.05), PathPoint(x: 0.8, y: 0.95), PathPoint(x: 1, y: 1)],
    ]

    static func curveName(_ pts: [PathPoint]) -> String {
        curves.first { $0.value == pts }?.key ?? "Custom"
    }
}

/// Transition that wipes the layer away (or in, animated 1 → 0).
struct WipeSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        let style = layer.wipeStyle ?? WipeStyle()
        InspectorSection("Wipe") {
            AnimSlider(layer: layer, property: .wipe, label: "Wipe")
                .help("0 = the whole layer shows, 100% = wiped away. Keyframe 100% → 0 to reveal it.")
            HStack(spacing: 6) {
                RowLabel("Type")
                Picker("", selection: Binding(get: { style.type }, set: { v in
                    store.updateLayer(id, "Wipe Type") { l in
                        var s = l.wipeStyle ?? WipeStyle()
                        s.type = v
                        l.wipeStyle = s
                    }
                })) {
                    ForEach(WipeType.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    if style.type == .iris || style.type == .blocks {
                        Color.clear.frame(height: 1)
                    } else {
                        NumberField(style.type == .radial ? "Start" : "Angle", style.angle, unit: "°", digits: 0) { v in
                            edit(id) { $0.angle = v }
                        }
                        .help(style.type == .radial ? "Where the hand starts: 0° = 12 o'clock"
                              : "Direction the edge travels as the wipe goes up: 0° = rightward, 90° = down")
                    }
                    NumberField("Feather", style.feather, digits: 0) { v in edit(id) { $0.feather = max(0, v) } }
                        .help("Soft edge width in px")
                }
                if style.type == .blinds || style.type == .blocks {
                    GridRow {
                        NumberField(style.type == .blinds ? "Stripes" : "Blocks", Double(style.count), digits: 0) { v in
                            edit(id) { $0.count = min(max(Int(v), 1), 200) }
                        }
                        if style.type == .blocks {
                            NumberField("Seed", Double(style.seed), digits: 0) { v in edit(id) { $0.seed = Int(v) } }
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                }
            }
            if style.type == .radial || style.type == .iris {
                Toggle(style.type == .radial ? "Counter-clockwise" : "Open from center",
                       isOn: Binding(get: { style.reverse }, set: { v in edit(id) { $0.reverse = v } }))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }
        }
    }

    private func edit(_ id: String, _ change: @escaping (inout WipeStyle) -> Void) {
        store.updateLayer(id, "Wipe") { l in
            var s = l.wipeStyle ?? WipeStyle()
            change(&s)
            l.wipeStyle = s
        }
    }
}

/// The scene camera: pan, zoom and rotation (values at the playhead; keyframes are upserted when animated).
struct CameraSection: View {
    @Environment(SceneStore.self) private var store

    var body: some View {
        let s = store.scene
        let t = store.panelTime
        InspectorSection("Camera") {
            Toggle("Camera on", isOn: Binding(get: { s.camera != nil }, set: { on in
                store.editScene(on ? "Add Camera" : "Remove Camera") { sc in
                    sc.camera = on ? Camera(x: Double(sc.width) / 2, y: Double(sc.height) / 2) : nil
                }
            }))
            .toggleStyle(.checkbox).controlSize(.small)
            .help("Pan, zoom and turn the whole scene; layers with depth move less or more (parallax)")
            if let cam = s.camera {
                Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        NumberField("X", cam.x.value(at: t), digits: 0) { v in edit("Camera X") { $0.x = $0.x.setting(v, at: store.time) } }
                        NumberField("Y", cam.y.value(at: t), digits: 0) { v in edit("Camera Y") { $0.y = $0.y.setting(v, at: store.time) } }
                    }
                    GridRow {
                        NumberField("Zoom", cam.zoom.value(at: t), unit: "×") { v in edit("Camera Zoom") { $0.zoom = $0.zoom.setting(max(0.05, v), at: store.time) } }
                        NumberField("Rotate", cam.rotation.value(at: t), unit: "°", digits: 1) { v in edit("Camera Rotation") { $0.rotation = $0.rotation.setting(v, at: store.time) } }
                    }
                }
                Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        NumberField("Orbit X", cam.orbitX.value(at: t), unit: "°", digits: 1) { v in edit("Camera Orbit") { $0.orbitX = $0.orbitX.setting(v, at: store.time) } }
                        NumberField("Orbit Y", cam.orbitY.value(at: t), unit: "°", digits: 1) { v in edit("Camera Orbit") { $0.orbitY = $0.orbitY.setting(v, at: store.time) } }
                    }
                    GridRow {
                        let lens = cam.lens?.value(at: t) ?? s.defaultLens
                        NumberField("Dist.", cam.distance?.value(at: t) ?? lens, unit: cam.distance == nil ? "auto" : "px", digits: 0) { v in
                            edit("Camera Distance") { $0.distance = ($0.distance ?? .constant(lens)).setting(v, at: store.time) }
                        }
                        NumberField("Lens", lens, unit: cam.lens == nil ? "auto" : "px", digits: 0) { v in
                            edit("Camera Lens") { $0.lens = ($0.lens ?? .constant(lens)).setting(max(1, v), at: store.time) }
                        }
                    }
                    GridRow {
                        NumberField("Z", cam.z.value(at: t), digits: 0) { v in edit("Camera Z") { $0.z = $0.z.setting(v, at: store.time) } }
                            .help("Depth of the point the camera looks at: raise it to fly forward through 3D layers")
                        Color.clear.frame(height: 1)
                    }
                }
                .help("3D layers only: orbit turns the camera around the point it looks at (Y right, X up), distance moves it closer or farther, lens = focal length in px (longer = flatter)")
                let tracks3D = [cam.z, cam.orbitX, cam.orbitY] + [cam.distance, cam.lens].compactMap { $0 }
                let animated = ([cam.x, cam.y, cam.zoom, cam.rotation] + tracks3D).filter(\.isAnimated).count
                HStack {
                    Text(animated > 0 ? "\(animated) animated track\(animated == 1 ? "" : "s")" : "Not animated")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(animated > 0 ? "Clear keys" : "Animate from here") {
                        edit(animated > 0 ? "Clear Camera Keys" : "Animate Camera") { c in
                            if animated > 0 {
                                c.x = .constant(c.x.value(at: t)); c.y = .constant(c.y.value(at: t))
                                c.zoom = .constant(c.zoom.value(at: t)); c.rotation = .constant(c.rotation.value(at: t))
                                c.z = .constant(c.z.value(at: t))
                                c.orbitX = .constant(c.orbitX.value(at: t)); c.orbitY = .constant(c.orbitY.value(at: t))
                                c.distance = c.distance.map { .constant($0.value(at: t)) }
                                c.lens = c.lens.map { .constant($0.value(at: t)) }
                            } else {
                                c.x = .keyframes([MotionKeyframe(t: store.time, v: c.x.value(at: t))])
                                c.y = .keyframes([MotionKeyframe(t: store.time, v: c.y.value(at: t))])
                                c.zoom = .keyframes([MotionKeyframe(t: store.time, v: c.zoom.value(at: t))])
                            }
                        }
                    }
                    .controlSize(.small)
                }
                .help("With keys, each change adds a keyframe at the playhead (move the playhead, change a value)")
                Toggle("Handheld shake", isOn: Binding(get: { !cam.wiggle.isEmpty }, set: { on in
                    edit(on ? "Camera Shake" : "Remove Camera Shake") { c in
                        c.wiggle = on ? ["x": Wiggle(amount: 8, frequency: 1.2), "y": Wiggle(amount: 6, frequency: 1.5, seed: 1),
                                         "rotation": Wiggle(amount: 0.6, frequency: 0.8, seed: 2)] : [:]
                    }
                }))
                .toggleStyle(.checkbox).controlSize(.small)
                Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        NumberField("Focus", cam.focus.value(at: t), digits: 2) { v in edit("Camera Focus") { $0.focus = $0.focus.setting(v, at: store.time) } }
                        NumberField("Aperture", cam.aperture.value(at: t), unit: "px", digits: 1) { v in
                            edit("Camera Aperture") { $0.aperture = $0.aperture.setting(max(0, v), at: store.time) }
                        }
                    }
                }
                .help("Depth of field: layers whose depth differs from Focus blur by Aperture px per unit (0 = off)")
            }
        }
    }

    private func edit(_ label: String, _ body: @escaping (inout Camera) -> Void) {
        store.editScene(label) { s in if s.camera != nil { body(&s.camera!) } }
    }
}

/// Settings of a generator layer (spectrum, waveform, noise, lightning, grid).
struct GeneratorEditor: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        let g = layer.generator
        HStack(spacing: 6) {
            RowLabel("Kind")
            Picker("", selection: Binding(get: { g.kind }, set: { v in edit(id, "Generator") { $0.kind = v } })) {
                ForEach(GeneratorKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                AnimField(layer: layer, property: .width, label: "W")
                AnimField(layer: layer, property: .height, label: "H")
            }
            switch g.kind {
            case .spectrum, .waveform:
                GridRow {
                    NumberField(g.shapeValue == .line ? "Points" : "Bars", Double(g.countValue), digits: 0) { v in
                        edit(id, "Generator") { $0.count = min(max(Int(v), 1), 512) }
                    }
                    NumberField("Gain", g.gainValue, unit: "×") { v in edit(id, "Generator") { $0.gain = max(0, v) } }
                }
                GridRow {
                    if g.shapeValue == .line {
                        AnimField(layer: layer, property: .strokeWidth, label: "Line")
                    } else {
                        AnimField(layer: layer, property: .cornerRadius, label: "Radius")
                    }
                    if g.kind == .waveform {
                        NumberField("Window", g.windowValue, unit: "s") { v in edit(id, "Generator") { $0.window = max(0.1, v) } }
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            case .noise:
                GridRow {
                    NumberField("Size", g.scaleValue, digits: 0) { v in edit(id, "Generator") { $0.scale = max(1, v) } }
                    NumberField("Detail", Double(g.detailValue), digits: 0) { v in
                        edit(id, "Generator") { $0.detail = min(max(Int(v), 1), 8) }
                    }
                }
                GridRow {
                    NumberField("Evolve", g.speedValue, unit: "/s") { v in edit(id, "Generator") { $0.speed = v } }
                    NumberField("Seed", Double(g.seedValue), digits: 0) { v in edit(id, "Generator") { $0.seed = Int(v) } }
                }
            case .lightning:
                GridRow {
                    NumberField("Strikes", g.speedValue, unit: "/s") { v in edit(id, "Generator") { $0.speed = max(0, v) } }
                    NumberField("Branches", Double(g.detailValue), digits: 0) { v in
                        edit(id, "Generator") { $0.detail = min(max(Int(v), 0), 8) }
                    }
                }
                GridRow {
                    AnimField(layer: layer, property: .strokeWidth, label: "Width")
                    NumberField("Seed", Double(g.seedValue), digits: 0) { v in edit(id, "Generator") { $0.seed = Int(v) } }
                }
            case .grid:
                GridRow {
                    NumberField("Cell", g.scaleValue, digits: 0) { v in edit(id, "Generator") { $0.scale = max(2, v) } }
                    NumberField("Scroll", g.speedValue, unit: "px/s", digits: 0) { v in edit(id, "Generator") { $0.speed = v } }
                }
                GridRow {
                    AnimField(layer: layer, property: .strokeWidth, label: "Line")
                    Color.clear.frame(height: 1)
                }
            case .chart:
                GridRow {
                    Picker("", selection: Binding(get: { g.chartValue }, set: { v in edit(id, "Chart Type") { $0.chart = v } })) {
                        ForEach(ChartType.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().controlSize(.small)
                    AnimField(layer: layer, property: .reveal, label: "Grow")
                }
                GridRow {
                    AnimField(layer: layer, property: .cornerRadius, label: "Radius")
                    AnimField(layer: layer, property: .strokeWidth, label: "Line")
                }
                GridRow {
                    NumberField("Font", layer.fontSize, digits: 0) { v in store.updateLayer(id) { $0.fontSize = max(1, v) } }
                    Color.clear.frame(height: 1)
                }
            case .flare:
                GridRow {
                    NumberField("Size", g.scale ?? 0, unit: g.scale == nil ? "auto" : "px", digits: 0) { v in
                        edit(id, "Generator") { $0.scale = v > 0 ? v : nil }
                    }
                    NumberField("Bright", g.gainValue, unit: "×") { v in edit(id, "Generator") { $0.gain = max(0, v) } }
                }
                GridRow {
                    NumberField("Light X", g.from?.x ?? 0, digits: 0) { v in edit(id, "Generator") { $0.from = PathPoint(x: v, y: $0.from?.y ?? 0) } }
                    NumberField("Light Y", g.from?.y ?? 0, digits: 0) { v in edit(id, "Generator") { $0.from = PathPoint(x: $0.from?.x ?? 0, y: v) } }
                }
                GridRow {
                    NumberField("Ghosts", Double(g.detail ?? 5), digits: 0) { v in edit(id, "Generator") { $0.detail = min(max(Int(v), 0), 12) } }
                    NumberField("Seed", Double(g.seedValue), digits: 0) { v in edit(id, "Generator") { $0.seed = Int(v) } }
                }
            }
            if g.kind == .chart {
                CommitTextField(placeholder: "12, 30, 18, 42", value: g.valuesValue.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }.joined(separator: ", "),
                                font: .system(.caption, design: .monospaced)) { v in
                    let nums = v.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
                    edit(id, "Chart Values") { $0.values = nums.isEmpty ? nil : nums }
                }
                .padding(7).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                .help("Values, comma separated")
                CommitTextField(placeholder: "Labels: Q1, Q2, Q3", value: (g.labels ?? []).joined(separator: ", "),
                                font: .system(.caption, design: .monospaced)) { v in
                    let items = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    edit(id, "Chart Labels") { $0.labels = items.isEmpty ? nil : items }
                }
                .padding(7).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                AnimColorField(layer: layer, property: .color, label: "Labels")
            }
        }
        if g.usesAudio {
            let audio = store.scene.audioLayers
            HStack(spacing: 6) {
                RowLabel("Audio")
                Picker("", selection: Binding(get: { g.source ?? "" }, set: { v in
                    edit(id, "Generator Source") { $0.source = v.isEmpty ? nil : v }
                })) {
                    Text("Music (auto)").tag("")
                    ForEach(audio) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            HStack(spacing: 6) {
                RowLabel("Shape")
                Picker("", selection: Binding(get: { g.shapeValue }, set: { v in edit(id, "Generator") { $0.shape = v } })) {
                    ForEach(GeneratorShape.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            if g.shapeValue != .circle {
                Toggle("Mirror (grow from the middle)", isOn: Binding(get: { g.mirrorValue }, set: { v in
                    edit(id, "Generator") { $0.mirror = v }
                }))
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
            if audio.isEmpty {
                Text("Add an audio layer: the visualizer follows it.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if g.kind == .noise || g.kind == .flare || g.kind == .chart {
            let colors = g.kind == .flare ? (g.colors ?? [.white, RGBA(r: 0.6, g: 0.8, b: 1)]) : g.colorsValue
            ForEach(Array(colors.enumerated()), id: \.offset) { i, c in
                let label = g.kind == .chart ? "Series \(i + 1)" : g.kind == .flare ? (i == 0 ? "Core" : "Ghosts")
                    : (i == 0 ? "Low" : i == colors.count - 1 ? "High" : "Mid")
                ColorField(label, c) { nc in
                    edit(id, "Generator Color") { gen in
                        var list = colors
                        list[i] = nc
                        gen.colors = list
                    }
                }
            }
            if g.kind == .chart {
                HStack {
                    Button("Add color") { edit(id, "Generator Color") { $0.colors = colors + [RGBA(hex: "#60A5FA")!] } }
                    if colors.count > 1 { Button("Remove last") { edit(id, "Generator Color") { $0.colors = Array(colors.dropLast()) } } }
                }
                .controlSize(.small)
            }
        } else {
            AnimColorField(layer: layer, property: .fill, label: "Color")
            GradientRows(layer: layer)
        }
    }

    private func edit(_ id: String, _ label: String, _ change: @escaping (inout Generator) -> Void) {
        store.updateLayer(id, label) { change(&$0.generator) }
    }
}

/// Pixelate, posterize, RGB split, glitch, grain, scanlines, vignette, directional/zoom blur and posterize time.
struct StylizeSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        InspectorSection("Stylize") {
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    AnimField(layer: layer, property: .pixelate, label: "Pixelate")
                    AnimField(layer: layer, property: .posterize, label: "Levels")
                        .help("Posterize: number of color levels (0 = off, 2–8 for a poster look)")
                }
                GridRow {
                    AnimField(layer: layer, property: .rgbSplit, label: "RGB split")
                    AnimField(layer: layer, property: .directionalBlur, label: "Dir. blur")
                }
                GridRow {
                    AnimField(layer: layer, property: .blurAngle, label: "Blur angle", unit: "°")
                    NumberField("Step fps", layer.posterizeTime ?? 0, digits: 0) { v in
                        store.updateLayer(id, "Posterize Time") { $0.posterizeTime = v > 0 ? v : nil }
                    }
                    .help("Posterize time: the layer only updates this many times a second (0 = off)")
                }
            }
            AnimSlider(layer: layer, property: .zoomBlur, label: "Zoom blur", range: 0...0.9)
            AnimSlider(layer: layer, property: .glitch, label: "Glitch")
            AnimSlider(layer: layer, property: .grain, label: "Grain")
            AnimSlider(layer: layer, property: .scanlines, label: "Scanlines")
            AnimSlider(layer: layer, property: .vignette, label: "Vignette")
        }
    }
}

/// Wave warp, ripple, twirl, bulge and turbulent displacement around the layer's position.
struct DistortSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let t = store.panelTime
        InspectorSection("Distort") {
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    AnimField(layer: layer, property: .waveWarp, label: "Wave")
                    AnimField(layer: layer, property: .ripple, label: "Ripple")
                }
                GridRow {
                    AnimField(layer: layer, property: .turbulence, label: "Turbulence")
                    AnimField(layer: layer, property: .twirl, label: "Twirl", unit: "°")
                }
                if [.waveWarp, .ripple, .turbulence].contains(where: { layer.value($0, at: t) != 0 || layer[$0].isAnimated }) {
                    GridRow {
                        AnimField(layer: layer, property: .waveLength, label: "Length")
                        AnimField(layer: layer, property: .waveSpeed, label: "Speed")
                    }
                }
                if [.twirl, .bulge].contains(where: { layer.value($0, at: t) != 0 || layer[$0].isAnimated }) {
                    GridRow {
                        AnimField(layer: layer, property: .distortRadius, label: "Radius")
                        Color.clear.frame(height: 1)
                    }
                }
            }
            AnimSlider(layer: layer, property: .bulge, label: "Bulge", range: -1...1)
        }
    }
}

/// Green/blue screen keying.
struct KeyingSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        InspectorSection("Keying") {
            Toggle("Key out a color", isOn: Binding(get: { layer.keyColor != nil }, set: { on in
                store.updateLayer(id, "Keying") { $0.keyColor = on ? RGBA(hex: "#00B140") : nil }
            }))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Removes a green or blue screen (or any color) from the layer")
            if let key = layer.keyColor {
                ColorField("Key", key) { c in store.updateLayer(id, "Key Color") { $0.keyColor = c } }
                AnimSlider(layer: layer, property: .keyTolerance, label: "Tolerance")
                AnimSlider(layer: layer, property: .keySoftness, label: "Softness")
            }
        }
    }
}

/// Font family of a text layer, picked from installed and asset-library fonts.
struct FontFamilyRow: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer
    @State private var showList = false

    var body: some View {
        let name = layer.fontName.flatMap { $0.isEmpty ? nil : $0 }
        HStack(spacing: 6) {
            RowLabel("Font")
            Button { showList.toggle() } label: {
                HStack {
                    Text(name ?? "System").lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fieldBackground()
            .popover(isPresented: $showList, arrowEdge: .leading) {
                FontListPopover(current: name) { family in
                    store.updateLayer(layer.id, "Change Font") { $0.fontName = family }
                    showList = false
                }
            }
        }
        .help("Fonts installed on this Mac and font files in the asset library. Get more in Free Assets → Fonts.")
        if let name, FontLibrary.resolve(name, weight: layer.fontWeight) == nil {
            Text("“\(name)” is not installed: the system font is used.")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

private struct FontListPopover: View {
    let current: String?
    let onPick: (String?) -> Void
    @State private var query = ""
    @State private var families: [String] = []
    @State private var library: Set<String> = []

    var body: some View {
        let q = query.lowercased()
        let shown = families.filter { q.isEmpty || $0.lowercased().contains(q) }
        VStack(spacing: 0) {
            TextField("Search fonts", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List {
                if q.isEmpty { row(nil, title: "System") }
                let lib = shown.filter(library.contains)
                if !lib.isEmpty {
                    Section("Asset library") { ForEach(lib, id: \.self) { row($0, title: $0) } }
                }
                Section("Installed") {
                    ForEach(shown.filter { !library.contains($0) }, id: \.self) { row($0, title: $0) }
                }
            }
        }
        .frame(width: 300, height: 420)
        .task {
            families = FontLibrary.listedFamilies()
            library = Set(FontLibrary.libraryFamilies)
        }
    }

    private func row(_ family: String?, title: String) -> some View {
        Button { onPick(family) } label: {
            HStack {
                Text(title).font(family.map { .custom($0, size: 15) } ?? .system(size: 15)).lineLimit(1)
                Spacer()
                if family == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Track matte: show the layer only through another layer.
struct MatteRow: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let candidates = store.scene.layers.filter { $0.type.isVisual && $0.id != layer.id }
        HStack(spacing: 6) {
            RowLabel("Matte")
            Picker("", selection: Binding(get: { layer.matte?.source ?? "" }, set: { v in
                store.updateLayer(layer.id, "Track Matte") { l in
                    l.matte = v.isEmpty ? nil : Matte(source: v, mode: l.matte?.mode ?? .alpha)
                }
            })) {
                Text("None").tag("")
                ForEach(candidates.reversed()) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .controlSize(.small)
            if let m = layer.matte {
                Picker("", selection: Binding(get: { m.mode }, set: { v in
                    store.updateLayer(layer.id, "Matte Mode") { $0.matte?.mode = v }
                })) {
                    ForEach(MatteMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
        }
        .help("Show this layer only where the matte layer is (alpha) or is bright (luma). The matte layer itself is hidden.")
    }
}

/// Trim paths: the drawn part of the stroke.
struct StrokeTrimRows: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        AnimSlider(layer: layer, property: .trimStart, label: "Trim start")
        AnimSlider(layer: layer, property: .trim, label: "Trim end")
            .help("Part of the stroke that is drawn (animate end 0 → 100% to draw the outline)")
        AnimSlider(layer: layer, property: .trimOffset, label: "Offset")
            .help("Slides the drawn part along the outline (100% = one lap)")
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                CommitTextField(placeholder: "Dash: 24, 12", value: layer.dash.map { String(Int($0)) }.joined(separator: ", "),
                                font: .system(.caption, design: .monospaced)) { v in
                    let nums = v.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
                    store.updateLayer(id, "Dash") { $0.dash = nums }
                }
                .padding(.horizontal, 7).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                .help("Dash pattern in px (on, off, …); empty = solid")
                if layer.dash.isEmpty { Color.clear.frame(height: 1) } else { AnimField(layer: layer, property: .dashOffset, label: "Phase") }
            }
            GridRow {
                AnimField(layer: layer, property: .taperStart, label: "Taper in")
                AnimField(layer: layer, property: .taperEnd, label: "Taper out")
            }
            if layer.type == .path {
                GridRow {
                    Toggle("Trim pieces in order", isOn: Binding(get: { layer.trimSequential }, set: { v in
                        store.updateLayer(id, "Trim Order") { $0.trimSequential = v }
                    }))
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("Trim runs through the pieces one after another (handwriting) instead of all at once")
                    .gridCellColumns(2)
                }
            }
            GridRow {
                AnimField(layer: layer, property: .offsetPath, label: "Offset")
                AnimField(layer: layer, property: .zigzag, label: "Zigzag")
            }
            GridRow {
                AnimField(layer: layer, property: .wigglePath, label: "Wiggle")
                AnimField(layer: layer, property: .pucker, label: "Pucker")
            }
            if layer.value(.zigzag, at: store.panelTime) != 0 || layer.value(.wigglePath, at: store.panelTime) != 0 {
                GridRow {
                    AnimField(layer: layer, property: .waveLength, label: "Spacing")
                    AnimField(layer: layer, property: .waveSpeed, label: "Speed")
                }
            }
        }
    }
}

/// Shine sweep, light rays, outline and inner glow.
struct LightRows: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        let t = store.panelTime
        AnimSlider(layer: layer, property: .shine, label: "Shine", range: 0...2)
            .help("A soft bright band across the layer; animate Position 0 → 1 to sweep it")
        if layer.value(.shine, at: t) > 0 || layer[.shine].isAnimated {
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    AnimField(layer: layer, property: .shinePosition, label: "Position")
                    AnimField(layer: layer, property: .shineAngle, label: "Angle", unit: "°")
                }
                GridRow {
                    AnimField(layer: layer, property: .shineWidth, label: "Width")
                    Color.clear.frame(height: 1)
                }
            }
            ColorField("Shine", layer.shineColor ?? RGBA(r: 1, g: 1, b: 1, a: 0.8)) { c in store.updateLayer(id, "Shine Color") { $0.shineColor = c } }
        }
        AnimSlider(layer: layer, property: .rays, label: "Light rays", range: 0...3)
            .help("Rays streaking out of the layer's bright parts")
        if layer.value(.rays, at: t) > 0 || layer[.rays].isAnimated {
            AnimSlider(layer: layer, property: .raysLength, label: "Length", range: 0...0.95)
        }
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                AnimField(layer: layer, property: .outline, label: "Outline")
                AnimField(layer: layer, property: .innerGlowRadius, label: "Inner r.")
            }
        }
        if layer.value(.outline, at: t) > 0 || layer[.outline].isAnimated {
            ColorField("Outline", layer.outlineColor ?? .white) { c in store.updateLayer(id, "Outline Color") { $0.outlineColor = c } }
        }
        AnimSlider(layer: layer, property: .innerGlow, label: "Inner glow", range: 0...2)
        if layer.value(.innerGlow, at: t) > 0 || layer[.innerGlow].isAnimated {
            ColorField("Inner", layer.innerGlowColor ?? .white) { c in store.updateLayer(id, "Inner Glow Color") { $0.innerGlowColor = c } }
        }
    }
}

/// Linear/radial gradient replacing the solid fill or text color.
struct GradientRows: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        if let g = layer.gradient {
            HStack(spacing: 6) {
                RowLabel("Gradient")
                Picker("", selection: Binding(get: { g.type }, set: { v in
                    store.updateLayer(id, "Gradient Type") { $0.gradient?.type = v }
                })) {
                    Text("Linear").tag(GradientType.linear)
                    Text("Radial").tag(GradientType.radial)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Button { store.updateLayer(id, "Remove Gradient") { $0.gradient = nil } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Back to a solid color")
            }
            ForEach(Array(g.stops.enumerated()), id: \.offset) { i, stop in
                ColorField(i == 0 ? "From" : i == g.stops.count - 1 ? "To" : "Via", stop.color) { c in
                    store.updateLayer(id, "Gradient Color") { $0.gradient?.stops[i].color = c }
                }
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    if g.type == .linear {
                        NumberField("Angle", g.angle.value(at: store.panelTime), unit: "°", digits: 0) { v in
                            store.updateLayer(id, "Gradient Angle") { $0.gradient?.angle = .constant(v) }
                        }
                    } else {
                        NumberField("Radius", g.radius.value(at: store.panelTime) * 100, unit: "%", digits: 0) { v in
                            store.updateLayer(id, "Gradient Radius") { $0.gradient?.radius = .constant(max(v, 1) / 100) }
                        }
                    }
                    NumberField("Shift", g.shift.value(at: store.panelTime) * 100, unit: "%", digits: 0) { v in
                        store.updateLayer(id, "Gradient Shift") { $0.gradient?.shift = .constant(v / 100) }
                    }
                }
            }
        } else {
            Button("Add Gradient") {
                store.updateLayer(id, "Add Gradient") { l in
                    let base = (l.type == .text ? l.color : l.fill).value(at: store.time)
                    let end = RGBA(r: base.r * 0.45, g: base.g * 0.45, b: base.b * 0.75, a: base.a)
                    l.gradient = Gradient(stops: [GradientStop(offset: 0, color: base), GradientStop(offset: 1, color: end)])
                }
            }
            .controlSize(.small)
        }
    }
}

/// A path layer's shape as SVG path data or a shorthand; keyframed shapes (morphs) are edited as JSON or by Claude.
struct PathShapeField: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        if layer.d.isAnimated {
            HStack {
                Image(systemName: "wand.and.stars").foregroundStyle(.secondary)
                Text("Morph · \(layer.d.keyframeList.count) shapes").font(.callout)
                Spacer()
            }
            .help("The shape morphs between keyframes. Edit the shapes in JSON or ask Claude.")
        } else {
            CommitTextField(placeholder: "M0 0 L100 0 … or star(5,160,70)", value: layer.pathShape(at: 0).description,
                            font: .system(.caption, design: .monospaced)) { v in
                do {
                    let shape = try PathShape(v)
                    store.updateLayer(layer.id, "Edit Path") { $0.d = .constant(shape) }
                } catch {
                    store.message = "Path: \(error.localizedDescription)"
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            .help("SVG path data around the layer's position, or star(points,outer,inner), polygon(sides,r), circle(r), ellipse(rx,ry), rect(w,h,r)")
        }
    }
}

/// Stepped copies of the layer (rings, rows, spirals, echo trails).
struct RepeaterSection: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        let t = store.panelTime
        InspectorSection("Repeater") {
            if let r = layer.repeater {
                Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        NumberField("Copies", Double(r.count), digits: 0) { v in
                            store.updateLayer(id, "Repeater") { $0.repeater?.count = min(max(Int(v), 1), Repeater.maxCount) }
                        }
                        NumberField("Delay", r.delay, unit: "s") { v in store.updateLayer(id, "Repeater") { $0.repeater?.delay = v } }
                    }
                    GridRow {
                        NumberField("Step X", r.x.value(at: t), digits: 0) { v in store.updateLayer(id, "Repeater") { $0.repeater?.x = .constant(v) } }
                        NumberField("Step Y", r.y.value(at: t), digits: 0) { v in store.updateLayer(id, "Repeater") { $0.repeater?.y = .constant(v) } }
                    }
                    GridRow {
                        NumberField("Rotate", r.rotation.value(at: t), unit: "°") { v in
                            store.updateLayer(id, "Repeater") { $0.repeater?.rotation = .constant(v) }
                        }
                        NumberField("Scale", r.scale.value(at: t), unit: "×") { v in
                            store.updateLayer(id, "Repeater") { $0.repeater?.scale = .constant(v) }
                        }
                    }
                    GridRow {
                        NumberField("Pivot X", r.pivotX, digits: 0) { v in store.updateLayer(id, "Repeater") { $0.repeater?.pivotX = v } }
                        NumberField("Pivot Y", r.pivotY, digits: 0) { v in store.updateLayer(id, "Repeater") { $0.repeater?.pivotY = v } }
                    }
                    GridRow {
                        NumberField("End opacity", r.opacityEnd * 100, unit: "%", digits: 0) { v in
                            store.updateLayer(id, "Repeater") { $0.repeater?.opacityEnd = min(max(v / 100, 0), 1) }
                        }
                        Button("Remove") { store.updateLayer(id, "Remove Repeater") { $0.repeater = nil } }
                            .controlSize(.small)
                    }
                }
            } else {
                Button("Add Repeater") {
                    store.updateLayer(id, "Add Repeater") { l in
                        var r = Repeater(count: 5)
                        r.x = .constant(80)
                        r.opacityEnd = 0.3
                        l.repeater = r
                    }
                }
                .controlSize(.small)
                .help("Draw stepped copies: rows, rings (rotation + pivot), spirals, cascades (delay)")
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
                        GridRow {
                            NumberField("Blur", a.blur, digits: 0) { v in edit(i) { $0.blur = max(0, v) } }
                            Toggle("Color", isOn: Binding(get: { a.color != nil }, set: { on in
                                edit(i) { $0.color = on ? RGBA(hex: "#FF3B6B") : nil }
                            }))
                            .toggleStyle(.checkbox).controlSize(.small)
                        }
                    }
                    if let c = a.color {
                        ColorField("Away color", c) { nc in edit(i) { $0.color = nc } }
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
                let assets = AssetLibrary.shared.assets.filter { $0.kind == kind && (kind != .other || $0.name.lowercased().hasSuffix(".cube")) }
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
                    case .other: panel.allowedContentTypes = [.data] // .cube LUTs
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

/// Settings of a 3D object: its shape and size, how deep it is, and its material.
struct ModelEditor: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let id = layer.id
        let m = layer.model
        HStack(spacing: 6) {
            RowLabel("Shape")
            Picker("", selection: Binding(get: { m.shape }, set: { v in
                store.updateLayer(id, "3D Shape") { l in
                    l.model.shape = v
                    if v == .text, l.text.isEmpty { l.text = "3D" }
                }
            })) {
                ForEach(ModelShape.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden().controlSize(.small)
        }
        switch m.shape {
        case .text:
            TextField("Text", text: Binding(get: { layer.text }, set: { v in store.updateLayer(id, "Edit Text") { $0.text = v } }),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            FontFamilyRow(layer: layer)
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    NumberField("Size", layer.fontSize, digits: 0) { v in store.updateLayer(id) { $0.fontSize = max(1, v) } }
                    Picker("", selection: Binding(get: { layer.fontWeight }, set: { v in store.updateLayer(id) { $0.fontWeight = v } })) {
                        ForEach(["thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"], id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }
                    .labelsHidden().controlSize(.small)
                }
            }
        case .path, .lathe:
            PathShapeField(layer: layer)
            if m.shape == .lathe {
                Text("The right half of the outline: x is the distance from the axis through the layer's center.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .file:
            ModelFileRow(path: layer.path) { p in store.updateLayer(id, "Change Model") { $0.path = p } }
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    AnimField(layer: layer, property: .width, label: "Size")
                    Color.clear.frame(height: 1)
                }
            }
            .help("The model is scaled so its largest side is this many px")
            let clips = layer.modelAnimations
            if !clips.isEmpty { ModelAnimationRows(layer: layer, clips: clips) }
        default:
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    AnimField(layer: layer, property: .width, label: "W")
                    AnimField(layer: layer, property: .height, label: "H")
                }
            }
        }
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                if m.shape != .plane && m.shape != .file && m.shape != .torus && m.shape != .lathe {
                    NumberField("Depth", m.depth ?? 0, unit: m.depth == nil ? "auto" : "px", digits: 0) { v in
                        store.updateLayer(id, "3D Depth") { $0.model.depth = v > 0 ? v : nil }
                    }
                    .help("Box depth, extrusion depth (text, path), or the size front to back (sphere, cylinder); 0 = automatic")
                } else {
                    Color.clear.frame(height: 1)
                }
                if [.sphere, .cylinder, .cone, .torus, .lathe].contains(m.shape) {
                    NumberField("Segments", Double(m.segmentCount), digits: 0) { v in
                        store.updateLayer(id, "3D Segments") { $0.model.segments = min(max(Int(v), 3), 256) }
                    }
                    .help("Roundness: fewer segments give a faceted, low-poly look")
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            if m.shape.isExtruded {
                GridRow {
                    NumberField("Bevel", m.bevelValue, unit: "px", digits: 0) { v in
                        store.updateLayer(id, "3D Bevel") { $0.model.bevel = v > 0 ? v : nil }
                    }
                    .help("Rounded edges, in px (kept within half the depth and the thinnest stroke)")
                    NumberField("Steps", Double(m.bevelStepCount), digits: 0) { v in
                        store.updateLayer(id, "3D Bevel Steps") { $0.model.bevelSteps = min(max(Int(v), 1), 12) }
                    }
                    .help("Steps around the bevel: 1 = a flat chamfer, more = rounder")
                }
            }
            if m.shape == .torus || m.shape == .cone {
                GridRow {
                    NumberField(m.shape == .torus ? "Tube" : "Top", m.radius ?? (m.shape == .torus ? 0.3 : 0)) { v in
                        store.updateLayer(id, "3D Radius") { $0.model.radius = min(max(v, 0), 1) }
                    }
                    .help(m.shape == .torus ? "Tube thickness as a fraction of the radius" : "Top radius as a fraction of the bottom one")
                    Color.clear.frame(height: 1)
                }
            }
            GridRow {
                NumberField("Gloss", m.shininessValue) { v in store.updateLayer(id, "3D Gloss") { $0.model.shininess = min(max(v, 0), 1) } }
                    .help("0 = matte … 1 = glossy highlights")
                NumberField("Metal", m.metallicValue) { v in store.updateLayer(id, "3D Metal") { $0.model.metallic = min(max(v, 0), 1) } }
                    .help("0 = plastic … 1 = metal (reflects its own color)")
            }
        }
        AnimColorField(layer: layer, property: .fill, label: "Color")
        HStack(spacing: 6) {
            Toggle("Sides", isOn: Binding(get: { m.sideColor != nil }, set: { on in
                store.updateLayer(id, "3D Side Color") { l in
                    l.model.sideColor = on ? (l.color(.fill, at: store.time) ?? .white).darkened : nil
                }
            }))
            .toggleStyle(.checkbox).controlSize(.small)
            .help("A color of its own for the extrusion walls, box sides and cylinder caps")
            if let side = m.sideColor {
                ColorField("", side) { c in store.updateLayer(id, "3D Side Color") { $0.model.sideColor = c } }
            }
        }
        if m.shape.isTexturable {
            HStack(spacing: 6) {
                FileRow(path: layer.path, kind: .image) { p in store.updateLayer(id, "3D Texture") { $0.path = p } }
                if layer.path != nil {
                    Button("Remove") { store.updateLayer(id, "Remove Texture") { $0.path = nil } }.controlSize(.small)
                }
            }
            .help("An image painted on the object (a planet map on a sphere, a label around a cylinder)")
        }
        Text("Lights: the scene's lights (update_scene \"lights\"), or a soft default rig.")
            .font(.caption2).foregroundStyle(.tertiary)
    }
}

/// The clip an animated model file plays, and its timing.
struct ModelAnimationRows: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer
    let clips: [ModelAnimation]

    var body: some View {
        let id = layer.id
        let m = layer.model
        let names = clips.map(\.name)
        HStack(spacing: 6) {
            RowLabel("Animation")
            Picker("", selection: Binding<Int>(get: { m.clipIndex(in: names) ?? -1 }, set: { pick($0, names) })) {
                Text("None (rest pose)").tag(-1)
                ForEach(clips.indices, id: \.self) { (i: Int) in
                    Text(label(clips[i])).tag(i)
                }
            }
            .labelsHidden().controlSize(.small)
        }
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                NumberField("Speed", m.animationSpeed ?? 1) { v in
                    store.updateLayer(id, "Animation Speed") { $0.model.animationSpeed = v == 1 ? nil : v }
                }
                .help("Playback rate of the clip (negative plays it backwards)")
                NumberField("Offset", m.animationOffset ?? 0, unit: "s") { v in
                    store.updateLayer(id, "Animation Offset") { $0.model.animationOffset = v == 0 ? nil : v }
                }
                .help("Seconds into the clip at the layer's start")
            }
        }
        Toggle("Loop", isOn: Binding(get: { m.animationLoopValue }, set: { on in
            store.updateLayer(id, "Animation Loop") { $0.model.animationLoop = on ? nil : false }
        }))
        .toggleStyle(.checkbox).controlSize(.small)
        .help("Start the clip over when it ends; off holds its last pose")
    }

    private func label(_ clip: ModelAnimation) -> String {
        clip.name + " · " + String(format: "%.1f s", clip.duration)
    }

    private func pick(_ i: Int, _ names: [String]) {
        let value: String
        if i < 0 {
            value = "none"
        } else {
            // Names can repeat: those are kept by number.
            value = names.filter { $0 == names[i] }.count == 1 ? names[i] : String(i)
        }
        store.updateLayer(layer.id, "Model Animation") { $0.model.animation = value }
    }
}

/// A model file: the library's 3D files, or any file on disk.
struct ModelFileRow: View {
    let path: String?
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "cube").foregroundStyle(.secondary)
            Text((path as NSString?)?.lastPathComponent ?? "No file")
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(path == nil ? .secondary : .primary)
                .help(path ?? "")
            Spacer(minLength: 4)
            Menu("Replace") {
                let assets = AssetLibrary.shared.assets.filter {
                    SceneStore.modelExtensions.contains(($0.name as NSString).pathExtension.lowercased())
                }
                if !assets.isEmpty {
                    Section("Assets") {
                        ForEach(assets) { a in Button(a.name) { onPick(a.path) } }
                    }
                }
                Button("Other File…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = SceneStore.modelExtensions.compactMap { UTType(filenameExtension: $0) }
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

private extension RGBA {
    var darkened: RGBA { RGBA(r: r * 0.6, g: g * 0.6, b: b * 0.6, a: a) }
}
