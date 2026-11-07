import CoreGraphics
import Foundation

// The scene camera (2D: pan, zoom, rotate, with parallax by layer depth), property links between layers, and
// group layers' sub-scenes.

// MARK: - Camera

/// Pans, zooms and turns everything drawn. `x`/`y` is the scene point shown at the frame's center.
public struct Camera: Codable, Equatable, Sendable {
    public var x: AnimValue
    public var y: AnimValue
    /// 1 = as is, 2 = twice as close.
    public var zoom: AnimValue
    /// Degrees, clockwise.
    public var rotation: AnimValue
    /// Handheld shake: smooth noise on x, y, zoom or rotation.
    public var wiggle: [String: Wiggle]

    public init(x: Double, y: Double, zoom: Double = 1, rotation: Double = 0) {
        self.x = .constant(x); self.y = .constant(y); self.zoom = .constant(zoom); self.rotation = .constant(rotation)
        wiggle = [:]
    }

    enum CodingKeys: String, CodingKey { case x, y, zoom, rotation, wiggle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A missing x/y means the scene center: filled in by `resolved(in:)`.
        x = try c.decodeIfPresent(AnimValue.self, forKey: .x) ?? .constant(.nan)
        y = try c.decodeIfPresent(AnimValue.self, forKey: .y) ?? .constant(.nan)
        zoom = try c.decodeIfPresent(AnimValue.self, forKey: .zoom) ?? .constant(1)
        rotation = try c.decodeIfPresent(AnimValue.self, forKey: .rotation) ?? .constant(0)
        wiggle = try c.decodeIfPresent([String: Wiggle].self, forKey: .wiggle) ?? [:]
        for k in wiggle.keys where !["x", "y", "zoom", "rotation"].contains(k) {
            throw DecodingError.dataCorruptedError(forKey: .wiggle, in: c,
                debugDescription: "Unknown camera property '\(k)' in wiggle. Use x, y, zoom or rotation.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        if zoom != .constant(1) { try c.encode(zoom, forKey: .zoom) }
        if rotation != .constant(0) { try c.encode(rotation, forKey: .rotation) }
        if !wiggle.isEmpty { try c.encode(wiggle, forKey: .wiggle) }
    }

    /// The camera with missing x/y set to the scene center.
    func resolved(in scene: MotionScene) -> Camera {
        var cam = self
        if case let .constant(v) = cam.x, v.isNaN { cam.x = .constant(Double(scene.width) / 2) }
        if case let .constant(v) = cam.y, v.isNaN { cam.y = .constant(Double(scene.height) / 2) }
        return cam
    }

    func value(_ key: String, _ track: AnimValue, at t: Double) -> Double {
        var v = track.value(at: t)
        if let w = wiggle[key], w.amount != 0 { v += w.offset(at: t, salt: Noise.hash("camera.\(key)")) }
        return v
    }

    /// Scene pixels → framed scene pixels for a layer at `depth` (0 = as drawn; the camera's movement is divided
    /// by 1 + depth, so far layers drift slowly and close ones rush past).
    func transform(depth: Double, sceneWidth w: Int, sceneHeight h: Int, at t: Double) -> CGAffineTransform {
        let f = 1 / (1 + max(depth, -0.9))
        let cx = Double(w) / 2, cy = Double(h) / 2
        let px = cx + (value("x", x, at: t) - cx) * f, py = cy + (value("y", y, at: t) - cy) * f
        let z = max(0.01, 1 + (value("zoom", zoom, at: t) - 1) * f)
        let r = value("rotation", rotation, at: t) * .pi / 180
        return CGAffineTransform(translationX: -px, y: -py)
            .concatenating(CGAffineTransform(scaleX: z, y: z))
            .concatenating(CGAffineTransform(rotationAngle: r))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
    }

    public mutating func shiftKeys(by d: Double) {
        x = x.shifted(by: d); y = y.shifted(by: d); zoom = zoom.shifted(by: d); rotation = rotation.shifted(by: d)
    }
}

extension MotionScene {
    /// The camera's effect on a layer (identity without a camera or for `fixed` layers).
    public func cameraTransform(for layer: MotionLayer, at t: Double) -> CGAffineTransform {
        guard let camera, !layer.fixed else { return .identity }
        return camera.resolved(in: self).transform(depth: layer.depth, sceneWidth: width, sceneHeight: height, at: t)
    }

    /// The scene a group's children are drawn in: the group's box, no camera, same timing.
    func subscene(of group: MotionLayer, at t: Double) -> MotionScene {
        let w = group.width.map { Int($0.value(at: t).rounded()) } ?? width
        let h = group.height.map { Int($0.value(at: t).rounded()) } ?? height
        var s = MotionScene(width: max(w, 1), height: max(h, 1), fps: fps, duration: duration, background: .clear,
                            layers: group.children)
        s.camera = nil
        return s
    }
}

// MARK: - Property links

/// A copy of the source property's track, so a linked layer can evaluate it without the scene (like `AudioLink`).
public struct LinkedTrack: Equatable, Hashable, Sendable {
    var value: AnimValue
    var loop: LoopMode?
    var wiggle: Wiggle?
    var react: AudioReact?
    var salt: UInt64

    func value(at t: Double) -> Double {
        var v = value.value(at: t, loop: loop)
        if let wiggle, wiggle.amount != 0 { v += wiggle.offset(at: t, salt: salt) }
        if let react { v += react.offset(at: t) }
        return v
    }
}

/// Drives a property from another layer's property: value = source × multiply + add, read `delay` seconds ago.
/// The layer's own keyframes for that property are ignored while linked (its wiggle/audioReact still add).
public struct PropertyLink: Codable, Equatable, Hashable, Sendable {
    public var layer: String
    public var property: String
    public var multiply: Double
    public var add: Double
    public var delay: Double
    /// The source as resolved by the scene (not saved).
    public var track: LinkedTrack?

    public init(layer: String, property: String, multiply: Double = 1, add: Double = 0, delay: Double = 0) {
        self.layer = layer; self.property = property; self.multiply = multiply; self.add = add; self.delay = delay
    }

    enum CodingKeys: String, CodingKey { case layer, property, multiply, add, delay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let property = try c.decodeIfPresent(String.self, forKey: .property) ?? ""
        guard AnimProperty(rawValue: property) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .property, in: c,
                debugDescription: "Unknown property '\(property)'. Use one of \(AnimProperty.allCases.map(\.rawValue)).")
        }
        self.init(layer: try c.decode(String.self, forKey: .layer), property: property,
                  multiply: try c.decodeIfPresent(Double.self, forKey: .multiply) ?? 1,
                  add: try c.decodeIfPresent(Double.self, forKey: .add) ?? 0,
                  delay: try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(layer, forKey: .layer)
        try c.encode(property, forKey: .property)
        if multiply != 1 { try c.encode(multiply, forKey: .multiply) }
        if add != 0 { try c.encode(add, forKey: .add) }
        if delay != 0 { try c.encode(delay, forKey: .delay) }
    }
}

// MARK: - Groups

extension MotionScene {
    /// Moves top-level layers (in their draw order) into a new group layer placed where the topmost of them was.
    /// Their positions are kept: the group is centered on the scene, so children keep scene coordinates.
    @discardableResult
    public mutating func groupLayers(_ ids: [String], id: String? = nil, name: String? = nil) throws -> String {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { throw SceneError.invalid("Give the ids of the layers to group") }
        for i in ids { _ = try layerIndex(i) }
        let members = layers.filter { wanted.contains($0.id) }
        guard let top = layers.lastIndex(where: { wanted.contains($0.id) }) else { throw SceneError.invalid("Nothing to group") }
        var group = MotionLayer(id: id ?? "group", name: name ?? "Group", type: .group,
                                x: Double(width) / 2, y: Double(height) / 2)
        group.children = members
        group.start = members.map(\.start).min() ?? 0
        let ends = members.map { $0.effectiveEnd(sceneDuration: duration) }
        group.end = ends.allSatisfy { $0 >= duration } ? nil : ends.max()
        // A member that followed a layer outside the group loses that parent (it would be out of reach).
        for i in group.children.indices where group.children[i].parent.map({ !wanted.contains($0) }) ?? false {
            group.children[i].parent = nil
        }
        let gid = uniqueId(base: group.id)
        group.id = gid
        var kept = layers.filter { !wanted.contains($0.id) }
        let insertAt = top - members.count + 1
        kept.insert(group, at: min(max(insertAt, 0), kept.count))
        for j in kept.indices where kept[j].parent.map({ wanted.contains($0) }) ?? false { kept[j].parent = nil }
        layers = kept
        return gid
    }

    /// Puts a group's children back at the group's place (dropping the group's own transform and effects).
    public mutating func ungroup(_ id: String) throws {
        let i = try layerIndex(id)
        guard layers[i].type == .group else { throw SceneError.invalid("'\(id)' is not a group") }
        let children = layers[i].children
        layers.remove(at: i)
        var insertAt = i
        for var c in children {
            c.id = uniqueId(base: c.id)
            layers.insert(c, at: insertAt)
            insertAt += 1
        }
    }
}
