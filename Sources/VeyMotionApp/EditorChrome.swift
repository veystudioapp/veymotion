import AppKit
import SwiftUI
import VeyMotionCore
import VeyMotionMCP

// Shared building blocks for the editor's panels: tab bars, collapsible sections and compact fields.

// MARK: - Panel tabs

protocol PanelTab: Hashable, CaseIterable where AllCases: RandomAccessCollection {
    var title: String { get }
    var icon: String { get }
}

/// The Claude logo (brand color), used wherever the UI refers to Claude.
struct ClaudeLogo: View {
    var size: CGFloat = 14

    static let image: NSImage = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="256" height="257" preserveAspectRatio="xMidYMid" viewBox="0 0 256 257">\
        <path fill="#D97757" d="m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518-28.775-.778-24.952-1.037-24.175-1.296-6.092-1.297L0 125.796l.583-3.759 5.12-3.434 7.324.648 16.202 1.101 24.304 1.685 17.629 1.037 26.118 2.722h4.148l.583-1.685-1.426-1.037-1.101-1.037-25.147-17.045-27.22-18.017-14.258-10.37-7.713-5.25-3.888-4.925-1.685-10.758 7-7.713 9.397.649 2.398.648 9.527 7.323 20.35 15.75L94.817 91.9l3.889 3.24 1.555-1.102.195-.777-1.75-2.917-14.453-26.118-15.425-26.572-6.87-11.018-1.814-6.61c-.648-2.723-1.102-4.991-1.102-7.778l7.972-10.823L71.42 0 82.05 1.426l4.472 3.888 6.61 15.101 10.694 23.786 16.591 32.34 4.861 9.592 2.592 8.879.973 2.722h1.685v-1.556l1.36-18.211 2.528-22.36 2.463-28.776.843-8.1 4.018-9.722 7.971-5.25 6.222 2.981 5.12 7.324-.713 4.73-3.046 19.768-5.962 30.98-3.889 20.739h2.268l2.593-2.593 10.499-13.934 17.628-22.036 7.778-8.749 9.073-9.657 5.833-4.601h11.018l8.1 12.055-3.628 12.443-11.342 14.388-9.398 12.184-13.48 18.147-8.426 14.518.778 1.166 2.01-.194 30.46-6.481 16.462-2.982 19.637-3.37 8.88 4.148.971 4.213-3.5 8.62-20.998 5.184-24.628 4.926-36.682 8.685-.454.324.519.648 16.526 1.555 7.065.389h17.304l32.21 2.398 8.426 5.574 5.055 6.805-.843 5.184-12.962 6.611-17.498-4.148-40.83-9.721-14-3.5h-1.944v1.167l11.666 11.406 21.387 19.314 26.767 24.887 1.36 6.157-3.434 4.86-3.63-.518-23.526-17.693-9.073-7.972-20.545-17.304h-1.36v1.814l4.73 6.935 25.017 37.59 1.296 11.536-1.814 3.76-6.481 2.268-7.13-1.297-14.647-20.544-15.1-23.138-12.185-20.739-1.49.843-7.194 77.448-3.37 3.953-7.778 2.981-6.48-4.925-3.436-7.972 3.435-15.749 4.148-20.544 3.37-16.333 3.046-20.285 1.815-6.74-.13-.454-1.49.194-15.295 20.999-23.267 31.433-18.406 19.702-4.407 1.75-7.648-3.954.713-7.064 4.277-6.286 25.47-32.405 15.36-20.092 9.917-11.6-.065-1.686h-.583L44.07 198.125l-12.055 1.555-5.185-4.86.648-7.972 2.463-2.593 20.35-13.999-.064.065Z"/></svg>
        """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!
        image.isTemplate = false
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("Claude")
    }
}

/// The Codex logo. A template image, so it follows the text color (dark and light mode).
struct CodexLogo: View {
    var size: CGFloat = 14

    static let image: NSImage = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">\
        <path fill="#111" fill-rule="evenodd" clip-rule="evenodd" d="M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"/></svg>
        """
        let image = NSImage(data: Data(svg.utf8))
            ?? NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("Codex")
    }
}

/// The logo of the CLI that runs the chat.
struct AgentLogo: View {
    var provider: AgentProvider
    var size: CGFloat = 14

    var body: some View {
        switch provider {
        case .claude: ClaudeLogo(size: size)
        case .codex: CodexLogo(size: size)
        }
    }
}

enum LeftPanelTab: String, PanelTab {
    case layers = "Layers", assets = "Assets"
    var title: String { self == .layers ? "Layers" : "Assets" }
    var icon: String { self == .layers ? "square.3.layers.3d" : "photo.on.rectangle" }
}

/// Text tabs at the top of a side panel (lighter than a segmented control).
struct PanelTabBar<Tab: PanelTab>: View {
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let on = tab == selection
                Button { selection = tab } label: {
                    Label(tab.title, systemImage: tab.icon)
                        .font(.callout.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.primary.opacity(0.09) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }
}

// MARK: - Inspector sections

/// A titled, collapsible inspector section. Collapsed titles are remembered across launches.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @AppStorage("inspectorCollapsed") private var collapsedRaw = ""

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    private var collapsed: Bool { collapsedRaw.split(separator: "|").contains { $0 == title } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                var set = Set(collapsedRaw.split(separator: "|").map(String.init))
                if collapsed { set.remove(title) } else { set.insert(title) }
                withAnimation(.easeOut(duration: 0.15)) { collapsedRaw = set.sorted().joined(separator: "|") }
            } label: {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed { content }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        Divider()
    }
}

// MARK: - Fields

private struct FieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.06)))
    }
}

extension View {
    func fieldBackground() -> some View { modifier(FieldBackground()) }
}

/// Compact number box with a small label inside it ("X 960"). Commits on Return or focus loss.
struct NumberField: View {
    let label: String
    let value: Double
    var unit: String?
    var digits = 2
    let onCommit: (Double) -> Void

    init(_ label: String, _ value: Double, unit: String? = nil, digits: Int = 2, onCommit: @escaping (Double) -> Void) {
        self.label = label; self.value = value; self.unit = unit; self.digits = digits; self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary).fixedSize()
            TextField("", value: Binding(get: { value }, set: { if $0 != value { onCommit($0) } }),
                      format: .number.precision(.fractionLength(0...digits)))
                .textFieldStyle(.plain)
                .font(.callout.monospacedDigit())
            if let unit { Text(unit).font(.caption).foregroundStyle(.tertiary) }
        }
        .fieldBackground()
    }
}

/// Text box that commits on Return (so renames are one undo step).
struct CommitTextField: View {
    let placeholder: String
    let value: String
    var font: Font = .callout
    let onCommit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .onSubmit { if draft != value { onCommit(draft) } }
            .onAppear { draft = value }
            .onChange(of: value) { _, v in draft = v }
    }
}

/// Color well + hex.
struct ColorField: View {
    let label: String
    let value: RGBA
    let onChange: (RGBA) -> Void

    init(_ label: String, _ value: RGBA, onChange: @escaping (RGBA) -> Void) {
        self.label = label; self.value = value; self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            ColorPicker("", selection: Binding(get: { value.color }, set: { onChange(RGBA($0)) }), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 38)
            Text(value.hex).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// Small leading label for rows that hold a non-field control (picker, slider…).
struct RowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
    }
}

// MARK: - Keyframes

/// One diamond per animatable track: hollow grey = not animated (click to animate), hollow accent = animated
/// with no key at the playhead (click to add), filled = key at the playhead (click to delete).
/// Animated tracks also get ◀ ▶ to jump the playhead to the previous / next key.
struct KeyframeButton: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer
    let track: KeyTrack

    init(layer: MotionLayer, track: KeyTrack) { self.layer = layer; self.track = track }
    init(layer: MotionLayer, property: AnimProperty) { self.init(layer: layer, track: .number(property)) }

    var body: some View {
        let tolerance = 0.5 / Double(store.scene.fps)
        let animated = layer.isAnimated(track)
        let times = layer.keyTimes(track)
        let now = store.panelTime
        let keyHere = times.first { abs($0 - now) < tolerance }
        HStack(spacing: 0) {
            if animated { jump("chevron.left", to: times.last { $0 < now - tolerance }, help: "Previous keyframe") }
            diamond(animated: animated, keyHere: keyHere)
            if animated { jump("chevron.right", to: times.first { $0 > now + tolerance }, help: "Next keyframe") }
        }
    }

    private func jump(_ symbol: String, to t: Double?, help: String) -> some View {
        Button {
            if let t { store.pause(); store.seek(t) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .frame(width: 9, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(t == nil ? Color.secondary.opacity(0.3) : Color.secondary)
        .disabled(t == nil)
        .help(help)
    }

    private func diamond(animated: Bool, keyHere: Double?) -> some View {
        Button {
            if !animated {
                store.toggleAnimation(layer.id, track)
            } else if let t = keyHere {
                try? store.apply("Delete Keyframe") { try $0.deleteKeyframes(layer.id, track: track, at: t) }
            } else {
                store.addKey(layer.id, track)
            }
        } label: {
            Image(systemName: keyHere != nil ? "diamond.fill" : "diamond")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(keyHere != nil || animated ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 16, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(!animated ? "Animate \(track.title.lowercased()): add a keyframe at the playhead"
              : keyHere != nil ? "Delete keyframe at the playhead" : "Add keyframe at the playhead")
        .contextMenu {
            if animated {
                Menu("Loop after last key") {
                    let current = layer.loop[track.name]
                    Button { setLoop(nil) } label: { check("None", current == nil) }
                    ForEach(LoopMode.allCases, id: \.self) { m in
                        Button { setLoop(m) } label: { check(m.title, current == m) }
                    }
                }
                Button("Remove Animation") { store.toggleAnimation(layer.id, track) }
            }
        }
    }

    private func setLoop(_ m: LoopMode?) {
        store.updateLayer(layer.id, "Loop") { $0.loop[track.name] = m }
    }
}

/// Menu label with a checkmark when selected.
@ViewBuilder func check(_ title: String, _ on: Bool) -> some View {
    if on { Label(title, systemImage: "checkmark") } else { Text(title) }
}

/// Color well for an animatable color, plus its keyframe diamond.
struct AnimColorField: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer
    let property: ColorProperty
    let label: String

    var body: some View {
        HStack(spacing: 2) {
            ColorField(label, layer.color(property, at: store.panelTime) ?? .clear) { c in
                store.setColor(layer.id, property, c)
            }
            KeyframeButton(layer: layer, track: .color(property))
        }
    }
}

/// Menu items for every easing, grouped like a curve library.
struct EasingMenuItems: View {
    let current: Easing?
    let onPick: (Easing) -> Void

    var body: some View {
        ForEach([Easing.linear, .easeIn, .easeOut, .easeInOut, .hold], id: \.self) { item($0) }
        Divider()
        ForEach(EaseCurve.allCases, id: \.self) { c in
            Menu(c.title) {
                ForEach(EaseMode.allCases, id: \.self) { m in item(.curve(c, m)) }
            }
        }
        Divider()
        Menu("Spring") {
            item(.spring)
            item(.springWith(damping: 3, frequency: 16), "Very Bouncy")
            item(.springWith(damping: 5, frequency: 13), "Bouncy")
            item(.springWith(damping: 10, frequency: 8), "Gentle")
            item(.springWith(damping: 16, frequency: 6), "Stiff")
        }
        Menu("Steps") {
            ForEach([2, 3, 4, 6, 8, 12], id: \.self) { n in item(.steps(n)) }
        }
        if case .cubicBezier = current { Divider(); item(current!) }
    }

    private func item(_ e: Easing, _ title: String? = nil) -> some View {
        Button { onPick(e) } label: { check(title ?? e.title, current == e) }
    }
}

/// Edits a cubic-bezier easing by dragging its two handles (values outside 0…1 vertically overshoot).
struct BezierEditor: View {
    @State private var p: [Double]
    let onApply: (Easing) -> Void
    private let w: CGFloat = 200
    private let h: CGFloat = 200
    /// Vertical range shown: -0.5 … 1.5.
    private func px(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: (1.5 - y) / 2 * h) }
    private func value(_ pt: CGPoint) -> (Double, Double) {
        (min(max(pt.x / w, 0), 1), 1.5 - pt.y / h * 2)
    }

    init(initial: Easing, onApply: @escaping (Easing) -> Void) {
        let c = initial.bezierControls ?? Easing.easeInOut.bezierControls!
        _p = State(initialValue: [c.0, c.1, c.2, c.3])
        self.onApply = onApply
    }

    var body: some View {
        let e = Easing.cubicBezier(p[0], p[1], p[2], p[3])
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom Bezier").font(.headline)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    var grid = Path()
                    grid.addRect(CGRect(origin: px(0, 1), size: CGSize(width: w, height: h / 2)))
                    ctx.stroke(grid, with: .color(.secondary.opacity(0.3)))
                    var handles = Path()
                    handles.move(to: px(0, 0)); handles.addLine(to: px(p[0], p[1]))
                    handles.move(to: px(1, 1)); handles.addLine(to: px(p[2], p[3]))
                    ctx.stroke(handles, with: .color(.accentColor.opacity(0.6)), lineWidth: 1)
                    var curve = Path()
                    for i in 0...80 {
                        let t = Double(i) / 80
                        let pt = px(t, e.apply(t))
                        if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                    }
                    ctx.stroke(curve, with: .color(.primary), lineWidth: 2)
                }
                .frame(width: w, height: h)
                handle(0)
                handle(2)
            }
            .frame(width: w, height: h)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    NumberField("x1", p[0]) { p[0] = min(max($0, 0), 1) }
                    NumberField("y1", p[1]) { p[1] = $0 }
                }
                GridRow {
                    NumberField("x2", p[2]) { p[2] = min(max($0, 0), 1) }
                    NumberField("y2", p[3]) { p[3] = $0 }
                }
            }
            .frame(width: w)
            HStack {
                Text(e.string).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { onApply(e) }.keyboardShortcut(.defaultAction)
            }
            .frame(width: w)
        }
        .padding(14)
    }

    private func handle(_ i: Int) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 12, height: 12)
            .position(px(p[i], p[i + 1]))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { g in
                let v = value(g.location)
                p[i] = (v.0 * 100).rounded() / 100
                p[i + 1] = (min(max(v.1, -0.5), 1.5) * 100).rounded() / 100
            })
    }
}

/// Number field for an animatable property, showing the value at the playhead, plus its keyframe diamond.
struct AnimField: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer
    let property: AnimProperty
    let label: String
    var unit: String?

    var body: some View {
        HStack(spacing: 2) {
            NumberField(label, layer[property].value(at: store.panelTime), unit: unit) { v in
                store.setValue(layer.id, property, v)
            }
            KeyframeButton(layer: layer, property: property)
        }
    }
}

/// Slider + percent field for a 0…1 animatable property. A slider drag is one undo step.
struct AnimSlider: View {
    @Environment(SceneStore.self) private var store
    let layer: MotionLayer
    let property: AnimProperty
    let label: String
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        let value = layer[property].value(at: store.panelTime)
        HStack(spacing: 6) {
            RowLabel(label)
            Slider(value: Binding(get: { value }, set: { v in
                store.updateInteractive { try $0.setValue(layer.id, property: property, value: v, at: store.time) }
            }), in: range) { editing in
                if editing { store.beginInteractive("Change \(property.rawValue)") } else { store.endInteractive() }
            }
            .controlSize(.small)
            NumberField("", value * 100, unit: "%", digits: 0) { store.setValue(layer.id, property, $0 / 100) }
                .frame(width: 64)
            KeyframeButton(layer: layer, property: property)
        }
    }
}

// MARK: - Misc

extension LayerType {
    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .path: return "scribble.variable"
        case .text: return "textformat"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .particles: return "sparkles"
        case .generator: return "waveform.path.ecg"
        case .group: return "folder"
        case .model: return "cube"
        case .drawing: return "scribble"
        }
    }
}

/// Agent connection indicator for the status bar; details and the MCP command live in a popover.
struct AgentStatusButton: View {
    @Environment(SceneStore.self) private var store
    @State private var showDetails = false

    var body: some View {
        let linkOK = store.controlStatus == "Ready"
        let mcpOK = store.mcpStatus.hasPrefix("Listening")
        Button { showDetails.toggle() } label: {
            HStack(spacing: 5) {
                Circle().fill(linkOK && mcpOK ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(linkOK && mcpOK ? "Agents ready" : "Agent connection issue")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Agent connections")
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Agent connections").font(.headline)
                statusRow("In-app Claude (vmotion)", store.controlStatus, ok: linkOK)
                statusRow("MCP server", store.mcpStatus, ok: mcpOK)
                Divider()
                Text("Connect Claude Code from a terminal:").font(.caption).foregroundStyle(.secondary)
                Text(store.claudeCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.claudeCommand, forType: .string)
                    store.message = "Copied: \(store.claudeCommand)"
                    showDetails = false
                }
            }
            .padding(14)
            .frame(width: 380)
        }
    }

    private func statusRow(_ title: String, _ status: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(title)
            Spacer()
            Text(status).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.callout)
    }
}

/// A selectable card or chip: accent outline and tint when selected.
struct ChoiceTileStyle: ButtonStyle {
    var selected: Bool
    var capsule = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: capsule ? 100 : 10, style: .continuous)
        configuration.label
            .padding(.horizontal, capsule ? 12 : 0).padding(.vertical, capsule ? 5 : 0)
            .frame(maxWidth: capsule ? nil : .infinity)
            .contentShape(shape)
            .background(shape.fill(selected ? Color.accentColor.opacity(0.12)
                                            : Color.primary.opacity(configuration.isPressed ? 0.08 : 0.04)))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1),
                                        lineWidth: selected ? 1.5 : 1))
            .foregroundStyle(selected && capsule ? Color.accentColor : .primary)
    }
}

/// Icon centered on the title's capitals: `.titleAndIcon` (baseline) and plain centering (which counts the
/// descenders) both leave the title looking low next to a tall symbol (sparkles, share).
struct CenteredLabelStyle: LabelStyle {
    var spacing: CGFloat = 6
    var fontSize = NSFont.systemFontSize

    func makeBody(configuration: Configuration) -> some View {
        let capHeight = NSFont.systemFont(ofSize: fontSize).capHeight
        HStack(alignment: .capCenter, spacing: spacing) {
            configuration.icon
            configuration.title
                .alignmentGuide(.capCenter) { d in d[.firstTextBaseline] - capHeight / 2 }
        }
    }
}

extension VerticalAlignment {
    private enum CapCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }

    /// The middle of a text's capitals; other views use their center.
    static let capCenter = VerticalAlignment(CapCenter.self)
}
