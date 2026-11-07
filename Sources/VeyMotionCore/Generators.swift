import CoreGraphics
import Foundation

// Generator layers draw procedural content in their width × height box, like After Effects' Generate effects:
// an audio spectrum or waveform, fractal noise, lightning and grids. Shapes are filled with the layer's fill (or
// gradient); noise maps its values onto `colors`.

public enum GeneratorKind: String, Codable, CaseIterable, Sendable {
    /// Music visualizer: bars (or a line, or a ring) following the frequencies of an audio layer.
    case spectrum
    /// Loudness of an audio layer over the last `window` seconds (an audiogram).
    case waveform
    /// Fractal noise: smoke, clouds, textures, animated backgrounds.
    case noise
    /// Electric bolt with branches between two points, re-striking `speed` times a second.
    case lightning
    /// Lines every `scale` px, optionally scrolling (retro grids, blueprints).
    case grid

    public var title: String { rawValue.capitalized }
}

/// How spectrum and waveform values are drawn.
public enum GeneratorShape: String, Codable, CaseIterable, Sendable {
    case bars, line, circle

    public var title: String { rawValue.capitalized }
}

public struct Generator: Codable, Equatable, Hashable, Sendable {
    public var kind: GeneratorKind
    /// spectrum/waveform: audio layer id (nil = the music layer, else the first audio layer).
    public var source: String?
    /// spectrum/waveform: bars, line or circle.
    public var shape: GeneratorShape?
    /// spectrum/waveform: number of bars or points.
    public var count: Int?
    /// spectrum/waveform bars: grow both ways from the middle.
    public var mirror: Bool?
    /// spectrum/waveform: multiplies the values.
    public var gain: Double?
    /// waveform: seconds shown across the width.
    public var window: Double?
    /// noise: feature size; grid: cell size; lightning: how far the bolt strays (px).
    public var scale: Double?
    /// noise: octaves (fine detail); lightning: number of branches.
    public var detail: Int?
    /// noise: evolution per second; lightning: strikes per second; grid: scroll px per second.
    public var speed: Double?
    /// noise: colors from low to high values (default black → white).
    public var colors: [RGBA]?
    /// lightning: ends in layer px from the layer's position (default: the left and right edges).
    public var from: PathPoint?
    public var to: PathPoint?
    public var seed: Int?
    /// The audio source as resolved by the scene (not saved).
    public var link: AudioLink?

    public init(kind: GeneratorKind = .spectrum) { self.kind = kind }

    enum CodingKeys: String, CodingKey {
        case kind, source, shape, count, mirror, gain, window, scale, detail, speed, colors, from, to, seed
    }

    /// Also accepts a bare kind ("noise").
    public init(from decoder: Decoder) throws {
        if let k = try? decoder.singleValueContainer().decode(GeneratorKind.self) {
            self.init(kind: k)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decodeIfPresent(GeneratorKind.self, forKey: .kind) ?? .spectrum)
        source = try c.decodeIfPresent(String.self, forKey: .source).flatMap { $0.isEmpty ? nil : $0 }
        shape = try c.decodeIfPresent(GeneratorShape.self, forKey: .shape)
        count = try c.decodeIfPresent(Int.self, forKey: .count).map { min(max($0, 1), 512) }
        mirror = try c.decodeIfPresent(Bool.self, forKey: .mirror)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain)
        window = try c.decodeIfPresent(Double.self, forKey: .window).map { max($0, 0.1) }
        scale = try c.decodeIfPresent(Double.self, forKey: .scale).map { max($0, 1) }
        detail = try c.decodeIfPresent(Int.self, forKey: .detail).map { min(max($0, 0), 8) }
        speed = try c.decodeIfPresent(Double.self, forKey: .speed)
        colors = try c.decodeIfPresent([RGBA].self, forKey: .colors).flatMap { $0.isEmpty ? nil : $0 }
        from = try c.decodeIfPresent(PathPoint.self, forKey: .from)
        to = try c.decodeIfPresent(PathPoint.self, forKey: .to)
        seed = try c.decodeIfPresent(Int.self, forKey: .seed)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(shape, forKey: .shape)
        try c.encodeIfPresent(count, forKey: .count)
        try c.encodeIfPresent(mirror, forKey: .mirror)
        try c.encodeIfPresent(gain, forKey: .gain)
        try c.encodeIfPresent(window, forKey: .window)
        try c.encodeIfPresent(scale, forKey: .scale)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(speed, forKey: .speed)
        try c.encodeIfPresent(colors, forKey: .colors)
        try c.encodeIfPresent(from, forKey: .from)
        try c.encodeIfPresent(to, forKey: .to)
        try c.encodeIfPresent(seed, forKey: .seed)
    }

    // MARK: Values with their per-kind defaults

    public var usesAudio: Bool { kind == .spectrum || kind == .waveform }
    public var shapeValue: GeneratorShape { shape ?? .bars }
    public var countValue: Int { count ?? (kind == .waveform ? 64 : 48) }
    public var mirrorValue: Bool { mirror ?? (kind == .waveform) }
    public var gainValue: Double { gain ?? 1 }
    public var windowValue: Double { window ?? 4 }
    public var scaleValue: Double {
        scale ?? { switch kind { case .noise: return 200; case .grid: return 80; default: return 40 } }()
    }
    /// lightning: how far the bolt strays, by default 15% of its length.
    func spread(length: Double) -> Double { scale ?? 0.15 * length }
    public var detailValue: Int { detail ?? (kind == .lightning ? 2 : 4) }
    public var speedValue: Double {
        speed ?? { switch kind { case .noise: return 0.3; case .lightning: return 12; default: return 0 } }()
    }
    public var colorsValue: [RGBA] { colors ?? [RGBA(r: 0, g: 0, b: 0, a: 1), .white] }
    public var seedValue: Int { seed ?? 0 }

    // MARK: Data

    /// spectrum/waveform values (0…1, before gain) at scene time t; zeros while the audio is silent or not analyzed.
    func audioValues(at t: Double) -> [Double] {
        let n = countValue
        guard let link, let a = AudioAnalysisCache.forRendering(path: link.path) else {
            return [Double](repeating: 0, count: n)
        }
        switch kind {
        case .spectrum:
            guard let ft = link.fileTime(at: t) else { return [Double](repeating: 0, count: n) }
            return a.spectrum(at: ft, count: n)
        default:
            // The last `window` seconds of loudness, newest on the right.
            guard let env = AudioAnalysisCache.envelope(path: link.path, band: .level, release: 0.05) else {
                return [Double](repeating: 0, count: n)
            }
            let w = windowValue
            return (0..<n).map { i in
                let st = t - w + w * (Double(i) + 0.5) / Double(n)
                return link.fileTime(at: st).map { AudioAnalysis.sample(env, at: $0) } ?? 0
            }
        }
    }

    // MARK: Shapes

    /// Filled outline of what the generator draws in `box` (layer px) at time t, or nil for noise (an image).
    /// `line` = stroke width for lines (line shape, lightning, grid); `radius` = bar corner radius.
    func path(in box: CGRect, at t: Double, line: Double, radius: Double, layerId: String) -> CGPath? {
        switch kind {
        case .spectrum, .waveform:
            let v = audioValues(at: t).map { min(max($0 * gainValue, 0), 1.5) }
            return audioPath(v, in: box, line: line, radius: radius)
        case .lightning:
            return lightningPath(in: box, at: t, line: line, salt: Noise.hash(layerId))
        case .grid:
            return gridPath(in: box, at: t, line: line)
        case .noise:
            return nil
        }
    }

    private func audioPath(_ v: [Double], in box: CGRect, line: Double, radius: Double) -> CGPath {
        let path = CGMutablePath()
        let n = v.count
        guard n > 0, box.width > 0, box.height > 0 else { return path }
        switch shapeValue {
        case .bars:
            let slot = box.width / Double(n), bw = max(1, slot * 0.7)
            for (i, x) in v.enumerated() {
                let hgt = max(bw * 0.5, x * box.height)
                let cx = box.minX + slot * (Double(i) + 0.5)
                let r = CGRect(x: cx - bw / 2, y: mirrorValue ? box.midY - hgt / 2 : box.maxY - hgt, width: bw, height: hgt)
                let cr = min(radius, bw / 2, hgt / 2)
                path.addRoundedRect(in: r, cornerWidth: cr, cornerHeight: cr)
            }
        case .line:
            var pts = [CGPoint]()
            for (i, x) in v.enumerated() {
                let px = box.minX + box.width * (n == 1 ? 0.5 : Double(i) / Double(n - 1))
                let y = mirrorValue ? box.midY - x * box.height / 2 : box.maxY - x * box.height
                pts.append(CGPoint(x: px, y: y))
            }
            let curve = Self.smooth(pts, closed: false)
            if mirrorValue {
                // The same curve flipped below the middle, as one closed band.
                let lower = Self.smooth(pts.reversed().map { CGPoint(x: $0.x, y: 2 * box.midY - $0.y) }, closed: false)
                let band = CGMutablePath()
                band.addPath(curve)
                band.addPath(lower)
                return band.copy(strokingWithWidth: line, lineCap: .round, lineJoin: .round, miterLimit: 10)
            }
            return curve.copy(strokingWithWidth: line, lineCap: .round, lineJoin: .round, miterLimit: 10)
        case .circle:
            let c = CGPoint(x: box.midX, y: box.midY)
            let inner = min(box.width, box.height) / 4, reach = min(box.width, box.height) / 4
            let bw = max(1, 2 * .pi * inner / Double(n) * 0.6)
            for (i, x) in v.enumerated() {
                let a = 2 * Double.pi * Double(i) / Double(n) - .pi / 2
                let len = max(bw, x * reach)
                var m = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a + .pi / 2)
                let cr = min(radius, bw / 2)
                let r = CGRect(x: -bw / 2, y: -inner - len, width: bw, height: len)
                path.addPath(CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: &m))
            }
        }
        return path
    }

    /// Catmull-Rom curve through the points.
    static func smooth(_ pts: [CGPoint], closed: Bool) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else {
            pts.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        if closed { path.closeSubpath() }
        return path
    }

    private func lightningPath(in box: CGRect, at t: Double, line: Double, salt: UInt64) -> CGPath {
        let a = from.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: box.minX, y: box.midY)
        let b = to.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: box.maxX, y: box.midY)
        let strike = speedValue > 0 ? Int(floor(t * speedValue + 1e-6)) : 0
        let rng = Noise.mix(salt ^ UInt64(bitPattern: Int64(seedValue)) ^ (UInt64(bitPattern: Int64(strike)) &* 0x9E3779B97F4A7C15))
        var k = 0
        func rand() -> Double { k += 1; return Noise.unit(k, rng) }
        /// Midpoint displacement: each split moves the middle sideways by up to `spread`, halving each level.
        func bolt(_ p: CGPoint, _ q: CGPoint, spread: Double, levels: Int) -> [CGPoint] {
            var pts = [p, q]
            var s = spread
            for _ in 0..<levels {
                var next = [pts[0]]
                for i in 0..<(pts.count - 1) {
                    let u = pts[i], v = pts[i + 1]
                    let dx = v.x - u.x, dy = v.y - u.y, len = max(hypot(dx, dy), 1e-6)
                    let off = (rand() * 2 - 1) * s
                    next.append(CGPoint(x: (u.x + v.x) / 2 - dy / len * off, y: (u.y + v.y) / 2 + dx / len * off))
                    next.append(v)
                }
                pts = next
                s /= 2
            }
            return pts
        }
        let total = hypot(b.x - a.x, b.y - a.y)
        let spread = self.spread(length: total)
        let main = bolt(a, b, spread: spread, levels: 6)
        let out = CGMutablePath()
        func stroke(_ pts: [CGPoint], width: Double) {
            let p = CGMutablePath()
            p.addLines(between: pts)
            out.addPath(p.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
        }
        stroke(main, width: line)
        // Branches leave from random points of the bolt and fork away from it, thinner and shorter.
        for _ in 0..<detailValue {
            let i = 1 + Int(rand() * Double(main.count - 2))
            let p = main[min(i, main.count - 1)]
            let side: Double = rand() < 0.5 ? -1 : 1
            let dir: Double = Double(atan2(b.y - a.y, b.x - a.x)) + side * (0.3 + rand() * 0.6)
            let len: Double = Double(total) * (0.15 + rand() * 0.25)
            let q = CGPoint(x: p.x + cos(dir) * len, y: p.y + sin(dir) * len)
            stroke(bolt(p, q, spread: spread * 0.5, levels: 4), width: max(0.5, line * 0.45))
        }
        return out
    }

    private func gridPath(in box: CGRect, at t: Double, line: Double) -> CGPath {
        let cell = scaleValue
        let shift = (speedValue * t).truncatingRemainder(dividingBy: cell)
        let p = CGMutablePath()
        var x = box.minX + (shift < 0 ? shift + cell : shift)
        while x <= box.maxX { p.addRect(CGRect(x: x - line / 2, y: box.minY, width: line, height: box.height)); x += cell }
        var y = box.minY + (shift < 0 ? shift + cell : shift)
        while y <= box.maxY { p.addRect(CGRect(x: box.minX, y: y - line / 2, width: box.width, height: line)); y += cell }
        return p
    }

    // MARK: Noise

    /// Fractal noise over the box as an image of `pixels` samples across (smooth, so it is drawn scaled up).
    func noiseImage(width w: Int, height h: Int, box: CGRect, at t: Double, layerId: String) -> CGImage? {
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rb = ctx.bytesPerRow
        let seed = Noise.hash(layerId) ^ Noise.mix(UInt64(bitPattern: Int64(seedValue)))
        let octaves = max(1, detailValue), z = t * speedValue
        let cols = colorsValue
        // Gradient lookup table (premultiplied RGBA) over 256 levels.
        var lut = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<256 {
            let x = Double(i) / 255 * Double(max(cols.count - 1, 0))
            let j = min(Int(x), max(cols.count - 2, 0)), f = x - Double(j)
            let c = cols.count == 1 ? cols[0] : RGBA.lerp(cols[j], cols[min(j + 1, cols.count - 1)], f)
            lut[4 * i] = UInt8((c.r * c.a * 255).rounded()); lut[4 * i + 1] = UInt8((c.g * c.a * 255).rounded())
            lut[4 * i + 2] = UInt8((c.b * c.a * 255).rounded()); lut[4 * i + 3] = UInt8((c.a * 255).rounded())
        }
        let sx = box.width / Double(w), sy = box.height / Double(h), size = scaleValue
        let rot = (0..<octaves).map { o -> (Double, Double) in
            let a = 0.52 + Double(o) * 1.13
            return (cos(a), sin(a))
        }
        for y in 0..<h {
            // Row 0 is the top of the image (the box's minY in layer space, y down).
            let ly = box.minY + (Double(y) + 0.5) * sy
            for x in 0..<w {
                let lx = box.minX + (Double(x) + 0.5) * sx
                var v = 0.0, amp = 1.0, freq = 1 / size, norm = 0.0
                for o in 0..<octaves {
                    // Each octave turned another way, so the lattice of value noise does not show as squares.
                    let (ca, sa) = rot[o]
                    let px = (lx * ca - ly * sa) * freq, py = (lx * sa + ly * ca) * freq
                    v += amp * Noise.value3(px, py, z + Double(o) * 7.3, seed: seed &+ UInt64(o)).v
                    norm += amp
                    amp *= 0.5; freq *= 2
                }
                // Value noise sits near 0; spread it to use the whole color range.
                let u = min(max(0.5 + 0.9 * v / norm, 0), 1)
                let li = 4 * Int(u * 255)
                let q = y * rb + 4 * x
                data[q] = lut[li]; data[q + 1] = lut[li + 1]; data[q + 2] = lut[li + 2]; data[q + 3] = lut[li + 3]
            }
        }
        return ctx.makeImage()
    }
}
