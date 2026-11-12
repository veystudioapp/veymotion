import Foundation

// A "look" gives a scene the finishing layers a flat composition lacks: a background with depth (gradient + two
// slow blurred color blobs), ambient particles, a grain/vignette pass on top and a slow camera push. It is built
// from ordinary layers in one group at the bottom (`look`) and one at the top (`look-finish`), so everything can be
// edited afterwards, and applying another look replaces them.

public enum LookKind: String, CaseIterable, Codable, Sendable {
    case cinematic, clean, neon, retro, sunset, studio

    public var title: String {
        switch self {
        case .cinematic: return "Cinematic Dark"
        case .clean: return "Clean Light"
        case .neon: return "Neon"
        case .retro: return "Retro Film"
        case .sunset: return "Sunset"
        case .studio: return "Studio Gray"
        }
    }

    /// Short description for menus and the agent.
    public var summary: String {
        switch self {
        case .cinematic: return "deep navy to black, cool blue and teal blobs, dust, grain and vignette (titles, tech, trailers)"
        case .clean: return "white to light gray, soft pastel blobs, no grain (product, corporate, explainer; use dark text)"
        case .neon: return "near-black with magenta and cyan glow, bokeh, strong vignette (music, gaming, nightlife)"
        case .retro: return "warm brown and plum with orange and pink blobs, heavy grain and scanlines (vintage, lo-fi)"
        case .sunset: return "coral to violet gradient, golden blobs, light grain (lifestyle, travel, warm promos)"
        case .studio: return "charcoal with a soft top spotlight and one accent blob, light grain (business, data, minimal)"
        }
    }

    /// Whether text should be dark on this look.
    public var isLight: Bool { self == .clean }

    struct Palette {
        var background: RGBA
        var gradientTop: RGBA
        var gradientBottom: RGBA
        var blobA: RGBA
        var blobB: RGBA
        var blobBlend: BlendMode
        var particles: ParticlePreset?
        var grain: Double
        var scanlines: Double
        var vignette: Double
    }

    var palette: Palette {
        func c(_ hex: String) -> RGBA { RGBA(hex: hex)! }
        switch self {
        case .cinematic:
            return Palette(background: c("#06070B"), gradientTop: c("#141A2E"), gradientBottom: c("#05060A"),
                           blobA: c("#2745B8"), blobB: c("#1C8C8C"), blobBlend: .screen, particles: .dust,
                           grain: 0.22, scanlines: 0, vignette: 0.55)
        case .clean:
            return Palette(background: c("#F5F6F8"), gradientTop: c("#FFFFFF"), gradientBottom: c("#E6E9F0"),
                           blobA: c("#B9C4FF"), blobB: c("#FFC9DC"), blobBlend: .normal, particles: nil,
                           grain: 0, scanlines: 0, vignette: 0.12)
        case .neon:
            return Palette(background: c("#05030F"), gradientTop: c("#120A2A"), gradientBottom: c("#04020A"),
                           blobA: c("#FF2D95"), blobB: c("#00D4FF"), blobBlend: .add, particles: .bokeh,
                           grain: 0.18, scanlines: 0, vignette: 0.7)
        case .retro:
            return Palette(background: c("#241410"), gradientTop: c("#3A2224"), gradientBottom: c("#1A0E14"),
                           blobA: c("#FF8C42"), blobB: c("#C34A8F"), blobBlend: .screen, particles: .dust,
                           grain: 0.45, scanlines: 0.12, vignette: 0.6)
        case .sunset:
            return Palette(background: c("#2A1240"), gradientTop: c("#FF6F61"), gradientBottom: c("#5B2A86"),
                           blobA: c("#FFC857"), blobB: c("#FF4F79"), blobBlend: .screen, particles: .bokeh,
                           grain: 0.15, scanlines: 0, vignette: 0.35)
        case .studio:
            return Palette(background: c("#121316"), gradientTop: c("#2B2E36"), gradientBottom: c("#0F1013"),
                           blobA: c("#4C6FFF"), blobB: c("#2B2E36"), blobBlend: .screen, particles: nil,
                           grain: 0.1, scanlines: 0, vignette: 0.45)
        }
    }
}

public struct LookOptions: Sendable {
    /// Replaces the main blob color (and tints the gradient slightly).
    public var accent: RGBA?
    /// 0.5 = subtle, 1 = default, 1.5 = strong: scales blob opacity, grain and vignette.
    public var intensity: Double = 1
    public var particles = true
    public var grain = true
    public var vignette = true
    /// Slow camera push-in over the scene (only when the scene has no camera yet).
    public var cameraDrift = true

    public init() {}
}

extension MotionScene {
    public static let lookGroupId = "look"
    public static let lookFinishId = "look-finish"

    /// Applies a look: sets the background, puts the ambient group at the bottom and the finish group on top.
    /// Returns the ids of the layers it created.
    @discardableResult
    public mutating func applyLook(_ kind: LookKind, options o: LookOptions = LookOptions()) throws -> [String] {
        try removeLook()
        let w = Double(width), h = Double(height)
        let p = kind.palette
        let k = max(0.2, min(o.intensity, 2))
        let accent = o.accent ?? p.blobA
        background = p.background

        var ambient: [MotionLayer] = []

        var bg = MotionLayer(id: "look-bg", name: "Backdrop", type: .rect, x: w / 2, y: h / 2)
        bg.width = .constant(w); bg.height = .constant(h)
        var top = p.gradientTop
        if let a = o.accent { top = top.mixed(with: a, 0.18) }
        var g = Gradient(type: .radial, stops: [GradientStop(offset: 0, color: top), GradientStop(offset: 1, color: p.gradientBottom)])
        g.cx = 0.5; g.cy = kind == .sunset ? 0.15 : 0.3; g.radius = .constant(1.1)
        bg.gradient = g
        ambient.append(bg)

        // Two big soft color fields that drift slowly: depth without competing with the content.
        let blobAlpha = (kind.isLight ? 0.55 : 0.5) * k
        func blob(_ id: String, color: RGBA, x: Double, y: Double, size: Double, seed: Int, drift: Double) -> MotionLayer {
            var b = MotionLayer(id: id, name: "Light", type: .ellipse, x: x, y: y)
            b.width = .constant(size); b.height = .constant(size * 0.85)
            b.fill = .constant(RGBA(r: color.r, g: color.g, b: color.b, a: min(1, blobAlpha)))
            b[.blur] = .constant((size * 0.3).rounded())
            b.blendMode = p.blobBlend
            b.wiggle[AnimProperty.x.rawValue] = Wiggle(amount: drift, frequency: 0.08, seed: seed)
            b.wiggle[AnimProperty.y.rawValue] = Wiggle(amount: drift * 0.6, frequency: 0.07, seed: seed + 1)
            b.scale = .keyframes([MotionKeyframe(t: 0, v: 0.95, easing: .linear),
                                  MotionKeyframe(t: max(duration, 4), v: 1.1, easing: .curve(.sine, .inOut))])
            b.loop[AnimProperty.scale.rawValue] = .pingpong
            return b
        }
        ambient.append(blob("look-light-1", color: accent, x: w * 0.22, y: h * 0.3, size: w * 0.55, seed: 11, drift: w * 0.04))
        ambient.append(blob("look-light-2", color: p.blobB, x: w * 0.8, y: h * 0.78, size: w * 0.5, seed: 23, drift: w * 0.03))

        if o.particles, let preset = p.particles {
            var dust = MotionLayer.makeParticles(preset, sceneWidth: width, sceneHeight: height)
            dust.id = "look-particles"; dust.name = "Ambient"
            dust.particles.rate = preset == .bokeh ? 3 : 18
            dust.particles.speed = preset == .bokeh ? 18 : 25
            dust.particles.prewarm = 6
            if preset == .bokeh { dust.particles.size *= 0.6 }
            dust.particles.colors = [RGBA(r: accent.r * 0.5 + 0.5, g: accent.g * 0.5 + 0.5, b: accent.b * 0.5 + 0.5, a: 1)]
            dust.opacity = .constant(min(1, (preset == .bokeh ? 0.25 : 0.5) * k))
            ambient.append(dust)
        }

        var group = MotionLayer(id: Self.lookGroupId, name: "Look · \(kind.title)", type: .group, x: w / 2, y: h / 2)
        group.children = ambient
        var ids = [addLayer(group, at: 0)]

        // Finish: vignette as a radial gradient, grain (+ scanlines) on a mid-gray overlay so only the noise shows.
        var finish: [MotionLayer] = []
        if o.vignette, p.vignette > 0 {
            var v = MotionLayer(id: "look-vignette", name: "Vignette", type: .rect, x: w / 2, y: h / 2)
            v.width = .constant(w); v.height = .constant(h)
            let edge = kind.isLight ? RGBA(r: 0.1, g: 0.12, b: 0.2, a: min(1, p.vignette * k)) : RGBA(r: 0, g: 0, b: 0, a: min(1, p.vignette * k))
            var vg = Gradient(type: .radial, stops: [GradientStop(offset: 0.45, color: RGBA(r: edge.r, g: edge.g, b: edge.b, a: 0)),
                                                     GradientStop(offset: 1, color: edge)])
            vg.radius = .constant(1.05)
            v.gradient = vg
            finish.append(v)
        }
        if o.grain, p.grain > 0 || p.scanlines > 0 {
            var n = MotionLayer(id: "look-grain", name: "Grain", type: .rect, x: w / 2, y: h / 2)
            n.width = .constant(w); n.height = .constant(h)
            n.fill = .constant(RGBA(r: 0.5, g: 0.5, b: 0.5, a: 1))
            n.blendMode = .overlay
            if p.grain > 0 { n[.grain] = .constant(min(1, p.grain * k)) }
            if p.scanlines > 0 { n[.scanlines] = .constant(min(1, p.scanlines * k)) }
            finish.append(n)
        }
        if !finish.isEmpty {
            var fg = MotionLayer(id: Self.lookFinishId, name: "Finish", type: .group, x: w / 2, y: h / 2)
            fg.children = finish
            ids.append(addLayer(fg))
        }

        if o.cameraDrift, camera == nil, duration > 1 {
            var cam = Camera(x: w / 2, y: h / 2)
            cam.zoom = .keyframes([MotionKeyframe(t: 0, v: 1, easing: .linear),
                                   MotionKeyframe(t: duration, v: 1.04, easing: .curve(.sine, .inOut))])
            camera = cam
        }
        return ids
    }

    /// Removes the layers of a previous look (keeps the background and camera).
    public mutating func removeLook() throws {
        for id in [Self.lookGroupId, Self.lookFinishId] where layers.contains(where: { $0.id == id }) {
            try removeLayer(id)
        }
    }
}

extension RGBA {
    /// Linear mix toward another color (0 = self, 1 = other).
    func mixed(with o: RGBA, _ t: Double) -> RGBA {
        RGBA(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t, a: a + (o.a - a) * t)
    }
}
