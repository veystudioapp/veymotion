import CoreGraphics
import Foundation
import Testing
@testable import VeyMotionCore

@Suite struct TransitionTests {
    /// The incoming layer's wipe must show exactly what the outgoing one hides, at every moment, or the background
    /// shows through mid-transition.
    @Test(arguments: [TransitionType.wipe, .iris, .blinds, .blocks, .clock, .dissolve])
    func wipeTransitionsAreComplementary(_ type: TransitionType) throws {
        let full = { (id: String) in MotionLayer.rect(id, x: 960, y: 540, w: 1920, h: 1080, fill: "#FFFFFF") }
        var scene = MotionScene.test(width: 1920, height: 1080, duration: 4, layers: [full("a"), full("b")])
        try scene.transition(type, out: "a", in: "b", at: 1, duration: 1, direction: nil)
        var out = try scene.layer("a"), inn = try scene.layer("b")
        // Feather softens the edge on both sides equally; the complement is about the hard regions.
        out.wipeStyle?.feather = 0; inn.wipeStyle?.feather = 0
        let box = CGRect(x: -960, y: -540, width: 1920, height: 1080)
        for t in [1.15, 1.5, 1.85] {
            let pOut = out.value(.wipe, at: t), pIn = inn.value(.wipe, at: t)
            #expect(abs(pOut + pIn - 1) < 1e-9, "wipes should mirror each other at \(t)")
            let rOut = out.wipeStyle!.visibleRegion(progress: pOut, box: box)
            let rIn = inn.wipeStyle!.visibleRegion(progress: pIn, box: box)
            var both = 0, neither = 0, total = 0
            var y = -520.3
            while y < 540 {
                var x = -940.7
                while x < 960 {
                    let p = CGPoint(x: x, y: y)
                    let a = rOut?.contains(p, using: .evenOdd) ?? false
                    let b = rIn?.contains(p, using: .evenOdd) ?? false
                    if a && b { both += 1 }
                    if !a && !b { neither += 1 }
                    total += 1
                    x += 61.7
                }
                y += 47.3
            }
            // Edges of blocks and stripes can land on a sample: allow a sliver, never a region.
            #expect(Double(neither) / Double(total) < 0.02, "\(type) at \(t): \(neither)/\(total) points show the background")
            #expect(Double(both) / Double(total) < 0.02, "\(type) at \(t): \(both)/\(total) points drawn twice")
        }
    }

    @Test func whipNeverLeavesTheFrameEmpty() throws {
        let full = { (id: String) in MotionLayer.rect(id, x: 960, y: 540, w: 1920, h: 1080, fill: "#FFFFFF") }
        var scene = MotionScene.test(width: 1920, height: 1080, duration: 4, layers: [full("a"), full("b")])
        try scene.transition(.whip, out: "a", in: "b", at: 1, duration: 0.8, direction: "left")
        let a = try scene.layer("a"), b = try scene.layer("b")
        for t in stride(from: 1.0, through: 1.8, by: 0.05) {
            // Right edge of the outgoing layer and left edge of the incoming one: the incoming must have arrived
            // before the outgoing is gone.
            let aRight = a.x.value(at: t) + 960, bLeft = b.x.value(at: t) - 960
            #expect(bLeft <= aRight + 1, "gap between the layers at \(t)")
        }
        #expect(a.end == 1.8)
    }

    @Test func blocksReverseIsTheComplement() {
        var normal = WipeStyle(type: .blocks, count: 10)
        var reversed = normal
        reversed.reverse = true
        normal.feather = 0; reversed.feather = 0
        let box = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let a = normal.visibleRegion(progress: 0.4, box: box)
        let b = reversed.visibleRegion(progress: 0.6, box: box)
        for (x, y) in [(50.5, 50.5), (350.5, 150.5), (650.5, 250.5), (950.5, 450.5), (150.5, 350.5)] {
            let p = CGPoint(x: x, y: y)
            let inA = a?.contains(p, using: .evenOdd) ?? false, inB = b?.contains(p, using: .evenOdd) ?? false
            #expect(inA != inB, "block at \(p) is in both or neither")
        }
    }
}
