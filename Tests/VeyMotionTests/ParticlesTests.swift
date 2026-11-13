import Foundation
import Testing
@testable import VeyMotionCore

@Suite struct ParticlesTests {
    @Test(arguments: ParticlePreset.allCases)
    func everyPresetEmitsAndIsDeterministic(_ preset: ParticlePreset) {
        var layer = MotionLayer.makeParticles(preset, sceneWidth: 1920, sceneHeight: 1080)
        if preset == .explosion { layer.particles.bursts = [ParticleBurst(t: 0.2, count: 100)] }
        let scene = MotionScene.test(width: 1920, height: 1080, layers: [layer])
        let t = preset == .explosion ? 0.5 : 2.0
        let a = scene.particles(of: layer, at: t), b = scene.particles(of: layer, at: t)
        #expect(!a.isEmpty, "\(preset) emits nothing at \(t)s")
        #expect(a.count <= MotionScene.maxParticles)
        #expect(a.count == b.count)
        for (p, q) in zip(a, b) {
            #expect(p.x == q.x && p.y == q.y && p.rotation == q.rotation && p.size == q.size)
        }
        for p in a {
            #expect(p.size > 0 && p.color.a > 0)
            #expect(p.variant >= 0 && p.variant < 1)
            #expect(p.scaleY >= -1 && p.scaleY <= 1)
        }
    }

    @Test func confettiFallsAcrossTheFrame() {
        let layer = MotionLayer.makeParticles(.confetti, sceneWidth: 1920, sceneHeight: 1080)
        let scene = MotionScene.test(width: 1920, height: 1080, duration: 8, layers: [layer])
        let ps = scene.particles(of: layer, at: 5)
        let lowest = ps.map(\.y).max() ?? 0
        #expect(lowest > 900, "confetti should reach the bottom of a 1080p frame within 5 s (got \(lowest))")
        #expect(layer.particles.shape == .confetti)
    }

    @Test func seedChangesTheArrangement() {
        var layer = MotionLayer.makeParticles(.snow, sceneWidth: 1920, sceneHeight: 1080)
        let scene = MotionScene.test(width: 1920, height: 1080, layers: [layer])
        let a = scene.particles(of: layer, at: 2)
        layer.particles.seed = 7
        let b = scene.particles(of: layer, at: 2)
        #expect(a.first.map { p in b.contains { $0.x == p.x && $0.y == p.y } } == false)
    }
}
