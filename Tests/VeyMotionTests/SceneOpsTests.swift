import Foundation
import Testing
@testable import VeyMotionCore

@Suite struct SceneOpsTests {
    @Test func layerIdsStayUnique() throws {
        var scene = MotionScene.test(layers: [.rect("box", x: 0, y: 0, w: 10, h: 10, fill: "#FFFFFF")])
        let second = scene.addLayer(.rect("box", x: 0, y: 0, w: 10, h: 10, fill: "#FFFFFF"))
        #expect(second == "box-2")
        let copy = try scene.duplicateLayer("box")
        #expect(copy != "box" && copy != "box-2")
        #expect(Set(scene.layers.map(\.id)).count == scene.layers.count)
    }

    @Test func duplicateLayerOffsetsCopies() throws {
        var scene = MotionScene.test(layers: [.rect("dot", x: 100, y: 100, w: 10, h: 10, fill: "#FFFFFF")])
        let ids = try scene.duplicateLayer("dot", count: 3, dx: 20, dy: 0, dt: 0.5)
        #expect(ids.count == 3)
        let last = try scene.layer(ids[2])
        #expect(last.x.value(at: 0) == 160)
        #expect(last.start == 1.5)
    }

    @Test func shiftTimeMovesLaterLayersAndKeyframes() throws {
        var a = MotionLayer.rect("a", x: 0, y: 0, w: 10, h: 10, fill: "#FFFFFF")
        a.start = 0; a.end = 3
        a.opacity = .keyframes([MotionKeyframe(t: 0.5, v: 0), MotionKeyframe(t: 2.5, v: 1)])
        var b = MotionLayer.rect("b", x: 0, y: 0, w: 10, h: 10, fill: "#FFFFFF")
        b.start = 2
        var scene = MotionScene.test(duration: 4, layers: [a, b])
        _ = try scene.shiftTime(from: 1, by: 1)
        #expect(scene.duration == 5)
        #expect(try scene.layer("b").start == 3)
        let shifted = try scene.layer("a")
        #expect(shifted.start == 0)
        if case let .keyframes(keys) = shifted.opacity {
            #expect(keys.map(\.t) == [0.5, 3.5])
        } else {
            Issue.record("opacity lost its keyframes")
        }
    }

    @Test func presetsKeyTheRestingValue() throws {
        var title = MotionLayer.text("title", "Hello", x: 320, y: 180)
        title.scale = .constant(1.5)
        var scene = MotionScene.test(layers: [title])
        try scene.applyPreset(.popIn, to: "title", start: 0.5, duration: 1)
        let l = try scene.layer("title")
        #expect(abs(l.scale.value(at: 0.5)) < 0.01)
        #expect(abs(l.scale.value(at: 2) - 1.5) < 1e-9)
        #expect(abs(l.opacity.value(at: 2) - 1) < 1e-9)
    }

    @Test func keyframesInterpolateAndHoldOutside() {
        let v = Animated<Double>.keyframes([MotionKeyframe(t: 1, v: 0, easing: .linear), MotionKeyframe(t: 3, v: 10, easing: .linear)])
        #expect(v.value(at: 0) == 0)
        #expect(abs(v.value(at: 2) - 5) < 1e-9)
        #expect(v.value(at: 9) == 10)
    }

    @Test func mergePatchFollowsRFC7386() {
        let target: [String: Any] = ["a": 1, "nested": ["x": 1, "y": 2], "gone": true,
                                     "x": ["keyframes": [["t": 0, "v": 0], ["t": 1, "v": 10]]]]
        let patch: [String: Any] = ["nested": ["y": 3], "gone": NSNull(), "x": ["keyframes": [["t": 0, "v": 5]]]]
        let out = JSONMerge.merge(target, patch) as? [String: Any]
        #expect(out?["a"] as? Int == 1)
        #expect((out?["nested"] as? [String: Any])?["x"] as? Int == 1)
        #expect((out?["nested"] as? [String: Any])?["y"] as? Int == 3)
        #expect(out?["gone"] == nil)
        // Anything with keyframes replaces the old value wholesale.
        #expect(((out?["x"] as? [String: Any])?["keyframes"] as? [Any])?.count == 1)
    }

    @Test func groupChildrenAreReachable() throws {
        var group = MotionLayer(id: "g", name: "g", type: .group, x: 320, y: 180)
        group.children = [.text("inner", "Hi", x: 0, y: 0)]
        var scene = MotionScene.test(layers: [group])
        try scene.applyPreset(.fadeIn, to: "inner", start: 0, duration: 1)
        let inner = try #require(scene.findLayer("inner"))
        #expect(inner.opacity.value(at: 0) == 0)
        #expect(scene.allLayers.map(\.id).contains("inner"))
    }
}
