import CoreGraphics
import Foundation

// Procedural motion: wiggle noise, motion paths, per-character text animators and layer transforms.

// MARK: - Noise

public enum Noise {
    /// Stable 64-bit FNV-1a hash (Swift's `hashValue` changes between launches).
    public static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    /// Deterministic random number in [-1, 1] for an integer lattice point.
    static func lattice(_ i: Int, _ seed: UInt64) -> Double {
        let h = mix(seed ^ UInt64(bitPattern: Int64(i)) &* 0x2545F4914F6CDD1D)
        return Double(h >> 11) / Double(1 << 53) * 2 - 1
    }

    /// Deterministic random number in [0, 1).
    public static func unit(_ i: Int, _ seed: UInt64) -> Double { (lattice(i, seed) + 1) / 2 }

    /// Smooth 1D value noise in about [-1, 1].
    public static func value(_ x: Double, seed: UInt64) -> Double {
        let i = Int(floor(x))
        let f = x - floor(x)
        let u = f * f * f * (f * (f * 6 - 15) + 10) // quintic fade
        return lattice(i, seed) + (lattice(i + 1, seed) - lattice(i, seed)) * u
    }

    /// Two octaves of value noise, normalized to about [-1, 1].
    public static func fractal(_ x: Double, seed: UInt64) -> Double {
        (value(x, seed: seed) + 0.5 * value(x * 2.03 + 17.1, seed: seed &+ 1)) / 1.5
    }
}

/// Random but smooth movement added on top of a property (like After Effects' wiggle()).
public struct Wiggle: Codable, Equatable, Hashable, Sendable {
    /// Largest offset, in the property's unit (px, degrees, 0…1 for opacity…).
    public var amount: Double
    /// Wobbles per second.
    public var frequency: Double
    /// Change to get a different motion with the same settings.
    public var seed: Int

    public init(amount: Double, frequency: Double = 2, seed: Int = 0) {
        self.amount = amount; self.frequency = frequency; self.seed = seed
    }

    enum CodingKeys: String, CodingKey { case amount, frequency, seed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 10
        frequency = max(0, try c.decodeIfPresent(Double.self, forKey: .frequency) ?? 2)
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? 0
    }

    public func offset(at t: Double, salt: UInt64) -> Double {
        amount * Noise.fractal(t * frequency, seed: salt ^ Noise.mix(UInt64(bitPattern: Int64(seed))))
    }
}

// MARK: - Audio react

/// Where an audio layer's file plays in the scene. Filled in by `MotionScene.resolveLinks`, not saved.
public struct AudioLink: Equatable, Hashable, Sendable {
    public var path: String
    public var start: Double
    public var trimIn: Double
    public var end: Double

    /// File time playing at scene time t, or nil when the layer is silent then.
    public func fileTime(at t: Double) -> Double? {
        t >= start && t < end ? t - start + trimIn : nil
    }
}

/// Adds `amount` × the music's level (0…1) in a band to a property: the layer moves with the sound.
public struct AudioReact: Codable, Equatable, Hashable, Sendable {
    public static let defaultRelease = 0.2

    /// Offset at full level, in the property's unit (negative = the other way).
    public var amount: Double
    public var band: AudioBand
    /// Seconds the reaction takes to fall back after a peak.
    public var release: Double
    /// Audio layer id; nil = the scene's music layer (or its first audio layer).
    public var source: String?
    /// The source as resolved by the scene.
    public var link: AudioLink?

    public init(amount: Double, band: AudioBand = .bass, release: Double = defaultRelease, source: String? = nil) {
        self.amount = amount; self.band = band; self.release = release; self.source = source
    }

    enum CodingKeys: String, CodingKey { case amount, band, release, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0.1
        band = try c.decodeIfPresent(AudioBand.self, forKey: .band) ?? .level
        release = max(0.01, try c.decodeIfPresent(Double.self, forKey: .release) ?? Self.defaultRelease)
        source = try c.decodeIfPresent(String.self, forKey: .source).flatMap { $0.isEmpty ? nil : $0 }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(amount, forKey: .amount)
        try c.encode(band, forKey: .band)
        try c.encode(release, forKey: .release)
        try c.encodeIfPresent(source, forKey: .source)
    }

    public func offset(at t: Double) -> Double {
        guard amount != 0, let link, let ft = link.fileTime(at: t),
              let env = AudioAnalysisCache.envelope(path: link.path, band: band, release: release) else { return 0 }
        return amount * AudioAnalysis.sample(env, at: ft)
    }
}

// MARK: - Motion path

public struct PathPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }

    enum CodingKeys: String, CodingKey { case x, y }

    /// Accepts [x, y] or {"x": …, "y": …}; written as [x, y].
    public init(from decoder: Decoder) throws {
        if var a = try? decoder.unkeyedContainer() {
            x = try a.decode(Double.self)
            y = try a.decode(Double.self)
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            x = try c.decode(Double.self, forKey: .x)
            y = try c.decode(Double.self, forKey: .y)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var a = encoder.unkeyedContainer()
        try a.encode(x)
        try a.encode(y)
    }
}

/// A path the layer's center travels along. `pathProgress` (0…1, animatable) is the position along it,
/// measured by distance so the speed is even.
public struct MotionPath: Codable, Equatable, Hashable, Sendable {
    /// Scene pixels (relative to the parent's center when the layer has a parent).
    public var points: [PathPoint]
    /// true = smooth curve through the points (Catmull-Rom); false = straight segments.
    public var smooth: Bool
    /// Join the last point back to the first; progress then wraps around.
    public var closed: Bool
    /// Rotate the layer to face the direction of travel (added to `rotation`).
    public var orient: Bool

    public init(points: [PathPoint], smooth: Bool = true, closed: Bool = false, orient: Bool = false) {
        self.points = points; self.smooth = smooth; self.closed = closed; self.orient = orient
    }

    enum CodingKeys: String, CodingKey { case points, smooth, closed, orient }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decode([PathPoint].self, forKey: .points)
        smooth = try c.decodeIfPresent(Bool.self, forKey: .smooth) ?? true
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed) ?? false
        orient = try c.decodeIfPresent(Bool.self, forKey: .orient) ?? false
    }

    /// Dense polyline approximating the path.
    public func polyline(samplesPerSegment: Int = 32) -> [CGPoint] {
        let pts = points.map { CGPoint(x: $0.x, y: $0.y) }
        guard pts.count >= 2 else { return pts }
        let n = pts.count
        let segments = closed ? n : n - 1
        func p(_ i: Int) -> CGPoint {
            if closed { return pts[((i % n) + n) % n] }
            return pts[min(max(i, 0), n - 1)]
        }
        var out: [CGPoint] = [pts[0]]
        for s in 0..<segments {
            let p0 = p(s - 1), p1 = p(s), p2 = p(s + 1), p3 = p(s + 2)
            let steps = smooth ? samplesPerSegment : 1
            for k in 1...steps {
                let t = Double(k) / Double(steps)
                if !smooth {
                    out.append(CGPoint(x: p1.x + (p2.x - p1.x) * t, y: p1.y + (p2.y - p1.y) * t))
                    continue
                }
                let t2 = t * t, t3 = t2 * t
                func cr(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append(CGPoint(x: cr(p0.x, p1.x, p2.x, p3.x), y: cr(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        return out
    }

    /// Point and direction (degrees, 0 = +x, clockwise on screen) at a progress along the path.
    public func sample(_ progress: Double) -> (point: CGPoint, angle: Double) {
        let poly = polyline()
        guard let first = poly.first else { return (.zero, 0) }
        guard poly.count >= 2 else { return (first, 0) }
        var lengths: [Double] = [0]
        lengths.reserveCapacity(poly.count)
        for i in 1..<poly.count {
            lengths.append(lengths[i - 1] + hypot(poly[i].x - poly[i - 1].x, poly[i].y - poly[i - 1].y))
        }
        let total = lengths.last ?? 0
        guard total > 1e-9 else { return (first, 0) }
        var pr = progress
        if closed { pr -= floor(pr) } else { pr = min(max(pr, 0), 1) }
        let target = pr * total
        var lo = 0, hi = lengths.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if lengths[mid] <= target { lo = mid } else { hi = mid }
        }
        let a = poly[lo], b = poly[hi]
        let seg = lengths[hi] - lengths[lo]
        let f = seg > 0 ? (target - lengths[lo]) / seg : 0
        let pt = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        return (pt, atan2(b.y - a.y, b.x - a.x) * 180 / .pi)
    }
}

// MARK: - Text animators

public enum TextUnit: String, Codable, CaseIterable, Sendable {
    case char, word, line
}

public enum StaggerOrder: String, Codable, CaseIterable, Sendable {
    case forward, reverse, center, edges, random
}

public enum AnimatorMode: String, Codable, CaseIterable, Sendable {
    /// Units arrive from the "away" state to their normal state.
    case `in`
    /// Units leave from their normal state to the "away" state.
    case out
}

/// Animates each character, word or line of a text layer separately, one after another.
/// The `opacity`/`x`/`y`/`scale`/`rotation` fields describe the "away" state; units animate between it and
/// their normal look.
public struct TextAnimator: Codable, Equatable, Hashable, Sendable {
    public var unit: TextUnit
    public var mode: AnimatorMode
    /// Scene time when the first unit starts.
    public var start: Double
    /// Seconds each unit takes.
    public var duration: Double
    /// Seconds between the starts of consecutive units.
    public var stagger: Double
    public var order: StaggerOrder
    public var easing: Easing
    public var opacity: Double
    /// Offset in px (y down).
    public var x: Double
    public var y: Double
    public var scale: Double
    /// Degrees.
    public var rotation: Double
    /// Blur (px) and color of the away state (nil color = the text's own).
    public var blur: Double
    public var color: RGBA?
    public var seed: Int
    /// Variable-font axes of the away state (0 = unchanged): each unit goes from the text's own wght/wdth to these.
    public var fontWeightAxis: Double
    public var fontWidth: Double

    public init(unit: TextUnit = .char, mode: AnimatorMode = .in, start: Double = 0, duration: Double = 0.5,
                stagger: Double = 0.04, order: StaggerOrder = .forward, easing: Easing? = nil,
                opacity: Double = 0, x: Double = 0, y: Double = 0, scale: Double = 1, rotation: Double = 0,
                blur: Double = 0, color: RGBA? = nil, seed: Int = 0, fontWeightAxis: Double = 0, fontWidth: Double = 0) {
        self.unit = unit; self.mode = mode; self.start = start; self.duration = duration; self.stagger = stagger
        self.order = order; self.easing = easing ?? (mode == .in ? .easeOut : .easeIn)
        self.opacity = opacity; self.x = x; self.y = y; self.scale = scale; self.rotation = rotation
        self.blur = blur; self.color = color; self.seed = seed
        self.fontWeightAxis = fontWeightAxis; self.fontWidth = fontWidth
    }

    enum CodingKeys: String, CodingKey {
        case unit, mode, start, duration, stagger, order, easing, opacity, x, y, scale, rotation, blur, color, seed
        case fontWeightAxis, fontWidth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try c.decodeIfPresent(AnimatorMode.self, forKey: .mode) ?? .in
        self.init(unit: try c.decodeIfPresent(TextUnit.self, forKey: .unit) ?? .char,
                  mode: mode,
                  start: try c.decodeIfPresent(Double.self, forKey: .start) ?? 0,
                  duration: max(0.001, try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0.5),
                  stagger: max(0, try c.decodeIfPresent(Double.self, forKey: .stagger) ?? 0.04),
                  order: try c.decodeIfPresent(StaggerOrder.self, forKey: .order) ?? .forward,
                  easing: try c.decodeIfPresent(Easing.self, forKey: .easing),
                  opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0,
                  x: try c.decodeIfPresent(Double.self, forKey: .x) ?? 0,
                  y: try c.decodeIfPresent(Double.self, forKey: .y) ?? 0,
                  scale: try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1,
                  rotation: try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0,
                  blur: max(0, try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0),
                  color: try c.decodeIfPresent(RGBA.self, forKey: .color),
                  seed: try c.decodeIfPresent(Int.self, forKey: .seed) ?? 0,
                  fontWeightAxis: try c.decodeIfPresent(Double.self, forKey: .fontWeightAxis) ?? 0,
                  fontWidth: try c.decodeIfPresent(Double.self, forKey: .fontWidth) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(unit, forKey: .unit)
        try c.encode(mode, forKey: .mode)
        try c.encode(start, forKey: .start)
        try c.encode(duration, forKey: .duration)
        try c.encode(stagger, forKey: .stagger)
        if order != .forward { try c.encode(order, forKey: .order) }
        try c.encode(easing, forKey: .easing)
        if opacity != 0 { try c.encode(opacity, forKey: .opacity) }
        if x != 0 { try c.encode(x, forKey: .x) }
        if y != 0 { try c.encode(y, forKey: .y) }
        if scale != 1 { try c.encode(scale, forKey: .scale) }
        if rotation != 0 { try c.encode(rotation, forKey: .rotation) }
        if blur != 0 { try c.encode(blur, forKey: .blur) }
        try c.encodeIfPresent(color, forKey: .color)
        if seed != 0 { try c.encode(seed, forKey: .seed) }
        if fontWeightAxis != 0 { try c.encode(fontWeightAxis, forKey: .fontWeightAxis) }
        if fontWidth != 0 { try c.encode(fontWidth, forKey: .fontWidth) }
    }

    /// When the last unit finishes.
    public func end(unitCount n: Int) -> Double { start + stagger * Double(max(n - 1, 0)) + duration }

    /// Position of each of n units in the stagger sequence (0 = first to move).
    public func ranks(_ n: Int) -> [Double] {
        let mid = Double(n - 1) / 2
        switch order {
        case .forward: return (0..<n).map(Double.init)
        case .reverse: return (0..<n).map { Double(n - 1 - $0) }
        case .center: return (0..<n).map { abs(Double($0) - mid) }
        case .edges: return (0..<n).map { mid - abs(Double($0) - mid) }
        case .random:
            let seed = Noise.mix(UInt64(bitPattern: Int64(seed)) &+ 77)
            let shuffled = (0..<n).sorted { Noise.unit($0, seed) < Noise.unit($1, seed) }
            var r = [Double](repeating: 0, count: n)
            for (rank, i) in shuffled.enumerated() { r[i] = Double(rank) }
            return r
        }
    }

    /// 0 = unit at rest, 1 = fully away (can overshoot with back/elastic/spring easings).
    public func away(rank: Double, at t: Double) -> Double {
        let begin = start + rank * stagger
        let p = min(max((t - begin) / max(duration, 0.001), 0), 1)
        let e = easing.apply(p)
        return mode == .in ? 1 - e : e
    }
}

/// Visual state of one character/word/line, combined from all animators.
public struct GlyphState: Equatable {
    public var opacity = 1.0
    public var dx = 0.0
    public var dy = 0.0
    public var scale = 1.0
    public var rotation = 0.0
    /// Blur in px.
    public var blur = 0.0
    /// Color mixed over the text's own (with its alpha as the mix).
    public var tint: RGBA?
    /// Variable-font axes for this unit (nil = the text's own).
    public var weightAxis: Double?
    public var widthAxis: Double?

    public static let rest = GlyphState()
    public var isRest: Bool { self == .rest }
}

extension MotionLayer {
    /// Combined state of each of n units (for the animators that use `unit`) at time t.
    public func glyphStates(unit: TextUnit, count n: Int, at t: Double) -> [GlyphState] {
        var states = [GlyphState](repeating: .rest, count: n)
        for a in textAnimators where a.unit == unit {
            let ranks = a.ranks(n)
            for i in 0..<n {
                let k = a.away(rank: ranks[i], at: t)
                states[i].opacity *= min(max(1 + (a.opacity - 1) * k, 0), 1)
                states[i].dx += a.x * k
                states[i].dy += a.y * k
                states[i].scale *= 1 + (a.scale - 1) * k
                states[i].rotation += a.rotation * k
                states[i].blur += a.blur * k
                if let c = a.color, k > 0.001 {
                    var mixed = c
                    mixed.a = c.a * min(k, 1)
                    states[i].tint = states[i].tint.map { RGBA.lerp($0, mixed, 0.5) } ?? mixed
                }
                if a.fontWeightAxis > 0 {
                    let rest = self[.fontWeightAxis].value(at: t)
                    let base = rest > 0 ? rest : 400
                    states[i].weightAxis = base + (a.fontWeightAxis - base) * k
                }
                if a.fontWidth > 0 {
                    let rest = self[.fontWidth].value(at: t)
                    let base = rest > 0 ? rest : 100
                    states[i].widthAxis = base + (a.fontWidth - base) * k
                }
            }
        }
        return states
    }
}

/// A marker band behind one word (or every occurrence) of a text layer, swept in from the left.
public struct TextHighlight: Codable, Equatable, Hashable, Sendable {
    public var word: String
    public var color: RGBA
    /// Extra px around the word's box.
    public var padding: Double
    public var radius: Double
    /// Scene second the sweep starts (nil = always fully shown) and how long it takes.
    public var start: Double?
    public var duration: Double
    /// Slant in degrees for a hand-drawn marker look.
    public var skew: Double
    /// Every occurrence of the word, not only the first.
    public var all: Bool

    public init(word: String, color: RGBA, padding: Double = 6, radius: Double = 6, start: Double? = nil,
                duration: Double = 0.4, skew: Double = 0, all: Bool = false) {
        self.word = word; self.color = color; self.padding = padding; self.radius = radius
        self.start = start; self.duration = duration; self.skew = skew; self.all = all
    }

    enum CodingKeys: String, CodingKey { case word, color, padding, radius, start, duration, skew, all }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(word: try c.decode(String.self, forKey: .word),
                  color: try c.decodeIfPresent(RGBA.self, forKey: .color) ?? RGBA(hex: "#FFE600")!,
                  padding: try c.decodeIfPresent(Double.self, forKey: .padding) ?? 6,
                  radius: try c.decodeIfPresent(Double.self, forKey: .radius) ?? 6,
                  start: try c.decodeIfPresent(Double.self, forKey: .start),
                  duration: max(0.01, try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0.4),
                  skew: try c.decodeIfPresent(Double.self, forKey: .skew) ?? 0,
                  all: try c.decodeIfPresent(Bool.self, forKey: .all) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(word, forKey: .word)
        try c.encode(color, forKey: .color)
        if padding != 6 { try c.encode(padding, forKey: .padding) }
        if radius != 6 { try c.encode(radius, forKey: .radius) }
        try c.encodeIfPresent(start, forKey: .start)
        if duration != 0.4 { try c.encode(duration, forKey: .duration) }
        if skew != 0 { try c.encode(skew, forKey: .skew) }
        if all { try c.encode(all, forKey: .all) }
    }
}

public enum TextUnits {
    /// Unit index for each UTF-16 offset of `text` (-1 for whitespace), and the number of units.
    /// `.line` counts hard line breaks; the renderer uses laid-out lines instead.
    public static func map(_ text: String, unit: TextUnit) -> (indices: [Int], count: Int) {
        var out: [Int] = []
        out.reserveCapacity(text.utf16.count)
        var count = 0
        var inWord = false
        var line = 0
        for ch in text {
            let len = ch.utf16.count
            let ws = ch.isWhitespace
            var idx = -1
            switch unit {
            case .char:
                if !ws { idx = count; count += 1 }
            case .word:
                if !ws {
                    if !inWord { count += 1; inWord = true }
                    idx = count - 1
                } else {
                    inWord = false
                }
            case .line:
                if ch.isNewline { line += 1 } else if !ws { idx = line; count = line + 1 }
            }
            out.append(contentsOf: repeatElement(idx, count: len))
        }
        return (out, count)
    }
}

// MARK: - Transforms

extension MotionLayer {
    /// Center of the layer at time t (in its parent's space): from the motion path if any, else x/y.
    public func position(at t: Double) -> (point: CGPoint, pathAngle: Double) {
        if let mp = motionPath, !mp.points.isEmpty {
            let s = mp.sample(value(.pathProgress, at: t))
            return (CGPoint(x: s.point.x + proceduralOffset(.x, at: t), y: s.point.y + proceduralOffset(.y, at: t)),
                    mp.orient ? s.angle : 0)
        }
        return (CGPoint(x: value(.x, at: t), y: value(.y, at: t)), 0)
    }

    /// Maps layer-local coordinates (origin at the layer center, y down) to its parent's space.
    public func localTransform(at t: Double) -> CGAffineTransform {
        let pos = position(at: t)
        let ax = value(.anchorX, at: t), ay = value(.anchorY, at: t)
        let s = value(.scale, at: t)
        let sx = s * value(.scaleX, at: t), sy = s * value(.scaleY, at: t)
        func tanDeg(_ d: Double) -> Double { tan(min(max(d, -85), 85) * .pi / 180) }
        let skew = CGAffineTransform(a: 1, b: tanDeg(value(.skewY, at: t)), c: tanDeg(value(.skewX, at: t)), d: 1, tx: 0, ty: 0)
        let angle = (value(.rotation, at: t) + pos.pathAngle) * .pi / 180
        return CGAffineTransform(translationX: -ax, y: -ay)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(skew)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: pos.point.x + ax, y: pos.point.y + ay))
    }
}

extension MotionScene {
    /// Maps a layer's local coordinates to framed scene pixels: through its chain of parents, then the camera.
    public func worldTransform(of layer: MotionLayer, at t: Double) -> CGAffineTransform {
        sceneTransform(of: layer, at: t).concatenating(cameraTransform(for: layer, at: t))
    }

    /// Maps a layer's local coordinates to scene pixels before the camera (where world-space particles live).
    public func sceneTransform(of layer: MotionLayer, at t: Double) -> CGAffineTransform {
        layer.localTransform(at: t).concatenating(ancestorsTransform(of: layer, at: t))
    }

    /// The chain of parents' transforms (identity without a parent), before the camera.
    func ancestorsTransform(of layer: MotionLayer, at t: Double) -> CGAffineTransform {
        // A layer on a bone lives in the bone's space (no layer parents).
        if let b = layer.bone, let bt = boneTransform(b, at: t) { return bt }
        var m = CGAffineTransform.identity
        var seen: Set<String> = [layer.id]
        var next = layer.parent
        while let pid = next, !seen.contains(pid), let p = layers.first(where: { $0.id == pid }) {
            m = m.concatenating(p.localTransform(at: t))
            seen.insert(pid)
            next = p.parent
        }
        return m
    }

    /// Everything around a layer's own transform: its parents, then the camera as seen at its depth.
    public func parentTransform(of layer: MotionLayer, at t: Double) -> CGAffineTransform {
        ancestorsTransform(of: layer, at: t).concatenating(cameraTransform(for: layer, at: t))
    }

    /// True if `a` is `b` or one of `b`'s parents.
    public func isAncestor(_ a: String, of b: String) -> Bool {
        var seen: Set<String> = []
        var cur: String? = b
        while let c = cur, !seen.contains(c) {
            if c == a { return true }
            seen.insert(c)
            cur = layers.first { $0.id == c }?.parent
        }
        return false
    }
}
