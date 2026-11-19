import CoreGraphics
import Foundation

// A deterministic design lint for the agent (check_design, the chat's auto-check after each turn) and the app.
// It has two kinds of findings. Problems (warnings) are what breaks a piece whatever its style: text on the edge,
// melted by goo, gone before it can be read, lost against what is behind it, overlapping or almost aligned, under a
// phone app's buttons; long shadows that stop mid-frame, outlines thickened by scale. Style notes (hints) are the
// defaults of a polished generic look: depth behind a flat background, light on the subject, a chosen font, a type
// hierarchy, ambient motion, eased and staggered entrances, curves instead of bare polygons, few fonts and hues.
// A piece may break any of them on purpose (a flat Swiss poster, a still frame, one type size), so they are listed
// for the agent to weigh, never sent back to be fixed. `DesignCraft.swift` holds the sameness, reading-time and
// picture rules. What it cannot see (does a drawing look right?) goes to `reviewNote`: one frame per section for the
// agent to look at.
// Everything is computed from the scene, so the same report comes out of the CLI, the MCP server and the app.

public struct DesignIssue: Codable, Equatable, Sendable {
    /// `hint` = a style note (a default a piece may break on purpose); `warning`/`error` = a problem to fix.
    public enum Severity: String, Codable, Sendable, Comparable {
        case hint, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
        var rank: Int { switch self { case .hint: return 0; case .warning: return 1; case .error: return 2 } }
    }

    public var severity: Severity
    /// Stable id of the rule, e.g. "flat-background".
    public var code: String
    public var message: String
    public var fix: String
    public var layers: [String]

    public var line: String {
        let who = layers.isEmpty ? "" : " (\(layers.prefix(6).joined(separator: ", "))\(layers.count > 6 ? ", …" : ""))"
        return "[\(severity.rawValue)] \(code): \(message)\(who) → \(fix)"
    }
}

extension RGBA {
    /// Relative luminance (0 black … 1 white), gamma ignored.
    var luminance: Double { r * 0.2126 + g * 0.7152 + b * 0.0722 }
    var saturation: Double { max(r, g, b) - min(r, g, b) }
}

extension MotionScene {
    /// Something covers most of the frame with more than a flat color: a look group, a gradient, an image or
    /// video, a very blurred shape, a full-frame generator or particles.
    public var hasBackgroundDepth: Bool {
        if layers.contains(where: { $0.id == Self.lookGroupId }) { return true }
        let area = Double(width * height)
        for l in allLayers {
            let t = l.start
            switch l.type {
            case .image, .video:
                let w = l.width.map { $0.value(at: t) } ?? Double(width)
                let h = l.height.map { $0.value(at: t) } ?? Double(height)
                if w * h >= area * 0.5 { return true }
            case .rect, .ellipse, .generator:
                let w = l.value(.width, at: t), h = l.value(.height, at: t)
                let big = w * h >= area * 0.5
                if big, l.gradient != nil || l.value(.blur, at: t) >= 60 || l.type == .generator { return true }
            case .particles:
                let w = l.value(.width, at: t), h = l.value(.height, at: t)
                if w * h >= area * 0.3 { return true }
            default:
                break
            }
        }
        return false
    }

    /// Picks a look for the background color (light → clean; gray → studio; else cinematic), takes the accent
    /// from the most saturated color in use, and applies it. Nothing happens when the scene already has depth.
    @discardableResult
    public mutating func applyAutoLook() throws -> LookKind? {
        guard !hasBackgroundDepth, !layers.isEmpty else { return nil }
        let bg = background
        let kind: LookKind = bg.luminance > 0.6 ? .clean : bg.saturation < 0.04 && bg.luminance > 0.04 ? .studio : .cinematic
        var o = LookOptions()
        var best: (RGBA, Double)?
        for l in allLayers where [.text, .rect, .ellipse, .path].contains(l.type) {
            for c in [l.color, l.fill] {
                guard case let .constant(v) = c else { continue }
                if v.saturation > 0.35, v.a > 0.5, best.map({ v.saturation > $0.1 }) ?? true { best = (v, v.saturation) }
            }
        }
        if let (c, _) = best { o.accent = c }
        try applyLook(kind, options: o)
        return kind
    }

    /// Runs every rule. `renderer` is needed for the text-edge rule (it measures the glyphs; without one that
    /// rule uses a rough estimate from fontSize) and for the rules that look at where texts are (`craftIssues`).
    /// `pixels: false` skips the ones that render frames (contrast, busy pictures): for callers that only want a
    /// quick summary on the main thread.
    public func designIssues(renderer: FrameRenderer? = nil, pixels: Bool = true) -> [DesignIssue] {
        var out: [DesignIssue] = []
        let w = Double(width), h = Double(height), area = w * h
        let lookIds: Set<String> = [Self.lookGroupId, Self.lookFinishId]
        // Content layers: everything except the look's own layers and sound.
        var timeOffset: [String: Double] = [:]
        let content = layers.filter { !lookIds.contains($0.id) }.flatMap { l -> [MotionLayer] in
            if l.type == .group {
                if l.localTime { for c in l.children { timeOffset[c.id] = l.start } }
                return [l] + l.children
            }
            return [l]
        }.filter { $0.type != .audio && $0.type != .group }
        guard !content.isEmpty else { return out }
        let texts = content.filter { $0.type == .text && !$0.text.isEmpty }
        func life(_ l: MotionLayer) -> (Double, Double) { (l.start, l.effectiveEnd(sceneDuration: duration)) }
        func mid(_ l: MotionLayer) -> Double { let (a, b) = life(l); return a + max(0, b - a) * 0.6 }
        func big(_ l: MotionLayer) -> Bool {
            switch l.type {
            case .image, .video:
                let lw = l.width.map { $0.value(at: l.start) } ?? w, lh = l.height.map { $0.value(at: l.start) } ?? h
                return lw * lh >= area * 0.5
            case .rect, .ellipse, .generator, .particles:
                return l.value(.width, at: l.start) * l.value(.height, at: l.start) >= area * 0.5
            default: return false
            }
        }

        // 1. Background
        if !hasBackgroundDepth {
            out.append(DesignIssue(severity: .hint, code: "flat-background",
                                   message: "The background is one flat color",
                                   fix: "fine if flatness is the design (posters, Swiss, flat illustration); else give it depth that fits the piece: a texture, a photo, a pattern, a gradient, light, or apply_look for a ready-made one", layers: []))
            // 2. Pure contrast only matters without a backdrop in between.
            let pure = texts.filter { t in
                guard case let .constant(c) = t.color else { return false }
                return (c.luminance > 0.98 && background.luminance < 0.03) || (c.luminance < 0.02 && background.luminance > 0.97)
            }
            if !pure.isEmpty {
                out.append(DesignIssue(severity: .hint, code: "pure-contrast",
                                       message: "Pure white text on pure black (or the reverse)",
                                       fix: "fine for a stark graphic style; for a softer read use a near-white on a near-black (or the reverse)",
                                       layers: pure.map(\.id)))
            }
        }

        // 3. Fonts
        let systemFont = texts.filter { ($0.fontName ?? "").isEmpty }
        if !systemFont.isEmpty {
            out.append(DesignIssue(severity: .hint, code: "system-font",
                                   message: "Text uses the system font",
                                   fix: "if the system font is not a deliberate choice, pick families for the mood (list_fonts, or search_stock kind font + import_stock) and set fontName",
                                   layers: systemFont.map(\.id)))
        }

        // 4. Type hierarchy
        if texts.count >= 3 {
            let sizes = texts.map { $0.fontSize * $0.value(.scale, at: mid($0)) }
            if let lo = sizes.min(), let hi = sizes.max(), hi <= lo * 1.25 {
                out.append(DesignIssue(severity: .hint, code: "flat-type",
                                       message: "All text is about the same size, so nothing reads first",
                                       fix: "if one size is not the idea, let the most important words read first through size, weight or color contrast",
                                       layers: texts.map(\.id)))
            }
        }

        // 5. Light on the subject
        let subjects = content.filter { [.text, .rect, .ellipse, .path, .image].contains($0.type) && !big($0) && $0.matte == nil }
        let matteSources = Set(content.compactMap { $0.matte?.source })
        let unlit = subjects.filter { l in
            guard !matteSources.contains(l.id) else { return false }
            let t = mid(l)
            if l.value(.shadowOpacity, at: t) > 0.05 || l.value(.glow, at: t) > 0.05 || l.gradient != nil
                || l.value(.outline, at: t) > 0 || l.value(.innerGlow, at: t) > 0 || l.threeD || l.value(.shine, at: t) > 0 {
                return false
            }
            if l.type == .path || l.type == .rect || l.type == .ellipse, l.stroke != nil { return false }
            return true
        }
        if unlit.count >= 2, Double(unlit.count) >= Double(subjects.count) * 0.6 {
            out.append(DesignIssue(severity: .hint, code: "unlit",
                                   message: "Most layers sit flat on the background (no shadow, glow or gradient)",
                                   fix: "fine for flat design; for a lit look give the subject a shadow, glow, gradient or outline",
                                   layers: unlit.map(\.id)))
        }

        // 6. Frozen stretches
        if duration >= 3 {
            var moving: [(Double, Double)] = []
            func add(_ a: Double, _ b: Double) { if b > a { moving.append((max(0, a), min(duration, b))) } }
            for l in content + layers.filter({ lookIds.contains($0.id) }).flatMap(\.children) {
                let shift = timeOffset[l.id] ?? 0
                func add(_ a: Double, _ b: Double) { if b > a { moving.append((max(0, a + shift), min(duration, b + shift))) } }
                let (s, e) = life(l)
                if l.type == .particles || l.type == .video || !l.wiggle.isEmpty || !l.audioReact.isEmpty
                    || !l.links.isEmpty || (l.type == .drawing && l.drawing.frames.count > 1)
                    || (l.type == .generator && [.spectrum, .waveform, .lightning, .noise].contains(l.generator.kind)) {
                    add(s, e)
                }
                for a in l.textAnimators { add(a.start, a.start + a.duration + a.stagger * Double(max(1, l.text.count))) }
                for p in AnimProperty.allCases {
                    let k = l[p].keyframeList
                    guard let f = k.first?.t, let g = k.last?.t else { continue }
                    add(f, l.loop[p.rawValue] != nil ? e : g)
                }
                for p in ColorProperty.allCases {
                    let k = l[p].keyframeList
                    guard let f = k.first?.t, let g = k.last?.t else { continue }
                    add(f, l.loop[p.rawValue] != nil ? e : g)
                }
                if l.d.isAnimated { add(l.d.keyframeList.first?.t ?? s, l.loop["d"] != nil ? e : (l.d.keyframeList.last?.t ?? e)) }
            }
            if let cam = camera {
                if !cam.wiggle.isEmpty { add(0, duration) }
                for v in [cam.x, cam.y, cam.zoom, cam.rotation, cam.z, cam.orbitX, cam.orbitY] {
                    let k = v.keyframeList
                    if let f = k.first?.t, let g = k.last?.t { add(f, g) }
                }
            }
            let merged = moving.sorted { $0.0 < $1.0 }.reduce(into: [(Double, Double)]()) { acc, iv in
                if let last = acc.last, iv.0 <= last.1 + 0.05 { acc[acc.count - 1].1 = max(last.1, iv.1) } else { acc.append(iv) }
            }
            var gaps: [String] = []
            var cursor = 0.0
            for iv in merged + [(duration, duration)] {
                if iv.0 - cursor >= 2 { gaps.append(String(format: "%.1f–%.1fs", cursor, iv.0)) }
                cursor = max(cursor, iv.1)
            }
            if !gaps.isEmpty {
                out.append(DesignIssue(severity: .hint, code: "static",
                                       message: "Nothing moves during \(gaps.prefix(4).joined(separator: ", "))",
                                       fix: "fine if the stillness is a held beat; else keep something alive (a slow drift, a loop, a camera move, texture)", layers: []))
            }
        }

        // 7. Text on the edge
        let margin = 80.0
        var edge: [String] = []
        for t in texts {
            let time = mid(t)
            var box: CGRect
            if let renderer {
                let paths = renderer.glyphPaths(t, at: time)
                guard !paths.isEmpty else { continue }
                box = paths.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
            } else {
                let lines = t.text.split(separator: "\n", omittingEmptySubsequences: false)
                let chars = Double(lines.map(\.count).max() ?? 0)
                let lw = min(t.maxWidth ?? .infinity, chars * t.fontSize * 0.55)
                box = CGRect(x: -lw / 2, y: -t.fontSize * 0.6 * Double(lines.count), width: lw, height: t.fontSize * 1.2 * Double(lines.count))
            }
            let world = box.applying(worldTransform(of: t, at: time))
            if world.minX < margin || world.maxX > w - margin || world.minY < margin || world.maxY > h - margin {
                edge.append(t.id)
            }
        }
        if !edge.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "edge",
                                   message: "Text closer than 80 px to the frame edge (or clipped)",
                                   fix: "move it inside the safe margin, shrink fontSize or set maxWidth", layers: edge))
        }

        // 8. Linear entrances
        var linear: [String] = []
        for l in content {
            for p in [AnimProperty.opacity, .y, .x, .scale] {
                let k = l[p].keyframeList
                guard k.count >= 2, abs(k[0].t - l.start) < 0.25, k[1].easing == .linear, p != .opacity || k[0].v < k[1].v else { continue }
                linear.append(l.id); break
            }
        }
        if !linear.isEmpty {
            out.append(DesignIssue(severity: .hint, code: "linear-entrance",
                                   message: "Entrances with linear easing",
                                   fix: "fine for a mechanical feel; for a natural one ease entrances out and exits in", layers: linear))
        }

        // 9. Only text and boxes: suggest two techniques that fit the content.
        let fancy = content.contains { l in
            l.type == .particles || l.matte != nil || l.repeater != nil || l.d.isAnimated || l.threeD || l.type == .model
                || !l.textAnimators.isEmpty || l.type == .generator || l[.trim].isAnimated || l.textPath != nil
        }
        if !fancy, content.count >= 2 {
            let hasMedia = content.contains { $0.type == .image || $0.type == .video }
            let tips = hasMedia
                ? "reveal the picture through a matte (inside a big word or a growing circle) and push the camera in with a little parallax"
                : texts.isEmpty ? "morph one shape into the next (keyframes on d) and spin a repeater ring around the subject"
                : "animate the title per letter (textAnimators / textRise) and let particles fly off it (particles with \"from\")"
            out.append(DesignIssue(severity: .hint, code: "plain",
                                   message: "Only text and boxes; nothing makes it memorable",
                                   fix: tips, layers: []))
        }

        // Rules 10–14 look at every layer, however deep it sits in groups. `offset` turns a layer's own clock into
        // scene time (groups with localTime); `chain` is its groups, outermost first, each with its own offset.
        struct Deep {
            var layer: MotionLayer
            var offset: Double
            var chain: [(group: MotionLayer, offset: Double)]
        }
        var deep: [Deep] = []
        func collect(_ list: [MotionLayer], _ chain: [(group: MotionLayer, offset: Double)], _ offset: Double) {
            for l in list where !lookIds.contains(l.id) && l.type != .audio {
                if l.type == .group {
                    collect(l.children, chain + [(l, offset)], l.localTime ? offset + l.start : offset)
                } else {
                    deep.append(Deep(layer: l, offset: offset, chain: chain))
                }
            }
        }
        collect(layers, [], 0)
        /// Largest value a track reaches (its keys, or the constant).
        func peak(_ l: MotionLayer, _ p: AnimProperty) -> Double {
            l[p].keyframeList.map(\.v).max() ?? l[p].value(at: l.start)
        }

        // 10. Text inside a goo group melts with its neighbors.
        let melted = deep.filter { d in
            d.layer.type == .text && !d.layer.text.isEmpty
                && (peak(d.layer, .goo) >= 1 || d.chain.contains { peak($0.group, .goo) >= 1 })
        }.map(\.layer.id)
        if !melted.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "goo-text",
                                   message: "Text inside a goo group: its letters fuse and stop being readable",
                                   fix: "move the text out of the goo group (keep only the blobs/drips in it), or lower goo below ~1/8 of the letter stroke",
                                   layers: melted))
        }

        // 11. A long shadow that stops inside the frame reads as a stray shape.
        var shortShadows: [String] = []
        var shadowLength = 0.0
        for d in deep {
            let l = d.layer, length = peak(l, .longShadow)
            guard length >= 1 else { continue }
            let t = mid(l)
            let angle = l.value(.longShadowAngle, at: t) * .pi / 180
            let dx = cos(angle), dy = sin(angle)
            let c = CGPoint.zero.applying(worldTransform(of: l, at: t))
            let end = CGPoint(x: c.x + dx * length, y: c.y + dy * length)
            guard CGRect(x: 40, y: 40, width: w - 80, height: h - 80).contains(end) else { continue }
            let tx = dx > 1e-6 ? (w - c.x) / dx : dx < -1e-6 ? -c.x / dx : .infinity
            let ty = dy > 1e-6 ? (h - c.y) / dy : dy < -1e-6 ? -c.y / dy : .infinity
            let exit = min(tx, ty)
            if exit.isFinite { shadowLength = max(shadowLength, ((exit + 300) / 50).rounded(.up) * 50) }
            shortShadows.append(l.id)
        }
        if !shortShadows.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "short-long-shadow",
                                   message: "Long shadows end inside the frame, as a blob with the shape's outline",
                                   fix: "let them run off the frame (longShadow ≥ \(Int(shadowLength > 0 ? shadowLength : 1500))) or clip them with the card/section they fall on",
                                   layers: shortShadows))
        }

        // 12. Illustrations made of bare polygons.
        func isStraight(_ a: PathPoint, _ s: CubicSegment) -> Bool {
            let vx = s.p.x - a.x, vy = s.p.y - a.y
            let tol = 0.02 * max(1, vx * vx + vy * vy).squareRoot()
            func off(_ c: PathPoint) -> Double { abs((c.x - a.x) * vy - (c.y - a.y) * vx) / max(1e-9, (vx * vx + vy * vy).squareRoot()) }
            return off(s.c1) <= tol && off(s.c2) <= tol
        }
        let pathLayers = deep.filter { $0.layer.type == .path && !matteSources.contains($0.layer.id) }
        let polygons = pathLayers.filter { d in
            let l = d.layer
            // Light beams, sunbursts and soft overlays are polygons on purpose.
            guard l.fill.value(at: mid(l)).a > 0.05, l.textPath == nil, l.repeater == nil, l.blendMode == .normal,
                  peak(l, .blur) < 4, l.value(.opacity, at: mid(l)) >= 0.5 else { return false }
            let shape = l.d.value(at: mid(l))
            // A star is meant to be pointy.
            if shape.source?.hasPrefix("star(") == true { return false }
            let subs = shape.subpaths.filter { !$0.segments.isEmpty }
            let count = subs.reduce(0) { $0 + $1.segments.count }
            guard !subs.isEmpty, count >= 3, count <= 10 else { return false }
            for s in subs {
                var from = s.start
                for seg in s.segments {
                    if !isStraight(from, seg) { return false }
                    from = seg.p
                }
            }
            let box = shape.cgPath.boundingBoxOfPath
            let k = abs(l.value(.scale, at: mid(l)))
            return max(box.width, box.height) * k >= 60
        }.map(\.layer.id)
        if polygons.count >= 3 {
            out.append(DesignIssue(severity: .hint, code: "crude-shapes",
                                   message: "\(polygons.count) illustration parts are bare straight-edged polygons (a triangle for a tree, a kite for a plane): they read as placeholders",
                                   fix: "fine if hard geometry is the style and the parts read as what they are; else draw the object with curves (C/Q/A in d), or import_vector an illustration whose style fits",
                                   layers: polygons))
        }

        // 13. Everything bounces the same way.
        var animated = 0
        var bouncing: [String] = []
        for d in deep {
            var moves = false, overshoots = false
            for p in AnimProperty.allCases {
                let k = d.layer[p].keyframeList
                guard k.count >= 2 else { continue }
                moves = true
                for key in k.dropFirst() {
                    switch key.easing {
                    case .spring, .springWith, .curve(.back, _), .curve(.elastic, _), .curve(.bounce, _): overshoots = true
                    default: break
                    }
                }
            }
            if moves { animated += 1 }
            if overshoots { bouncing.append(d.layer.id) }
        }
        if animated >= 12, Double(bouncing.count) >= Double(animated) * 0.4 {
            out.append(DesignIssue(severity: .hint, code: "overshoot-everywhere",
                                   message: "\(bouncing.count) of \(animated) animated layers overshoot (back/elastic/bounce/spring), so every move feels the same",
                                   fix: "keep the bounce for one or two hero elements per section; give the rest easeOutExpo / easeOutCubic / easeInOutCubic, and motionBlur on fast moves",
                                   layers: bouncing))
        }

        // 14. Stretches where only the background is on screen.
        if duration >= 2 {
            func size(_ l: MotionLayer, at t: Double) -> Double {
                let k = l.value(.scale, at: t), kk = k * k * abs(l.value(.scaleX, at: t) * l.value(.scaleY, at: t))
                switch l.type {
                case .rect, .ellipse, .generator:
                    return l.value(.width, at: t) * l.value(.height, at: t) * kk
                case .image, .video:
                    let lw = l.width.map { $0.value(at: t) } ?? w, lh = l.height.map { $0.value(at: t) } ?? h
                    return lw * lh * kk
                case .path:
                    let box = l.d.value(at: t).cgPath.boundingBoxOfPath
                    return box.isNull ? 0 : max(box.width, 4) * max(box.height, 4) * kk
                case .text:
                    let lines = l.text.split(separator: "\n", omittingEmptySubsequences: false)
                    let chars = Double(lines.map(\.count).max() ?? 0)
                    return chars * l.fontSize * 0.55 * l.fontSize * 1.2 * Double(lines.count) * kk
                case .particles:
                    return 0
                default:
                    return area * 0.1
                }
            }
            func subject(at time: Double) -> Double {
                var sum = 0.0
                for d in deep {
                    let l = d.layer, t = time - d.offset
                    guard t >= l.start, t < l.effectiveEnd(sceneDuration: duration), !matteSources.contains(l.id) else { continue }
                    var alpha = l.value(.opacity, at: t), grow = 1.0, alive = true
                    for (g, o) in d.chain {
                        let gt = time - o
                        if gt < g.start || gt >= g.effectiveEnd(sceneDuration: duration) { alive = false; break }
                        alpha *= g.value(.opacity, at: gt)
                        let k = g.value(.scale, at: gt)
                        grow *= k * k * abs(g.value(.scaleX, at: gt) * g.value(.scaleY, at: gt))
                    }
                    guard alive, alpha > 0.05 else { continue }
                    let s = size(l, at: t) * grow
                    // A shape over half the frame is a backdrop, not a subject.
                    if [.rect, .ellipse, .generator].contains(l.type), s >= area * 0.5 { continue }
                    sum += s
                    if sum >= area * 0.01 { break }
                }
                return sum
            }
            var empty: [String] = []
            var from: Double?
            var time = 0.25
            while time < duration + 0.5 {
                let bare = time < duration && subject(at: time) < area * 0.01
                if bare {
                    if from == nil { from = time }
                } else if let f = from {
                    if time - f >= 1 { empty.append(String(format: "%.1f–%.1fs", f - 0.25, min(duration, time - 0.25))) }
                    from = nil
                }
                time += 0.5
            }
            if !empty.isEmpty {
                out.append(DesignIssue(severity: .hint, code: "empty-frame",
                                       message: "Nothing but the background (or a hairline) on screen during \(empty.prefix(4).joined(separator: ", "))",
                                       fix: "fine for a deliberate pause or small type in space; else bring the next subject in earlier or hold the previous one longer", layers: []))
            }
        }

        // 15. Outlines grown with scale: the stroke widens with the shape (a 4 px ring at scale 3.4 draws 14 px),
        // so expanding rings and frames turn heavy instead of thinning out like a shockwave.
        var thickened: [String] = []
        for d in deep where d.layer.type == .rect || d.layer.type == .ellipse || d.layer.type == .path {
            let l = d.layer
            guard let stroke = l.stroke, l.strokeWidth.value(at: l.start) > 0 || !l.strokeWidth.keyframeList.isEmpty,
                  !l.scale.keyframeList.isEmpty || !l[.scaleX].keyframeList.isEmpty || !l[.scaleY].keyframeList.isEmpty
            else { continue }
            let (a, b) = life(l)
            guard b > a else { continue }
            var designed = 0.0, drawn = 0.0
            for i in 0...24 {
                let t = a + (b - a) * Double(i) / 24
                let sw = l.value(.strokeWidth, at: t)
                designed = max(designed, sw)
                guard stroke.value(at: t).a > 0.05, l.value(.opacity, at: t) > 0.1 else { continue }
                let k = abs(l.value(.scale, at: t)) * max(abs(l.value(.scaleX, at: t)), abs(l.value(.scaleY, at: t)))
                drawn = max(drawn, sw * k)
            }
            if designed > 0, drawn >= 4, drawn >= designed * 2 { thickened.append(l.id) }
        }
        if !thickened.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "scaled-stroke",
                                   message: "Outlines grown with scale draw their stroke 2× or more wider than strokeWidth, so expanding rings/frames look heavy and crude",
                                   fix: "grow them with width/height instead (apply_preset ripple does it for rings: grows, thins the stroke, fades, glows), or key strokeWidth down as scale goes up",
                                   layers: thickened))
        }
        out += craftIssues(renderer: renderer, pixels: pixels)
        return out.sorted { $0.severity > $1.severity }
    }

    /// One time per section for a look at full size: the 60% point of every top-level group (or of every ~3 s
    /// when the piece is not built from groups), at most `limit`.
    public func reviewTimes(limit: Int = 24) -> [Double] {
        let lookIds: Set<String> = [Self.lookGroupId, Self.lookFinishId]
        let matteSources = Set(allLayers.compactMap { $0.matte?.source })
        var times = layers.filter { $0.type == .group && !lookIds.contains($0.id) && !matteSources.contains($0.id) }.compactMap { g -> Double? in
            let a = max(0, g.start), b = min(duration, g.effectiveEnd(sceneDuration: duration))
            return b > a ? a + (b - a) * 0.6 : nil
        }
        if times.count < 2 {
            let n = max(1, min(limit, Int((duration / 3).rounded(.up))))
            times = (0..<n).map { (Double($0) + 0.6) * duration / Double(n) }
        }
        times = times.map { ($0 * 10).rounded() / 10 }.sorted()
        var out: [Double] = []
        for t in times where out.last.map({ t - $0 >= 0.4 }) ?? true { out.append(t) }
        if out.count > limit {
            let step = Double(out.count) / Double(limit)
            out = (0..<limit).map { out[Int(Double($0) * step)] }
        }
        return out
    }

    /// What the agent must do after the lint: look at each section at full size, and what to look for.
    public var reviewNote: String {
        let times = reviewTimes().map { String(format: "%g", $0) }.joined(separator: ", ")
        return """
            Close look (the lint cannot see pictures): render_frame at full size, one call per time, and Read each PNG: \(times).
            In every frame check: does it look intended and finished in the direction you chose? Does each object look like \
            what it is, or like a placeholder made of boxes and triangles? Do parts join (limbs meet the body, shadows touch \
            their object)? Is every word readable (not melted, not over a busy picture, not overlapping other text)? Is empty \
            space or a small subject there on purpose? Fix what fails, then render that time again.
            """
    }

    /// One text block for the agent: problems to fix first, then style notes to weigh.
    public static func designReport(_ issues: [DesignIssue]) -> String {
        let problems = issues.filter { $0.severity >= .warning }, notes = issues.filter { $0.severity == .hint }
        var lines = [problems.isEmpty
            ? "Design check: no problems (nothing unreadable, clipped, overlapping or broken)."
            : "Design check: \(problems.count) problem\(problems.count == 1 ? "" : "s") to fix"]
        lines += problems.map { "- " + $0.line }
        if !notes.isEmpty {
            lines.append("Style notes (defaults of a polished generic look, not errors: follow one only if it serves the direction you chose for this piece):")
            lines += notes.map { "- " + $0.line }
        }
        return lines.joined(separator: "\n")
    }

    /// A few words for the context line: "ok" or "3 findings: flat-background, system-font, …".
    public static func designSummary(_ issues: [DesignIssue]) -> String {
        let real = issues.filter { $0.severity >= .warning }
        guard !real.isEmpty else { return "ok" }
        return "\(real.count) finding\(real.count == 1 ? "" : "s"): " + real.map(\.code).joined(separator: ", ")
    }
}
