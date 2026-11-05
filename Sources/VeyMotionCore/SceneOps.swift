import Foundation

public enum Preset: String, CaseIterable, Codable, Sendable {
    // Entrances
    case fadeIn, slideUp, slideDown, slideInLeft, slideInRight, popIn, zoomIn, blurIn, bounceIn, dropIn, flipIn, rotateIn
    // Exits
    case fadeOut, slideOutUp, slideOutDown, slideOutLeft, slideOutRight, popOut, zoomOut, blurOut, flipOut
    // Emphasis
    case spin, pulse, heartbeat, shake, wobble, jello
    // Shapes
    case drawOn
    // Text
    case typewriter, textRise, textPop, textDrop, textLines, textOut

    public var title: String {
        switch self {
        case .fadeIn: return "Fade In"
        case .fadeOut: return "Fade Out"
        case .slideUp: return "Slide Up"
        case .slideDown: return "Slide Down"
        case .slideInLeft: return "Slide In Left"
        case .slideInRight: return "Slide In Right"
        case .slideOutUp: return "Slide Out Up"
        case .slideOutDown: return "Slide Out Down"
        case .slideOutLeft: return "Slide Out Left"
        case .slideOutRight: return "Slide Out Right"
        case .popIn: return "Pop In"
        case .popOut: return "Pop Out"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .blurIn: return "Blur In"
        case .blurOut: return "Blur Out"
        case .bounceIn: return "Bounce In"
        case .dropIn: return "Drop In"
        case .flipIn: return "Flip In"
        case .flipOut: return "Flip Out"
        case .rotateIn: return "Rotate In"
        case .spin: return "Spin"
        case .pulse: return "Pulse"
        case .heartbeat: return "Heartbeat"
        case .shake: return "Shake"
        case .wobble: return "Wobble"
        case .jello: return "Jello"
        case .drawOn: return "Draw On"
        case .typewriter: return "Typewriter"
        case .textRise: return "Letters Rise"
        case .textPop: return "Words Pop"
        case .textDrop: return "Letters Drop"
        case .textLines: return "Lines Slide"
        case .textOut: return "Letters Out"
        }
    }

    public enum Group: String, CaseIterable, Sendable {
        case entrance = "Entrance", exit = "Exit", emphasis = "Emphasis", shape = "Shape", text = "Text"
    }

    public var group: Group {
        switch self {
        case .fadeIn, .slideUp, .slideDown, .slideInLeft, .slideInRight, .popIn, .zoomIn, .blurIn, .bounceIn, .dropIn,
             .flipIn, .rotateIn: return .entrance
        case .fadeOut, .slideOutUp, .slideOutDown, .slideOutLeft, .slideOutRight, .popOut, .zoomOut, .blurOut,
             .flipOut: return .exit
        case .spin, .pulse, .heartbeat, .shake, .wobble, .jello: return .emphasis
        case .drawOn: return .shape
        case .typewriter, .textRise, .textPop, .textDrop, .textLines, .textOut: return .text
        }
    }

    /// Whether the preset can be applied to a layer of this type.
    public func applies(to type: LayerType) -> Bool {
        switch group {
        case .text: return type == .text
        case .shape: return type == .rect || type == .ellipse
        default: return type.isVisual
        }
    }
}

/// All scene mutations live here so the UI and the MCP server share exactly the same behavior.
extension MotionScene {
    public func layerIndex(_ id: String) throws -> Int {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { throw SceneError.layerNotFound(id) }
        return i
    }

    public func layer(_ id: String) throws -> MotionLayer { layers[try layerIndex(id)] }

    public func uniqueId(base: String) -> String {
        let cleaned = base.trimmingCharacters(in: .whitespaces)
        let b = cleaned.isEmpty ? "layer" : cleaned
        let ids = Set(layers.map(\.id))
        if !ids.contains(b) { return b }
        var n = 2
        while ids.contains("\(b)-\(n)") { n += 1 }
        return "\(b)-\(n)"
    }

    /// Adds a layer on top (or at `index`), returning its final id.
    @discardableResult
    public mutating func addLayer(_ layer: MotionLayer, at index: Int? = nil) -> String {
        var l = layer
        l.id = uniqueId(base: l.id.isEmpty ? l.type.rawValue : l.id)
        if l.name.isEmpty { l.name = l.id }
        let i = min(max(index ?? layers.count, 0), layers.count)
        layers.insert(l, at: i)
        return l.id
    }

    public mutating func removeLayer(_ id: String) throws {
        let i = try layerIndex(id)
        for child in children(of: id) { try setParent(child, to: layers[i].parent, at: layers[i].start) }
        layers.remove(at: try layerIndex(id))
    }

    @discardableResult
    public mutating func duplicateLayer(_ id: String) throws -> String {
        let i = try layerIndex(id)
        var copy = layers[i]
        copy.id = uniqueId(base: copy.id)
        copy.name += " copy"
        layers.insert(copy, at: i + 1)
        return copy.id
    }

    /// Moves a layer to a draw-order index (0 = bottom).
    public mutating func moveLayer(_ id: String, to index: Int) throws {
        let i = try layerIndex(id)
        let l = layers.remove(at: i)
        layers.insert(l, at: min(max(index, 0), layers.count))
    }

    public mutating func setKeyframes(_ id: String, property: AnimProperty, keyframes: [MotionKeyframe]) throws {
        let i = try layerIndex(id)
        let fallback = layers[i][property].value(at: 0)
        layers[i][property] = AnimValue.make(keyframes, fallback: fallback)
    }

    public mutating func setValue(_ id: String, property: AnimProperty, value: Double, at t: Double) throws {
        let i = try layerIndex(id)
        layers[i][property] = layers[i][property].setting(value, at: t)
    }

    /// Applies a merge patch (RFC 7386 style) to one layer.
    public mutating func updateLayer(_ id: String, patch: [String: Any]) throws {
        let i = try layerIndex(id)
        var base = try SceneJSON.object(layers[i]) as? [String: Any] ?? [:]
        base = JSONMerge.merge(base, patch) as? [String: Any] ?? base
        var updated = try SceneJSON.decode(MotionLayer.self, fromObject: base)
        if updated.id != layers[i].id {
            let others = layers.enumerated().filter { $0.offset != i }.map(\.element.id)
            if updated.id.isEmpty || others.contains(updated.id) {
                throw SceneError.invalid("id '\(updated.id)' is empty or already used")
            }
        }
        if updated.name.isEmpty { updated.name = updated.id }
        if let p = updated.parent, p == updated.id || !layers.contains(where: { $0.id == p }) || isAncestor(layers[i].id, of: p) {
            throw SceneError.invalid("parent '\(p)' must be another existing layer that is not a child of '\(updated.id)'")
        }
        if let p = updated.parent, layers.first(where: { $0.id == p })?.type == .camera {
            throw SceneError.invalid("a camera cannot be a parent")
        }
        let oldId = layers[i].id
        layers[i] = updated
        if updated.id != oldId {
            for j in layers.indices where layers[j].parent == oldId { layers[j].parent = updated.id }
            for j in layers.indices {
                for (k, r) in layers[j].audioReact where r.source == oldId { layers[j].audioReact[k]?.source = updated.id }
            }
        }
    }

    /// Patches scene settings (width, height, fps, duration, background). `layers` is ignored.
    public mutating func updateSettings(patch: [String: Any]) throws {
        var p = patch
        p.removeValue(forKey: "layers")
        var base = try SceneJSON.object(self) as? [String: Any] ?? [:]
        base = JSONMerge.merge(base, p) as? [String: Any] ?? base
        self = try SceneJSON.decode(MotionScene.self, fromObject: base)
    }

    public mutating func applyPreset(_ preset: Preset, to id: String, start s: Double, duration d: Double) throws {
        guard d > 0 else { throw SceneError.invalid("duration must be > 0") }
        let i = try layerIndex(id)
        var l = layers[i]
        guard preset.applies(to: l.type) else {
            throw SceneError.invalid("\(preset.rawValue) only applies to \(preset.group == .text ? "text" : preset.group == .shape ? "rect/ellipse" : "visual") layers")
        }
        let e = s + d
        func put(_ p: AnimProperty, _ kfs: [MotionKeyframe]) {
            l[p] = l[p].inserting(kfs, replacing: s, e)
        }
        func kf(_ t: Double, _ v: Double, _ easing: Easing = .easeInOut) -> MotionKeyframe {
            MotionKeyframe(t: t, v: v, easing: easing)
        }
        let opacityIn = max(l.opacity.value(at: e), 0.01)
        let opacityOut = l.opacity.value(at: s)
        func fadeIn(_ fraction: Double) { put(.opacity, [kf(s, 0, .linear), kf(s + d * fraction, opacityIn, .easeOut)]) }
        func fadeOut(from fraction: Double) {
            put(.opacity, [kf(s + d * fraction, opacityOut, .linear), kf(e, 0, .easeIn)])
        }
        /// Decaying oscillation around the current value (shake, wobble, jello).
        func oscillate(_ p: AnimProperty, amplitude: Double, count: Int = 7) {
            let base = l[p].value(at: s)
            var kfs = [kf(s, base, .linear)]
            for k in 1...count {
                let decay = 1 - Double(k - 1) / Double(count)
                kfs.append(kf(s + d * Double(k) / Double(count + 1), base + amplitude * decay * (k % 2 == 1 ? 1 : -1), .curve(.sine, .inOut)))
            }
            kfs.append(kf(e, base, .curve(.sine, .inOut)))
            put(p, kfs)
        }
        switch preset {
        case .fadeIn:
            put(.opacity, [kf(s, 0, .linear), kf(e, opacityIn, .easeOut)])
        case .fadeOut:
            put(.opacity, [kf(s, opacityOut), kf(e, 0, .easeIn)])
        case .slideUp, .slideDown:
            let y = l.y.value(at: e)
            let offset = preset == .slideUp ? 120.0 : -120.0
            put(.y, [kf(s, y + offset, .linear), kf(e, y, .easeOut)])
            fadeIn(0.6)
        case .slideInLeft, .slideInRight:
            let x = l.x.value(at: e)
            let offset = preset == .slideInLeft ? -300.0 : 300.0
            put(.x, [kf(s, x + offset, .linear), kf(e, x, .easeOut)])
            fadeIn(0.6)
        case .slideOutUp, .slideOutDown:
            let y = l.y.value(at: s)
            put(.y, [kf(s, y, .linear), kf(e, y + (preset == .slideOutUp ? -120.0 : 120.0), .easeIn)])
            fadeOut(from: 0.4)
        case .slideOutLeft, .slideOutRight:
            let x = l.x.value(at: s)
            put(.x, [kf(s, x, .linear), kf(e, x + (preset == .slideOutLeft ? -300.0 : 300.0), .easeIn)])
            fadeOut(from: 0.4)
        case .popIn:
            let sc = l.scale.value(at: e)
            put(.scale, [kf(s, 0, .linear), kf(s + d * 0.7, sc * 1.08, .easeOut), kf(e, sc, .easeInOut)])
            fadeIn(0.3)
        case .popOut:
            let sc = l.scale.value(at: s)
            put(.scale, [kf(s, sc, .linear), kf(s + d * 0.3, sc * 1.08, .easeOut), kf(e, 0, .easeIn)])
            fadeOut(from: 0.5)
        case .zoomIn:
            let sc = l.scale.value(at: e)
            put(.scale, [kf(s, sc * 1.6, .linear), kf(e, sc, .curve(.expo, .out))])
            fadeIn(0.5)
        case .zoomOut:
            let sc = l.scale.value(at: s)
            put(.scale, [kf(s, sc, .linear), kf(e, sc * 1.6, .curve(.expo, .in))])
            fadeOut(from: 0.3)
        case .blurIn:
            put(.blur, [kf(s, 40, .linear), kf(e, 0, .curve(.cubic, .out))])
            fadeIn(0.6)
        case .blurOut:
            put(.blur, [kf(s, 0, .linear), kf(e, 40, .curve(.cubic, .in))])
            fadeOut(from: 0.4)
        case .bounceIn:
            let sc = l.scale.value(at: e)
            put(.scale, [kf(s, 0, .linear), kf(e, sc, .curve(.elastic, .out))])
            fadeIn(0.15)
        case .dropIn:
            let y = l.y.value(at: e)
            put(.y, [kf(s, y - 260, .linear), kf(e, y, .curve(.bounce, .out))])
            fadeIn(0.2)
        case .flipIn:
            put(.scaleX, [kf(s, 0, .linear), kf(e, l.value(.scaleX, at: e), .curve(.back, .out))])
            fadeIn(0.3)
        case .flipOut:
            put(.scaleX, [kf(s, l.value(.scaleX, at: s), .linear), kf(e, 0, .curve(.back, .in))])
            fadeOut(from: 0.6)
        case .rotateIn:
            let r = l.rotation.value(at: e), sc = l.scale.value(at: e)
            put(.rotation, [kf(s, r - 90, .linear), kf(e, r, .springWith(damping: 7, frequency: 9))])
            put(.scale, [kf(s, sc * 0.5, .linear), kf(e, sc, .curve(.back, .out))])
            fadeIn(0.4)
        case .spin:
            let r = l.rotation.value(at: s)
            put(.rotation, [kf(s, r, .linear), kf(e, r + 360, .easeInOut)])
        case .pulse:
            let sc = l.scale.value(at: s)
            put(.scale, [kf(s, sc, .linear), kf(s + d / 2, sc * 1.12, .easeOut), kf(e, sc, .easeInOut)])
        case .heartbeat:
            let sc = l.scale.value(at: s)
            put(.scale, [kf(s, sc, .linear), kf(s + d * 0.15, sc * 1.15, .easeOut), kf(s + d * 0.3, sc, .easeIn),
                         kf(s + d * 0.45, sc * 1.1, .easeOut), kf(e, sc, .easeInOut)])
        case .shake:
            oscillate(.x, amplitude: 24, count: 8)
        case .wobble:
            oscillate(.rotation, amplitude: 10, count: 6)
        case .jello:
            oscillate(.skewX, amplitude: 14, count: 6)
        case .drawOn:
            if l.stroke == nil {
                l.stroke = .constant(l.fill.value(at: s))
                l.fill = .constant(.clear)
            }
            if l.strokeWidth.value(at: s) <= 0 { l.strokeWidth = .constant(6) }
            put(.trim, [kf(s, 0, .linear), kf(e, 1, .curve(.cubic, .inOut))])
        case .typewriter:
            put(.reveal, [kf(s, 0, .linear), kf(e, 1, .linear)])
        case .textRise, .textPop, .textDrop, .textLines, .textOut:
            var a: TextAnimator
            switch preset {
            case .textPop: a = TextAnimator(unit: .word, easing: .curve(.back, .out), scale: 0)
            case .textDrop: a = TextAnimator(unit: .char, easing: .curve(.back, .out), y: -70, rotation: -25)
            case .textLines: a = TextAnimator(unit: .line, easing: .curve(.expo, .out), x: -60, y: 30)
            case .textOut: a = TextAnimator(unit: .char, mode: .out, easing: .curve(.cubic, .in), y: -40)
            default: a = TextAnimator(unit: .char, easing: .curve(.cubic, .out), y: 50)
            }
            let n = max(1, TextUnits.map(l.text, unit: a.unit).count)
            let unitDur = n <= 1 ? d : min(max(d * 0.35, min(0.6, d * 0.6)), d)
            a.start = s
            a.duration = unitDur
            a.stagger = n <= 1 ? 0 : max(0, (d - unitDur) / Double(n - 1))
            l.textAnimators.removeAll { $0.mode == a.mode }
            l.textAnimators.append(a)
        }
        layers[i] = l
    }

    /// Applies a preset to several layers, each starting `stagger` seconds after the previous one.
    /// Layers the preset doesn't apply to are skipped; returns the ids it was applied to.
    @discardableResult
    public mutating func applyPreset(_ preset: Preset, to ids: [String], start s: Double, duration d: Double,
                                     stagger: Double) throws -> [String] {
        var done: [String] = []
        for id in ids {
            let l = try layer(id)
            guard preset.applies(to: l.type) else { continue }
            try applyPreset(preset, to: id, start: s + stagger * Double(done.count), duration: d)
            done.append(id)
        }
        if done.isEmpty { throw SceneError.invalid("\(preset.rawValue) does not apply to any of these layers") }
        return done
    }

    public mutating func setColor(_ id: String, property c: ColorProperty, value: RGBA, at t: Double) throws {
        let i = try layerIndex(id)
        if c == .stroke && layers[i].stroke == nil {
            layers[i].stroke = .constant(value)
            if layers[i].strokeWidth.value(at: t) <= 0 { layers[i].strokeWidth = .constant(4) }
            return
        }
        layers[i][c] = layers[i][c].setting(value, at: t)
    }

    public mutating func setColorKeyframes(_ id: String, property c: ColorProperty, keyframes: [ColorKeyframe]) throws {
        let i = try layerIndex(id)
        let fallback = layers[i][c].value(at: 0)
        layers[i][c] = ColorValue.make(keyframes, fallback: fallback)
        if c == .stroke && layers[i].strokeWidth.value(at: 0) <= 0 && !keyframes.isEmpty { layers[i].strokeWidth = .constant(4) }
    }

    /// Links a layer to a parent (nil = unlink). With `keepPosition`, the layer's position is converted so it
    /// stays where it is at time t.
    public mutating func setParent(_ id: String, to parent: String?, at t: Double, keepPosition: Bool = true) throws {
        let i = try layerIndex(id)
        let parent = parent.flatMap { $0.isEmpty ? nil : $0 }
        if let p = parent {
            let pi = try layerIndex(p)
            guard p != id, !isAncestor(id, of: p) else {
                throw SceneError.invalid("'\(p)' cannot be the parent of '\(id)' (that would make a loop)")
            }
            guard layers[i].type != .camera, layers[pi].type != .camera else {
                throw SceneError.invalid("cameras cannot be linked to a parent or be a parent")
            }
        }
        if keepPosition {
            let l = layers[i]
            let world = l.position(at: t).point.applying(parentTransform(of: l, at: t))
            var linked = l
            linked.parent = parent
            let local = world.applying(parentTransform(of: linked, at: t).inverted())
            let dx = local.x - l.position(at: t).point.x, dy = local.y - l.position(at: t).point.y
            if var mp = l.motionPath {
                mp.points = mp.points.map { PathPoint(x: $0.x + dx, y: $0.y + dy) }
                layers[i].motionPath = mp
            } else {
                layers[i].x = l.x.offsetting(by: dx)
                layers[i].y = l.y.offsetting(by: dy)
            }
        }
        layers[i].parent = parent
    }

    /// Ids of the layers that have `id` as their parent.
    public func children(of id: String) -> [String] {
        layers.filter { $0.parent == id }.map(\.id)
    }
}

extension Animated where V == Double {
    /// Every value (constant or keyframes) moved by d.
    public func offsetting(by d: Double) -> AnimValue {
        switch self {
        case let .constant(v): return .constant(v + d)
        case let .keyframes(k): return .keyframes(k.map { Keyframe(t: $0.t, v: $0.v + d, easing: $0.easing) })
        }
    }
}

public enum JSONMerge {
    /// RFC 7386 JSON merge patch: objects merge recursively, `null` deletes, anything else replaces.
    public static func merge(_ target: Any, _ patch: Any) -> Any {
        guard let p = patch as? [String: Any] else { return patch }
        var t = target as? [String: Any] ?? [:]
        // Keyframe objects replace wholesale so stale keyframes never linger.
        if p["keyframes"] != nil { return p }
        for (k, v) in p {
            if v is NSNull {
                t.removeValue(forKey: k)
            } else {
                t[k] = merge(t[k] ?? [String: Any](), v)
            }
        }
        return t
    }
}
