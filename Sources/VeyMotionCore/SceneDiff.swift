import Foundation

/// Which frames an edit can have changed, so a frame cache keeps the rest (`MotionScene.change(since:)`).
public enum SceneChange: Equatable, Sendable {
    /// Nothing that is drawn changed.
    case none
    /// Every frame: the size, frame rate, duration, background, camera, lights, bones or the draw order.
    case all
    /// Only frames whose time lies in one of these spans (scene seconds, ends included).
    case spans([ClosedRange<Double>])

    /// Whether the frame at `t` may look different after the edit.
    public func contains(_ t: Double) -> Bool {
        switch self {
        case .none: return false
        case .all: return true
        case let .spans(spans): return spans.contains { $0.contains(t) }
        }
    }
}

extension MotionScene {
    /// The frames that may look different from `old`. A layer is drawn only while it is visible, so an edited
    /// top-level layer (a group for any edit inside it) changes only its own time on screen, before and after the
    /// edit, widened by a frame each side (motion blur samples around the frame time) and by its repeater copies'
    /// lag. Layers that follow it by id (`parent`, `matte`, particles `from`) are redrawn over their own time too,
    /// and so is a layer that becomes or stops being a matte (a matte is not drawn on its own). Audio and property
    /// links are copied into the layers that use them (`resolveLinks`), so those layers show up as edited
    /// themselves; audio layers draw nothing. Anything outside the layers changes every frame.
    public func change(since old: MotionScene) -> SceneChange {
        if self == old { return .none }
        // The same scene with the old layers: anything else that differs changes every frame.
        var rest = self
        rest.layers = old.layers
        guard rest == old else { return .all }

        let oldById = Dictionary(old.layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newById = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var spans: [ClosedRange<Double>] = []
        // Top-level ids already redrawn, and every id (children too) other layers may follow.
        var redrawn = Set<String>()
        var moved = Set<String>()

        func redraw(_ id: String) {
            guard redrawn.insert(id).inserted else { return }
            for (layer, scene) in [(newById[id], self), (oldById[id], old)] {
                guard let layer else { continue }
                Self.collectIds(of: layer, into: &moved)
                if let span = scene.drawnSpan(of: layer) { spans.append(span) }
                // A layer that is (or was) another's matte is not drawn on its own.
                if let m = layer.matte?.source, m != layer.id, newById[m] != nil || oldById[m] != nil { redraw(m) }
            }
        }

        for layer in layers where oldById[layer.id] != layer { redraw(layer.id) }
        for layer in old.layers where newById[layer.id] == nil { redraw(layer.id) }
        // Reordered layers: each one whose place among the layers kept on both sides differs.
        let keptNew = layers.map(\.id).filter { oldById[$0] != nil }
        let keptOld = old.layers.map(\.id).filter { newById[$0] != nil }
        for (a, b) in zip(keptNew, keptOld) where a != b {
            redraw(a)
            redraw(b)
        }

        // Layers following an edited one by id, until no more are found (chains of parents).
        var grew = true
        while grew {
            grew = false
            for layer in layers where !redrawn.contains(layer.id) && Self.follows(layer, anyOf: moved) {
                redraw(layer.id)
                grew = true
            }
        }
        return spans.isEmpty ? .none : .spans(spans)
    }

    /// When `layer` (top-level) can be drawn, widened by a frame each side and by its repeater copies' lag;
    /// nil for layers that draw nothing (audio).
    func drawnSpan(of layer: MotionLayer) -> ClosedRange<Double>? {
        guard layer.type != .audio else { return nil }
        let frame = 1 / Double(max(fps, 1))
        let shutter = (layer.motionBlur + abs(layer.motionBlurPhase ?? 0)) / 360
        let margin = frame * (1 + max(0, shutter))
        var end = layer.effectiveEnd(sceneDuration: duration)
        if let rep = layer.repeater, rep.count > 1, rep.delay > 0 {
            end += Double(min(rep.count, Repeater.maxCount) - 1) * rep.delay
        }
        return (layer.start - margin)...(max(end, layer.start) + margin)
    }

    private static func collectIds(of layer: MotionLayer, into ids: inout Set<String>) {
        ids.insert(layer.id)
        for child in layer.children { collectIds(of: child, into: &ids) }
    }

    /// Whether `layer` or anything inside it looks at one of `ids` while drawing.
    private static func follows(_ layer: MotionLayer, anyOf ids: Set<String>) -> Bool {
        if let p = layer.parent, ids.contains(p) { return true }
        if let m = layer.matte?.source, ids.contains(m) { return true }
        if layer.type == .particles, let f = layer.particles.from, ids.contains(f) { return true }
        return layer.children.contains { follows($0, anyOf: ids) }
    }
}
