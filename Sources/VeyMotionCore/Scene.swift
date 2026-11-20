import Foundation

public enum LayerType: String, Codable, CaseIterable, Sendable {
    case rect, ellipse, path, text, image, video, audio, particles, generator, group
    /// A 3D object (box, sphere, extruded text…, or a model file), lit and drawn in the scene's 3D space.
    case model
    /// Frame-by-frame drawing: `drawing.frames`, each a list of strokes held for some frames at `drawing.fps`.
    case drawing

    /// Drawn in the frame (audio layers are not).
    public var isVisual: Bool { self != .audio }

    /// Images and videos: sized by their file unless width/height are set.
    public var hasNaturalSize: Bool { self == .image || self == .video }

    /// Filled/stroked vector shapes.
    public var isShape: Bool { self == .rect || self == .ellipse || self == .path }
}

/// What an audio layer is, used for ducking (music dips under voice) and display.
public enum AudioRole: String, Codable, CaseIterable, Sendable {
    case voice, music, sfx
}

/// A spoken word in a voice layer or a transcribed audio/video layer; `t` is seconds from the start of the file.
public struct WordTiming: Codable, Equatable, Hashable, Sendable {
    public var t: Double
    public var text: String
    /// How long the word is spoken (transcriptions only).
    public var d: Double?
    public init(t: Double, text: String, d: Double? = nil) { self.t = t; self.text = text; self.d = d }
}

public enum TextAlign: String, Codable, CaseIterable, Sendable {
    case left, center, right
}

/// How a layer's pixels combine with what is below it.
public enum BlendMode: String, Codable, CaseIterable, Sendable {
    case normal, add, screen, multiply, overlay, lighten, darken

    public var title: String { rawValue.capitalized }
}

public enum AnimProperty: String, Codable, CaseIterable, Sendable {
    case x, y, scale, scaleX, scaleY, rotation, skewX, skewY, anchorX, anchorY, opacity
    case width, height, cornerRadius, strokeWidth, trim, trimStart, trimOffset
    case reveal, letterSpacing
    case blur, shadowX, shadowY, shadowBlur, shadowOpacity, glow, glowRadius
    case pathProgress
    case volume
    /// Particles: multipliers on the system's rate, speed and size, read when each particle is born.
    case emission, particleSpeed, particleSize
    /// Color correction: brightness, contrast and saturation -1…1 (0 = unchanged), hue in degrees, tint 0…1.
    case brightness, contrast, saturation, hue, tint
    /// Transition completion 0…1 (0 = whole layer shows, 1 = wiped away), shaped by `wipeStyle`.
    case wipe
    /// Keying (with `keyColor`): chroma distance that is removed, and the soft range above it.
    case keyTolerance, keySoftness
    /// Distort: wave warp and ripple amplitudes (px) sharing a wavelength (px) and speed (cycles/s); twirl (degrees at
    /// the center) and bulge (-1 pinch…1) within distortRadius (px); turbulent displacement (px).
    case waveWarp, ripple, waveLength, waveSpeed, twirl, bulge, distortRadius, turbulence
    /// Stylize: posterize (color levels, 0 = off), pixelate (block px), rgbSplit (px), glitch, grain, scanlines and
    /// vignette (0…1).
    case posterize, pixelate, rgbSplit, glitch, grain, scanlines, vignette
    /// Blur along a direction (length px, blurAngle degrees) and toward the layer's center (0…1).
    case directionalBlur, blurAngle, zoomBlur
    /// Text: the number shown in place of "{n}"; scramble (0…1 of the letters shown as random ones); offset along
    /// `textPath` in px.
    case counter, scramble, textOffset
    /// Light: a bright band sweeping the layer (shine strength 0…2, shinePosition -0.5…1.5 across the box,
    /// shineAngle degrees, shineWidth px), rays of light streaking out of its bright parts (rays strength,
    /// raysLength 0…0.95), an outline around its alpha (px) and a glow inside its edges (strength, radius px).
    case shine, shinePosition, shineAngle, shineWidth, rays, raysLength, outline, innerGlow, innerGlowRadius
    /// Path operators (shapes): offsetPath (px, + grows), zigzag (amplitude px, ridges every waveLength/2),
    /// wigglePath (amplitude px, bumps every waveLength/2, evolving with waveSpeed), pucker (-1 bloat … 1 pucker),
    /// dashOffset (px along the dash pattern), taperStart/taperEnd (0…1 of the stroke thinning to a point).
    case offsetPath, zigzag, wigglePath, pucker, dashOffset, taperStart, taperEnd
    /// Video: the source second shown (keyframed: speed ramps, freeze frames, reverse). Replaces speed/trimIn.
    case timeRemap
    /// 2.5D: turn around the layer's horizontal / vertical axis (degrees), seen from `perspective` px away.
    /// In 3D (`threeD` layers, models) they turn the layer in the scene's 3D space and `perspective` is unused.
    case rotationX, rotationY, perspective
    /// 3D: depth of the layer (px, + = away from the viewer) and scale along it (models).
    case z, scaleZ
    /// Grading: input levels (black/white point 0…1, gamma), and how much of `gradientMap` / `lut` applies (0…1).
    case levelsBlack, levelsWhite, levelsGamma, gradientMapAmount, lutAmount
    /// Variable fonts (text): the wght / wdth axis value, 0 = the face's own.
    case fontWeightAxis, fontWidth
    /// Long shadow: length (px) cast along longShadowAngle (degrees, 45 = down-right) in `longShadowColor`.
    case longShadow, longShadowAngle
    /// Gooey merge (px: blurred then re-sharpened alpha, so overlapping shapes fuse like liquid) and halftone (dot cell px).
    case goo, halftone
    /// Secondary motion: inertia (0…1, overshoot after a move stops) and squash (0…1, stretch along the velocity).
    case inertia, squash

    /// Value a layer has when the property is not set.
    public var defaultValue: Double {
        switch self {
        case .scale, .scaleX, .scaleY, .scaleZ, .opacity, .reveal, .trim, .volume, .emission, .particleSpeed, .particleSize: return 1
        case .x: return 960
        case .y: return 540
        case .width: return 400
        case .height: return 240
        case .shadowY: return 8
        case .shadowBlur: return 16
        case .glowRadius: return 24
        case .keyTolerance: return 0.2
        case .keySoftness: return 0.1
        case .waveLength: return 120
        case .waveSpeed: return 1
        case .distortRadius: return 300
        case .perspective: return 1200
        case .levelsWhite, .levelsGamma, .gradientMapAmount, .lutAmount: return 1
        case .shineAngle: return 30
        case .shineWidth: return 120
        case .shinePosition: return 0.5
        case .raysLength: return 0.6
        case .innerGlowRadius: return 20
        case .longShadowAngle: return 45
        default: return 0
        }
    }

    /// Properties kept in `MotionLayer.extra` (written to JSON only when set).
    static let extras: [AnimProperty] = [.scaleX, .scaleY, .skewX, .skewY, .anchorX, .anchorY, .trim, .trimStart,
                                         .trimOffset, .letterSpacing, .blur, .shadowX, .shadowY, .shadowBlur,
                                         .shadowOpacity, .glow, .glowRadius, .pathProgress,
                                         .emission, .particleSpeed, .particleSize,
                                         .brightness, .contrast, .saturation, .hue, .tint, .wipe,
                                         .keyTolerance, .keySoftness, .waveWarp, .ripple, .waveLength, .waveSpeed,
                                         .twirl, .bulge, .distortRadius, .turbulence, .posterize, .pixelate, .rgbSplit,
                                         .glitch, .grain, .scanlines, .vignette, .directionalBlur, .blurAngle, .zoomBlur,
                                         .counter, .scramble, .textOffset,
                                         .shine, .shinePosition, .shineAngle, .shineWidth, .rays, .raysLength, .outline,
                                         .innerGlow, .innerGlowRadius, .offsetPath, .zigzag, .wigglePath, .pucker,
                                         .dashOffset, .taperStart, .taperEnd, .rotationX, .rotationY, .perspective,
                                         .z, .scaleZ,
                                         .levelsBlack, .levelsWhite, .levelsGamma, .gradientMapAmount, .lutAmount,
                                         .fontWeightAxis, .fontWidth, .longShadow, .longShadowAngle, .goo, .halftone,
                                         .inertia, .squash]

    public var title: String {
        switch self {
        case .x: return "X"
        case .y: return "Y"
        case .scale: return "Scale"
        case .scaleX: return "Scale X"
        case .scaleY: return "Scale Y"
        case .rotation: return "Rotation"
        case .skewX: return "Skew X"
        case .skewY: return "Skew Y"
        case .anchorX: return "Anchor X"
        case .anchorY: return "Anchor Y"
        case .opacity: return "Opacity"
        case .width: return "Width"
        case .height: return "Height"
        case .cornerRadius: return "Radius"
        case .strokeWidth: return "Stroke Width"
        case .trim: return "Trim End"
        case .trimStart: return "Trim Start"
        case .trimOffset: return "Trim Offset"
        case .reveal: return "Reveal"
        case .letterSpacing: return "Letter Spacing"
        case .blur: return "Blur"
        case .shadowX: return "Shadow X"
        case .shadowY: return "Shadow Y"
        case .shadowBlur: return "Shadow Blur"
        case .shadowOpacity: return "Shadow Opacity"
        case .glow: return "Glow"
        case .glowRadius: return "Glow Radius"
        case .pathProgress: return "Path Progress"
        case .volume: return "Volume"
        case .emission: return "Emission"
        case .particleSpeed: return "Particle Speed"
        case .particleSize: return "Particle Size"
        case .brightness: return "Brightness"
        case .contrast: return "Contrast"
        case .saturation: return "Saturation"
        case .hue: return "Hue"
        case .tint: return "Tint"
        case .wipe: return "Wipe"
        case .keyTolerance: return "Key Tolerance"
        case .keySoftness: return "Key Softness"
        case .waveWarp: return "Wave Warp"
        case .ripple: return "Ripple"
        case .waveLength: return "Wavelength"
        case .waveSpeed: return "Wave Speed"
        case .twirl: return "Twirl"
        case .bulge: return "Bulge"
        case .distortRadius: return "Distort Radius"
        case .turbulence: return "Turbulence"
        case .posterize: return "Posterize"
        case .pixelate: return "Pixelate"
        case .rgbSplit: return "RGB Split"
        case .glitch: return "Glitch"
        case .grain: return "Grain"
        case .scanlines: return "Scanlines"
        case .vignette: return "Vignette"
        case .directionalBlur: return "Directional Blur"
        case .blurAngle: return "Blur Angle"
        case .zoomBlur: return "Zoom Blur"
        case .counter: return "Counter"
        case .scramble: return "Scramble"
        case .textOffset: return "Path Offset"
        case .shine: return "Shine"
        case .shinePosition: return "Shine Position"
        case .shineAngle: return "Shine Angle"
        case .shineWidth: return "Shine Width"
        case .rays: return "Light Rays"
        case .raysLength: return "Rays Length"
        case .outline: return "Outline"
        case .innerGlow: return "Inner Glow"
        case .innerGlowRadius: return "Inner Glow Radius"
        case .offsetPath: return "Offset Path"
        case .zigzag: return "Zigzag"
        case .wigglePath: return "Wiggle Path"
        case .pucker: return "Pucker"
        case .dashOffset: return "Dash Offset"
        case .taperStart: return "Taper Start"
        case .taperEnd: return "Taper End"
        case .timeRemap: return "Time Remap"
        case .rotationX: return "Rotation X"
        case .rotationY: return "Rotation Y"
        case .perspective: return "Perspective"
        case .z: return "Z"
        case .scaleZ: return "Scale Z"
        case .fontWeightAxis: return "Font Weight Axis"
        case .fontWidth: return "Font Width"
        case .longShadow: return "Long Shadow"
        case .longShadowAngle: return "Long Shadow Angle"
        case .goo: return "Goo"
        case .halftone: return "Halftone"
        case .inertia: return "Inertia"
        case .squash: return "Squash"
        case .levelsBlack: return "Levels Black"
        case .levelsWhite: return "Levels White"
        case .levelsGamma: return "Gamma"
        case .gradientMapAmount: return "Gradient Map"
        case .lutAmount: return "LUT"
        }
    }

    /// Shown with two decimals rather than as whole pixels/degrees.
    public var isFractional: Bool {
        switch self {
        case .scale, .scaleX, .scaleY, .scaleZ, .opacity, .trim, .trimStart, .trimOffset, .reveal, .shadowOpacity, .glow,
             .pathProgress, .volume, .emission, .particleSpeed, .particleSize,
             .brightness, .contrast, .saturation, .tint, .wipe, .keyTolerance, .keySoftness, .waveSpeed, .bulge,
             .glitch, .grain, .scanlines, .vignette, .zoomBlur, .scramble, .shine, .shinePosition, .rays, .raysLength,
             .innerGlow, .pucker, .taperStart, .taperEnd, .levelsBlack, .levelsWhite, .levelsGamma,
             .gradientMapAmount, .lutAmount: return true
        default: return false
        }
    }
}

/// Animatable colors of a layer.
public enum ColorProperty: String, Codable, CaseIterable, Sendable {
    case fill, stroke, color

    public var title: String { rawValue.capitalized }
}

/// One keyframe track of a layer: a number or a color.
public enum KeyTrack: Hashable, Sendable {
    case number(AnimProperty)
    case color(ColorProperty)

    public init?(name: String) {
        if let p = AnimProperty(rawValue: name) { self = .number(p) }
        else if let c = ColorProperty(rawValue: name) { self = .color(c) }
        else { return nil }
    }

    public var name: String {
        switch self {
        case let .number(p): return p.rawValue
        case let .color(c): return c.rawValue
        }
    }

    public var title: String {
        switch self {
        case let .number(p): return p.title
        case let .color(c): return c.title
        }
    }

    public static var all: [KeyTrack] { AnimProperty.allCases.map(KeyTrack.number) + ColorProperty.allCases.map(KeyTrack.color) }
    public static var allNames: [String] { all.map(\.name) }
}

/// One visual element. Position (x, y) is the layer's center in scene pixels, origin top-left
/// (relative to the parent's center when `parent` is set).
public struct MotionLayer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var type: LayerType
    public var start: Double
    public var end: Double?

    public var x: AnimValue
    public var y: AnimValue
    public var scale: AnimValue
    public var rotation: AnimValue
    public var opacity: AnimValue
    /// Text only: fraction of characters shown (0...1), for typewriter effects.
    public var reveal: AnimValue
    /// Less common animatable properties (scaleX, skew, anchor, blur, shadow…). Missing = default value.
    public var extra: [AnimProperty: AnimValue]

    /// Layer whose transform (position, rotation, scale, skew) this layer follows.
    public var parent: String?
    /// When set, the layer's center follows this path (x/y are ignored), driven by `pathProgress`.
    public var motionPath: MotionPath?
    /// When set, the x/y keys form one curved path traveled at even speed (After Effects' spatial interpolation).
    public var spatial: SpatialPath?
    /// Per-track behavior after the last keyframe, keyed by property name ("rotation", "fill"…).
    public var loop: [String: LoopMode]
    /// Procedural noise added to numeric properties, keyed by property name.
    public var wiggle: [String: Wiggle]
    /// Offsets driven by the music's loudness or beat, keyed by property name.
    public var audioReact: [String: AudioReact]
    public var shadowColor: RGBA
    public var blendMode: BlendMode
    /// Glow tint (nil = the layer's own colors).
    public var glowColor: RGBA?
    /// Shown only through another layer's shape or brightness.
    public var matte: Matte?
    /// Draws stepped copies of the layer.
    public var repeater: Repeater?
    /// Shutter angle in degrees (180 = film look, 0 = off): fast motion smears over the frame's exposure.
    public var motionBlur: Double
    /// When the shutter opens, in degrees of a frame relative to the frame time (nil = centered: -motionBlur/2).
    public var motionBlurPhase: Double?
    /// Linear or radial fill (shapes, paths, text); replaces the solid fill/color.
    public var gradient: Gradient?
    /// Color the `tint` property maps white to (nil = white, i.e. black and white).
    public var tintColor: RGBA?
    /// Shape of the `wipe` transition (nil = linear, left to right).
    public var wipeStyle: WipeStyle?
    /// Camera parallax: 0 = moves with the camera as drawn, 1 = half as much (far away), -0.5 = twice as much (close).
    public var depth: Double
    /// Ignores the camera (HUD, captions, watermarks).
    public var fixed: Bool
    /// Properties driven by another layer's property (one hop), keyed by property name.
    public var links: [String: PropertyLink]
    /// Group: the layers inside it, drawn in its box (scene-sized unless width/height are set) with the group's
    /// center at the box's center; their x/y are in that box like in a scene, their times are scene times.
    public var children: [MotionLayer]
    /// Colors of the shine band, the outline and the inner glow (nil = white).
    public var shineColor: RGBA?
    public var outlineColor: RGBA?
    /// Color of the long shadow (default black at 35%).
    public var longShadowColor: RGBA?
    /// Marker-style bands behind words of a text layer.
    public var textHighlights: [TextHighlight]
    /// Other variable-font axes by tag ("slnt": -10, "opsz": 24); wght/wdth are the animatable fontWeightAxis/fontWidth.
    public var fontVariations: [String: Double]
    public var innerGlowColor: RGBA?
    /// Stroke dash pattern in px (on, off, …); empty = solid.
    public var dash: [Double]
    /// The layer's box corners pinned elsewhere (screens, signs), animatable.
    public var cornerPin: CornerPinValue?
    /// Puppet pins bending the layer.
    public var pins: [PuppetPin]
    /// Hide the layer while it is turned away (rotationX/Y past 90°), e.g. the two faces of a card flip.
    public var hideBackface: Bool
    /// Lives in the scene's 3D space (z, rotations in 3D, the camera's orbit/lens, sorted by depth). A 3D group keeps
    /// its 3D children in that space too. Models always are.
    public var threeD: Bool
    /// Model layers: the object and its material.
    public var model: Model3D
    /// Rig: the bone this layer hangs on (x/y/rotation are then relative to the bone's start and direction).
    public var bone: String?
    /// Groups: children's times (start/end, keyframes) count from the group's start instead of the scene's.
    public var localTime: Bool
    /// Drawing layers: the frames.
    public var drawing: Drawing
    /// Trim runs through the path's pieces one after another (handwriting) instead of all at once.
    public var trimSequential: Bool
    /// Master tone curve: points [x, y] in 0…1 (smooth, monotone between them).
    public var curves: [PathPoint]
    /// Colors from shadows to highlights the layer's brightness is mapped onto (duotone, tritone…).
    public var gradientMap: [RGBA]
    /// A 3D color lookup table (.cube file, asset name or path) applied to the layer.
    public var lut: String?
    /// Images/videos: cut out the person ("person") or the main subject ("subject") with Vision.
    public var removeBackground: BackgroundRemoval?
    /// Videos: how in-between source times are shown in slow motion (nearest frame, a blend, or optical flow).
    public var frameBlend: FrameBlend
    /// Color keyed out (green/blue screen); nil = no keying.
    public var keyColor: RGBA?
    /// Plays the layer's animation at this many frames per second (stop-motion look); nil = every frame.
    public var posterizeTime: Double?

    // Shape (rect/ellipse) and image size. Image defaults to its natural size.
    public var width: AnimValue?
    public var height: AnimValue?
    public var cornerRadius: AnimValue
    public var fill: ColorValue
    public var stroke: ColorValue?
    public var strokeWidth: AnimValue
    public var lineCap: LineCap?
    public var lineJoin: LineJoin?

    // Path: the shape in layer px around the layer's x/y (keyframes morph between shapes)
    public var d: PathValue
    public var fillRule: FillRule

    // Text
    public var text: String
    public var fontSize: Double
    public var fontWeight: String
    public var fontName: String?
    public var color: ColorValue
    public var align: TextAlign
    public var maxWidth: Double?
    /// Per-character / word / line animations (staggered entrances and exits).
    public var textAnimators: [TextAnimator]
    /// Decimals of the `counter` number shown for "{n}", and whether thousands are grouped ("1,234").
    public var counterDecimals: Int
    public var counterGrouping: Bool
    /// The text runs along this path (layer px around the layer's center) instead of in lines.
    public var textPath: MotionPath?

    // Image / video / audio file (a video can also be a folder of numbered images; particles: the sprite image)
    public var path: String?

    // Particles (width/height are the emitter's size)
    public var particles: ParticleSystem

    // Generator (width/height are its box)
    public var generator: Generator

    // Video
    /// Playback rate (2 = twice as fast).
    public var speed: Double
    /// What happens after the last frame.
    public var playback: VideoPlayback
    /// Image sequences: frames per second of the images (set from the scene when the layer is added).
    public var fps: Double?
    /// Source seconds shown over time (nil = play through speed/trimIn).
    public var timeRemap: AnimValue?

    // Audio
    /// Gain (1 = original level), animatable.
    public var volume: AnimValue
    public var role: AudioRole
    /// Seconds skipped at the beginning of the file (audio and video).
    public var trimIn: Double
    public var fadeIn: Double
    public var fadeOut: Double
    /// Music only: gain while a voice layer is speaking (e.g. 0.25). nil = no ducking.
    public var duckTo: Double?
    /// Length of the audio/video source in seconds (filled in when the layer is added).
    public var sourceDuration: Double?
    /// Voice layers: the spoken text and per-word timings.
    public var transcript: String?
    public var words: [WordTiming]?

    public init(id: String = "", name: String? = nil, type: LayerType, x: Double = 960, y: Double = 540) {
        self.id = id
        self.name = name ?? type.rawValue.capitalized
        self.type = type
        start = 0
        end = nil
        self.x = .constant(x)
        self.y = .constant(y)
        scale = .constant(1)
        rotation = .constant(0)
        opacity = .constant(1)
        reveal = .constant(1)
        extra = [:]
        parent = nil
        motionPath = nil
        spatial = nil
        loop = [:]
        wiggle = [:]
        audioReact = [:]
        shadowColor = RGBA(r: 0, g: 0, b: 0, a: 0.6)
        blendMode = .normal
        glowColor = nil
        matte = nil
        repeater = nil
        motionBlur = 0
        motionBlurPhase = nil
        gradient = nil
        tintColor = nil
        wipeStyle = nil
        depth = 0
        fixed = false
        links = [:]
        children = []
        shineColor = nil
        outlineColor = nil
        longShadowColor = nil
        textHighlights = []
        fontVariations = [:]
        innerGlowColor = nil
        dash = []
        cornerPin = nil
        pins = []
        hideBackface = false
        threeD = false
        bone = nil
        localTime = false
        drawing = Drawing()
        model = Model3D()
        trimSequential = false
        curves = []
        gradientMap = []
        lut = nil
        removeBackground = nil
        frameBlend = .off
        keyColor = nil
        posterizeTime = nil
        width = nil
        height = nil
        cornerRadius = .constant(0)
        fill = .constant(.white)
        stroke = nil
        strokeWidth = .constant(0)
        lineCap = nil
        lineJoin = nil
        d = .constant(.zero)
        fillRule = .nonzero
        text = type == .text ? "Text" : ""
        fontSize = 72
        fontWeight = "bold"
        fontName = nil
        color = .constant(.white)
        align = .center
        maxWidth = nil
        textAnimators = []
        counterDecimals = 0
        counterGrouping = false
        textPath = nil
        path = nil
        particles = ParticleSystem()
        generator = Generator()
        speed = 1
        playback = .once
        fps = nil
        timeRemap = nil
        volume = .constant(1)
        role = .sfx
        trimIn = 0
        fadeIn = 0
        fadeOut = 0
        duckTo = nil
        sourceDuration = nil
        transcript = nil
        words = nil
    }

    public subscript(_ p: AnimProperty) -> AnimValue {
        get {
            switch p {
            case .x: return x
            case .y: return y
            case .scale: return scale
            case .rotation: return rotation
            case .opacity: return opacity
            case .reveal: return reveal
            case .volume: return volume
            case .width: return width ?? .constant(type.hasNaturalSize ? 0 : p.defaultValue)
            case .height: return height ?? .constant(type.hasNaturalSize ? 0 : p.defaultValue)
            case .timeRemap: return timeRemap ?? .constant(0)
            case .cornerRadius: return cornerRadius
            case .strokeWidth: return strokeWidth
            default: return extra[p] ?? .constant(p.defaultValue)
            }
        }
        set {
            switch p {
            case .x: x = newValue
            case .y: y = newValue
            case .scale: scale = newValue
            case .rotation: rotation = newValue
            case .opacity: opacity = newValue
            case .reveal: reveal = newValue
            case .volume: volume = newValue
            case .width: width = (type.hasNaturalSize && newValue == .constant(0)) ? nil : newValue
            case .height: height = (type.hasNaturalSize && newValue == .constant(0)) ? nil : newValue
            case .timeRemap: timeRemap = newValue
            case .cornerRadius: cornerRadius = newValue
            case .strokeWidth: strokeWidth = newValue
            default: extra[p] = newValue == .constant(p.defaultValue) ? nil : newValue
            }
        }
    }

    public subscript(_ c: ColorProperty) -> ColorValue {
        get {
            switch c {
            case .fill: return fill
            case .stroke: return stroke ?? .constant(.clear)
            case .color: return color
            }
        }
        set {
            switch c {
            case .fill: fill = newValue
            case .stroke: stroke = newValue
            case .color: color = newValue
            }
        }
    }

    /// Value of a property at time t, including loops, wiggle, audio react and links to other layers.
    public func value(_ p: AnimProperty, at t: Double) -> Double {
        var v: Double
        if let link = links[p.rawValue], let track = link.track {
            v = track.value(at: t - link.delay) * link.multiply + link.add + proceduralOffset(p, at: t)
        } else {
            v = self[p].value(at: t, loop: loop[p.rawValue]) + proceduralOffset(p, at: t)
        }
        guard !extra.isEmpty else { return v }
        switch p {
        case .x, .y, .rotation, .scale, .scaleX, .scaleY:
            let inertia = self[.inertia].value(at: t)
            if inertia > 0.001 { v += inertiaOffset(p, amount: inertia, at: t) }
            if p == .scaleX || p == .scaleY {
                let squash = self[.squash].value(at: t)
                if squash > 0.001 { v *= squashFactor(p, amount: squash, at: t) }
            }
        default: break
        }
        return v
    }

    /// Damped wobble added after a keyframed move stops (or changes speed abruptly): `amount` × the lost velocity,
    /// ringing at 2.5 Hz and dying out within about a second. Deterministic: any frame renders alone.
    func inertiaOffset(_ p: AnimProperty, amount: Double, at t: Double) -> Double {
        let keys = self[p].keyframeList
        guard keys.count >= 2 else { return 0 }
        let omega = 2 * Double.pi * 2.5, damping = 3.5, h = 1.0 / 120
        let lp = loop[p.rawValue]
        func raw(_ x: Double) -> Double { self[p].value(at: x, loop: lp) }
        var off = 0.0
        for k in keys.dropFirst() {
            let dt = t - k.t
            guard dt > 0 else { break }
            guard dt < 2.5 else { continue }
            let before = (raw(k.t) - raw(k.t - h)) / h
            let after = (raw(k.t + h) - raw(k.t)) / h
            let dv = before - after
            guard abs(dv) > 1e-6 else { continue }
            off += amount * dv / omega * exp(-damping * dt) * sin(omega * dt)
        }
        return off
    }

    /// Stretch along the direction the layer moves (and squeeze across it): 1 + amount × speed / 2000 px/s, at most 1.7×.
    func squashFactor(_ p: AnimProperty, amount: Double, at t: Double) -> Double {
        let h = 1.0 / 120
        let vx = (self[.x].value(at: t + h, loop: loop["x"]) - self[.x].value(at: t - h, loop: loop["x"])) / (2 * h)
        let vy = (self[.y].value(at: t + h, loop: loop["y"]) - self[.y].value(at: t - h, loop: loop["y"])) / (2 * h)
        let speed = (vx * vx + vy * vy).squareRoot()
        guard speed > 1 else { return 1 }
        let k = min(amount * speed / 2000, 0.7)
        let alongX = abs(vx) >= abs(vy)
        if p == .scaleX { return alongX ? 1 + k : 1 / (1 + k) }
        return alongX ? 1 / (1 + k) : 1 + k
    }

    /// What wiggle and audio react add to a property at time t.
    public func proceduralOffset(_ p: AnimProperty, at t: Double) -> Double {
        var v = 0.0
        if let w = wiggle[p.rawValue], w.amount != 0 {
            v += w.offset(at: t, salt: Noise.hash("\(id).\(p.rawValue)"))
        }
        if let r = audioReact[p.rawValue] { v += r.offset(at: t) }
        return v
    }

    /// Color at time t, including loops. nil for a layer without a stroke.
    public func color(_ c: ColorProperty, at t: Double) -> RGBA? {
        if c == .stroke && stroke == nil { return nil }
        return self[c].value(at: t, loop: loop[c.rawValue])
    }

    /// Properties that make sense for this layer type (inspector, timeline).
    public var applicableProperties: [AnimProperty] {
        if type == .audio { return [.volume] }
        // 3D layers have a depth and see the camera's perspective; 2D ones have a perspective of their own.
        var list: [AnimProperty] = [.x, .y] + (is3D ? [.z] : []) + [.scale, .scaleX, .scaleY, .rotation, .rotationX, .rotationY]
            + (is3D ? [] : [.perspective]) + [.skewX, .skewY, .anchorX, .anchorY, .opacity]
        switch type {
        case .rect: list += [.width, .height, .cornerRadius, .strokeWidth, .trimStart, .trim, .trimOffset]
        case .ellipse: list += [.width, .height, .strokeWidth, .trimStart, .trim, .trimOffset]
        case .path: list += [.strokeWidth, .trimStart, .trim, .trimOffset]
        case .text:
            list += [.reveal, .letterSpacing, .strokeWidth, .scramble, .fontWeightAxis, .fontWidth]
            if text.contains("{n}") { list.append(.counter) }
            if textPath != nil { list.append(.textOffset) }
        case .image: list += [.width, .height]
        case .video:
            list += [.width, .height, .volume]
            if timeRemap != nil { list.append(.timeRemap) }
        case .particles: list += [.width, .height, .emission, .particleSpeed, .particleSize]
        case .generator:
            list += [.width, .height, .cornerRadius, .strokeWidth]
            if generator.kind == .chart { list.append(.reveal) }
        case .group: list += [.width, .height]
        case .model: list += [.width, .height, .scaleZ]
        case .drawing: break
        case .audio: break
        }
        list += [.blur, .shadowX, .shadowY, .shadowBlur, .shadowOpacity, .glow, .glowRadius, .longShadow, .longShadowAngle]
        list += [.goo, .halftone, .inertia, .squash]
        list += [.brightness, .contrast, .saturation, .hue, .tint, .wipe, .levelsBlack, .levelsWhite, .levelsGamma]
        if !gradientMap.isEmpty { list.append(.gradientMapAmount) }
        if lut != nil { list.append(.lutAmount) }
        list += [.posterize, .pixelate, .rgbSplit, .glitch, .grain, .scanlines, .vignette, .directionalBlur, .blurAngle,
                 .zoomBlur, .waveWarp, .ripple, .waveLength, .waveSpeed, .twirl, .bulge, .distortRadius, .turbulence]
        if keyColor != nil { list += [.keyTolerance, .keySoftness] }
        list += [.shine, .shinePosition, .shineAngle, .shineWidth, .rays, .raysLength, .outline, .innerGlow, .innerGlowRadius]
        if type.isShape {
            list += [.offsetPath, .zigzag, .wigglePath, .pucker, .taperStart, .taperEnd]
            if !dash.isEmpty { list.append(.dashOffset) }
        }
        if motionPath != nil { list.append(.pathProgress) }
        return list
    }

    public var applicableColors: [ColorProperty] {
        switch type {
        case .rect, .ellipse, .path: return [.fill, .stroke]
        case .text: return [.color, .stroke]
        case .model: return [.fill]
        case .generator:
            switch generator.kind {
            case .noise, .flare: return []
            case .chart: return [.fill, .color]
            default: return [.fill]
            }
        default: return []
        }
    }

    /// Playable length of an audio layer's file after trimming.
    public var audioLength: Double? { sourceDuration.map { max(0, $0 - trimIn) } }

    /// Scene seconds the layer can last before its source runs out: audio, and videos that play once.
    /// nil when unknown or unlimited (videos that hold or loop).
    public var mediaLength: Double? {
        switch type {
        case .audio: return audioLength
        case .video where playback == .once && timeRemap == nil: return sourceDuration.map { max(0, $0 - trimIn) / max(speed, 0.01) }
        default: return nil
        }
    }

    public var animatedProperties: [AnimProperty] {
        AnimProperty.allCases.filter { self[$0].isAnimated }
    }

    public var animatedColors: [ColorProperty] {
        ColorProperty.allCases.filter { self[$0].isAnimated }
    }

    /// Every keyframed track (numbers, then colors).
    public var animatedTracks: [KeyTrack] {
        animatedProperties.map(KeyTrack.number) + animatedColors.map(KeyTrack.color)
    }

    public var keyframeTimes: [Double] {
        Array(Set(KeyTrack.all.flatMap { keyTimes($0) })).sorted()
    }

    // MARK: Track access (numbers and colors alike)

    public func isAnimated(_ k: KeyTrack) -> Bool {
        switch k {
        case let .number(p): return self[p].isAnimated
        case let .color(c): return self[c].isAnimated
        }
    }

    public func keyTimes(_ k: KeyTrack) -> [Double] {
        switch k {
        case let .number(p): return self[p].keyframeList.map(\.t)
        case let .color(c): return self[c].keyframeList.map(\.t)
        }
    }

    /// (time, easing, value rising?) of every key of a track, for drawing curves.
    public func keys(_ k: KeyTrack) -> [(t: Double, easing: Easing, rising: Bool)] {
        switch k {
        case let .number(p):
            let kfs = self[p].keyframeList
            return kfs.indices.map { i in (kfs[i].t, kfs[i].easing, i == 0 || kfs[i].v >= kfs[i - 1].v) }
        case let .color(c):
            return self[c].keyframeList.map { ($0.t, $0.easing, true) }
        }
    }

    public func hasKey(_ k: KeyTrack, at t: Double, tolerance: Double) -> Bool {
        switch k {
        case let .number(p): return self[p].hasKey(at: t, tolerance: tolerance)
        case let .color(c): return self[c].hasKey(at: t, tolerance: tolerance)
        }
    }

    public func easing(_ k: KeyTrack, at t: Double, tolerance: Double) -> Easing? {
        switch k {
        case let .number(p): return self[p].keyframeList.first { abs($0.t - t) < tolerance }?.easing
        case let .color(c): return self[c].keyframeList.first { abs($0.t - t) < tolerance }?.easing
        }
    }

    public mutating func moveKey(_ k: KeyTrack, at t: Double, to newT: Double, tolerance: Double) {
        switch k {
        case let .number(p):
            self[p] = self[p].movingKey(at: t, to: newT, tolerance: tolerance)
            if p == .x || p == .y { spatial?.moveHandle(at: t, to: newT) }
        case let .color(c): self[c] = self[c].movingKey(at: t, to: newT, tolerance: tolerance)
        }
    }

    public mutating func setEasing(_ k: KeyTrack, at t: Double, _ e: Easing, tolerance: Double) {
        switch k {
        case let .number(p): self[p] = self[p].settingEasing(at: t, e, tolerance: tolerance)
        case let .color(c): self[c] = self[c].settingEasing(at: t, e, tolerance: tolerance)
        }
    }

    public mutating func deleteKey(_ k: KeyTrack, at t: Double, tolerance: Double) {
        switch k {
        case let .number(p):
            self[p] = self[p].deletingKey(at: t, tolerance: tolerance)
            if (p == .x || p == .y) && !x.hasKey(at: t, tolerance: tolerance) && !y.hasKey(at: t, tolerance: tolerance) {
                spatial?.handles.removeAll { abs($0.t - t) < tolerance }
            }
        case let .color(c):
            if c == .stroke && stroke == nil { return }
            self[c] = self[c].deletingKey(at: t, tolerance: tolerance)
        }
    }

    /// Moves every keyframe (and text animator) by d seconds.
    public mutating func shiftKeys(by d: Double) {
        for p in AnimProperty.allCases where self[p].isAnimated { self[p] = self[p].shifted(by: d) }
        for c in ColorProperty.allCases where self[c].isAnimated { self[c] = self[c].shifted(by: d) }
        for i in textAnimators.indices { textAnimators[i].start += d }
        for i in particles.bursts.indices { particles.bursts[i].t += d }
        self.d = self.d.shifted(by: d)
        gradient = gradient?.shifted(by: d)
        repeater = repeater?.shifted(by: d)
        cornerPin = cornerPin?.shifted(by: d)
        pins = pins.map { $0.shifted(by: d) }
        timeRemap = timeRemap?.shifted(by: d)
        if spatial != nil { for i in spatial!.handles.indices { spatial!.handles[i].t += d } }
    }

    /// Earliest keyframe, text-animator or particle-burst time, if any.
    public var earliestKeyTime: Double? {
        (Array(keyframeTimes.prefix(1)) + textAnimators.map(\.start) + particles.bursts.map(\.t)).min()
    }

    /// Visual layers default to the scene end; audio layers and videos that play once to the end of their (trimmed) file.
    public func effectiveEnd(sceneDuration: Double) -> Double {
        if let end { return end }
        if let len = mediaLength { return start + len }
        return sceneDuration
    }

    public func isVisible(at t: Double, sceneDuration: Double) -> Bool {
        t >= start && t < effectiveEnd(sceneDuration: sceneDuration) + 1e-9
    }

    public func shapeWidth(at t: Double) -> Double { value(.width, at: t) }
    /// Path layers: the shape at time t (morphing between keyframes, looping like other tracks under "d").
    public func pathShape(at t: Double) -> PathShape { d.value(at: t, loop: loop["d"]) }
    public func shapeHeight(at t: Double) -> Double { value(.height, at: t) }

    enum CodingKeys: String, CodingKey {
        case id, name, type, start, end, x, y, scale, rotation, opacity, reveal
        case scaleX, scaleY, skewX, skewY, anchorX, anchorY, trim, letterSpacing
        case trimStart, trimOffset, glow, glowRadius, glowColor, matte, repeater, motionBlur, motionBlurPhase, gradient
        case blur, shadowX, shadowY, shadowBlur, shadowOpacity, shadowColor, pathProgress, blendMode
        case emission, particleSpeed, particleSize, particles, generator
        case brightness, contrast, saturation, hue, tint, tintColor, wipe, wipeStyle
        case keyColor, keyTolerance, keySoftness, waveWarp, ripple, waveLength, waveSpeed, twirl, bulge, distortRadius
        case turbulence, posterize, pixelate, rgbSplit, glitch, grain, scanlines, vignette, directionalBlur, blurAngle
        case zoomBlur, posterizeTime, depth, fixed, links, children, counterDecimals, counterGrouping, textPath
        case counter, scramble, textOffset
        case shine, shinePosition, shineAngle, shineWidth, rays, raysLength, outline, innerGlow, innerGlowRadius
        case shineColor, outlineColor, innerGlowColor, dash
        case fontWeightAxis, fontWidth, longShadow, longShadowAngle, longShadowColor, goo, halftone, inertia, squash
        case textHighlights, fontVariations
        case bone, localTime, drawing
        case rotationX, rotationY, perspective, cornerPin, pins, hideBackface, trimSequential, z, scaleZ, threeD, model
        case levelsBlack, levelsWhite, levelsGamma, gradientMapAmount, lutAmount, curves, gradientMap, lut
        case removeBackground, frameBlend
        case offsetPath, zigzag, wigglePath, pucker, dashOffset, taperStart, taperEnd
        case parent, motionPath, spatial, loop, wiggle, audioReact, textAnimators
        case width, height, cornerRadius, fill, stroke, strokeWidth, lineCap, lineJoin, d, fillRule
        case text, fontSize, fontWeight, fontName, color, align, maxWidth
        case path, speed, playback, fps, timeRemap
        case volume, role, trimIn, fadeIn, fadeOut, duckTo, sourceDuration, transcript, words
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(LayerType.self, forKey: .type)
        self.init(type: type)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? (id.isEmpty ? type.rawValue.capitalized : id)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? start
        end = try c.decodeIfPresent(Double.self, forKey: .end)
        x = try c.decodeIfPresent(AnimValue.self, forKey: .x) ?? x
        y = try c.decodeIfPresent(AnimValue.self, forKey: .y) ?? y
        scale = try c.decodeIfPresent(AnimValue.self, forKey: .scale) ?? scale
        rotation = try c.decodeIfPresent(AnimValue.self, forKey: .rotation) ?? rotation
        opacity = try c.decodeIfPresent(AnimValue.self, forKey: .opacity) ?? opacity
        reveal = try c.decodeIfPresent(AnimValue.self, forKey: .reveal) ?? reveal
        for p in AnimProperty.extras {
            guard let key = CodingKeys(rawValue: p.rawValue) else { continue }
            if let v = try c.decodeIfPresent(AnimValue.self, forKey: key) { self[p] = v }
        }
        parent = try c.decodeIfPresent(String.self, forKey: .parent).flatMap { $0.isEmpty ? nil : $0 }
        motionPath = try c.decodeIfPresent(MotionPath.self, forKey: .motionPath)
        spatial = try c.decodeIfPresent(SpatialPath.self, forKey: .spatial)
        loop = try c.decodeIfPresent([String: LoopMode].self, forKey: .loop) ?? [:]
        for k in loop.keys where KeyTrack(name: k) == nil && k != "d" {
            throw DecodingError.dataCorruptedError(forKey: .loop, in: c,
                debugDescription: "Unknown property '\(k)' in loop. Use one of \(KeyTrack.allNames + ["d"]).")
        }
        wiggle = try c.decodeIfPresent([String: Wiggle].self, forKey: .wiggle) ?? [:]
        for k in wiggle.keys where AnimProperty(rawValue: k) == nil {
            throw DecodingError.dataCorruptedError(forKey: .wiggle, in: c,
                debugDescription: "Unknown property '\(k)' in wiggle. Use one of \(AnimProperty.allCases.map(\.rawValue)).")
        }
        audioReact = try c.decodeIfPresent([String: AudioReact].self, forKey: .audioReact) ?? [:]
        for k in audioReact.keys where AnimProperty(rawValue: k) == nil {
            throw DecodingError.dataCorruptedError(forKey: .audioReact, in: c,
                debugDescription: "Unknown property '\(k)' in audioReact. Use one of \(AnimProperty.allCases.map(\.rawValue)).")
        }
        shadowColor = try c.decodeIfPresent(RGBA.self, forKey: .shadowColor) ?? shadowColor
        particles = try c.decodeIfPresent(ParticleSystem.self, forKey: .particles) ?? particles
        generator = try c.decodeIfPresent(Generator.self, forKey: .generator) ?? generator
        blendMode = try c.decodeIfPresent(BlendMode.self, forKey: .blendMode)
            ?? (type == .particles ? particles.preset?.defaultBlendMode ?? .normal : .normal)
        glowColor = try c.decodeIfPresent(RGBA.self, forKey: .glowColor)
        matte = try c.decodeIfPresent(Matte.self, forKey: .matte).flatMap { $0.source.isEmpty ? nil : $0 }
        repeater = try c.decodeIfPresent(Repeater.self, forKey: .repeater)
        motionBlur = min(max(try c.decodeIfPresent(Double.self, forKey: .motionBlur) ?? 0, 0), 720)
        motionBlurPhase = try c.decodeIfPresent(Double.self, forKey: .motionBlurPhase).map { min(max($0, -360), 360) }
        gradient = try c.decodeIfPresent(Gradient.self, forKey: .gradient)
        tintColor = try c.decodeIfPresent(RGBA.self, forKey: .tintColor)
        wipeStyle = try c.decodeIfPresent(WipeStyle.self, forKey: .wipeStyle)
        keyColor = try c.decodeIfPresent(RGBA.self, forKey: .keyColor)
        shineColor = try c.decodeIfPresent(RGBA.self, forKey: .shineColor)
        outlineColor = try c.decodeIfPresent(RGBA.self, forKey: .outlineColor)
        longShadowColor = try c.decodeIfPresent(RGBA.self, forKey: .longShadowColor)
        textHighlights = try c.decodeIfPresent([TextHighlight].self, forKey: .textHighlights) ?? []
        fontVariations = try c.decodeIfPresent([String: Double].self, forKey: .fontVariations) ?? [:]
        innerGlowColor = try c.decodeIfPresent(RGBA.self, forKey: .innerGlowColor)
        cornerPin = try c.decodeIfPresent(CornerPinValue.self, forKey: .cornerPin)
        pins = try c.decodeIfPresent([PuppetPin].self, forKey: .pins) ?? []
        hideBackface = try c.decodeIfPresent(Bool.self, forKey: .hideBackface) ?? false
        threeD = try c.decodeIfPresent(Bool.self, forKey: .threeD) ?? false
        bone = try c.decodeIfPresent(String.self, forKey: .bone).flatMap { $0.isEmpty ? nil : $0 }
        localTime = try c.decodeIfPresent(Bool.self, forKey: .localTime) ?? false
        drawing = try c.decodeIfPresent(Drawing.self, forKey: .drawing) ?? Drawing()
        model = try c.decodeIfPresent(Model3D.self, forKey: .model) ?? model
        trimSequential = try c.decodeIfPresent(Bool.self, forKey: .trimSequential) ?? false
        curves = (try c.decodeIfPresent([PathPoint].self, forKey: .curves) ?? [])
            .map { PathPoint(x: min(max($0.x, 0), 1), y: min(max($0.y, 0), 1)) }.sorted { $0.x < $1.x }
        gradientMap = try c.decodeIfPresent([RGBA].self, forKey: .gradientMap) ?? []
        lut = try c.decodeIfPresent(String.self, forKey: .lut).flatMap { $0.isEmpty ? nil : $0 }
        removeBackground = try c.decodeIfPresent(BackgroundRemoval.self, forKey: .removeBackground)
        frameBlend = try c.decodeIfPresent(FrameBlend.self, forKey: .frameBlend) ?? .off
        dash = (try c.decodeIfPresent([Double].self, forKey: .dash) ?? []).map { max(0, $0) }
        if dash.allSatisfy({ $0 <= 0 }) { dash = [] }
        depth = max(-0.9, try c.decodeIfPresent(Double.self, forKey: .depth) ?? 0)
        fixed = try c.decodeIfPresent(Bool.self, forKey: .fixed) ?? false
        links = try c.decodeIfPresent([String: PropertyLink].self, forKey: .links) ?? [:]
        for k in links.keys where AnimProperty(rawValue: k) == nil {
            throw DecodingError.dataCorruptedError(forKey: .links, in: c,
                debugDescription: "Unknown property '\(k)' in links. Use one of \(AnimProperty.allCases.map(\.rawValue)).")
        }
        children = try c.decodeIfPresent([MotionLayer].self, forKey: .children) ?? []
        posterizeTime = try c.decodeIfPresent(Double.self, forKey: .posterizeTime).flatMap { $0 > 0 ? $0 : nil }
        width = try c.decodeIfPresent(AnimValue.self, forKey: .width)
        height = try c.decodeIfPresent(AnimValue.self, forKey: .height)
        cornerRadius = try c.decodeIfPresent(AnimValue.self, forKey: .cornerRadius) ?? cornerRadius
        stroke = try c.decodeIfPresent(ColorValue.self, forKey: .stroke)
        // A path with only a stroke is a line: no fill unless one is given.
        fill = try c.decodeIfPresent(ColorValue.self, forKey: .fill) ?? (type == .path && stroke != nil ? .constant(.clear) : fill)
        strokeWidth = try c.decodeIfPresent(AnimValue.self, forKey: .strokeWidth) ?? .constant(stroke == nil ? 0 : 4)
        lineCap = try c.decodeIfPresent(LineCap.self, forKey: .lineCap)
        lineJoin = try c.decodeIfPresent(LineJoin.self, forKey: .lineJoin)
        d = try c.decodeIfPresent(PathValue.self, forKey: .d) ?? d
        fillRule = try c.decodeIfPresent(FillRule.self, forKey: .fillRule) ?? .nonzero
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? text
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        fontWeight = try c.decodeIfPresent(String.self, forKey: .fontWeight) ?? fontWeight
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        color = try c.decodeIfPresent(ColorValue.self, forKey: .color) ?? color
        align = try c.decodeIfPresent(TextAlign.self, forKey: .align) ?? align
        maxWidth = try c.decodeIfPresent(Double.self, forKey: .maxWidth)
        textAnimators = try c.decodeIfPresent([TextAnimator].self, forKey: .textAnimators) ?? []
        counterDecimals = min(max(try c.decodeIfPresent(Int.self, forKey: .counterDecimals) ?? 0, 0), 6)
        counterGrouping = try c.decodeIfPresent(Bool.self, forKey: .counterGrouping) ?? false
        textPath = try c.decodeIfPresent(MotionPath.self, forKey: .textPath).flatMap { $0.points.count >= 2 ? $0 : nil }
        path = try c.decodeIfPresent(String.self, forKey: .path)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        guard speed > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .speed, in: c, debugDescription: "speed must be greater than 0")
        }
        playback = try c.decodeIfPresent(VideoPlayback.self, forKey: .playback) ?? .once
        fps = try c.decodeIfPresent(Double.self, forKey: .fps).flatMap { $0 > 0 ? $0 : nil }
        timeRemap = try c.decodeIfPresent(AnimValue.self, forKey: .timeRemap)
        volume = try c.decodeIfPresent(AnimValue.self, forKey: .volume) ?? volume
        role = try c.decodeIfPresent(AudioRole.self, forKey: .role) ?? role
        trimIn = max(0, try c.decodeIfPresent(Double.self, forKey: .trimIn) ?? 0)
        fadeIn = max(0, try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0)
        fadeOut = max(0, try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0)
        duckTo = try c.decodeIfPresent(Double.self, forKey: .duckTo)
        sourceDuration = try c.decodeIfPresent(Double.self, forKey: .sourceDuration)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript)
        words = try c.decodeIfPresent([WordTiming].self, forKey: .words)
    }

    private func encodePaint(_ c: inout KeyedEncodingContainer<CodingKeys>) throws {
        try c.encode(fill, forKey: .fill)
        try c.encodeIfPresent(stroke, forKey: .stroke)
        if stroke != nil { try c.encode(strokeWidth, forKey: .strokeWidth) }
        try c.encodeIfPresent(lineCap, forKey: .lineCap)
        try c.encodeIfPresent(lineJoin, forKey: .lineJoin)
    }

    /// Only writes fields relevant to the layer type, so JSON stays compact for humans and agents.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encode(start, forKey: .start)
        try c.encodeIfPresent(end, forKey: .end)
        if type == .audio {
            try c.encodeIfPresent(path, forKey: .path)
            try c.encode(role, forKey: .role)
            try c.encode(volume, forKey: .volume)
            if trimIn > 0 { try c.encode(trimIn, forKey: .trimIn) }
            if fadeIn > 0 { try c.encode(fadeIn, forKey: .fadeIn) }
            if fadeOut > 0 { try c.encode(fadeOut, forKey: .fadeOut) }
            try c.encodeIfPresent(duckTo, forKey: .duckTo)
            try c.encodeIfPresent(sourceDuration, forKey: .sourceDuration)
            try c.encodeIfPresent(transcript, forKey: .transcript)
            try c.encodeIfPresent(words, forKey: .words)
            if loop["volume"] != nil { try c.encode(loop, forKey: .loop) }
            if wiggle["volume"] != nil { try c.encode(wiggle, forKey: .wiggle) }
            return
        }
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(scale, forKey: .scale)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(opacity, forKey: .opacity)
        for p in AnimProperty.extras {
            guard let v = extra[p], v != .constant(p.defaultValue), let key = CodingKeys(rawValue: p.rawValue) else { continue }
            try c.encode(v, forKey: key)
        }
        if extra[.shadowOpacity] != nil { try c.encode(shadowColor, forKey: .shadowColor) }
        // Particles always write it: a missing blendMode takes the preset's default.
        if blendMode != .normal || type == .particles { try c.encode(blendMode, forKey: .blendMode) }
        if extra[.glow] != nil { try c.encodeIfPresent(glowColor, forKey: .glowColor) }
        try c.encodeIfPresent(matte, forKey: .matte)
        try c.encodeIfPresent(repeater, forKey: .repeater)
        if motionBlur > 0 { try c.encode(motionBlur, forKey: .motionBlur) }
        try c.encodeIfPresent(motionBlurPhase, forKey: .motionBlurPhase)
        // Written even before tint/wipe are set, so a patch that only sets the style survives the next round trip.
        try c.encodeIfPresent(tintColor, forKey: .tintColor)
        try c.encodeIfPresent(wipeStyle, forKey: .wipeStyle)
        try c.encodeIfPresent(keyColor, forKey: .keyColor)
        try c.encodeIfPresent(shineColor, forKey: .shineColor)
        try c.encodeIfPresent(outlineColor, forKey: .outlineColor)
        try c.encodeIfPresent(longShadowColor, forKey: .longShadowColor)
        if !textHighlights.isEmpty && type == .text { try c.encode(textHighlights, forKey: .textHighlights) }
        if !fontVariations.isEmpty && type == .text { try c.encode(fontVariations, forKey: .fontVariations) }
        try c.encodeIfPresent(innerGlowColor, forKey: .innerGlowColor)
        if !dash.isEmpty && type.isShape { try c.encode(dash, forKey: .dash) }
        try c.encodeIfPresent(cornerPin, forKey: .cornerPin)
        if !pins.isEmpty { try c.encode(pins, forKey: .pins) }
        if hideBackface { try c.encode(hideBackface, forKey: .hideBackface) }
        if threeD && type != .model { try c.encode(threeD, forKey: .threeD) }
        if trimSequential && type.isShape { try c.encode(trimSequential, forKey: .trimSequential) }
        if !curves.isEmpty { try c.encode(curves, forKey: .curves) }
        if !gradientMap.isEmpty { try c.encode(gradientMap, forKey: .gradientMap) }
        try c.encodeIfPresent(lut, forKey: .lut)
        if type.hasNaturalSize { try c.encodeIfPresent(removeBackground, forKey: .removeBackground) }
        if type == .video && frameBlend != .off { try c.encode(frameBlend, forKey: .frameBlend) }
        if depth != 0 { try c.encode(depth, forKey: .depth) }
        if fixed { try c.encode(fixed, forKey: .fixed) }
        if !links.isEmpty { try c.encode(links, forKey: .links) }
        try c.encodeIfPresent(posterizeTime, forKey: .posterizeTime)
        if type.isShape || type == .text || type == .generator { try c.encodeIfPresent(gradient, forKey: .gradient) }
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encodeIfPresent(bone, forKey: .bone)
        try c.encodeIfPresent(motionPath, forKey: .motionPath)
        try c.encodeIfPresent(spatial, forKey: .spatial)
        if !loop.isEmpty { try c.encode(loop, forKey: .loop) }
        if !wiggle.isEmpty { try c.encode(wiggle, forKey: .wiggle) }
        if !audioReact.isEmpty { try c.encode(audioReact, forKey: .audioReact) }
        switch type {
        case .audio:
            break
        case .rect, .ellipse:
            try c.encode(self[.width], forKey: .width)
            try c.encode(self[.height], forKey: .height)
            if type == .rect { try c.encode(cornerRadius, forKey: .cornerRadius) }
            try encodePaint(&c)
        case .path:
            try c.encode(d, forKey: .d)
            try encodePaint(&c)
            if fillRule != .nonzero { try c.encode(fillRule, forKey: .fillRule) }
        case .text:
            try c.encode(reveal, forKey: .reveal)
            try c.encode(text, forKey: .text)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encode(fontWeight, forKey: .fontWeight)
            try c.encodeIfPresent(fontName, forKey: .fontName)
            try c.encode(color, forKey: .color)
            try c.encode(align, forKey: .align)
            try c.encodeIfPresent(maxWidth, forKey: .maxWidth)
            if !textAnimators.isEmpty { try c.encode(textAnimators, forKey: .textAnimators) }
            if stroke != nil { try c.encode(stroke, forKey: .stroke); try c.encode(strokeWidth, forKey: .strokeWidth) }
            if counterDecimals != 0 { try c.encode(counterDecimals, forKey: .counterDecimals) }
            if counterGrouping { try c.encode(counterGrouping, forKey: .counterGrouping) }
            try c.encodeIfPresent(textPath, forKey: .textPath)
        case .image:
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(width, forKey: .width)
            try c.encodeIfPresent(height, forKey: .height)
        case .video:
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(width, forKey: .width)
            try c.encodeIfPresent(height, forKey: .height)
            if trimIn > 0 { try c.encode(trimIn, forKey: .trimIn) }
            if speed != 1 { try c.encode(speed, forKey: .speed) }
            try c.encode(playback, forKey: .playback)
            try c.encodeIfPresent(fps, forKey: .fps)
            try c.encodeIfPresent(timeRemap, forKey: .timeRemap)
            try c.encodeIfPresent(sourceDuration, forKey: .sourceDuration)
            if volume != .constant(1) { try c.encode(volume, forKey: .volume) }
            try c.encodeIfPresent(transcript, forKey: .transcript)
            try c.encodeIfPresent(words, forKey: .words)
        case .particles:
            try c.encode(self[.width], forKey: .width)
            try c.encode(self[.height], forKey: .height)
            try c.encode(particles, forKey: .particles)
            try c.encodeIfPresent(path, forKey: .path)
        case .group:
            try c.encode(children, forKey: .children)
            try c.encodeIfPresent(width, forKey: .width)
            try c.encodeIfPresent(height, forKey: .height)
            if localTime { try c.encode(localTime, forKey: .localTime) }
        case .drawing:
            try c.encode(drawing, forKey: .drawing)
        case .model:
            try c.encode(model, forKey: .model)
            try c.encode(self[.width], forKey: .width)
            try c.encode(self[.height], forKey: .height)
            try c.encode(fill, forKey: .fill)
            try c.encodeIfPresent(path, forKey: .path)
            switch model.shape {
            case .text:
                try c.encode(text, forKey: .text)
                try c.encode(fontSize, forKey: .fontSize)
                try c.encode(fontWeight, forKey: .fontWeight)
                try c.encodeIfPresent(fontName, forKey: .fontName)
                try c.encode(align, forKey: .align)
                try c.encodeIfPresent(maxWidth, forKey: .maxWidth)
            case .path:
                try c.encode(d, forKey: .d)
                if fillRule != .nonzero { try c.encode(fillRule, forKey: .fillRule) }
            case .lathe:
                try c.encode(d, forKey: .d)
            default:
                break
            }
        case .generator:
            try c.encode(generator, forKey: .generator)
            try c.encode(self[.width], forKey: .width)
            try c.encode(self[.height], forKey: .height)
            if generator.kind != .noise && generator.kind != .flare { try c.encode(fill, forKey: .fill) }
            if generator.kind == .chart {
                try c.encode(reveal, forKey: .reveal)
                try c.encode(color, forKey: .color)
                try c.encode(fontSize, forKey: .fontSize)
                try c.encode(fontWeight, forKey: .fontWeight)
                try c.encodeIfPresent(fontName, forKey: .fontName)
            }
            if strokeWidth != .constant(0) { try c.encode(strokeWidth, forKey: .strokeWidth) }
            if cornerRadius != .constant(0) { try c.encode(cornerRadius, forKey: .cornerRadius) }
        }
    }
}

public struct MotionScene: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var duration: Double { didSet { resolveLinks() } }
    public var background: RGBA
    /// Pans, zooms and turns the whole scene (nil = none). Layers with `depth` move less or more (parallax),
    /// `fixed` layers not at all.
    public var camera: Camera? { didSet { if camera != oldValue { resolveLinks() } } }
    /// Lights for model layers (empty = `Light.defaults`: soft ambient, a key light from the upper left, a fill).
    public var lights: [Light]
    /// Cut-out rig (see `Rig.swift`): bones layers can hang on, posed by angle keyframes or `solveIK`.
    public var bones: [Bone]
    /// The piece is meant to repeat seamlessly: its last frame flows into its first (the lint checks the seam).
    public var loop: Bool = false
    /// Draw order: first is bottom-most.
    /// Every change re-links `audioReact` to its audio layer and `links` to their source tracks, so
    /// `MotionLayer.value` can follow them on its own.
    public var layers: [MotionLayer] { didSet { resolveLinks() } }

    public init(width: Int = 1920, height: Int = 1080, fps: Int = 30, duration: Double = 5,
                background: RGBA = RGBA(hex: "#0E0E12")!, layers: [MotionLayer] = []) {
        self.init(width: width, height: height, fps: fps, duration: duration, background: background, layers: layers,
                  resolving: true)
    }

    /// `resolving: false` keeps the layers' audio and property links as they are: for a group's sub-scene, whose
    /// children were already linked by the whole scene (the music and the link sources are outside the group, so
    /// resolving again would cut every link).
    init(width: Int, height: Int, fps: Int, duration: Double, background: RGBA, layers: [MotionLayer], resolving: Bool) {
        self.width = width; self.height = height; self.fps = fps
        self.duration = duration; self.background = background; self.layers = layers
        lights = []
        bones = []
        if resolving { resolveLinks() }
    }

    /// The audio layer an `audioReact` follows when it names no source: the music, else the first audio layer.
    public var defaultReactSource: MotionLayer? {
        let audio = audioLayers
        return audio.first { $0.role == .music } ?? audio.first
    }

    /// Points every `audioReact` at its source audio layer's file and timing (nil when the source is missing), and
    /// every property link at a copy of its source track.
    mutating func resolveLinks() {
        let all = allLayers
        guard all.contains(where: {
            !$0.audioReact.isEmpty || !$0.links.isEmpty || ($0.type == .generator && $0.generator.usesAudio)
        }) else { return }
        // Resolved on a copy and assigned once: writing `layers` here re-enters this through `didSet`, and nesting
        // once per reaction overflowed the 512 KB stacks of background threads (project thumbnails).
        var resolved = layers
        var changed = false
        Self.resolve(&resolved, audio: audioLayers, fallback: defaultReactSource, duration: duration, offset: 0,
                     lookup: { id in Self.find(id, in: all) }, changed: &changed)
        if changed { layers = resolved }
    }

    /// `offset`: how far the layers' clock runs behind scene time (the starts of the `localTime` groups they sit in),
    /// so their audio links map their own time to the right moment of the sound.
    private static func resolve(_ resolved: inout [MotionLayer], audio: [MotionLayer], fallback: MotionLayer?,
                                duration: Double, offset: Double, lookup: (String) -> MotionLayer?, changed: inout Bool) {
        for i in resolved.indices where resolved[i].type == .group {
            let inner = offset + (resolved[i].localTime ? resolved[i].start : 0)
            resolve(&resolved[i].children, audio: audio, fallback: fallback, duration: duration, offset: inner,
                    lookup: lookup, changed: &changed)
        }
        for i in resolved.indices where !resolved[i].links.isEmpty {
            for key in Array(resolved[i].links.keys) {
                guard let link = resolved[i].links[key] else { continue }
                var track: LinkedTrack?
                if link.layer != resolved[i].id, let src = lookup(link.layer), let p = AnimProperty(rawValue: link.property) {
                    track = LinkedTrack(value: src[p], loop: src.loop[p.rawValue], wiggle: src.wiggle[p.rawValue],
                                        react: src.audioReact[p.rawValue], salt: Noise.hash("\(src.id).\(p.rawValue)"))
                }
                if resolved[i].links[key]?.track != track { resolved[i].links[key]?.track = track; changed = true }
            }
        }
        for i in resolved.indices where !resolved[i].audioReact.isEmpty {
            for key in Array(resolved[i].audioReact.keys) {
                guard let react = resolved[i].audioReact[key] else { continue }
                let src = react.source.map { id in audio.first { $0.id == id } } ?? fallback
                let link = src.flatMap { s in
                    s.path.map { AudioLink(path: $0, start: s.start - offset, trimIn: s.trimIn,
                                       end: s.effectiveEnd(sceneDuration: duration) - offset) }
                }
                if react.link != link { resolved[i].audioReact[key]?.link = link; changed = true }
            }
        }
        for i in resolved.indices where resolved[i].type == .generator && resolved[i].generator.usesAudio {
            let g = resolved[i].generator
            let src = g.source.map { id in audio.first { $0.id == id } } ?? fallback
            let link = src.flatMap { s in
                s.path.map { AudioLink(path: $0, start: s.start - offset, trimIn: s.trimIn,
                                       end: s.effectiveEnd(sceneDuration: duration) - offset) }
            }
            if g.link != link { resolved[i].generator.link = link; changed = true }
        }
    }

    enum CodingKeys: String, CodingKey { case width, height, fps, duration, background, camera, lights, layers, bones, loop }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? height
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? fps
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? duration
        background = try c.decodeIfPresent(RGBA.self, forKey: .background) ?? background
        layers = try c.decodeIfPresent([MotionLayer].self, forKey: .layers) ?? []
        camera = try c.decodeIfPresent(Camera.self, forKey: .camera)?.resolved(in: self)
        lights = try c.decodeIfPresent([Light].self, forKey: .lights) ?? []
        bones = try c.decodeIfPresent([Bone].self, forKey: .bones) ?? []
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
        try validate()
        normalizeIds()
        resolveLinks()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(fps, forKey: .fps)
        try c.encode(duration, forKey: .duration)
        try c.encode(background, forKey: .background)
        try c.encodeIfPresent(camera, forKey: .camera)
        if !lights.isEmpty { try c.encode(lights, forKey: .lights) }
        if !bones.isEmpty { try c.encode(bones, forKey: .bones) }
        if loop { try c.encode(loop, forKey: .loop) }
        try c.encode(layers, forKey: .layers)
    }

    public func validate() throws {
        guard (16...7680).contains(width), (16...7680).contains(height) else {
            throw SceneError.invalid("width/height must be between 16 and 7680")
        }
        guard (1...120).contains(fps) else { throw SceneError.invalid("fps must be between 1 and 120") }
        guard duration > 0, duration <= 600 else { throw SceneError.invalid("duration must be in (0, 600] seconds") }
    }

    /// Gives every layer (groups' children included) a unique, non-empty id.
    public mutating func normalizeIds() {
        var seen = Set<String>()
        Self.normalizeIds(&layers, seen: &seen)
    }

    static func normalizeIds(_ list: inout [MotionLayer], seen: inout Set<String>) {
        for i in list.indices {
            var id = list[i].id.trimmingCharacters(in: .whitespaces)
            if id.isEmpty { id = list[i].type.rawValue }
            if seen.contains(id) {
                var n = 2
                while seen.contains("\(id)-\(n)") { n += 1 }
                id = "\(id)-\(n)"
            }
            seen.insert(id)
            list[i].id = id
            if list[i].type == .group { normalizeIds(&list[i].children, seen: &seen) }
        }
    }

    /// Every layer in draw order, groups' children after their group.
    public var allLayers: [MotionLayer] {
        layers.flatMap { l in [l] + (l.type == .group ? MotionScene(layers: l.children).allLayers : []) }
    }

    /// A layer anywhere in the tree.
    public func findLayer(_ id: String) -> MotionLayer? {
        Self.find(id, in: layers)
    }

    static func find(_ id: String, in list: [MotionLayer]) -> MotionLayer? {
        for l in list {
            if l.id == id { return l }
            if l.type == .group, let c = find(id, in: l.children) { return c }
        }
        return nil
    }

    /// Edits a layer anywhere in the tree.
    public mutating func withLayer(_ id: String, _ body: (inout MotionLayer) throws -> Void) throws {
        guard try Self.edit(id, in: &layers, body) else { throw SceneError.layerNotFound(id) }
    }

    static func edit(_ id: String, in list: inout [MotionLayer], _ body: (inout MotionLayer) throws -> Void) throws -> Bool {
        for i in list.indices {
            if list[i].id == id { try body(&list[i]); return true }
            if list[i].type == .group, try edit(id, in: &list[i].children, body) { return true }
        }
        return false
    }

    public var frameCount: Int { max(1, Int((duration * Double(fps)).rounded())) }
}

public enum SceneError: LocalizedError, Equatable {
    case invalid(String)
    case layerNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .invalid(m): return m
        case let .layerNotFound(id): return "Layer '\(id)' not found"
        }
    }
}

public enum SceneJSON {
    public static func encode<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        return try e.encode(value)
    }

    /// Atomic write via a sibling temp file + rename(2). Avoids Foundation's `.atomic`, which may stage
    /// files in a system temp directory that sandboxed processes cannot write to.
    public static func write(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        try data.write(to: tmp)
        guard rename(tmp.path, url.path) == 0 else {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmp)
            throw SceneError.invalid("Cannot write \(url.path): \(err)")
        }
    }

    public static func string<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        (try? encode(value, pretty: pretty)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let DecodingError.dataCorrupted(ctx) {
            throw SceneError.invalid("\(pathString(ctx.codingPath)): \(ctx.debugDescription)")
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw SceneError.invalid("\(pathString(ctx.codingPath + [key])): missing required field")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw SceneError.invalid("\(pathString(ctx.codingPath)): \(ctx.debugDescription)")
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw SceneError.invalid("\(pathString(ctx.codingPath)): \(ctx.debugDescription)")
        }
    }

    /// Decodes from a JSON object produced by JSONSerialization.
    public static func decode<T: Decodable>(_ type: T.Type, fromObject obj: Any) throws -> T {
        guard JSONSerialization.isValidJSONObject(obj) else { throw SceneError.invalid("Expected a JSON object") }
        return try decode(type, from: JSONSerialization.data(withJSONObject: obj))
    }

    public static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encode(value, pretty: false))
    }

    static func pathString(_ path: [CodingKey]) -> String {
        let s = path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return s.isEmpty ? "scene" : "scene" + s
    }
}
