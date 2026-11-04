import Foundation

public enum LayerType: String, Codable, CaseIterable, Sendable {
    case rect, ellipse, text, image, audio

    public var isVisual: Bool { self != .audio }
}

/// What an audio layer is, used for ducking (music dips under voice) and display.
public enum AudioRole: String, Codable, CaseIterable, Sendable {
    case voice, music, sfx
}

/// A spoken word in a voice layer; `t` is seconds from the start of the audio file.
public struct WordTiming: Codable, Equatable, Hashable, Sendable {
    public var t: Double
    public var text: String
    public init(t: Double, text: String) { self.t = t; self.text = text }
}

public enum TextAlign: String, Codable, CaseIterable, Sendable {
    case left, center, right
}

public enum AnimProperty: String, Codable, CaseIterable, Sendable {
    case x, y, scale, scaleX, scaleY, rotation, skewX, skewY, anchorX, anchorY, opacity
    case width, height, cornerRadius, strokeWidth, trim
    case reveal, letterSpacing
    case blur, shadowX, shadowY, shadowBlur, shadowOpacity
    case pathProgress
    case volume

    /// Value a layer has when the property is not set.
    public var defaultValue: Double {
        switch self {
        case .scale, .scaleX, .scaleY, .opacity, .reveal, .trim, .volume: return 1
        case .x: return 960
        case .y: return 540
        case .width: return 400
        case .height: return 240
        case .shadowY: return 8
        case .shadowBlur: return 16
        default: return 0
        }
    }

    /// Properties kept in `MotionLayer.extra` (written to JSON only when set).
    static let extras: [AnimProperty] = [.scaleX, .scaleY, .skewX, .skewY, .anchorX, .anchorY, .trim, .letterSpacing,
                                         .blur, .shadowX, .shadowY, .shadowBlur, .shadowOpacity, .pathProgress]

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
        case .trim: return "Trim"
        case .reveal: return "Reveal"
        case .letterSpacing: return "Letter Spacing"
        case .blur: return "Blur"
        case .shadowX: return "Shadow X"
        case .shadowY: return "Shadow Y"
        case .shadowBlur: return "Shadow Blur"
        case .shadowOpacity: return "Shadow Opacity"
        case .pathProgress: return "Path Progress"
        case .volume: return "Volume"
        }
    }

    /// Shown with two decimals rather than as whole pixels/degrees.
    public var isFractional: Bool {
        switch self {
        case .scale, .scaleX, .scaleY, .opacity, .trim, .reveal, .shadowOpacity, .pathProgress, .volume: return true
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
    /// Per-track behavior after the last keyframe, keyed by property name ("rotation", "fill"…).
    public var loop: [String: LoopMode]
    /// Procedural noise added to numeric properties, keyed by property name.
    public var wiggle: [String: Wiggle]
    public var shadowColor: RGBA

    // Shape (rect/ellipse) and image size. Image defaults to its natural size.
    public var width: AnimValue?
    public var height: AnimValue?
    public var cornerRadius: AnimValue
    public var fill: ColorValue
    public var stroke: ColorValue?
    public var strokeWidth: AnimValue

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

    // Image / audio file
    public var path: String?

    // Audio
    /// Gain (1 = original level), animatable.
    public var volume: AnimValue
    public var role: AudioRole
    /// Seconds skipped at the beginning of the file.
    public var trimIn: Double
    public var fadeIn: Double
    public var fadeOut: Double
    /// Music only: gain while a voice layer is speaking (e.g. 0.25). nil = no ducking.
    public var duckTo: Double?
    /// Length of the audio file in seconds (filled in when the layer is added).
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
        loop = [:]
        wiggle = [:]
        shadowColor = RGBA(r: 0, g: 0, b: 0, a: 0.6)
        width = nil
        height = nil
        cornerRadius = .constant(0)
        fill = .constant(.white)
        stroke = nil
        strokeWidth = .constant(0)
        text = type == .text ? "Text" : ""
        fontSize = 72
        fontWeight = "bold"
        fontName = nil
        color = .constant(.white)
        align = .center
        maxWidth = nil
        textAnimators = []
        path = nil
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
            case .width: return width ?? .constant(type == .image ? 0 : p.defaultValue)
            case .height: return height ?? .constant(type == .image ? 0 : p.defaultValue)
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
            case .width: width = (type == .image && newValue == .constant(0)) ? nil : newValue
            case .height: height = (type == .image && newValue == .constant(0)) ? nil : newValue
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

    /// Value of a property at time t, including loops and wiggle.
    public func value(_ p: AnimProperty, at t: Double) -> Double {
        var v = self[p].value(at: t, loop: loop[p.rawValue])
        if let w = wiggle[p.rawValue], w.amount != 0 {
            v += w.offset(at: t, salt: Noise.hash("\(id).\(p.rawValue)"))
        }
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
        var list: [AnimProperty] = [.x, .y, .scale, .scaleX, .scaleY, .rotation, .skewX, .skewY, .anchorX, .anchorY, .opacity]
        switch type {
        case .rect: list += [.width, .height, .cornerRadius, .strokeWidth, .trim]
        case .ellipse: list += [.width, .height, .strokeWidth, .trim]
        case .text: list += [.reveal, .letterSpacing]
        case .image: list += [.width, .height]
        case .audio: break
        }
        list += [.blur, .shadowX, .shadowY, .shadowBlur, .shadowOpacity]
        if motionPath != nil { list.append(.pathProgress) }
        return list
    }

    public var applicableColors: [ColorProperty] {
        switch type {
        case .rect, .ellipse: return [.fill, .stroke]
        case .text: return [.color]
        default: return []
        }
    }

    /// Playable length of an audio layer's file after trimming.
    public var audioLength: Double? { sourceDuration.map { max(0, $0 - trimIn) } }

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
        case let .number(p): self[p] = self[p].movingKey(at: t, to: newT, tolerance: tolerance)
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
        case let .number(p): self[p] = self[p].deletingKey(at: t, tolerance: tolerance)
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
    }

    /// Earliest keyframe or text-animator time, if any.
    public var earliestKeyTime: Double? {
        (Array(keyframeTimes.prefix(1)) + textAnimators.map(\.start)).min()
    }

    /// Visual layers default to the scene end; audio layers to the end of their (trimmed) file.
    public func effectiveEnd(sceneDuration: Double) -> Double {
        if let end { return end }
        if type == .audio, let len = audioLength { return start + len }
        return sceneDuration
    }

    public func isVisible(at t: Double, sceneDuration: Double) -> Bool {
        t >= start && t < effectiveEnd(sceneDuration: sceneDuration) + 1e-9
    }

    public func shapeWidth(at t: Double) -> Double { value(.width, at: t) }
    public func shapeHeight(at t: Double) -> Double { value(.height, at: t) }

    enum CodingKeys: String, CodingKey {
        case id, name, type, start, end, x, y, scale, rotation, opacity, reveal
        case scaleX, scaleY, skewX, skewY, anchorX, anchorY, trim, letterSpacing
        case blur, shadowX, shadowY, shadowBlur, shadowOpacity, shadowColor, pathProgress
        case parent, motionPath, loop, wiggle, textAnimators
        case width, height, cornerRadius, fill, stroke, strokeWidth
        case text, fontSize, fontWeight, fontName, color, align, maxWidth
        case path
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
        loop = try c.decodeIfPresent([String: LoopMode].self, forKey: .loop) ?? [:]
        for k in loop.keys where KeyTrack(name: k) == nil {
            throw DecodingError.dataCorruptedError(forKey: .loop, in: c,
                debugDescription: "Unknown property '\(k)' in loop. Use one of \(KeyTrack.allNames).")
        }
        wiggle = try c.decodeIfPresent([String: Wiggle].self, forKey: .wiggle) ?? [:]
        for k in wiggle.keys where AnimProperty(rawValue: k) == nil {
            throw DecodingError.dataCorruptedError(forKey: .wiggle, in: c,
                debugDescription: "Unknown property '\(k)' in wiggle. Use one of \(AnimProperty.allCases.map(\.rawValue)).")
        }
        shadowColor = try c.decodeIfPresent(RGBA.self, forKey: .shadowColor) ?? shadowColor
        width = try c.decodeIfPresent(AnimValue.self, forKey: .width)
        height = try c.decodeIfPresent(AnimValue.self, forKey: .height)
        cornerRadius = try c.decodeIfPresent(AnimValue.self, forKey: .cornerRadius) ?? cornerRadius
        fill = try c.decodeIfPresent(ColorValue.self, forKey: .fill) ?? fill
        stroke = try c.decodeIfPresent(ColorValue.self, forKey: .stroke)
        strokeWidth = try c.decodeIfPresent(AnimValue.self, forKey: .strokeWidth) ?? .constant(stroke == nil ? 0 : 4)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? text
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        fontWeight = try c.decodeIfPresent(String.self, forKey: .fontWeight) ?? fontWeight
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        color = try c.decodeIfPresent(ColorValue.self, forKey: .color) ?? color
        align = try c.decodeIfPresent(TextAlign.self, forKey: .align) ?? align
        maxWidth = try c.decodeIfPresent(Double.self, forKey: .maxWidth)
        textAnimators = try c.decodeIfPresent([TextAnimator].self, forKey: .textAnimators) ?? []
        path = try c.decodeIfPresent(String.self, forKey: .path)
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
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encodeIfPresent(motionPath, forKey: .motionPath)
        if !loop.isEmpty { try c.encode(loop, forKey: .loop) }
        if !wiggle.isEmpty { try c.encode(wiggle, forKey: .wiggle) }
        switch type {
        case .audio:
            break
        case .rect, .ellipse:
            try c.encode(self[.width], forKey: .width)
            try c.encode(self[.height], forKey: .height)
            if type == .rect { try c.encode(cornerRadius, forKey: .cornerRadius) }
            try c.encode(fill, forKey: .fill)
            try c.encodeIfPresent(stroke, forKey: .stroke)
            if stroke != nil { try c.encode(strokeWidth, forKey: .strokeWidth) }
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
        case .image:
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(width, forKey: .width)
            try c.encodeIfPresent(height, forKey: .height)
        }
    }
}

public struct MotionScene: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var duration: Double
    public var background: RGBA
    /// Draw order: first is bottom-most.
    public var layers: [MotionLayer]

    public init(width: Int = 1920, height: Int = 1080, fps: Int = 30, duration: Double = 5,
                background: RGBA = RGBA(hex: "#0E0E12")!, layers: [MotionLayer] = []) {
        self.width = width; self.height = height; self.fps = fps
        self.duration = duration; self.background = background; self.layers = layers
    }

    enum CodingKeys: String, CodingKey { case width, height, fps, duration, background, layers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? width
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? height
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? fps
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? duration
        background = try c.decodeIfPresent(RGBA.self, forKey: .background) ?? background
        layers = try c.decodeIfPresent([MotionLayer].self, forKey: .layers) ?? []
        try validate()
        normalizeIds()
    }

    public func validate() throws {
        guard (16...7680).contains(width), (16...7680).contains(height) else {
            throw SceneError.invalid("width/height must be between 16 and 7680")
        }
        guard (1...120).contains(fps) else { throw SceneError.invalid("fps must be between 1 and 120") }
        guard duration > 0, duration <= 600 else { throw SceneError.invalid("duration must be in (0, 600] seconds") }
    }

    /// Gives every layer a unique, non-empty id.
    public mutating func normalizeIds() {
        var seen = Set<String>()
        for i in layers.indices {
            var id = layers[i].id.trimmingCharacters(in: .whitespaces)
            if id.isEmpty { id = layers[i].type.rawValue }
            if seen.contains(id) {
                var n = 2
                while seen.contains("\(id)-\(n)") { n += 1 }
                id = "\(id)-\(n)"
            }
            seen.insert(id)
            layers[i].id = id
        }
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
