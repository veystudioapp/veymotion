using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using VeyMotion.Core;
using Windows.Foundation;
using Windows.UI;

namespace VeyMotion.App.Rendering;

/// <summary>Generator layers: a filled outline (spectrum, waveform, lightning, grid), a noise image, a chart or a lens
/// flare in the layer's box. Port of <c>drawGenerator</c>, <c>drawChart</c> and <c>drawFlare</c> in
/// <c>Renderer.swift</c> and the shapes of <c>Generators.swift</c>.</summary>
static class GeneratorPainter
{
    public static void Draw(CanvasDrawingSession ds, MotionLayer layer, double t)
    {
        var g = layer.Generator;
        double w = Math.Max(layer.Value(AnimProperty.Width, t), 0), h = Math.Max(layer.Value(AnimProperty.Height, t), 0);
        if (w <= 0 || h <= 0) return;
        var box = new Rect(-w / 2, -h / 2, w, h);
        switch (g.Kind)
        {
            case GeneratorKind.Chart: DrawChart(ds, layer, box, t); return;
            case GeneratorKind.Flare: DrawFlare(ds, layer, box); return;
            case GeneratorKind.Noise:
            {
                // About one sample per 3 device pixels: noise is smooth, so it is drawn scaled up with interpolation.
                var scale = Math.Sqrt(Math.Abs(ds.Transform.GetDeterminant()));
                const double step = 3;
                int iw = Math.Clamp((int)Math.Ceiling(w * scale / step), 2, 1024), ih = Math.Clamp((int)Math.Ceiling(h * scale / step), 2, 1024);
                var px = g.NoisePixels(iw, ih, box.X, box.Y, w, h, t, layer.Id);
                using var bmp = CanvasBitmap.CreateFromBytes(ds, px, iw, ih, Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Premultiplied);
                ds.DrawImage(bmp, box, bmp.Bounds, 1, CanvasImageInterpolation.HighQualityCubic);
                ds.Flush(); // the bitmap is disposed next
                return;
            }
        }
        var width = layer.Value(AnimProperty.StrokeWidth, t);
        var line = width > 0 ? width : (g.Kind == GeneratorKind.Grid ? 2 : 4);
        using var path = Outline(ds, layer, g, box, t, line, Math.Max(0, layer.Value(AnimProperty.CornerRadius, t)));
        if (path == null) return;
        if (layer.Gradient is { } grad)
        {
            using var brush = ContentPainter.GradientBrush(ds, grad, box, t);
            ds.FillGeometry(path, brush);
        }
        else if (layer.ColorAt(ColorProperty.Fill, t) is { A: > 0 } fill) ds.FillGeometry(path, FrameCompositor.ToColor(fill));
    }

    static readonly CanvasStrokeStyle RoundStroke = new() { StartCap = CanvasCapStyle.Round, EndCap = CanvasCapStyle.Round, LineJoin = CanvasLineJoin.Round };

    /// <summary>The filled outline of a spectrum, waveform, lightning or grid in the box (layer px).</summary>
    static CanvasGeometry? Outline(ICanvasResourceCreator rc, MotionLayer layer, Generator g, Rect box, double t, double line, double radius)
    {
        var parts = new List<CanvasGeometry>();
        try
        {
            switch (g.Kind)
            {
                case GeneratorKind.Spectrum or GeneratorKind.Waveform:
                {
                    var v = g.AudioValues(t).Select(x => Math.Clamp(x * g.GainValue, 0, 1.5)).ToArray();
                    AudioShapes(rc, g, v, box, line, radius, parts);
                    break;
                }
                case GeneratorKind.Lightning:
                    foreach (var (pts, lw) in g.Lightning(box.X, box.Y, box.Width, box.Height, t, line, Noise.Hash(layer.Id)))
                    {
                        using var poly = Polyline(rc, pts);
                        parts.Add(poly.Stroke((float)lw, RoundStroke));
                    }
                    break;
                case GeneratorKind.Grid:
                {
                    var cell = g.ScaleValue;
                    var shift = g.SpeedValue * t % cell;
                    if (shift < 0) shift += cell;
                    for (var x = box.X + shift; x <= box.Right; x += cell)
                        parts.Add(CanvasGeometry.CreateRectangle(rc, (float)(x - line / 2), (float)box.Y, (float)line, (float)box.Height));
                    for (var y = box.Y + shift; y <= box.Bottom; y += cell)
                        parts.Add(CanvasGeometry.CreateRectangle(rc, (float)box.X, (float)(y - line / 2), (float)box.Width, (float)line));
                    break;
                }
            }
            return parts.Count == 0 ? null : CanvasGeometry.CreateGroup(rc, [.. parts], CanvasFilledRegionDetermination.Winding);
        }
        finally
        {
            foreach (var p in parts) p.Dispose();
        }
    }

    static void AudioShapes(ICanvasResourceCreator rc, Generator g, double[] v, Rect box, double line, double radius, List<CanvasGeometry> parts)
    {
        var n = v.Length;
        if (n == 0) return;
        switch (g.ShapeValue)
        {
            case GeneratorShape.Bars:
            {
                double slot = box.Width / n, bw = Math.Max(1, slot * 0.7);
                for (var i = 0; i < n; i++)
                {
                    var hgt = Math.Max(bw * 0.5, v[i] * box.Height);
                    var cx = box.X + slot * (i + 0.5);
                    var y = g.MirrorValue ? box.Y + box.Height / 2 - hgt / 2 : box.Bottom - hgt;
                    var cr = (float)Math.Min(radius, Math.Min(bw / 2, hgt / 2));
                    parts.Add(CanvasGeometry.CreateRoundedRectangle(rc, (float)(cx - bw / 2), (float)y, (float)bw, (float)hgt, cr, cr));
                }
                break;
            }
            case GeneratorShape.Line:
            {
                var midY = box.Y + box.Height / 2;
                var pts = v.Select((x, i) => new Vector2(
                    (float)(box.X + box.Width * (n == 1 ? 0.5 : (double)i / (n - 1))),
                    (float)(g.MirrorValue ? midY - x * box.Height / 2 : box.Bottom - x * box.Height))).ToList();
                using var b = new CanvasPathBuilder(rc);
                Smooth(b, pts);
                // The same curve flipped below the middle, as one band.
                if (g.MirrorValue) Smooth(b, pts.AsEnumerable().Reverse().Select(p => new Vector2(p.X, (float)(2 * midY - p.Y))).ToList());
                using var curve = CanvasGeometry.CreatePath(b);
                parts.Add(curve.Stroke((float)line, RoundStroke));
                break;
            }
            case GeneratorShape.Circle:
            {
                var c = new Vector2((float)(box.X + box.Width / 2), (float)(box.Y + box.Height / 2));
                double inner = Math.Min(box.Width, box.Height) / 4, reach = inner;
                var bw = Math.Max(1, 2 * Math.PI * inner / n * 0.6);
                for (var i = 0; i < n; i++)
                {
                    var a = 2 * Math.PI * i / n - Math.PI / 2;
                    var len = Math.Max(bw, v[i] * reach);
                    var cr = (float)Math.Min(radius, bw / 2);
                    using var bar = CanvasGeometry.CreateRoundedRectangle(rc, (float)(-bw / 2), (float)(-inner - len), (float)bw, (float)len, cr, cr);
                    parts.Add(bar.Transform(Matrix3x2.CreateRotation((float)(a + Math.PI / 2)) * Matrix3x2.CreateTranslation(c)));
                }
                break;
            }
        }
    }

    static CanvasGeometry Polyline(ICanvasResourceCreator rc, List<Vector2> pts)
    {
        using var b = new CanvasPathBuilder(rc);
        b.BeginFigure(pts[0]);
        foreach (var p in pts.Skip(1)) b.AddLine(p);
        b.EndFigure(CanvasFigureLoop.Open);
        return CanvasGeometry.CreatePath(b);
    }

    /// <summary>A Catmull-Rom curve through the points, as an open figure.</summary>
    static void Smooth(CanvasPathBuilder b, List<Vector2> pts)
    {
        if (pts.Count == 0) return;
        b.BeginFigure(pts[0]);
        if (pts.Count <= 2) foreach (var p in pts.Skip(1)) b.AddLine(p);
        else
            for (var i = 0; i < pts.Count - 1; i++)
            {
                Vector2 p0 = pts[Math.Max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[Math.Min(i + 2, pts.Count - 1)];
                b.AddCubicBezier(p1 + (p2 - p0) / 6, p2 - (p3 - p1) / 6, p2);
            }
        b.EndFigure(CanvasFigureLoop.Open);
    }

    /// <summary>Bar, line, area, pie or donut chart in the box; reveal grows it in. Series colors come from the
    /// generator's colors (else the fill); labels use the layer's font and text color.</summary>
    static void DrawChart(CanvasDrawingSession ds, MotionLayer layer, Rect box, double t)
    {
        var g = layer.Generator;
        var values = g.ValuesValue;
        var n = values.Count;
        if (n == 0) return;
        var reveal = Math.Clamp(layer.Value(AnimProperty.Reveal, t), 0, 1);
        var colors = g.Colors ?? [layer.ColorAt(ColorProperty.Fill, t) ?? Rgba.White];
        Rgba ColorOf(int i) => layer.Gradient is { } grad ? grad.Stops[Math.Min(i, grad.Stops.Count - 1)].Color : colors[i % colors.Count];
        var labels = g.Labels ?? [];
        var labelColor = FrameCompositor.ToColor(layer.ColorAt(ColorProperty.Color, t) ?? Rgba.White);
        var fontSize = layer.FontSize;
        var labelH = labels.Count == 0 ? 0 : fontSize * 1.4;
        var maxV = Math.Max(values.Max(), 1e-9);
        var (weight, italic) = ContentPainter.ParseWeight(layer.FontWeight);
        using var format = new CanvasTextFormat
        {
            FontFamily = layer.FontName ?? "Segoe UI Variable Display", FontSize = (float)Math.Max(1, fontSize),
            FontWeight = new Windows.UI.Text.FontWeight { Weight = weight },
            FontStyle = italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
            WordWrapping = CanvasWordWrapping.NoWrap,
        };
        // The label's baseline at p, centered on its x.
        void Label(string s, double x, double y)
        {
            using var tl = new CanvasTextLayout(ds, s, format, 100_000, 100_000);
            var baseline = tl.LineMetrics.Length > 0 ? tl.LineMetrics[0].Baseline : (float)fontSize * 0.8f;
            ds.DrawTextLayout(tl, (float)(x - tl.LayoutBounds.Width / 2), (float)y - baseline, labelColor);
        }
        switch (g.ChartValue)
        {
            case ChartType.Bar:
            {
                var plot = new Rect(box.X, box.Y, box.Width, Math.Max(0, box.Height - labelH));
                double slot = plot.Width / n, bw = slot * 0.64;
                var r = Math.Max(0, layer.Value(AnimProperty.CornerRadius, t));
                for (var i = 0; i < n; i++)
                {
                    // Bars grow one after another, overlapping a little.
                    var k = Math.Clamp(reveal * n * 0.7 - i * 0.7 + 0.3, 0, 1);
                    var ease = 1 - Math.Pow(1 - k, 3);
                    var hgt = Math.Max(0, values[i] / maxV) * plot.Height * ease;
                    var x = plot.X + slot * (i + 0.5);
                    if (hgt > 0)
                    {
                        var cr = (float)Math.Min(r, Math.Min(bw / 2, hgt / 2));
                        ds.FillRoundedRectangle(new Rect(x - bw / 2, plot.Bottom - hgt, bw, hgt), cr, cr, FrameCompositor.ToColor(ColorOf(i)));
                    }
                    if (i < labels.Count) Label(labels[i], x, box.Bottom - fontSize * 0.25);
                }
                break;
            }
            case ChartType.Line or ChartType.Area:
            {
                var plotH = Math.Max(0, box.Height - labelH - 8);
                double plotTop = box.Y + 4, plotBottom = plotTop + plotH;
                var pts = values.Select((v, i) => new Vector2(
                    (float)(box.X + box.Width * (n == 1 ? 0.5 : (double)i / (n - 1))),
                    (float)(plotBottom - Math.Max(0, v / maxV) * plotH))).ToList();
                var lw = layer.Value(AnimProperty.StrokeWidth, t);
                var strokeW = lw > 0 ? lw : 6;
                var main = ColorOf(0);
                // Drawn on from the left.
                using (ds.CreateLayer(1, new Rect(box.X - 10, box.Y - 10, (box.Width + 20) * reveal, box.Height + 20)))
                {
                    using var b = new CanvasPathBuilder(ds);
                    Smooth(b, pts);
                    using var curve = CanvasGeometry.CreatePath(b);
                    if (g.ChartValue == ChartType.Area)
                    {
                        using var ab = new CanvasPathBuilder(ds);
                        ab.BeginFigure(pts[0]);
                        if (pts.Count <= 2) foreach (var p in pts.Skip(1)) ab.AddLine(p);
                        else
                            for (var i = 0; i < pts.Count - 1; i++)
                            {
                                Vector2 p0 = pts[Math.Max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[Math.Min(i + 2, pts.Count - 1)];
                                ab.AddCubicBezier(p1 + (p2 - p0) / 6, p2 - (p3 - p1) / 6, p2);
                            }
                        ab.AddLine(new Vector2(pts[^1].X, (float)plotBottom));
                        ab.AddLine(new Vector2(pts[0].X, (float)plotBottom));
                        ab.EndFigure(CanvasFigureLoop.Closed);
                        using var area = CanvasGeometry.CreatePath(ab);
                        ds.FillGeometry(area, FrameCompositor.ToColor(main with { A = main.A * 0.3 }));
                    }
                    ds.DrawGeometry(curve, FrameCompositor.ToColor(main), (float)strokeW, RoundStroke);
                    var dot = (float)Math.Max(3, strokeW * 0.9);
                    foreach (var p in pts) ds.FillEllipse(p, dot, dot, FrameCompositor.ToColor(main));
                }
                for (var i = 0; i < pts.Count && i < labels.Count; i++) Label(labels[i], pts[i].X, box.Bottom - fontSize * 0.25);
                break;
            }
            case ChartType.Pie or ChartType.Donut:
            {
                var total = Math.Max(values.Sum(), 1e-9);
                var c = new Vector2((float)(box.X + box.Width / 2), (float)(box.Y + box.Height / 2));
                var radius = Math.Min(box.Width, box.Height) / 2 - (labels.Count == 0 ? 0 : fontSize * 1.2);
                var inner = g.ChartValue == ChartType.Donut ? radius * 0.55 : 0;
                var a0 = -Math.PI / 2;
                var sweepAll = 2 * Math.PI * reveal;
                var used = 0.0;
                for (var i = 0; i < n; i++)
                {
                    var sweep = values[i] / total * 2 * Math.PI;
                    var shown = Math.Min(sweep, Math.Max(0, sweepAll - used));
                    used += sweep;
                    if (shown > 0 && radius > 0)
                    {
                        using var b = new CanvasPathBuilder(ds);
                        var start = c + new Vector2((float)(Math.Cos(a0) * radius), (float)(Math.Sin(a0) * radius));
                        b.BeginFigure(inner > 0 ? start : c);
                        b.AddArc(c, (float)radius, (float)radius, (float)a0, (float)shown);
                        if (inner > 0) b.AddArc(c, (float)inner, (float)inner, (float)(a0 + shown), (float)-shown);
                        b.EndFigure(CanvasFigureLoop.Closed);
                        using var slice = CanvasGeometry.CreatePath(b);
                        ds.FillGeometry(slice, FrameCompositor.ToColor(ColorOf(i)));
                    }
                    if (i < labels.Count && (reveal > 0.999 || used <= sweepAll))
                    {
                        double mid = a0 + sweep / 2, lr = radius + fontSize * 0.7;
                        Label(labels[i], c.X + Math.Cos(mid) * lr, c.Y + Math.Sin(mid) * lr + fontSize * 0.35);
                    }
                    a0 += sweep;
                }
                break;
            }
        }
    }

    /// <summary>Lens flare: a bright source at from (default the box center) with a halo and ghost discs mirrored
    /// across the center of the box, all adding light.</summary>
    static void DrawFlare(CanvasDrawingSession ds, MotionLayer layer, Rect box)
    {
        var g = layer.Generator;
        var c = new Vector2((float)(box.X + box.Width / 2), (float)(box.Y + box.Height / 2));
        var src = g.From is { } f ? new Vector2((float)f.X, (float)f.Y) : c;
        var colors = g.ColorsValue;
        var core = colors.Count > 0 ? colors[0] : Rgba.White;
        var ghost = colors.Count > 1 ? colors[1] : new Rgba(0.6, 0.8, 1, 1);
        var size = g.Scale ?? Math.Min(box.Width, box.Height) * 0.25;
        var strength = g.GainValue;
        void Radial(Rgba color, Vector2 p, double radius, double alpha, double hollow = 0)
        {
            if (radius <= 0) return;
            var a = FrameCompositor.ToColor(color with { A = color.A * alpha });
            var clear = FrameCompositor.ToColor(color with { A = 0 });
            CanvasGradientStop[] stops = hollow > 0
                // A ring: clear inside, peaking at hollow of the radius, clear at the edge.
                ? [new() { Position = 0, Color = clear }, new() { Position = (float)Math.Max(0, hollow - 0.12), Color = clear },
                   new() { Position = (float)hollow, Color = a }, new() { Position = 1, Color = clear }]
                : [new() { Position = 0, Color = a }, new() { Position = 1, Color = clear }];
            using var brush = new CanvasRadialGradientBrush(ds, stops) { Center = p, RadiusX = (float)radius, RadiusY = (float)radius };
            ds.FillEllipse(p, (float)radius, (float)radius, brush);
        }
        var blend = ds.Blend;
        ds.Blend = CanvasBlend.Add;
        // Core and glow.
        Radial(core, src, size * 0.35, Math.Min(1, strength));
        Radial(core, src, size * 1.6, 0.35 * strength);
        // Streak across the source.
        var saved = ds.Transform;
        ds.Transform = Matrix3x2.CreateScale(1, 0.06f) * Matrix3x2.CreateTranslation(src) * saved;
        Radial(core, Vector2.Zero, size * 4, 0.6 * strength);
        ds.Transform = saved;
        // Ghosts along the line through the center, on the far side.
        var salt = Noise.Mix(Noise.Hash($"flare.{layer.Id}") ^ unchecked((ulong)g.SeedValue));
        var count = g.Detail ?? 5;
        for (var i = 0; i < count; i++)
        {
            var k = -0.3 - i * (1.3 / Math.Max(count, 1)) - Noise.Unit(i, salt) * 0.15;
            var p = c + (src - c) * (float)k;
            var r = size * (0.15 + Noise.Unit(i + 50, salt) * 0.5);
            Radial(ghost, p, r, 0.25 * strength, i % 2 == 0 ? 0 : 0.75);
        }
        // Big faint ring around the center (an anamorphic halo).
        Radial(ghost, c, Vector2.Distance(src, c) + size, 0.18 * strength, 0.92);
        ds.Blend = blend;
    }
}
