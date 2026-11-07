using System.Numerics;
using System.Runtime.CompilerServices;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using VeyMotion.Core;
using Windows.Foundation;
using Windows.UI;

namespace VeyMotion.App.Rendering;

/// <summary>Draws a particle layer's live particles, and picks emission points on texts and paths. Port of
/// <c>drawParticles</c> and <c>emitPoint</c> in <c>Renderer.swift</c>. Soft discs and image sprites go through one
/// Direct2D sprite batch (tinted per particle).</summary>
static class ParticlePainter
{
    public static void Draw(CanvasDrawingSession ds, MotionLayer layer, List<Particle> particles, double alpha)
    {
        var sys = layer.Particles;
        using var round = new CanvasStrokeStyle { StartCap = CanvasCapStyle.Round, EndCap = CanvasCapStyle.Round };
        static Color C(Rgba c, double a) => FrameCompositor.ToColor(c with { A = a });

        // Trails first: ribbons thinning and fading toward their tails.
        foreach (var p in particles)
        {
            if (p.Trail is not { Count: > 0 } trail) continue;
            var a = alpha * p.Color.A;
            if (a <= 0.002) continue;
            var prev = new Vector2((float)p.X, (float)p.Y);
            for (var k = 0; k < trail.Count; k++)
            {
                var f = 1 - (double)(k + 1) / (trail.Count + 1);
                ds.DrawLine(prev, trail[k], C(p.Color, a * f * 0.8), (float)Math.Max(0.5, p.Size * (0.3 + 0.7 * f)), round);
                prev = trail[k];
            }
        }

        var picture = sys.Shape == ParticleShape.Image && layer.Path is { } path ? ContentPainter.Picture(ds, path) : null;
        ICanvasImage? sprite = sys.Shape switch
        {
            ParticleShape.Soft => SoftDisc(ds.Device),
            ParticleShape.Image when picture?.Bitmap is { } bmp => sys.Tint ? Mask(ds.Device, bmp) : bmp,
            _ => null,
        };
        if (sprite is CanvasBitmap spriteBitmap && CanvasSpriteBatch.IsSupported(ds.Device))
        {
            var size = spriteBitmap.Size;
            using var batch = ds.CreateSpriteBatch(CanvasSpriteSortMode.None, CanvasImageInterpolation.Linear, CanvasSpriteOptions.None);
            foreach (var p in particles)
            {
                var a = alpha * p.Color.A;
                if (a <= 0.002) continue;
                // Soft discs and tinted images take the particle's color; plain images keep theirs.
                var tint = sys.Shape == ParticleShape.Soft || sys.Tint
                    ? new Vector4((float)p.Color.R, (float)p.Color.G, (float)p.Color.B, (float)a)
                    : new Vector4(1, 1, 1, (float)a);
                var s = (float)p.Size;
                if (sys.Shape == ParticleShape.Soft)
                {
                    batch.Draw(spriteBitmap, new Rect(p.X - s / 2, p.Y - s / 2, s, s), tint);
                    continue;
                }
                var h = s * (float)(size.Height / size.Width);
                var m = Matrix3x2.CreateScale(s / (float)size.Width, h / (float)size.Height)
                    * Matrix3x2.CreateTranslation(-s / 2, -h / 2)
                    * Matrix3x2.CreateScale(1, (float)p.ScaleY)
                    * Matrix3x2.CreateRotation((float)(p.Rotation * Math.PI / 180))
                    * Matrix3x2.CreateTranslation((float)p.X, (float)p.Y);
                batch.Draw(spriteBitmap, m, tint);
            }
            return;
        }

        var saved = ds.Transform;
        foreach (var p in particles)
        {
            var a = alpha * p.Color.A;
            if (a <= 0.002) continue;
            var color = C(p.Color, a);
            var s = (float)p.Size;
            var center = new Vector2((float)p.X, (float)p.Y);
            switch (sys.Shape)
            {
                case ParticleShape.Circle or ParticleShape.Soft:
                    ds.FillEllipse(center, s / 2, s / 2, color);
                    break;
                case ParticleShape.Square:
                    ds.Transform = Matrix3x2.CreateScale(1, (float)p.ScaleY) * Matrix3x2.CreateRotation((float)(p.Rotation * Math.PI / 180))
                        * Matrix3x2.CreateTranslation(center) * saved;
                    ds.FillRectangle(-s / 2, -s / 2, s, s, color);
                    ds.Transform = saved;
                    break;
                case ParticleShape.Spark:
                {
                    var v = Math.Sqrt(p.Vx * p.Vx + p.Vy * p.Vy);
                    var len = Math.Max(v * sys.Streak, 0.01);
                    var (ux, uy) = v > 1e-6 ? (p.Vx / v, p.Vy / v) : (0.0, -1.0);
                    ds.DrawLine(new Vector2((float)(p.X - ux * len), (float)(p.Y - uy * len)), center, color, s, round);
                    break;
                }
                case ParticleShape.Image when picture is { Size.Width: > 0 } pic:
                {
                    var h = s * pic.Size.Height / pic.Size.Width;
                    ds.Transform = Matrix3x2.CreateScale(1, (float)p.ScaleY) * Matrix3x2.CreateRotation((float)(p.Rotation * Math.PI / 180))
                        * Matrix3x2.CreateTranslation(center) * saved;
                    var rect = new Rect(-s / 2, -h / 2, s, h);
                    if (pic.Svg is { } svg)
                    {
                        ds.Transform = Matrix3x2.CreateScale((float)(s / pic.Size.Width), (float)(h / pic.Size.Height))
                            * Matrix3x2.CreateTranslation(-s / 2, (float)(-h / 2)) * ds.Transform;
                        using (ds.CreateLayer((float)a)) ds.DrawSvg(svg, pic.Size);
                    }
                    else if (sprite != null) ds.DrawImage(sprite, rect, ((CanvasBitmap)sprite).Bounds, (float)a);
                    ds.Transform = saved;
                    break;
                }
            }
        }
    }

    static readonly ConditionalWeakTable<CanvasDevice, CanvasBitmap> SoftDiscs = new();

    /// <summary>White disc fading to clear at its edge ((1 − r²)²), the soft particle sprite.</summary>
    static CanvasBitmap SoftDisc(CanvasDevice device)
    {
        lock (SoftDiscs)
        {
            if (SoftDiscs.TryGetValue(device, out var hit)) return hit;
            const int n = 64;
            var px = new byte[n * n * 4];
            var c = (n - 1) / 2.0;
            for (var y = 0; y < n; y++)
                for (var x = 0; x < n; x++)
                {
                    double dx = (x - c) / c, dy = (y - c) / c;
                    var f = Math.Max(0, 1 - (dx * dx + dy * dy));
                    var v = (byte)PixelBuffer.Round(f * f * 255);
                    var i = (y * n + x) * 4;
                    px[i] = px[i + 1] = px[i + 2] = px[i + 3] = v; // premultiplied white
                }
            var bmp = CanvasBitmap.CreateFromBytes(device, px, n, n, Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Premultiplied);
            SoftDiscs.Add(device, bmp);
            return bmp;
        }
    }

    static readonly ConditionalWeakTable<CanvasBitmap, CanvasBitmap> Masks = new();

    /// <summary>The image's shape in white (its alpha), to paint with the particle colors.</summary>
    static CanvasBitmap Mask(CanvasDevice device, CanvasBitmap image)
    {
        lock (Masks)
        {
            if (Masks.TryGetValue(image, out var hit)) return hit;
            var target = new CanvasRenderTarget(device, (float)image.Size.Width, (float)image.Size.Height, 96);
            using (var ds = target.CreateDrawingSession())
            {
                ds.Clear(Color.FromArgb(0, 0, 0, 0));
                // Premultiplied white: every color channel becomes the alpha.
                ds.DrawImage(new ColorMatrixEffect
                {
                    Source = image, AlphaMode = CanvasAlphaMode.Straight,
                    ColorMatrix = new Matrix5x4 { M41 = 0, M51 = 1, M52 = 1, M53 = 1, M44 = 1 },
                });
            }
            Masks.Add(image, target);
            return target;
        }
    }

    // Emission points on other layers

    static readonly Dictionary<string, CanvasGeometry> Outlines = [];
    static readonly Lock OutlinesLock = new();

    /// <summary>Birth points on a text (its letters), an image/video (its frame) or a path; null for shapes (Core
    /// samples those).</summary>
    public static EmitSampler Sampler(CanvasDevice device) => (src, t, r1, r2, edge) =>
    {
        switch (src.Type)
        {
            case LayerType.Image or LayerType.Video:
            {
                var r = ContentPainter.WipeBox(device, new MotionScene(), src, t);
                return ParticleSim.RectPoint(r.Width, r.Height, r1, r2, edge);
            }
            case LayerType.Text or LayerType.Path:
            {
                var outline = Outline(device, src, t);
                if (outline == null) return null;
                lock (OutlinesLock)
                {
                    var closed = src.Type == LayerType.Text || src.PathShapeAt(t).Subpaths.Any(s => s.Closed);
                    if (!edge && closed)
                    {
                        var seed = Noise.Mix((ulong)(r1 * 9_007_199_254_740_992) ^ ((ulong)(r2 * 9_007_199_254_740_992) << 1));
                        var b = outline.ComputeBounds();
                        for (var i = 0; i < 24; i++)
                        {
                            var q = new Vector2((float)(b.X + Noise.Unit(2 * i, seed) * b.Width), (float)(b.Y + Noise.Unit(2 * i + 1, seed) * b.Height));
                            if (outline.FillContainsPoint(q)) return new PathPoint(q.X, q.Y);
                        }
                    }
                    var length = outline.ComputePathLength();
                    var p = outline.ComputePointOnPath((float)(length * r1));
                    return new PathPoint(p.X, p.Y);
                }
            }
            default:
                return null;
        }
    };

    /// <summary>A text's letters or a path's shape as one geometry in layer px (cached).</summary>
    static CanvasGeometry? Outline(CanvasDevice device, MotionLayer l, double t)
    {
        string key;
        if (l.Type == LayerType.Text)
        {
            var text = l.DisplayText(t);
            if (text.Length == 0) return null;
            key = string.Join("|", text, l.FontSize, l.FontWeight, l.FontName, l.MaxWidth, l.Align, l.Value(AnimProperty.LetterSpacing, t).ToString("F2"));
        }
        else
        {
            var shape = l.PathShapeAt(t);
            if (shape.IsEmpty) return null;
            key = "path|" + shape.Svg + "|" + l.FillRule;
        }
        lock (OutlinesLock)
        {
            if (Outlines.TryGetValue(key, out var hit)) return hit;
            CanvasGeometry geometry;
            if (l.Type == LayerType.Text)
            {
                using var layout = ContentPainter.TextLayout(device, l, l.DisplayText(t), t, out _, out var origin);
                using var raw = CanvasGeometry.CreateText(layout);
                geometry = raw.Transform(Matrix3x2.CreateTranslation(origin));
            }
            else geometry = ContentPainter.Geometry(device, l.PathShapeAt(t).Subpaths, l.FillRule);
            if (Outlines.Count > 64)
            {
                foreach (var g in Outlines.Values) g.Dispose();
                Outlines.Clear();
            }
            Outlines[key] = geometry;
            return geometry;
        }
    }
}
