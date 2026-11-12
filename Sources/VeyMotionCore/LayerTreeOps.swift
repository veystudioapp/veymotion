import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Edits that reach into groups (remove / add / reorder / duplicate a child by id), shifting a stretch of the
// timeline, and contact sheets. Layer ids are unique scene-wide, so a child is addressed like any layer.

extension MotionScene {
    /// The group holding a child layer, or nil for a top-level layer (or an unknown id).
    public func parentGroup(of id: String) -> String? {
        Self.container(of: id, in: layers)?.id
    }

    static func container(of id: String, in list: [MotionLayer]) -> MotionLayer? {
        for l in list where l.type == .group {
            if l.children.contains(where: { $0.id == id }) { return l }
            if let c = container(of: id, in: l.children) { return c }
        }
        return nil
    }

    /// Removes a layer wherever it is in the tree.
    public mutating func removeLayerAnywhere(_ id: String) throws {
        if layers.contains(where: { $0.id == id }) { try removeLayer(id); return }
        guard let g = parentGroup(of: id) else { throw SceneError.layerNotFound(id) }
        try withLayer(g) { group in
            group.children.removeAll { $0.id == id }
            for j in group.children.indices where group.children[j].matte?.source == id { group.children[j].matte = nil }
        }
    }

    /// Adds a layer inside a group (on top of its children, or at `index`) and returns its id.
    @discardableResult
    public mutating func addLayer(_ layer: MotionLayer, into groupId: String, at index: Int? = nil) throws -> String {
        var l = layer
        l.id = uniqueId(base: l.id.isEmpty ? l.type.rawValue : l.id)
        if l.name.isEmpty { l.name = l.id }
        if l.type == .group {
            var seen = Set(allLayers.map(\.id)); seen.insert(l.id)
            Self.normalizeIds(&l.children, seen: &seen)
        }
        let id = l.id
        var ok = false
        try withLayer(groupId) { g in
            guard g.type == .group else { return }
            g.children.insert(l, at: min(max(index ?? g.children.count, 0), g.children.count))
            ok = true
        }
        guard ok else { throw SceneError.invalid("'\(groupId)' is not a group") }
        return id
    }

    /// Moves a layer to an index among its siblings (top-level or inside its group).
    public mutating func moveLayerAnywhere(_ id: String, to index: Int) throws {
        if layers.contains(where: { $0.id == id }) { try moveLayer(id, to: index); return }
        guard let g = parentGroup(of: id) else { throw SceneError.layerNotFound(id) }
        try withLayer(g) { group in
            guard let i = group.children.firstIndex(where: { $0.id == id }) else { return }
            let l = group.children.remove(at: i)
            group.children.insert(l, at: min(max(index, 0), group.children.count))
        }
    }

    /// Copies a layer `count` times next to it (same container), each copy moved by `dx`/`dy` px and `dt`
    /// seconds more than the last. Ids come from `ids`, else "<id>-2", "<id>-3", … Returns the new ids.
    @discardableResult
    public mutating func duplicateLayer(_ id: String, count: Int, dx: Double = 0, dy: Double = 0, dt: Double = 0,
                                        ids: [String] = []) throws -> [String] {
        let original = try layer(id)
        var made: [String] = []
        var copies: [MotionLayer] = []
        for n in 1...max(1, count) {
            var c = original
            c.id = uniqueId(base: n - 1 < ids.count ? ids[n - 1] : id)
            // Keep the chosen ids unique against the copies made in this call too.
            while made.contains(c.id) || copies.contains(where: { $0.id == c.id }) { c.id = uniqueId(base: c.id + "-2") }
            c.name = original.name + (n == 1 ? " copy" : " copy \(n)")
            if c.type == .group {
                var seen = Set(allLayers.map(\.id) + made + copies.flatMap { [$0.id] + $0.children.map(\.id) })
                seen.insert(c.id)
                Self.normalizeIds(&c.children, seen: &seen)
            }
            let k = Double(n)
            if dx != 0 { c.x = c.x.offset(by: dx * k) }
            if dy != 0 { c.y = c.y.offset(by: dy * k) }
            if dt != 0 {
                c.start += dt * k
                if let e = c.end { c.end = e + dt * k }
                Self.shiftTree(&c, by: dt * k)
            }
            made.append(c.id)
            copies.append(c)
        }
        if let i = layers.firstIndex(where: { $0.id == id }) {
            layers.insert(contentsOf: copies, at: i + 1)
        } else if let g = parentGroup(of: id) {
            try withLayer(g) { group in
                guard let i = group.children.firstIndex(where: { $0.id == id }) else { return }
                group.children.insert(contentsOf: copies, at: i + 1)
            }
        }
        return made
    }

    /// Shifts keyframes, animators and children of a layer (not its start/end).
    static func shiftTree(_ l: inout MotionLayer, by d: Double) {
        l.shiftKeys(by: d)
        if l.localTime { return } // children count from the group's start: they move with it untouched
        for i in l.children.indices {
            l.children[i].start += d
            if let e = l.children[i].end { l.children[i].end = e + d }
            shiftTree(&l.children[i], by: d)
        }
    }

    /// Moves everything that happens at or after `from` by `by` seconds: layers starting there shift whole,
    /// layers spanning it keep their start and get longer (their later keyframes shift), the camera's later
    /// keyframes shift, and the scene grows by the same amount (shrinks when `by` is negative, never below
    /// its content). Returns the ids of the layers touched.
    @discardableResult
    public mutating func shiftTime(from: Double, by: Double, extendDuration: Bool = true) throws -> [String] {
        guard by != 0 else { return [] }
        let eps = 1e-6
        var touched: [String] = []
        for i in layers.indices {
            let s = layers[i].start, e = layers[i].effectiveEnd(sceneDuration: duration)
            if s >= from - eps {
                let d = max(by, -s)
                layers[i].start += d
                if let end = layers[i].end { layers[i].end = end + d }
                Self.shiftTree(&layers[i], by: d)
                touched.append(layers[i].id)
            } else if e > from + eps {
                if let end = layers[i].end { layers[i].end = max(from, end + by) }
                Self.shiftLate(&layers[i], from: from, by: by)
                touched.append(layers[i].id)
            }
        }
        if var cam = camera {
            cam.shiftKeys(after: from, by: by)
            camera = cam
        }
        if extendDuration {
            duration = max(duration + by, layers.map { $0.effectiveEnd(sceneDuration: duration) }.max() ?? 1, 1)
        }
        return touched
    }

    /// Shifts only the keyframes (and animators, children) at or after `from`.
    static func shiftLate(_ l: inout MotionLayer, from: Double, by d: Double) {
        for p in AnimProperty.allCases where l[p].isAnimated { l[p] = l[p].shifted(after: from, by: d) }
        for c in ColorProperty.allCases where l[c].isAnimated { l[c] = l[c].shifted(after: from, by: d) }
        l.d = l.d.shifted(after: from, by: d)
        for i in l.textAnimators.indices where l.textAnimators[i].start >= from { l.textAnimators[i].start += d }
        for i in l.particles.bursts.indices where l.particles.bursts[i].t >= from { l.particles.bursts[i].t += d }
        if l.localTime { return }
        for i in l.children.indices {
            if l.children[i].start >= from {
                l.children[i].start += d
                if let e = l.children[i].end { l.children[i].end = e + d }
                shiftTree(&l.children[i], by: d)
            } else {
                if let e = l.children[i].end, e > from { l.children[i].end = max(from, e + d) }
                shiftLate(&l.children[i], from: from, by: d)
            }
        }
    }
}

extension Animated {
    /// Keyframes at or after `after` moved by `d` (earlier ones stay; order is kept by clamping).
    public func shifted(after: Double, by d: Double) -> Animated<V> {
        guard isAnimated else { return self }
        var out: [Keyframe<V>] = []
        for k in keyframeList {
            var t = k.t
            if t >= after - 1e-6 { t = max(t + d, after) }
            if let last = out.last?.t, t < last { t = last }
            out.append(Keyframe(t: t, v: k.v, easing: k.easing))
        }
        return .keyframes(out)
    }
}

extension Animated where V == Double {
    /// The value (constant or every keyframe) moved by `d`.
    public func offset(by d: Double) -> Animated<Double> {
        switch self {
        case let .constant(v): return .constant(v + d)
        case let .keyframes(k): return .keyframes(k.map { Keyframe(t: $0.t, v: $0.v + d, easing: $0.easing) })
        }
    }
}

extension Camera {
    mutating func shiftKeys(after: Double, by d: Double) {
        x = x.shifted(after: after, by: d); y = y.shifted(after: after, by: d)
        zoom = zoom.shifted(after: after, by: d); rotation = rotation.shifted(after: after, by: d)
        focus = focus.shifted(after: after, by: d); aperture = aperture.shifted(after: after, by: d)
        z = z.shifted(after: after, by: d); orbitX = orbitX.shifted(after: after, by: d); orbitY = orbitY.shifted(after: after, by: d)
        distance = distance?.shifted(after: after, by: d); lens = lens?.shifted(after: after, by: d)
    }
}

extension FrameRenderer {
    /// Several frames in one image, `columns` per row, each labeled with its time. `scale` is per frame.
    public func contactSheetPNG(_ scene: MotionScene, times: [Double], columns: Int = 4, scale: Double = 0.25) -> Data? {
        guard !times.isEmpty else { return nil }
        let fw = max(1, Int((Double(scene.width) * scale).rounded()))
        let fh = max(1, Int((Double(scene.height) * scale).rounded()))
        let cols = max(1, min(columns, times.count)), rows = (times.count + cols - 1) / cols
        let gap = 6, label = 22
        let W = cols * fw + (cols + 1) * gap, H = rows * (fh + label) + (rows + 1) * gap
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (i, t) in times.enumerated() {
            guard let img = makeImage(scene, at: t, scale: scale) else { continue }
            let c = i % cols, r = i / cols
            let x = gap + c * (fw + gap)
            let yTop = gap + r * (fh + label + gap)           // from the top
            let y = H - yTop - fh                             // CG origin is bottom-left
            ctx.draw(img, in: CGRect(x: x, y: y, width: fw, height: fh))
            // Label: "t=2.50s" in a small sans, white.
            let text = String(format: "%.2fs", t) as CFString
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil)
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0.9, alpha: 1)]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text, attrs as CFDictionary))
            ctx.textPosition = CGPoint(x: CGFloat(x + 4), y: CGFloat(y - label + 6))
            CTLineDraw(line, ctx)
        }
        guard let out = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
