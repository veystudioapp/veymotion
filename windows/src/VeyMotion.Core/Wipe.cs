using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

using MotionKeyframe = Keyframe<double>;

public enum WipeType { Linear, Radial, Iris, Blinds, Blocks }

/// <summary>How the wipe property hides the layer: 0 = whole layer shows, 1 = all of it is wiped away.
/// Port of <c>WipeStyle</c> in <c>Effects.swift</c>.</summary>
public sealed record WipeStyle(WipeType Type = WipeType.Linear, double Angle = 0, double Feather = 0, int Count = 8,
    bool Reverse = false, long Seed = 0)
{
    /// <summary>The part of the layer that still shows at wipe progress (0…1), in layer coordinates, for an even-odd
    /// fill; null when nothing shows. The region reaches far beyond the box so shadows and glows are not cut off.</summary>
    public PathShape? VisibleRegion(double progress, double boxX, double boxY, double boxW, double boxH)
    {
        var p = Math.Clamp(progress, 0, 1);
        if (!(p < 1 - 1e-6) || !(boxW > 0 || boxH > 0)) return null;
        var far = 4 * Math.Max(boxW, boxH) + 4 * Feather + 10_000;
        double cx = boxX + boxW / 2, cy = boxY + boxH / 2;
        var figures = new List<Subpath>();
        var a = Angle * Math.PI / 180;
        double ux = Math.Cos(a), uy = Math.Sin(a), vx = -uy, vy = ux;
        (double Lo, double Hi) Span()
        {
            double[] d = [boxX * ux + boxY * uy, (boxX + boxW) * ux + boxY * uy, boxX * ux + (boxY + boxH) * uy, (boxX + boxW) * ux + (boxY + boxH) * uy];
            return (d.Min(), d.Max());
        }
        void Polygon(params PathPoint[] pts)
        {
            var segs = Enumerable.Range(0, pts.Length).Select(i => CubicSegment.Line(pts[i], pts[(i + 1) % pts.Length])).ToList();
            figures.Add(new Subpath(pts[0], segs, true));
        }
        // The band between from and to along u, as wide as far across.
        void Band(double from, double to)
        {
            if (!(to > from)) return;
            PathPoint Pt(double s, double w) => new(ux * s + vx * w, uy * s + vy * w);
            Polygon(Pt(from, -far), Pt(to, -far), Pt(to, far), Pt(from, far));
        }
        void Rect(double x, double y, double w, double h) => Polygon(new(x, y), new(x + w, y), new(x + w, y + h), new(x, y + h));
        void Circle(double r) => figures.Add(Offset(PathParser.Ellipse(r, r)[0], cx, cy));

        switch (Type)
        {
            case WipeType.Linear:
            {
                // The edge starts and ends a feather beyond the box, so 0 and 1 show and hide all of it.
                var (lo, hi) = Span();
                Band(lo - Feather + p * (hi - lo + 2 * Feather), hi + far);
                break;
            }
            case WipeType.Blinds:
            {
                var (lo, hi) = Span();
                var n = Math.Max(Count, 1);
                var w = (hi - lo) / n;
                // Each stripe closes from its leading side; the ends stay open so nothing beyond the box is cut.
                Band(lo - far, lo);
                for (var k = 0; k < n; k++)
                {
                    var s = lo + k * w;
                    Band(s + p * w, s + w);
                }
                Band(hi, hi + far);
                break;
            }
            case WipeType.Radial:
            {
                // The hidden sector grows clockwise from angle (counter-clockwise when reversed); 12 o'clock is -90°.
                var zero = (Angle - 90) * Math.PI / 180;
                var sweep = 2 * Math.PI * (1 - p);
                var from = Reverse ? zero : zero + 2 * Math.PI * p;
                var steps = Math.Max(2, (int)(sweep / (2 * Math.PI) * 180));
                var pts = new List<PathPoint> { new(cx, cy) };
                for (var k = 0; k <= steps; k++)
                {
                    var aa = from + sweep * k / steps;
                    pts.Add(new PathPoint(cx + far * Math.Cos(aa), cy + far * Math.Sin(aa)));
                }
                Polygon([.. pts]);
                break;
            }
            case WipeType.Iris:
            {
                var rmax = Math.Sqrt(boxW * boxW + boxH * boxH) / 2 + Feather;
                if (Reverse)
                {
                    var r = p * rmax;
                    Rect(cx - far, cy - far, 2 * far, 2 * far);
                    if (r > 0) Circle(r);
                }
                else
                {
                    var r = (1 - p) * rmax;
                    if (r <= 0) return null;
                    Circle(r);
                }
                break;
            }
            case WipeType.Blocks:
            {
                var n = Math.Max(Count, 1);
                var size = Math.Max(boxW, boxH) / n;
                if (size <= 0) return null;
                int cols = Math.Max(1, (int)Math.Ceiling(boxW / size)), rows = Math.Max(1, (int)Math.Ceiling(boxH / size));
                var salt = Noise.Mix(unchecked((ulong)Seed + 0x5EED));
                // Blocks centered on the box; each drops out once progress passes its random threshold.
                double ox = cx - cols * size / 2, oy = cy - rows * size / 2;
                for (var r = 0; r < rows; r++)
                    for (var c = 0; c < cols; c++)
                        if (Noise.Unit(r * 7919 + c, salt) >= p) Rect(ox + c * size, oy + r * size, size, size);
                if (figures.Count == 0) return null;
                break;
            }
        }
        return new PathShape(figures);
    }

    static Subpath Offset(Subpath s, double dx, double dy)
    {
        PathPoint M(PathPoint p) => new(p.X + dx, p.Y + dy);
        return new Subpath(M(s.Start), s.Segments.Select(g => new CubicSegment(M(g.C1), M(g.C2), M(g.P))).ToList(), s.Closed);
    }

    // JSON: a bare type name ("iris") or {type, angle, feather, count (1…200), reverse, seed}; only non-defaults written.

    internal static WipeStyle Decode(JsonNode? n, string path)
    {
        if (n is JsonValue v && v.GetValueKind() == JsonValueKind.String)
            return new WipeStyle(JsonName<WipeType>.Parse(v.GetValue<string>())
                ?? throw Reader.Fail(path, $"Cannot initialize WipeType from invalid String value {v.GetValue<string>()}"));
        var r = Reader.Of(n, path);
        return new WipeStyle(r.Enum<WipeType>("type") ?? WipeType.Linear, r.Num("angle") ?? 0, Math.Max(0, r.Num("feather") ?? 0),
            Math.Clamp(r.Int("count") ?? 8, 1, 200), r.Bool("reverse") ?? false, (long)(r.Num("seed") ?? 0));
    }

    internal JsonObject Encode()
    {
        var o = new JsonObject { ["type"] = Type.Json() };
        if (Angle != 0) o["angle"] = Angle;
        if (Feather != 0) o["feather"] = Feather;
        if (Count != 8 && Type is WipeType.Blinds or WipeType.Blocks) o["count"] = Count;
        if (Reverse) o["reverse"] = true;
        if (Seed != 0) o["seed"] = Seed;
        return o;
    }
}

public enum TransitionType { Fade, Dissolve, Push, Slide, Zoom, Whip, Wipe, Iris, Blinds, Blocks, Clock, Glitch, Flash, Blur }

public static class TransitionOps
{
    /// <summary>Animates out away and in in over [at, at + d]; the outgoing layer ends and the incoming one starts there.
    /// direction (left|right|up|down) is where the motion goes for push/slide/whip/wipe. Port of <c>transition</c> in
    /// <c>SceneOps.swift</c>.</summary>
    public static void Transition(this MotionScene scene, TransitionType type, string? outId, string? inId, double s, double d, string? direction)
    {
        if (!(d > 0)) throw new SceneException("duration must be > 0");
        if (outId == null && inId == null) throw new SceneException("Give `out` and/or `in` layer ids");
        double e = s + d, mid = s + d / 2;
        var dir = direction ?? "left";
        double dx = dir == "left" ? -1 : dir == "right" ? 1 : 0, dy = dir == "up" ? -1 : dir == "down" ? 1 : 0;
        double w = scene.Width, h = scene.Height;
        double wipeAngle = dir == "right" ? 0 : dir == "down" ? 90 : dir == "up" ? 270 : 180;
        static MotionKeyframe K(double t, double v, Easing? easing = null) => new(t, v, easing ?? Easing.EaseInOut);
        static void Put(MotionLayer l, AnimProperty p, params MotionKeyframe[] kfs) => l[p] = l[p].Inserting(kfs, kfs[0].T, kfs[^1].T);
        WipeStyle Style(WipeType t) => new(t, wipeAngle, t == WipeType.Linear ? 60 : 20, t == WipeType.Blocks ? 14 : t == WipeType.Blinds ? 8 : 8);
        static WipeType WipeFor(TransitionType t) => t switch
        {
            TransitionType.Wipe => WipeType.Linear, TransitionType.Iris => WipeType.Iris, TransitionType.Blinds => WipeType.Blinds,
            TransitionType.Blocks => WipeType.Blocks, _ => WipeType.Radial,
        };
        var cubicInOut = Easing.Named(EaseCurve.Cubic, EaseMode.InOut);
        var expoIn = Easing.Named(EaseCurve.Expo, EaseMode.In);
        var expoOut = Easing.Named(EaseCurve.Expo, EaseMode.Out);

        if (outId != null)
        {
            scene.WithLayer(outId, l =>
            {
                double x0 = l.X.ValueAt(s), y0 = l.Y.ValueAt(s), sc = l.Scale.ValueAt(s), op = l.Opacity.ValueAt(s);
                switch (type)
                {
                    case TransitionType.Fade or TransitionType.Flash:
                        Put(l, AnimProperty.Opacity, K(s, op, Easing.Linear), K(type == TransitionType.Flash ? mid : e, 0, Easing.EaseIn));
                        break;
                    case TransitionType.Dissolve:
                        l.WipeStyle = Style(WipeType.Blocks) with { Count = 40 };
                        Put(l, AnimProperty.Wipe, K(s, 0, Easing.Linear), K(e, 1, Easing.Linear));
                        break;
                    case TransitionType.Push or TransitionType.Slide:
                        Put(l, AnimProperty.X, K(s, x0, Easing.Linear), K(e, x0 + dx * w, cubicInOut));
                        Put(l, AnimProperty.Y, K(s, y0, Easing.Linear), K(e, y0 + dy * h, cubicInOut));
                        if (type == TransitionType.Slide) Put(l, AnimProperty.Opacity, K(s + d * 0.4, op, Easing.Linear), K(e, 0, Easing.EaseIn));
                        break;
                    case TransitionType.Zoom:
                        Put(l, AnimProperty.Scale, K(s, sc, Easing.Linear), K(e, sc * 3, expoIn));
                        Put(l, AnimProperty.Opacity, K(s + d * 0.3, op, Easing.Linear), K(e, 0, Easing.EaseIn));
                        Put(l, AnimProperty.ZoomBlur, K(s, 0, Easing.Linear), K(e, 0.6, Easing.EaseIn));
                        break;
                    case TransitionType.Whip:
                        Put(l, AnimProperty.X, K(s, x0, Easing.Linear), K(mid, x0 + dx * w * 1.2, expoIn));
                        Put(l, AnimProperty.Y, K(s, y0, Easing.Linear), K(mid, y0 + dy * h * 1.2, expoIn));
                        Put(l, AnimProperty.DirectionalBlur, K(s, 0, Easing.Linear), K(mid, 160, Easing.EaseIn));
                        l[AnimProperty.BlurAngle] = dy != 0 ? 90.0 : 0.0;
                        break;
                    case TransitionType.Wipe or TransitionType.Iris or TransitionType.Blinds or TransitionType.Blocks or TransitionType.Clock:
                        l.WipeStyle = Style(WipeFor(type));
                        Put(l, AnimProperty.Wipe, K(s, 0, Easing.Linear), K(e, 1, cubicInOut));
                        break;
                    case TransitionType.Glitch:
                        Put(l, AnimProperty.Glitch, K(s, 0, Easing.Linear), K(s + d * 0.1, 0.9, Easing.Hold), K(mid, 1, Easing.Hold));
                        Put(l, AnimProperty.RgbSplit, K(s, 0, Easing.Linear), K(s + d * 0.1, 10, Easing.Hold));
                        Put(l, AnimProperty.Opacity, K(mid - 0.01, op, Easing.Linear), K(mid, 0, Easing.Hold));
                        break;
                    case TransitionType.Blur:
                        Put(l, AnimProperty.Blur, K(s, 0, Easing.Linear), K(e, 50, Easing.EaseIn));
                        Put(l, AnimProperty.Opacity, K(s + d * 0.3, op, Easing.Linear), K(e, 0, Easing.EaseIn));
                        break;
                }
                if (l.End == null || l.End > e)
                    l.End = type is TransitionType.Whip or TransitionType.Glitch or TransitionType.Flash ? mid + 0.02 : e;
            });
        }
        if (inId != null)
        {
            scene.WithLayer(inId, l =>
            {
                if (l.Start > s) l.Start = s;
                double x1 = l.X.ValueAt(e), y1 = l.Y.ValueAt(e), sc = l.Scale.ValueAt(e);
                var op = Math.Max(l.Opacity.ValueAt(e), 0.01);
                switch (type)
                {
                    case TransitionType.Fade:
                        Put(l, AnimProperty.Opacity, K(s, 0, Easing.Linear), K(e, op, Easing.EaseOut));
                        break;
                    case TransitionType.Flash:
                        Put(l, AnimProperty.Opacity, K(mid, 0, Easing.Linear), K(e, op, Easing.EaseOut));
                        break;
                    case TransitionType.Dissolve:
                        l.WipeStyle = Style(WipeType.Blocks) with { Count = 40 };
                        Put(l, AnimProperty.Wipe, K(s, 1, Easing.Linear), K(e, 0, Easing.Linear));
                        break;
                    case TransitionType.Push:
                        Put(l, AnimProperty.X, K(s, x1 - dx * w, Easing.Linear), K(e, x1, cubicInOut));
                        Put(l, AnimProperty.Y, K(s, y1 - dy * h, Easing.Linear), K(e, y1, cubicInOut));
                        break;
                    case TransitionType.Slide:
                        Put(l, AnimProperty.X, K(s, x1 - dx * w * 0.3, Easing.Linear), K(e, x1, expoOut));
                        Put(l, AnimProperty.Y, K(s, y1 - dy * h * 0.3, Easing.Linear), K(e, y1, expoOut));
                        Put(l, AnimProperty.Opacity, K(s, 0, Easing.Linear), K(s + d * 0.6, op, Easing.EaseOut));
                        break;
                    case TransitionType.Zoom:
                        Put(l, AnimProperty.Scale, K(s, sc * 0.4, Easing.Linear), K(e, sc, expoOut));
                        Put(l, AnimProperty.Opacity, K(s, 0, Easing.Linear), K(s + d * 0.5, op, Easing.EaseOut));
                        Put(l, AnimProperty.ZoomBlur, K(s, 0.5, Easing.Linear), K(e, 0, Easing.EaseOut));
                        break;
                    case TransitionType.Whip:
                        Put(l, AnimProperty.X, K(mid, x1 - dx * w * 1.2, Easing.Linear), K(e, x1, expoOut));
                        Put(l, AnimProperty.Y, K(mid, y1 - dy * h * 1.2, Easing.Linear), K(e, y1, expoOut));
                        Put(l, AnimProperty.DirectionalBlur, K(mid, 160, Easing.Linear), K(e, 0, Easing.EaseOut));
                        l[AnimProperty.BlurAngle] = dy != 0 ? 90.0 : 0.0;
                        if (l.Start > mid - 0.02 || l.Start == s) l.Start = Math.Min(l.Start, mid - 0.02);
                        break;
                    case TransitionType.Wipe or TransitionType.Iris or TransitionType.Blinds or TransitionType.Blocks or TransitionType.Clock:
                    {
                        var wt = WipeFor(type);
                        l.WipeStyle = Style(wt) with { Reverse = false };
                        Put(l, AnimProperty.Wipe, K(s, 1, Easing.Linear), K(e, 0, cubicInOut));
                        break;
                    }
                    case TransitionType.Glitch:
                        Put(l, AnimProperty.Opacity, K(mid - 0.01, 0, Easing.Linear), K(mid, op, Easing.Hold));
                        Put(l, AnimProperty.Glitch, K(mid, 1, Easing.Linear), K(mid + d * 0.3, 0.5, Easing.Hold), K(e, 0, Easing.Hold));
                        Put(l, AnimProperty.RgbSplit, K(mid, 10, Easing.Linear), K(e, 0, Easing.Hold));
                        break;
                    case TransitionType.Blur:
                        Put(l, AnimProperty.Blur, K(s, 50, Easing.Linear), K(e, 0, Easing.EaseOut));
                        Put(l, AnimProperty.Opacity, K(s, 0, Easing.Linear), K(s + d * 0.7, op, Easing.EaseOut));
                        break;
                }
            });
        }
        if (type == TransitionType.Flash)
        {
            var f = new MotionLayer(LayerType.Rect, "flash", "Flash", w / 2, h / 2)
            {
                Width = w, Height = h, Fill = Rgba.White, Start = s, End = e,
                Opacity = Animated<double>.Keyframes([K(s, 0, Easing.Linear), K(mid, 1, Easing.EaseIn), K(e, 0, Easing.EaseOut)]),
            };
            scene.AddLayer(f);
        }
    }
}
