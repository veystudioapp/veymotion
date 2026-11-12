import CoreGraphics
import Foundation

// A deterministic design lint for the agent (check_design, the chat's auto-check after each turn) and the app.
// It cannot judge taste, only the things that reliably make a piece look like a draft: a flat background, nothing
// lighting the subject, no type hierarchy, the system font, frozen stretches, text on the edge, linear entrances.
// Everything is computed from the scene, so the same report comes out of the CLI, the MCP server and the app.

public struct DesignIssue: Codable, Equatable, Sendable {
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

    /// Runs every rule. `renderer` is needed for the text-edge rule (it measures the glyphs); without one that
    /// rule uses a rough estimate from fontSize.
    public func designIssues(renderer: FrameRenderer? = nil) -> [DesignIssue] {
        var out: [DesignIssue] = []
        let w = Double(width), h = Double(height), area = w * h
        let lookIds: Set<String> = [Self.lookGroupId, Self.lookFinishId]
        // Content layers: everything except the look's own layers and sound.
        let content = layers.filter { !lookIds.contains($0.id) }.flatMap { l -> [MotionLayer] in
            l.type == .group ? [l] + l.children : [l]
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
            out.append(DesignIssue(severity: .error, code: "flat-background",
                                   message: "The background is one flat color",
                                   fix: "apply_look (cinematic/clean/neon/retro/sunset/studio), or a full-frame gradient rect + two blurred blobs + vignette/grain", layers: []))
            // 2. Pure contrast only matters without a backdrop in between.
            let pure = texts.filter { t in
                guard case let .constant(c) = t.color else { return false }
                return (c.luminance > 0.98 && background.luminance < 0.03) || (c.luminance < 0.02 && background.luminance > 0.97)
            }
            if !pure.isEmpty {
                out.append(DesignIssue(severity: .warning, code: "pure-contrast",
                                       message: "Pure white text on pure black (or the reverse)",
                                       fix: "near-white #F2F3F7 on #0B0C10 / near-black #15171C on #F5F6F8, and a backdrop with depth",
                                       layers: pure.map(\.id)))
            }
        }

        // 3. Fonts
        let systemFont = texts.filter { ($0.fontName ?? "").isEmpty }
        if !systemFont.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "system-font",
                                   message: "Text uses the system font",
                                   fix: "pick 1–2 families for the mood (list_fonts, or search_stock kind font + import_stock) and set fontName",
                                   layers: systemFont.map(\.id)))
        }

        // 4. Type hierarchy
        if texts.count >= 3 {
            let sizes = texts.map { $0.fontSize * $0.value(.scale, at: mid($0)) }
            if let lo = sizes.min(), let hi = sizes.max(), hi <= lo * 1.25 {
                out.append(DesignIssue(severity: .warning, code: "flat-type",
                                       message: "All text is about the same size, so nothing reads first",
                                       fix: "hero 120–180 px, heading 64–96, body 32–44, eyebrow 22–28 uppercase with letterSpacing; soften secondary text's color",
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
            out.append(DesignIssue(severity: .warning, code: "unlit",
                                   message: "Most layers sit flat on the background (no shadow, glow or gradient)",
                                   fix: "dark looks: glow 0.5–1.5; light looks: shadowOpacity 0.3–0.5, shadowY 10–20, shadowBlur 30–50; gradients on big shapes",
                                   layers: unlit.map(\.id)))
        }

        // 6. Frozen stretches
        if duration >= 3 {
            var moving: [(Double, Double)] = []
            func add(_ a: Double, _ b: Double) { if b > a { moving.append((max(0, a), min(duration, b))) } }
            for l in content + layers.filter({ lookIds.contains($0.id) }).flatMap(\.children) {
                let (s, e) = life(l)
                if l.type == .particles || l.type == .video || !l.wiggle.isEmpty || !l.audioReact.isEmpty
                    || !l.links.isEmpty
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
                out.append(DesignIssue(severity: .warning, code: "static",
                                       message: "Nothing moves during \(gaps.prefix(4).joined(separator: ", "))",
                                       fix: "ambient motion (look blobs, wiggle/loop on a decorative shape, particles) or a camera drift 1 → 1.04", layers: []))
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
                                   fix: "easeOutExpo / easeOutBack / spring for entrances, easeIn for exits, stagger 0.08–0.15 s", layers: linear))
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
        return out.sorted { $0.severity > $1.severity }
    }

    /// One text block for the agent.
    public static func designReport(_ issues: [DesignIssue]) -> String {
        guard !issues.isEmpty else { return "Design check passed: nothing flat, static, unlit or on the edge." }
        let errors = issues.filter { $0.severity == .error }.count, warnings = issues.filter { $0.severity == .warning }.count
        let head = "Design check: \(issues.count) finding\(issues.count == 1 ? "" : "s") (\(errors) error, \(warnings) warning, \(issues.count - errors - warnings) hint)"
        return ([head] + issues.map { "- " + $0.line }).joined(separator: "\n")
    }

    /// A few words for the context line: "ok" or "3 findings: flat-background, system-font, …".
    public static func designSummary(_ issues: [DesignIssue]) -> String {
        let real = issues.filter { $0.severity >= .warning }
        guard !real.isEmpty else { return "ok" }
        return "\(real.count) finding\(real.count == 1 ? "" : "s"): " + real.map(\.code).joined(separator: ", ")
    }
}
