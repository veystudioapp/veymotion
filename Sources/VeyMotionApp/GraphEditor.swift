import AppKit
import SwiftUI
import VeyMotionCore

/// Curve colors, by position in the layer's list of keyframed numbers.
enum GraphPalette {
    static let colors: [Color] = [.red, .green, .blue, .orange, .purple, .pink, .teal, .yellow, .mint, .cyan, .indigo, .brown]
    static func color(_ i: Int) -> Color { colors[i % colors.count] }
}

/// After Effects' keyframe assistants: Bezier handles on either side of a key.
enum GraphEase: CaseIterable {
    case easy, easeIn, easeOut, linear

    var title: String {
        switch self {
        case .easy: return "Easy Ease"
        case .easeIn: return "Easy Ease In"
        case .easeOut: return "Easy Ease Out"
        case .linear: return "Linear"
        }
    }

    var icon: String {
        switch self {
        case .easy: return "point.topleft.down.to.point.bottomright.curvepath"
        case .easeIn: return "arrow.down.right.and.arrow.up.left"
        case .easeOut: return "arrow.up.left.and.arrow.down.right"
        case .linear: return "line.diagonal"
        }
    }

    /// (x2, y2) of the segment arriving at the key: y 1 = arrives at zero speed.
    var incoming: (x: Double, y: Double)? {
        switch self {
        case .easy, .easeIn: return (2.0 / 3, 1)
        case .linear: return (2.0 / 3, 2.0 / 3)
        case .easeOut: return nil
        }
    }

    /// (x1, y1) of the segment leaving the key: y 0 = leaves at zero speed.
    var outgoing: (x: Double, y: Double)? {
        switch self {
        case .easy, .easeOut: return (1.0 / 3, 0)
        case .linear: return (1.0 / 3, 1.0 / 3)
        case .easeIn: return nil
        }
    }

    /// F9, ⇧F9 and ⌘⇧F9 like After Effects.
    var shortcut: KeyboardShortcut? {
        let f9 = KeyEquivalent(Character(UnicodeScalar(NSF9FunctionKey)!))
        switch self {
        case .easy: return KeyboardShortcut(f9, modifiers: [])
        case .easeIn: return KeyboardShortcut(f9, modifiers: .shift)
        case .easeOut: return KeyboardShortcut(f9, modifiers: [.command, .shift])
        case .linear: return nil
        }
    }

    var shortcutLabel: String? {
        switch self {
        case .easy: return "F9"
        case .easeIn: return "⇧F9"
        case .easeOut: return "⌘⇧F9"
        case .linear: return nil
        }
    }

    func apply(_ store: SceneStore, layer: String, properties: [AnimProperty], at t: Double) {
        guard !properties.isEmpty else { return }
        try? store.apply(title) { s in
            for p in properties {
                try s.setKeyHandles(layer, property: p, at: t, incoming: incoming, outgoing: outgoing)
            }
        }
    }
}

extension TimelineState {
    /// The curve the graph edits: the chosen one if shown, else the first shown.
    func focusedGraphTrack(in tracks: [AnimProperty]) -> AnimProperty? {
        let shown = tracks.filter { !graphHidden.contains($0) }
        if let f = graphFocus, shown.contains(f) { return f }
        return shown.first
    }
}

/// Name column in graph mode: the layer's keyframed numbers. Click one to edit its curve; the eye shows or hides it.
struct GraphTrackList: View {
    @Environment(SceneStore.self) private var store
    let tl: TimelineState
    let layer: MotionLayer?

    var body: some View {
        if let l = layer, !l.animatedProperties.isEmpty {
            let tracks = l.animatedProperties
            let focus = tl.focusedGraphTrack(in: tracks)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(l.name).font(.caption.weight(.semibold)).lineLimit(1)
                        .padding(.horizontal, 8).frame(height: 22)
                    ForEach(Array(tracks.enumerated()), id: \.element) { i, p in
                        row(l, p, color: GraphPalette.color(i), focused: p == focus)
                    }
                    if !l.animatedColors.isEmpty {
                        Text("Color keyframes are edited on the timeline.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.top, 6)
                    }
                }
            }
        } else {
            Color.clear
        }
    }

    private func row(_ l: MotionLayer, _ p: AnimProperty, color: Color, focused: Bool) -> some View {
        let hidden = tl.graphHidden.contains(p)
        return HStack(spacing: 6) {
            Button {
                if hidden { tl.graphHidden.remove(p) } else { tl.graphHidden.insert(p) }
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye").font(.caption2).frame(width: 14)
            }
            .buttonStyle(.borderless)
            .help(hidden ? "Show this curve" : "Hide this curve")
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(hidden ? 0.3 : 1)).frame(width: 8, height: 8)
            Text(p.title).font(.caption).lineLimit(1).foregroundStyle(hidden ? .secondary : .primary)
            Spacer(minLength: 4)
            Text(String(format: p.isFractional ? "%.2f" : "%.0f", l.value(p, at: store.panelTime)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(focused ? Color.accentColor.opacity(0.15) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            tl.graphFocus = p
            tl.graphHidden.remove(p)
        }
    }
}

/// Value graph of a layer's keyframed numbers, on the timeline's time axis. Each curve is fitted to its own value
/// range; the focused one shows its keys (drag in time and value, ⇧ locks to one axis) and the Bezier handles of
/// each segment (drag to reshape the easing).
struct GraphEditor: View {
    @Environment(SceneStore.self) private var store
    let tl: TimelineState
    let layer: MotionLayer
    /// Frame rounding + snapping to the playhead and beats, like the timeline.
    let snap: (Double) -> Double
    /// Value ranges held while dragging, so the curve doesn't rescale under the pointer.
    @State private var frozen: [AnimProperty: ClosedRange<Double>]?
    @State private var keyOrigin: MotionKeyframe?

    private let inset = 18.0

    private struct Handle {
        let keyT: Double
        let incoming: Bool
        let t: Double
        let v: Double
        /// Stored y of the control point: kept when the segment is flat (no value change to measure it against).
        let cy: Double
        let from: MotionKeyframe
        let to: MotionKeyframe
    }

    var body: some View {
        let tracks = layer.animatedProperties
        let shown = tracks.filter { !tl.graphHidden.contains($0) }
        let focus = tl.focusedGraphTrack(in: tracks)
        GeometryReader { geo in
            let h = Double(geo.size.height)
            let ranges = Dictionary(uniqueKeysWithValues: shown.map { p in (p, frozen?[p] ?? range(p, focused: p == focus)) })
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.white.opacity(0.0001))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        store.seek(tl.time(atX: g.location.x))
                        tl.selectedKey = nil
                    })
                curves(tracks: tracks, shown: shown, focus: focus, ranges: ranges, height: h)
                    .allowsHitTesting(false)
                if let p = focus, let r = ranges[p] {
                    handleViews(p, range: r, ranges: ranges, height: h)
                    keyViews(p, range: r, ranges: ranges, height: h)
                }
                if shown.isEmpty {
                    Text("All curves are hidden").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "graph")
        }
    }

    // MARK: Mapping

    private func y(_ v: Double, _ r: ClosedRange<Double>, _ h: Double) -> Double {
        let span = max(r.upperBound - r.lowerBound, 1e-9)
        return inset + (1 - (v - r.lowerBound) / span) * max(h - 2 * inset, 1)
    }

    private func value(atY y: Double, _ r: ClosedRange<Double>, _ h: Double) -> Double {
        let span = r.upperBound - r.lowerBound
        return r.lowerBound + (1 - (y - inset) / max(h - 2 * inset, 1)) * span
    }

    /// Everything the curve reaches between its first and last key (overshoot included), plus the handles if focused.
    private func range(_ p: AnimProperty, focused: Bool) -> ClosedRange<Double> {
        let track = layer[p]
        let kfs = track.keyframeList
        var lo = Double.infinity, hi = -Double.infinity
        func add(_ v: Double) { lo = min(lo, v); hi = max(hi, v) }
        kfs.forEach { add($0.v) }
        if let a = kfs.first?.t, let b = kfs.last?.t, b > a {
            for i in 0...240 { add(track.value(at: a + (b - a) * Double(i) / 240)) }
        }
        if focused { handles(p).forEach { add($0.v) } }
        guard lo.isFinite else { return -1...1 }
        if hi - lo < 1e-9 {
            let pad = max(abs(lo) * 0.1, p.isFractional ? 0.1 : 1)
            return (lo - pad)...(hi + pad)
        }
        return lo...hi
    }

    private func handles(_ p: AnimProperty) -> [Handle] {
        let kfs = layer[p].keyframeList
        guard kfs.count > 1 else { return [] }
        var out: [Handle] = []
        for i in 1..<kfs.count {
            let a = kfs[i - 1], b = kfs[i]
            guard b.t - a.t > 1e-6, let c = b.easing.bezierControls else { continue }
            let dt = b.t - a.t, dv = b.v - a.v
            out.append(Handle(keyT: a.t, incoming: false, t: a.t + c.0 * dt, v: a.v + c.1 * dv, cy: c.1, from: a, to: b))
            out.append(Handle(keyT: b.t, incoming: true, t: a.t + c.2 * dt, v: a.v + c.3 * dv, cy: c.3, from: a, to: b))
        }
        return out
    }

    private func rounded(_ v: Double, _ p: AnimProperty) -> Double {
        let step = p.isFractional ? 0.001 : 0.1
        return (v / step).rounded() * step
    }

    // MARK: Drawing

    private func curves(tracks: [AnimProperty], shown: [AnimProperty], focus: AnimProperty?,
                        ranges: [AnimProperty: ClosedRange<Double>], height h: Double) -> some View {
        let pps = tl.pps, scrollX = tl.scrollX, duration = tl.duration
        let hs = focus.map(handles) ?? []
        return Canvas { ctx, size in
            let endX = min(Double(size.width), duration * pps - scrollX)
            if let p = focus, let r = ranges[p] {
                let step = Self.niceStep((r.upperBound - r.lowerBound) / 4)
                let decimals = max(0, Int(-floor(log10(step))))
                var v = ceil(r.lowerBound / step) * step
                while v <= r.upperBound + step * 1e-6 {
                    let yy = y(v, r, h)
                    ctx.fill(Path(CGRect(x: 0, y: yy, width: size.width, height: 0.5)),
                             with: .color(.secondary.opacity(abs(v) < step * 1e-6 ? 0.4 : 0.15)))
                    ctx.draw(Text(String(format: "%.\(decimals)f", v)).font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(.secondary),
                             at: CGPoint(x: 4, y: yy - 6), anchor: .leading)
                    v += step
                }
            }
            // Focused curve last, so it is drawn on top.
            for p in shown.filter({ $0 != focus }) + shown.filter({ $0 == focus }) {
                guard let r = ranges[p], let i = tracks.firstIndex(of: p) else { continue }
                let track = layer[p], loop = layer.loop[p.rawValue]
                var path = Path()
                var x = max(0, -scrollX)
                var first = true
                while x <= endX {
                    let pt = CGPoint(x: x, y: y(track.value(at: tl.time(atX: x), loop: loop), r, h))
                    if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
                    x += 2
                }
                let color = GraphPalette.color(i)
                ctx.stroke(path, with: .color(p == focus ? color : color.opacity(0.4)), lineWidth: p == focus ? 1.8 : 1)
                if p != focus {
                    for k in track.keyframeList {
                        let c = CGPoint(x: tl.x(k.t), y: y(k.v, r, h))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)),
                                 with: .color(color.opacity(0.6)))
                    }
                }
            }
            if let p = focus, let r = ranges[p] {
                var lines = Path()
                for hd in hs {
                    let key = hd.incoming ? hd.to : hd.from
                    lines.move(to: CGPoint(x: tl.x(key.t), y: y(key.v, r, h)))
                    lines.addLine(to: CGPoint(x: tl.x(hd.t), y: y(hd.v, r, h)))
                }
                ctx.stroke(lines, with: .color(.white.opacity(0.55)), lineWidth: 1)
            }
        }
    }

    private func handleViews(_ p: AnimProperty, range r: ClosedRange<Double>,
                             ranges: [AnimProperty: ClosedRange<Double>], height h: Double) -> some View {
        let hs = handles(p)
        return ForEach(hs.indices, id: \.self) { i in
            let hd = hs[i]
            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                .frame(width: 8, height: 8)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .position(x: tl.x(hd.t), y: y(hd.v, r, h))
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("graph"))
                    .onChanged { g in
                        if frozen == nil {
                            frozen = ranges
                            store.beginInteractive("Edit Curve")
                        }
                        let fr = frozen?[p] ?? r
                        let dt = hd.to.t - hd.from.t, dv = hd.to.v - hd.from.v
                        let x = (tl.time(atX: g.location.x) - hd.from.t) / dt
                        let yv = abs(dv) > 1e-9 ? (value(atY: g.location.y, fr, h) - hd.from.v) / dv : hd.cy
                        let handle = (x: x, y: yv)
                        store.updateInteractive {
                            try $0.setKeyHandles(layer.id, property: p, at: hd.keyT,
                                                 incoming: hd.incoming ? handle : nil, outgoing: hd.incoming ? nil : handle)
                        }
                    }
                    .onEnded { _ in
                        store.endInteractive()
                        frozen = nil
                    })
                .help(hd.incoming ? "Drag to shape the ease into this keyframe" : "Drag to shape the ease out of this keyframe")
        }
    }

    private func keyViews(_ p: AnimProperty, range r: ClosedRange<Double>,
                          ranges: [AnimProperty: ClosedRange<Double>], height h: Double) -> some View {
        let kfs = layer[p].keyframeList
        let fps = Double(max(store.scene.fps, 1))
        return ForEach(kfs.indices, id: \.self) { i in
            let k = kfs[i]
            let selected = tl.selectedKey == KeySelection(layerId: layer.id, property: .number(p), t: k.t)
                || abs(k.t - store.panelTime) < 0.5 / fps
            let hold = k.easing == .hold
            KeyShape(square: hold)
                .fill(selected ? Color.accentColor : Color.yellow)
                .overlay(KeyShape(square: hold).stroke(Color.white, lineWidth: selected ? 1.5 : 0))
                .frame(width: 11, height: 11)
                .shadow(color: .black.opacity(0.35), radius: 0.5, y: 0.5)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
                .position(x: tl.x(k.t), y: y(k.v, r, h))
                .onTapGesture {
                    store.selection = layer.id
                    tl.selectedKey = KeySelection(layerId: layer.id, property: .number(p), t: k.t)
                    store.seek(k.t)
                }
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("graph"))
                    .onChanged { g in
                        if keyOrigin == nil {
                            keyOrigin = k
                            frozen = ranges
                            store.beginInteractive("Edit Keyframe")
                        }
                        guard let o = keyOrigin else { return }
                        let fr = frozen?[p] ?? r
                        var dx = Double(g.translation.width), dy = Double(g.translation.height)
                        if NSEvent.modifierFlags.contains(.shift) {
                            if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 }
                        }
                        let newT = dx == 0 ? o.t : snap(o.t + dx / tl.pps)
                        let newV = dy == 0 ? o.v : rounded(value(atY: y(o.v, fr, h) + dy, fr, h), p)
                        store.updateInteractive {
                            try $0.moveKeyframes(layer.id, track: .number(p), from: o.t, to: newT)
                            try $0.setValue(layer.id, property: p, value: newV, at: newT)
                        }
                        store.seek(newT)
                        tl.selectedKey = KeySelection(layerId: layer.id, property: .number(p), t: newT)
                    }
                    .onEnded { _ in
                        store.endInteractive()
                        keyOrigin = nil
                        frozen = nil
                    })
                .contextMenu {
                    ForEach(GraphEase.allCases, id: \.self) { e in
                        Button(e.title) { e.apply(store, layer: layer.id, properties: [p], at: k.t) }
                    }
                    Button("Hold into this keyframe") {
                        try? store.apply("Change Easing") { try $0.setEasing(layer.id, track: .number(p), at: k.t, easing: .hold) }
                    }
                    Divider()
                    Button("Delete keyframe", role: .destructive) {
                        try? store.apply("Delete Keyframe") { try $0.deleteKeyframes(layer.id, track: .number(p), at: k.t) }
                    }
                }
                .help(String(format: "%@ = %@ at %.2fs (%@)", p.title,
                             String(format: p.isFractional ? "%.3f" : "%.1f", k.v), k.t, k.easing.title))
        }
    }

    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let e = pow(10, floor(log10(raw)))
        let f = raw / e
        return (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * e
    }
}
