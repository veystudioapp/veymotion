import Foundation

// Ready-made animated pieces (like Premiere's Motion Graphics templates): each is a group of ordinary layers with
// their entrance and exit already keyed, so they can be edited like anything else afterwards.

public enum TemplateKind: String, CaseIterable, Codable, Sendable {
    case lowerThird, callout, subscribe, endCard, titleCard, quote

    public var title: String {
        switch self {
        case .lowerThird: return "Lower Third"
        case .callout: return "Call-out"
        case .subscribe: return "Subscribe Button"
        case .endCard: return "End Card"
        case .titleCard: return "Title Card"
        case .quote: return "Quote"
        }
    }
}

public struct TemplateOptions: Sendable {
    public var title: String?
    public var subtitle: String?
    public var accent: RGBA?
    public var start: Double = 0
    public var duration: Double = 4
    /// Where the template points at or sits (scene px); each kind has a sensible default.
    public var x: Double?
    public var y: Double?
    public var fontName: String?

    public init() {}
}

extension MotionScene {
    /// Adds a template as a group on top and returns its id.
    @discardableResult
    public mutating func addTemplate(_ kind: TemplateKind, id: String?, options o: TemplateOptions) throws -> String {
        try License.require(.templates)
        let w = Double(width), h = Double(height)
        let s = o.start, e = o.start + max(o.duration, 1)
        let accent = o.accent ?? RGBA(hex: "#FF4D6D")!
        let base = id ?? kind.rawValue
        // Child ids: "<group>-<part>" made unique scene-wide by addLayer.
        var children: [MotionLayer] = []
        func text(_ part: String, _ string: String, size: Double, weight: String = "bold", x: Double, y: Double,
                  color: RGBA = .white, align: TextAlign = .center) -> MotionLayer {
            var l = MotionLayer(id: "\(base)-\(part)", name: part.capitalized, type: .text, x: x, y: y)
            l.text = string; l.fontSize = size; l.fontWeight = weight; l.color = .constant(color); l.align = align
            l.fontName = o.fontName
            l.start = s; l.end = e
            return l
        }
        func rect(_ part: String, x: Double, y: Double, w rw: Double, h rh: Double, color: RGBA, radius: Double = 0) -> MotionLayer {
            var l = MotionLayer(id: "\(base)-\(part)", name: part.capitalized, type: .rect, x: x, y: y)
            l.width = .constant(rw); l.height = .constant(rh); l.fill = .constant(color); l.cornerRadius = .constant(radius)
            l.start = s; l.end = e
            return l
        }
        var presets: [(String, Preset, Double, Double)] = [] // (child id, preset, start, duration)
        switch kind {
        case .lowerThird:
            let left = o.x ?? w * 0.06, top = o.y ?? h * 0.78
            let title = o.title ?? "Your Name"
            let tw = max(Double(title.count) * h * 0.034, w * 0.22)
            var panel = rect("panel", x: left + tw / 2 + 24, y: top + h * 0.04, w: tw + 48, h: h * 0.13,
                             color: RGBA(r: 0.05, g: 0.06, b: 0.09, a: 0.82), radius: 10)
            panel.wipeStyle = WipeStyle(type: .linear, angle: 180, feather: 30)
            children.append(panel)
            children.append(rect("bar", x: left + 6, y: top + h * 0.04, w: 12, h: h * 0.13, color: accent, radius: 4))
            children.append(text("title", title, size: h * 0.05, weight: "heavy", x: left + 36 + tw / 2, y: top + h * 0.015,
                                 align: .left))
            children[children.count - 1].maxWidth = tw
            children.append(text("subtitle", o.subtitle ?? "Title · Company", size: h * 0.028, weight: "medium",
                                 x: left + 36 + tw / 2, y: top + h * 0.075, color: RGBA(r: 0.8, g: 0.82, b: 0.88), align: .left))
            children[children.count - 1].maxWidth = tw
            presets = [("bar", .dropIn, s, 0.5), ("panel", .wipeIn, s + 0.1, 0.6), ("title", .textRise, s + 0.25, 0.7),
                       ("subtitle", .fadeIn, s + 0.55, 0.5), ("panel", .wipeOut, e - 0.6, 0.5),
                       ("title", .fadeOut, e - 0.5, 0.4), ("subtitle", .fadeOut, e - 0.55, 0.4), ("bar", .slideOutLeft, e - 0.4, 0.4)]
        case .callout:
            let px = o.x ?? w * 0.42, py = o.y ?? h * 0.5
            let lx = px + w * 0.12, ly = py - h * 0.16
            var dot = MotionLayer(id: "\(base)-dot", name: "Dot", type: .ellipse, x: px, y: py)
            dot.width = .constant(26); dot.height = .constant(26); dot.fill = .constant(accent)
            dot.stroke = .constant(.white); dot.strokeWidth = .constant(4); dot.start = s; dot.end = e
            children.append(dot)
            var line = MotionLayer(id: "\(base)-line", name: "Line", type: .path, x: 0, y: 0)
            line.d = .constant((try? PathShape("M \(px) \(py) L \(px + w * 0.05) \(ly) L \(lx + w * 0.11) \(ly)")) ?? .zero)
            line.fill = .constant(.clear); line.stroke = .constant(.white); line.strokeWidth = .constant(3)
            line.start = s; line.end = e
            children.append(line)
            children.append(text("title", o.title ?? "Look here", size: h * 0.04, weight: "heavy", x: lx + w * 0.11, y: ly - h * 0.035))
            children.append(text("subtitle", o.subtitle ?? "A detail worth noticing", size: h * 0.024, weight: "medium",
                                 x: lx + w * 0.11, y: ly + h * 0.03, color: RGBA(r: 0.85, g: 0.87, b: 0.92)))
            presets = [("dot", .popIn, s, 0.4), ("line", .drawOn, s + 0.2, 0.6), ("title", .textPop, s + 0.6, 0.5),
                       ("subtitle", .fadeIn, s + 0.8, 0.5), ("dot", .pulse, s + 1.4, 0.6),
                       ("title", .fadeOut, e - 0.5, 0.4), ("subtitle", .fadeOut, e - 0.5, 0.4), ("dot", .popOut, e - 0.4, 0.4)]
        case .subscribe:
            let cx = o.x ?? w * 0.5, cy = o.y ?? h * 0.82
            let bw = w * 0.2, bh = h * 0.09
            var button = rect("button", x: cx, y: cy, w: bw, h: bh, color: RGBA(hex: "#FF0033")!, radius: bh / 2)
            let click = s + 1.3
            button.fill = .keyframes([ColorKeyframe(t: click, v: RGBA(hex: "#FF0033")!, easing: .linear),
                                      ColorKeyframe(t: click + 0.1, v: RGBA(hex: "#3A3D46")!, easing: .hold)])
            children.append(button)
            var label = text("label", o.title ?? "SUBSCRIBE", size: bh * 0.4, weight: "heavy", x: cx, y: cy)
            label.end = click + 0.1
            children.append(label)
            var done = text("done", o.subtitle ?? "SUBSCRIBED ✓", size: bh * 0.36, weight: "heavy", x: cx, y: cy)
            done.start = click + 0.1
            children.append(done)
            var cursor = MotionLayer(id: "\(base)-cursor", name: "Cursor", type: .path, x: cx + bw * 0.25, y: cy + bh * 0.9)
            cursor.d = .constant((try? PathShape("M 0 0 L 0 36 L 9 28 L 16 44 L 22 41 L 15 26 L 27 26 Z")) ?? .zero)
            cursor.fill = .constant(.white); cursor.stroke = .constant(.black); cursor.strokeWidth = .constant(2)
            cursor.start = s + 0.5; cursor.end = e
            cursor.x = .keyframes([MotionKeyframe(t: s + 0.5, v: cx + bw * 0.6, easing: .linear),
                                   MotionKeyframe(t: click - 0.15, v: cx + bw * 0.2, easing: .curve(.cubic, .inOut))])
            cursor.y = .keyframes([MotionKeyframe(t: s + 0.5, v: cy + bh * 1.6, easing: .linear),
                                   MotionKeyframe(t: click - 0.15, v: cy + bh * 0.05, easing: .curve(.cubic, .inOut))])
            children.append(cursor)
            presets = [("button", .popIn, s, 0.5), ("label", .fadeIn, s + 0.2, 0.3), ("cursor", .fadeIn, s + 0.5, 0.2),
                       ("button", .pulse, click - 0.05, 0.3), ("done", .popIn, click + 0.1, 0.35),
                       ("button", .popOut, e - 0.4, 0.4), ("done", .fadeOut, e - 0.4, 0.3), ("cursor", .fadeOut, e - 0.5, 0.3)]
        case .endCard:
            children.append(text("title", o.title ?? "Thanks for watching", size: h * 0.07, weight: "heavy",
                                 x: o.x ?? w / 2, y: (o.y ?? h * 0.2)))
            let cardW = w * 0.3, cardH = cardW * 9 / 16, gy = h * 0.55
            for (k, dx) in [-0.19, 0.19].enumerated() {
                var c = rect("video\(k + 1)", x: w / 2 + w * dx, y: gy, w: cardW, h: cardH,
                             color: RGBA(r: 1, g: 1, b: 1, a: 0.08), radius: 16)
                c.stroke = .constant(RGBA(r: 1, g: 1, b: 1, a: 0.5)); c.strokeWidth = .constant(3)
                children.append(c)
                children.append(text("label\(k + 1)", k == 0 ? "Next video" : "Best of", size: h * 0.03, weight: "semibold",
                                     x: w / 2 + w * dx, y: gy + cardH / 2 + h * 0.04, color: RGBA(r: 0.8, g: 0.82, b: 0.88)))
            }
            var sub = MotionLayer(id: "\(base)-sub", name: "Subscribe", type: .ellipse, x: w / 2, y: h * 0.86)
            sub.width = .constant(h * 0.13); sub.height = .constant(h * 0.13); sub.fill = .constant(accent)
            sub.start = s; sub.end = e
            children.append(sub)
            children.append(text("subtext", o.subtitle ?? "Subscribe", size: h * 0.025, weight: "bold", x: w / 2, y: h * 0.86))
            presets = [("title", .textRise, s, 0.7), ("video1", .zoomIn, s + 0.3, 0.6), ("video2", .zoomIn, s + 0.45, 0.6),
                       ("label1", .fadeIn, s + 0.7, 0.4), ("label2", .fadeIn, s + 0.8, 0.4), ("sub", .bounceIn, s + 0.9, 0.7),
                       ("subtext", .fadeIn, s + 1.2, 0.3), ("sub", .heartbeat, s + 2, 1)]
        case .titleCard:
            let cx = o.x ?? w / 2, cy = o.y ?? h * 0.47
            var title = text("title", o.title ?? "THE TITLE", size: h * 0.12, weight: "black", x: cx, y: cy)
            title[.shine] = .constant(1.2)
            title[.shinePosition] = .keyframes([MotionKeyframe(t: s + 0.8, v: -0.3, easing: .linear),
                                                MotionKeyframe(t: s + 2, v: 1.3, easing: .curve(.cubic, .inOut))])
            children.append(title)
            var rule = MotionLayer(id: "\(base)-rule", name: "Rule", type: .path, x: cx, y: cy + h * 0.1)
            rule.d = .constant((try? PathShape("M -\(w * 0.16) 0 L \(w * 0.16) 0")) ?? .zero)
            rule.fill = .constant(.clear); rule.stroke = .constant(accent); rule.strokeWidth = .constant(6)
            rule.start = s; rule.end = e
            children.append(rule)
            children.append(text("subtitle", o.subtitle ?? "A short subtitle", size: h * 0.035, weight: "medium",
                                 x: cx, y: cy + h * 0.16, color: RGBA(r: 0.82, g: 0.84, b: 0.9)))
            presets = [("title", .textFocus, s, 0.9), ("rule", .drawOn, s + 0.4, 0.6), ("subtitle", .slideUp, s + 0.7, 0.6),
                       ("title", .textOut, e - 0.7, 0.6), ("rule", .fadeOut, e - 0.5, 0.4), ("subtitle", .fadeOut, e - 0.6, 0.4)]
        case .quote:
            let cx = o.x ?? w / 2, cy = o.y ?? h * 0.48
            children.append(text("mark", "\u{201C}", size: h * 0.3, weight: "black", x: cx - w * 0.3, y: cy - h * 0.15, color: accent))
            var body = text("body", o.title ?? "Simplicity is the ultimate sophistication.", size: h * 0.06, weight: "semibold",
                            x: cx, y: cy)
            body.maxWidth = w * 0.6
            children.append(body)
            children.append(text("author", "— " + (o.subtitle ?? "Leonardo da Vinci"), size: h * 0.032, weight: "medium",
                                 x: cx, y: cy + h * 0.16, color: RGBA(r: 0.8, g: 0.82, b: 0.88)))
            presets = [("mark", .popIn, s, 0.5), ("body", .textPop, s + 0.3, 1.2), ("author", .fadeIn, s + 1.5, 0.6),
                       ("body", .fadeOut, e - 0.6, 0.5), ("author", .fadeOut, e - 0.6, 0.5), ("mark", .popOut, e - 0.5, 0.4)]
        }
        // The group fills the scene, so children keep scene coordinates.
        var group = MotionLayer(id: base, name: kind.title, type: .group, x: w / 2, y: h / 2)
        group.children = children
        group.start = s
        group.end = e
        let gid = addLayer(group)
        // Children ids may have been suffixed: map "<base>-<part>" → actual id by order.
        let actual = (try? layer(gid))?.children.map(\.id) ?? []
        let wanted = children.map(\.id)
        var ids: [String: String] = [:]
        for (w, a) in zip(wanted, actual) { ids[w] = a }
        for (part, preset, start, d) in presets {
            guard let cid = ids["\(base)-\(part)"] else { continue }
            try applyPreset(preset, to: cid, start: max(start, s), duration: d)
        }
        return gid
    }
}
