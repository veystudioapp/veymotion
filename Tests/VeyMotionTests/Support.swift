import CoreGraphics
import Foundation
import Testing
@testable import VeyMotionCore

/// Pixels of a rendered frame, for tests that look at the picture.
struct Pixels {
    let width: Int, height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage?) {
        guard let image else { return nil }
        width = image.width; height = image.height
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard ok else { return nil }
        bytes = px
    }

    /// RGBA at scene-like coordinates (x right, y down), 0…255. (A bitmap context's first row is its top.)
    subscript(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
    }

    /// Mean absolute difference per channel against another frame of the same size.
    func meanDifference(to other: Pixels) -> Double {
        precondition(width == other.width && height == other.height)
        var sum = 0
        for i in 0..<bytes.count { sum += abs(Int(bytes[i]) - Int(other.bytes[i])) }
        return Double(sum) / Double(bytes.count)
    }
}

extension MotionScene {
    /// A frame-sized scene with a flat background and the given layers.
    static func test(width: Int = 640, height: Int = 360, duration: Double = 4, background: String = "#202020",
                     layers: [MotionLayer] = []) -> MotionScene {
        MotionScene(width: width, height: height, fps: 30, duration: duration, background: RGBA(hex: background)!, layers: layers)
    }
}

extension MotionLayer {
    static func rect(_ id: String, x: Double, y: Double, w: Double, h: Double, fill: String) -> MotionLayer {
        var l = MotionLayer(id: id, name: id, type: .rect, x: x, y: y)
        l.width = .constant(w); l.height = .constant(h); l.fill = .constant(RGBA(hex: fill)!)
        return l
    }

    static func text(_ id: String, _ string: String, x: Double, y: Double, size: Double = 48) -> MotionLayer {
        var l = MotionLayer(id: id, name: id, type: .text, x: x, y: y)
        l.text = string; l.fontSize = size
        return l
    }
}
