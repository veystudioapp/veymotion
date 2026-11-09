import AppKit
import SwiftUI
import VeyMotionCore

// MARK: - Model

/// A mark drawn over the paused canvas to show Claude what to change. Coordinates and sizes are in scene
/// units (y down), so the marks stay on the frame when the canvas is resized and land exactly on the image sent.
struct Annotation: Identifiable, Equatable {
    enum ShapeKind: String, CaseIterable {
        case rect, ellipse, arrow, line
        var title: String {
            switch self {
            case .rect: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .arrow: return "Arrow"
            case .line: return "Line"
            }
        }
        var symbol: String {
            switch self {
            case .rect: return "square"
            case .ellipse: return "circle"
            case .arrow: return "arrow.up.right"
            case .line: return "line.diagonal"
            }
        }
    }

    enum Kind: Equatable {
        case stroke([CGPoint])
        case shape(ShapeKind, CGPoint, CGPoint)
        case text(String, CGPoint)
    }

    var id = UUID()
    var kind: Kind
    var color: NSColor
    /// Line width, or font size for text.
    var size: Double

    func moved(by d: CGSize) -> Annotation {
        let m = { (p: CGPoint) in CGPoint(x: p.x + d.width, y: p.y + d.height) }
        var a = self
        switch kind {
        case let .stroke(ps): a.kind = .stroke(ps.map(m))
        case let .shape(k, p, q): a.kind = .shape(k, m(p), m(q))
        case let .text(s, p): a.kind = .text(s, m(p))
        }
        return a
    }

    var bounds: CGRect {
        switch kind {
        case let .stroke(ps):
            guard let f = ps.first else { return .null }
            return ps.reduce(CGRect(origin: f, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
                .insetBy(dx: -size / 2, dy: -size / 2)
        case let .shape(_, p, q):
            return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
                .insetBy(dx: -size / 2, dy: -size / 2)
        case let .text(s, p):
            return CGRect(origin: p, size: Self.textBox(s, size: size, color: color).size)
        }
    }

    /// Whether `p` is on the mark (lines and outlines within `tolerance`, text anywhere in its box).
    func hit(_ p: CGPoint, tolerance: Double) -> Bool {
        let reach = size / 2 + tolerance
        switch kind {
        case let .stroke(ps):
            if ps.count == 1 { return hypot(ps[0].x - p.x, ps[0].y - p.y) <= reach }
            return zip(ps, ps.dropFirst()).contains { Self.distance(p, $0, $1) <= reach }
        case let .shape(k, a, b):
            switch k {
            case .arrow, .line: return Self.distance(p, a, b) <= reach
            case .rect, .ellipse:
                // Inside counts too: thin outlines are hard to grab.
                return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
            }
        case .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Drawing

    static func font(_ size: Double) -> NSFont { .systemFont(ofSize: max(size, 1), weight: .semibold) }

    private static func attributed(_ s: String, size: Double, color: NSColor, outline: Bool) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: font(size), .foregroundColor: color]
        if outline {
            attrs[.strokeColor] = contrast(color)
            attrs[.strokeWidth] = 18.0 // percent of the font size, stroke only
        }
        return NSAttributedString(string: s.isEmpty ? " " : s, attributes: attrs)
    }

    static func textBox(_ s: String, size: Double, color: NSColor) -> CGRect {
        attributed(s, size: size, color: color, outline: false)
            .boundingRect(with: CGSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin])
    }

    /// White behind dark colors, black behind light ones, so marks read on any frame.
    static func contrast(_ c: NSColor) -> NSColor {
        guard let rgb = c.usingColorSpace(.sRGB) else { return .white }
        let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return lum > 0.6 ? NSColor.black.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.9)
    }

    /// Draws into a y-down context whose units are scene units.
    func draw(in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(size)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch kind {
        case let .stroke(ps):
            guard let f = ps.first else { return }
            if ps.count == 1 {
                ctx.fillEllipse(in: CGRect(x: f.x - size / 2, y: f.y - size / 2, width: size, height: size))
                return
            }
            ctx.addLines(between: Self.smoothed(ps))
            ctx.strokePath()
        case let .shape(k, a, b):
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            switch k {
            case .rect: ctx.stroke(r)
            case .ellipse: ctx.strokeEllipse(in: r)
            case .line:
                ctx.addLines(between: [a, b])
                ctx.strokePath()
            case .arrow:
                let len: CGFloat = hypot(b.x - a.x, b.y - a.y)
                guard len > 0 else { return }
                let head: CGFloat = min(max(CGFloat(size) * 3.5, 10), len * 0.6)
                let ang: CGFloat = atan2(b.y - a.y, b.x - a.x)
                let back = CGPoint(x: b.x - cos(ang) * head * 0.8, y: b.y - sin(ang) * head * 0.8)
                ctx.addLines(between: [a, back])
                ctx.strokePath()
                let spread: CGFloat = 0.45
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - cos(ang - spread) * head, y: b.y - sin(ang - spread) * head))
                ctx.addLine(to: CGPoint(x: b.x - cos(ang + spread) * head, y: b.y - sin(ang + spread) * head))
                ctx.closePath()
                ctx.drawPath(using: .fillStroke)
            }
        case let .text(s, p):
            guard !s.isEmpty else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let rect = CGRect(origin: p, size: Self.textBox(s, size: size, color: color).size)
            Self.attributed(s, size: size, color: color, outline: true).draw(with: rect, options: [.usesLineFragmentOrigin])
            Self.attributed(s, size: size, color: color, outline: false).draw(with: rect, options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Light smoothing of a freehand stroke (moving average) so mouse jitter does not show.
    private static func smoothed(_ ps: [CGPoint]) -> [CGPoint] {
        guard ps.count > 3 else { return ps }
        var out = [ps[0]]
        for i in 1..<(ps.count - 1) {
            out.append(CGPoint(x: (ps[i - 1].x + 2 * ps[i].x + ps[i + 1].x) / 4,
                               y: (ps[i - 1].y + 2 * ps[i].y + ps[i + 1].y) / 4))
        }
        out.append(ps[ps.count - 1])
        return out
    }
}

// MARK: - Store

/// Annotation mode: the canvas pauses, the marks are drawn over it, and "Add to chat" sends the frame with
/// the marks to Claude as an image attachment. Nothing here touches the scene.
@Observable
final class AnnotationStore {
    static let shared = AnnotationStore()

    enum Tool { case select, pen, shape, text }

    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.90, green: 0.24, blue: 0.23, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // purple
        .white,
        .black,
    ]
    /// On-screen line widths in points.
    static let widths: [Double] = [2, 4, 6, 10]

    private(set) var isActive = false
    var tool: Tool = .pen { didSet { if tool != oldValue { finishText(); if tool != .select { selection = nil } } } }
    var shape: Annotation.ShapeKind = .rect
    var color: NSColor = AnnotationStore.colors[0] {
        didSet { restyleSelection { $0.color = self.color } }
    }
    var width: Double = 4
    private(set) var items: [Annotation] = []
    var selection: UUID?
    /// The mark being drawn (not in `items` yet).
    var draft: Annotation?
    /// The text mark being typed; it stays in `items` (drawn by the text field instead) until finished.
    private(set) var editingText: UUID?
    var textDraft = ""
    var isSending = false

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { items.isEmpty && draft == nil }

    func begin() {
        SceneStore.shared.pause()
        isActive = true
    }

    func close() {
        isActive = false
        items = []
        draft = nil
        selection = nil
        editingText = nil
        textDraft = ""
        undoStack = []
        redoStack = []
    }

    /// Line width (or font size) in scene units for a canvas showing `unit` points per scene unit.
    func sceneSize(unit: Double, forText: Bool) -> Double {
        (forText ? 12 + width * 2.2 : width) / max(unit, 0.0001)
    }

    // MARK: Edits (each is one undo step)

    func record() {
        undoStack.append(items)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
    }

    func add(_ a: Annotation) {
        record()
        items.append(a)
    }

    /// Moves a mark during a drag; call `record()` once when the drag starts.
    func replace(_ a: Annotation) {
        if let i = items.firstIndex(where: { $0.id == a.id }) { items[i] = a }
    }

    func undo() {
        finishText()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(items)
        items = prev
        dropStaleSelection()
    }

    func redo() {
        finishText()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        dropStaleSelection()
    }

    /// Deletes the selected mark, or every mark when none is selected.
    func delete() {
        finishText()
        guard !items.isEmpty else { return }
        record()
        if let id = selection {
            items.removeAll { $0.id == id }
            selection = nil
        } else {
            items = []
        }
    }

    func hit(_ p: CGPoint, tolerance: Double) -> Annotation? {
        items.last { $0.hit(p, tolerance: tolerance) }
    }

    private func dropStaleSelection() {
        if let s = selection, !items.contains(where: { $0.id == s }) { selection = nil }
    }

    private func restyleSelection(_ change: (inout Annotation) -> Void) {
        guard let id = selection ?? editingText, let i = items.firstIndex(where: { $0.id == id }) else { return }
        var a = items[i]
        change(&a)
        guard a != items[i] else { return }
        if editingText == nil { record() }
        items[i] = a
    }

    /// Applies the chosen width to the selected mark (font size for text).
    func setWidth(_ w: Double, unit: Double) {
        width = w
        restyleSelection { a in
            if case .text = a.kind { a.size = self.sceneSize(unit: unit, forText: true) }
            else { a.size = self.sceneSize(unit: unit, forText: false) }
        }
    }

    // MARK: Text

    func startText(at p: CGPoint, unit: Double) {
        finishText()
        let a = Annotation(kind: .text("", p), color: color, size: sceneSize(unit: unit, forText: true))
        record()
        items.append(a)
        editingText = a.id
        textDraft = ""
    }

    func editText(_ a: Annotation) {
        guard case let .text(s, _) = a.kind else { return }
        finishText()
        record()
        editingText = a.id
        textDraft = s
        selection = nil
    }

    /// Ends typing: keeps the text, or drops the mark if it is empty.
    func finishText() {
        guard let id = editingText else { return }
        editingText = nil
        textFinished = Date()
        guard let i = items.firstIndex(where: { $0.id == id }), case let .text(_, p) = items[i].kind else { return }
        let s = textDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        textDraft = ""
        if s.isEmpty {
            items.remove(at: i)
        } else {
            items[i].kind = .text(s, p)
        }
        // Typing nothing (or leaving a note as it was) is not an edit worth undoing.
        if undoStack.last == items { undoStack.removeLast() }
    }

    /// When typing last ended: the click that ends it should not also start a new note.
    private(set) var textFinished = Date.distantPast

    // MARK: Send

    /// Renders the current frame at up to 1600 px with the marks on top and attaches it to the chat.
    func addToChat(scene: MotionScene, time: Double, completion: @escaping (Bool) -> Void) {
        finishText()
        draft = nil
        let marks = items
        isSending = true
        let scale = min(1, 1600 / Double(max(scene.width, scene.height, 1)))
        DispatchQueue.global(qos: .userInitiated).async {
            let frame = AudioAnalysisCache.withoutWaiting {
                FrameRenderer().makeImage(scene, at: time, scale: scale)
            }
            let data = frame.flatMap { Self.compose($0, marks: marks, scale: scale) }
            DispatchQueue.main.async {
                self.isSending = false
                guard let data, let image = NSImage(data: data) else { completion(false); return }
                let note = marks.isEmpty
                    ? String(format: "[Attached: the canvas frame at %.2fs.]", time)
                    : String(format: "[Attached: the canvas frame at %.2fs with my annotations drawn on top. "
                        + "The marks (outlines, arrows, scribbles, notes) point at what I mean; they are not part of the scene.]",
                        time)
                ChatStore.shared.attachAnnotatedFrame(data, image: image, time: time, note: note)
                self.close()
                completion(true)
            }
        }
    }

    private static func compose(_ frame: CGImage, marks: [Annotation], scale: Double) -> Data? {
        let w = frame.width, h = frame.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // JPEG has no alpha: transparent scenes go on black, like the exported .mp4.
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        for m in marks { m.draw(in: ctx) }
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}

// MARK: - Overlay

/// Sits exactly over the canvas image; draws the marks and turns drags into them.
struct AnnotationOverlay: View {
    let annotations: AnnotationStore
    /// Canvas points per scene unit.
    let unit: Double
    @FocusState private var textFocused: Bool
    @State private var drag: (start: CGPoint, original: Annotation, moved: Bool)?
    @State private var dragging = false

    var body: some View {
        @Bindable var annotations = annotations
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                ctx.withCGContext { cg in
                    cg.scaleBy(x: unit, y: unit)
                    for a in annotations.items where a.id != annotations.editingText { a.draw(in: cg) }
                    annotations.draft?.draw(in: cg)
                }
            }
            if annotations.tool == .select, let id = annotations.selection,
               let a = annotations.items.first(where: { $0.id == id }) {
                let b = a.bounds
                Rectangle()
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: b.width * unit + 8, height: b.height * unit + 8)
                    .offset(x: b.minX * unit - 4, y: b.minY * unit - 4)
                    .allowsHitTesting(false)
            }
            if let id = annotations.editingText, let a = annotations.items.first(where: { $0.id == id }),
               case let .text(_, p) = a.kind {
                TextField("", text: $annotations.textDraft, prompt: Text("Type a note").foregroundColor(Color(nsColor: a.color).opacity(0.5)))
                    .textFieldStyle(.plain)
                    .font(Font(Annotation.font(a.size * unit)))
                    .foregroundStyle(Color(nsColor: a.color))
                    .shadow(color: Color(nsColor: Annotation.contrast(a.color)), radius: 1.5)
                    .fixedSize()
                    .frame(minWidth: 120, alignment: .leading)
                    .focused($textFocused)
                    .onSubmit { annotations.finishText() }
                    .offset(x: p.x * unit, y: p.y * unit)
                    .onAppear { DispatchQueue.main.async { textFocused = true } }
                    .onChange(of: textFocused) { _, focused in if !focused { annotations.finishText() } }
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged(changed).onEnded(ended))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
            guard annotations.tool == .select, let a = annotations.hit(scenePoint(v.location), tolerance: 6 / unit),
                  case .text = a.kind else { return }
            annotations.editText(a)
        })
        .onContinuousHover { phase in
            switch phase {
            case .active:
                switch annotations.tool {
                case .select: NSCursor.arrow.set()
                case .pen, .shape: NSCursor.crosshair.set()
                case .text: NSCursor.iBeam.set()
                }
            case .ended: NSCursor.arrow.set()
            }
        }
        .clipped()
    }

    private func scenePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / unit, y: p.y / unit) }

    private func changed(_ v: DragGesture.Value) {
        let p = scenePoint(v.location)
        if !dragging {
            dragging = true
            let start = scenePoint(v.startLocation)
            switch annotations.tool {
            case .select:
                if let a = annotations.hit(start, tolerance: 6 / unit) {
                    annotations.selection = a.id
                    drag = (start, a, false)
                } else {
                    annotations.selection = nil
                }
            case .pen:
                annotations.draft = Annotation(kind: .stroke([start]), color: annotations.color,
                                               size: annotations.sceneSize(unit: unit, forText: false))
            case .shape:
                annotations.draft = Annotation(kind: .shape(annotations.shape, start, start), color: annotations.color,
                                               size: annotations.sceneSize(unit: unit, forText: false))
            case .text:
                break
            }
        }
        switch annotations.tool {
        case .select:
            guard var d = drag else { return }
            let delta = CGSize(width: p.x - d.start.x, height: p.y - d.start.y)
            if !d.moved {
                guard hypot(delta.width, delta.height) * unit >= 2 else { return } // a click only selects
                annotations.record() // one undo step for the whole drag
                d.moved = true
                drag = d
            }
            annotations.replace(d.original.moved(by: delta))
        case .pen:
            if case var .stroke(ps)? = annotations.draft?.kind {
                if let last = ps.last, hypot(last.x - p.x, last.y - p.y) * unit < 1 { return }
                ps.append(p)
                annotations.draft?.kind = .stroke(ps)
            }
        case .shape:
            if case let .shape(k, a, _)? = annotations.draft?.kind {
                var q = p
                // ⇧ keeps squares/circles, and 45° steps for lines and arrows.
                if NSEvent.modifierFlags.contains(.shift) { q = constrained(a, p, kind: k) }
                annotations.draft?.kind = .shape(k, a, q)
            }
        case .text:
            break
        }
    }

    private func ended(_ v: DragGesture.Value) {
        defer { dragging = false; drag = nil }
        switch annotations.tool {
        case .select:
            break
        case .pen:
            if let d = annotations.draft { annotations.add(d) }
            annotations.draft = nil
        case .shape:
            if let d = annotations.draft, case let .shape(_, a, b) = d.kind, hypot(b.x - a.x, b.y - a.y) * unit >= 3 {
                annotations.add(d)
            }
            annotations.draft = nil
        case .text:
            let p = scenePoint(v.location)
            if annotations.editingText != nil || Date().timeIntervalSince(annotations.textFinished) < 0.5 {
                annotations.finishText() // a click away from the field only ends typing
            } else if let a = annotations.hit(p, tolerance: 4 / unit), case .text = a.kind {
                annotations.editText(a)
            } else {
                // Click lands mid-line, so the text starts a little above it.
                annotations.startText(at: CGPoint(x: p.x, y: p.y - annotations.sceneSize(unit: unit, forText: true) * 0.6),
                                      unit: unit)
            }
        }
    }

    private func constrained(_ a: CGPoint, _ p: CGPoint, kind: Annotation.ShapeKind) -> CGPoint {
        let dx = p.x - a.x, dy = p.y - a.y
        switch kind {
        case .rect, .ellipse:
            let s = max(abs(dx), abs(dy))
            return CGPoint(x: a.x + (dx < 0 ? -s : s), y: a.y + (dy < 0 ? -s : s))
        case .arrow, .line:
            let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: a.x + cos(ang) * len, y: a.y + sin(ang) * len)
        }
    }
}

// MARK: - Toolbar

/// Floating bar over the canvas: tools · color · width · undo/redo/delete · Add to chat · close.
struct AnnotationToolbar: View {
    @Environment(SceneStore.self) private var store
    let annotations: AnnotationStore
    let unit: Double
    @AppStorage("ui.rightPanelTab") private var rightTab: RightPanelTab = .claude
    @AppStorage("showInspector") private var showInspector = true
    @State private var showColors = false
    @State private var showWidths = false

    var body: some View {
        HStack(spacing: 4) {
            tool(.select, "cursorarrow", help: "Select and move marks (double-click a note to edit it)")
            tool(.pen, "pencil", help: "Draw freehand")
            HStack(spacing: 0) {
                tool(.shape, annotations.shape.symbol, help: "Draw a \(annotations.shape.title.lowercased()) (⇧ to constrain)")
                Menu {
                    ForEach(Annotation.ShapeKind.allCases, id: \.self) { k in
                        Button { annotations.shape = k; annotations.tool = .shape } label: {
                            Label(k.title, systemImage: k.symbol)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Shape")
            }
            tool(.text, "textformat", help: "Add a text note")

            divider

            Button { showColors.toggle() } label: {
                HStack(spacing: 4) {
                    Circle().fill(Color(nsColor: annotations.color))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                        .frame(width: 18, height: 18)
                    chevron
                }
                .frame(height: 30).padding(.horizontal, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Color")
            .popover(isPresented: $showColors, arrowEdge: .bottom) { colorGrid }

            Button { showWidths.toggle() } label: {
                HStack(spacing: 6) {
                    Capsule().fill(Color.primary).frame(width: 26, height: max(1.5, annotations.width * 0.6))
                    chevron
                }
                .frame(height: 30).padding(.horizontal, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Line width and text size")
            .popover(isPresented: $showWidths, arrowEdge: .bottom) { widthList }

            divider

            iconButton("arrow.uturn.backward", help: "Undo (⌘Z)", disabled: !annotations.canUndo) { annotations.undo() }
            iconButton("arrow.uturn.forward", help: "Redo (⇧⌘Z)", disabled: !annotations.canRedo) { annotations.redo() }
            iconButton("trash", help: annotations.selection != nil ? "Delete the selected mark (⌘⌫)" : "Clear all marks",
                       disabled: annotations.items.isEmpty) { annotations.delete() }

            Button { send() } label: {
                HStack(spacing: 6) {
                    if annotations.isSending { ProgressView().controlSize(.small) }
                    Text("Add to chat")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(annotations.isSending)
            .padding(.leading, 6)
            .help("Attach this frame with your marks to the Claude chat")

            iconButton("xmark", help: "Close (Esc)", disabled: false) { annotations.close() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize()
    }

    private func send() {
        annotations.addToChat(scene: store.scene, time: store.time) { ok in
            if ok {
                withAnimation(.easeOut(duration: 0.2)) { showInspector = true }
                rightTab = .claude
            } else {
                store.message = "Could not render the frame for the chat."
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 20).padding(.horizontal, 6)
    }

    private func tool(_ t: AnnotationStore.Tool, _ symbol: String, help: String) -> some View {
        let on = annotations.tool == t
        return Button { annotations.tool = t } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 30)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.primary)
        .disabled(disabled)
        .help(help)
    }

    private var colorGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 4), spacing: 8) {
            ForEach(Array(AnnotationStore.colors.enumerated()), id: \.offset) { _, c in
                Button { annotations.color = c; showColors = false } label: {
                    Circle().fill(Color(nsColor: c))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                            .opacity(c == annotations.color ? 1 : 0))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    private var widthList: some View {
        VStack(spacing: 2) {
            ForEach(AnnotationStore.widths, id: \.self) { w in
                Button { annotations.setWidth(w, unit: unit); showWidths = false } label: {
                    HStack {
                        Capsule().fill(Color.primary).frame(width: 60, height: w)
                        Spacer(minLength: 10)
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                            .opacity(annotations.width == w ? 1 : 0)
                    }
                    .padding(.horizontal, 10).frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 120)
    }
}
