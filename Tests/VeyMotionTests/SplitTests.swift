import Foundation
import Testing
@testable import VeyMotionCore

@Suite struct SplitTests {
    @Test func splitKeepsKeyframesOnBothHalves() throws {
        var a = MotionLayer.rect("box", x: 0, y: 0, w: 10, h: 10, fill: "#FFFFFF")
        a.opacity = .keyframes([MotionKeyframe(t: 0, v: 0), MotionKeyframe(t: 2, v: 1)])
        var scene = MotionScene.test(duration: 4, layers: [a])
        let copy = try scene.splitLayer("box", at: 1)
        #expect(copy == "box-2")
        #expect(scene.layers.map(\.id) == ["box", "box-2"])
        let first = try scene.layer("box"), second = try scene.layer(copy)
        #expect(first.start == 0 && first.end == 1)
        #expect(second.start == 1 && second.end == nil)
        // The fade runs on across the cut.
        #expect(abs(second.value(.opacity, at: 1.5) - a.value(.opacity, at: 1.5)) < 1e-9)
        #expect(throws: SceneError.self) { try scene.splitLayer("box", at: 0) }
        #expect(throws: SceneError.self) { try scene.splitLayer("box", at: 3.99) }
    }

    @Test func splitAudioContinuesInTheFile() throws {
        var music = MotionLayer(id: "music", name: "Music", type: .audio)
        music.path = "/tmp/music.wav"
        music.start = 1
        music.trimIn = 2
        music.sourceDuration = 10
        music.fadeIn = 0.5
        music.fadeOut = 1
        var scene = MotionScene.test(duration: 20, layers: [music])
        let end = music.effectiveEnd(sceneDuration: 20)
        let copy = try scene.splitLayer("music", at: 4)
        let first = try scene.layer("music"), second = try scene.layer(copy)
        #expect(first.end == 4 && first.fadeIn == 0.5 && first.fadeOut == 0)
        #expect(second.start == 4 && second.trimIn == 5 && second.fadeIn == 0 && second.fadeOut == 1)
        #expect(abs(second.effectiveEnd(sceneDuration: 20) - end) < 1e-9)
    }

    @Test func hiddenLayersAreNotDrawnOrHeardAndRoundTrip() throws {
        var music = MotionLayer(id: "music", name: "Music", type: .audio)
        music.path = "/tmp/music.wav"
        var scene = MotionScene.test(layers: [.rect("box", x: 0, y: 0, w: 10, h: 10, fill: "#FFFFFF"), music])
        try scene.setHidden(["box", "music"], true)
        #expect(try !scene.layer("box").isVisible(at: 0, sceneDuration: scene.duration))
        #expect(scene.soundLayers.isEmpty)
        let data = try JSONEncoder().encode(scene)
        #expect(try JSONDecoder().decode(MotionScene.self, from: data).layers.allSatisfy(\.hidden))
        try scene.setHidden(["box"], false)
        #expect(!String(decoding: try JSONEncoder().encode(scene.layers[0]), as: UTF8.self).contains("hidden"))
    }
}
