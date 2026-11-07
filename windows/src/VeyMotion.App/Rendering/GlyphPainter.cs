using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using VeyMotion.Core;
using Windows.UI;

namespace VeyMotion.App.Rendering;

/// <summary>
/// Text drawn glyph by glyph: text animators (each character, word or line moves on its own) and text laid along
/// <c>textPath</c>. Port of <c>drawAnimatedGlyphs</c>, <c>drawGlyph</c> and <c>drawTextOnPath</c> in
/// <c>Renderer.swift</c>. DirectWrite hands the laid-out glyph runs to <see cref="Collector"/>, the CTRun equivalent.
/// </summary>
static class GlyphPainter
{
    /// <summary>One laid-out glyph. <c>Pen</c> is where it is drawn alone (baseline, layer px).</summary>
    readonly record struct Glyph(Vector2 Pen, float Advance, bool Rtl, CanvasGlyph Value, CanvasFontFace Face, float Size,
        bool Sideways, uint Bidi, int Index, int Line)
    {
        public float CenterX => Pen.X + (Rtl ? -Advance : Advance) / 2;
        public float MinX => Rtl ? Pen.X - Advance : Pen.X;
        public float MaxX => Rtl ? Pen.X : Pen.X + Advance;
    }

    sealed class Collector(int[] lineStarts) : ICanvasTextRenderer
    {
        public readonly List<Glyph> Glyphs = [];

        public void DrawGlyphRun(Vector2 point, CanvasFontFace fontFace, float fontSize, CanvasGlyph[] glyphs, bool isSideways,
            uint bidiLevel, object brush, CanvasTextMeasuringMode measuringMode, string localeName, string textString,
            int[] clusterMapIndices, uint characterIndex, CanvasGlyphOrientation glyphOrientation)
        {
            // The first character of each glyph's cluster.
            var glyphChar = new int[glyphs.Length];
            Array.Fill(glyphChar, -1);
            for (var i = 0; i < clusterMapIndices.Length; i++)
                if (clusterMapIndices[i] < glyphs.Length && glyphChar[clusterMapIndices[i]] < 0) glyphChar[clusterMapIndices[i]] = i;
            var rtl = (bidiLevel & 1) == 1;
            var pen = point.X;
            for (var g = 0; g < glyphs.Length; g++)
            {
                if (glyphChar[g] < 0) glyphChar[g] = g > 0 ? glyphChar[g - 1] : 0;
                var index = (int)characterIndex + glyphChar[g];
                var line = Array.BinarySearch(lineStarts, index);
                if (line < 0) line = ~line - 1;
                var adv = glyphs[g].Advance;
                Glyphs.Add(new Glyph(new Vector2(pen, point.Y), adv, rtl, glyphs[g], fontFace, fontSize, isSideways, bidiLevel,
                    index, Math.Max(line, 0)));
                pen += rtl ? -adv : adv;
            }
        }

        public void DrawStrikethrough(Vector2 point, float strikethroughWidth, float strikethroughThickness, float strikethroughOffset,
            CanvasTextDirection textDirection, object brush, CanvasTextMeasuringMode textMeasuringMode, string localeName,
            CanvasGlyphOrientation glyphOrientation) { }

        public void DrawUnderline(Vector2 point, float underlineWidth, float underlineThickness, float underlineOffset,
            float runHeight, CanvasTextDirection textDirection, object brush, CanvasTextMeasuringMode textMeasuringMode,
            string localeName, CanvasGlyphOrientation glyphOrientation) { }

        public void DrawInlineObject(Vector2 baselineOrigin, ICanvasTextInlineObject inlineObject, bool isSideways,
            bool isRightToLeft, object brush, CanvasGlyphOrientation glyphOrientation) { }

        public float Dpi => 96;
        public bool PixelSnappingDisabled => true;
        public Matrix3x2 Transform => Matrix3x2.Identity;
    }

    sealed class Paint : IDisposable
    {
        public Rgba Color;
        public Rgba? Stroke;
        public float StrokeWidth;
        public ICanvasBrush? Gradient;
        public CanvasStrokeStyle StrokeStyle = new() { LineJoin = CanvasLineJoin.Round };
        public void Dispose()
        {
            Gradient?.Dispose();
            StrokeStyle.Dispose();
        }
    }

    /// <summary>Each visible glyph of a text layer as an outline in layer px, laid out like DrawText.</summary>
    internal static List<CanvasGeometry> GlyphOutlines(ICanvasResourceCreator rc, MotionLayer l, double t)
    {
        var full = l.DisplayText(t);
        var output = new List<CanvasGeometry>();
        if (full.Length == 0) return output;
        using var layout = ContentPainter.TextLayout(rc, l, full, t, out _, out var origin);
        var metrics = layout.LineMetrics;
        var lineStarts = new int[metrics.Length];
        for (int i = 0, at = 0; i < metrics.Length; at += metrics[i].CharacterCount, i++) lineStarts[i] = at;
        var collector = new Collector(lineStarts);
        layout.DrawToTextRenderer(collector, origin);
        foreach (var gl in collector.Glyphs)
        {
            var geometry = CanvasGeometry.CreateGlyphRun(rc, gl.Pen, gl.Face, gl.Size, [gl.Value], gl.Sideways, gl.Bidi,
                CanvasTextMeasuringMode.Natural, CanvasGlyphOrientation.Upright);
            var b = geometry.ComputeBounds();
            if (b.Width > 0 && b.Height > 0) output.Add(geometry);
            else geometry.Dispose();
        }
        return output;
    }

    public static void Draw(CanvasDrawingSession ds, MotionLayer l, string full, double t)
    {
        using var layout = ContentPainter.TextLayout(ds, l, full, t, out var box, out var origin);
        if (l.TextPath != null)
        {
            // One line (line breaks end the text on a path, like macOS).
            layout.WordWrapping = CanvasWordWrapping.NoWrap;
        }
        var metrics = layout.LineMetrics;
        var lineStarts = new int[metrics.Length];
        for (int i = 0, at = 0; i < metrics.Length; at += metrics[i].CharacterCount, i++) lineStarts[i] = at;
        var collector = new Collector(lineStarts);
        layout.DrawToTextRenderer(collector, origin);
        var glyphs = collector.Glyphs;
        if (glyphs.Count == 0) return;

        // Typewriter: glyphs past the reveal are not drawn (the layout stays put).
        var reveal = Math.Clamp(l.Value(AnimProperty.Reveal, t), 0, 1);
        var shown = (int)Math.Floor(full.Length * reveal);
        var strokeW = l.Value(AnimProperty.StrokeWidth, t);
        using var paint = new Paint
        {
            Color = l.ColorAt(ColorProperty.Color, t) ?? Rgba.White,
            Stroke = strokeW > 0 && l.ColorAt(ColorProperty.Stroke, t) is { A: > 0 } sc ? sc : null,
            StrokeWidth = (float)strokeW,
            Gradient = l.Gradient is { } g ? ContentPainter.GradientBrush(ds, g, box, t) : null,
        };

        var charMap = TextUnits.Map(full, TextUnit.Char);
        var wordMap = TextUnits.Map(full, TextUnit.Word);
        var charStates = l.GlyphStates(TextUnit.Char, charMap.Count, t);
        var wordStates = l.GlyphStates(TextUnit.Word, wordMap.Count, t);
        GlyphState StateOf(Glyph gl)
        {
            var st = GlyphState.Rest;
            if (gl.Index < charMap.Indices.Length && charMap.Indices[gl.Index] >= 0) st.Combine(charStates[charMap.Indices[gl.Index]]);
            if (gl.Index < wordMap.Indices.Length && wordMap.Indices[gl.Index] >= 0) st.Combine(wordStates[wordMap.Indices[gl.Index]]);
            return st;
        }

        if (l.TextPath is { } mp)
        {
            DrawOnPath(ds, l, mp, glyphs.Where(gl => gl.Line == 0).ToList(), shown, StateOf, paint, t);
            return;
        }

        var lineCount = metrics.Length;
        var lineStates = l.GlyphStates(TextUnit.Line, lineCount, t);
        var onlyLines = l.TextAnimators.All(a => a.Unit == TextUnit.Line);
        // Per line: horizontal middle, and the vertical middle of the letters (between ascent and descent).
        var lineMidX = new float[lineCount];
        var lineMidY = new float[lineCount];
        foreach (var group in glyphs.GroupBy(gl => gl.Line))
        {
            var li = Math.Min(group.Key, lineCount - 1);
            lineMidX[li] = (group.Min(gl => gl.MinX) + group.Max(gl => gl.MaxX)) / 2;
            float ascent = group.Max(gl => gl.Face.Ascent * gl.Size), descent = group.Max(gl => gl.Face.Descent * gl.Size);
            lineMidY[li] = group.First().Pen.Y - (ascent - descent) / 2;
        }
        foreach (var gl in glyphs)
        {
            if (gl.Index >= shown) continue;
            var st = StateOf(gl);
            var li = Math.Min(gl.Line, lineCount - 1);
            // Pivot: the glyph's own center (words use it too), the line center for line-only animators.
            var pivotX = gl.CenterX;
            if (!lineStates[li].IsRest)
            {
                st.Combine(lineStates[li]);
                if (onlyLines) pivotX = lineMidX[li];
            }
            if (st.Opacity <= 0.001 || Math.Abs(st.Scale) <= 0.0001) continue;
            var pivot = new Vector2(pivotX, lineMidY[li]);
            var m = Matrix3x2.CreateTranslation(-pivot)
                * Matrix3x2.CreateScale((float)st.Scale)
                * Matrix3x2.CreateRotation((float)(st.Rotation * Math.PI / 180))
                * Matrix3x2.CreateTranslation(pivot + new Vector2((float)st.Dx, (float)st.Dy));
            DrawGlyph(ds, gl, gl.Pen, m, st, paint);
        }
    }

    /// <summary>Text laid along the path: each glyph sits on the curve, turned to its direction, from the path's start
    /// (plus <c>textOffset</c>; centered/right-aligned texts start later). Animators still apply per character.</summary>
    static void DrawOnPath(CanvasDrawingSession ds, MotionLayer l, MotionPath mp, List<Glyph> glyphs, int shown,
        Func<Glyph, GlyphState> stateOf, Paint paint, double t)
    {
        var poly = mp.Polyline();
        if (poly.Count < 2 || glyphs.Count == 0) return;
        var lengths = new double[poly.Count];
        for (var i = 1; i < poly.Count; i++) lengths[i] = lengths[i - 1] + Vector2.Distance(poly[i], poly[i - 1]);
        var total = lengths[^1];
        if (total <= 1) return;
        (Vector2 Point, double Angle) At(double d)
        {
            d = mp.Closed ? d - Math.Floor(d / total) * total : Math.Clamp(d, 0, total);
            int lo = 0, hi = lengths.Length - 1;
            while (hi - lo > 1)
            {
                var mid = (lo + hi) / 2;
                if (lengths[mid] <= d) lo = mid; else hi = mid;
            }
            Vector2 a = poly[lo], b = poly[hi];
            var seg = lengths[hi] - lengths[lo];
            var f = seg > 0 ? (float)((d - lengths[lo]) / seg) : 0;
            return (a + (b - a) * f, Math.Atan2(b.Y - a.Y, b.X - a.X));
        }
        var lineOrigin = glyphs.Min(gl => gl.MinX);
        var lineWidth = glyphs.Max(gl => gl.MaxX) - lineOrigin;
        var startD = l.Value(AnimProperty.TextOffset, t) + l.Align switch
        {
            TextAlign.Center => (total - lineWidth) / 2,
            TextAlign.Right => total - lineWidth,
            _ => 0,
        };
        foreach (var gl in glyphs)
        {
            if (gl.Index >= shown) continue;
            var st = stateOf(gl);
            if (st.Opacity <= 0.001 || Math.Abs(st.Scale) <= 0.0001) continue;
            var half = gl.Advance / 2;
            var d = startD + gl.CenterX - lineOrigin;
            if (!mp.Closed && (d < -half || d > total + half)) continue;
            var (p, angle) = At(d);
            // The glyph's center on the path, its baseline along it.
            var m = Matrix3x2.CreateScale((float)st.Scale)
                * Matrix3x2.CreateRotation((float)(angle + st.Rotation * Math.PI / 180))
                * Matrix3x2.CreateTranslation(p + new Vector2((float)st.Dx, (float)st.Dy));
            var pen = new Vector2(gl.Rtl ? half : -half, 0);
            DrawGlyph(ds, gl, pen, m, st, paint);
        }
    }

    /// <summary>One glyph at <paramref name="pen"/>, mapped by <paramref name="m"/> into layer space: outline behind
    /// (twice as wide, half shows) or cut out when the fill is clear, then the fill; blurred through an effect.</summary>
    static void DrawGlyph(CanvasDrawingSession ds, Glyph gl, Vector2 pen, Matrix3x2 m, GlyphState st, Paint paint)
    {
        var saved = ds.Transform;
        ds.Transform = m * saved;
        try
        {
            using var opacity = st.Opacity < 0.999 ? ds.CreateLayer((float)Math.Clamp(st.Opacity, 0, 1)) : null;
            if (st.Blur * Math.Abs(st.Scale) > 0.05)
            {
                using var list = new CanvasCommandList(ds);
                using (var cl = list.CreateDrawingSession()) Paint1(cl, gl, pen, m, st, paint);
                using var blur = new GaussianBlurEffect
                {
                    Source = list, BlurAmount = (float)(st.Blur / 2), BorderMode = EffectBorderMode.Soft,
                    Optimization = EffectOptimization.Balanced,
                };
                ds.DrawImage(blur);
                ds.Flush(); // the effect and its command list are disposed next
            }
            else Paint1(ds, gl, pen, m, st, paint);
        }
        finally { ds.Transform = saved; }
    }

    static void Paint1(CanvasDrawingSession ds, Glyph gl, Vector2 pen, Matrix3x2 m, GlyphState st, Paint paint)
    {
        CanvasGlyph[] one = [gl.Value];
        var hollow = paint.Color.A <= 0.001 && paint.Gradient == null;
        if (paint.Stroke is { } stroke)
        {
            using var geometry = CanvasGeometry.CreateGlyphRun(ds, pen, gl.Face, gl.Size, one, gl.Sideways, gl.Bidi,
                CanvasTextMeasuringMode.Natural, CanvasGlyphOrientation.Upright);
            if (hollow)
            {
                using var outline = geometry.Stroke(paint.StrokeWidth * 2, paint.StrokeStyle);
                using var cut = outline.CombineWith(geometry, Matrix3x2.Identity, CanvasGeometryCombine.Exclude);
                ds.FillGeometry(cut, FrameCompositor.ToColor(stroke));
                return;
            }
            ds.DrawGeometry(geometry, FrameCompositor.ToColor(stroke), paint.StrokeWidth * 2, paint.StrokeStyle);
        }
        if (paint.Gradient is { } brush)
        {
            // The gradient stays put in layer space while the glyph moves.
            Matrix3x2.Invert(m, out var inverse);
            switch (brush)
            {
                case CanvasLinearGradientBrush lin: lin.Transform = inverse; break;
                case CanvasRadialGradientBrush rad: rad.Transform = inverse; break;
            }
            ds.DrawGlyphRun(pen, gl.Face, gl.Size, one, gl.Sideways, gl.Bidi, brush);
            return;
        }
        var fill = paint.Color;
        if (st.Tint is { } tint)
            fill = Rgba.Lerp(fill, tint with { A = fill.A }, tint.A) with { A = fill.A };
        using var solid = new CanvasSolidColorBrush(ds, FrameCompositor.ToColor(fill));
        ds.DrawGlyphRun(pen, gl.Face, gl.Size, one, gl.Sideways, gl.Bidi, solid);
    }
}
