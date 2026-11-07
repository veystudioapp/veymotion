import SwiftUI
import VeyMotionCore

/// Settings of a particle layer (shown in its appearance section).
struct ParticlesEditor: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer

    var body: some View {
        let p = layer.particles
        HStack(spacing: 6) {
            RowLabel("Preset")
            Menu(p.preset?.title ?? "Custom") {
                ForEach(ParticlePreset.allCases, id: \.self) { preset in
                    Button(preset.title) { applyPreset(preset) }
                }
            }
            .controlSize(.small)
            .help("Start over from a preset (moves and sizes the emitter for it)")
            Button { edit("New Seed") { $0.particles.seed += 1 } } label: { Image(systemName: "dice") }
                .buttonStyle(.borderless)
                .help("Another random layout with the same settings")
        }

        group("Emitter")
        picker("Shape", \.emitter, EmitterShape.allCases) { $0.rawValue.capitalized }
        if p.emitter != .point || p.from != nil {
            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    AnimField(layer: layer, property: .width, label: "W")
                    AnimField(layer: layer, property: .height, label: "H")
                }
            }
        }
        sourcePicker
        HStack(spacing: 12) {
            Toggle("Outline only", isOn: bind(\.edge))
            Toggle("Follow layer", isOn: Binding(get: { p.space == .local },
                                                 set: { v in edit("Particle Space") { $0.particles.space = v ? .local : .world } }))
                .help("Particles move with the layer instead of staying where they were born")
                .disabled(p.from != nil)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                number("Rate", \.rate, unit: "/s", digits: 0, min: 0)
                AnimField(layer: layer, property: .emission, label: "Emit ×")
            }
            GridRow {
                number("Life", \.lifetime, unit: "s", min: 0.01)
                number("Life ±", \.lifetimeRandom, max: 1)
            }
            GridRow {
                number("Prewarm", \.prewarm, unit: "s", min: 0)
                    .help("Seconds simulated before the layer starts, so it opens already full")
                Color.clear.frame(height: 1)
            }
        }
        burstRows

        group("Motion")
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                number("Speed", \.speed, digits: 0)
                AnimField(layer: layer, property: .particleSpeed, label: "Speed ×")
            }
            GridRow {
                number("Speed ±", \.speedRandom, max: 1)
                number("Inherit", \.inherit)
                    .help("Share of the emitter's own movement particles keep")
            }
            GridRow {
                number("Direction", \.direction, unit: "°", digits: 0)
                number("Spread", \.spread, unit: "°", digits: 0, min: 0, max: 360)
            }
            GridRow {
                number("Gravity", \.gravity, digits: 0)
                number("Wind", \.wind, digits: 0)
            }
            GridRow {
                number("Drag", \.drag, min: 0)
                number("Swirl", \.turbulence, digits: 0, min: 0)
                    .help("Turbulence: swirling flow, for smoke, fire and dust")
            }
            if p.turbulence > 0 {
                GridRow {
                    number("Swirl size", \.turbulenceScale, digits: 0, min: 1)
                    number("Swirl speed", \.turbulenceSpeed, min: 0)
                }
            }
        }
        HStack(spacing: 6) {
            Toggle("Floor", isOn: Binding(get: { p.floor != nil }, set: { v in
                let y = Double(store.scene.height) * 0.9
                edit("Particle Floor") { $0.particles.floor = v ? y : nil }
            }))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .help("Particles bounce on a horizontal line")
            if let floor = p.floor {
                NumberField("Y", floor, digits: 0) { v in edit("Particle Floor") { $0.particles.floor = v } }
                number("Bounce", \.bounce, max: 1)
            }
        }

        group("Look")
        picker("Particle", \.shape, ParticleShape.allCases) { $0.rawValue.capitalized }
        if p.shape == .image {
            FileRow(path: layer.path, kind: .image) { path in store.updateLayer(layer.id, "Particle Image") { $0.path = path } }
            Toggle("Paint with colors", isOn: bind(\.tint))
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                number("Size", \.size, digits: 1, min: 0)
                AnimField(layer: layer, property: .particleSize, label: "Size ×")
            }
            GridRow {
                number("Size ±", \.sizeRandom, max: 1)
                number("Grow", \.grow, min: 0)
                    .help("Size at the end of life as a multiple of the size at birth")
            }
            GridRow {
                number("Fade in", \.fadeIn, max: 1)
                number("Fade out", \.fadeOut, max: 1)
            }
            GridRow {
                number("Spin", \.spin, unit: "°/s", digits: 0)
                number("Angle ±", \.angleRandom, unit: "°", digits: 0)
            }
            GridRow {
                if p.shape == .spark {
                    number("Streak", \.streak, unit: "s", digits: 3, min: 0)
                    number("Trail", \.trail, unit: "s", digits: 2, min: 0)
                } else {
                    number("Flutter", \.flutter, unit: "/s", min: 0)
                }
                Toggle("Orient", isOn: bind(\.orient))
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Turn each particle to face where it goes")
            }
        }
        colorRows
    }

    // MARK: Parts

    private func group(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary).padding(.top, 4)
    }

    /// Emit from another layer: a text's letters, a shape or an image's frame.
    private var sourcePicker: some View {
        let candidates = store.scene.layers.filter {
            $0.id != layer.id && [.text, .rect, .ellipse, .path, .image, .video].contains($0.type)
        }
        return HStack(spacing: 6) {
            RowLabel("From")
            Picker("", selection: Binding(get: { layer.particles.from ?? "" }, set: { v in
                edit("Emit From") { $0.particles.from = v.isEmpty ? nil : v }
            })) {
                Text("This layer").tag("")
                ForEach(candidates.reversed()) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .help("Emit from another layer's shape: a text's letters, a rect/ellipse, or an image")
    }

    @ViewBuilder private var burstRows: some View {
        let bursts = layer.particles.bursts
        ForEach(bursts.indices, id: \.self) { i in
            HStack(spacing: 6) {
                Text("Burst").font(.caption).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                NumberField("At", bursts[i].t, unit: "s") { v in
                    edit("Burst") { if $0.particles.bursts.indices.contains(i) { $0.particles.bursts[i].t = max(0, v) } }
                }
                NumberField("Count", Double(bursts[i].count), digits: 0) { v in
                    edit("Burst") {
                        if $0.particles.bursts.indices.contains(i) { $0.particles.bursts[i].count = max(0, Int(v)) }
                    }
                }
                Button { edit("Remove Burst") { $0.particles.bursts.remove(at: i) } } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        Button("Add Burst at Playhead") {
            let t = store.time
            edit("Add Burst") { $0.particles.bursts.append(ParticleBurst(t: t, count: 200)) }
        }
        .controlSize(.small)
        .help("Many particles at one moment (explosions, text breaking apart)")
    }

    @ViewBuilder private var colorRows: some View {
        let colors = layer.particles.colors
        HStack(spacing: 6) {
            RowLabel("Colors")
            Picker("", selection: bind(\.colorMode)) {
                Text("Over life").tag(ParticleColorMode.life)
                Text("Random").tag(ParticleColorMode.random)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        ForEach(colors.indices, id: \.self) { i in
            HStack(spacing: 4) {
                ColorField("\(i + 1)", colors[i]) { c in
                    edit("Particle Color") { if $0.particles.colors.indices.contains(i) { $0.particles.colors[i] = c } }
                }
                if colors.count > 1 {
                    Button { edit("Remove Color") { $0.particles.colors.remove(at: i) } } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        Button("Add Color") { edit("Add Color") { $0.particles.colors.append(colors.last ?? .white) } }
            .controlSize(.small)
    }

    // MARK: Helpers

    private func number(_ label: String, _ kp: WritableKeyPath<ParticleSystem, Double>, unit: String? = nil,
                        digits: Int = 2, min lo: Double = -.infinity, max hi: Double = .infinity) -> some View {
        NumberField(label, layer.particles[keyPath: kp], unit: unit, digits: digits) { v in
            edit("Particles") { $0.particles[keyPath: kp] = Swift.min(Swift.max(v, lo), hi) }
        }
    }

    private func picker<V: Hashable>(_ label: String, _ kp: WritableKeyPath<ParticleSystem, V>, _ values: [V],
                                     title: @escaping (V) -> String) -> some View {
        HStack(spacing: 6) {
            RowLabel(label)
            Picker("", selection: bind(kp)) {
                ForEach(values, id: \.self) { Text(title($0)).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func bind<V>(_ kp: WritableKeyPath<ParticleSystem, V>) -> Binding<V> {
        Binding(get: { layer.particles[keyPath: kp] }, set: { v in edit("Particles") { $0.particles[keyPath: kp] = v } })
    }

    private func edit(_ label: String, _ body: (inout MotionLayer) -> Void) {
        store.updateLayer(layer.id, label, body)
    }

    /// Replaces the settings with a preset's and places the emitter for it (unless its position is animated).
    private func applyPreset(_ preset: ParticlePreset) {
        let template = MotionLayer.makeParticles(preset, sceneWidth: store.scene.width, sceneHeight: store.scene.height)
        edit("Particle Preset") { l in
            let seed = l.particles.seed
            l.particles = template.particles
            l.particles.seed = seed
            l.blendMode = template.blendMode
            l.width = template.width
            l.height = template.height
            l[.blur] = template[.blur]
            if !l.x.isAnimated && !l.y.isAnimated && l.motionPath == nil && l.parent == nil { l.x = template.x; l.y = template.y }
        }
    }
}
