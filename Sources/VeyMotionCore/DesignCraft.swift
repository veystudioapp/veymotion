import CoreGraphics
import Foundation

// The second half of the design lint (`designIssues` calls it): what makes a piece look machine-made even when
// nothing is flat or frozen. Sameness (every layer enters the same way, at the same instant, in six hues and four
// fonts), text nobody has time to read, and what only shows in the picture: text that cannot be told from what is
// behind it, text over a busy picture, texts on top of each other, columns that miss each other by a few pixels,
// and text under a phone app's buttons. The picture rules render a few small frames without the text layers and
// measure the pixels behind each text, so they need a renderer (`pixels: false` skips the renders).

extension RGBA {
    /// Hue in degrees (0 ..< 360); 0 for grays.
    var hue: Double {
        let hi = max(r, g, b), lo = min(r, g, b), d = hi - lo
        guard d > 1e-6 else { return 0 }
        var h: Double
        if hi == r { h = (g - b) / d } else if hi == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    /// WCAG relative luminance (sRGB decoded), for contrast ratios.
    var relativeLuminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

/// A rendered frame as bytes, to measure what is behind a text.
private struct FramePixels {
    let width: Int, height: Int
    private var data: [UInt8]
    private static let linear: [Double] = (0..<256).map { i in
        let c = Double(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w; height = h; data = bytes
    }

    /// Mean relative luminance of the area (rows from the top), and how much its brightness varies (standard
    /// deviation of the encoded luma, 0 flat … 0.5 half black half white).
    func stats(in rect: CGRect) -> (luminance: Double, spread: Double)? {
        let x0 = max(0, Int(rect.minX.rounded(.down))), x1 = min(width, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY.rounded(.down))), y1 = min(height, Int(rect.maxY.rounded(.up)))
        guard x1 > x0, y1 > y0 else { return nil }
        let step = max(1, Int((Double((x1 - x0) * (y1 - y0)) / 3000).squareRoot()))
        var n = 0.0, lum = 0.0, sum = 0.0, squares = 0.0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                let i = (y * width + x) * 4
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                lum += 0.2126 * Self.linear[r] + 0.7152 * Self.linear[g] + 0.0722 * Self.linear[b]
                let luma = (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
                sum += luma; squares += luma * luma
                n += 1
                x += step
            }
            y += step
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        return (lum / n, max(0, squares / n - mean * mean).squareRoot())
    }
}

extension MotionScene {
    /// A layer that is not a group, with the groups around it (outermost first). `offset` turns its own clock into
    /// scene time (groups with localTime); each group carries the offset of its own clock.
    struct PlacedLayer {
        var layer: MotionLayer
        var offset: Double
        var chain: [(group: MotionLayer, offset: Double)]
    }

    /// Every content layer however deep it sits, without the look's layers and sound.
    func placedLayers() -> [PlacedLayer] {
        let lookIds: Set<String> = [Self.lookGroupId, Self.lookFinishId]
        var out: [PlacedLayer] = []
        func collect(_ list: [MotionLayer], _ chain: [(group: MotionLayer, offset: Double)], _ offset: Double) {
            for l in list where !lookIds.contains(l.id) && l.type != .audio {
                if l.type == .group {
                    collect(l.children, chain + [(l, offset)], l.localTime ? offset + l.start : offset)
                } else {
                    out.append(PlacedLayer(layer: l, offset: offset, chain: chain))
                }
            }
        }
        collect(layers, [], 0)
        return out
    }

    /// When the layer is on screen, in scene time: its own life cut by its groups' lives.
    func span(of p: PlacedLayer) -> (start: Double, end: Double)? {
        var a = p.layer.start + p.offset, b = p.layer.effectiveEnd(sceneDuration: duration) + p.offset
        for (g, o) in p.chain {
            a = max(a, g.start + o)
            b = min(b, g.effectiveEnd(sceneDuration: duration) + o)
        }
        a = max(a, 0); b = min(b, duration)
        return b > a ? (a, b) : nil
    }

    /// The layer's opacity times its groups', at a scene time.
    func opacity(of p: PlacedLayer, at time: Double) -> Double {
        p.chain.reduce(p.layer.value(.opacity, at: time - p.offset)) { $0 * $1.group.value(.opacity, at: time - $1.offset) }
    }

    /// Layer px → frame px through every group around it (a group draws its children in its own box, centered on
    /// the group's origin).
    func frameTransform(of p: PlacedLayer, at time: Double) -> CGAffineTransform {
        func place(_ scene: MotionScene, _ i: Int) -> CGAffineTransform {
            guard i < p.chain.count else { return scene.worldTransform(of: p.layer, at: time - p.offset) }
            let (g, o) = p.chain[i]
            let gt = time - o
            let sub = scene.subscene(of: g, at: g.localTime ? gt - g.start : gt)
            return place(sub, i + 1)
                .concatenating(CGAffineTransform(translationX: -Double(sub.width) / 2, y: -Double(sub.height) / 2))
                .concatenating(scene.worldTransform(of: g, at: gt))
        }
        return place(self, 0)
    }

    /// "Inter-Bold", "Inter SemiBold" and "inter" are one family.
    static func fontFamilyKey(_ name: String) -> String {
        let styles: Set<String> = ["thin", "extralight", "ultralight", "light", "regular", "book", "medium", "semibold",
                                   "demibold", "bold", "extrabold", "ultrabold", "black", "heavy", "italic", "oblique",
                                   "condensed", "expanded", "display", "text", "variable"]
        var words = name.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map(String.init)
        while words.count > 1, let last = words.last, styles.contains(last) { words.removeLast() }
        return words.joined()
    }

    func craftIssues(renderer: FrameRenderer?, pixels: Bool) -> [DesignIssue] {
        var out: [DesignIssue] = []
        let w = Double(width), h = Double(height)
        let placed = placedLayers()
        guard !placed.isEmpty else { return out }
        let matteSources = Set(allLayers.compactMap { $0.matte?.source })
        func clock(_ t: Double) -> String { String(format: "%.1fs", t) }

        // 15 / 16. Entrances: what moves in the first quarter second of a layer's life, how, and when.
        struct Entrance {
            var id: String
            var time: Double
            var end: Double
            var props: String
            var signature: String
            /// Copies of one text stacked for an echo or an extrusion move as one thing.
            var text: String
        }
        var entrances: [Entrance] = []
        for p in placed {
            let l = p.layer
            var props: [String] = [], easing: Easing?, length = 0.0, first = Double.infinity
            for prop in AnimProperty.allCases {
                let k = l[prop].keyframeList
                guard k.count >= 2, abs(k[0].t - l.start) < 0.25, k[0].v != k[1].v else { continue }
                props.append(prop.rawValue)
                if easing == nil { easing = k[1].easing }
                length = max(length, k[1].t - k[0].t)
                first = min(first, k[0].t)
            }
            for a in l.textAnimators where abs(a.start - l.start) < 0.25 {
                props.append("letters")
                if easing == nil { easing = a.easing }
                length = max(length, a.duration)
                first = min(first, a.start)
            }
            guard !props.isEmpty, let easing else { continue }
            let what = props.sorted().joined(separator: " + ")
            let signature = "\(what), \(easing.string), \(String(format: "%.1f", length)) s"
            entrances.append(Entrance(id: l.id, time: first + p.offset, end: first + p.offset + length, props: what,
                                      signature: signature, text: l.type == .text ? l.text : ""))
        }
        if entrances.count >= 12 {
            let groups = Dictionary(grouping: entrances, by: \.signature)
            if let top = groups.max(by: { $0.value.count < $1.value.count }), Double(top.value.count) >= Double(entrances.count) * 0.8 {
                out.append(DesignIssue(severity: .warning, code: "same-entrance",
                                       message: "\(top.value.count) of \(entrances.count) layers enter the same way (\(top.key)), so the piece reads as one preset applied to everything",
                                       fix: "give each role its own entrance: the hero a reveal of its own (per letter, through a matte, drawn on with trim), supporting text a short quiet slide, decoration a slow drift; change direction and length between sections",
                                       layers: top.value.map(\.id)))
            }
        }
        // The same move, started and finished at the same instant by five layers or more. Starting together with
        // different lengths is a stagger of its own, so that passes.
        var together: [[Entrance]] = []
        var run: [Entrance] = []
        func close() {
            for same in Dictionary(grouping: run, by: { "\($0.props) \(Int(($0.end * 25).rounded()))" }).values {
                var texts = Set<String>()
                let distinct = same.filter { $0.text.isEmpty || texts.insert($0.text).inserted }
                if distinct.count >= 5 { together.append(distinct) }
            }
            run = []
        }
        for e in entrances.sorted(by: { $0.time < $1.time }) {
            if let f = run.first, e.time - f.time > 0.02 { close() }
            run.append(e)
        }
        close()
        if !together.isEmpty {
            together.sort { $0[0].time < $1[0].time }
            let times = together.prefix(4).map { "\($0.count) at \(clock($0[0].time))" }.joined(separator: ", ")
            out.append(DesignIssue(severity: .warning, code: "no-stagger",
                                   message: "Layers make the same move at the same instant (\(times)), so nothing leads the eye",
                                   fix: "start them 0.06–0.12 s apart in reading order (most important first), or move a unit as one group and stagger only its parts",
                                   layers: together.flatMap { $0.map(\.id) }))
        }

        // Text shown through a matte (a reveal, or the copies a shape transition makes for its span) is judged by eye.
        let texts = placed.filter { p in
            p.layer.type == .text && !p.layer.text.isEmpty && !matteSources.contains(p.layer.id) && p.layer.matte == nil
                && !p.chain.contains { $0.group.matte != nil || matteSources.contains($0.group.id) }
        }

        // 17. Fonts
        let families = Set(texts.compactMap { p -> String? in
            guard let name = p.layer.fontName, !name.isEmpty else { return nil }
            return Self.fontFamilyKey(name)
        })
        if families.count > 3 {
            out.append(DesignIssue(severity: .warning, code: "too-many-fonts",
                                   message: "\(families.count) font families in one piece",
                                   fix: "keep two: one for titles, one for everything else; get contrast from size and weight instead",
                                   layers: []))
        }

        // 18. Palette: hue families among the flat colors of text and plain shapes.
        var hues: [(hue: Double, id: String)] = []
        for p in placed where [.text, .rect, .ellipse].contains(p.layer.type) && p.layer.gradient == nil {
            let l = p.layer
            guard case let .constant(c) = l.type == .text ? l.color : l.fill, c.saturation > 0.3, c.a > 0.5 else { continue }
            // Window dots, status lights and other specks are not the palette.
            if l.type != .text, l.value(.width, at: l.start) * l.value(.height, at: l.start) < w * h * 0.004 { continue }
            hues.append((c.hue, l.id))
        }
        if hues.count >= 6 {
            // Hues within 25° of the family's first one are the same family (the circle closes at 360).
            var kinds: [Double] = []
            for (hue, _) in hues.sorted(by: { $0.hue < $1.hue }) {
                if let last = kinds.last, hue - last <= 25 { continue }
                kinds.append(hue)
            }
            if kinds.count > 1, let f = kinds.first, let l = kinds.last, f + 360 - l <= 25 { kinds.removeLast() }
            if kinds.count >= 6 {
                out.append(DesignIssue(severity: .warning, code: "too-many-hues",
                                       message: "\(kinds.count) unrelated hues on text and shapes",
                                       fix: "one accent hue + one supporting hue + neutrals; make the other colors tints or shades of those two",
                                       layers: hues.map(\.id)))
            }
        }

        // 19. Reading time: about 4 words a second.
        var rushed: [String] = []
        for p in texts {
            let words = p.layer.text.split(whereSeparator: { $0 == " " || $0.isNewline }).count
            guard words >= 3, let (a, b) = span(of: p), b - a < Double(words) * 0.2 else { continue }
            rushed.append(p.layer.id)
        }
        if !rushed.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "reading-time",
                                   message: "Text is gone before it can be read (under 0.2 s per word)",
                                   fix: "hold it about 1 s per 4 words after it has arrived, or cut the words", layers: rushed))
        }

        // The rest looks at where each text is in the frame. Every text is looked at once, at 60% of its life, and
        // texts on screen together share a time (and a render).
        guard let renderer else { return out }
        struct Spot {
            var placed: PlacedLayer
            var start: Double, end: Double
            var time: Double
        }
        var spots: [Spot] = []
        for p in texts where p.layer.textPath == nil && !p.layer.threeD {
            guard let (a, b) = span(of: p) else { continue }
            spots.append(Spot(placed: p, start: a, end: b, time: a + (b - a) * 0.6))
        }
        spots.sort { $0.time < $1.time }
        var times: [Double] = []
        for i in spots.indices {
            let s = spots[i]
            let own = opacity(of: s.placed, at: s.time)
            if let shared = times.first(where: { $0 >= s.start && $0 < s.end && opacity(of: s.placed, at: $0) >= own * 0.9 }) {
                spots[i].time = shared
            } else {
                times.append(s.time)
            }
        }
        let maxFrames = 6
        if times.count > maxFrames {
            let step = Double(times.count) / Double(maxFrames)
            times = (0..<maxFrames).map { times[Int(Double($0) * step)] }
        }

        struct Seen {
            var layer: MotionLayer
            var box: CGRect          // glyphs, frame px
            var edge: Double         // the x its alignment hangs on
            var alpha: Double
            var size: Double
            var upright: Bool
            var steady: Bool         // nothing shakes it
            var own: Bool            // this is the time the text is judged at
            var t: Double            // that time on the layer's clock
        }
        let unit = max(w, h) / 1920
        var overlaps: [String] = [], overlapNotes: [String] = []
        var misaligned: [String] = [], misalignedNotes: [String] = []
        var faint: [String] = [], faintNotes: [String] = []
        var busy: [String] = [], covered: [String] = []
        let scale = min(1, 400 / w)
        let vertical = h >= w * 1.5

        for time in times {
            var seen: [Seen] = []
            for s in spots where time >= s.start && time < s.end {
                let l = s.placed.layer, t = time - s.placed.offset
                let alpha = opacity(of: s.placed, at: time)
                guard alpha > 0.05 else { continue }
                let glyphs = renderer.glyphPaths(l, at: t)
                guard !glyphs.isEmpty else { continue }
                let local = glyphs.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
                let m = frameTransform(of: s.placed, at: time)
                let half = Double(renderer.textBoxSize(l, at: t)?.width ?? local.width) / 2
                let hang = CGPoint(x: l.align == .left ? -half : l.align == .right ? half : 0, y: 0).applying(m)
                let turn = abs(atan2(Double(m.b), Double(m.a))) * 180 / .pi
                let grow = (Double(m.a) * Double(m.a) + Double(m.b) * Double(m.b)).squareRoot()
                seen.append(Seen(layer: l, box: local.applying(m), edge: Double(hang.x), alpha: alpha, size: l.fontSize * grow,
                                 upright: turn < 3, steady: l.wiggle.isEmpty && l.audioReact.isEmpty, own: s.time == time, t: t))
            }
            // Copies of one text stacked for an echo or an extrusion: only the top one is the text.
            var top: [String: Int] = [:]
            for (i, s) in seen.enumerated() { top[s.layer.text] = i }
            let echoes = seen
            seen = seen.enumerated().filter { top[$0.element.layer.text] == $0.offset }.map(\.element)
            guard !seen.isEmpty else { continue }

            // 20. Texts on top of each other. 21. Columns that almost line up.
            for i in seen.indices {
                for j in seen.indices where j > i {
                    let a = seen[i], b = seen[j]
                    guard a.alpha >= 0.6, b.alpha >= 0.6, a.upright, b.upright, a.layer.text != b.layer.text else { continue }
                    let cut = a.box.intersection(b.box)
                    let smaller = min(a.box.width * a.box.height, b.box.width * b.box.height)
                    let ratio = max(a.size, b.size) / max(1, min(a.size, b.size))
                    if !cut.isNull, smaller > 0, cut.width * cut.height >= smaller * 0.2, ratio <= 3 {
                        if !overlaps.contains(a.layer.id) || !overlaps.contains(b.layer.id) {
                            overlapNotes.append("\(a.layer.id) × \(b.layer.id) at \(clock(time))")
                        }
                        for id in [a.layer.id, b.layer.id] where !overlaps.contains(id) { overlaps.append(id) }
                        continue
                    }
                    // Stacked in one column, hanging on the same side, a few pixels apart.
                    let stacked = a.box.maxY <= b.box.minY || b.box.maxY <= a.box.minY
                    let column = a.box.minX < b.box.maxX && b.box.minX < a.box.maxX
                    let off = abs(a.edge - b.edge)
                    if stacked, column, a.layer.align == b.layer.align, a.steady, b.steady, off >= 3 * unit, off <= 8 * unit {
                        if !misaligned.contains(a.layer.id) || !misaligned.contains(b.layer.id) {
                            misalignedNotes.append("\(a.layer.id) / \(b.layer.id): \(Int(off.rounded())) px")
                        }
                        for id in [a.layer.id, b.layer.id] where !misaligned.contains(id) { misaligned.append(id) }
                    }
                }
            }

            // 22. Under a phone app's buttons and caption (vertical pieces).
            if vertical {
                for s in seen where s.own && s.alpha >= 0.6 {
                    if s.box.maxY > h * 0.86 || (s.box.maxX > w * 0.88 && s.box.midY > h * 0.5) { covered.append(s.layer.id) }
                }
            }

            // 23 / 24. What is behind each text: the frame without its texts, small.
            guard pixels else { continue }
            let judged = seen.filter { s in
                let l = s.layer, t = s.t
                return s.own && s.alpha >= 0.5 && l.gradient == nil && l.blendMode == .normal && l.matte == nil
                    && l.textHighlights.isEmpty && l.stroke == nil && l.value(.outline, at: t) <= 0 && l.value(.blur, at: t) < 2
            }
            guard !judged.isEmpty else { continue }
            var bare = self
            for s in echoes { try? bare.removeLayerAnywhere(s.layer.id) }
            guard let image = renderer.makeImage(bare, at: time, scale: scale), let frame = FramePixels(image) else { continue }
            for s in judged {
                let l = s.layer, t = s.t
                let area = CGRect(x: s.box.minX * scale, y: s.box.minY * scale, width: s.box.width * scale, height: s.box.height * scale)
                guard let color = l.color(.color, at: t), let behind = frame.stats(in: area) else { continue }
                let a = min(1, s.alpha * color.a)
                let ink = color.relativeLuminance * a + behind.luminance * (1 - a)
                let ratio = (max(ink, behind.luminance) + 0.05) / (min(ink, behind.luminance) + 0.05)
                let shadowed = l.value(.shadowOpacity, at: t) > 0.3
                // Display type reads by its shape at a contrast that would lose body text.
                let floor = s.size >= min(w, h) * 0.1 ? 1.5 : 2.5
                if ratio < floor, !(shadowed && ratio >= 1.6) {
                    faint.append(l.id)
                    faintNotes.append("\(l.id) \(String(format: "%.1f", ratio)):1")
                } else if behind.spread > 0.22, !shadowed {
                    busy.append(l.id)
                }
            }
        }

        if !overlaps.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "text-overlap",
                                   message: "Texts sit on top of each other (\(overlapNotes.prefix(4).joined(separator: ", ")))",
                                   fix: "move them apart (leave at least half a line between blocks), shorten one, or end the first before the second arrives",
                                   layers: overlaps))
        }
        if !faint.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "low-contrast",
                                   message: "Text is hard to tell from what is behind it (measured \(faintNotes.prefix(5).joined(separator: ", ")); 4.5:1 reads well)",
                                   fix: "near-white on dark or near-black on light, or put a plate behind it (a dark/light rounded rect at 60–80% opacity), or shadowOpacity 0.6 + shadowBlur 20",
                                   layers: faint))
        }
        if !busy.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "busy-behind-text",
                                   message: "Text lies over a busy picture (light and dark areas cross the letters)",
                                   fix: "dim or blur what is behind it (a black rect or gradient at 40–60% under the text), move it to a calm area, or give it a plate or a soft shadow",
                                   layers: busy))
        }
        if !misaligned.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "misaligned",
                                   message: "Stacked texts miss each other's edge by a few pixels (\(misalignedNotes.prefix(4).joined(separator: ", ")))",
                                   fix: "hang them on one line: same align and the same edge (for left-aligned text set maxWidth on both and the same x), or offset them clearly on purpose (40 px or more)",
                                   layers: misaligned))
        }
        if !covered.isEmpty {
            out.append(DesignIssue(severity: .warning, code: "platform-ui",
                                   message: "Text in the part of a vertical video that TikTok / Reels / Shorts cover with their caption and buttons (bottom 14%, right 12% of the lower half)",
                                   fix: "keep text above 86% of the height and left of 88% of the width in the lower half",
                                   layers: covered))
        }
        return out
    }
}
