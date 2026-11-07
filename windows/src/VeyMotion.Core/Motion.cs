using System.Globalization;
using System.Numerics;
using System.Text;

namespace VeyMotion.Core;

using AnimValue = Animated<double>;

/// <summary>Deterministic noise. Port of <c>Noise</c> in <c>Motion.swift</c> (same hashes, so the same wiggles).</summary>
public static class Noise
{
    /// <summary>Stable 64-bit FNV-1a hash.</summary>
    public static ulong Hash(string s)
    {
        var h = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes(s)) h = unchecked((h ^ b) * 0x100000001b3UL);
        return h;
    }

    public static ulong Mix(ulong x)
    {
        unchecked
        {
            var z = x + 0x9e3779b97f4a7c15UL;
            z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
            z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
            return z ^ (z >> 31);
        }
    }

    /// <summary>Deterministic random number in [-1, 1] for an integer lattice point.</summary>
    static double Lattice(long i, ulong seed)
    {
        var h = Mix(seed ^ unchecked((ulong)i * 0x2545F4914F6CDD1DUL));
        return (h >> 11) / (double)(1UL << 53) * 2 - 1;
    }

    /// <summary>Deterministic random number in [0, 1).</summary>
    public static double Unit(long i, ulong seed) => (Lattice(i, seed) + 1) / 2;

    /// <summary>Smooth 1D value noise in about [-1, 1].</summary>
    public static double Value(double x, ulong seed)
    {
        var i = (long)Math.Floor(x);
        var f = x - Math.Floor(x);
        var u = f * f * f * (f * (f * 6 - 15) + 10); // quintic fade
        return Lattice(i, seed) + (Lattice(i + 1, seed) - Lattice(i, seed)) * u;
    }

    /// <summary>Two octaves of value noise, normalized to about [-1, 1].</summary>
    public static double Fractal(double x, ulong seed) =>
        (Value(x, seed) + 0.5 * Value(x * 2.03 + 17.1, unchecked(seed + 1))) / 1.5;

    static double Lattice3(long x, long y, long z, ulong seed)
    {
        unchecked
        {
            var hx = (ulong)x * 0x9E3779B185EBCA87UL;
            var hy = (ulong)y * 0xC2B2AE3D27D4EB4FUL;
            var hz = (ulong)z * 0x165667B19E3779F9UL;
            var h = Mix(seed ^ hx ^ (hy + 0x27D4EB2F165667C5UL) ^ (hz + 0x94D049BB133111EBUL));
            return (h >> 11) / (double)(1UL << 53) * 2 - 1;
        }
    }

    /// <summary>3D value noise in about [-1, 1] and its derivatives along x and y. Port of <c>Noise.value3</c>
    /// (<c>Particles.swift</c>).</summary>
    public static (double V, double Dx, double Dy) Value3(double x, double y, double z, ulong seed)
    {
        double fx0 = Math.Floor(x), fy0 = Math.Floor(y), fz0 = Math.Floor(z);
        long ix = (long)fx0, iy = (long)fy0, iz = (long)fz0;
        double fx = x - fx0, fy = y - fy0, fz = z - fz0;
        static double Fade(double f) => f * f * f * (f * (f * 6 - 15) + 10);
        static double DFade(double f) => 30 * f * f * (f - 1) * (f - 1);
        double u = Fade(fx), v = Fade(fy), w = Fade(fz), du = DFade(fx), dv = DFade(fy);
        double c000 = Lattice3(ix, iy, iz, seed), c100 = Lattice3(ix + 1, iy, iz, seed);
        double c010 = Lattice3(ix, iy + 1, iz, seed), c110 = Lattice3(ix + 1, iy + 1, iz, seed);
        double c001 = Lattice3(ix, iy, iz + 1, seed), c101 = Lattice3(ix + 1, iy, iz + 1, seed);
        double c011 = Lattice3(ix, iy + 1, iz + 1, seed), c111 = Lattice3(ix + 1, iy + 1, iz + 1, seed);
        double k1 = c100 - c000, k2 = c010 - c000, k3 = c001 - c000;
        var k4 = c000 - c100 - c010 + c110;
        var k5 = c000 - c010 - c001 + c011;
        var k6 = c000 - c100 - c001 + c101;
        var k7 = -c000 + c100 + c010 - c110 + c001 - c101 - c011 + c111;
        var value = c000 + k1 * u + k2 * v + k3 * w + k4 * u * v + k5 * v * w + k6 * w * u + k7 * u * v * w;
        return (value, du * (k1 + k4 * v + k6 * w + k7 * v * w), dv * (k2 + k4 * u + k5 * w + k7 * u * w));
    }

    /// <summary>Divergence-free 2D flow (curl of two octaves of noise), about unit strength. z animates the field.</summary>
    public static (double X, double Y) Curl(double x, double y, double z, ulong seed)
    {
        var a = Value3(x, y, z, seed);
        var b = Value3(x * 2.03 + 17.1, y * 2.03 - 9.3, z * 1.7, unchecked(seed + 1));
        double dx = a.Dx + 0.5 * 2.03 * b.Dx, dy = a.Dy + 0.5 * 2.03 * b.Dy;
        return (dy / 1.6, -dx / 1.6);
    }
}

/// <summary>Random but smooth movement added on top of a property (like After Effects' wiggle()).</summary>
public sealed record Wiggle(double Amount, double Frequency = 2, long Seed = 0)
{
    public double Offset(double t, ulong salt) =>
        Amount * Noise.Fractal(t * Frequency, salt ^ Noise.Mix(unchecked((ulong)Seed)));
}

/// <summary>A path the layer's center travels along, measured by distance so the speed is even.</summary>
public sealed record MotionPath(List<PathPoint> Points, bool Smooth = true, bool Closed = false, bool Orient = false)
{
    /// <summary>Dense polyline approximating the path.</summary>
    public List<Vector2> Polyline(int samplesPerSegment = 32)
    {
        var pts = Points.Select(p => new Vector2((float)p.X, (float)p.Y)).ToList();
        if (pts.Count < 2) return pts;
        var n = pts.Count;
        var segments = Closed ? n : n - 1;
        Vector2 P(int i) => Closed ? pts[((i % n) + n) % n] : pts[Math.Clamp(i, 0, n - 1)];
        var output = new List<Vector2> { pts[0] };
        for (var s = 0; s < segments; s++)
        {
            Vector2 p0 = P(s - 1), p1 = P(s), p2 = P(s + 1), p3 = P(s + 2);
            var steps = Smooth ? samplesPerSegment : 1;
            for (var k = 1; k <= steps; k++)
            {
                var t = (float)k / steps;
                if (!Smooth) { output.Add(p1 + (p2 - p1) * t); continue; }
                float t2 = t * t, t3 = t2 * t;
                float Cr(float a, float b, float c, float d) =>
                    0.5f * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3);
                output.Add(new Vector2(Cr(p0.X, p1.X, p2.X, p3.X), Cr(p0.Y, p1.Y, p2.Y, p3.Y)));
            }
        }
        return output;
    }

    /// <summary>Point and direction (degrees, 0 = +x, clockwise on screen) at a progress along the path.</summary>
    public (Vector2 Point, double Angle) Sample(double progress)
    {
        var poly = Polyline();
        if (poly.Count == 0) return (Vector2.Zero, 0);
        if (poly.Count < 2) return (poly[0], 0);
        var lengths = new double[poly.Count];
        for (var i = 1; i < poly.Count; i++) lengths[i] = lengths[i - 1] + Vector2.Distance(poly[i], poly[i - 1]);
        var total = lengths[^1];
        if (total <= 1e-9) return (poly[0], 0);
        var pr = progress;
        if (Closed) pr -= Math.Floor(pr); else pr = Math.Clamp(pr, 0, 1);
        var target = pr * total;
        int lo = 0, hi = lengths.Length - 1;
        while (hi - lo > 1)
        {
            var mid = (lo + hi) / 2;
            if (lengths[mid] <= target) lo = mid; else hi = mid;
        }
        Vector2 a = poly[lo], b = poly[hi];
        var seg = lengths[hi] - lengths[lo];
        var f = seg > 0 ? (float)((target - lengths[lo]) / seg) : 0;
        return (a + (b - a) * f, Math.Atan2(b.Y - a.Y, b.X - a.X) * 180 / Math.PI);
    }
}

/// <summary>Pans, zooms and turns everything drawn. <c>X</c>/<c>Y</c> is the scene point shown at the frame's center
/// (null = the scene center). Port of <c>Camera</c> in <c>Camera.swift</c>.</summary>
public sealed class Camera
{
    public AnimValue? X;
    public AnimValue? Y;
    public AnimValue Zoom = 1.0;
    public AnimValue Rotation = 0.0;
    /// <summary>Handheld shake on x, y, zoom or rotation.</summary>
    public Dictionary<string, Wiggle> Wiggle = [];
    /// <summary>Depth of field: layers whose depth differs from focus blur by aperture px per unit of difference.</summary>
    public AnimValue Focus = 0.0;
    public AnimValue Aperture = 0.0;

    double Value(string key, AnimValue track, double t)
    {
        var v = track.ValueAt(t);
        if (Wiggle.TryGetValue(key, out var w) && w.Amount != 0) v += w.Offset(t, Noise.Hash($"camera.{key}"));
        return v;
    }

    /// <summary>Scene pixels → framed scene pixels for a layer at <paramref name="depth"/>.</summary>
    public Matrix3x2 Transform(double depth, int w, int h, double t)
    {
        var f = 1 / (1 + Math.Max(depth, -0.9));
        double cx = w / 2.0, cy = h / 2.0;
        var px = cx + (Value("x", X ?? cx, t) - cx) * f;
        var py = cy + (Value("y", Y ?? cy, t) - cy) * f;
        var z = Math.Max(0.01, 1 + (Value("zoom", Zoom, t) - 1) * f);
        var r = Value("rotation", Rotation, t) * Math.PI / 180;
        return Matrix3x2.CreateTranslation((float)-px, (float)-py)
            * Matrix3x2.CreateScale((float)z)
            * Matrix3x2.CreateRotation((float)r)
            * Matrix3x2.CreateTranslation((float)cx, (float)cy);
    }
}

/// <summary>A copy of the source property's track, so a linked layer can evaluate it without the scene.</summary>
public sealed record LinkedTrack(AnimValue Value, LoopMode? Loop, Wiggle? Wiggle, ulong Salt, AudioReact? React = null)
{
    public double ValueAt(double t)
    {
        var v = Value.ValueAt(t, Loop);
        if (Wiggle is { Amount: not 0 } w) v += w.Offset(t, Salt);
        if (React != null) v += React.Offset(t);
        return v;
    }
}

/// <summary>Drives a property from another layer's property: source × multiply + add, read delay seconds ago.</summary>
public sealed class PropertyLink
{
    public required string Layer;
    public required string Property;
    public double Multiply = 1;
    public double Add;
    public double Delay;
    /// <summary>The source as resolved by the scene (not saved).</summary>
    public LinkedTrack? Track;
}

/// <summary>Draws copies of a layer, each one transformed a step further than the previous.</summary>
public sealed class Repeater
{
    public const int MaxCount = 500;
    public int Count = 3;
    public AnimValue X = 0.0, Y = 0.0, Rotation = 0.0, Scale = 1.0;
    public double PivotX, PivotY;
    public double OpacityEnd = 1;
    public double Delay;

    /// <summary>Transform (in the layer's parent space) and opacity of copy i, for a layer centered at position.</summary>
    public (Matrix3x2 Transform, double Opacity) Copy(int i, double t, Vector2 position)
    {
        float px = position.X + (float)PivotX, py = position.Y + (float)PivotY;
        var step = Matrix3x2.CreateTranslation(-px, -py)
            * Matrix3x2.CreateScale((float)Scale.ValueAt(t))
            * Matrix3x2.CreateRotation((float)(Rotation.ValueAt(t) * Math.PI / 180))
            * Matrix3x2.CreateTranslation(px + (float)X.ValueAt(t), py + (float)Y.ValueAt(t));
        var m = Matrix3x2.Identity;
        for (var k = 0; k < i; k++) m *= step;
        var f = Count > 1 ? (double)i / (Count - 1) : 0;
        return (m, 1 + (OpacityEnd - 1) * f);
    }
}

public enum GradientType { Linear, Radial }

public sealed record GradientStop(double Offset, Rgba Color);

/// <summary>Fill of a shape, path or text that varies across it. Replaces the solid fill/color when set.</summary>
public sealed class Gradient
{
    public GradientType Type = GradientType.Linear;
    public List<GradientStop> Stops = [];
    /// <summary>Linear: direction in degrees (0 = left → right, 90 = top → bottom).</summary>
    public AnimValue Angle = 90.0;
    /// <summary>Moves the colors along the gradient (fraction of its length).</summary>
    public AnimValue Shift = 0.0;
    /// <summary>Radial: center as a fraction of the layer box, radius as a fraction of half its diagonal.</summary>
    public double Cx = 0.5, Cy = 0.5;
    public AnimValue Radius = 1.0;
}

/// <summary>Affine color transform <c>out = m · rgb + b</c> on straight colors in 0…1. Port of <c>Effects.swift</c>.</summary>
public sealed record ColorMatrix(double[] M, double[] B)
{
    public static ColorMatrix Identity => new([1, 0, 0, 0, 1, 0, 0, 0, 1], [0, 0, 0]);
    static readonly double[] Luma = [0.2126, 0.7152, 0.0722];

    /// <summary>This transform followed by <paramref name="next"/>.</summary>
    public ColorMatrix Then(ColorMatrix next)
    {
        var m2 = new double[9];
        var b2 = new double[3];
        for (var i = 0; i < 3; i++)
        {
            var bi = next.B[i];
            for (var k = 0; k < 3; k++)
            {
                var nk = next.M[3 * i + k];
                for (var j = 0; j < 3; j++) m2[3 * i + j] += nk * M[3 * k + j];
                bi += nk * B[k];
            }
            b2[i] = bi;
        }
        return new ColorMatrix(m2, b2);
    }

    public static ColorMatrix Brightness(double a) => new([1, 0, 0, 0, 1, 0, 0, 0, 1], [a, a, a]);

    public static ColorMatrix Contrast(double amount)
    {
        var f = Math.Max(0, 1 + amount);
        var o = 0.5 * (1 - f);
        return new([f, 0, 0, 0, f, 0, 0, 0, f], [o, o, o]);
    }

    public static ColorMatrix Saturation(double amount)
    {
        var s = Math.Max(0, 1 + amount);
        var m = new double[9];
        for (var i = 0; i < 3; i++)
            for (var j = 0; j < 3; j++) m[3 * i + j] = (1 - s) * Luma[j] + (i == j ? s : 0);
        return new(m, [0, 0, 0]);
    }

    public static ColorMatrix Hue(double degrees)
    {
        var a = degrees * Math.PI / 180;
        double c = Math.Cos(a), s = Math.Sin(a);
        return new([
            0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928,
            0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283,
            0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072,
        ], [0, 0, 0]);
    }

    public static ColorMatrix Tint(double amount, Rgba color)
    {
        var k = Math.Clamp(amount, 0, 1);
        double[] target = [color.R, color.G, color.B];
        var m = new double[9];
        for (var i = 0; i < 3; i++)
            for (var j = 0; j < 3; j++) m[3 * i + j] = (1 - k) * (i == j ? 1 : 0) + k * target[i] * Luma[j];
        return new(m, [0, 0, 0]);
    }
}

/// <summary>Transforms and time-dependent values. Port of the transform parts of <c>Motion.swift</c> and
/// <c>Camera.swift</c>. Matrices compose like CGAffineTransform.concatenating: <c>a * b</c> = a, then b.</summary>
public static class MotionMath
{
    /// <summary>Center of the layer at time t (in its parent's space): from the motion path if any, else x/y.</summary>
    public static (Vector2 Point, double PathAngle) Position(this MotionLayer l, double t)
    {
        if (l.MotionPath is { Points.Count: > 0 } mp)
        {
            var s = mp.Sample(l.Value(AnimProperty.PathProgress, t));
            return (new Vector2(s.Point.X + (float)l.ProceduralOffset(AnimProperty.X, t), s.Point.Y + (float)l.ProceduralOffset(AnimProperty.Y, t)),
                mp.Orient ? s.Angle : 0);
        }
        return (new Vector2((float)l.Value(AnimProperty.X, t), (float)l.Value(AnimProperty.Y, t)), 0);
    }

    /// <summary>Maps layer-local coordinates (origin at the layer center, y down) to its parent's space.</summary>
    public static Matrix3x2 LocalTransform(this MotionLayer l, double t)
    {
        var pos = l.Position(t);
        float ax = (float)l.Value(AnimProperty.AnchorX, t), ay = (float)l.Value(AnimProperty.AnchorY, t);
        var s = l.Value(AnimProperty.Scale, t);
        var sx = (float)(s * l.Value(AnimProperty.ScaleX, t));
        var sy = (float)(s * l.Value(AnimProperty.ScaleY, t));
        static float TanDeg(double d) => (float)Math.Tan(Math.Clamp(d, -85, 85) * Math.PI / 180);
        var skew = new Matrix3x2(1, TanDeg(l.Value(AnimProperty.SkewY, t)), TanDeg(l.Value(AnimProperty.SkewX, t)), 1, 0, 0);
        var angle = (float)((l.Value(AnimProperty.Rotation, t) + pos.PathAngle) * Math.PI / 180);
        return Matrix3x2.CreateTranslation(-ax, -ay)
            * Matrix3x2.CreateScale(sx, sy)
            * skew
            * Matrix3x2.CreateRotation(angle)
            * Matrix3x2.CreateTranslation(pos.Point.X + ax, pos.Point.Y + ay);
    }

    /// <summary>Layer local → framed scene pixels: through its chain of parents, then the camera.</summary>
    public static Matrix3x2 WorldTransform(this MotionScene s, MotionLayer l, double t) =>
        s.SceneTransform(l, t) * s.CameraTransform(l, t);

    /// <summary>Layer local → scene pixels before the camera.</summary>
    public static Matrix3x2 SceneTransform(this MotionScene s, MotionLayer l, double t) =>
        l.LocalTransform(t) * s.AncestorsTransform(l, t);

    /// <summary>The chain of parents' transforms (identity without a parent), before the camera.</summary>
    public static Matrix3x2 AncestorsTransform(this MotionScene s, MotionLayer l, double t)
    {
        var m = Matrix3x2.Identity;
        var seen = new HashSet<string> { l.Id };
        var next = l.Parent;
        while (next is { } pid && seen.Add(pid) && s.Layers.FirstOrDefault(x => x.Id == pid) is { } p)
        {
            m *= p.LocalTransform(t);
            next = p.Parent;
        }
        return m;
    }

    /// <summary>Everything around a layer's own transform: its parents, then the camera at its depth.</summary>
    public static Matrix3x2 ParentTransform(this MotionScene s, MotionLayer l, double t) =>
        s.AncestorsTransform(l, t) * s.CameraTransform(l, t);

    /// <summary>The camera's effect on a layer (identity without a camera or for fixed layers).</summary>
    public static Matrix3x2 CameraTransform(this MotionScene s, MotionLayer l, double t) =>
        s.Camera is { } cam && !l.Fixed ? cam.Transform(l.Depth, s.Width, s.Height, t) : Matrix3x2.Identity;

    /// <summary>Extra blur (px) the camera's depth of field gives a layer.</summary>
    public static double FocusBlur(this MotionScene s, MotionLayer l, double t)
    {
        if (s.Camera is not { } cam || l.Fixed) return 0;
        var a = cam.Aperture.ValueAt(t);
        return a > 0 ? a * Math.Abs(l.Depth - cam.Focus.ValueAt(t)) : 0;
    }

    /// <summary>The scene a group's children are drawn in: the group's box, no camera, same timing.</summary>
    public static MotionScene Subscene(this MotionScene s, MotionLayer group, double t)
    {
        var w = group.Width is { } gw ? (int)Math.Round(gw.ValueAt(t)) : s.Width;
        var h = group.Height is { } gh ? (int)Math.Round(gh.ValueAt(t)) : s.Height;
        return new MotionScene
        {
            Width = Math.Max(w, 1), Height = Math.Max(h, 1), Fps = s.Fps, Duration = s.Duration,
            Background = Rgba.Clear, Layers = group.Children,
        };
    }

    /// <summary>The layer's color correction at time t, or null when it leaves colors unchanged. AE's order: hue,
    /// saturation, tint, then brightness and contrast.</summary>
    public static ColorMatrix? ColorMatrixAt(this MotionLayer l, double t)
    {
        double hue = l.Value(AnimProperty.Hue, t), sat = l.Value(AnimProperty.Saturation, t), tint = l.Value(AnimProperty.Tint, t);
        double bright = l.Value(AnimProperty.Brightness, t), contrast = l.Value(AnimProperty.Contrast, t);
        const double eps = 1e-4;
        if (!(Math.Abs(hue) > eps || Math.Abs(sat) > eps || tint > eps || Math.Abs(bright) > eps || Math.Abs(contrast) > eps)) return null;
        var cm = ColorMatrix.Identity;
        if (Math.Abs(hue) > eps) cm = cm.Then(ColorMatrix.Hue(hue));
        if (Math.Abs(sat) > eps) cm = cm.Then(ColorMatrix.Saturation(sat));
        if (tint > eps) cm = cm.Then(ColorMatrix.Tint(tint, l.TintColor ?? Rgba.White));
        if (Math.Abs(bright) > eps) cm = cm.Then(ColorMatrix.Brightness(bright));
        if (Math.Abs(contrast) > eps) cm = cm.Then(ColorMatrix.Contrast(contrast));
        return cm;
    }

    /// <summary>The text as shown at time t: "{n}" replaced by the counter's number, and scrambled letters.</summary>
    public static string DisplayText(this MotionLayer l, double t)
    {
        var s = l.Text;
        if (s.Contains("{n}"))
        {
            var v = l.Value(AnimProperty.Counter, t);
            var d = l.CounterDecimals;
            var rounded = Math.Round(v, d, MidpointRounding.ToEven); // NumberFormatter rounds half to even
            var n = rounded.ToString((l.CounterGrouping ? "N" : "F") + d, CultureInfo.InvariantCulture);
            s = s.Replace("{n}", n);
        }
        var scramble = Math.Clamp(l.Value(AnimProperty.Scramble, t), 0, 1);
        if (scramble > 0.001)
        {
            // The letters resolve from the start; the rest flicker through random characters ~15 times a second.
            var chars = s.ToCharArray();
            var letters = Enumerable.Range(0, chars.Length).Where(i => !char.IsWhiteSpace(chars[i])).ToList();
            var keep = (int)Math.Floor(letters.Count * (1 - scramble));
            const string pool = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#$%&@*+=<>?";
            var tick = (ulong)Math.Max(0, (long)(t * 15));
            var salt = Noise.Mix(Noise.Hash($"scramble.{l.Id}") ^ unchecked(tick * 0x9E3779B97F4A7C15UL));
            for (var rank = keep; rank < letters.Count; rank++)
            {
                var i = letters[rank];
                var r = pool[(int)(Noise.Unit(i, salt) * pool.Length) % pool.Length];
                chars[i] = char.IsLower(chars[i]) ? char.ToLowerInvariant(r) : r;
            }
            s = new string(chars);
        }
        return s;
    }
}
