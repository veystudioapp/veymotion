import CoreGraphics
import Foundation
import Testing
@testable import VeyMotionCore

@Suite struct RenderTests {
    @Test func rendersTheSampleScene() throws {
        let image = FrameRenderer().makeImage(MotionScene.sample, at: 1, scale: 0.25)
        let px = try #require(Pixels(image))
        #expect(px.width == MotionScene.sample.width / 4)
        #expect(px.height == MotionScene.sample.height / 4)
    }

    @Test func shapesLandWhereTheyAreSaid() throws {
        let scene = MotionScene.test(layers: [.rect("r", x: 100, y: 100, w: 60, h: 40, fill: "#FF0000")])
        let px = try #require(Pixels(FrameRenderer().makeImage(scene, at: 0)))
        let inside = px[100, 100], outside = px[200, 200]
        #expect(inside.r > 240 && inside.g < 20)
        #expect(outside.r < 60 && outside.g < 60)
    }

    /// A flare's streak reaches past the layer's box: it must fade out, not be cut at the box edge.
    @Test func flareStreakIsNotCutAtTheLayerBox() throws {
        var flare = MotionLayer(id: "f", name: "f", type: .generator, x: 200, y: 180)
        flare.width = .constant(200); flare.height = .constant(200)
        flare.generator.kind = .flare
        flare.generator.scale = 60 // streak: 240 px each way, past the box edge at x = 300
        flare.opacity = .constant(0.8) // drawn through a transparency layer bounded by the content bounds
        let px = try #require(Pixels(FrameRenderer().makeImage(MotionScene.test(background: "#000000", layers: [flare]), at: 0)))
        #expect(px[310, 180].r > 5, "no streak past the box: \(px[310, 180])")
        #expect(abs(px[296, 180].r - px[304, 180].r) <= 6, "edge at the box: \(px[296, 180]) vs \(px[304, 180])")
    }

    /// Opacity on a blurred layer is multiplied into the pixels before compositing: it must still mean opacity.
    @Test func opacityOnBlurredLayersIsLinear() throws {
        var solid = MotionLayer.rect("r", x: 320, y: 180, w: 300, h: 200, fill: "#FFFFFF")
        solid[.blur] = .constant(40)
        var faded = solid
        faded.opacity = .constant(0.5)
        let renderer = FrameRenderer()
        let a = try #require(Pixels(renderer.makeImage(MotionScene.test(background: "#000000", layers: [solid]), at: 0)))
        let b = try #require(Pixels(renderer.makeImage(MotionScene.test(background: "#000000", layers: [faded]), at: 0)))
        let full = a[320, 180].r, half = b[320, 180].r
        #expect(full > 240)
        #expect(abs(half - full / 2) <= 6, "half opacity gave \(half) against \(full)")
    }

    /// A wide blur is rendered at a fraction of the resolution: the picture must stay the same as the full one.
    @Test func downsampledBlurMatchesFullResolution() throws {
        var blob = MotionLayer.rect("b", x: 320, y: 180, w: 240, h: 160, fill: "#4FD1FF")
        blob[.blur] = .constant(40) // sigma 20 px at 1×: downsampled 2×
        var sharp = blob
        sharp[.blur] = .constant(31) // sigma 15.5: full resolution
        let renderer = FrameRenderer()
        let a = try #require(Pixels(renderer.makeImage(MotionScene.test(background: "#000000", layers: [blob]), at: 0)))
        let b = try #require(Pixels(renderer.makeImage(MotionScene.test(background: "#000000", layers: [sharp]), at: 0)))
        // Not identical (different sigma), but the same blob: bright in the middle, dark far away, close overall.
        #expect(a[320, 180].b > 200 && b[320, 180].b > 200)
        #expect(a[20, 20].b < 10 && b[20, 20].b < 10)
        #expect(a.meanDifference(to: b) < 6)
    }

    @Test func groupsUnderACameraZoomStillComposite() throws {
        var light = MotionLayer.rect("light", x: 320, y: 180, w: 300, h: 300, fill: "#FFFFFF")
        light[.blur] = .constant(120)
        var group = MotionLayer(id: "g", name: "g", type: .group, x: 320, y: 180)
        group.width = .constant(640); group.height = .constant(360)
        group.children = [light]
        var scene = MotionScene.test(background: "#000000", layers: [group])
        scene.camera = Camera(x: 320, y: 180, zoom: 1.03)
        let px = try #require(Pixels(FrameRenderer().makeImage(scene, at: 0)))
        #expect(px[320, 180].r > 150)
        #expect(px[5, 5].r < 40)
    }

    @Test func motionBlurAveragesSamples() throws {
        var box = MotionLayer.rect("m", x: 100, y: 180, w: 80, h: 80, fill: "#FFFFFF")
        box.x = .keyframes([MotionKeyframe(t: 0, v: 100, easing: .linear), MotionKeyframe(t: 1, v: 540, easing: .linear)])
        box.motionBlur = 360
        let px = try #require(Pixels(FrameRenderer().makeImage(MotionScene.test(background: "#000000", layers: [box]), at: 0.5)))
        // At t = 0.5 the box (80 px wide) is at x 320 and travels ~15 px per frame: just past its edge the smear
        // is partial white.
        let center = px[320, 180].r, edge = px[364, 180].r, far = px[600, 180].r
        #expect(center > 200)
        #expect(edge > 20 && edge < center)
        #expect(far < 5)
    }
}
