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

    @Test func rippleGrowsBySizeAndThinsItsStroke() throws {
        var ring = MotionLayer.rect("ring", x: 320, y: 180, w: 100, h: 100, fill: "#FFFFFF")
        ring.type = .ellipse
        ring.strokeWidth = .constant(4)
        var scene = MotionScene.test(layers: [ring])
        try scene.applyPreset(.ripple, to: "ring", start: 0.5, duration: 1.4)
        let l = try scene.layer("ring")
        #expect(l.stroke?.value(at: 0).a == 1) // the fill became the outline
        #expect(l.fill.value(at: 0).a == 0)
        #expect(l.scale.keyframeList.isEmpty)
        #expect(abs(l.value(.width, at: 1.9) - 320) < 1e-9)
        #expect(l.value(.strokeWidth, at: 1.9) < 1)
        #expect(l.value(.opacity, at: 1.9) == 0)
        #expect(l.value(.glow, at: 1) > 0)
        var text = MotionScene.test(layers: [.text("t", "Hi", x: 0, y: 0)])
        #expect(throws: SceneError.self) { try text.applyPreset(.ripple, to: "t", start: 0, duration: 1) }
    }

    @Test func lintFlagsStrokesWidenedByScale() throws {
        var ring = MotionLayer.rect("ring", x: 320, y: 180, w: 100, h: 100, fill: "#00000000")
        ring.type = .ellipse
        ring.stroke = .constant(.white)
        ring.strokeWidth = .constant(4)
        ring.scale = .keyframes([MotionKeyframe(t: 0, v: 1), MotionKeyframe(t: 2, v: 3.4)])
        var scene = MotionScene.test(layers: [ring])
        #expect(scene.designIssues(pixels: false).contains { $0.code == "scaled-stroke" })
        // Grown by size instead: nothing to report.
        ring.scale = .constant(1)
        scene.layers = [ring]
        try scene.applyPreset(.ripple, to: "ring", start: 0, duration: 2)
        #expect(!scene.designIssues(pixels: false).contains { $0.code == "scaled-stroke" })
    }

    @Test func lintLeavesDeliberateEdgeTypeAlone() {
        func flagged(_ code: String, _ layers: [MotionLayer]) -> Set<String> {
            let scene = MotionScene.test(width: 1920, height: 1080, layers: layers)
            return Set(scene.designIssues(pixels: false).filter { $0.code == code }.flatMap(\.layers))
        }
        // A corner label may sit at 40 px; body text at the same place may not.
        let edge = flagged("edge", [.text("hud", "VEY—MOTION", x: 116, y: 72, size: 16),
                                    .text("body", "VEY—MOTION", x: 300, y: 72, size: 40)])
        #expect(edge == ["body"])
        // Display type a third outside the frame is a crop; a line a little too long is a slip.
        let crop = flagged("edge", [.text("big", "MOVE", x: 200, y: 540, size: 600),
                                    .text("long", "This sentence is a little too long for the frame", x: 960, y: 540, size: 80)])
        #expect(crop == ["long"])
        // A repeated-word band runs off both edges and past in a moment: a texture, not reading.
        var band = MotionLayer.text("band", String(repeating: "MOTION — ", count: 5), x: 960, y: 540, size: 150)
        band.end = 0.5
        var line = MotionLayer.text("line", "Five words gone too fast", x: 960, y: 300, size: 40)
        line.end = 0.5
        #expect(flagged("edge", [band]).isEmpty)
        #expect(flagged("reading-time", [band, line]) == ["line"])
    }

    @Test func largeStackGivesBackgroundWorkRoom() async {
        // GCD threads have 512 KB; the lint's renders overflowed that (SIGBUS) in debug builds.
        let size = await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning: LargeStack.run { pthread_get_stacksize_np(pthread_self()) }) }
        }
        #expect(size >= LargeStack.size)
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

    @Test func filePathsFollowAProjectRenameInsideGroups() throws {
        var pic = MotionLayer(id: "pic", name: "pic", type: .image, x: 0, y: 0)
        pic.path = "/p/Old/assets/images/a.png"
        pic.lut = "/p/Old/assets/luts/warm.cube"
        var group = MotionLayer(id: "g", name: "g", type: .group, x: 320, y: 180)
        group.children = [pic]
        var top = MotionLayer(id: "top", name: "top", type: .image, x: 0, y: 0)
        top.path = "/p/Old/assets/images/b.png"
        var scene = MotionScene.test(layers: [top, group])

        let stored = scene.relativizingPaths(to: URL(fileURLWithPath: "/p/Old"))
        #expect(stored.findLayer("pic")?.path == "assets/images/a.png")
        #expect(stored.findLayer("pic")?.lut == "assets/luts/warm.cube")

        var loaded = stored
        loaded.resolvePaths(relativeTo: URL(fileURLWithPath: "/p/New"))
        #expect(loaded.findLayer("pic")?.path == "/p/New/assets/images/a.png")
        #expect(loaded.findLayer("top")?.path == "/p/New/assets/images/b.png")

        #expect(Set(scene.replaceFolder("/p/Old", with: "/p/New")) == ["top", "pic"])
        #expect(scene.findLayer("pic")?.path == "/p/New/assets/images/a.png")
        #expect(scene.findLayer("pic")?.lut == "/p/New/assets/luts/warm.cube")
        #expect(scene.layers(usingPath: "/p/New/assets/images/a.png") == ["pic"])
        #expect(scene.replacePath("/p/New/assets/images/a.png", with: "/p/New/assets/images/c.png") == ["pic"])
    }
}
