import CoreGraphics
import Foundation
import Testing
@testable import VeyMotionCore

@Suite struct LottieTests {
    /// A 100×100, 2 s (60 frames at 30 fps) animation: a red 40×40 square near the top moving from x 30 to x 70.
    private static let json = """
    {"v":"5.7.0","fr":30,"ip":0,"op":60,"w":100,"h":100,"nm":"test","ddd":0,"assets":[],
     "layers":[{"ddd":0,"ind":1,"ty":4,"nm":"square","ip":0,"op":60,"st":0,"sr":1,"ao":0,"bm":0,
      "ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]},
            "p":{"a":1,"k":[{"t":0,"s":[30,25,0],"i":{"x":1,"y":1},"o":{"x":0,"y":0}},{"t":60,"s":[70,25,0]}]}},
      "shapes":[{"ty":"rc","nm":"r","d":1,"p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[40,40]},"r":{"a":0,"k":0}},
                {"ty":"fl","nm":"f","c":{"a":0,"k":[1,0,0,1]},"o":{"a":0,"k":100},"r":1}]}]}
    """

    private func writeAnimation() throws -> String {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let url = tmp.appendingPathComponent("veymotion-lottie-\(UUID().uuidString).json")
        try Data(Self.json.utf8).write(to: url)
        return url.path
    }

    @Test func recognizesLottieFiles() throws {
        let path = try writeAnimation()
        #expect(LottieSource.isLottie(path))
        #expect(AssetStore.kind(of: URL(fileURLWithPath: path)) == .video)
        let info = try VideoSource.info(of: path)
        #expect(abs((info.duration ?? 0) - 2) < 1e-6)
        #expect(info.width == 100 && info.height == 100)

        let other = path.replacingOccurrences(of: ".json", with: "-other.json")
        try Data(#"{"name":"not an animation","items":[1,2,3]}"#.utf8).write(to: URL(fileURLWithPath: other))
        #expect(!LottieSource.isLottie(other))
        #expect(AssetStore.kind(of: URL(fileURLWithPath: other)) == .text)
    }

    /// Drawn upright (the square stays near the top), stretched to the layer's box, and moving with scene time.
    @Test func drawsAsAVideoLayer() throws {
        var layer = MotionLayer(id: "l", name: "l", type: .video, x: 320, y: 180)
        layer.path = try writeAnimation()
        layer.width = .constant(200) // 2× the animation: the box spans 220…420 × 80…280
        var scene = MotionScene.test(background: "#000000", layers: [layer])
        try scene.layers[0].loadVideoInfo(sceneFps: scene.fps)
        #expect(scene.layers[0].sourceDuration == 2)

        let r = FrameRenderer()
        let start = try #require(Pixels(r.makeImage(scene, at: 0)))
        #expect(start[280, 130].r > 240 && start[280, 130].g < 20, "square at its start: \(start[280, 130])")
        #expect(start[280, 230].r < 20, "upside down: \(start[280, 230])")
        #expect(start[360, 130].r < 20)

        let middle = try #require(Pixels(r.makeImage(scene, at: 1)))
        #expect(middle[320, 130].r > 240, "square halfway: \(middle[320, 130])")
        #expect(middle[262, 130].r < 20)
    }
}
