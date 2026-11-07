using System.Globalization;

namespace VeyMotion.Core;

/// <summary>One cubic segment; it starts where the previous one ends. Lines are stored as cubics too, so any two
/// paths can be morphed point by point. Port of <c>Shapes.swift</c>.</summary>
public readonly record struct CubicSegment(PathPoint C1, PathPoint C2, PathPoint P)
{
    public static CubicSegment Line(PathPoint a, PathPoint b) => new(
        new PathPoint(a.X + (b.X - a.X) / 3, a.Y + (b.Y - a.Y) / 3),
        new PathPoint(a.X + (b.X - a.X) * 2 / 3, a.Y + (b.Y - a.Y) * 2 / 3), b);
}

public sealed record Subpath(PathPoint Start, List<CubicSegment> Segments, bool Closed)
{
    public bool Equals(Subpath? o) => o != null && Start == o.Start && Closed == o.Closed && Segments.SequenceEqual(o.Segments);
    public override int GetHashCode() => HashCode.Combine(Start, Closed, Segments.Count);

    public double Length
    {
        get
        {
            double total = 0;
            var from = Start;
            foreach (var s in Segments) { total += SegmentLength(from, s); from = s.P; }
            return total;
        }
    }

    public static double SegmentLength(PathPoint a, CubicSegment s, int steps = 16)
    {
        double total = 0;
        var last = a;
        for (var i = 1; i <= steps; i++)
        {
            var q = Point(a, s, (double)i / steps);
            total += Math.Sqrt((q.X - last.X) * (q.X - last.X) + (q.Y - last.Y) * (q.Y - last.Y));
            last = q;
        }
        return total;
    }

    public static PathPoint Point(PathPoint a, CubicSegment s, double t)
    {
        var u = 1 - t;
        double w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t;
        return new PathPoint(w0 * a.X + w1 * s.C1.X + w2 * s.C2.X + w3 * s.P.X, w0 * a.Y + w1 * s.C1.Y + w2 * s.C2.Y + w3 * s.P.Y);
    }

    /// <summary>The same number of segments, all at the subpath's center (a shape morphs out of nothing).</summary>
    public Subpath Collapsed()
    {
        var pts = Segments.Select(s => s.P).Prepend(Start).ToList();
        var c = new PathPoint(pts.Average(p => p.X), pts.Average(p => p.Y));
        return new Subpath(c, Segments.Select(_ => new CubicSegment(c, c, c)).ToList(), Closed);
    }

    /// <summary>Splits the longest segments in half until there are n.</summary>
    public Subpath Subdivided(int n)
    {
        if (Segments.Count == 0) return this;
        var segs = Segments.ToList();
        while (segs.Count < n)
        {
            int best = 0;
            double bestLen = -1;
            var from = Start;
            for (var i = 0; i < segs.Count; i++)
            {
                var s = segs[i];
                var len = Dist(s.P, from) + Dist(s.C1, from);
                if (len > bestLen) { best = i; bestLen = len; }
                from = s.P;
            }
            var a = best == 0 ? Start : segs[best - 1].P;
            var (l, r) = Split(a, segs[best]);
            segs[best] = l;
            segs.Insert(best + 1, r);
        }
        return this with { Segments = segs };
    }

    static double Dist(PathPoint a, PathPoint b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    static (CubicSegment, CubicSegment) Split(PathPoint a, CubicSegment s)
    {
        static PathPoint Mid(PathPoint u, PathPoint v) => new((u.X + v.X) / 2, (u.Y + v.Y) / 2);
        PathPoint ab = Mid(a, s.C1), bc = Mid(s.C1, s.C2), cd = Mid(s.C2, s.P);
        PathPoint abc = Mid(ab, bc), bcd = Mid(bc, cd), m = Mid(abc, bcd);
        return (new CubicSegment(ab, abc, m), new CubicSegment(bcd, cd, s.P));
    }

    /// <summary>Closed loop starting at segment k's start, optionally run the other way.</summary>
    Subpath Rotated(int k, bool reversed)
    {
        var loop = this;
        if (reversed)
        {
            var segs = new List<CubicSegment>();
            for (var i = Segments.Count - 1; i >= 0; i--)
            {
                var from = i == 0 ? Start : Segments[i - 1].P;
                segs.Add(new CubicSegment(Segments[i].C2, Segments[i].C1, from));
            }
            loop = new Subpath(Segments.Count > 0 ? Segments[^1].P : Start, segs, true);
        }
        if (k <= 0 || k >= loop.Segments.Count) return loop;
        var s = loop.Segments[k - 1].P;
        return new Subpath(s, loop.Segments.Skip(k).Concat(loop.Segments.Take(k)).ToList(), true);
    }

    /// <summary>This closed loop started at the point (and run in the direction) closest to other, so a morph doesn't twist.</summary>
    public Subpath AlignedTo(Subpath other)
    {
        var n = Segments.Count;
        if (n <= 1 || n != other.Segments.Count) return this;
        var target = other.Segments.Select(s => s.P).ToList();
        var best = this;
        var bestCost = double.PositiveInfinity;
        foreach (var rev in new[] { false, true })
        {
            for (var k = 0; k < n; k++)
            {
                var cand = Rotated(k, rev);
                double cost = 0;
                for (var i = 0; i < n && cost < bestCost; i++)
                {
                    var u = cand.Segments[i].P;
                    var v = target[i];
                    cost += (u.X - v.X) * (u.X - v.X) + (u.Y - v.Y) * (u.Y - v.Y);
                }
                if (cost < bestCost) { best = cand; bestCost = cost; }
            }
        }
        return best;
    }
}

/// <summary>A vector shape from SVG path data ("M0 0 L100 0 …") or a shorthand such as "star(5,200,80)".
/// Keyframes between two shapes morph one into the other.</summary>
public sealed class PathShape : IEquatable<PathShape>
{
    /// <summary>The text it was written as (null for an in-between shape of a morph).</summary>
    public string? Source { get; }
    public IReadOnlyList<Subpath> Subpaths { get; }

    public PathShape(IReadOnlyList<Subpath> subpaths) { Source = null; Subpaths = subpaths; }

    /// <exception cref="FormatException">Bad path data.</exception>
    public PathShape(string text) { Source = text; Subpaths = PathParser.Parse(text); }

    public static readonly PathShape Zero = new([]);
    public bool IsEmpty => Subpaths.All(s => s.Segments.Count == 0);

    /// <summary>SVG path data of the shape (all segments as cubics).</summary>
    public string Svg
    {
        get
        {
            static string N(double v) => v == Math.Round(v) ? ((long)v).ToString(CultureInfo.InvariantCulture) : v.ToString("0.00", CultureInfo.InvariantCulture);
            static string Pt(PathPoint p) => $"{N(p.X)} {N(p.Y)}";
            return string.Join(" ", Subpaths.Select(s =>
                $"M{Pt(s.Start)}" + string.Concat(s.Segments.Select(g => $" C{Pt(g.C1)} {Pt(g.C2)} {Pt(g.P)}")) + (s.Closed ? " Z" : "")));
        }
    }

    public override string ToString() => Source ?? Svg;

    public bool Equals(PathShape? o) => o != null && (ReferenceEquals(this, o) || (Source == o.Source && Subpaths.SequenceEqual(o.Subpaths)));
    public override bool Equals(object? obj) => Equals(obj as PathShape);
    public override int GetHashCode() => Source?.GetHashCode() ?? Subpaths.Count;

    public static PathShape Lerp(PathShape a, PathShape b, double p)
    {
        if (p == 0 || a.Equals(b)) return a;
        if (p == 1) return b;
        if (a.IsEmpty || b.IsEmpty) return p < 0.5 ? a : b;
        var sa = a.Subpaths.Where(s => s.Segments.Count > 0).ToList();
        var sb = b.Subpaths.Where(s => s.Segments.Count > 0).ToList();
        // Missing subpaths grow from (or shrink to) the center of their counterpart.
        while (sa.Count < sb.Count) sa.Add(sb[sa.Count].Collapsed());
        while (sb.Count < sa.Count) sb.Add(sa[sb.Count].Collapsed());
        var output = new List<Subpath>();
        for (var i = 0; i < sa.Count; i++)
        {
            var n = Math.Max(sa[i].Segments.Count, sb[i].Segments.Count);
            var x = sa[i].Subdivided(n);
            var y = sb[i].Subdivided(n);
            if (x.Closed && y.Closed) y = y.AlignedTo(x);
            PathPoint L(PathPoint u, PathPoint v) => new(u.X + (v.X - u.X) * p, u.Y + (v.Y - u.Y) * p);
            var segs = x.Segments.Zip(y.Segments, (s1, s2) => new CubicSegment(L(s1.C1, s2.C1), L(s1.C2, s2.C2), L(s1.P, s2.P))).ToList();
            output.Add(new Subpath(L(x.Start, y.Start), segs, x.Closed || y.Closed));
        }
        return new PathShape(output);
    }

    /// <summary>Bounding box of the control polygon (a little generous for curves).</summary>
    public (double MinX, double MinY, double MaxX, double MaxY)? Bounds
    {
        get
        {
            var pts = Subpaths.SelectMany(s => s.Segments.SelectMany(g => new[] { g.C1, g.C2, g.P }).Prepend(s.Start)).ToList();
            if (pts.Count == 0) return null;
            return (pts.Min(p => p.X), pts.Min(p => p.Y), pts.Max(p => p.X), pts.Max(p => p.Y));
        }
    }
}

public static class PathParser
{
    internal static List<Subpath> Parse(string text)
    {
        var s = text.Trim();
        var open = s.IndexOf('(');
        if (open > 0 && s.EndsWith(')') && char.IsLetter(s[0]))
        {
            var name = s[..open].Trim().ToLowerInvariant();
            var parts = s[(open + 1)..^1].Split(',');
            var args = new List<double>();
            foreach (var p in parts)
            {
                if (!double.TryParse(p.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v))
                    throw new FormatException($"arguments of {name}() must be numbers");
                args.Add(v);
            }
            return Shorthand(name, args);
        }
        return new Scanner(s).Run();
    }

    /// <summary>star(points, outer, inner[, rotation]), polygon(sides, radius[, rotation]), circle(r), ellipse(rx, ry),
    /// rect(w, h[, cornerRadius]); centered on 0,0, starting at the top, clockwise.</summary>
    static List<Subpath> Shorthand(string name, List<double> a)
    {
        void Need(int n, string usage) { if (a.Count < n) throw new FormatException($"use {usage}"); }
        static List<Subpath> Corners(List<PathPoint> pts)
        {
            if (pts.Count == 0) return [];
            var segs = new List<CubicSegment>();
            for (var i = 0; i < pts.Count; i++) segs.Add(CubicSegment.Line(pts[i], pts[(i + 1) % pts.Count]));
            return [new Subpath(pts[0], segs, true)];
        }
        static PathPoint OnCircle(double r, double deg) => new(r * Math.Cos(deg * Math.PI / 180), r * Math.Sin(deg * Math.PI / 180));
        switch (name)
        {
            case "star":
            {
                Need(3, "star(points, outerRadius, innerRadius[, rotation])");
                var n = Math.Max(2, (int)a[0]);
                var rot = a.Count > 3 ? a[3] : 0;
                return Corners(Enumerable.Range(0, 2 * n).Select(i => OnCircle(i % 2 == 0 ? a[1] : a[2], -90 + rot + i * 180.0 / n)).ToList());
            }
            case "polygon":
            {
                Need(2, "polygon(sides, radius[, rotation])");
                var n = Math.Max(3, (int)a[0]);
                var rot = a.Count > 2 ? a[2] : 0;
                return Corners(Enumerable.Range(0, n).Select(i => OnCircle(a[1], -90 + rot + i * 360.0 / n)).ToList());
            }
            case "circle":
                Need(1, "circle(radius)");
                return Ellipse(a[0], a[0]);
            case "ellipse":
                Need(2, "ellipse(rx, ry)");
                return Ellipse(a[0], a[1]);
            case "rect":
            {
                Need(2, "rect(width, height[, cornerRadius])");
                double w = a[0] / 2, h = a[1] / 2;
                var r = Math.Min(Math.Max(a.Count > 2 ? a[2] : 0, 0), Math.Min(w, h));
                if (r <= 0) return Corners([new(-w, -h), new(w, -h), new(w, h), new(-w, h)]);
                return [RoundedRect(-w, -h, 2 * w, 2 * h, r)];
            }
            default:
                throw new FormatException($"unknown shape {name}(); use star, polygon, circle, ellipse or rect, or SVG path data");
        }
    }

    public static List<Subpath> Ellipse(double rx, double ry)
    {
        const double k = 0.5522847498;
        static PathPoint P(double x, double y) => new(x, y);
        return
        [
            new Subpath(P(0, -ry),
            [
                new(P(k * rx, -ry), P(rx, -k * ry), P(rx, 0)),
                new(P(rx, k * ry), P(k * rx, ry), P(0, ry)),
                new(P(-k * rx, ry), P(-rx, k * ry), P(-rx, 0)),
                new(P(-rx, -k * ry), P(-k * rx, -ry), P(0, -ry)),
            ], true),
        ];
    }

    /// <summary>A rounded rectangle as cubics, starting after the top-left corner, clockwise (y down).</summary>
    public static Subpath RoundedRect(double x, double y, double w, double h, double r)
    {
        const double k = 0.5522847498;
        double x1 = x + w, y1 = y + h, c = r * (1 - k);
        static PathPoint P(double px, double py) => new(px, py);
        var segs = new List<CubicSegment>
        {
            CubicSegment.Line(P(x + r, y), P(x1 - r, y)),
            new(P(x1 - c, y), P(x1, y + c), P(x1, y + r)),
            CubicSegment.Line(P(x1, y + r), P(x1, y1 - r)),
            new(P(x1, y1 - c), P(x1 - c, y1), P(x1 - r, y1)),
            CubicSegment.Line(P(x1 - r, y1), P(x + r, y1)),
            new(P(x + c, y1), P(x, y1 - c), P(x, y1 - r)),
            CubicSegment.Line(P(x, y1 - r), P(x, y + r)),
            new(P(x, y + c), P(x + c, y), P(x + r, y)),
        };
        return new Subpath(P(x + r, y), segs, true);
    }

    sealed class Scanner(string text)
    {
        readonly string _b = text;
        int _i;
        readonly List<Subpath> _out = [];
        PathPoint _start;
        List<CubicSegment>? _cur;
        PathPoint _pos;
        PathPoint? _lastCubic, _lastQuad;

        void Skip()
        {
            while (_i < _b.Length && (_b[_i] == ' ' || _b[_i] == ',' || (_b[_i] >= '\t' && _b[_i] <= '\r'))) _i++;
        }

        bool AtNumber()
        {
            Skip();
            if (_i >= _b.Length) return false;
            var c = _b[_i];
            return char.IsAsciiDigit(c) || c is '-' or '+' or '.';
        }

        double Num()
        {
            Skip();
            var s = _i;
            if (_i < _b.Length && _b[_i] is '-' or '+') _i++;
            var dot = false;
            while (_i < _b.Length && (char.IsAsciiDigit(_b[_i]) || (_b[_i] == '.' && !dot))) { if (_b[_i] == '.') dot = true; _i++; }
            if (_i < _b.Length && _b[_i] is 'e' or 'E')
            {
                _i++;
                if (_i < _b.Length && _b[_i] is '-' or '+') _i++;
                while (_i < _b.Length && char.IsAsciiDigit(_b[_i])) _i++;
            }
            if (_i <= s || !double.TryParse(_b.AsSpan(s, _i - s), NumberStyles.Float, CultureInfo.InvariantCulture, out var v))
                throw new FormatException($"expected a number at character {s + 1}");
            return v;
        }

        bool Flag()
        {
            Skip();
            if (_i >= _b.Length || _b[_i] is not ('0' or '1')) throw new FormatException($"expected an arc flag (0 or 1) at character {_i + 1}");
            return _b[_i++] == '1';
        }

        PathPoint Point(bool rel)
        {
            double x = Num(), y = Num();
            return rel ? new PathPoint(_pos.X + x, _pos.Y + y) : new PathPoint(x, y);
        }

        void Add(CubicSegment s)
        {
            if (_cur == null) { _cur = []; _start = _pos; }
            _cur.Add(s);
            _pos = s.P;
        }

        void Finish(bool closed = false)
        {
            if (_cur != null && (_cur.Count > 0 || closed)) _out.Add(new Subpath(_start, _cur, closed));
            _cur = null;
        }

        static bool IsLetter(char c) => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z';

        public List<Subpath> Run()
        {
            var cmd = '\0';
            Skip();
            while (_i < _b.Length)
            {
                var c = _b[_i];
                if (IsLetter(c)) { cmd = c; _i++; }
                else if (cmd == '\0') throw new FormatException("path data must start with a command such as M");
                var rel = char.IsLower(cmd);
                PathPoint? cubicCtrl = null, quadCtrl = null;
                switch (char.ToLowerInvariant(cmd))
                {
                    case 'm':
                        Finish();
                        _pos = Point(rel);
                        _start = _pos;
                        _cur = [];
                        cmd = rel ? 'l' : 'L'; // further pairs are lines
                        break;
                    case 'l': { var p = Point(rel); Add(CubicSegment.Line(_pos, p)); break; }
                    case 'h': { var x = Num(); Add(CubicSegment.Line(_pos, new PathPoint(rel ? _pos.X + x : x, _pos.Y))); break; }
                    case 'v': { var y = Num(); Add(CubicSegment.Line(_pos, new PathPoint(_pos.X, rel ? _pos.Y + y : y))); break; }
                    case 'c':
                    {
                        PathPoint c1 = Point(rel), c2 = Point(rel), p = Point(rel);
                        Add(new CubicSegment(c1, c2, p));
                        cubicCtrl = c2;
                        break;
                    }
                    case 's':
                    {
                        var c1 = _lastCubic is { } lc ? new PathPoint(2 * _pos.X - lc.X, 2 * _pos.Y - lc.Y) : _pos;
                        PathPoint c2 = Point(rel), p = Point(rel);
                        Add(new CubicSegment(c1, c2, p));
                        cubicCtrl = c2;
                        break;
                    }
                    case 'q':
                    {
                        PathPoint q = Point(rel), p = Point(rel);
                        AddQuad(q, p);
                        quadCtrl = q;
                        break;
                    }
                    case 't':
                    {
                        var q = _lastQuad is { } lq ? new PathPoint(2 * _pos.X - lq.X, 2 * _pos.Y - lq.Y) : _pos;
                        var p = Point(rel);
                        AddQuad(q, p);
                        quadCtrl = q;
                        break;
                    }
                    case 'a':
                    {
                        double rx = Num(), ry = Num(), rot = Num();
                        bool large = Flag(), sweep = Flag();
                        var p = Point(rel);
                        foreach (var s in Arc(_pos, p, rx, ry, rot, large, sweep)) Add(s);
                        _pos = p;
                        break;
                    }
                    case 'z':
                        if (_cur != null)
                        {
                            if (Math.Abs(_pos.X - _start.X) > 1e-9 || Math.Abs(_pos.Y - _start.Y) > 1e-9) _cur.Add(CubicSegment.Line(_pos, _start));
                            _pos = _start;
                            Finish(closed: true);
                        }
                        Skip();
                        _lastCubic = null; _lastQuad = null;
                        if (_i < _b.Length && !IsLetter(_b[_i])) throw new FormatException($"unexpected character at {_i + 1}");
                        continue;
                    default:
                        throw new FormatException($"unknown path command '{cmd}'");
                }
                _lastCubic = cubicCtrl; _lastQuad = quadCtrl;
                Skip();
                if (_i < _b.Length && !AtNumber() && !IsLetter(_b[_i])) throw new FormatException($"unexpected character at {_i + 1}");
            }
            Finish();
            return _out;
        }

        void AddQuad(PathPoint q, PathPoint p) => Add(new CubicSegment(
            new PathPoint(_pos.X + 2.0 / 3 * (q.X - _pos.X), _pos.Y + 2.0 / 3 * (q.Y - _pos.Y)),
            new PathPoint(p.X + 2.0 / 3 * (q.X - p.X), p.Y + 2.0 / 3 * (q.Y - p.Y)), p));

        /// <summary>SVG elliptical arc as cubic segments of at most 90°.</summary>
        static List<CubicSegment> Arc(PathPoint a, PathPoint b, double rx, double ry, double rotation, bool large, bool sweep)
        {
            rx = Math.Abs(rx); ry = Math.Abs(ry);
            if (rx < 1e-9 || ry < 1e-9 || (a.X == b.X && a.Y == b.Y)) return [CubicSegment.Line(a, b)];
            var phi = rotation * Math.PI / 180;
            double cp = Math.Cos(phi), sp = Math.Sin(phi);
            double dx = (a.X - b.X) / 2, dy = (a.Y - b.Y) / 2;
            double x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy;
            var lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry);
            if (lambda > 1) { rx *= Math.Sqrt(lambda); ry *= Math.Sqrt(lambda); }
            var num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
            var den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
            var k = Math.Sqrt(Math.Max(0, num) / den);
            if (large == sweep) k = -k;
            double cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx;
            double cx = cp * cx1 - sp * cy1 + (a.X + b.X) / 2, cy = sp * cx1 + cp * cy1 + (a.Y + b.Y) / 2;
            static double Angle(double ux, double uy, double vx, double vy) => Math.Atan2(ux * vy - uy * vx, ux * vx + uy * vy);
            var th1 = Angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry);
            var dth = Angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry);
            if (!sweep && dth > 0) dth -= 2 * Math.PI;
            if (sweep && dth < 0) dth += 2 * Math.PI;
            var n = Math.Max(1, (int)Math.Ceiling(Math.Abs(dth) / (Math.PI / 2) - 1e-9));
            var step = dth / n;
            var t = 4.0 / 3 * Math.Tan(step / 4);
            (PathPoint, PathPoint) At(double th)
            {
                double ex = rx * Math.Cos(th), ey = ry * Math.Sin(th);
                var p = new PathPoint(cx + cp * ex - sp * ey, cy + sp * ex + cp * ey);
                double tx = -rx * Math.Sin(th), ty = ry * Math.Cos(th);
                return (p, new PathPoint(cp * tx - sp * ty, sp * tx + cp * ty));
            }
            var segs = new List<CubicSegment>();
            var th = th1;
            for (var i = 0; i < n; i++)
            {
                var (p0, d0) = At(th);
                var (p1, d1) = At(th + step);
                var end = i == n - 1 ? b : p1;
                segs.Add(new CubicSegment(new PathPoint(p0.X + t * d0.X, p0.Y + t * d0.Y), new PathPoint(p1.X - t * d1.X, p1.Y - t * d1.Y), end));
                th += step;
            }
            return segs;
        }
    }
}
