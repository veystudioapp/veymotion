import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Splits an image into irregular shards for a "shatter" effect: each shard becomes its own image layer that can
/// fly apart. Shards are cut from a jittered grid (interior points nudged at random, corners shared between
/// neighbors so they still tile the whole picture with no gaps), deterministic from `seed` like Particles.
public enum ImageShatter {
    public struct Shard: Sendable {
        /// PNG of just this shard (transparent outside its polygon), cropped to its bounding box.
        public var png: Data
        /// Bounding box in source image pixels (origin top-left, y down).
        public var rect: CGRect
        /// Polygon centroid in source image pixels (origin top-left, y down).
        public var centroid: CGPoint
    }

    /// `count` is a target: the actual number of shards is rows × cols, chosen close to it from the image's aspect.
    public static func shards(of image: CGImage, count: Int, seed: Int) throws -> [Shard] {
        let w = Double(image.width), h = Double(image.height)
        guard w >= 2, h >= 2 else { throw SceneError.invalid("Image is too small to shatter") }
        let target = Double(max(count, 1))
        let cols = max(1, Int((target * w / h).squareRoot().rounded()))
        let rows = max(1, Int((target * h / w).squareRoot().rounded()))
        let cellW = w / Double(cols), cellH = h / Double(rows)
        let salt = Noise.mix(Noise.hash("shatter") ^ UInt64(bitPattern: Int64(seed)))

        // (rows+1) x (cols+1) grid; only interior points are jittered, so adjoining cells still share an edge.
        var points = [[CGPoint]](repeating: [CGPoint](repeating: .zero, count: cols + 1), count: rows + 1)
        for r in 0...rows {
            for c in 0...cols {
                var x = Double(c) * cellW, y = Double(r) * cellH
                if r > 0, r < rows, c > 0, c < cols {
                    let key = Noise.mix(salt ^ UInt64(bitPattern: Int64(r * (cols + 1) + c)))
                    x += (Noise.unit(0, key) - 0.5) * cellW * 0.7
                    y += (Noise.unit(1, key) - 0.5) * cellH * 0.7
                }
                points[r][c] = CGPoint(x: x, y: y)
            }
        }

        var out: [Shard] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let quad = [points[r][c], points[r][c + 1], points[r + 1][c + 1], points[r + 1][c]]
                let minX = quad.map(\.x).min()!, maxX = quad.map(\.x).max()!
                let minY = quad.map(\.y).min()!, maxY = quad.map(\.y).max()!
                let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                guard bounds.width > 0.5, bounds.height > 0.5, let shard = render(image, quad: quad, bounds: bounds) else { continue }
                out.append(shard)
            }
        }
        return out
    }

    /// Clips `image` to `quad` (in the same top-left, y-down pixel space as `bounds`) and renders just `bounds`.
    private static func render(_ image: CGImage, quad: [CGPoint], bounds: CGRect) -> Shard? {
        let w = max(1, Int(bounds.width.rounded(.up))), h = max(1, Int(bounds.height.rounded(.up)))
        guard let cropped = image.cropping(to: bounds) else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: FrameRenderer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGContext is bottom-left/y-up; flip the quad into that space to clip, then draw the already-cropped
        // image straight into the full canvas (no further transform needed for a plain CGImage draw).
        let local = quad.map { CGPoint(x: $0.x - bounds.minX, y: bounds.maxY - $0.y) }
        let path = CGMutablePath()
        path.addLines(between: local)
        path.closeSubpath()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
        guard let cg = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let centroid = CGPoint(x: quad.map(\.x).reduce(0, +) / 4, y: quad.map(\.y).reduce(0, +) / 4)
        return Shard(png: data as Data, rect: bounds, centroid: centroid)
    }
}
