namespace VeyMotion.Core;

/// <summary>
/// Path operators on shape layers (After Effects' Offset Paths, Zig Zag, Wiggle Paths, Pucker &amp; Bloat) and tapered
/// strokes. They work on flattened polylines and give back subpaths, so trim paths, gradients and morph keyframes keep
/// working on the result. Port of <c>PathOps</c> in <c>PathOps.swift</c>.
/// </summary>
public readonly struct PathOps
{
    public readonly double Offset, Zigzag, Wiggle, Pucker, Spacing, Speed, Time;
    public readonly ulong Seed;

    public PathOps(MotionLayer layer, double t)
    {
        Offset = layer.Value(AnimProperty.OffsetPath, t);
        Zigzag = layer.Value(AnimProperty.Zigzag, t);
        Wiggle = layer.Value(AnimProperty.WigglePath, t);
        Pucker = Math.Clamp(layer.Value(AnimProperty.Pucker, t), -1, 1);
        Spacing = Math.Max(4, layer.Value(AnimProperty.WaveLength, t) / 2);
        Speed = layer.Value(AnimProperty.WaveSpeed, t);
        Time = t;
        Seed = Noise.Hash($"pathops.{layer.Id}");
    }

    public bool IsActive => Math.Abs(Offset) > 0.01 || Math.Abs(Zigzag) > 0.01 || Math.Abs(Wiggle) > 0.01 || Math.Abs(Pucker) > 0.001;

    /// <summary>How far the operators can move the outline, in layer px.</summary>
    public double Reach => Math.Abs(Offset) + Math.Abs(Zigzag) + Math.Abs(Wiggle);

    public List<Subpath> Apply(IEnumerable<Subpath> subpaths)
    {
        var self = this;
        var subs = subpaths.Where(s => s.Segments.Count > 0).ToList();
        if (Math.Abs(Pucker) > 0.001) subs = subs.Select(s => PuckerSubpath(s, self.Pucker)).ToList();
        if (!(Math.Abs(Offset) > 0.01 || Math.Abs(Zigzag) > 0.01 || Math.Abs(Wiggle) > 0.01)) return subs;
        return subs.Select((s, i) =>
        {
            var pts = Flatten(s);
            if (Math.Abs(self.Offset) > 0.01) pts = OffsetPoints(pts, self.Offset, s.Closed);
            if (Math.Abs(self.Zigzag) > 0.01) pts = ZigzagPoints(pts, self.Zigzag, self.Spacing, s.Closed);
            if (Math.Abs(self.Wiggle) > 0.01)
                pts = WigglePoints(pts, self.Wiggle, self.Spacing, s.Closed, self.Time * self.Speed, unchecked(self.Seed + (ulong)i));
            return ToSubpath(pts, s.Closed, Math.Abs(self.Zigzag) < 0.01);
        }).ToList();
    }

    // Pucker & bloat: anchor points move toward (or away from) the center, control points the other way.

    public static Subpath PuckerSubpath(Subpath s, double k)
    {
        var pts = s.Segments.Select(g => g.P).Prepend(s.Start).ToList();
        var c = new PathPoint(pts.Average(p => p.X), pts.Average(p => p.Y));
        PathPoint Move(PathPoint p) => new(p.X + (c.X - p.X) * k, p.Y + (c.Y - p.Y) * k);
        PathPoint Push(PathPoint q) => new(q.X - (c.X - q.X) * k * 0.6, q.Y - (c.Y - q.Y) * k * 0.6);
        return new Subpath(Move(s.Start), s.Segments.Select(g => new CubicSegment(Push(g.C1), Push(g.C2), Move(g.P))).ToList(), s.Closed);
    }

    // Polylines

    /// <summary>Points along the subpath about every <paramref name="step"/> px (closed paths do not repeat the start).</summary>
    public static List<PathPoint> Flatten(Subpath s, double step = 3)
    {
        var output = new List<PathPoint> { s.Start };
        var from = s.Start;
        foreach (var seg in s.Segments)
        {
            var n = Math.Max(1, (int)Math.Ceiling(Subpath.SegmentLength(from, seg, 8) / step));
            for (var k = 1; k <= n; k++) output.Add(Subpath.Point(from, seg, (double)k / n));
            from = seg.P;
        }
        if (s.Closed && output.Count > 1 && Dist(output[0], output[^1]) < 1e-6) output.RemoveAt(output.Count - 1);
        return output;
    }

    static double Dist(PathPoint a, PathPoint b) => Math.Sqrt((a.X - b.X) * (a.X - b.X) + (a.Y - b.Y) * (a.Y - b.Y));

    /// <summary>Outward normal at each point (for closed paths; the left-hand normal for open ones).</summary>
    public static List<PathPoint> Normals(List<PathPoint> pts, bool closed)
    {
        var n = pts.Count;
        if (n < 2) return pts.Select(_ => new PathPoint(0, -1)).ToList();
        // Orientation: positive area in y-down coordinates means clockwise on screen.
        double area = 0;
        if (closed)
            for (var i = 0; i < n; i++) { PathPoint a = pts[i], b = pts[(i + 1) % n]; area += a.X * b.Y - b.X * a.Y; }
        double sign = closed && area > 0 ? 1 : -1;
        return Enumerable.Range(0, n).Select(i =>
        {
            PathPoint prev = pts[closed ? (i + n - 1) % n : Math.Max(i - 1, 0)], next = pts[closed ? (i + 1) % n : Math.Min(i + 1, n - 1)];
            double dx = next.X - prev.X, dy = next.Y - prev.Y;
            var len = Math.Sqrt(dx * dx + dy * dy);
            if (len < 1e-9) { dx = 1; dy = 0; } else { dx /= len; dy /= len; }
            // Left-hand normal of the direction, flipped to point outward for clockwise loops.
            return new PathPoint(dy * sign, -dx * sign);
        }).ToList();
    }

    public static List<PathPoint> OffsetPoints(List<PathPoint> pts, double d, bool closed)
    {
        var ns = Normals(pts, closed);
        return pts.Select((p, i) => new PathPoint(p.X + ns[i].X * d, p.Y + ns[i].Y * d)).ToList();
    }

    /// <summary>Resamples the polyline every <paramref name="spacing"/> px (the last point kept for open paths).</summary>
    public static List<PathPoint> Resample(List<PathPoint> pts, double spacing, bool closed)
    {
        if (pts.Count < 2) return pts;
        var loop = new List<PathPoint>(pts);
        if (closed) loop.Add(pts[0]);
        var lengths = new double[loop.Count];
        for (var i = 1; i < loop.Count; i++) lengths[i] = lengths[i - 1] + Dist(loop[i], loop[i - 1]);
        var total = lengths[^1];
        if (!(total > spacing)) return pts;
        var count = Math.Max(2, (int)Math.Round(total / spacing, MidpointRounding.AwayFromZero));
        var step = total / count;
        var output = new List<PathPoint>();
        var j = 0;
        for (var k = 0; k < (closed ? count : count + 1); k++)
        {
            var d = Math.Min(k * step, total);
            while (j < lengths.Length - 2 && lengths[j + 1] < d) j++;
            var seg = lengths[j + 1] - lengths[j];
            var f = seg > 0 ? (d - lengths[j]) / seg : 0;
            output.Add(new PathPoint(loop[j].X + (loop[j + 1].X - loop[j].X) * f, loop[j].Y + (loop[j + 1].Y - loop[j].Y) * f));
        }
        return output;
    }

    public static List<PathPoint> ZigzagPoints(List<PathPoint> pts, double amplitude, double spacing, bool closed)
    {
        var re = Resample(pts, spacing, closed);
        if (closed && re.Count % 2 == 1) re = Resample(pts, spacing * re.Count / (re.Count + 1), true);
        var ns = Normals(re, closed);
        return re.Select((p, i) =>
        {
            double s = i % 2 == 0 ? 1 : -1;
            return new PathPoint(p.X + ns[i].X * amplitude * s, p.Y + ns[i].Y * amplitude * s);
        }).ToList();
    }

    public static List<PathPoint> WigglePoints(List<PathPoint> pts, double amplitude, double spacing, bool closed, double z, ulong seed)
    {
        var re = Resample(pts, spacing, closed);
        var ns = Normals(re, closed);
        return re.Select((p, i) =>
        {
            var k = Noise.Value3(i * 0.37, z, 0, seed).V;
            return new PathPoint(p.X + ns[i].X * amplitude * k, p.Y + ns[i].Y * amplitude * k);
        }).ToList();
    }

    /// <summary>Polyline back to a subpath: straight segments, or a Catmull-Rom curve through the points.</summary>
    public static Subpath ToSubpath(List<PathPoint> pts, bool closed, bool smooth)
    {
        if (pts.Count == 0) return new Subpath(new PathPoint(0, 0), [], closed);
        var n = pts.Count;
        var segs = new List<CubicSegment>();
        var count = closed ? n : n - 1;
        for (var i = 0; i < count; i++)
        {
            PathPoint p1 = pts[i], p2 = pts[(i + 1) % n];
            if (smooth)
            {
                PathPoint p0 = pts[closed ? (i + n - 1) % n : Math.Max(i - 1, 0)], p3 = pts[closed ? (i + 2) % n : Math.Min(i + 2, n - 1)];
                segs.Add(new CubicSegment(new PathPoint(p1.X + (p2.X - p0.X) / 6, p1.Y + (p2.Y - p0.Y) / 6),
                    new PathPoint(p2.X - (p3.X - p1.X) / 6, p2.Y - (p3.Y - p1.Y) / 6), p2));
            }
            else segs.Add(CubicSegment.Line(p1, p2));
        }
        return new Subpath(pts[0], segs, closed);
    }

    // Tapered strokes

    /// <summary>A stroke that thins to a point over the first <paramref name="taperStart"/> and last
    /// <paramref name="taperEnd"/> of what is drawn, as a polygon to fill. <paramref name="from"/>/<paramref name="to"/>
    /// (0…1 of the piece's length, to may exceed 1 to wrap) select the drawn part. Empty when nothing shows.</summary>
    public static List<PathPoint> TaperedStroke(Subpath s, double width, double from, double to, double taperStart, double taperEnd)
    {
        var pts = Flatten(s, 2);
        if (s.Closed && pts.Count > 0) pts.Add(pts[0]);
        if (pts.Count < 2) return [];
        var lengths = new double[pts.Count];
        for (var i = 1; i < pts.Count; i++) lengths[i] = lengths[i - 1] + Dist(pts[i], pts[i - 1]);
        var total = lengths[^1];
        if (!(total > 0)) return [];
        PathPoint Point(double d)
        {
            d = s.Closed ? d - Math.Floor(d / total) * total : Math.Clamp(d, 0, total);
            int lo = 0, hi = lengths.Length - 1;
            while (hi - lo > 1)
            {
                var mid = (lo + hi) / 2;
                if (lengths[mid] <= d) lo = mid; else hi = mid;
            }
            var seg = lengths[hi] - lengths[lo];
            var f = seg > 0 ? (d - lengths[lo]) / seg : 0;
            return new PathPoint(pts[lo].X + (pts[hi].X - pts[lo].X) * f, pts[lo].Y + (pts[hi].Y - pts[lo].Y) * f);
        }
        double a = from * total, b = to * total;
        if (!(b > a + 0.5)) return [];
        var n = Math.Max(2, (int)((b - a) / 2));
        var left = new List<PathPoint>();
        var right = new List<PathPoint>();
        for (var k = 0; k <= n; k++)
        {
            var u = (double)k / n;
            var d = a + (b - a) * u;
            PathPoint p = Point(d), q = Point(d + 1), r = Point(d - 1);
            double dx = q.X - r.X, dy = q.Y - r.Y;
            var len = Math.Sqrt(dx * dx + dy * dy);
            if (len < 1e-9) { dx = 1; dy = 0; } else { dx /= len; dy /= len; }
            var w = 1.0;
            if (taperStart > 0.001) w = Math.Min(w, u / taperStart);
            if (taperEnd > 0.001) w = Math.Min(w, (1 - u) / taperEnd);
            var h = Math.Max(0, w) * width / 2;
            left.Add(new PathPoint(p.X - dy * h, p.Y + dx * h));
            right.Add(new PathPoint(p.X + dy * h, p.Y - dx * h));
        }
        right.Reverse();
        left.AddRange(right);
        return left;
    }
}
