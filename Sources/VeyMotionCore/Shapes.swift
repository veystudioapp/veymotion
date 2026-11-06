import CoreGraphics
import Foundation

// Vector paths (with morphing), gradients, track mattes and repeaters.

// MARK: - Paths

/// One cubic segment; it starts where the previous one ends. Lines are stored as cubics too, so any two paths
/// can be morphed point by point.
public struct CubicSegment: Hashable, Sendable {
    public var c1: PathPoint
    public var c2: PathPoint
    public var p: PathPoint

    static func line(_ a: PathPoint, _ b: PathPoint) -> CubicSegment {
        CubicSegment(c1: PathPoint(x: a.x + (b.x - a.x) / 3, y: a.y + (b.y - a.y) / 3),
                     c2: PathPoint(x: a.x + (b.x - a.x) * 2 / 3, y: a.y + (b.y - a.y) * 2 / 3), p: b)
    }
}

public struct Subpath: Hashable, Sendable {
    public var start: PathPoint
    public var segments: [CubicSegment]
    /// Closed subpaths end with a segment back to `start`.
    public var closed: Bool
}

/// A vector shape from SVG path data ("M0 0 L100 0 …") or a shorthand such as "star(5,200,80)".
/// Keyframes between two shapes morph one into the other.
public struct PathShape: Interpolatable, CustomStringConvertible {
    /// The text it was written as (nil for an in-between shape of a morph).
    public var source: String?
    public var subpaths: [Subpath]

    public init(subpaths: [Subpath]) { source = nil; self.subpaths = subpaths }

    public init(_ text: String) throws {
        source = text
        subpaths = try PathParser.parse(text)
    }

    public static var zero: PathShape { PathShape(subpaths: []) }
    public var isEmpty: Bool { subpaths.allSatisfy { $0.segments.isEmpty } }
    public var description: String { source ?? svg }

    /// SVG path data of the shape (all segments as cubics).
    public var svg: String {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
        func pt(_ p: PathPoint) -> String { "\(n(p.x)) \(n(p.y))" }
        return subpaths.map { s in
            "M\(pt(s.start))" + s.segments.map { " C\(pt($0.c1)) \(pt($0.c2)) \(pt($0.p))" }.joined() + (s.closed ? " Z" : "")
        }.joined(separator: " ")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        do { try self.init(s) } catch {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad path: \(error.localizedDescription)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(source ?? svg)
    }

    public static func extrapolate(_ v: PathShape, first: PathShape, last: PathShape, cycles: Double) -> PathShape { v }

    public var cgPath: CGPath {
        let path = CGMutablePath()
        for s in subpaths { s.add(to: path) }
        return path
    }

    /// Each subpath as its own CGPath with its length (trim paths work per subpath, like After Effects).
    public var strokePieces: [(path: CGPath, length: Double)] {
        subpaths.filter { !$0.segments.isEmpty }.map { s in
            let p = CGMutablePath()
            s.add(to: p)
            return (p, s.length)
        }
    }

    // MARK: Morphing

    public static func lerp(_ a: PathShape, _ b: PathShape, _ p: Double) -> PathShape {
        if p == 0 || a == b { return a }
        if p == 1 { return b }
        if a.isEmpty || b.isEmpty { return p < 0.5 ? a : b }
        var sa = a.subpaths.filter { !$0.segments.isEmpty }, sb = b.subpaths.filter { !$0.segments.isEmpty }
        // Missing subpaths grow from (or shrink to) the center of their counterpart.
        while sa.count < sb.count { sa.append(sb[sa.count].collapsed) }
        while sb.count < sa.count { sb.append(sa[sb.count].collapsed) }
        var out: [Subpath] = []
        for (x, y) in zip(sa, sb) {
            var x = x, y = y
            let n = max(x.segments.count, y.segments.count)
            x.subdivide(to: n); y.subdivide(to: n)
            if x.closed && y.closed { y = y.aligned(to: x) }
            func l(_ u: PathPoint, _ v: PathPoint) -> PathPoint { PathPoint(x: u.x + (v.x - u.x) * p, y: u.y + (v.y - u.y) * p) }
            let segs = zip(x.segments, y.segments).map { CubicSegment(c1: l($0.c1, $1.c1), c2: l($0.c2, $1.c2), p: l($0.p, $1.p)) }
            out.append(Subpath(start: l(x.start, y.start), segments: segs, closed: x.closed || y.closed))
        }
        return PathShape(subpaths: out)
    }
}

extension Subpath {
    func add(to path: CGMutablePath) {
        path.move(to: CGPoint(x: start.x, y: start.y))
        for s in segments {
            path.addCurve(to: CGPoint(x: s.p.x, y: s.p.y), control1: CGPoint(x: s.c1.x, y: s.c1.y),
                          control2: CGPoint(x: s.c2.x, y: s.c2.y))
        }
        if closed { path.closeSubpath() }
    }

    var length: Double {
        var total = 0.0, from = start
        for s in segments { total += Self.length(from, s); from = s.p }
        return total
    }

    static func length(_ a: PathPoint, _ s: CubicSegment, steps: Int = 16) -> Double {
        var total = 0.0, last = a
        for i in 1...steps {
            let q = point(a, s, Double(i) / Double(steps))
            total += hypot(q.x - last.x, q.y - last.y)
            last = q
        }
        return total
    }

    static func point(_ a: PathPoint, _ s: CubicSegment, _ t: Double) -> PathPoint {
        let u = 1 - t
        let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
        return PathPoint(x: w0 * a.x + w1 * s.c1.x + w2 * s.c2.x + w3 * s.p.x,
                         y: w0 * a.y + w1 * s.c1.y + w2 * s.c2.y + w3 * s.p.y)
    }

    /// The same number of segments, all at the subpath's center (a shape morphs out of nothing).
    var collapsed: Subpath {
        let pts = [start] + segments.map(\.p)
        let c = PathPoint(x: pts.map(\.x).reduce(0, +) / Double(pts.count), y: pts.map(\.y).reduce(0, +) / Double(pts.count))
        return Subpath(start: c, segments: segments.map { _ in CubicSegment(c1: c, c2: c, p: c) }, closed: closed)
    }

    /// Splits the longest segments in half until there are n.
    mutating func subdivide(to n: Int) {
        guard !segments.isEmpty else { return }
        while segments.count < n {
            var best = 0, bestLen = -1.0, from = start
            for (i, s) in segments.enumerated() {
                let len = hypot(s.p.x - from.x, s.p.y - from.y) + hypot(s.c1.x - from.x, s.c1.y - from.y)
                if len > bestLen { best = i; bestLen = len }
                from = s.p
            }
            let a = best == 0 ? start : segments[best - 1].p
            let (l, r) = Self.split(a, segments[best])
            segments.replaceSubrange(best...best, with: [l, r])
        }
    }

    static func split(_ a: PathPoint, _ s: CubicSegment) -> (CubicSegment, CubicSegment) {
        func mid(_ u: PathPoint, _ v: PathPoint) -> PathPoint { PathPoint(x: (u.x + v.x) / 2, y: (u.y + v.y) / 2) }
        let ab = mid(a, s.c1), bc = mid(s.c1, s.c2), cd = mid(s.c2, s.p)
        let abc = mid(ab, bc), bcd = mid(bc, cd), m = mid(abc, bcd)
        return (CubicSegment(c1: ab, c2: abc, p: m), CubicSegment(c1: bcd, c2: cd, p: s.p))
    }

    /// Closed loop starting at segment k's start, optionally run the other way.
    func rotated(_ k: Int, reversed rev: Bool) -> Subpath {
        var loop = self
        if rev {
            var segs: [CubicSegment] = []
            for i in stride(from: segments.count - 1, through: 0, by: -1) {
                let from = i == 0 ? start : segments[i - 1].p
                segs.append(CubicSegment(c1: segments[i].c2, c2: segments[i].c1, p: from))
            }
            loop = Subpath(start: segments.last?.p ?? start, segments: segs, closed: true)
        }
        guard k > 0, k < loop.segments.count else { return loop }
        let s = loop.segments[k - 1].p
        return Subpath(start: s, segments: Array(loop.segments[k...] + loop.segments[..<k]), closed: true)
    }

    /// This closed loop started at the point (and run in the direction) closest to `other`, so a morph doesn't twist.
    func aligned(to other: Subpath) -> Subpath {
        let n = segments.count
        guard n > 1, n == other.segments.count else { return self }
        let target = other.segments.map(\.p)
        var best = self, bestCost = Double.infinity
        for rev in [false, true] {
            for k in 0..<n {
                let cand = rotated(k, reversed: rev)
                var cost = 0.0
                for (u, v) in zip(cand.segments, target) {
                    cost += (u.p.x - v.x) * (u.p.x - v.x) + (u.p.y - v.y) * (u.p.y - v.y)
                    if cost >= bestCost { break }
                }
                if cost < bestCost { best = cand; bestCost = cost }
            }
        }
        return best
    }
}

enum PathParser {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ text: String) throws -> [Subpath] {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = s.firstIndex(of: "("), s.hasSuffix(")"), s.first?.isLetter == true {
            let name = s[..<open].lowercased().trimmingCharacters(in: .whitespaces)
            let args = s[s.index(after: open)..<s.index(before: s.endIndex)].split(separator: ",")
                .map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard args.allSatisfy({ $0 != nil }) else { throw Failure(message: "arguments of \(name)() must be numbers") }
            return try shorthand(name, args.compactMap { $0 })
        }
        var p = Scanner(Array(s.utf8))
        return try p.run()
    }

    /// star(points, outerRadius, innerRadius[, rotation]), polygon(sides, radius[, rotation]),
    /// circle(r), ellipse(rx, ry), rect(w, h[, cornerRadius]); centered on 0,0, starting at the top, clockwise.
    static func shorthand(_ name: String, _ a: [Double]) throws -> [Subpath] {
        func need(_ n: Int, _ usage: String) throws {
            guard a.count >= n else { throw Failure(message: "use \(usage)") }
        }
        func corners(_ pts: [PathPoint]) -> [Subpath] {
            guard let first = pts.first else { return [] }
            var segs: [CubicSegment] = []
            for i in 0..<pts.count { segs.append(.line(pts[i], pts[(i + 1) % pts.count])) }
            return [Subpath(start: first, segments: segs, closed: true)]
        }
        func onCircle(_ r: Double, _ deg: Double) -> PathPoint {
            PathPoint(x: r * cos(deg * .pi / 180), y: r * sin(deg * .pi / 180))
        }
        switch name {
        case "star":
            try need(3, "star(points, outerRadius, innerRadius[, rotation])")
            let n = max(2, Int(a[0])), rot = a.count > 3 ? a[3] : 0
            return corners((0..<(2 * n)).map { i in
                onCircle(i % 2 == 0 ? a[1] : a[2], -90 + rot + Double(i) * 180 / Double(n))
            })
        case "polygon":
            try need(2, "polygon(sides, radius[, rotation])")
            let n = max(3, Int(a[0])), rot = a.count > 2 ? a[2] : 0
            return corners((0..<n).map { onCircle(a[1], -90 + rot + Double($0) * 360 / Double(n)) })
        case "circle":
            try need(1, "circle(radius)")
            return ellipse(a[0], a[0])
        case "ellipse":
            try need(2, "ellipse(rx, ry)")
            return ellipse(a[0], a[1])
        case "rect":
            try need(2, "rect(width, height[, cornerRadius])")
            let w = a[0] / 2, h = a[1] / 2, r = min(max(a.count > 2 ? a[2] : 0, 0), w, h)
            if r <= 0 {
                return corners([PathPoint(x: -w, y: -h), PathPoint(x: w, y: -h), PathPoint(x: w, y: h), PathPoint(x: -w, y: h)])
            }
            let path = CGPath(roundedRect: CGRect(x: -w, y: -h, width: 2 * w, height: 2 * h), cornerWidth: r, cornerHeight: r, transform: nil)
            return subpaths(of: path)
        default:
            throw Failure(message: "unknown shape \(name)(); use star, polygon, circle, ellipse or rect, or SVG path data")
        }
    }

    static func ellipse(_ rx: Double, _ ry: Double) -> [Subpath] {
        let k = 0.5522847498
        func p(_ x: Double, _ y: Double) -> PathPoint { PathPoint(x: x, y: y) }
        let segs = [
            CubicSegment(c1: p(k * rx, -ry), c2: p(rx, -k * ry), p: p(rx, 0)),
            CubicSegment(c1: p(rx, k * ry), c2: p(k * rx, ry), p: p(0, ry)),
            CubicSegment(c1: p(-k * rx, ry), c2: p(-rx, k * ry), p: p(-rx, 0)),
            CubicSegment(c1: p(-rx, -k * ry), c2: p(-k * rx, -ry), p: p(0, -ry)),
        ]
        return [Subpath(start: p(0, -ry), segments: segs, closed: true)]
    }

    /// Subpaths of a CGPath (lines and quads become cubics).
    static func subpaths(of path: CGPath) -> [Subpath] {
        var out: [Subpath] = []
        var cur: Subpath?
        var pos = PathPoint(x: 0, y: 0)
        func pp(_ c: CGPoint) -> PathPoint { PathPoint(x: c.x, y: c.y) }
        path.applyWithBlock { el in
            let e = el.pointee, pts = e.points
            switch e.type {
            case .moveToPoint:
                if let c = cur { out.append(c) }
                pos = pp(pts[0]); cur = Subpath(start: pos, segments: [], closed: false)
            case .addLineToPoint:
                cur?.segments.append(.line(pos, pp(pts[0]))); pos = pp(pts[0])
            case .addQuadCurveToPoint:
                let c = pp(pts[0]), e = pp(pts[1])
                cur?.segments.append(CubicSegment(c1: PathPoint(x: pos.x + 2 / 3 * (c.x - pos.x), y: pos.y + 2 / 3 * (c.y - pos.y)),
                                                  c2: PathPoint(x: e.x + 2 / 3 * (c.x - e.x), y: e.y + 2 / 3 * (c.y - e.y)), p: e))
                pos = e
            case .addCurveToPoint:
                cur?.segments.append(CubicSegment(c1: pp(pts[0]), c2: pp(pts[1]), p: pp(pts[2]))); pos = pp(pts[2])
            case .closeSubpath:
                if var c = cur {
                    if hypot(pos.x - c.start.x, pos.y - c.start.y) > 1e-9 { c.segments.append(.line(pos, c.start)) }
                    c.closed = true
                    out.append(c)
                    pos = c.start
                    cur = Subpath(start: pos, segments: [], closed: false)
                }
            @unknown default: break
            }
        }
        if let c = cur, !c.segments.isEmpty { out.append(c) }
        return out
    }

    struct Scanner {
        let b: [UInt8]
        var i = 0
        var out: [Subpath] = []
        var cur: Subpath?
        var pos = PathPoint(x: 0, y: 0)
        /// Second control point of the previous command (for S/T reflection) and whether it was a cubic/quad.
        var lastCubic: PathPoint?
        var lastQuad: PathPoint?

        init(_ b: [UInt8]) { self.b = b }

        mutating func skip() {
            while i < b.count, b[i] == 32 || b[i] == 44 || (9...13).contains(b[i]) { i += 1 }
        }

        mutating func atNumber() -> Bool {
            skip()
            guard i < b.count else { return false }
            let c = b[i]
            return (48...57).contains(c) || c == 45 || c == 43 || c == 46
        }

        mutating func num() throws -> Double {
            skip()
            let s = i
            if i < b.count, b[i] == 45 || b[i] == 43 { i += 1 }
            var dot = false
            while i < b.count, (48...57).contains(b[i]) || (b[i] == 46 && !dot) { if b[i] == 46 { dot = true }; i += 1 }
            if i < b.count, b[i] == 101 || b[i] == 69 {
                i += 1
                if i < b.count, b[i] == 45 || b[i] == 43 { i += 1 }
                while i < b.count, (48...57).contains(b[i]) { i += 1 }
            }
            guard i > s, let v = Double(String(decoding: b[s..<i], as: UTF8.self)) else {
                throw Failure(message: "expected a number at character \(s + 1)")
            }
            return v
        }

        mutating func flag() throws -> Bool {
            skip()
            guard i < b.count, b[i] == 48 || b[i] == 49 else { throw Failure(message: "expected an arc flag (0 or 1) at character \(i + 1)") }
            i += 1
            return b[i - 1] == 49
        }

        mutating func point(_ rel: Bool) throws -> PathPoint {
            let x = try num(), y = try num()
            return rel ? PathPoint(x: pos.x + x, y: pos.y + y) : PathPoint(x: x, y: y)
        }

        mutating func add(_ s: CubicSegment) {
            if cur == nil { cur = Subpath(start: pos, segments: [], closed: false) }
            cur?.segments.append(s)
            pos = s.p
        }

        mutating func finish() {
            if let c = cur, !c.segments.isEmpty || c.closed { out.append(c) }
            cur = nil
        }

        mutating func run() throws -> [Subpath] {
            var cmd: UInt8 = 0
            skip()
            while i < b.count {
                let c = b[i]
                if (65...90).contains(c) || (97...122).contains(c) {
                    cmd = c; i += 1
                } else if cmd == 0 {
                    throw Failure(message: "path data must start with a command such as M")
                }
                let rel = (97...122).contains(cmd)
                var cubicCtrl: PathPoint?, quadCtrl: PathPoint?
                switch cmd | 0x20 { // lowercase
                case 109: // m
                    finish()
                    pos = try point(rel)
                    cur = Subpath(start: pos, segments: [], closed: false)
                    cmd = rel ? 108 : 76 // further pairs are lines
                case 108: // l
                    let p = try point(rel); add(.line(pos, p))
                case 104: // h
                    let x = try num(); add(.line(pos, PathPoint(x: rel ? pos.x + x : x, y: pos.y)))
                case 118: // v
                    let y = try num(); add(.line(pos, PathPoint(x: pos.x, y: rel ? pos.y + y : y)))
                case 99: // c
                    let c1 = try point(rel), c2 = try point(rel), p = try point(rel)
                    add(CubicSegment(c1: c1, c2: c2, p: p)); cubicCtrl = c2
                case 115: // s
                    let c1 = lastCubic.map { PathPoint(x: 2 * pos.x - $0.x, y: 2 * pos.y - $0.y) } ?? pos
                    let c2 = try point(rel), p = try point(rel)
                    add(CubicSegment(c1: c1, c2: c2, p: p)); cubicCtrl = c2
                case 113: // q
                    let q = try point(rel), p = try point(rel)
                    addQuad(q, p); quadCtrl = q
                case 116: // t
                    let q = lastQuad.map { PathPoint(x: 2 * pos.x - $0.x, y: 2 * pos.y - $0.y) } ?? pos
                    let p = try point(rel)
                    addQuad(q, p); quadCtrl = q
                case 97: // a
                    let rx = try num(), ry = try num(), rot = try num()
                    let large = try flag(), sweep = try flag()
                    let p = try point(rel)
                    for s in Self.arc(from: pos, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep) { add(s) }
                    pos = p
                case 122: // z
                    if var c = cur {
                        if hypot(pos.x - c.start.x, pos.y - c.start.y) > 1e-9 { c.segments.append(.line(pos, c.start)) }
                        c.closed = true
                        pos = c.start
                        cur = c
                        finish()
                    }
                    skip()
                    lastCubic = nil; lastQuad = nil
                    if i < b.count, !((65...90).contains(b[i]) || (97...122).contains(b[i])) {
                        throw Failure(message: "unexpected character at \(i + 1)")
                    }
                    continue
                default:
                    throw Failure(message: "unknown path command '\(String(UnicodeScalar(cmd)))'")
                }
                lastCubic = cubicCtrl; lastQuad = quadCtrl
                skip()
                if i < b.count, !atNumber(), !((65...90).contains(b[i]) || (97...122).contains(b[i])) {
                    throw Failure(message: "unexpected character at \(i + 1)")
                }
            }
            finish()
            return out
        }

        mutating func addQuad(_ q: PathPoint, _ p: PathPoint) {
            add(CubicSegment(c1: PathPoint(x: pos.x + 2 / 3 * (q.x - pos.x), y: pos.y + 2 / 3 * (q.y - pos.y)),
                             c2: PathPoint(x: p.x + 2 / 3 * (q.x - p.x), y: p.y + 2 / 3 * (q.y - p.y)), p: p))
        }

        /// SVG elliptical arc as cubic segments of at most 90°.
        static func arc(from a: PathPoint, to b: PathPoint, rx: Double, ry: Double, rotation: Double,
                        large: Bool, sweep: Bool) -> [CubicSegment] {
            var rx = abs(rx), ry = abs(ry)
            if rx < 1e-9 || ry < 1e-9 || (a.x == b.x && a.y == b.y) { return [.line(a, b)] }
            let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
            let dx = (a.x - b.x) / 2, dy = (a.y - b.y) / 2
            let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
            let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
            if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
            let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
            var k = (max(0, num) / den).squareRoot()
            if large == sweep { k = -k }
            let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
            let cx = cp * cx1 - sp * cy1 + (a.x + b.x) / 2, cy = sp * cx1 + cp * cy1 + (a.y + b.y) / 2
            func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
                atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            }
            let th1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
            var dth = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
            if !sweep && dth > 0 { dth -= 2 * .pi }
            if sweep && dth < 0 { dth += 2 * .pi }
            let n = max(1, Int(ceil(abs(dth) / (.pi / 2) - 1e-9)))
            let step = dth / Double(n), t = 4 / 3 * tan(step / 4)
            func at(_ th: Double) -> (PathPoint, PathPoint) {
                let ex = rx * cos(th), ey = ry * sin(th)
                let p = PathPoint(x: cx + cp * ex - sp * ey, y: cy + sp * ex + cp * ey)
                let tx = -rx * sin(th), ty = ry * cos(th)
                return (p, PathPoint(x: cp * tx - sp * ty, y: sp * tx + cp * ty))
            }
            var segs: [CubicSegment] = []
            var th = th1
            for i in 0..<n {
                let (p0, d0) = at(th), (p1, d1) = at(th + step)
                let end = i == n - 1 ? b : p1
                segs.append(CubicSegment(c1: PathPoint(x: p0.x + t * d0.x, y: p0.y + t * d0.y),
                                         c2: PathPoint(x: p1.x - t * d1.x, y: p1.y - t * d1.y), p: end))
                th += step
            }
            return segs
        }
    }
}

public typealias PathValue = Animated<PathShape>

public enum FillRule: String, Codable, CaseIterable, Sendable { case nonzero, evenodd }
public enum LineCap: String, Codable, CaseIterable, Sendable { case butt, round, square }
public enum LineJoin: String, Codable, CaseIterable, Sendable { case miter, round, bevel }

// MARK: - Gradients

public enum GradientType: String, Codable, CaseIterable, Sendable { case linear, radial }

public struct GradientStop: Codable, Equatable, Hashable, Sendable {
    /// 0…1 along the gradient.
    public var offset: Double
    public var color: RGBA

    public init(offset: Double, color: RGBA) { self.offset = offset; self.color = color }
}

/// Fill of a shape, path or text that varies across it. Replaces the solid fill/color when set.
public struct Gradient: Codable, Equatable, Hashable, Sendable {
    public var type: GradientType
    public var stops: [GradientStop]
    /// Linear: direction in degrees (0 = left → right, 90 = top → bottom).
    public var angle: AnimValue
    /// Moves the colors along the gradient (fraction of its length; animate -1 → 1 for a shine sweep).
    public var shift: AnimValue
    /// Radial: center as a fraction of the layer box (0.5, 0.5 = middle) and radius as a fraction of half its diagonal.
    public var cx: Double
    public var cy: Double
    public var radius: AnimValue

    public init(type: GradientType = .linear, stops: [GradientStop], angle: Double = 90) {
        self.type = type; self.stops = stops; self.angle = .constant(angle); shift = .constant(0)
        cx = 0.5; cy = 0.5; radius = .constant(1)
    }

    enum CodingKeys: String, CodingKey { case type, stops, colors, angle, shift, cx, cy, radius }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(GradientType.self, forKey: .type) ?? .linear
        // Stops are {"offset","color"} objects, or plain colors spread evenly.
        let key: CodingKeys = c.contains(.stops) ? .stops : .colors
        var list = try c.nestedUnkeyedContainer(forKey: key)
        var stops: [GradientStop] = []
        var plain: [RGBA] = []
        while !list.isAtEnd {
            if let color = try? list.decode(RGBA.self) { plain.append(color) } else { stops.append(try list.decode(GradientStop.self)) }
        }
        if !plain.isEmpty {
            guard stops.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Use either colors or {offset, color} stops, not both")
            }
            stops = plain.enumerated().map { GradientStop(offset: plain.count > 1 ? Double($0.offset) / Double(plain.count - 1) : 0, color: $0.element) }
        }
        guard stops.count >= 2 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "A gradient needs at least 2 colors")
        }
        self.stops = stops.sorted { $0.offset < $1.offset }
        angle = try c.decodeIfPresent(AnimValue.self, forKey: .angle) ?? .constant(90)
        shift = try c.decodeIfPresent(AnimValue.self, forKey: .shift) ?? .constant(0)
        cx = try c.decodeIfPresent(Double.self, forKey: .cx) ?? 0.5
        cy = try c.decodeIfPresent(Double.self, forKey: .cy) ?? 0.5
        radius = try c.decodeIfPresent(AnimValue.self, forKey: .radius) ?? .constant(1)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(stops, forKey: .stops)
        if type == .linear {
            try c.encode(angle, forKey: .angle)
        } else {
            if cx != 0.5 { try c.encode(cx, forKey: .cx) }
            if cy != 0.5 { try c.encode(cy, forKey: .cy) }
            if radius != .constant(1) { try c.encode(radius, forKey: .radius) }
        }
        if shift != .constant(0) { try c.encode(shift, forKey: .shift) }
    }

    func shifted(by d: Double) -> Gradient {
        var g = self
        g.angle = angle.shifted(by: d); g.shift = shift.shifted(by: d); g.radius = radius.shifted(by: d)
        return g
    }
}

// MARK: - Track matte

public enum MatteMode: String, Codable, CaseIterable, Sendable {
    /// Visible where the matte layer is opaque.
    case alpha
    /// Visible where the matte layer is not.
    case alphaInverted
    /// Visible where the matte layer is bright.
    case luma
    case lumaInverted

    public var title: String {
        switch self {
        case .alpha: return "Alpha"
        case .alphaInverted: return "Alpha Inverted"
        case .luma: return "Luma"
        case .lumaInverted: return "Luma Inverted"
        }
    }
}

/// Shows a layer only through another layer (the matte), which is then not drawn on its own.
public struct Matte: Codable, Equatable, Hashable, Sendable {
    public var source: String
    public var mode: MatteMode

    public init(source: String, mode: MatteMode = .alpha) { self.source = source; self.mode = mode }

    enum CodingKeys: String, CodingKey { case source, mode }

    /// Also accepts a bare layer id (alpha matte).
    public init(from decoder: Decoder) throws {
        if let id = try? decoder.singleValueContainer().decode(String.self) {
            self.init(source: id)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(source: try c.decode(String.self, forKey: .source),
                  mode: try c.decodeIfPresent(MatteMode.self, forKey: .mode) ?? .alpha)
    }
}

// MARK: - Repeater

/// Draws copies of a layer, each one transformed a step further than the previous (like After Effects' repeater):
/// rings of dots, fans, spirals, trails, staggered grids.
public struct Repeater: Codable, Equatable, Hashable, Sendable {
    public static let maxCount = 500

    /// Copies including the original.
    public var count: Int
    /// Per-copy step: move (px), turn (degrees) and scale (×), applied around the pivot and compounded.
    public var x: AnimValue
    public var y: AnimValue
    public var rotation: AnimValue
    public var scale: AnimValue
    /// Pivot of the rotation/scale as an offset from the layer's position (px), e.g. the center of a ring.
    public var pivotX: Double
    public var pivotY: Double
    /// Opacity of the last copy (the first is 1); copies in between fade evenly.
    public var opacityEnd: Double
    /// Seconds each copy lags behind the previous one (its animation and start time), for cascades and trails.
    public var delay: Double

    public init(count: Int = 3) {
        self.count = count
        x = .constant(0); y = .constant(0); rotation = .constant(0); scale = .constant(1)
        pivotX = 0; pivotY = 0; opacityEnd = 1; delay = 0
    }

    enum CodingKeys: String, CodingKey { case count, x, y, rotation, scale, pivotX, pivotY, opacityEnd, delay }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(count: min(max(try c.decodeIfPresent(Int.self, forKey: .count) ?? 3, 1), Self.maxCount))
        x = try c.decodeIfPresent(AnimValue.self, forKey: .x) ?? x
        y = try c.decodeIfPresent(AnimValue.self, forKey: .y) ?? y
        rotation = try c.decodeIfPresent(AnimValue.self, forKey: .rotation) ?? rotation
        scale = try c.decodeIfPresent(AnimValue.self, forKey: .scale) ?? scale
        pivotX = try c.decodeIfPresent(Double.self, forKey: .pivotX) ?? 0
        pivotY = try c.decodeIfPresent(Double.self, forKey: .pivotY) ?? 0
        opacityEnd = min(max(try c.decodeIfPresent(Double.self, forKey: .opacityEnd) ?? 1, 0), 1)
        delay = try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        if x != .constant(0) { try c.encode(x, forKey: .x) }
        if y != .constant(0) { try c.encode(y, forKey: .y) }
        if rotation != .constant(0) { try c.encode(rotation, forKey: .rotation) }
        if scale != .constant(1) { try c.encode(scale, forKey: .scale) }
        if pivotX != 0 { try c.encode(pivotX, forKey: .pivotX) }
        if pivotY != 0 { try c.encode(pivotY, forKey: .pivotY) }
        if opacityEnd != 1 { try c.encode(opacityEnd, forKey: .opacityEnd) }
        if delay != 0 { try c.encode(delay, forKey: .delay) }
    }

    /// Transform (in the layer's parent space) and opacity of copy i, for a layer whose center is at `position`.
    public func copy(_ i: Int, at t: Double, position: CGPoint) -> (transform: CGAffineTransform, opacity: Double) {
        let px = position.x + pivotX, py = position.y + pivotY
        let step = CGAffineTransform(translationX: -px, y: -py)
            .concatenating(CGAffineTransform(scaleX: scale.value(at: t), y: scale.value(at: t)))
            .concatenating(CGAffineTransform(rotationAngle: rotation.value(at: t) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: px + x.value(at: t), y: py + y.value(at: t)))
        var m = CGAffineTransform.identity
        for _ in 0..<i { m = m.concatenating(step) }
        let f = count > 1 ? Double(i) / Double(count - 1) : 0
        return (m, 1 + (opacityEnd - 1) * f)
    }

    func shifted(by d: Double) -> Repeater {
        var r = self
        r.x = x.shifted(by: d); r.y = y.shifted(by: d); r.rotation = rotation.shifted(by: d); r.scale = scale.shifted(by: d)
        return r
    }
}
