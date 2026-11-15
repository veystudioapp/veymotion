import CoreGraphics
import Foundation
import Testing
@testable import VeyMotionCore

/// Picking and dragging layers on the canvas (`CanvasEdit.swift`).
struct CanvasEditTests {
    /// A full-frame background, a card, and a title on the card.
    private func stack() -> MotionScene {
        MotionScene.test(layers: [
            .rect("bg", x: 320, y: 180, w: 640, h: 360, fill: "#101020"),
            .rect("card", x: 320, y: 180, w: 300, h: 160, fill: "#FFFFFF"),
            .text("title", "Hello", x: 320, y: 180, size: 40),
        ])
    }

    @Test func clickPicksTheSmallestThingUnderIt() {
        let scene = stack(), r = FrameRenderer()
        #expect(r.layerHit(in: scene, at: CGPoint(x: 320, y: 180), time: 1) == "title")
        #expect(r.layerHit(in: scene, at: CGPoint(x: 200, y: 120), time: 1) == "card")
        // The background covers the frame: a click on it selects nothing.
        #expect(r.layerHit(in: scene, at: CGPoint(x: 20, y: 20), time: 1) == nil)
    }

    @Test func clickPassesThroughWhatIsNotShown() {
        var scene = stack(), r = FrameRenderer()
        scene.layers[2].opacity = .constant(0)
        #expect(r.layerHit(in: scene, at: CGPoint(x: 320, y: 180), time: 1) == "card")
        scene.layers[1].start = 2
        #expect(r.layerHit(in: scene, at: CGPoint(x: 320, y: 180), time: 1) == nil)
        #expect(r.selectionOutline(of: "card", in: scene, at: 1) == nil)
        #expect(r.selectionOutline(of: "card", in: scene, at: 3) != nil)
    }

    @Test func clickOnAGroupChildPicksTheGroup() {
        var group = MotionLayer(id: "badge", name: "badge", type: .group, x: 500, y: 100)
        group.width = .constant(200); group.height = .constant(100)
        group.children = [.rect("badge-box", x: 100, y: 50, w: 80, h: 40, fill: "#FF0000")]
        let scene = MotionScene.test(layers: [group]), r = FrameRenderer()
        // The child sits at the middle of the group's box, which is centered on the group's position.
        #expect(r.layerHit(in: scene, at: CGPoint(x: 500, y: 100), time: 0) == "badge")
        #expect(r.layerHit(in: scene, at: CGPoint(x: 430, y: 100), time: 0) == nil)
        let outline = r.selectionOutline(of: "badge", in: scene, at: 0)?.boundingBoxOfPath
        #expect(outline.map { abs($0.width - 80) < 1 && abs($0.midX - 500) < 1 } == true)
    }

    @Test func rotatedLayersArePickedByTheirOwnBox() {
        var bar = MotionLayer.rect("bar", x: 320, y: 180, w: 200, h: 20, fill: "#FFFFFF")
        bar.rotation = .constant(90)
        let scene = MotionScene.test(layers: [bar]), r = FrameRenderer()
        #expect(r.layerHit(in: scene, at: CGPoint(x: 320, y: 260), time: 0) == "bar")
        #expect(r.layerHit(in: scene, at: CGPoint(x: 400, y: 180), time: 0) == nil)
    }

    @Test func moveShiftsTheWholeMotion() throws {
        var dot = MotionLayer.rect("dot", x: 100, y: 100, w: 10, h: 10, fill: "#FFFFFF")
        dot.x = .keyframes([MotionKeyframe(t: 0, v: 100), MotionKeyframe(t: 1, v: 300)])
        var scene = MotionScene.test(layers: [dot])
        try scene.moveLayer("dot", byFrame: CGVector(dx: 25, dy: -10), at: 0.5)
        let moved = try scene.layer("dot")
        #expect(moved.x.keyframeList.map(\.v) == [125, 325])
        #expect(moved.y == .constant(90))
    }

    @Test func moveFollowsTheCursorUnderParentsAndTheCamera() throws {
        var parent = MotionLayer.rect("parent", x: 200, y: 200, w: 10, h: 10, fill: "#FFFFFF")
        parent.scale = .constant(2); parent.rotation = .constant(90)
        var child = MotionLayer.rect("child", x: 30, y: 0, w: 10, h: 10, fill: "#FFFFFF")
        child.parent = "parent"
        var scene = MotionScene.test(layers: [parent, child])
        scene.camera = Camera(x: 320, y: 180, zoom: 2)
        let before = try #require(scene.frameOrigin(of: try scene.layer("child"), at: 0))
        try scene.moveLayer("child", byFrame: CGVector(dx: 40, dy: 12), at: 0)
        let after = try #require(scene.frameOrigin(of: try scene.layer("child"), at: 0))
        #expect(abs(after.x - before.x - 40) < 0.05 && abs(after.y - before.y - 12) < 0.05)
    }

    @Test func moveFollowsTheCursorIn3D() throws {
        var card = MotionLayer.rect("card", x: 320, y: 180, w: 100, h: 60, fill: "#FFFFFF")
        card.threeD = true
        card[.z] = .constant(400)
        var scene = MotionScene.test(layers: [card])
        let before = try #require(scene.frameOrigin(of: try scene.layer("card"), at: 0))
        try scene.moveLayer("card", byFrame: CGVector(dx: 60, dy: 30), at: 0)
        let after = try #require(scene.frameOrigin(of: try scene.layer("card"), at: 0))
        #expect(abs(after.x - before.x - 60) < 0.5 && abs(after.y - before.y - 30) < 0.5)
    }

    @Test func moveShiftsAMotionPathAndRefusesLinkedPositions() throws {
        var rider = MotionLayer.rect("rider", x: 0, y: 0, w: 10, h: 10, fill: "#FFFFFF")
        rider.motionPath = MotionPath(points: [PathPoint(x: 100, y: 100), PathPoint(x: 300, y: 100)], smooth: false)
        var follower = MotionLayer.rect("follower", x: 50, y: 50, w: 10, h: 10, fill: "#FFFFFF")
        follower.links["x"] = PropertyLink(layer: "rider", property: "x")
        var scene = MotionScene.test(layers: [rider, follower])
        try scene.moveLayer("rider", byFrame: CGVector(dx: 10, dy: 20), at: 0)
        #expect(try scene.layer("rider").motionPath?.points == [PathPoint(x: 110, y: 120), PathPoint(x: 310, y: 120)])
        #expect(throws: SceneError.self) { try scene.moveLayer("follower", byFrame: CGVector(dx: 10, dy: 0), at: 0) }
    }
}
