import CoreGraphics
import Foundation

// Particle systems. Every frame is computed from scratch: particle k is born at a fixed time with fixed random
// numbers, and its state at age a comes from a closed form (or from stepping its own path from birth when it
// swirls or bounces). Scrubbing, preview and export at any fps therefore show the same particles.

public enum ParticleShape: String, Codable, CaseIterable, Sendable {
    /// Hard-edged disc.
    case circle
    /// Disc fading out to its edge (glow, smoke, fire).
    case soft
    case square
    /// Streak along the direction of travel (sparks, rain); `streak` sets its length.
    case spark
    /// The layer's `path` image (e.g. a smoke puff PNG).
    case image
}

public enum EmitterShape: String, Codable, CaseIterable, Sendable {
    case point, line, rect, ellipse
}

public enum ParticleSpace: String, Codable, CaseIterable, Sendable {
    /// Particles stay where they were emitted when the emitter moves (trails).
    case world
    /// Particles move, turn and scale with the layer.
    case local
}

public enum ParticleColorMode: String, Codable, CaseIterable, Sendable {
    /// `colors` is a gradient over each particle's life.
    case life
    /// Each particle takes one of `colors` at random (confetti).
    case random
}

public enum ParticlePreset: String, Codable, CaseIterable, Sendable {
    case fire, smoke, dust, sparks, snow, rain, confetti, bokeh, magic, explosion

    public var title: String { rawValue.capitalized }

    /// Blend mode a new layer of this preset gets when none is given.
    public var defaultBlendMode: BlendMode {
        switch self {
        case .fire, .sparks, .magic, .explosion, .bokeh, .dust: return .add
        default: return .normal
        }
    }
}

public struct ParticleBurst: Codable, Equatable, Hashable, Sendable {
    /// Scene seconds.
    public var t: Double
    public var count: Int

    public init(t: Double, count: Int) { self.t = t; self.count = count }

    enum CodingKeys: String, CodingKey { case t, count }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        count = max(0, try c.decodeIfPresent(Int.self, forKey: .count) ?? 100)
    }
}

/// Settings of a particle layer. Angles are degrees, 0 = right, 90 = down (clockwise on screen, like rotation).
public struct ParticleSystem: Equatable, Hashable, Sendable {
    /// Starting values; fields that are set override them.
    public var preset: ParticlePreset?
    public var seed = 0

    // Emission
    /// Particles per second (× the animatable `emission`).
    public var rate = 40.0
    public var bursts: [ParticleBurst] = []
    /// Seconds simulated before the layer starts, so it opens already full (snow, dust).
    public var prewarm = 0.0
    public var lifetime = 2.0
    /// 0…1: each particle lives lifetime × (1 ± lifetimeRandom).
    public var lifetimeRandom = 0.3
    /// Area particles are born in, sized by the layer's width/height (line: width only).
    public var emitter = EmitterShape.point
    /// Emit from the emitter's (or the `from` layer's) outline only.
    public var edge = false
    /// Emit from another layer's shape instead: a rect/ellipse, an image's frame or a text's letters.
    public var from: String?
    public var space = ParticleSpace.world

    // Motion
    /// px/s (× the animatable `particleSpeed`).
    public var speed = 150.0
    /// 0…1: speed × (1 ± speedRandom).
    public var speedRandom = 0.3
    public var direction = -90.0
    /// Width of the cone particles leave in, degrees (360 = every direction).
    public var spread = 30.0
    /// 0…1: share of the emitter's own velocity particles keep (trails behind a moving emitter).
    public var inherit = 0.0
    /// px/s², positive pulls down (negative = rises, like hot air).
    public var gravity = 0.0
    /// px/s², positive pushes right.
    public var wind = 0.0
    /// Air resistance, 1/s (0 = none, 2 = particles slow down quickly).
    public var drag = 0.0
    /// Strength of swirling flow, px/s (smoke, fire, dust).
    public var turbulence = 0.0
    /// Size of the swirls, px.
    public var turbulenceScale = 200.0
    /// How fast the swirls change, per second.
    public var turbulenceSpeed = 0.5
    /// Scene y (px) of a floor particles bounce on; nil = none.
    public var floor: Double?
    /// 0…1: speed kept after a bounce.
    public var bounce = 0.4
    /// 0…1: sideways speed lost on each bounce.
    public var friction = 0.2

    // Look
    public var shape = ParticleShape.soft
    /// Diameter in px (× the animatable `particleSize`).
    public var size = 16.0
    /// 0…1: size × (1 ± sizeRandom).
    public var sizeRandom = 0.4
    /// Size at the end of life as a multiple of the size at birth (3 = grows, 0 = shrinks away).
    public var grow = 1.0
    /// Spark length in seconds of travel.
    public var streak = 0.04
    /// Turn each particle to face where it goes.
    public var orient = false
    /// Random starting rotation, ± degrees.
    public var angleRandom = 180.0
    /// Degrees per second; each particle turns one way or the other.
    public var spin = 0.0
    /// 0…1: spin × (1 ± spinRandom).
    public var spinRandom = 0.5
    /// Flips per second around the horizontal axis (confetti).
    public var flutter = 0.0
    public var colors: [RGBA] = [.white]
    public var colorMode = ParticleColorMode.life
    /// Fractions of the life spent fading in and out.
    public var fadeIn = 0.1
    public var fadeOut = 0.4
    /// Image particles: paint the image's shape with `colors` instead of its own colors.
    public var tint = false

    public init() {}

    public init(preset: ParticlePreset) {
        self = ParticleSystem.base(preset)
    }

    /// Emits from another layer or with `space` world: particles are simulated in scene pixels.
    public var usesWorldSpace: Bool { from != nil || space == .world }

    // swiftlint:disable:next function_body_length
    public static func base(_ preset: ParticlePreset?) -> ParticleSystem {
        var p = ParticleSystem()
        guard let preset else { return p }
        p.preset = preset
        func hex(_ s: String) -> RGBA { RGBA(hex: s)! }
        switch preset {
        case .fire:
            p.rate = 240; p.lifetime = 0.9; p.lifetimeRandom = 0.4
            p.emitter = .line
            p.speed = 140; p.speedRandom = 0.5; p.direction = -90; p.spread = 20
            p.gravity = -320; p.drag = 1.2
            p.turbulence = 90; p.turbulenceScale = 70; p.turbulenceSpeed = 2
            p.shape = .soft; p.size = 62; p.sizeRandom = 0.35; p.grow = 0.12
            p.colors = [hex("#FFE9A050"), hex("#FFA83058"), hex("#FF541048"), hex("#A8180030"), hex("#30080000")]
            p.fadeIn = 0.08; p.fadeOut = 0.35
        case .smoke:
            p.rate = 16; p.lifetime = 4.5; p.lifetimeRandom = 0.3
            p.emitter = .line
            p.speed = 70; p.speedRandom = 0.4; p.direction = -90; p.spread = 25
            p.gravity = -25; p.drag = 0.4
            p.turbulence = 60; p.turbulenceScale = 220; p.turbulenceSpeed = 0.35
            p.shape = .soft; p.size = 60; p.sizeRandom = 0.4; p.grow = 3.5
            p.colors = [hex("#9A9AA248"), hex("#7A7A8430"), hex("#5A5A6000")]
            p.fadeIn = 0.15; p.fadeOut = 0.6
        case .dust:
            p.rate = 30; p.prewarm = 6; p.lifetime = 6; p.lifetimeRandom = 0.4
            p.emitter = .rect
            p.speed = 8; p.speedRandom = 1; p.spread = 360
            p.turbulence = 18; p.turbulenceScale = 320; p.turbulenceSpeed = 0.25
            p.shape = .soft; p.size = 6; p.sizeRandom = 0.7
            p.colors = [hex("#FFE8C2B0")]
            p.fadeIn = 0.3; p.fadeOut = 0.3
        case .sparks:
            p.rate = 70; p.lifetime = 0.9; p.lifetimeRandom = 0.5
            p.speed = 650; p.speedRandom = 0.45; p.direction = -90; p.spread = 70
            p.gravity = 1100; p.drag = 0.8
            p.shape = .spark; p.size = 3; p.sizeRandom = 0.4; p.grow = 0.4; p.streak = 0.035
            p.colors = [hex("#FFFFF0"), hex("#FFD060"), hex("#FF7A20"), hex("#C0300000")]
            p.fadeIn = 0; p.fadeOut = 0.3
        case .snow:
            p.rate = 45; p.prewarm = 9; p.lifetime = 9; p.lifetimeRandom = 0.2
            p.emitter = .line
            p.speed = 90; p.speedRandom = 0.4; p.direction = 90; p.spread = 20
            p.turbulence = 30; p.turbulenceScale = 280; p.turbulenceSpeed = 0.3
            p.shape = .soft; p.size = 10; p.sizeRandom = 0.6
            p.colors = [hex("#FFFFFFE0")]
            p.fadeIn = 0.05; p.fadeOut = 0.1
        case .rain:
            p.rate = 420; p.prewarm = 1.2; p.lifetime = 1.2; p.lifetimeRandom = 0.1
            p.emitter = .line
            p.speed = 1500; p.speedRandom = 0.15; p.direction = 100; p.spread = 2
            p.shape = .spark; p.size = 2; p.sizeRandom = 0.3; p.streak = 0.03
            p.colors = [hex("#B8CCFF90")]
            p.fadeIn = 0; p.fadeOut = 0.05
        case .confetti:
            p.rate = 70; p.prewarm = 0; p.lifetime = 5; p.lifetimeRandom = 0.2
            p.emitter = .line
            p.speed = 120; p.speedRandom = 0.5; p.direction = 90; p.spread = 50
            p.gravity = 260; p.drag = 1.4
            p.turbulence = 50; p.turbulenceScale = 220; p.turbulenceSpeed = 0.6
            p.shape = .square; p.size = 16; p.sizeRandom = 0.35
            p.spin = 360; p.spinRandom = 0.6; p.flutter = 2.5
            p.colors = [hex("#FF4D6D"), hex("#FFC93C"), hex("#3CCF91"), hex("#4D96FF"), hex("#B15CFF")]
            p.colorMode = .random
            p.fadeIn = 0; p.fadeOut = 0.15
        case .bokeh:
            p.rate = 4; p.prewarm = 8; p.lifetime = 8; p.lifetimeRandom = 0.3
            p.emitter = .rect
            p.speed = 15; p.speedRandom = 1; p.spread = 360
            p.turbulence = 10; p.turbulenceScale = 500; p.turbulenceSpeed = 0.15
            p.shape = .soft; p.size = 120; p.sizeRandom = 0.6
            p.colors = [hex("#FFB86B50"), hex("#FF6BB550"), hex("#6BC8FF50")]
            p.colorMode = .random
            p.fadeIn = 0.3; p.fadeOut = 0.4
        case .magic:
            p.rate = 120; p.lifetime = 1.4; p.lifetimeRandom = 0.5
            p.speed = 40; p.speedRandom = 1; p.spread = 360; p.inherit = 0.15
            p.gravity = 40; p.drag = 1.5
            p.turbulence = 30; p.turbulenceScale = 120; p.turbulenceSpeed = 1
            p.shape = .soft; p.size = 10; p.sizeRandom = 0.6; p.grow = 0
            p.colors = [hex("#FFFFFF"), hex("#9FE8FF"), hex("#B98BFF00")]
            p.fadeIn = 0; p.fadeOut = 0.5
        case .explosion:
            p.rate = 0; p.bursts = [ParticleBurst(t: 0, count: 260)]
            p.lifetime = 1.4; p.lifetimeRandom = 0.5
            p.speed = 900; p.speedRandom = 0.7; p.spread = 360
            p.gravity = 500; p.drag = 2.2
            p.shape = .spark; p.size = 4; p.sizeRandom = 0.5; p.grow = 0.3; p.streak = 0.05
            p.colors = [hex("#FFFFFF"), hex("#FFD27A"), hex("#FF7B2A"), hex("#7A1A0000")]
            p.fadeIn = 0; p.fadeOut = 0.4
        }
        return p
    }
}

// MARK: - Codable (only fields that differ from the preset are written)

extension ParticleSystem: Codable {
    enum CodingKeys: String, CodingKey {
        case preset, seed, rate, bursts, prewarm, lifetime, lifetimeRandom, emitter, edge, from, space
        case speed, speedRandom, direction, spread, inherit, gravity, wind, drag
        case turbulence, turbulenceScale, turbulenceSpeed, floor, bounce, friction
        case shape, size, sizeRandom, grow, streak, orient, angleRandom, spin, spinRandom, flutter
        case colors, colorMode, fadeIn, fadeOut, tint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var preset: ParticlePreset?
        if let name = try c.decodeIfPresent(String.self, forKey: .preset) {
            guard let p = ParticlePreset(rawValue: name) else {
                throw DecodingError.dataCorruptedError(forKey: .preset, in: c, debugDescription:
                    "Unknown preset '\(name)'. Use one of \(ParticlePreset.allCases.map(\.rawValue)).")
            }
            preset = p
        }
        let b = ParticleSystem.base(preset)
        func d<T: Decodable>(_ k: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? fallback }
        func unit(_ k: CodingKeys, _ fallback: Double) throws -> Double { min(max(try d(k, fallback), 0), 1) }
        self.preset = preset
        seed = try d(.seed, b.seed)
        rate = max(0, try d(.rate, b.rate))
        bursts = try d(.bursts, b.bursts)
        prewarm = max(0, try d(.prewarm, b.prewarm))
        lifetime = max(0.01, try d(.lifetime, b.lifetime))
        lifetimeRandom = try unit(.lifetimeRandom, b.lifetimeRandom)
        emitter = try d(.emitter, b.emitter)
        edge = try d(.edge, b.edge)
        from = try c.decodeIfPresent(String.self, forKey: .from).flatMap { $0.isEmpty ? nil : $0 } ?? b.from
        space = try d(.space, b.space)
        speed = try d(.speed, b.speed)
        speedRandom = try unit(.speedRandom, b.speedRandom)
        direction = try d(.direction, b.direction)
        spread = min(max(try d(.spread, b.spread), 0), 360)
        inherit = try d(.inherit, b.inherit)
        gravity = try d(.gravity, b.gravity)
        wind = try d(.wind, b.wind)
        drag = max(0, try d(.drag, b.drag))
        turbulence = max(0, try d(.turbulence, b.turbulence))
        turbulenceScale = max(1, try d(.turbulenceScale, b.turbulenceScale))
        turbulenceSpeed = max(0, try d(.turbulenceSpeed, b.turbulenceSpeed))
        floor = try c.decodeIfPresent(Double.self, forKey: .floor) ?? b.floor
        bounce = try unit(.bounce, b.bounce)
        friction = try unit(.friction, b.friction)
        shape = try d(.shape, b.shape)
        size = max(0, try d(.size, b.size))
        sizeRandom = try unit(.sizeRandom, b.sizeRandom)
        grow = max(0, try d(.grow, b.grow))
        streak = max(0, try d(.streak, b.streak))
        orient = try d(.orient, b.orient)
        angleRandom = try d(.angleRandom, b.angleRandom)
        spin = try d(.spin, b.spin)
        spinRandom = try unit(.spinRandom, b.spinRandom)
        flutter = max(0, try d(.flutter, b.flutter))
        colors = try d(.colors, b.colors)
        if colors.isEmpty { colors = [.white] }
        colorMode = try d(.colorMode, b.colorMode)
        fadeIn = try unit(.fadeIn, b.fadeIn)
        fadeOut = try unit(.fadeOut, b.fadeOut)
        tint = try d(.tint, b.tint)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let b = ParticleSystem.base(preset)
        func e<T: Encodable & Equatable>(_ v: T, _ base: T, _ k: CodingKeys) throws { if v != base { try c.encode(v, forKey: k) } }
        try c.encodeIfPresent(preset, forKey: .preset)
        try e(seed, b.seed, .seed)
        try e(rate, b.rate, .rate)
        try e(bursts, b.bursts, .bursts)
        try e(prewarm, b.prewarm, .prewarm)
        try e(lifetime, b.lifetime, .lifetime)
        try e(lifetimeRandom, b.lifetimeRandom, .lifetimeRandom)
        try e(emitter, b.emitter, .emitter)
        try e(edge, b.edge, .edge)
        try c.encodeIfPresent(from, forKey: .from)
        try e(space, b.space, .space)
        try e(speed, b.speed, .speed)
        try e(speedRandom, b.speedRandom, .speedRandom)
        try e(direction, b.direction, .direction)
        try e(spread, b.spread, .spread)
        try e(inherit, b.inherit, .inherit)
        try e(gravity, b.gravity, .gravity)
        try e(wind, b.wind, .wind)
        try e(drag, b.drag, .drag)
        try e(turbulence, b.turbulence, .turbulence)
        try e(turbulenceScale, b.turbulenceScale, .turbulenceScale)
        try e(turbulenceSpeed, b.turbulenceSpeed, .turbulenceSpeed)
        try c.encodeIfPresent(floor, forKey: .floor)
        try e(bounce, b.bounce, .bounce)
        try e(friction, b.friction, .friction)
        try e(shape, b.shape, .shape)
        try e(size, b.size, .size)
        try e(sizeRandom, b.sizeRandom, .sizeRandom)
        try e(grow, b.grow, .grow)
        try e(streak, b.streak, .streak)
        try e(orient, b.orient, .orient)
        try e(angleRandom, b.angleRandom, .angleRandom)
        try e(spin, b.spin, .spin)
        try e(spinRandom, b.spinRandom, .spinRandom)
        try e(flutter, b.flutter, .flutter)
        try e(colors, b.colors, .colors)
        try e(colorMode, b.colorMode, .colorMode)
        try e(fadeIn, b.fadeIn, .fadeIn)
        try e(fadeOut, b.fadeOut, .fadeOut)
        try e(tint, b.tint, .tint)
    }
}

// MARK: - New layers

extension MotionLayer {
    /// A particle layer with the preset's emitter placed and sized for a scene of the given size.
    public static func makeParticles(_ preset: ParticlePreset, sceneWidth: Int, sceneHeight: Int) -> MotionLayer {
        let w = Double(sceneWidth), h = Double(sceneHeight)
        var l = MotionLayer(id: preset.rawValue, name: preset.title, type: .particles, x: w / 2, y: h / 2)
        l.particles = ParticleSystem(preset: preset)
        l.blendMode = preset.defaultBlendMode
        var size = (w: 400.0, h: 240.0)
        switch preset {
        case .fire: l.y = .constant(h * 0.85); size = (w * 0.12, 0); l[.blur] = .constant(3)
        case .smoke: l.y = .constant(h * 0.75); size = (w * 0.1, 0); l[.blur] = .constant(2)
        case .sparks: l.y = .constant(h * 0.75)
        case .snow, .confetti: l.y = .constant(-40); size = (w * 1.2, 0)
        case .rain: l.x = .constant(w * 0.45); l.y = .constant(-60); size = (w * 1.4, 0)
        case .dust, .bokeh: size = (w, h)
        case .magic, .explosion: break
        }
        l.width = .constant(size.w.rounded())
        l.height = .constant(size.h.rounded())
        return l
    }
}

// MARK: - Simulation

/// One particle as drawn at a moment. Position/velocity are in scene pixels (world space) or layer pixels (local).
public struct Particle: Sendable {
    public var x: Double
    public var y: Double
    /// Velocity, px/s (sparks are drawn along it).
    public var vx: Double
    public var vy: Double
    /// Diameter, px.
    public var size: Double
    /// Degrees.
    public var rotation: Double
    /// Vertical squash, -1…1 (confetti flutter).
    public var scaleY: Double
    /// Color with the particle's fades in `a`.
    public var color: RGBA
}

/// Picks an emission point on a layer (layer-local px, y down), from two random numbers in [0, 1).
/// nil = the layer has no shape to emit from (its center is used).
public typealias EmitSampler = (_ source: MotionLayer, _ t: Double, _ r1: Double, _ r2: Double, _ edge: Bool) -> CGPoint?

extension MotionScene {
    public static let maxParticles = 20_000
    /// Emission ticks per second: births are spread inside ticks, so this only bounds the timing grid.
    static let emitTick = 1.0 / 240
    /// Step used when particles swirl or bounce.
    static let simStep = 1.0 / 48

    /// Live particles of a particle layer at time t, oldest first.
    public func particles(of layer: MotionLayer, at t: Double, sampler: EmitSampler? = nil) -> [Particle] {
        guard layer.type == .particles, t >= layer.start else { return [] }
        let sys = layer.particles
        let salt = Noise.mix(Noise.hash("particles.\(layer.id)") ^ UInt64(bitPattern: Int64(sys.seed)))
        let maxLife = sys.lifetime * (1 + sys.lifetimeRandom)
        let first = max(layer.start - sys.prewarm, t - maxLife)
        var births: [(t: Double, key: UInt64)] = []

        let dt = Self.emitTick
        if sys.rate > 0 {
            let j0 = Int(floor(first / dt)), j1 = Int(floor(t / dt))
            if j1 >= j0 {
                for j in j0...j1 {
                    let tick = Double(j) * dt
                    let expected = sys.rate * max(0, layer.value(.emission, at: tick)) * dt
                    guard expected > 0 else { continue }
                    let tickKey = Noise.mix(salt ^ UInt64(bitPattern: Int64(j)))
                    let count = Int(expected) + (Noise.unit(0, tickKey) < expected - floor(expected) ? 1 : 0)
                    for s in 0..<count {
                        let key = Noise.mix(tickKey &+ UInt64(s + 1))
                        let tb = (Double(j) + Noise.unit(1, key)) * dt
                        if tb >= first && tb <= t { births.append((tb, key)) }
                    }
                    if births.count >= Self.maxParticles { break }
                }
            }
        }
        for (bi, burst) in sys.bursts.enumerated() where burst.t >= first && burst.t <= t {
            let bkey = Noise.mix(salt ^ 0xB0B5_7000 ^ UInt64(bi) << 24)
            for i in 0..<min(burst.count, Self.maxParticles) {
                births.append((burst.t, Noise.mix(bkey &+ UInt64(i))))
            }
        }
        if !sys.bursts.isEmpty { births.sort { $0.t < $1.t } }
        if births.count > Self.maxParticles { births.removeFirst(births.count - Self.maxParticles) }

        let source = sys.from.flatMap { id in layers.first { $0.id == id && $0.id != layer.id } }
        var out: [Particle] = []
        out.reserveCapacity(births.count)
        for b in births {
            if let p = particle(layer, sys, born: b.t, key: b.key, at: t, source: source, sampler: sampler) { out.append(p) }
        }
        return out
    }

    private func particle(_ layer: MotionLayer, _ sys: ParticleSystem, born tb: Double, key: UInt64, at t: Double,
                          source: MotionLayer?, sampler: EmitSampler?) -> Particle? {
        func r(_ i: Int) -> Double { Noise.unit(i, key) }
        func spreadOf(_ amount: Double, _ i: Int) -> Double { 1 + amount * (2 * r(i) - 1) }
        let life = sys.lifetime * spreadOf(sys.lifetimeRandom, 0)
        let age = t - tb
        guard age >= 0, age < life else { return nil }

        // Where it is born, how fast it leaves and how big it is.
        var origin: CGPoint
        var angle = sys.direction + sys.spread * (r(3) - 0.5)
        var scale = 1.0
        var emitterVelocity = CGPoint.zero
        if let source {
            let local = sampler?(source, tb, r(1), r(2), sys.edge) ?? Self.shapePoint(source, at: tb, r(1), r(2), sys.edge)
            origin = local.applying(sceneTransform(of: source, at: tb))
            if sys.inherit != 0 { emitterVelocity = velocity(of: source, at: tb) }
        } else {
            origin = Self.emitterPoint(layer, sys, at: tb, r(1), r(2))
            if sys.space == .world {
                let m = sceneTransform(of: layer, at: tb)
                origin = origin.applying(m)
                angle += atan2(m.b, m.a) * 180 / .pi
                scale = abs(m.a * m.d - m.b * m.c).squareRoot()
                if sys.inherit != 0 { emitterVelocity = velocity(of: layer, at: tb) }
            }
        }
        let rad = angle * .pi / 180
        let speed = sys.speed * spreadOf(sys.speedRandom, 4) * layer.value(.particleSpeed, at: tb) * scale
        var x = Double(origin.x), y = Double(origin.y)
        var vx = cos(rad) * speed + sys.inherit * Double(emitterVelocity.x)
        var vy = sin(rad) * speed + sys.inherit * Double(emitterVelocity.y)
        let size0 = sys.size * spreadOf(sys.sizeRandom, 5) * max(0, layer.value(.particleSize, at: tb)) * scale

        // Where it is now.
        let k = sys.drag, ax = sys.wind, ay = sys.gravity
        if sys.turbulence <= 0 && sys.floor == nil {
            if k < 1e-6 {
                x += vx * age + 0.5 * ax * age * age
                y += vy * age + 0.5 * ay * age * age
                vx += ax * age
                vy += ay * age
            } else {
                let e = exp(-k * age)
                x += ax / k * age + (vx - ax / k) * (1 - e) / k
                y += ay / k * age + (vy - ay / k) * (1 - e) / k
                vx = ax / k + (vx - ax / k) * e
                vy = ay / k + (vy - ay / k) * e
            }
        } else {
            let field = Noise.mix(Noise.hash("turbulence") ^ UInt64(bitPattern: Int64(sys.seed)))
            let inv = 1 / sys.turbulenceScale
            var ux = 0.0, uy = 0.0
            var s = 0.0
            while s < age - 1e-9 {
                let h = min(Self.simStep, age - s)
                if sys.turbulence > 0 {
                    let c = Noise.curl(x * inv, y * inv, (tb + s) * sys.turbulenceSpeed, seed: field)
                    ux = c.x * sys.turbulence; uy = c.y * sys.turbulence
                }
                vx += (ax - k * vx) * h
                vy += (ay - k * vy) * h
                x += (vx + ux) * h
                y += (vy + uy) * h
                if let floorY = sys.floor, y > floorY, vy > 0 {
                    y = floorY - (y - floorY) * sys.bounce
                    vy = -vy * sys.bounce
                    vx *= 1 - sys.friction
                }
                s += h
            }
            vx += ux; vy += uy
        }

        // How it looks now.
        let u = age / life
        let growth = sys.grow >= 1 ? 1 - (1 - u) * (1 - u) : u * u
        let size = size0 * (1 + (sys.grow - 1) * growth)
        var color: RGBA
        switch sys.colorMode {
        case .random: color = sys.colors[min(Int(r(6) * Double(sys.colors.count)), sys.colors.count - 1)]
        case .life: color = Self.gradient(sys.colors, u)
        }
        func smooth(_ v: Double) -> Double { let c = min(max(v, 0), 1); return c * c * (3 - 2 * c) }
        if sys.fadeIn > 0 { color.a *= smooth(u / sys.fadeIn) }
        if sys.fadeOut > 0 { color.a *= smooth((1 - u) / sys.fadeOut) }
        guard color.a > 0.002, size > 0.05 else { return nil }
        let spinSign: Double = r(8) < 0.5 ? -1 : 1
        var rotation = sys.angleRandom * (2 * r(7) - 1) + spinSign * sys.spin * spreadOf(sys.spinRandom, 9) * age
        if sys.orient { rotation = atan2(vy, vx) * 180 / .pi }
        let scaleY = sys.flutter > 0 ? cos(2 * .pi * (sys.flutter * spreadOf(0.4, 10) * age + r(11))) : 1
        return Particle(x: x, y: y, vx: vx, vy: vy, size: size, rotation: rotation, scaleY: scaleY, color: color)
    }

    /// Scene-space velocity of a layer's center, px/s.
    private func velocity(of layer: MotionLayer, at t: Double) -> CGPoint {
        let h = 1.0 / 120
        let a = CGPoint.zero.applying(sceneTransform(of: layer, at: t - h))
        let b = CGPoint.zero.applying(sceneTransform(of: layer, at: t + h))
        return CGPoint(x: (b.x - a.x) / (2 * h), y: (b.y - a.y) / (2 * h))
    }

    /// Color at fraction u of a gradient with evenly spaced stops.
    static func gradient(_ colors: [RGBA], _ u: Double) -> RGBA {
        guard colors.count > 1 else { return colors.first ?? .white }
        let p = min(max(u, 0), 1) * Double(colors.count - 1)
        let i = min(Int(p), colors.count - 2)
        return RGBA.lerp(colors[i], colors[i + 1], p - Double(i))
    }

    /// Birth point inside the layer's own emitter (layer-local px).
    static func emitterPoint(_ layer: MotionLayer, _ sys: ParticleSystem, at t: Double, _ r1: Double, _ r2: Double) -> CGPoint {
        let w = max(0, layer.shapeWidth(at: t)), h = max(0, layer.shapeHeight(at: t))
        switch sys.emitter {
        case .point: return .zero
        case .line: return CGPoint(x: (r1 - 0.5) * w, y: 0)
        case .rect: return rectPoint(w, h, r1, r2, sys.edge)
        case .ellipse: return ellipsePoint(w, h, r1, r2, sys.edge)
        }
    }

    /// Birth point on a rect or ellipse layer used as a `from` source (other layers: their center).
    public static func shapePoint(_ layer: MotionLayer, at t: Double, _ r1: Double, _ r2: Double, _ edge: Bool) -> CGPoint {
        let w = max(0, layer.shapeWidth(at: t)), h = max(0, layer.shapeHeight(at: t))
        switch layer.type {
        case .rect, .particles: return rectPoint(w, h, r1, r2, edge)
        case .ellipse: return ellipsePoint(w, h, r1, r2, edge)
        default: return .zero
        }
    }

    public static func rectPoint(_ w: Double, _ h: Double, _ r1: Double, _ r2: Double, _ edge: Bool) -> CGPoint {
        guard edge, w + h > 0 else { return CGPoint(x: (r1 - 0.5) * w, y: (r2 - 0.5) * h) }
        var d = r1 * 2 * (w + h)
        if d < w { return CGPoint(x: d - w / 2, y: -h / 2) }
        d -= w
        if d < h { return CGPoint(x: w / 2, y: d - h / 2) }
        d -= h
        if d < w { return CGPoint(x: w / 2 - d, y: h / 2) }
        d -= w
        return CGPoint(x: -w / 2, y: h / 2 - d)
    }

    static func ellipsePoint(_ w: Double, _ h: Double, _ r1: Double, _ r2: Double, _ edge: Bool) -> CGPoint {
        let a = 2 * .pi * r1
        let rr = edge ? 1 : r2.squareRoot()
        return CGPoint(x: cos(a) * w / 2 * rr, y: sin(a) * h / 2 * rr)
    }
}

// MARK: - 3D value noise with its gradient, for curl turbulence

extension Noise {
    private static func lattice3(_ x: Int, _ y: Int, _ z: Int, _ seed: UInt64) -> Double {
        let hx = UInt64(bitPattern: Int64(x)) &* 0x9E3779B185EBCA87
        let hy = UInt64(bitPattern: Int64(y)) &* 0xC2B2AE3D27D4EB4F
        let hz = UInt64(bitPattern: Int64(z)) &* 0x165667B19E3779F9
        let h = mix(seed ^ hx ^ (hy &+ 0x27D4EB2F165667C5) ^ (hz &+ 0x94D049BB133111EB))
        return Double(h >> 11) / Double(1 << 53) * 2 - 1
    }

    /// Value noise in about [-1, 1] and its derivatives along x and y.
    static func value3(_ x: Double, _ y: Double, _ z: Double, seed: UInt64) -> (v: Double, dx: Double, dy: Double) {
        let fx0 = floor(x), fy0 = floor(y), fz0 = floor(z)
        let ix = Int(fx0), iy = Int(fy0), iz = Int(fz0)
        let fx = x - fx0, fy = y - fy0, fz = z - fz0
        func fade(_ f: Double) -> Double { f * f * f * (f * (f * 6 - 15) + 10) }
        func dfade(_ f: Double) -> Double { 30 * f * f * (f - 1) * (f - 1) }
        let u = fade(fx), v = fade(fy), w = fade(fz)
        let du = dfade(fx), dv = dfade(fy)
        let c000 = lattice3(ix, iy, iz, seed), c100 = lattice3(ix + 1, iy, iz, seed)
        let c010 = lattice3(ix, iy + 1, iz, seed), c110 = lattice3(ix + 1, iy + 1, iz, seed)
        let c001 = lattice3(ix, iy, iz + 1, seed), c101 = lattice3(ix + 1, iy, iz + 1, seed)
        let c011 = lattice3(ix, iy + 1, iz + 1, seed), c111 = lattice3(ix + 1, iy + 1, iz + 1, seed)
        let k1 = c100 - c000, k2 = c010 - c000, k3 = c001 - c000
        let k4 = c000 - c100 - c010 + c110
        let k5 = c000 - c010 - c001 + c011
        let k6 = c000 - c100 - c001 + c101
        let k7 = -c000 + c100 + c010 - c110 + c001 - c101 - c011 + c111
        let value = c000 + k1 * u + k2 * v + k3 * w + k4 * u * v + k5 * v * w + k6 * w * u + k7 * u * v * w
        let dx = du * (k1 + k4 * v + k6 * w + k7 * v * w)
        let dy = dv * (k2 + k4 * u + k5 * w + k7 * u * w)
        return (value, dx, dy)
    }

    /// Divergence-free 2D flow (curl of two octaves of noise), about unit strength. z animates the field.
    public static func curl(_ x: Double, _ y: Double, _ z: Double, seed: UInt64) -> (x: Double, y: Double) {
        let a = value3(x, y, z, seed: seed)
        let b = value3(x * 2.03 + 17.1, y * 2.03 - 9.3, z * 1.7, seed: seed &+ 1)
        let dx = a.dx + 0.5 * 2.03 * b.dx, dy = a.dy + 0.5 * 2.03 * b.dy
        return (dy / 1.6, -dx / 1.6)
    }
}
