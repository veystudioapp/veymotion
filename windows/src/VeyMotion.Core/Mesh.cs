using System.Numerics;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

using AnimValue = Animated<double>;

/// <summary>Four corners of a layer's box after a corner pin, in layer px around its center (top-left, top-right,
/// bottom-right, bottom-left). Animatable: keyframes interpolate each corner. Port of <c>Mesh.swift</c>.</summary>
public readonly record struct CornerPin(PathPoint Tl, PathPoint Tr, PathPoint Br, PathPoint Bl)
{
    public static CornerPin Zero => default;

    public static CornerPin Lerp(CornerPin a, CornerPin b, double p)
    {
        static PathPoint L(PathPoint u, PathPoint v, double p) => new(u.X + (v.X - u.X) * p, u.Y + (v.Y - u.Y) * p);
        return new CornerPin(L(a.Tl, b.Tl, p), L(a.Tr, b.Tr, p), L(a.Br, b.Br, p), L(a.Bl, b.Bl, p));
    }

    internal static CornerPin Read(JsonNode? n, string path)
    {
        var r = Reader.Of(n, path);
        PathPoint P(string k) => r.Has(k) ? LayerCodec.ReadPoint(r.Obj[k], $"{path}.{k}") : throw Reader.Fail($"{path}.{k}", "missing required field");
        return new CornerPin(P("tl"), P("tr"), P("br"), P("bl"));
    }

    internal JsonObject ToJson()
    {
        static JsonArray A(PathPoint p) => new(p.X, p.Y);
        return new JsonObject { ["tl"] = A(Tl), ["tr"] = A(Tr), ["br"] = A(Br), ["bl"] = A(Bl) };
    }
}

/// <summary>A handle on the layer: the point at (x, y) (layer px, at rest) moves by (dx, dy). Pins pull the picture
/// around them like After Effects' Puppet tool; pins that do not move hold their part in place.</summary>
public sealed record PuppetPin(double X, double Y, AnimValue Dx, AnimValue Dy)
{
    internal static PuppetPin Read(JsonNode? n, string path)
    {
        var r = Reader.Of(n, path);
        return new PuppetPin(r.Num("x") ?? throw Reader.Fail(path + ".x", "missing required field"),
            r.Num("y") ?? throw Reader.Fail(path + ".y", "missing required field"), r.Anim("dx") ?? 0.0, r.Anim("dy") ?? 0.0);
    }

    internal JsonObject ToJson()
    {
        var o = new JsonObject { ["x"] = X, ["y"] = Y };
        if (Dx != AnimValue.Constant(0)) o["dx"] = SceneJson.Anim(Dx);
        if (Dy != AnimValue.Constant(0)) o["dy"] = SceneJson.Anim(Dy);
        return o;
    }
}

/// <summary>The warp of one layer at one time, mapping layer-local points (around its center) to warped local points:
/// 2.5D rotation with perspective, corner pin and puppet pins. Port of <c>MeshWarp</c> in <c>Mesh.swift</c>.</summary>
public sealed class MeshWarp
{
    public readonly double RotX, RotY, Distance;
    public readonly bool HideBackface;
    /// <summary>Pins at rest and moved (empty unless one moves).</summary>
    public readonly List<(Vector2 P, Vector2 Q)> Pins;
    readonly double[]? _homography;

    MeshWarp(double rotX, double rotY, double distance, bool hideBackface, List<(Vector2, Vector2)> pins, double[]? homography)
    {
        RotX = rotX; RotY = rotY; Distance = distance; HideBackface = hideBackface; Pins = pins; _homography = homography;
    }

    /// <summary>The warp of a layer whose box (what a corner pin maps from) is <paramref name="box"/>, or null.</summary>
    public static MeshWarp? Of(MotionLayer layer, double boxX, double boxY, double boxW, double boxH, double t)
    {
        if (!layer.RotationXYOrPinned) return null;
        var rotX = layer.Value(AnimProperty.RotationX, t);
        var rotY = layer.Value(AnimProperty.RotationY, t);
        var distance = Math.Max(50, layer.Value(AnimProperty.Perspective, t));
        CornerPin? pin = layer.CornerPin?.ValueAt(t, layer.Loop.GetValueOrDefault("cornerPin"));
        var pins = layer.Pins.Select(p => (new Vector2((float)p.X, (float)p.Y),
            new Vector2((float)(p.X + p.Dx.ValueAt(t)), (float)(p.Y + p.Dy.ValueAt(t))))).ToList();
        var rotates = Math.Abs(rotX) > 0.01 || Math.Abs(rotY) > 0.01;
        var pinsMove = pins.Any(p => Vector2.Distance(p.Item1, p.Item2) > 0.01);
        if (!rotates && pin == null && !pinsMove) return null;
        if (!pinsMove) pins = [];
        double[]? h = null;
        if (pin is { } cp && boxW > 0 && boxH > 0)
            h = Homography([new(boxX, boxY), new(boxX + boxW, boxY), new(boxX + boxW, boxY + boxH), new(boxX, boxY + boxH)],
                [cp.Tl, cp.Tr, cp.Br, cp.Bl]);
        return new MeshWarp(rotX, rotY, distance, layer.HideBackface, pins, h);
    }

    /// <summary>Grid cells per side: puppet pins bend more than perspective does.</summary>
    public int Cells => Pins.Count == 0 ? 12 : 20;

    /// <summary>True when the layer is turned away from the viewer.</summary>
    public bool FacesAway => Math.Cos(RotX * Math.PI / 180) * Math.Cos(RotY * Math.PI / 180) < 0;

    bool Rotates => Math.Abs(RotX) > 0.01 || Math.Abs(RotY) > 0.01;

    public PathPoint Map(PathPoint v)
    {
        var p = v;
        if (Pins.Count > 0) p = Mls(p, Pins);
        if (_homography is { } h) p = Apply(h, p);
        if (Rotates)
        {
            var r = Turned(p);
            var s = Distance / Math.Max(Distance + r.Z, Distance * 0.05);
            p = new PathPoint(r.X * s, r.Y * s);
        }
        return p;
    }

    static PathPoint Apply(double[] h, PathPoint p)
    {
        var w = h[6] * p.X + h[7] * p.Y + 1;
        return new PathPoint((h[0] * p.X + h[1] * p.Y + h[2]) / w, (h[3] * p.X + h[4] * p.Y + h[5]) / w);
    }

    /// <summary>Turns a point around the layer's vertical axis (rotationY, + = right side goes back), then its horizontal
    /// one (rotationX, + = top goes back); z is the distance added between the point and the eye.</summary>
    (double X, double Y, double Z) Turned(PathPoint p)
    {
        double a = RotY * Math.PI / 180, b = RotX * Math.PI / 180;
        double x1 = p.X * Math.Cos(a), z1 = p.X * Math.Sin(a);
        return (x1, p.Y * Math.Cos(b) + z1 * Math.Sin(b), -p.Y * Math.Sin(b) + z1 * Math.Cos(b));
    }

    /// <summary>Without puppet pins, rotation + perspective and corner pin are projective, so the whole warp of the box
    /// is the homography through its four corners: [h0…h7] with h8 = 1. Null when there are pins, or when the plane
    /// reaches behind the eye or a crossed corner pin folds it.</summary>
    public double[]? ProjectiveMap(double x, double y, double w, double h)
    {
        if (Pins.Count > 0 || w <= 0 || h <= 0) return null;
        PathPoint[] corners = [new(x, y), new(x + w, y), new(x + w, y + h), new(x, y + h)];
        var pinned = corners.ToArray();
        if (_homography is { } hm)
            for (var i = 0; i < 4; i++)
            {
                var p = corners[i];
                if (hm[6] * p.X + hm[7] * p.Y + 1 <= 1e-6) return null;
                pinned[i] = Apply(hm, p);
            }
        if (Rotates && pinned.Any(p => Distance + Turned(p).Z < Distance * 0.05 + 1e-6)) return null;
        if (Homography(corners, corners.Select(Map).ToArray()) is not { } result) return null;
        foreach (var p in corners)
            if (result[6] * p.X + result[7] * p.Y + 1 <= 1e-6) return null;
        return result;
    }

    // Moving least squares (similarity), Schaefer et al. 2006

    public static PathPoint Mls(PathPoint v, List<(Vector2 P, Vector2 Q)> pins)
    {
        if (pins.Count == 1) return new PathPoint(v.X + pins[0].Q.X - pins[0].P.X, v.Y + pins[0].Q.Y - pins[0].P.Y);
        var ws = new double[pins.Count];
        double sw = 0, psx = 0, psy = 0, qsx = 0, qsy = 0;
        for (var i = 0; i < pins.Count; i++)
        {
            var (p, q) = pins[i];
            var d2 = (p.X - v.X) * (p.X - v.X) + (p.Y - v.Y) * (p.Y - v.Y);
            if (d2 < 1e-6) return new PathPoint(q.X, q.Y);
            var w = 1 / d2;
            ws[i] = w; sw += w;
            psx += w * p.X; psy += w * p.Y;
            qsx += w * q.X; qsy += w * q.Y;
        }
        psx /= sw; psy /= sw; qsx /= sw; qsy /= sw;
        double dx = v.X - psx, dy = v.Y - psy;
        double mu = 0, fx = 0, fy = 0;
        for (var i = 0; i < pins.Count; i++)
        {
            double phx = pins[i].P.X - psx, phy = pins[i].P.Y - psy, qhx = pins[i].Q.X - qsx, qhy = pins[i].Q.Y - qsy;
            mu += ws[i] * (phx * phx + phy * phy);
            // A = w [p̂; -p̂⊥] [d, -d⊥], with (x, y)⊥ = (-y, x).
            double a00 = phx * dx + phy * dy, a01 = phx * dy - phy * dx;
            double a10 = -(phx * dy - phy * dx), a11 = phx * dx + phy * dy;
            fx += ws[i] * (qhx * a00 + qhy * a10);
            fy += ws[i] * (qhx * a01 + qhy * a11);
        }
        if (mu <= 1e-9) return new PathPoint(v.X + qsx - psx, v.Y + qsy - psy);
        return new PathPoint(fx / mu + qsx, fy / mu + qsy);
    }

    /// <summary>Homography from 4 point pairs (h8 = 1), or null when degenerate.</summary>
    public static double[]? Homography(PathPoint[] s, PathPoint[] d)
    {
        var a = new double[8, 9];
        for (var i = 0; i < 4; i++)
        {
            double x = s[i].X, y = s[i].Y, u = d[i].X, v = d[i].Y;
            double[] r0 = [x, y, 1, 0, 0, 0, -u * x, -u * y, u], r1 = [0, 0, 0, x, y, 1, -v * x, -v * y, v];
            for (var k = 0; k < 9; k++) { a[2 * i, k] = r0[k]; a[2 * i + 1, k] = r1[k]; }
        }
        for (var col = 0; col < 8; col++)
        {
            var piv = col;
            for (var r = col + 1; r < 8; r++) if (Math.Abs(a[r, col]) > Math.Abs(a[piv, col])) piv = r;
            if (Math.Abs(a[piv, col]) <= 1e-12) return null;
            for (var k = 0; k < 9; k++) (a[col, k], a[piv, k]) = (a[piv, k], a[col, k]);
            for (var r = 0; r < 8; r++)
            {
                if (r == col) continue;
                var f = a[r, col] / a[col, col];
                if (f != 0) for (var k = col; k < 9; k++) a[r, k] -= f * a[col, k];
            }
        }
        return Enumerable.Range(0, 8).Select(i => a[i, 8] / a[i, i]).ToArray();
    }
}
