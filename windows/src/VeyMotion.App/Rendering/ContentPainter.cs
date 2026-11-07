using System.Numerics;
using System.Xml.Linq;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Svg;
using Microsoft.Graphics.Canvas.Text;
using VeyMotion.Core;
using Windows.Foundation;
using Windows.Storage.Streams;
using Windows.UI;

namespace VeyMotion.App.Rendering;

/// <summary>
/// What a layer paints in its own space (origin at its center, y down), the session's transform mapping that to
/// device pixels. Port of <c>drawShape</c>, <c>drawText</c>, <c>drawImage</c> and <c>drawGradient</c> in
/// <c>Renderer.swift</c>.
/// </summary>
static class ContentPainter
{
    public static void Draw(CanvasDrawingSession ds, MotionScene scene, MotionLayer layer, double t)
    {
        switch (layer.Type)
        {
            case LayerType.Rect or LayerType.Ellipse or LayerType.Path: DrawShape(ds, layer, t); break;
            case LayerType.Text: DrawText(ds, layer, t); break;
            case LayerType.Image: DrawImage(ds, layer, t); break;
            case LayerType.Generator: GeneratorPainter.Draw(ds, layer, t); break;
            case LayerType.Video: DrawVideo(ds, layer, t); break;
            default: DrawPlaceholder(ds, layer, t); break;
        }
    }

    /// <summary>Layer-local box a wipe sweeps across: what the layer shows. Port of <c>wipeBox</c>.</summary>
    public static Rect WipeBox(ICanvasResourceCreator rc, MotionScene scene, MotionLayer l, double t)
    {
        switch (l.Type)
        {
            case LayerType.Group:
            {
                var w = l.Width?.ValueAt(t) ?? scene.Width;
                var h = l.Height?.ValueAt(t) ?? scene.Height;
                return new Rect(-w / 2, -h / 2, Math.Max(w, 0), Math.Max(h, 0));
            }
            case LayerType.Rect or LayerType.Ellipse or LayerType.Particles or LayerType.Generator:
            {
                double w = Math.Max(l.Value(AnimProperty.Width, t), 0), h = Math.Max(l.Value(AnimProperty.Height, t), 0);
                return new Rect(-w / 2, -h / 2, w, h);
            }
            case LayerType.Path:
                return Outline(l, t)?.Box ?? new Rect(0, 0, 0, 0);
            case LayerType.Image:
                return ImageRect(l, t, l.Path is { } p ? LoadImage(rc, p)?.Size : null);
            case LayerType.Video:
                return ImageRect(l, t, l.Path is { } vp ? VideoFrames.NaturalSize(vp) : null);
            case LayerType.Text when l.DisplayText(t) is { Length: > 0 } text:
                using (TextLayout(rc, l, text, t, out var box, out _)) return box;
        }
        return new Rect(-scene.Width / 2.0, -scene.Height / 2.0, scene.Width, scene.Height);
    }

    /// <summary>Layer-local area the layer's own content can cover (strokes, glyph overhangs, animated letters), or null
    /// when unknown. Port of <c>flatContentBounds</c>.</summary>
    public static Rect? FlatBounds(ICanvasResourceCreator rc, MotionScene scene, MotionLayer l, double t)
    {
        static Rect Inflate(Rect r, double d) => new(r.X - d, r.Y - d, Math.Max(0, r.Width + 2 * d), Math.Max(0, r.Height + 2 * d));
        var stroke = Math.Max(l.Value(AnimProperty.StrokeWidth, t), 0);
        switch (l.Type)
        {
            case LayerType.Rect or LayerType.Ellipse:
                return Inflate(WipeBox(rc, scene, l, t), stroke + new PathOps(l, t).Reach);
            case LayerType.Path:
                if (Outline(l, t) is not var (_, pathBox)) return null;
                // Miter joins on sharp corners reach up to 5 line widths out (miter limit 10).
                return Inflate(pathBox, stroke * (l.LineJoin == LineJoin.Miter ? 5 : 1) + 1 + new PathOps(l, t).Reach);
            case LayerType.Image or LayerType.Video:
                return Inflate(WipeBox(rc, scene, l, t), 4);
            case LayerType.Text when l.TextPath is { } mp:
            {
                var pts = mp.Polyline();
                if (pts.Count == 0) return null;
                float x0 = pts.Min(p => p.X), y0 = pts.Min(p => p.Y), x1 = pts.Max(p => p.X), y1 = pts.Max(p => p.Y);
                var pad = Math.Max(l.FontSize, 1) * 1.5 + stroke + l.TextAnimators.Select(a => Math.Abs(a.X) + Math.Abs(a.Y)).DefaultIfEmpty().Max();
                return Inflate(new Rect(x0, y0, x1 - x0, y1 - y0), pad);
            }
            case LayerType.Text:
            {
                var box = WipeBox(rc, scene, l, t);
                if (box.Width <= 0) return null;
                // Glyph overhang outside the line box (italics, accents); animated letters stray further.
                var pad = l.TextAnimators.Count == 0 ? Math.Max(l.FontSize, 1)
                    : Math.Max(l.FontSize, 1) * 2 + l.TextAnimators.Max(a => Math.Abs(a.X) + Math.Abs(a.Y));
                return Inflate(box, pad + stroke);
            }
            default:
                var b = WipeBox(rc, scene, l, t);
                return b.Width > 0 && b.Height > 0 ? b : null;
        }
    }

    // Shapes

    public static CanvasGeometry Geometry(ICanvasResourceCreator rc, IEnumerable<Subpath> subpaths, FillRule rule = FillRule.Nonzero)
    {
        using var b = new CanvasPathBuilder(rc);
        b.SetFilledRegionDetermination(rule == FillRule.Evenodd ? CanvasFilledRegionDetermination.Alternate : CanvasFilledRegionDetermination.Winding);
        foreach (var s in subpaths)
        {
            if (s.Segments.Count == 0) continue;
            b.BeginFigure(V(s.Start));
            foreach (var g in s.Segments) b.AddCubicBezier(V(g.C1), V(g.C2), V(g.P));
            b.EndFigure(s.Closed ? CanvasFigureLoop.Closed : CanvasFigureLoop.Open);
        }
        return CanvasGeometry.CreatePath(b);
    }

    static Vector2 V(PathPoint p) => new((float)p.X, (float)p.Y);

    /// <summary>The outline of a rect/ellipse/path layer at time t, and its box.</summary>
    static (List<Subpath> Subpaths, Rect Box)? Outline(MotionLayer l, double t)
    {
        if (l.Type == LayerType.Path)
        {
            var shape = l.PathShapeAt(t);
            if (shape.IsEmpty || shape.Bounds is not { } b) return null;
            return (shape.Subpaths.ToList(), new Rect(b.MinX, b.MinY, b.MaxX - b.MinX, b.MaxY - b.MinY));
        }
        double w = Math.Max(l.Value(AnimProperty.Width, t), 0), h = Math.Max(l.Value(AnimProperty.Height, t), 0);
        if (w <= 0 || h <= 0) return null;
        var box = new Rect(-w / 2, -h / 2, w, h);
        if (l.Type == LayerType.Ellipse) return (PathParser.Ellipse(w / 2, h / 2), box);
        var r = Math.Max(0, Math.Min(l.Value(AnimProperty.CornerRadius, t), Math.Min(w / 2, h / 2)));
        if (r <= 0)
        {
            PathPoint[] pts = [new(-w / 2, -h / 2), new(w / 2, -h / 2), new(w / 2, h / 2), new(-w / 2, h / 2)];
            var segs = Enumerable.Range(0, 4).Select(i => CubicSegment.Line(pts[i], pts[(i + 1) % 4])).ToList();
            return ([new Subpath(pts[0], segs, true)], box);
        }
        return ([PathParser.RoundedRect(-w / 2, -h / 2, w, h, r)], box);
    }

    static void DrawShape(CanvasDrawingSession ds, MotionLayer l, double t)
    {
        if (Outline(l, t) is not var (subpaths, box)) return;
        var ops = new PathOps(l, t);
        if (ops.IsActive)
        {
            subpaths = ops.Apply(subpaths);
            if (new PathShape(subpaths).Bounds is not { } b) return;
            box = new Rect(b.MinX, b.MinY, b.MaxX - b.MinX, b.MaxY - b.MinY);
        }
        using var fillPath = Geometry(ds, subpaths, l.FillRule);
        if (l.Gradient is { } g)
        {
            using var brush = GradientBrush(ds, g, box, t);
            ds.FillGeometry(fillPath, brush);
        }
        else if (l.ColorAt(ColorProperty.Fill, t) is { A: > 0 } fill)
        {
            ds.FillGeometry(fillPath, FrameCompositor.ToColor(fill));
        }
        if (Math.Max(0, l.Value(AnimProperty.TaperStart, t)) + Math.Max(0, l.Value(AnimProperty.TaperEnd, t)) > 0.001)
            StrokeTapered(ds, l, subpaths, t);
        else
            StrokeTrimmed(ds, l, subpaths, t);
    }

    /// <summary>A stroke thinning to a point at its ends (taperStart/taperEnd), honoring trim like StrokeTrimmed.</summary>
    static void StrokeTapered(CanvasDrawingSession ds, MotionLayer l, List<Subpath> subpaths, double t)
    {
        var lineWidth = l.Value(AnimProperty.StrokeWidth, t);
        if (l.ColorAt(ColorProperty.Stroke, t) is not { } stroke || lineWidth <= 0) return;
        double s = Math.Clamp(l.Value(AnimProperty.TrimStart, t), 0, 1), e = Math.Clamp(l.Value(AnimProperty.Trim, t), 0, 1);
        if (s > e) (s, e) = (e, s);
        if (e - s <= 0.0005) return;
        var offset = l.Value(AnimProperty.TrimOffset, t);
        double ts = Math.Clamp(l.Value(AnimProperty.TaperStart, t), 0, 1), te = Math.Clamp(l.Value(AnimProperty.TaperEnd, t), 0, 1);
        var color = FrameCompositor.ToColor(stroke);
        foreach (var sp in subpaths.Where(p => p.Segments.Count > 0))
        {
            double from = s + offset, to = e + offset;
            if (!sp.Closed) { from = Math.Clamp(from, 0, 1); to = Math.Clamp(to, 0, 1); }
            var polygon = PathOps.TaperedStroke(sp, lineWidth, from, to, ts, te);
            if (polygon.Count < 3) continue;
            using var b = new CanvasPathBuilder(ds);
            b.SetFilledRegionDetermination(CanvasFilledRegionDetermination.Winding);
            b.BeginFigure(V(polygon[0]));
            foreach (var p in polygon.Skip(1)) b.AddLine(V(p));
            b.EndFigure(CanvasFigureLoop.Closed);
            using var geo = CanvasGeometry.CreatePath(b);
            ds.FillGeometry(geo, color);
        }
    }

    /// <summary>Strokes each subpath between trimStart and trim (end), moved along by trimOffset; trims wrap around.
    /// Dash lengths in Direct2D are in stroke widths.</summary>
    static void StrokeTrimmed(CanvasDrawingSession ds, MotionLayer l, List<Subpath> subpaths, double t)
    {
        var lineWidth = l.Value(AnimProperty.StrokeWidth, t);
        if (l.ColorAt(ColorProperty.Stroke, t) is not { } strokeRgba || lineWidth <= 0) return;
        var stroke = FrameCompositor.ToColor(strokeRgba);
        double s = Math.Clamp(l.Value(AnimProperty.TrimStart, t), 0, 1), e = Math.Clamp(l.Value(AnimProperty.Trim, t), 0, 1);
        if (s > e) (s, e) = (e, s);
        var visible = e - s;
        if (visible <= 0.0005) return;
        var trimmed = visible < 0.9995;
        var offset = s + l.Value(AnimProperty.TrimOffset, t);
        var start = offset - Math.Floor(offset);
        var isPath = l.Type == LayerType.Path;
        var cap = (l.LineCap ?? (isPath || trimmed ? LineCap.Round : LineCap.Butt)) switch
        {
            LineCap.Round => CanvasCapStyle.Round, LineCap.Square => CanvasCapStyle.Square, _ => CanvasCapStyle.Flat,
        };
        var join = (l.LineJoin ?? (isPath ? LineJoin.Round : LineJoin.Miter)) switch
        {
            LineJoin.Round => CanvasLineJoin.Round, LineJoin.Bevel => CanvasLineJoin.Bevel, _ => CanvasLineJoin.MiterOrBevel,
        };
        var w = (float)lineWidth;
        CanvasStrokeStyle Style(float[]? dashes = null, double phase = 0) => new()
        {
            StartCap = cap, EndCap = cap, DashCap = cap, LineJoin = join, MiterLimit = 10,
            CustomDashStyle = dashes?.Select(d => Math.Max(d / w, 1e-4f)).ToArray(), DashOffset = (float)(phase / w),
        };
        var pieces = subpaths.Where(p => p.Segments.Count > 0).Select(p => (Path: p, Length: p.Length)).ToList();

        if (trimmed && l.TrimSequential && pieces.Count > 1)
        {
            // One window over all pieces laid end to end, so letters write one after another.
            var total = pieces.Sum(p => p.Length);
            var shift = l.Value(AnimProperty.TrimOffset, t) * total;
            double from = s * total + shift, to = e * total + shift, at = 0;
            foreach (var piece in pieces)
            {
                var a = Math.Max(from - at, 0);
                var b = Math.Min(to - at, piece.Length);
                if (b - a > 0.01 && piece.Length > 0)
                {
                    var period = (b - a) + 3 * piece.Length;
                    using var geo = Geometry(ds, [piece.Path]);
                    using var style = Style([(float)(b - a), (float)(period - (b - a))], a > 0 ? period - a : 0);
                    ds.DrawGeometry(geo, stroke, w, style);
                }
                at += piece.Length;
            }
            return;
        }
        foreach (var piece in pieces)
        {
            if (piece.Length <= 0) continue;
            using var geo = Geometry(ds, [piece.Path]);
            if (trimmed)
            {
                var on = visible * piece.Length;
                // Wrapping past the end needs a pattern that repeats every path length.
                var wraps = start + visible > 1 + 1e-9;
                var period = wraps ? piece.Length : on + 2 * piece.Length;
                using var style = Style([(float)on, (float)(period - on)], start > 0 ? period - start * piece.Length : 0);
                ds.DrawGeometry(geo, stroke, w, style);
            }
            else if (l.Dash.Count > 0 && l.Dash.Any(d => d > 0))
            {
                using var style = Style(l.Dash.Select(d => (float)Math.Max(d, 0.01)).ToArray(), l.Value(AnimProperty.DashOffset, t));
                ds.DrawGeometry(geo, stroke, w, style);
            }
            else
            {
                using var style = Style();
                ds.DrawGeometry(geo, stroke, w, style);
            }
        }
    }

    /// <summary>A gradient laid out over <paramref name="box"/> (layer-local px).</summary>
    internal static ICanvasBrush GradientBrush(ICanvasResourceCreator rc, Gradient g, Rect box, double t)
    {
        var shift = g.Shift.ValueAt(t);
        if (g.Type == GradientType.Linear)
        {
            var a = g.Angle.ValueAt(t) * Math.PI / 180;
            double dx = Math.Cos(a), dy = Math.Sin(a);
            var half = Math.Max((Math.Abs(dx) * box.Width + Math.Abs(dy) * box.Height) / 2, 0.5);
            double cx = box.X + box.Width / 2 + dx * 2 * half * shift, cy = box.Y + box.Height / 2 + dy * 2 * half * shift;
            var stops = g.Stops.Select(s => new CanvasGradientStop { Position = (float)Math.Clamp(s.Offset, 0, 1), Color = FrameCompositor.ToColor(s.Color) }).ToArray();
            return new CanvasLinearGradientBrush(rc, stops)
            {
                StartPoint = new Vector2((float)(cx - dx * half), (float)(cy - dy * half)),
                EndPoint = new Vector2((float)(cx + dx * half), (float)(cy + dy * half)),
            };
        }
        var c = new Vector2((float)(box.X + g.Cx * box.Width), (float)(box.Y + g.Cy * box.Height));
        var r = Math.Max(0.5, g.Radius.ValueAt(t) * Math.Sqrt(box.Width * box.Width + box.Height * box.Height) / 2);
        // macOS starts the colors `shift × r` out from the center; Direct2D has no inner radius, so the stops move.
        var inner = Math.Max(0, shift) * r;
        var outer = r + inner;
        var radial = g.Stops.Select(s => new CanvasGradientStop
        {
            Position = (float)((inner + Math.Clamp(s.Offset, 0, 1) * r) / outer), Color = FrameCompositor.ToColor(s.Color),
        }).ToArray();
        return new CanvasRadialGradientBrush(rc, radial) { Center = c, RadiusX = (float)outer, RadiusY = (float)outer };
    }

    // Text

    /// <summary>The text box is centered on the layer's position, like the macOS renderer.</summary>
    static void DrawText(CanvasDrawingSession ds, MotionLayer l, double t)
    {
        var full = l.DisplayText(t);
        if (full.Length == 0) return;
        if (l.TextPath != null || l.TextAnimators.Count > 0)
        {
            GlyphPainter.Draw(ds, l, full, t);
            return;
        }
        using var layout = TextLayout(ds, l, full, t, out var box, out var origin);
        var color = FrameCompositor.ToColor(l.ColorAt(ColorProperty.Color, t) ?? Rgba.White);

        // Typewriter: hide trailing characters but keep the layout stable.
        var reveal = Math.Clamp(l.Value(AnimProperty.Reveal, t), 0, 1);
        var shown = (int)Math.Floor(full.Length * reveal);
        if (shown <= 0) return;
        if (shown < full.Length) layout.SetColor(shown, full.Length - shown, Color.FromArgb(0, 0, 0, 0));


        var hollow = (l.ColorAt(ColorProperty.Color, t)?.A ?? 1) <= 0.001;
        var strokeW = l.Value(AnimProperty.StrokeWidth, t);
        if (l.ColorAt(ColorProperty.Stroke, t) is { A: > 0 } sc && strokeW > 0)
        {
            // Outline behind the letters (twice as wide, half shows). Outline-only text (clear fill) cuts the letters
            // out of the stroke instead.
            using var geometry = CanvasGeometry.CreateText(layout);
            using var style = new CanvasStrokeStyle { LineJoin = CanvasLineJoin.Round };
            if (hollow)
            {
                using var outline = geometry.Stroke((float)(strokeW * 2), style);
                using var cut = outline.CombineWith(geometry, Matrix3x2.Identity, CanvasGeometryCombine.Exclude);
                ds.FillGeometry(cut, origin, FrameCompositor.ToColor(sc));
                return;
            }
            ds.DrawGeometry(geometry, origin, FrameCompositor.ToColor(sc), (float)(strokeW * 2), style);
        }
        if (l.Gradient is { } g)
        {
            using var brush = GradientBrush(ds, g, box, t);
            ds.DrawTextLayout(layout, origin, brush);
        }
        else ds.DrawTextLayout(layout, origin, color);
    }

    /// <summary>Typesets the text; <paramref name="box"/> is the text box centered on the layer (layer px).</summary>
    internal static CanvasTextLayout TextLayout(ICanvasResourceCreator rc, MotionLayer l, string text, double t, out Rect box, out Vector2 origin)
    {
        var (weight, italic) = ParseWeight(l.FontWeight);
        // fontName + fontWeight resolved like macOS FontLibrary.resolve: installed or asset-library fonts.
        string? family = l.FontName;
        if (DirectWriteFonts.Shared.Resolve(l.FontName, l.FontWeight) is { } face) (family, weight, italic) = face;
        using var format = new CanvasTextFormat
        {
            FontFamily = family ?? "Segoe UI Variable Display",
            FontSize = (float)Math.Max(1, l.FontSize),
            FontWeight = new Windows.UI.Text.FontWeight { Weight = weight },
            FontStyle = italic ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
            HorizontalAlignment = l.Align switch
            {
                TextAlign.Left => CanvasHorizontalAlignment.Left,
                TextAlign.Right => CanvasHorizontalAlignment.Right,
                _ => CanvasHorizontalAlignment.Center,
            },
            WordWrapping = l.MaxWidth != null ? CanvasWordWrapping.Wrap : CanvasWordWrapping.NoWrap,
        };
        var layout = new CanvasTextLayout(rc, text, format, (float)(l.MaxWidth ?? 100_000), 100_000);
        var spacing = l.Value(AnimProperty.LetterSpacing, t);
        if (Math.Abs(spacing) > 0.001) layout.SetCharacterSpacing(0, text.Length, 0, (float)spacing, 0);
        var b = layout.LayoutBounds;
        if (l.MaxWidth is { } mw)
        {
            // A fixed-width box (+2 px like macOS), the lines aligned inside it.
            var bw = Math.Ceiling(mw) + 2;
            var bh = Math.Ceiling(b.Height) + 2;
            box = new Rect(-bw / 2, -bh / 2, bw, bh);
            origin = new Vector2((float)(-bw / 2 + 1), (float)(-bh / 2 + 1 - b.Y));
        }
        else
        {
            // The text's own box, centered (the layout is wider; its alignment places the lines within).
            box = new Rect(-b.Width / 2, -b.Height / 2, b.Width, b.Height);
            origin = new Vector2((float)(-b.X - b.Width / 2), (float)(-b.Y - b.Height / 2));
        }
        return layout;
    }

    /// <summary>Weight names as in <c>Fonts.swift</c> ("bold", "light italic", "600").</summary>
    internal static (ushort Weight, bool Italic) ParseWeight(string s)
    {
        var words = s.ToLowerInvariant().Replace('-', ' ').Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var italic = words.Contains("italic") || words.Contains("oblique");
        ushort weight = 400;
        foreach (var w in words)
        {
            if (ushort.TryParse(w, out var n) && n is >= 1 and <= 1000) { weight = n; continue; }
            weight = w switch
            {
                "thin" or "hairline" => 100,
                "ultralight" or "extralight" => 200,
                "light" => 300,
                "regular" or "normal" or "book" => 400,
                "medium" => 500,
                "semibold" or "demibold" => 600,
                "bold" => 700,
                "heavy" or "extrabold" or "ultrabold" => 800,
                "black" => 900,
                _ => weight,
            };
        }
        return (weight, italic);
    }

    // Images

    sealed record LoadedImage(DateTime Modified, CanvasBitmap? Bitmap, CanvasSvgDocument? Svg, Size Size);

    static readonly Dictionary<string, LoadedImage?> Images = [];
    static readonly Lock ImagesLock = new();

    /// <summary>A picture file (bitmap or SVG), cached by path and modification time so overwritten files reload.</summary>
    static LoadedImage? LoadImage(ICanvasResourceCreator rc, string path)
    {
        DateTime modified;
        try { modified = File.GetLastWriteTimeUtc(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
        if (!File.Exists(path)) return null;
        lock (ImagesLock)
        {
            if (Images.TryGetValue(path, out var hit) && hit?.Modified == modified) return hit;
            LoadedImage? loaded = null;
            try
            {
                if (path.EndsWith(".svg", StringComparison.OrdinalIgnoreCase))
                {
                    var xml = File.ReadAllText(path);
                    using var stream = new InMemoryRandomAccessStream();
                    using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
                    {
                        writer.WriteString(xml);
                        writer.StoreAsync().AsTask().GetAwaiter().GetResult();
                    }
                    stream.Seek(0);
                    var doc = CanvasSvgDocument.LoadAsync(rc, stream).AsTask().GetAwaiter().GetResult();
                    loaded = new LoadedImage(modified, null, doc, SvgSize(xml));
                }
                else
                {
                    var bmp = CanvasBitmap.LoadAsync(rc, path, 96).AsTask().GetAwaiter().GetResult();
                    loaded = new LoadedImage(modified, bmp, null, new Size(bmp.SizeInPixels.Width, bmp.SizeInPixels.Height));
                }
            }
            catch (Exception e) when (e is IOException or ArgumentException or System.Runtime.InteropServices.COMException or UnauthorizedAccessException) { }
            Images[path] = loaded;
            return loaded;
        }
    }

    /// <summary>A picture file for particle sprites: its bitmap or SVG document and natural size.</summary>
    internal static (CanvasBitmap? Bitmap, CanvasSvgDocument? Svg, Size Size)? Picture(ICanvasResourceCreator rc, string path) =>
        LoadImage(rc, path) is { } img ? (img.Bitmap, img.Svg, img.Size) : null;

    /// <summary>An SVG's natural size: width/height, else its viewBox, else 300×150 (the browser default).</summary>
    static Size SvgSize(string xml)
    {
        try
        {
            var root = XDocument.Parse(xml).Root;
            static double? Num(string? s) => s != null && double.TryParse(new string(s.TakeWhile(c => char.IsDigit(c) || c is '.' or '-').ToArray()),
                System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : null;
            double? w = Num((string?)root?.Attribute("width")), h = Num((string?)root?.Attribute("height"));
            var vb = ((string?)root?.Attribute("viewBox"))?.Split([' ', ','], StringSplitOptions.RemoveEmptyEntries);
            if (vb is { Length: 4 } && Num(vb[2]) is { } vw && Num(vb[3]) is { } vh)
            {
                w ??= h is { } hh ? hh * vw / vh : vw;
                h ??= w * vh / vw;
            }
            return new Size(w ?? 300, h ?? 150);
        }
        catch (System.Xml.XmlException) { return new Size(300, 150); }
    }

    /// <summary>The picture's layer-local rect: natural size unless width/height are set (one keeps the aspect).</summary>
    static Rect ImageRect(MotionLayer l, double t, Size? natural)
    {
        var setW = l.Width?.ValueAt(t) is > 0 and var sw ? sw : (double?)null;
        var setH = l.Height?.ValueAt(t) is > 0 and var sh ? sh : (double?)null;
        double w = setW ?? 400, h = setH ?? 240;
        if (natural is { Width: > 0, Height: > 0 } n)
        {
            w = setW ?? n.Width;
            h = setH ?? n.Height;
            if (setW != null && setH == null) h = w * n.Height / n.Width;
            if (setH != null && setW == null) w = h * n.Width / n.Height;
        }
        return new Rect(-w / 2, -h / 2, w, h);
    }

    /// <summary>The video frame at t (or two blended for slow motion); the missing-picture mark when the file cannot
    /// be read, nothing outside the clip.</summary>
    static void DrawVideo(CanvasDrawingSession ds, MotionLayer l, double t)
    {
        var natural = l.Path is { } p ? VideoFrames.NaturalSize(p) : null;
        var rect = ImageRect(l, t, natural);
        if (natural == null) { DrawMissing(ds, rect); return; }
        if (VideoFrames.Frame(ds, l, t) is not var (a, b, mix)) return;
        ds.DrawImage(a, rect, a.Bounds, 1, CanvasImageInterpolation.HighQualityCubic);
        if (b != null) ds.DrawImage(b, rect, b.Bounds, mix, CanvasImageInterpolation.HighQualityCubic);
    }

    static void DrawImage(CanvasDrawingSession ds, MotionLayer l, double t)
    {
        // TODO(port): removeBackground (Windows ML).
        var img = l.Path is { } p ? LoadImage(ds, p) : null;
        var rect = ImageRect(l, t, img?.Size);
        if (img?.Bitmap is { } bmp) ds.DrawImage(bmp, rect, bmp.Bounds, 1, CanvasImageInterpolation.HighQualityCubic);
        else if (img?.Svg is { } svg)
        {
            var saved = ds.Transform;
            ds.Transform = Matrix3x2.CreateScale((float)(rect.Width / img.Size.Width), (float)(rect.Height / img.Size.Height))
                * Matrix3x2.CreateTranslation((float)rect.X, (float)rect.Y) * saved;
            ds.DrawSvg(svg, img.Size);
            ds.Transform = saved;
        }
        else DrawMissing(ds, rect);
    }

    /// <summary>A missing picture, as macOS draws it: translucent gray with a red cross.</summary>
    static void DrawMissing(CanvasDrawingSession ds, Rect r)
    {
        ds.FillRectangle(r, Color.FromArgb(64, 128, 128, 128));
        var red = Color.FromArgb(255, 255, 77, 77);
        ds.DrawRectangle(r, red, 4);
        ds.DrawLine((float)r.Left, (float)r.Top, (float)r.Right, (float)r.Bottom, red, 4);
        ds.DrawLine((float)r.Right, (float)r.Top, (float)r.Left, (float)r.Bottom, red, 4);
    }

    /// <summary>Layer types not ported yet (particles, generators): a dashed box with the layer's name.</summary>
    static void DrawPlaceholder(CanvasDrawingSession ds, MotionLayer l, double t)
    {
        var w = (float)l.Value(AnimProperty.Width, t);
        var h = (float)l.Value(AnimProperty.Height, t);
        if (w <= 0) w = 400;
        if (h <= 0) h = 240;
        var box = new Rect(-w / 2, -h / 2, w, h);
        var tint = Color.FromArgb(160, 255, 255, 255);
        ds.FillRectangle(box, Color.FromArgb(24, 255, 255, 255));
        using var dashed = new CanvasStrokeStyle { DashStyle = CanvasDashStyle.Dash };
        ds.DrawRectangle(box, tint, 2, dashed);
        using var format = new CanvasTextFormat
        {
            FontSize = Math.Clamp(Math.Min(w, h) / 8, 12, 36),
            HorizontalAlignment = CanvasHorizontalAlignment.Center,
            VerticalAlignment = CanvasVerticalAlignment.Center,
        };
        ds.DrawText($"{l.Name}\n{l.Type.Json()} — not ported yet", box, tint, format);
    }
}
