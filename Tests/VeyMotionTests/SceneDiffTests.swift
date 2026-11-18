import Foundation
import Testing
@testable import VeyMotionCore

/// Which frames an edit can change (`SceneDiff.swift`), for the RAM preview to keep the rest.
struct SceneDiffTests {
    /// A background all along, a card from 1 to 2 s and a title from 3 s to the end (4 s).
    private func timeline() -> MotionScene {
        var card = MotionLayer.rect("card", x: 200, y: 180, w: 120, h: 80, fill: "#3366FF")
        card.start = 1; card.end = 2
        var title = MotionLayer.text("title", "Hi", x: 420, y: 180)
        title.start = 3
        return MotionScene.test(layers: [.rect("bg", x: 320, y: 180, w: 640, h: 360, fill: "#101020"), card, title])
    }

    @Test func anEditChangesOnlyTheLayersTime() throws {
        let old = timeline()
        var scene = old
        try scene.updateLayer("card", patch: ["x": 260])
        let change = scene.change(since: old)
        #expect(change.contains(1.5))
        #expect(!change.contains(0.5))
        #expect(!change.contains(2.5))
        #expect(!change.contains(3.5))
        // Frames outside the change render as before.
        let r = FrameRenderer()
        for t in [0.0, 0.5, 2.5, 3.5] where !change.contains(t) {
            let a = try #require(Pixels(r.makeImage(old, at: t, scale: 0.5)))
            let b = try #require(Pixels(r.makeImage(scene, at: t, scale: 0.5)))
            #expect(a.meanDifference(to: b) == 0)
        }
    }

    @Test func movingALayerInTimeChangesBothPlaces() throws {
        let old = timeline()
        var scene = old
        try scene.updateLayer("card", patch: ["start": 3, "end": 3.5])
        let change = scene.change(since: old)
        #expect(change.contains(1.5) && change.contains(3.2))
        #expect(!change.contains(0.5) && !change.contains(3.8))
    }

    @Test func sceneSettingsChangeEveryFrame() {
        let old = timeline()
        var scene = old
        scene.background = RGBA(hex: "#FFFFFF")!
        #expect(scene.change(since: old) == .all)
        scene = old
        scene.camera = Camera(x: 320, y: 180, zoom: 1.1)
        #expect(scene.change(since: old) == .all)
        #expect(old.change(since: old) == .none)
    }

    @Test func followersAreRedrawnToo() throws {
        var old = timeline()
        // The title hangs on the card (which ends before the title starts, but still moves it).
        old.layers[2].parent = "card"
        var scene = old
        try scene.updateLayer("card", patch: ["x": 260])
        let change = scene.change(since: old)
        #expect(change.contains(1.5) && change.contains(3.5))
        #expect(!change.contains(0.5) && !change.contains(2.5))
    }

    @Test func aNewMatteHidesItsSource() throws {
        let old = timeline()
        var scene = old
        // The background becomes the card's matte: it is no longer drawn at any time.
        try scene.updateLayer("card", patch: ["matte": "bg"])
        #expect(scene.change(since: old).contains(0.5))
    }

    @Test func audioLayersDrawNothing() {
        let old = timeline()
        var scene = old
        var music = MotionLayer(id: "music", name: "music", type: .audio)
        music.path = "/nowhere/song.wav"
        scene.layers.append(music)
        #expect(scene.change(since: old) == .none)
    }

    @Test func reorderingRedrawsTheLayersThatSwapped() {
        let old = timeline()
        var scene = old
        scene.layers.swapAt(1, 2)
        let change = scene.change(since: old)
        #expect(change.contains(1.5) && change.contains(3.5))
        #expect(!change.contains(0.5) && !change.contains(2.5))
    }

    @Test func repeaterCopiesLagPastTheEnd() throws {
        let old = timeline()
        var scene = old
        try scene.updateLayer("card", patch: ["repeater": ["count": 3, "delay": 0.5]])
        let change = scene.change(since: old)
        #expect(change.contains(2.9))
        #expect(!change.contains(3.5))
    }
}
