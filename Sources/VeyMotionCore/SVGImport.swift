import CoreGraphics
import Foundation

// Imports an SVG as editable layers: every <path>, <rect>, <circle>, <ellipse>, <line>, <polyline>, <polygon>
// becomes a path layer (d, fill, stroke, opacity, fill rule, caps/joins, gradients), every <g> a group, so the
// parts of an illustration can be animated on their own. Transforms are baked into the points; the whole
// drawing is scaled to `width`/`height` (or 1:1 in scene px) and centered on x/y. Children use scene coordinates
// like every group in VeyMotion. Not handled: <text>, <image>, <use>, clip paths, masks, filters, CSS <style>.

public struct SVGImportOptions: Sendable {
    public var id = "vector"
    public var x: Double
    public var y: Double
    /// Target size in scene px; nil keeps the SVG's own units (viewBox) as px, one of them keeps the aspect.
    public var width: Double?
    public var height: Double?
    /// Put every shape directly in one group (no nested groups).
    public var flatten = false

    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum SVGImport {
    public struct Summary {
        public var group: MotionLayer
        public var shapes: Int
        public var groups: Int
        public var skipped: [String]
    }

    /// Builds a group layer from SVG data. Throws when the file is not SVG.
    public static func group(from data: Data, options o: SVGImportOptions) throws -> Summary {
        let doc = try SVGDocument(data: data)
        guard let root = doc.root else { throw SceneError.invalid("Not an SVG file (no <svg> element)") }
        // Document box: viewBox, else width/height, else the drawing's bounds.
        var box = doc.viewBox ?? CGRect(x: 0, y: 0, width: doc.width ?? 0, height: doc.height ?? 0)
        var builder = Builder(doc: doc, base: o.id, flatten: o.flatten)
        var items = builder.build(root.children, transform: .identity)
        if box.width <= 0 || box.height <= 0 {
            let all = Builder.allShapes(items).reduce(CGRect.null) { $0.union($1.bounds) }
            box = all.isNull ? CGRect(x: 0, y: 0, width: 100, height: 100) : all
        }
        // Fit: scale the document box to the wanted size, centered on x/y.
        var sx = 1.0, sy = 1.0
        if let w = o.width, let h = o.height { sx = w / box.width; sy = h / box.height }
        else if let w = o.width { sx = w / box.width; sy = sx }
        else if let h = o.height { sy = h / box.height; sx = sy }
        let fit = CGAffineTransform(translationX: o.x, y: o.y)
            .scaledBy(x: sx, y: sy)
            .translatedBy(x: -box.midX, y: -box.midY)
        Builder.apply(fit, to: &items)
        let scaleForStroke = (abs(sx) + abs(sy)) / 2
        var group = MotionLayer(id: o.id, name: o.id, type: .group, x: o.x, y: o.y)
        group.children = Builder.layers(items, strokeScale: scaleForStroke)
        return Summary(group: group, shapes: Builder.allShapes(items).count,
                       groups: Builder.countGroups(items), skipped: builder.skipped)
    }

    // MARK: - Intermediate tree

    enum Item {
        case shape(Shape)
        case group(id: String, name: String, opacity: Double, children: [Item])
    }

    struct Shape {
        var id: String
        var name: String
        var path: PathShape
        var fill: RGBA?
        var fillGradient: Gradient?
        var stroke: RGBA?
        var strokeWidth: Double
        var opacity: Double
        var fillRule: FillRule
        var lineCap: LineCap?
        var lineJoin: LineJoin?
        var dash: [Double]

        var bounds: CGRect { path.cgPath.boundingBoxOfPath }
    }

    struct Builder {
        let doc: SVGDocument
        let base: String
        let flatten: Bool
        var counter = 0
        var skipped: [String] = []
        var usedIds = Set<String>()

        init(doc: SVGDocument, base: String, flatten: Bool) { self.doc = doc; self.base = base; self.flatten = flatten }

        mutating func nextId(_ wanted: String?, kind: String) -> String {
            var id = (wanted ?? "").trimmingCharacters(in: .whitespaces)
            if id.isEmpty { counter += 1; id = "\(base)-\(kind)\(counter)" }
            else { id = "\(base)-\(id)" }
            var candidate = id, n = 2
            while usedIds.contains(candidate) { candidate = "\(id)-\(n)"; n += 1 }
            usedIds.insert(candidate)
            return candidate
        }

        mutating func build(_ nodes: [SVGNode], transform: CGAffineTransform, inherited: Style = Style()) -> [Item] {
            var out: [Item] = []
            for n in nodes {
                let style = inherited.merged(with: Style(node: n, doc: doc))
                if style.hidden { continue }
                let t = SVGTransform.parse(n.attrs["transform"]).concatenating(transform)
                switch n.name {
                case "g":
                    let children = build(n.children, transform: t, inherited: style.forChildren())
                    if children.isEmpty { continue }
                    if flatten { out.append(contentsOf: children) }
                    else {
                        let id = nextId(n.attrs["id"], kind: "g")
                        out.append(.group(id: id, name: n.attrs["id"] ?? "Group", opacity: style.opacity, children: children))
                    }
                case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
                    guard let d = Self.pathData(n), var shape = try? PathShape(d) else { skipped.append(n.name); continue }
                    shape = shape.applying(t)
                    if shape.isEmpty { continue }
                    let hasFill = style.fill != nil || style.fillGradient != nil
                    let hasStroke = style.stroke != nil && style.strokeWidth > 0
                    guard hasFill || hasStroke else { continue }
                    let id = nextId(n.attrs["id"], kind: n.name)
                    let sw = style.strokeWidth * sqrt(abs(t.a * t.d - t.b * t.c))
                    out.append(.shape(Shape(id: id, name: n.attrs["id"] ?? n.name.capitalized, path: shape,
                                            fill: style.fill, fillGradient: style.fillGradient,
                                            stroke: hasStroke ? style.stroke : nil, strokeWidth: sw,
                                            opacity: style.opacity, fillRule: style.fillRule,
                                            lineCap: style.lineCap, lineJoin: style.lineJoin, dash: style.dash)))
                case "defs", "style", "title", "desc", "metadata", "linearGradient", "radialGradient", "clipPath", "mask", "filter", "symbol", "marker", "pattern":
                    continue
                case "svg", "a", "switch":
                    out.append(contentsOf: build(n.children, transform: t, inherited: style.forChildren()))
                default:
                    skipped.append(n.name)
                }
            }
            return out
        }

        static func pathData(_ n: SVGNode) -> String? {
            func num(_ k: String, _ d: Double = 0) -> Double { SVGLength.parse(n.attrs[k]) ?? d }
            switch n.name {
            case "path": return n.attrs["d"]
            case "rect":
                let x = num("x"), y = num("y"), w = num("width"), h = num("height")
                guard w > 0, h > 0 else { return nil }
                var rx = num("rx", -1), ry = num("ry", -1)
                if rx < 0 && ry < 0 { rx = 0; ry = 0 } else if rx < 0 { rx = ry } else if ry < 0 { ry = rx }
                rx = min(rx, w / 2); ry = min(ry, h / 2)
                if rx <= 0 || ry <= 0 { return "M\(x) \(y) H\(x + w) V\(y + h) H\(x) Z" }
                return "M\(x + rx) \(y) H\(x + w - rx) A\(rx) \(ry) 0 0 1 \(x + w) \(y + ry) V\(y + h - ry) A\(rx) \(ry) 0 0 1 \(x + w - rx) \(y + h) H\(x + rx) A\(rx) \(ry) 0 0 1 \(x) \(y + h - ry) V\(y + ry) A\(rx) \(ry) 0 0 1 \(x + rx) \(y) Z"
            case "circle":
                let cx = num("cx"), cy = num("cy"), r = num("r")
                guard r > 0 else { return nil }
                return ellipse(cx, cy, r, r)
            case "ellipse":
                let cx = num("cx"), cy = num("cy"), rx = num("rx"), ry = num("ry")
                guard rx > 0, ry > 0 else { return nil }
                return ellipse(cx, cy, rx, ry)
            case "line":
                return "M\(num("x1")) \(num("y1")) L\(num("x2")) \(num("y2"))"
            case "polyline", "polygon":
                let nums = (n.attrs["points"] ?? "").components(separatedBy: CharacterSet(charactersIn: " ,\n\t\r")).compactMap(Double.init)
                guard nums.count >= 4 else { return nil }
                var s = "M\(nums[0]) \(nums[1])"
                var i = 2
                while i + 1 < nums.count { s += " L\(nums[i]) \(nums[i + 1])"; i += 2 }
                return n.name == "polygon" ? s + " Z" : s
            default: return nil
            }
        }

        static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> String {
            let k = 0.5522847498
            return "M\(cx + rx) \(cy) C\(cx + rx) \(cy + ry * k) \(cx + rx * k) \(cy + ry) \(cx) \(cy + ry) "
                + "C\(cx - rx * k) \(cy + ry) \(cx - rx) \(cy + ry * k) \(cx - rx) \(cy) "
                + "C\(cx - rx) \(cy - ry * k) \(cx - rx * k) \(cy - ry) \(cx) \(cy - ry) "
                + "C\(cx + rx * k) \(cy - ry) \(cx + rx) \(cy - ry * k) \(cx + rx) \(cy) Z"
        }

        static func allShapes(_ items: [Item]) -> [Shape] {
            items.flatMap { i -> [Shape] in
                switch i { case let .shape(s): return [s]; case let .group(_, _, _, c): return allShapes(c) }
            }
        }

        static func countGroups(_ items: [Item]) -> Int {
            items.reduce(0) { acc, i in
                if case let .group(_, _, _, c) = i { return acc + 1 + countGroups(c) }
                return acc
            }
        }

        static func apply(_ t: CGAffineTransform, to items: inout [Item]) {
            for i in items.indices {
                switch items[i] {
                case var .shape(s):
                    s.path = s.path.applying(t)
                    s.strokeWidth *= sqrt(abs(t.a * t.d - t.b * t.c))
                    items[i] = .shape(s)
                case .group(let id, let name, let op, var c):
                    apply(t, to: &c)
                    items[i] = .group(id: id, name: name, opacity: op, children: c)
                }
            }
        }

        /// Scene layers: each path centered on its bounds, d relative to that center.
        static func layers(_ items: [Item], strokeScale: Double) -> [MotionLayer] {
            items.map { item in
                switch item {
                case let .shape(s):
                    let b = s.bounds
                    let c = CGPoint(x: b.midX, y: b.midY)
                    var l = MotionLayer(id: s.id, name: s.name, type: .path, x: c.x, y: c.y)
                    l.d = .constant(s.path.applying(CGAffineTransform(translationX: -c.x, y: -c.y)).rounded())
                    if let g = s.fillGradient { l.gradient = g; l.fill = .constant(s.fill ?? .white) }
                    else { l.fill = .constant(s.fill ?? .clear) }
                    if let st = s.stroke { l.stroke = .constant(st); l.strokeWidth = .constant(max(0.1, s.strokeWidth)) }
                    if s.opacity < 1 { l.opacity = .constant(s.opacity) }
                    l.fillRule = s.fillRule
                    l.lineCap = s.lineCap
                    l.lineJoin = s.lineJoin
                    if !s.dash.isEmpty { l.dash = s.dash.map { $0 * strokeScale } }
                    return l
                case let .group(id, name, opacity, children):
                    let kids = layers(children, strokeScale: strokeScale)
                    let b = kids.reduce(CGRect.null) { $0.union(CGRect(x: $1.x.value(at: 0), y: $1.y.value(at: 0), width: 0, height: 0)) }
                    var g = MotionLayer(id: id, name: name, type: .group, x: b.isNull ? 0 : b.midX, y: b.isNull ? 0 : b.midY)
                    g.children = kids
                    if opacity < 1 { g.opacity = .constant(opacity) }
                    return g
                }
            }
        }
    }

    // MARK: - Style

    struct Style {
        var fill: RGBA? = .black
        var fillGradient: Gradient?
        var fillSet = false
        var stroke: RGBA?
        var strokeWidth = 1.0
        var opacity = 1.0
        var fillRule = FillRule.nonzero
        var lineCap: LineCap?
        var lineJoin: LineJoin?
        var dash: [Double] = []
        var hidden = false
        var own: [String: String] = [:]

        init() {}

        init(node n: SVGNode, doc: SVGDocument) {
            var a = n.attrs
            // style="fill:#f00; stroke-width:2" wins over presentation attributes.
            if let css = a["style"] {
                for decl in css.split(separator: ";") {
                    let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2 { a[kv[0]] = kv[1] }
                }
            }
            own = a
            fill = nil; fillSet = false
            if let f = a["fill"] {
                fillSet = true
                if f == "none" { fill = nil }
                else if f.hasPrefix("url("), let g = doc.gradient(named: f) { fillGradient = g.gradient; fill = g.average }
                else { fill = SVGColor.parse(f) }
            }
            if let s = a["stroke"] { stroke = s == "none" ? nil : SVGColor.parse(s) }
            if let w = a["stroke-width"], let v = SVGLength.parse(w) { strokeWidth = v }
            var op = 1.0
            if let o = a["opacity"], let v = Double(o) { op *= v }
            opacity = op
            if let fo = a["fill-opacity"], let v = Double(fo), var c = fill { c.a *= v; fill = c }
            if let so = a["stroke-opacity"], let v = Double(so), var c = stroke { c.a *= v; stroke = c }
            if a["fill-rule"] == "evenodd" || a["clip-rule"] == "evenodd" && a["fill-rule"] == nil { fillRule = .evenodd }
            if let c = a["stroke-linecap"] { lineCap = LineCap(rawValue: c) }
            if let j = a["stroke-linejoin"] { lineJoin = LineJoin(rawValue: j) }
            if let d = a["stroke-dasharray"], d != "none" {
                dash = d.components(separatedBy: CharacterSet(charactersIn: " ,")).compactMap { SVGLength.parse($0) }
            }
            if a["display"] == "none" || a["visibility"] == "hidden" { hidden = true }
        }

        /// Child values over inherited ones (fill/stroke inherit; opacity multiplies; fill "none" is explicit).
        func merged(with child: Style) -> Style {
            var s = self
            if child.fillSet { s.fill = child.fill; s.fillGradient = child.fillGradient; s.fillSet = true }
            else if child.own["fill-opacity"] != nil, let v = Double(child.own["fill-opacity"]!), var c = s.fill { c.a *= v; s.fill = c }
            if child.own["stroke"] != nil { s.stroke = child.stroke }
            else if child.own["stroke-opacity"] != nil, let v = Double(child.own["stroke-opacity"]!), var c = s.stroke { c.a *= v; s.stroke = c }
            if child.own["stroke-width"] != nil { s.strokeWidth = child.strokeWidth }
            s.opacity = opacity * child.opacity
            if child.own["fill-rule"] != nil { s.fillRule = child.fillRule }
            if child.lineCap != nil { s.lineCap = child.lineCap }
            if child.lineJoin != nil { s.lineJoin = child.lineJoin }
            if child.own["stroke-dasharray"] != nil { s.dash = child.dash }
            s.hidden = hidden || child.hidden
            s.own = child.own
            return s
        }

        /// What a group's children inherit: the group's own opacity is applied on the group layer, not again.
        func forChildren() -> Style {
            var s = self
            s.opacity = 1
            return s
        }
    }
}

// MARK: - XML

final class SVGNode {
    let name: String
    var attrs: [String: String]
    var children: [SVGNode] = []
    weak var parent: SVGNode?
    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }
}

final class SVGDocument: NSObject, XMLParserDelegate {
    private(set) var root: SVGNode?
    private var stack: [SVGNode] = []
    private var byId: [String: SVGNode] = [:]
    private var error: Error?

    var viewBox: CGRect? {
        guard let vb = root?.attrs["viewBox"] else { return nil }
        let n = vb.components(separatedBy: CharacterSet(charactersIn: " ,")).compactMap(Double.init)
        guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }
    var width: Double? { SVGLength.parse(root?.attrs["width"]) }
    var height: Double? { SVGLength.parse(root?.attrs["height"]) }

    init(data: Data) throws {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        guard parser.parse() || root != nil else {
            throw SceneError.invalid("Could not parse the SVG: \(parser.parserError?.localizedDescription ?? "invalid XML")")
        }
        if root == nil { throw SceneError.invalid("Not an SVG file (no <svg> element)") }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let node = SVGNode(name: name, attrs: attributes)
        if let top = stack.last { top.children.append(node); node.parent = top }
        else if name == "svg" { root = node }
        else if root == nil { root = SVGNode(name: "svg", attrs: [:]); root!.children.append(node) }
        if let id = attributes["id"] { byId[id] = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        _ = stack.popLast()
    }

    /// A fill of `url(#id)`: the gradient and an average color for fallbacks.
    func gradient(named ref: String) -> (gradient: Gradient, average: RGBA)? {
        guard let open = ref.firstIndex(of: "#") else { return nil }
        let id = ref[ref.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
        guard let node = resolveGradient(id, depth: 0) else { return nil }
        var stops: [GradientStop] = []
        var src = node
        // Stops may live on a referenced gradient (xlink:href).
        var hops = 0
        while src.children.filter({ $0.name == "stop" }).isEmpty, hops < 4,
              let href = src.attrs["href"] ?? src.attrs["xlink:href"], href.hasPrefix("#"), let r = byId[String(href.dropFirst())] {
            src = r; hops += 1
        }
        for s in src.children where s.name == "stop" {
            var a = s.attrs
            if let css = a["style"] {
                for decl in css.split(separator: ";") {
                    let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2 { a[kv[0]] = kv[1] }
                }
            }
            var off = 0.0
            if let o = a["offset"] {
                if o.hasSuffix("%") { off = (Double(o.dropLast()) ?? 0) / 100 } else { off = Double(o) ?? 0 }
            }
            var c = SVGColor.parse(a["stop-color"] ?? "#000000") ?? .black
            if let so = a["stop-opacity"], let v = Double(so) { c.a *= v }
            stops.append(GradientStop(offset: min(max(off, 0), 1), color: c))
        }
        guard stops.count >= 2 else { return nil }
        var g: Gradient
        if node.name == "radialGradient" {
            g = Gradient(type: .radial, stops: stops)
        } else {
            func pct(_ s: String?, _ d: Double) -> Double {
                guard let s else { return d }
                if s.hasSuffix("%") { return (Double(s.dropLast()) ?? d * 100) / 100 }
                return Double(s) ?? d
            }
            let x1 = pct(node.attrs["x1"], 0), y1 = pct(node.attrs["y1"], 0), x2 = pct(node.attrs["x2"], 1), y2 = pct(node.attrs["y2"], 0)
            let angle = atan2(y2 - y1, x2 - x1) * 180 / .pi
            g = Gradient(type: .linear, stops: stops, angle: angle)
        }
        let avg = stops.reduce(RGBA(r: 0, g: 0, b: 0, a: 0)) { acc, s in
            RGBA(r: acc.r + s.color.r / Double(stops.count), g: acc.g + s.color.g / Double(stops.count),
                 b: acc.b + s.color.b / Double(stops.count), a: acc.a + s.color.a / Double(stops.count))
        }
        return (g, avg)
    }

    private func resolveGradient(_ id: String, depth: Int) -> SVGNode? {
        guard let n = byId[id], ["linearGradient", "radialGradient"].contains(n.name) else { return nil }
        return n
    }
}

// MARK: - Small parsers

enum SVGLength {
    /// "12", "12px", "1.5em" (16 px), "50%" (nil: percentages need a reference box).
    static func parse(_ s: String?) -> Double? {
        guard var v = s?.trimmingCharacters(in: .whitespaces), !v.isEmpty, !v.hasSuffix("%") else { return nil }
        var factor = 1.0
        for (unit, f) in [("px", 1.0), ("pt", 1.333), ("mm", 3.78), ("cm", 37.8), ("in", 96.0), ("em", 16.0), ("rem", 16.0)] where v.hasSuffix(unit) {
            v = String(v.dropLast(unit.count)); factor = f; break
        }
        return Double(v).map { $0 * factor }
    }
}

enum SVGColor {
    static let named: [String: String] = [
        "black": "#000000", "white": "#FFFFFF", "red": "#FF0000", "green": "#008000", "blue": "#0000FF", "yellow": "#FFFF00",
        "cyan": "#00FFFF", "aqua": "#00FFFF", "magenta": "#FF00FF", "fuchsia": "#FF00FF", "gray": "#808080", "grey": "#808080",
        "silver": "#C0C0C0", "maroon": "#800000", "olive": "#808000", "lime": "#00FF00", "teal": "#008080", "navy": "#000080",
        "purple": "#800080", "orange": "#FFA500", "pink": "#FFC0CB", "brown": "#A52A2A", "gold": "#FFD700", "coral": "#FF7F50",
        "salmon": "#FA8072", "tomato": "#FF6347", "crimson": "#DC143C", "indigo": "#4B0082", "violet": "#EE82EE",
        "turquoise": "#40E0D0", "skyblue": "#87CEEB", "lightgray": "#D3D3D3", "lightgrey": "#D3D3D3", "darkgray": "#A9A9A9",
        "darkgrey": "#A9A9A9", "dimgray": "#696969", "beige": "#F5F5DC", "ivory": "#FFFFF0", "khaki": "#F0E68C",
        "lavender": "#E6E6FA", "tan": "#D2B48C", "chocolate": "#D2691E", "orchid": "#DA70D6", "plum": "#DDA0DD",
    ]

    static func parse(_ raw: String) -> RGBA? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "none" || s == "transparent" { return nil }
        if s == "currentcolor" { return .black }
        if s.hasPrefix("#") {
            if s.count == 4 || s.count == 5 { // #rgb / #rgba
                let e = s.dropFirst().map { "\($0)\($0)" }.joined()
                return RGBA(hex: "#" + e)
            }
            return RGBA(hex: s)
        }
        if s.hasPrefix("rgb") {
            let inner = s.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
            let parts = inner.components(separatedBy: CharacterSet(charactersIn: ", /")).filter { !$0.isEmpty }
            guard parts.count >= 3 else { return nil }
            func ch(_ p: String) -> Double { p.hasSuffix("%") ? (Double(p.dropLast()) ?? 0) / 100 : (Double(p) ?? 0) / 255 }
            var a = 1.0
            if parts.count >= 4 { a = parts[3].hasSuffix("%") ? (Double(parts[3].dropLast()) ?? 100) / 100 : (Double(parts[3]) ?? 1) }
            return RGBA(r: ch(parts[0]), g: ch(parts[1]), b: ch(parts[2]), a: a)
        }
        if let hex = named[s] { return RGBA(hex: hex) }
        return nil
    }
}

enum SVGTransform {
    /// "translate(10 20) rotate(45) scale(2)" → one affine transform (applied right to left, as SVG does).
    static func parse(_ s: String?) -> CGAffineTransform {
        guard let s, !s.isEmpty else { return .identity }
        var result = CGAffineTransform.identity
        let scanner = Scanner(string: s)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\t\r")
        while !scanner.isAtEnd {
            guard let name = scanner.scanCharacters(from: .letters), scanner.scanString("(") != nil else { break }
            var nums: [Double] = []
            while let v = scanner.scanDouble() { nums.append(v) }
            _ = scanner.scanString(")")
            var t = CGAffineTransform.identity
            switch name {
            case "matrix" where nums.count == 6:
                t = CGAffineTransform(a: nums[0], b: nums[1], c: nums[2], d: nums[3], tx: nums[4], ty: nums[5])
            case "translate":
                t = CGAffineTransform(translationX: nums.first ?? 0, y: nums.count > 1 ? nums[1] : 0)
            case "scale":
                let sx = nums.first ?? 1
                t = CGAffineTransform(scaleX: sx, y: nums.count > 1 ? nums[1] : sx)
            case "rotate":
                let a = (nums.first ?? 0) * .pi / 180
                if nums.count >= 3 {
                    t = CGAffineTransform(translationX: nums[1], y: nums[2]).rotated(by: a).translatedBy(x: -nums[1], y: -nums[2])
                } else { t = CGAffineTransform(rotationAngle: a) }
            case "skewX":
                t = CGAffineTransform(a: 1, b: 0, c: tan((nums.first ?? 0) * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewY":
                t = CGAffineTransform(a: 1, b: tan((nums.first ?? 0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: break
            }
            // SVG applies the list left to right to the coordinate system, i.e. the point goes through the
            // last one first: point × t_n × … × t_1. CGAffineTransform concatenation: (A.concat(B)) = A then B.
            result = t.concatenating(result)
        }
        return result
    }
}

extension PathShape {
    /// Every point mapped through an affine transform (keeps the segment structure).
    public func applying(_ t: CGAffineTransform) -> PathShape {
        func m(_ p: PathPoint) -> PathPoint {
            let q = CGPoint(x: p.x, y: p.y).applying(t)
            return PathPoint(x: q.x, y: q.y)
        }
        return PathShape(subpaths: subpaths.map { s in
            Subpath(start: m(s.start), segments: s.segments.map { CubicSegment(c1: m($0.c1), c2: m($0.c2), p: m($0.p)) }, closed: s.closed)
        })
    }

    /// Coordinates rounded to 0.01 px, so the JSON stays short.
    public func rounded() -> PathShape {
        func r(_ p: PathPoint) -> PathPoint { PathPoint(x: (p.x * 100).rounded() / 100, y: (p.y * 100).rounded() / 100) }
        return PathShape(subpaths: subpaths.map { s in
            Subpath(start: r(s.start), segments: s.segments.map { CubicSegment(c1: r($0.c1), c2: r($0.c2), p: r($0.p)) }, closed: s.closed)
        })
    }
}

extension MotionScene {
    /// Imports an SVG file as a group of path layers on top and returns a summary (group id, counts).
    @discardableResult
    public mutating func importVector(at url: URL, options: SVGImportOptions) throws -> SVGImport.Summary {
        let data = try Data(contentsOf: url)
        var summary = try SVGImport.group(from: data, options: options)
        let id = addLayer(summary.group)
        summary.group = try layer(id)
        return summary
    }
}
