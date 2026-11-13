import Foundation
import Testing
@testable import VeyMotionCore

@Suite struct SceneCodableTests {
    @Test func sampleSceneSurvivesARoundTrip() throws {
        let scene = MotionScene.sample
        let data = try SceneJSON.encode(scene)
        let back = try SceneJSON.decode(MotionScene.self, from: data)
        #expect(back.layers.map(\.id) == scene.layers.map(\.id))
        #expect(back.width == scene.width && back.height == scene.height && back.duration == scene.duration)
        // Encoding again gives the same JSON: nothing is lost on the way through.
        let first = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let second = try JSONSerialization.jsonObject(with: SceneJSON.encode(back)) as? NSDictionary
        #expect(first == second)
    }

    @Test func missingFieldsGetDefaults() throws {
        let json = #"{"width":1280,"height":720,"layers":[{"id":"t","type":"text","text":"Hi","x":10,"y":20}]}"#
        let scene = try SceneJSON.decode(MotionScene.self, from: Data(json.utf8))
        #expect(scene.fps == 30)
        #expect(scene.duration > 0)
        let t = try scene.layer("t")
        #expect(t.opacity.value(at: 0) == 1)
        #expect(t.scale.value(at: 0) == 1)
        #expect(t.fontSize > 0)
    }

    @Test func encodingWritesOnlyWhatTheLayerTypeUses() throws {
        let scene = MotionScene.test(layers: [.rect("r", x: 100, y: 100, w: 50, h: 50, fill: "#FF0000")])
        let text = String(decoding: try SceneJSON.encode(scene), as: UTF8.self)
        #expect(text.contains("\"fill\""))
        #expect(!text.contains("\"fontSize\""))
        #expect(!text.contains("\"particles\""))
    }

    @Test func unknownParticlePresetIsAnError() {
        let json = #"{"width":100,"height":100,"layers":[{"id":"p","type":"particles","x":0,"y":0,"particles":{"preset":"lava"}}]}"#
        #expect(throws: (any Error).self) { try SceneJSON.decode(MotionScene.self, from: Data(json.utf8)) }
    }

    @Test func particleSystemEncodesOnlyOverrides() throws {
        var p = ParticleSystem(preset: .confetti)
        p.rate = 120
        let data = try JSONEncoder().encode(p)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"rate\":120"))
        #expect(!text.contains("\"gravity\""))
        let back = try JSONDecoder().decode(ParticleSystem.self, from: data)
        #expect(back == p)
    }
}
