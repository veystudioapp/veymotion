import Foundation

public enum Preset: String, CaseIterable, Codable, Sendable {
    // Entrances
    case fadeIn, slideUp, slideDown, slideInLeft, slideInRight, popIn, zoomIn, blurIn, bounceIn, dropIn, flipIn, rotateIn, wipeIn
    case swingIn
    // Exits
    case fadeOut, slideOutUp, slideOutDown, slideOutLeft, slideOutRight, popOut, zoomOut, blurOut, flipOut, wipeOut
    case swingOut
    // Emphasis
    case spin, pulse, heartbeat, shake, wobble, jello, glitchBurst, turntable
    // Shapes
    case drawOn, writeOn
    // Text
    case typewriter, textRise, textPop, textDrop, textLines, textOut, decode, textBlurIn, textFocus

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
        case .wipeIn: return "Wipe In"
        case .wipeOut: return "Wipe Out"
        case .swingIn: return "Swing In (3D)"
        case .swingOut: return "Swing Out (3D)"
        case .turntable: return "Turntable (3D)"
        case .spin: return "Spin"
        case .pulse: return "Pulse"
        case .heartbeat: return "Heartbeat"
        case .shake: return "Shake"
        case .wobble: return "Wobble"
        case .jello: return "Jello"
        case .glitchBurst: return "Glitch"
        case .drawOn: return "Draw On"
        case .writeOn: return "Write On"
        case .typewriter: return "Typewriter"
        case .textRise: return "Letters Rise"
        case .textPop: return "Words Pop"
        case .textDrop: return "Letters Drop"
        case .textLines: return "Lines Slide"
        case .textOut: return "Letters Out"
        case .decode: return "Decode"
        case .textBlurIn: return "Letters Blur In"
        case .textFocus: return "Words Focus"
        }
    }

    public enum Group: String, CaseIterable, Sendable {
        case entrance = "Entrance", exit = "Exit", emphasis = "Emphasis", shape = "Shape", text = "Text"
    }

    public var group: Group {
        switch self {
        case .fadeIn, .slideUp, .slideDown, .slideInLeft, .slideInRight, .popIn, .zoomIn, .blurIn, .bounceIn, .dropIn,
             .flipIn, .rotateIn, .wipeIn, .swingIn: return .entrance
        case .fadeOut, .slideOutUp, .slideOutDown, .slideOutLeft, .slideOutRight, .popOut, .zoomOut, .blurOut,
             .flipOut, .wipeOut, .swingOut: return .exit
        case .spin, .pulse, .heartbeat, .shake, .wobble, .jello, .glitchBurst, .turntable: return .emphasis
        case .drawOn, .writeOn: return .shape
        case .typewriter, .textRise, .textPop, .textDrop, .textLines, .textOut, .decode, .textBlurIn, .textFocus: return .text
        }
    }

    /// Whether the preset can be applied to a layer of this type.
    public func applies(to type: LayerType) -> Bool {
        switch group {
        case .text: return type == .text
        case .shape: return type.isShape
        default: return type.isVisual
        }
    }
}

public enum TransitionType: String, CaseIterable, Codable, Sendable {
    case fade, dissolve, push, slide, zoom, whip, wipe, iris, blinds, blocks, clock, glitch, flash, blur
    /// A circle (or any path, `shape`) growing from a point until it fills the frame, revealing the new layer.
    case circle, shape
    /// Match cut: the new layer starts where the old one is (position, scale) and both settle into the new one's place.
    case match

    public var title: String { rawValue.capitalized }
}

/// All scene mutations live here so the UI and the MCP server share exactly the same behavior.
extension MotionScene {
    /// Animates `out` away and `in` in over [at, at + d]; the outgoing layer ends and the incoming one starts there.
    /// `direction` (left|right|up|down) is where the motion goes for push/slide/whip/wipe.
    public mutating func transition(_ type: TransitionType, out outId: String?, in inId: String?, at s: Double,
                                    duration d: Double, direction: String?, shape: String? = nil,
                                    origin: (x: Double, y: Double)? = nil) throws {
        guard d > 0 else { throw SceneError.invalid("duration must be > 0") }
        guard outId != nil || inId != nil else { throw SceneError.invalid("Give `out` and/or `in` layer ids") }
        if type == .circle || type == .shape {
            try shapeTransition(out: outId, in: inId, at: s, duration: d, shape: type == .circle ? "circle(1)" : (shape ?? "circle(1)"), origin: origin)
            return
        }
        if type == .match {
            try matchTransition(out: outId, in: inId, at: s, duration: d)
            return
        }
        let e = s + d, mid = s + d / 2
        let dir = direction ?? "left"
        let dx: Double = dir == "left" ? -1 : dir == "right" ? 1 : 0
        let dy: Double = dir == "up" ? -1 : dir == "down" ? 1 : 0
        let w = Double(width), h = Double(height)
        let wipeAngle: Double = dir == "right" ? 0 : dir == "down" ? 90 : dir == "up" ? 270 : 180
        func kf(_ t: Double, _ v: Double, _ easing: Easing = .easeInOut) -> MotionKeyframe { MotionKeyframe(t: t, v: v, easing: easing) }
        func put(_ l: inout MotionLayer, _ p: AnimProperty, _ kfs: [MotionKeyframe]) {
            l[p] = l[p].inserting(kfs, replacing: kfs.first!.t, kfs.last!.t)
        }
        func wipeStyle(_ t: WipeType) -> WipeStyle {
            var st = WipeStyle(type: t, angle: wipeAngle, feather: t == .linear ? 60 : 20)
            if t == .blocks { st.count = 14 }
            if t == .blinds { st.count = 8 }
            return st
        }
        if let outId {
            try withLayer(outId) { l in
                let x0 = l.x.value(at: s), y0 = l.y.value(at: s), sc = l.scale.value(at: s)
                switch type {
                case .fade, .flash:
                    put(&l, .opacity, [kf(s, l.opacity.value(at: s), .linear), kf(type == .flash ? mid : e, 0, .easeIn)])
                case .dissolve:
                    l.wipeStyle = wipeStyle(.blocks); l.wipeStyle?.count = 40
                    put(&l, .wipe, [kf(s, 0, .linear), kf(e, 1, .linear)])
                case .push, .slide:
                    put(&l, .x, [kf(s, x0, .linear), kf(e, x0 + dx * w, .curve(.cubic, .inOut))])
                    put(&l, .y, [kf(s, y0, .linear), kf(e, y0 + dy * h, .curve(.cubic, .inOut))])
                    if type == .slide { put(&l, .opacity, [kf(s + d * 0.4, l.opacity.value(at: s), .linear), kf(e, 0, .easeIn)]) }
                case .zoom:
                    put(&l, .scale, [kf(s, sc, .linear), kf(e, sc * 3, .curve(.expo, .in))])
                    put(&l, .opacity, [kf(s + d * 0.3, l.opacity.value(at: s), .linear), kf(e, 0, .easeIn)])
                    put(&l, .zoomBlur, [kf(s, 0, .linear), kf(e, 0.6, .easeIn)])
                case .whip:
                    put(&l, .x, [kf(s, x0, .linear), kf(mid, x0 + dx * w * 1.2, .curve(.expo, .in))])
                    put(&l, .y, [kf(s, y0, .linear), kf(mid, y0 + dy * h * 1.2, .curve(.expo, .in))])
                    put(&l, .directionalBlur, [kf(s, 0, .linear), kf(mid, 160, .easeIn)])
                    l[.blurAngle] = .constant(dy != 0 ? 90 : 0)
                case .wipe, .iris, .blinds, .blocks, .clock:
                    let wt: WipeType = type == .wipe ? .linear : type == .iris ? .iris : type == .blinds ? .blinds : type == .blocks ? .blocks : .radial
                    l.wipeStyle = wipeStyle(wt)
                    put(&l, .wipe, [kf(s, 0, .linear), kf(e, 1, .curve(.cubic, .inOut))])
                case .glitch:
                    put(&l, .glitch, [kf(s, 0, .linear), kf(s + d * 0.1, 0.9, .hold), kf(mid, 1, .hold)])
                    put(&l, .rgbSplit, [kf(s, 0, .linear), kf(s + d * 0.1, 10, .hold)])
                    put(&l, .opacity, [kf(mid - 0.01, l.opacity.value(at: s), .linear), kf(mid, 0, .hold)])
                case .blur:
                    put(&l, .blur, [kf(s, 0, .linear), kf(e, 50, .easeIn)])
                    put(&l, .opacity, [kf(s + d * 0.3, l.opacity.value(at: s), .linear), kf(e, 0, .easeIn)])
                case .circle, .shape, .match:
                    break // handled above
                }
                if l.end == nil || l.end! > e { l.end = type == .whip || type == .glitch || type == .flash ? mid + 0.02 : e }
            }
        }
        if let inId {
            try withLayer(inId) { l in
                if l.start > s { l.start = s }
                let x1 = l.x.value(at: e), y1 = l.y.value(at: e), sc = l.scale.value(at: e)
                let op = max(l.opacity.value(at: e), 0.01)
                switch type {
                case .fade:
                    put(&l, .opacity, [kf(s, 0, .linear), kf(e, op, .easeOut)])
                case .flash:
                    put(&l, .opacity, [kf(mid, 0, .linear), kf(e, op, .easeOut)])
                case .dissolve:
                    l.wipeStyle = wipeStyle(.blocks); l.wipeStyle?.count = 40
                    put(&l, .wipe, [kf(s, 1, .linear), kf(e, 0, .linear)])
                case .push:
                    put(&l, .x, [kf(s, x1 - dx * w, .linear), kf(e, x1, .curve(.cubic, .inOut))])
                    put(&l, .y, [kf(s, y1 - dy * h, .linear), kf(e, y1, .curve(.cubic, .inOut))])
                case .slide:
                    put(&l, .x, [kf(s, x1 - dx * w * 0.3, .linear), kf(e, x1, .curve(.expo, .out))])
                    put(&l, .y, [kf(s, y1 - dy * h * 0.3, .linear), kf(e, y1, .curve(.expo, .out))])
                    put(&l, .opacity, [kf(s, 0, .linear), kf(s + d * 0.6, op, .easeOut)])
                case .zoom:
                    put(&l, .scale, [kf(s, sc * 0.4, .linear), kf(e, sc, .curve(.expo, .out))])
                    put(&l, .opacity, [kf(s, 0, .linear), kf(s + d * 0.5, op, .easeOut)])
                    put(&l, .zoomBlur, [kf(s, 0.5, .linear), kf(e, 0, .easeOut)])
                case .whip:
                    put(&l, .x, [kf(mid, x1 - dx * w * 1.2, .linear), kf(e, x1, .curve(.expo, .out))])
                    put(&l, .y, [kf(mid, y1 - dy * h * 1.2, .linear), kf(e, y1, .curve(.expo, .out))])
                    put(&l, .directionalBlur, [kf(mid, 160, .linear), kf(e, 0, .easeOut)])
                    l[.blurAngle] = .constant(dy != 0 ? 90 : 0)
                    if l.start > mid - 0.02 || l.start == s { l.start = min(l.start, mid - 0.02) }
                case .wipe, .iris, .blinds, .blocks, .clock:
                    let wt: WipeType = type == .wipe ? .linear : type == .iris ? .iris : type == .blinds ? .blinds : type == .blocks ? .blocks : .radial
                    l.wipeStyle = wipeStyle(wt)
                    if wt == .iris { l.wipeStyle?.reverse = false }
                    put(&l, .wipe, [kf(s, 1, .linear), kf(e, 0, .curve(.cubic, .inOut))])
                case .glitch:
                    put(&l, .opacity, [kf(mid - 0.01, 0, .linear), kf(mid, op, .hold)])
                    put(&l, .glitch, [kf(mid, 1, .linear), kf(mid + d * 0.3, 0.5, .hold), kf(e, 0, .hold)])
                    put(&l, .rgbSplit, [kf(mid, 10, .linear), kf(e, 0, .hold)])
                case .blur:
                    put(&l, .blur, [kf(s, 50, .linear), kf(e, 0, .easeOut)])
                    put(&l, .opacity, [kf(s, 0, .linear), kf(s + d * 0.7, op, .easeOut)])
                case .circle, .shape, .match:
                    break // handled above
                }
            }
        }
        if type == .flash {
            var f = MotionLayer(id: "flash", name: "Flash", type: .rect, x: w / 2, y: h / 2)
            f.width = .constant(w); f.height = .constant(h)
            f.fill = .constant(.white)
            f.start = s; f.end = e
            f.opacity = .keyframes([kf(s, 0, .linear), kf(mid, 1, .easeIn), kf(e, 0, .easeOut)])
            addLayer(f)
        }
    }
    public func layerIndex(_ id: String) throws -> Int {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { throw SceneError.layerNotFound(id) }
        return i
    }

    /// A layer anywhere in the tree (groups' children included).
    public func layer(_ id: String) throws -> MotionLayer {
        guard let l = findLayer(id) else { throw SceneError.layerNotFound(id) }
        return l
    }

    public func uniqueId(base: String) -> String {
        let cleaned = base.trimmingCharacters(in: .whitespaces)
        let b = cleaned.isEmpty ? "layer" : cleaned
        let ids = Set(allLayers.map(\.id))
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
        if l.type == .group {
            // Children's ids must be unique scene-wide too.
            var seen = Set(allLayers.map(\.id))
            seen.insert(l.id)
            Self.normalizeIds(&l.children, seen: &seen)
        }
        let i = min(max(index ?? layers.count, 0), layers.count)
        layers.insert(l, at: i)
        return l.id
    }

    public mutating func removeLayer(_ id: String) throws {
        let i = try layerIndex(id)
        for child in children(of: id) { try setParent(child, to: layers[i].parent, at: layers[i].start) }
        layers.remove(at: try layerIndex(id))
        for j in layers.indices where layers[j].matte?.source == id { layers[j].matte = nil }
    }

    @discardableResult
    public mutating func duplicateLayer(_ id: String) throws -> String {
        let i = try layerIndex(id)
        var copy = layers[i]
        copy.id = uniqueId(base: copy.id)
        copy.name += " copy"
        if copy.type == .group {
            var seen = Set(allLayers.map(\.id))
            seen.insert(copy.id)
            Self.normalizeIds(&copy.children, seen: &seen)
        }
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
        try withLayer(id) { l in
            let fallback = l[property].value(at: 0)
            l[property] = AnimValue.make(keyframes, fallback: fallback)
        }
    }

    /// Path layers: replaces the shape keyframes (a morph between them); an empty list keeps the shape at 0 s.
    public mutating func setPathKeyframes(_ id: String, keyframes: [Keyframe<PathShape>]) throws {
        try withLayer(id) { l in
            guard l.type == .path else { throw SceneError.invalid("'\(id)' is not a path layer") }
            l.d = PathValue.make(keyframes, fallback: l.d.value(at: 0))
        }
    }

    public mutating func setValue(_ id: String, property: AnimProperty, value: Double, at t: Double) throws {
        try withLayer(id) { l in l[property] = l[property].setting(value, at: t) }
    }

    /// Applies a merge patch (RFC 7386 style) to one layer (anywhere in the tree).
    public mutating func updateLayer(_ id: String, patch: [String: Any]) throws {
        let old = try layer(id)
        var base = try SceneJSON.object(old) as? [String: Any] ?? [:]
        base = JSONMerge.merge(base, patch) as? [String: Any] ?? base
        var updated = try SceneJSON.decode(MotionLayer.self, fromObject: base)
        if updated.id != old.id {
            let others = allLayers.map(\.id).filter { $0 != old.id }
            if updated.id.isEmpty || others.contains(updated.id) {
                throw SceneError.invalid("id '\(updated.id)' is empty or already used")
            }
        }
        if updated.name.isEmpty { updated.name = updated.id }
        let isTop = layers.contains { $0.id == old.id }
        if let p = updated.parent, p == updated.id || (isTop && (!layers.contains(where: { $0.id == p }) || isAncestor(old.id, of: p))) {
            throw SceneError.invalid("parent '\(p)' must be another existing layer that is not a child of '\(updated.id)'")
        }
        if let m = updated.matte, m.source == old.id || m.source == updated.id || findLayer(m.source) == nil {
            throw SceneError.invalid("matte '\(m.source)' must be another existing layer")
        }
        if updated.type == .group {
            // Ids used elsewhere in the scene (the group's own subtree may keep its ids).
            let mine = Set(MotionScene(layers: [old]).allLayers.map(\.id))
            var seen = Set(allLayers.map(\.id).filter { !mine.contains($0) })
            seen.insert(updated.id)
            Self.normalizeIds(&updated.children, seen: &seen)
        }
        let oldId = old.id
        try withLayer(oldId) { $0 = updated }
        if updated.id != oldId {
            for j in layers.indices where layers[j].parent == oldId { layers[j].parent = updated.id }
            for j in layers.indices where layers[j].particles.from == oldId { layers[j].particles.from = updated.id }
            for j in layers.indices where layers[j].matte?.source == oldId { layers[j].matte?.source = updated.id }
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
        var l = try layer(id)
        guard preset.applies(to: l.type) else {
            throw SceneError.invalid("\(preset.rawValue) only applies to \(preset.group == .text ? "text" : preset.group == .shape ? "rect/ellipse/path" : "visual") layers")
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
        case .swingIn:
            // Turns in around its vertical axis (3D layers, models; 2.5D on others).
            let r = l[.rotationY].value(at: e)
            put(.rotationY, [kf(s, r + 90, .linear), kf(e, r, .curve(.back, .out))])
            fadeIn(0.3)
        case .swingOut:
            let r = l[.rotationY].value(at: s)
            put(.rotationY, [kf(s, r, .linear), kf(e, r - 90, .curve(.back, .in))])
            fadeOut(from: 0.6)
        case .turntable:
            // One full turn at an even speed (loop "rotationY": "offset" keeps it going).
            let r = l[.rotationY].value(at: s)
            put(.rotationY, [kf(s, r, .linear), kf(e, r + 360, .linear)])
        case .rotateIn:
            let r = l.rotation.value(at: e), sc = l.scale.value(at: e)
            put(.rotation, [kf(s, r - 90, .linear), kf(e, r, .springWith(damping: 7, frequency: 9))])
            put(.scale, [kf(s, sc * 0.5, .linear), kf(e, sc, .curve(.back, .out))])
            fadeIn(0.4)
        case .wipeIn:
            // Without a wipe style, a soft edge sweeping left to right (the edge travels left as wipe goes 0 → 1).
            if l.wipeStyle == nil { l.wipeStyle = WipeStyle(type: .linear, angle: 180, feather: 40) }
            put(.wipe, [kf(s, 1, .linear), kf(e, 0, .curve(.cubic, .inOut))])
        case .wipeOut:
            if l.wipeStyle == nil { l.wipeStyle = WipeStyle(type: .linear, angle: 0, feather: 40) }
            put(.wipe, [kf(s, 0, .linear), kf(e, 1, .curve(.cubic, .inOut))])
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
        case .glitchBurst:
            put(.glitch, [kf(s, 0, .linear), kf(s + d * 0.1, 0.9, .hold), kf(s + d * 0.45, 0.35, .hold),
                          kf(s + d * 0.7, 0.8, .hold), kf(e, 0, .hold)])
            put(.rgbSplit, [kf(s, 0, .linear), kf(s + d * 0.1, 8, .hold), kf(e, 0, .hold)])
        case .drawOn:
            if l.stroke == nil {
                l.stroke = .constant(l.fill.value(at: s))
                l.fill = .constant(.clear)
            }
            if l.strokeWidth.value(at: s) <= 0 { l.strokeWidth = .constant(6) }
            put(.trim, [kf(s, 0, .linear), kf(e, 1, .curve(.cubic, .inOut))])
        case .writeOn:
            // Handwriting: the outline writes piece by piece (letters one after another), then the fill fades in.
            let color = l.fill.value(at: e)
            if l.stroke == nil { l.stroke = .constant(color.a > 0 ? color : .white) }
            if l.strokeWidth.value(at: s) <= 0 { l.strokeWidth = .constant(3) }
            l.trimSequential = true
            put(.trim, [kf(s, 0, .linear), kf(s + d * 0.8, 1, .linear)])
            var clear = color
            clear.a = 0
            l.fill = l.fill.inserting([Keyframe(t: s, v: clear, easing: .linear), Keyframe(t: s + d * 0.7, v: clear, easing: .hold),
                                       Keyframe(t: e, v: color, easing: .easeOut)], replacing: s, e)
        case .typewriter:
            put(.reveal, [kf(s, 0, .linear), kf(e, 1, .linear)])
        case .decode:
            put(.scramble, [kf(s, 1, .linear), kf(e, 0, .linear)])
        case .textRise, .textPop, .textDrop, .textLines, .textOut, .textBlurIn, .textFocus:
            var a: TextAnimator
            switch preset {
            case .textBlurIn: a = TextAnimator(unit: .char, easing: .curve(.cubic, .out), blur: 24)
            case .textFocus: a = TextAnimator(unit: .word, easing: .curve(.quad, .out), scale: 1.6, blur: 16)
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
        try withLayer(id) { $0 = l }
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
        try withLayer(id) { l in
            if c == .stroke && l.stroke == nil {
                l.stroke = .constant(value)
                if l.strokeWidth.value(at: t) <= 0 { l.strokeWidth = .constant(4) }
                return
            }
            l[c] = l[c].setting(value, at: t)
        }
    }

    public mutating func setColorKeyframes(_ id: String, property c: ColorProperty, keyframes: [ColorKeyframe]) throws {
        try withLayer(id) { l in
            let fallback = l[c].value(at: 0)
            l[c] = ColorValue.make(keyframes, fallback: fallback)
            if c == .stroke && l.strokeWidth.value(at: 0) <= 0 && !keyframes.isEmpty { l.strokeWidth = .constant(4) }
        }
    }

    /// Links a layer to a parent (nil = unlink). With `keepPosition`, the layer's position is converted so it
    /// stays where it is at time t.
    public mutating func setParent(_ id: String, to parent: String?, at t: Double, keepPosition: Bool = true) throws {
        let i = try layerIndex(id)
        let parent = parent.flatMap { $0.isEmpty ? nil : $0 }
        if let p = parent {
            _ = try layerIndex(p)
            guard p != id, !isAncestor(id, of: p) else {
                throw SceneError.invalid("'\(p)' cannot be the parent of '\(id)' (that would make a loop)")
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


// MARK: - Shape and match transitions

extension MotionScene {
    /// Reveals the incoming layer through a path growing from `origin` (frame center by default) until it covers
    /// the frame, and hides the outgoing one by its inverse. Works with a copy of each layer for the transition
    /// span (track mattes cannot be keyed), so the originals stay plain before/after.
    mutating func shapeTransition(out outId: String?, in inId: String?, at s: Double, duration d: Double,
                                  shape: String, origin: (x: Double, y: Double)?) throws {
        let e = s + d
        let w = Double(width), h = Double(height)
        let ox = origin?.x ?? w / 2, oy = origin?.y ?? h / 2
        let path = try PathShape(shape)
        let box = path.cgPath.boundingBoxOfPath
        let radius = max(abs(box.minX), abs(box.maxX), abs(box.minY), abs(box.maxY), 0.5)
        // Far corner of the frame from the origin, so the shape covers everything at the end.
        let far = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: 0, y: h), CGPoint(x: w, y: h)]
            .map { hypot($0.x - ox, $0.y - oy) }.max() ?? hypot(w, h)
        let cover = far / radius * 1.05
        let base = (inId ?? outId ?? "reveal")
        var matte = MotionLayer(id: "\(base)-reveal", name: "Reveal Shape", type: .path, x: ox, y: oy)
        matte.d = .constant(path)
        matte.fill = .constant(.white)
        matte.start = s; matte.end = e
        matte.scale = .keyframes([MotionKeyframe(t: s, v: 0.001, easing: .linear),
                                  MotionKeyframe(t: e, v: cover, easing: .curve(.cubic, .inOut))])
        let matteId = addLayer(matte)
        func split(_ id: String, mode: MatteMode, incoming: Bool) throws {
            guard let i = layers.firstIndex(where: { $0.id == id }) else {
                throw SceneError.invalid("'\(id)' must be a top-level layer for a shape transition")
            }
            var copy = layers[i]
            copy.id = uniqueId(base: id + (incoming ? "-in" : "-out"))
            copy.name = layers[i].name + (incoming ? " (entering)" : " (leaving)")
            copy.start = s; copy.end = e
            copy.matte = Matte(source: matteId, mode: mode)
            if incoming { layers[i].start = max(layers[i].start, e) } else { layers[i].end = s }
            if copy.type == .group {
                var seen = Set(allLayers.map(\.id)); seen.insert(copy.id)
                Self.normalizeIds(&copy.children, seen: &seen)
            }
            layers.insert(copy, at: i + 1)
        }
        if let outId { try split(outId, mode: .alphaInverted, incoming: false) }
        if let inId { try split(inId, mode: .alpha, incoming: true) }
        // The matte stays on top of both copies.
        if let mi = layers.firstIndex(where: { $0.id == matteId }) {
            let m = layers.remove(at: mi)
            layers.append(m)
        }
    }

    /// The incoming layer appears where the outgoing one is and both move to the incoming one's place.
    mutating func matchTransition(out outId: String?, in inId: String?, at s: Double, duration d: Double) throws {
        let e = s + d
        func kf(_ t: Double, _ v: Double, _ easing: Easing = .easeInOut) -> MotionKeyframe { MotionKeyframe(t: t, v: v, easing: easing) }
        func put(_ l: inout MotionLayer, _ p: AnimProperty, _ kfs: [MotionKeyframe]) {
            l[p] = l[p].inserting(kfs, replacing: kfs.first!.t, kfs.last!.t)
        }
        guard let outId, let inId else { throw SceneError.invalid("A match cut needs both `out` and `in`") }
        let from = try layer(outId), to = try layer(inId)
        let fx = from.x.value(at: s), fy = from.y.value(at: s), fs = from.scale.value(at: s), fr = from.rotation.value(at: s)
        let tx = to.x.value(at: e), ty = to.y.value(at: e), ts = to.scale.value(at: e), tr = to.rotation.value(at: e)
        try withLayer(inId) { l in
            if l.start > s { l.start = s }
            put(&l, .x, [kf(s, fx, .linear), kf(e, tx, .curve(.expo, .out))])
            put(&l, .y, [kf(s, fy, .linear), kf(e, ty, .curve(.expo, .out))])
            put(&l, .scale, [kf(s, fs, .linear), kf(e, ts, .curve(.expo, .out))])
            if abs(fr - tr) > 0.01 { put(&l, .rotation, [kf(s, fr, .linear), kf(e, tr, .curve(.expo, .out))]) }
            put(&l, .opacity, [kf(s, 0, .linear), kf(s + d * 0.35, max(l.opacity.value(at: e), 0.01), .easeOut)])
        }
        try withLayer(outId) { l in
            put(&l, .x, [kf(s, fx, .linear), kf(e, tx, .curve(.expo, .out))])
            put(&l, .y, [kf(s, fy, .linear), kf(e, ty, .curve(.expo, .out))])
            put(&l, .scale, [kf(s, fs, .linear), kf(e, ts, .curve(.expo, .out))])
            if abs(fr - tr) > 0.01 { put(&l, .rotation, [kf(s, fr, .linear), kf(e, tr, .curve(.expo, .out))]) }
            put(&l, .opacity, [kf(s + d * 0.2, l.opacity.value(at: s), .linear), kf(s + d * 0.6, 0, .easeIn)])
            if l.end == nil || l.end! > e { l.end = e }
        }
    }
}
