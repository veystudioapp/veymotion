import Foundation

// Color grading beyond the color matrix: input levels + a tone curve (one 256-entry table), a gradient map, and
// 3D LUTs read from .cube files (the format DaVinci Resolve, Premiere and most LUT packs use).

/// A parsed 3D LUT: `size`³ RGB entries, red varying fastest (the .cube order).
public final class CubeLUT: @unchecked Sendable {
    public let size: Int
    let data: [Float]
    /// Input range (DOMAIN_MIN / DOMAIN_MAX), per channel.
    let lo: [Double], hi: [Double]

    init(size: Int, data: [Float], lo: [Double] = [0, 0, 0], hi: [Double] = [1, 1, 1]) {
        self.size = size; self.data = data; self.lo = lo; self.hi = hi
    }

    /// Parses a .cube file (LUT_3D_SIZE, optional DOMAIN_MIN/MAX, then size³ lines of "r g b").
    public static func parse(_ text: String) throws -> CubeLUT {
        var size = 0
        var lo: [Float] = [0, 0, 0], hi: [Float] = [1, 1, 1]
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            switch parts.first.map(String.init) {
            case "LUT_3D_SIZE": size = Int(parts.last ?? "") ?? 0
            case "DOMAIN_MIN": lo = parts.dropFirst().compactMap { Float($0) }
            case "DOMAIN_MAX": hi = parts.dropFirst().compactMap { Float($0) }
            case "TITLE", "LUT_1D_SIZE", "LUT_3D_INPUT_RANGE": continue
            default:
                let nums = parts.compactMap { Float($0) }
                if nums.count == 3 { values.append(contentsOf: nums) }
            }
        }
        guard size >= 2, size <= 256 else { throw SceneError.invalid("Not a 3D .cube LUT (missing or bad LUT_3D_SIZE)") }
        guard values.count >= size * size * size * 3 else {
            throw SceneError.invalid("The .cube LUT has \(values.count / 3) entries, expected \(size * size * size)")
        }
        let domainOK = lo.count == 3 && hi.count == 3 && zip(lo, hi).allSatisfy { $1 > $0 }
        return CubeLUT(size: size, data: Array(values.prefix(size * size * size * 3)),
                       lo: domainOK ? lo.map(Double.init) : [0, 0, 0], hi: domainOK ? hi.map(Double.init) : [1, 1, 1])
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (lut: CubeLUT?, modified: Date?)] = [:]

    /// The LUT at a path (asset name or absolute), cached until the file changes; nil if unreadable.
    public static func load(_ path: String) -> CubeLUT? {
        let url = (try? AssetStore.existing(path)) ?? URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        lock.lock()
        if let hit = cache[url.path], hit.modified == modified { lock.unlock(); return hit.lut }
        lock.unlock()
        let lut = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? parse($0) }
        lock.lock()
        cache[url.path] = (lut, modified)
        lock.unlock()
        return lut
    }

    /// Trilinear lookup of a color in 0…1.
    @inline(__always)
    func apply(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let n = size - 1
        func norm(_ v: Double, _ k: Int) -> Double { min(max((v - lo[k]) / (hi[k] - lo[k]), 0), 1) * Double(n) }
        let fr = norm(r, 0), fg = norm(g, 1), fb = norm(b, 2)
        let r0 = min(Int(fr), n - 1), g0 = min(Int(fg), n - 1), b0 = min(Int(fb), n - 1)
        let tr = fr - Double(r0), tg = fg - Double(g0), tb = fb - Double(b0)
        var out = (0.0, 0.0, 0.0)
        for db in 0...1 {
            for dg in 0...1 {
                for dr in 0...1 {
                    let w = (dr == 1 ? tr : 1 - tr) * (dg == 1 ? tg : 1 - tg) * (db == 1 ? tb : 1 - tb)
                    guard w > 0 else { continue }
                    let i = 3 * ((r0 + dr) + (g0 + dg) * size + (b0 + db) * size * size)
                    out.0 += w * Double(data[i]); out.1 += w * Double(data[i + 1]); out.2 += w * Double(data[i + 2])
                }
            }
        }
        return out
    }
}

/// The grading of one layer at one time.
struct Grading {
    /// 256-entry tone table (levels + curve) applied to R, G and B; nil = identity.
    var tone: [UInt8]?
    var gradientMap: [RGBA] = []
    var gradientAmount = 0.0
    var lut: CubeLUT?
    var lutAmount = 0.0

    init?(_ layer: MotionLayer, at t: Double) {
        let black = layer.value(.levelsBlack, at: t), white = layer.value(.levelsWhite, at: t)
        let gamma = max(0.05, layer.value(.levelsGamma, at: t))
        let levels = abs(black) > 1e-4 || abs(white - 1) > 1e-4 || abs(gamma - 1) > 1e-4
        if levels || layer.curves.count >= 2 {
            let curve = Self.curveTable(layer.curves)
            tone = (0..<256).map { i in
                var v = Double(i) / 255
                if levels { v = pow(min(max((v - black) / max(white - black, 1e-4), 0), 1), 1 / gamma) }
                if let curve { v = curve[min(255, Int((v * 255).rounded()))] }
                return UInt8((min(max(v, 0), 1) * 255).rounded())
            }
        }
        if layer.gradientMap.count >= 1 {
            gradientMap = layer.gradientMap
            gradientAmount = min(max(layer.value(.gradientMapAmount, at: t), 0), 1)
        }
        if let path = layer.lut, let cube = CubeLUT.load(path) {
            lut = cube
            lutAmount = min(max(layer.value(.lutAmount, at: t), 0), 1)
        }
        guard tone != nil || gradientAmount > 0.001 || (lut != nil && lutAmount > 0.001) else { return nil }
    }

    /// A smooth monotone curve through the points (Fritsch–Carlson), sampled at 256 steps.
    static func curveTable(_ pts: [PathPoint]) -> [Double]? {
        guard pts.count >= 2 else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let n = xs.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (ys[i + 1] - ys[i]) / max(xs[i + 1] - xs[i], 1e-6) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
        return (0..<256).map { k in
            let x = Double(k) / 255
            if x <= xs[0] { return ys[0] }
            if x >= xs[n - 1] { return ys[n - 1] }
            var i = 0
            while i < n - 2 && x > xs[i + 1] { i += 1 }
            let h = max(xs[i + 1] - xs[i], 1e-6), u = (x - xs[i]) / h
            let h00 = 2 * u * u * u - 3 * u * u + 1, h10 = u * u * u - 2 * u * u + u
            let h01 = -2 * u * u * u + 3 * u * u, h11 = u * u * u - u * u
            return h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1]
        }
    }

    func apply(_ buf: PixelBuffer) {
        let gm = gradientMap
        for y in 0..<buf.h {
            let row = buf.p + y * buf.rb
            for x in 0..<buf.w {
                let q = row + 4 * x
                let a = Double(q[3])
                guard a > 0 else { continue }
                var r = Double(q[0]) / a, g = Double(q[1]) / a, b = Double(q[2]) / a
                if let tone {
                    r = Double(tone[min(255, Int(r * 255 + 0.5))]) / 255
                    g = Double(tone[min(255, Int(g * 255 + 0.5))]) / 255
                    b = Double(tone[min(255, Int(b * 255 + 0.5))]) / 255
                }
                if gradientAmount > 0.001, !gm.isEmpty {
                    let l = min(max(0.2126 * r + 0.7152 * g + 0.0722 * b, 0), 1)
                    let c: RGBA
                    if gm.count == 1 { c = gm[0] } else {
                        let f = l * Double(gm.count - 1), i = min(Int(f), gm.count - 2)
                        c = RGBA.lerp(gm[i], gm[i + 1], f - Double(i))
                    }
                    r += (c.r - r) * gradientAmount; g += (c.g - g) * gradientAmount; b += (c.b - b) * gradientAmount
                }
                if let lut, lutAmount > 0.001 {
                    let (lr, lg, lb) = lut.apply(r, g, b)
                    r += (lr - r) * lutAmount; g += (lg - g) * lutAmount; b += (lb - b) * lutAmount
                }
                q[0] = UInt8(min(max(r, 0), 1) * a + 0.5)
                q[1] = UInt8(min(max(g, 0), 1) * a + 0.5)
                q[2] = UInt8(min(max(b, 0), 1) * a + 0.5)
            }
        }
    }
}
