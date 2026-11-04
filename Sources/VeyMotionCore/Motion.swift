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
    public var seed: Int

    public init(unit: TextUnit = .char, mode: AnimatorMode = .in, start: Double = 0, duration: Double = 0.5,
                stagger: Double = 0.04, order: StaggerOrder = .forward, easing: Easing? = nil,
                opacity: Double = 0, x: Double = 0, y: Double = 0, scale: Double = 1, rotation: Double = 0, seed: Int = 0) {
        self.unit = unit; self.mode = mode; self.start = start; self.duration = duration; self.stagger = stagger
        self.order = order; self.easing = easing ?? (mode == .in ? .easeOut : .easeIn)
        self.opacity = opacity; self.x = x; self.y = y; self.scale = scale; self.rotation = rotation; self.seed = seed
    }

    enum CodingKeys: String, CodingKey { case unit, mode, start, duration, stagger, order, easing, opacity, x, y, scale, rotation, seed }

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
                  seed: try c.decodeIfPresent(Int.self, forKey: .seed) ?? 0)
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
            }
        }
        return states
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
            let wx = wiggle["x"].map { $0.offset(at: t, salt: Noise.hash("\(id).x")) } ?? 0
            let wy = wiggle["y"].map { $0.offset(at: t, salt: Noise.hash("\(id).y")) } ?? 0
            return (CGPoint(x: s.point.x + wx, y: s.point.y + wy), mp.orient ? s.angle : 0)
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

// MARK: - Camera (2.5D)

/// What the active camera sees at one time. Layers stay flat and face the camera; a layer at depth `z` is scaled by
/// `perspective / (perspective + z − camera z)` around the camera axis, which gives parallax, dolly and depth of field
/// while every transform stays affine (so the CoreGraphics renderer draws it as before).
public struct CameraView: Equatable, Sendable {
    /// Distance from the camera to the z = 0 plane when the camera's own z is 0 (≈ a 40 mm lens at 1920 px wide).
    public static let defaultPerspective = 2000.0
    /// Layers closer than this to the camera (or behind it) are not drawn.
    public static let nearClip = 10.0

    /// Scene point (on the z = 0 plane) the camera looks at; it lands on the frame center.
    public var center: CGPoint
    /// Camera dolly: positive moves the camera toward the layers.
    public var z: Double
    /// Lens zoom (1 = none): magnifies everything uniformly, without changing perspective.
    public var zoom: Double
    /// Camera roll in degrees.
    public var roll: Double
    public var perspective: Double
    /// Depth (z) of the plane in focus.
    public var focus: Double
    /// Blur in px of a layer 1000 px of depth away from the focus plane (0 = no depth of field).
    public var aperture: Double
    public var frameCenter: CGPoint

    /// The camera used when the scene has none: renders z = 0 layers exactly as without a camera.
    public static func `default`(width: Int, height: Int) -> CameraView {
        let c = CGPoint(x: Double(width) / 2, y: Double(height) / 2)
        return CameraView(center: c, z: 0, zoom: 1, roll: 0, perspective: defaultPerspective, focus: 0, aperture: 0,
                          frameCenter: c)
    }

    /// Size factor of a plane at depth `depth` (1 at z = camera z, smaller farther away); nil if behind the near clip.
    public func depthScale(_ depth: Double) -> Double? {
        let p = max(perspective, 1)
        let distance = p + depth - z
        guard distance > Self.nearClip else { return nil }
        return p / distance
    }

    /// Maps scene-plane coordinates of a layer at depth `depth` to frame pixels; nil if the layer is behind the camera.
    public func projection(depth: Double) -> CGAffineTransform? {
        guard let k = depthScale(depth) else { return nil }
        let s = k * zoom
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: -roll * .pi / 180))
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: frameCenter.x, y: frameCenter.y))
    }

    /// Depth-of-field blur (scene px) for a layer at depth `depth`.
    public func depthBlur(_ depth: Double) -> Double {
        max(0, aperture) * abs(depth - focus) / 1000
    }
}

extension MotionScene {
    /// The camera layer in use at t: the topmost camera layer visible at t (several cameras = cuts between them).
    public func activeCamera(at t: Double) -> MotionLayer? {
        layers.last { $0.type == .camera && $0.isVisible(at: t, sceneDuration: duration) }
    }

    /// The view of the active camera at t (a neutral camera when the scene has none).
    public func camera(at t: Double) -> CameraView {
        var view = CameraView.default(width: width, height: height)
        guard let cam = activeCamera(at: t) else { return view }
        let pos = cam.position(at: t)
        view.center = pos.point
        view.z = cam.value(.z, at: t)
        view.zoom = cam.value(.scale, at: t)
        view.roll = cam.value(.rotation, at: t) + pos.pathAngle
        view.perspective = cam.value(.perspective, at: t)
        view.focus = cam.value(.focus, at: t)
        view.aperture = cam.value(.aperture, at: t)
        return view
    }

    /// Depth of a layer: its own z plus its parents' z.
    public func depth(of layer: MotionLayer, at t: Double) -> Double {
        var z = layer.value(.z, at: t)
        var seen: Set<String> = [layer.id]
        var next = layer.parent
        while let pid = next, !seen.contains(pid), let p = layers.first(where: { $0.id == pid }) {
            z += p.value(.z, at: t)
            seen.insert(pid)
            next = p.parent
        }
        return z
    }

    /// Maps a layer's local coordinates to frame pixels: its world transform seen through the camera.
    /// nil when the layer is behind the camera. Pass `camera` to reuse a view computed once per frame.
    public func screenTransform(of layer: MotionLayer, at t: Double, camera: CameraView? = nil) -> CGAffineTransform? {
        let view = camera ?? self.camera(at: t)
        guard let p = view.projection(depth: depth(of: layer, at: t)) else { return nil }
        return worldTransform(of: layer, at: t).concatenating(p)
    }
}

extension MotionScene {
    /// Maps a layer's local coordinates to scene pixels, through its chain of parents (before the camera:
    /// use `screenTransform` to draw).
    public func worldTransform(of layer: MotionLayer, at t: Double) -> CGAffineTransform {
        var m = layer.localTransform(at: t)
        var seen: Set<String> = [layer.id]
        var next = layer.parent
        while let pid = next, !seen.contains(pid), let p = layers.first(where: { $0.id == pid }) {
            m = m.concatenating(p.localTransform(at: t))
            seen.insert(pid)
            next = p.parent
        }
        return m
    }

    /// The parent's world transform (identity without a parent).
    public func parentTransform(of layer: MotionLayer, at t: Double) -> CGAffineTransform {
        guard let pid = layer.parent, let p = layers.first(where: { $0.id == pid }), pid != layer.id else { return .identity }
        if isAncestor(layer.id, of: pid) { return .identity }
        return worldTransform(of: p, at: t)
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
