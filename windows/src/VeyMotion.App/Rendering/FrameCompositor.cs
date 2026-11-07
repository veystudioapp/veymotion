using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Effects;
using Microsoft.Graphics.Canvas.Geometry;
using VeyMotion.Core;
using Windows.Foundation;
using Windows.UI;

namespace VeyMotion.App.Rendering;

/// <summary>
/// Draws one frame. Port of the layer pipeline of <c>FrameRenderer</c> (<c>Renderer.swift</c>): <c>RenderLayer</c>
/// (track matte + repeater copies) → <c>DrawLayer</c> (transform, opacity, blend mode, color correction, blur, shadow,
/// glow). Everything is composed in device-pixel bitmaps (Win2D render targets) so blend modes can read what is below,
/// like CoreGraphics does on its bitmap context.
/// </summary>
public sealed class FrameCompositor
{
    readonly CanvasDevice _device;
    /// <summary>Device pixels per scene pixel of the root scene (blur and shadow sizes are in scene pixels).</summary>
    readonly float _pixelScale;
    readonly int _pw, _ph;
    readonly List<CanvasRenderTarget> _temps = [];

    FrameCompositor(CanvasDevice device, float pixelScale, int pw, int ph)
    {
        _device = device;
        _pixelScale = pixelScale;
        _pw = pw;
        _ph = ph;
    }

    /// <summary>Renders the scene at time t into a new pw×ph bitmap (scene stretched to fill it).</summary>
    public static CanvasRenderTarget Render(CanvasDevice device, MotionScene scene, double t, int pw, int ph)
    {
        var target = new CanvasRenderTarget(device, pw, ph, 96);
        var c = new FrameCompositor(device, (float)pw / Math.Max(scene.Width, 1), pw, ph);
        try
        {
            using (var ds = target.CreateDrawingSession())
            {
                ds.Clear(Transparent);
                ds.FillRectangle(0, 0, pw, ph, ToColor(scene.Background));
            }
            c.DrawScene(target, scene, t, Matrix3x2.CreateScale((float)pw / scene.Width, (float)ph / scene.Height));
        }
        finally { c.DisposeTemps(); }
        return target;
    }

    static readonly Color Transparent = Color.FromArgb(0, 0, 0, 0);

    CanvasRenderTarget NewTarget(bool highPrecision = false)
    {
        var t = highPrecision
            ? new CanvasRenderTarget(_device, _pw, _ph, 96, Windows.Graphics.DirectX.DirectXPixelFormat.R16G16B16A16Float, CanvasAlphaMode.Premultiplied)
            : new CanvasRenderTarget(_device, _pw, _ph, 96);
        using (var ds = t.CreateDrawingSession()) ds.Clear(Transparent);
        _temps.Add(t);
        return t;
    }

    void DisposeTemps(int from = 0)
    {
        for (var i = from; i < _temps.Count; i++) _temps[i].Dispose();
        _temps.RemoveRange(from, _temps.Count - from);
    }

    Rect Frame => new(0, 0, _pw, _ph);

    // Scenes and layers

    /// <summary>Draws a scene's layers onto <paramref name="acc"/>; <paramref name="toDevice"/> maps scene px to its pixels.</summary>
    void DrawScene(CanvasRenderTarget acc, MotionScene scene, double t, Matrix3x2 toDevice, int depth = 0)
    {
        // A layer used as another's track matte is only drawn through that layer.
        var matteSources = scene.Layers.Select(l => l.Matte?.Source is { } s && s != l.Id ? s : null).OfType<string>().ToHashSet();
        foreach (var layer in scene.Layers)
        {
            if (!layer.Type.IsVisual() || matteSources.Contains(layer.Id)) continue;
            RenderLayer(acc, scene, layer, t, toDevice, depth);
        }
    }

    /// <summary>A layer with its track matte and repeater copies. <paramref name="depth"/> limits mattes of mattes.</summary>
    void RenderLayer(CanvasRenderTarget acc, MotionScene scene, MotionLayer layer, double time, Matrix3x2 toDevice, int depth)
    {
        // Posterize time: the layer only changes posterizeTime times a second.
        var t = layer.PosterizeTime is { } pfps ? Math.Floor(time * pfps + 1e-6) / pfps : time;
        var rep = layer.Repeater;
        var n = rep != null ? Math.Clamp(rep.Count, 1, Repeater.MaxCount) : 1;
        var delay = rep?.Delay ?? 0;
        // Each copy lags delay behind the previous one, start time included.
        var copies = Enumerable.Range(0, n).Where(i => layer.IsVisible(t - i * delay, scene.Duration)).ToList();
        if (copies.Count == 0) return;

        CanvasRenderTarget dest = acc;
        ICanvasImage? mask = null;
        if (layer.Matte is { } matte && matte.Source != layer.Id && depth < 4
            && scene.Layers.FirstOrDefault(l => l.Id == matte.Source) is { } src)
        {
            mask = MatteMask(scene, src, matte.Mode, t, toDevice, depth);
            dest = NewTarget(); // the copies are drawn alone, then shown through the mask
        }
        // The original (copy 0) is on top.
        for (var k = copies.Count - 1; k >= 0; k--)
        {
            var i = copies[k];
            var ti = t - i * delay;
            if (rep != null)
            {
                var c = rep.Copy(i, t, layer.Position(ti).Point);
                DrawCopy(dest, scene, layer, ti, toDevice, c.Transform, c.Opacity, depth);
            }
            else DrawCopy(dest, scene, layer, ti, toDevice, null, 1, depth);
        }
        if (mask != null)
        {
            using var ds = acc.CreateDrawingSession();
            ds.DrawImage(new AlphaMaskEffect { Source = dest, AlphaMask = mask });
        }
    }

    /// <summary>Alpha mask of the frame (opaque = show) from a matte layer.</summary>
    ICanvasImage MatteMask(MotionScene scene, MotionLayer src, MatteMode mode, double t, Matrix3x2 toDevice, int depth)
    {
        var luma = mode is MatteMode.Luma or MatteMode.LumaInverted;
        var invert = mode is MatteMode.AlphaInverted or MatteMode.LumaInverted;
        var target = NewTarget();
        if (luma)
            using (var ds = target.CreateDrawingSession()) ds.Clear(Color.FromArgb(255, 0, 0, 0)); // brightness over black
        RenderLayer(target, scene, src, t, toDevice, depth + 1);
        if (!luma && !invert) return target;
        // Output alpha = luma (Rec. 709 on the composited colors, as macOS: 54/183/19 of 256) or 1 − alpha.
        Matrix5x4 m = default;
        if (luma)
        {
            float s = invert ? -1 : 1;
            m.M14 = s * 54 / 256f; m.M24 = s * 183 / 256f; m.M34 = s * 19 / 256f; m.M54 = invert ? 1 : 0;
        }
        else { m.M44 = -1; m.M54 = 1; }
        return new ColorMatrixEffect { Source = target, ColorMatrix = m, ClampOutput = true };
    }

    /// <summary>Scene transform of a layer (or of one of its repeater copies, copy being the step in its parent's space).</summary>
    static Matrix3x2 TransformOf(MotionScene scene, MotionLayer l, double t, Matrix3x2? copy) =>
        copy is { } c ? l.LocalTransform(t) * c * scene.ParentTransform(l, t) : scene.WorldTransform(l, t);

    const int MotionBlurSamples = 8;
    bool _inMotionSample;

    /// <summary>One copy of a layer, averaged over the shutter time when it has motion blur.</summary>
    void DrawCopy(CanvasRenderTarget acc, MotionScene scene, MotionLayer layer, double t, Matrix3x2 toDevice,
        Matrix3x2? copy, double alphaScale, int depth)
    {
        var shutter = layer.MotionBlur / 360 / Math.Max(scene.Fps, 1);
        if (!(shutter > 0) || _inMotionSample)
        {
            DrawLayer(acc, scene, layer, t, toDevice, copy, alphaScale, depth);
            return;
        }
        // The samples add up in a half-float bitmap (1/n of each), then go onto the frame with the blend mode.
        var sum = NewTarget(highPrecision: true);
        var sample = NewTarget();
        _inMotionSample = true;
        try
        {
            for (var i = 0; i < MotionBlurSamples; i++)
            {
                var tk = t + shutter * ((i + 0.5) / MotionBlurSamples - 0.5);
                var mark = _temps.Count;
                using (var ds = sample.CreateDrawingSession()) ds.Clear(Transparent);
                DrawLayer(sample, scene, layer, tk, toDevice, copy, alphaScale, depth, BlendMode.Normal);
                using (var ds = sum.CreateDrawingSession())
                    ds.DrawImage(sample, Vector2.Zero, Frame, 1f / MotionBlurSamples, CanvasImageInterpolation.NearestNeighbor, CanvasComposite.Add);
                DisposeTemps(mark);
            }
        }
        finally { _inMotionSample = false; }
        Composite(acc, sum, layer.BlendMode, 1);
    }

    void DrawLayer(CanvasRenderTarget acc, MotionScene scene, MotionLayer layer, double t, Matrix3x2 toDevice,
        Matrix3x2? copy, double alphaScale, int depth, BlendMode? blendOverride = null)
    {
        var blendMode = blendOverride ?? layer.BlendMode;
        var opacity = Math.Clamp(layer.Value(AnimProperty.Opacity, t), 0, 1) * alphaScale;
        if (opacity <= 0.001) return;
        var wipe = layer.Value(AnimProperty.Wipe, t);
        if (wipe >= 0.9999) return;
        var m = TransformOf(scene, layer, t, copy);
        if (Math.Abs(m.GetDeterminant()) <= 1e-8) return; // scaled to nothing
        var dm = m * toDevice;
        // The wipe is in the layer's own space, also for world-space particles (drawn without the layer transform).
        var contentDm = dm;
        _particles = null;
        if (layer.Type == LayerType.Particles)
        {
            _particles = scene.Particles(layer, t, ParticlePainter.Sampler(_device));
            if (_particles.Count == 0) return;
            if (layer.Particles.UsesWorldSpace) contentDm = (copy ?? Matrix3x2.Identity) * scene.CameraTransform(layer, t) * toDevice;
        }
        if (wipe > 0.0001)
        {
            // The wipe clips everything the layer draws (shadow, blur and glow included): draw it alone, then show it
            // through the visible region (soft-edged when feathered) with its blend mode.
            var style = layer.WipeStyle ?? new WipeStyle();
            var box = ContentPainter.WipeBox(_device, scene, layer, t);
            if (style.VisibleRegion(wipe, box.X, box.Y, box.Width, box.Height) is not { } region) return;
            var alone = NewTarget();
            DrawLayerContent(alone, scene, layer, t, contentDm, opacity, BlendMode.Normal, depth);
            var maskTarget = NewTarget();
            using (var ds = maskTarget.CreateDrawingSession())
            {
                ds.Transform = dm;
                using var geo = ContentPainter.Geometry(ds, region.Subpaths, FillRule.Evenodd);
                ds.FillGeometry(geo, Color.FromArgb(255, 255, 255, 255));
            }
            // Scene px per layer px, to turn the feather into a blur radius.
            var featherSigma = (float)(style.Feather * Math.Sqrt(Math.Abs(m.GetDeterminant())) * _pixelScale / 2);
            ICanvasImage mask = featherSigma > 0.25
                ? new GaussianBlurEffect { Source = maskTarget, BlurAmount = featherSigma, BorderMode = EffectBorderMode.Hard }
                : maskTarget;
            Composite(acc, new AlphaMaskEffect { Source = alone, AlphaMask = mask }, blendMode, 1);
            return;
        }
        DrawLayerContent(acc, scene, layer, t, contentDm, opacity, blendMode, depth);
    }

    /// <summary>Live particles of the particle layer being drawn.</summary>
    List<Particle>? _particles;

    /// <summary>The layer's picture with its effects, composited onto <paramref name="acc"/>.</summary>
    void DrawLayerContent(CanvasRenderTarget acc, MotionScene scene, MotionLayer layer, double t, Matrix3x2 dm,
        double opacity, BlendMode blendMode, int depth)
    {
        var blur = Math.Max(0, layer.Value(AnimProperty.Blur, t)) + scene.FocusBlur(layer, t);
        var sigma = (float)(blur * _pixelScale / 2);
        var colorMatrix = layer.ColorMatrixAt(t);
        var shadow = Math.Clamp(layer.Value(AnimProperty.ShadowOpacity, t), 0, 1);
        var glow = Math.Clamp(layer.Value(AnimProperty.Glow, t), 0, 4);
        // Layers with a mesh warp (2.5D rotation, corner pin, puppet pins) are drawn flat, then warped.
        MeshWarp? warp = null;
        var flat = default(Rect);
        if (layer.RotationXYOrPinned && layer.Type != LayerType.Particles && ContentPainter.FlatBounds(_device, scene, layer, t) is { } fb)
        {
            var box = ContentPainter.WipeBox(_device, scene, layer, t);
            if (box.Width <= 0 || box.Height <= 0) box = fb;
            warp = MeshWarp.Of(layer, box.X, box.Y, box.Width, box.Height, t);
            if (warp is { HideBackface: true, FacesAway: true }) return;
            flat = fb;
        }
        var fx = new PixelEffects(layer, t, scene.Fps);
        var pixels = fx.NeedsPixels;
        var simple = blendMode == BlendMode.Normal && sigma <= 0.125 && colorMatrix == null && shadow <= 0.001
            && glow <= 0.001 && layer.Type is not (LayerType.Group or LayerType.Particles) && warp == null && !pixels && fx.Shine <= 0.001;

        if (simple)
        {
            using var ds = acc.CreateDrawingSession();
            ds.Transform = dm;
            if (opacity < 1)
            {
                using (ds.CreateLayer((float)opacity)) ContentPainter.Draw(ds, scene, layer, t);
            }
            else ContentPainter.Draw(ds, scene, layer, t);
            return;
        }

        // The layer alone, in device pixels.
        var content = NewTarget();
        if (warp != null) DrawWarped(content, scene, layer, t, dm, warp, flat, depth);
        else if (layer.Type == LayerType.Group) DrawGroup(content, scene, layer, t, dm, depth);
        else if (layer.Type == LayerType.Particles)
        {
            // Particles take the opacity one by one (and add up among themselves when the blend mode is add).
            using var ds = content.CreateDrawingSession();
            ds.Transform = dm;
            if (blendMode == BlendMode.Add) ds.Blend = CanvasBlend.Add;
            ParticlePainter.Draw(ds, layer, _particles ?? [], opacity);
            opacity = 1;
        }
        else
        {
            using var ds = content.CreateDrawingSession();
            ds.Transform = dm;
            ContentPainter.Draw(ds, scene, layer, t);
        }

        ICanvasImage picture = content;
        var blurred = false;
        if (pixels)
        {
            // Keying, distortion, grading, stylize…: on the CPU over the area the layer can reach (the color matrix
            // goes with them), before and after the gaussian blur.
            var (ax, ay, aw, ah) = PixelArea(scene, layer, t, dm, fx, sigma, warp != null);
            if (aw > 0 && ah > 0)
            {
                var scale = Math.Sqrt(Math.Abs(dm.GetDeterminant()));
                double cx = dm.M31 - ax, cy = dm.M32 - ay;
                var bytes = content.GetPixelBytes(ax, ay, aw, ah);
                fx.ApplyBeforeBlur(new PixelBuffer(bytes, aw, ah), cx, cy, scale);
                content.SetPixelBytes(bytes, ax, ay, aw, ah);
                if (fx.HasAfterBlur(scale))
                {
                    var target = content;
                    if (sigma > 0.125)
                    {
                        target = NewTarget();
                        using (var ds = target.CreateDrawingSession())
                            ds.DrawImage(new GaussianBlurEffect { Source = content, BlurAmount = sigma, BorderMode = EffectBorderMode.Soft, Optimization = EffectOptimization.Balanced });
                        blurred = true;
                    }
                    var after = target.GetPixelBytes(ax, ay, aw, ah);
                    fx.ApplyAfterBlur(new PixelBuffer(after, aw, ah), cx, cy, scale, _pixelScale);
                    target.SetPixelBytes(after, ax, ay, aw, ah);
                    picture = target;
                }
            }
        }
        else if (colorMatrix != null) picture = new ColorMatrixEffect { Source = picture, ColorMatrix = ToMatrix(colorMatrix), ClampOutput = true };
        var corrected = pixels ? content : picture;
        if (sigma > 0.125 && !blurred)
            picture = new GaussianBlurEffect { Source = picture, BlurAmount = sigma, BorderMode = EffectBorderMode.Soft, Optimization = EffectOptimization.Balanced };
        if (fx.Shine > 0.001) picture = Shine(picture, scene, layer, t, dm, fx.Shine);
        if (shadow > 0.001)
        {
            // Drop shadow of the whole layer. Offsets are in scene pixels (y down), independent of rotation.
            var c = layer.ShadowColor with { A = layer.ShadowColor.A * shadow };
            var shadowImage = new Transform2DEffect
            {
                Source = new ShadowEffect
                {
                    Source = picture, ShadowColor = ToColor(c),
                    BlurAmount = (float)(Math.Max(0, layer.Value(AnimProperty.ShadowBlur, t)) * _pixelScale / 2),
                },
                TransformMatrix = Matrix3x2.CreateTranslation(
                    (float)(layer.Value(AnimProperty.ShadowX, t) * _pixelScale), (float)(layer.Value(AnimProperty.ShadowY, t) * _pixelScale)),
            };
            picture = new CompositeEffect { Sources = { shadowImage, picture } };
        }

        Composite(acc, picture, blendMode, opacity);

        if (glow > 0.001)
        {
            // Light added on top of the layer: its blurred copy (or that shape in glowColor), glow times over.
            ICanvasImage g = new GaussianBlurEffect
            {
                Source = corrected, BlurAmount = (float)(Math.Max(1, layer.Value(AnimProperty.GlowRadius, t)) * _pixelScale / 2),
                BorderMode = EffectBorderMode.Soft,
            };
            if (layer.GlowColor is { } tint)
                g = new CompositeEffect { Mode = CanvasComposite.SourceIn, Sources = { g, new ColorSourceEffect { Color = ToColor(tint) } } };
            using var ds = acc.CreateDrawingSession();
            for (var left = glow; left > 0.001; left -= 1)
                ds.DrawImage(g, Vector2.Zero, Frame, (float)(Math.Min(left, 1) * opacity), CanvasImageInterpolation.Linear, CanvasComposite.Add);
        }
    }

    /// <summary>Device-pixel area the layer can reach once processed and blurred (the whole frame when unknown).</summary>
    (int X, int Y, int W, int H) PixelArea(MotionScene scene, MotionLayer layer, double t, Matrix3x2 dm, PixelEffects fx,
        float sigma, bool warped)
    {
        if (warped || layer.Type == LayerType.Particles || ContentPainter.FlatBounds(_device, scene, layer, t) is not { } b)
            return (0, 0, _pw, _ph);
        var r = fx.Reach(b.Width);
        double x0 = b.X - r, y0 = b.Y - r, x1 = b.X + b.Width + r, y1 = b.Y + b.Height + r;
        // Twirl and bulge pull pixels around anywhere inside their radius.
        if (fx.Twirl != 0 || fx.Bulge != 0)
        {
            x0 = Math.Min(x0, -fx.Radius); y0 = Math.Min(y0, -fx.Radius);
            x1 = Math.Max(x1, fx.Radius); y1 = Math.Max(y1, fx.Radius);
        }
        // Zoom blur smears outward from the origin, up to 1 / (1 - amount) times as far.
        if (fx.ZoomBlur > 0.001)
        {
            var k = 1 / (1 - fx.ZoomBlur);
            x0 = Math.Min(x0, x0 * k); y0 = Math.Min(y0, y0 * k);
            x1 = Math.Max(x1, x1 * k); y1 = Math.Max(y1, y1 * k);
        }
        Vector2[] corners = [new((float)x0, (float)y0), new((float)x1, (float)y0), new((float)x1, (float)y1), new((float)x0, (float)y1)];
        var pts = corners.Select(c => Vector2.Transform(c, dm)).ToArray();
        var reach = 3 * sigma + 2;
        int ax = Math.Max(0, (int)Math.Floor(pts.Min(p => p.X) - reach)), ay = Math.Max(0, (int)Math.Floor(pts.Min(p => p.Y) - reach));
        int bx = Math.Min(_pw, (int)Math.Ceiling(pts.Max(p => p.X) + reach)), by = Math.Min(_ph, (int)Math.Ceiling(pts.Max(p => p.Y) + reach));
        return bx > ax && by > ay ? (ax, ay, bx - ax, by - ay) : (0, 0, 0, 0);
    }

    /// <summary>A soft bright band across the layer's box, only where the layer has pixels (light sweep). Port of
    /// <c>drawShine</c>.</summary>
    ICanvasImage Shine(ICanvasImage picture, MotionScene scene, MotionLayer layer, double t, Matrix3x2 dm, double strength)
    {
        var box = ContentPainter.WipeBox(_device, scene, layer, t);
        if (box.Width <= 0 || box.Height <= 0) return picture;
        var pos = layer.Value(AnimProperty.ShinePosition, t);
        var angle = layer.Value(AnimProperty.ShineAngle, t) * Math.PI / 180;
        var width = Math.Max(1, layer.Value(AnimProperty.ShineWidth, t));
        var color = layer.ShineColor ?? new Rgba(1, 1, 1, 0.8);
        var mid = color with { A = Math.Min(1, color.A * Math.Min(strength, 1)) };
        var clear = color with { A = 0 };
        // The band's center travels along the box's width (turned by the angle), from before its left edge to past
        // its right one.
        double dx = Math.Cos(angle), dy = Math.Sin(angle);
        var span = Math.Abs(dx) * box.Width + Math.Abs(dy) * box.Height;
        double cx = box.X + box.Width / 2 + dx * (pos - 0.5) * (span + width), cy = box.Y + box.Height / 2 + dy * (pos - 0.5) * (span + width);
        var band = new CanvasCommandList(_device);
        using (var ds = band.CreateDrawingSession())
        {
            ds.Transform = dm;
            using var brush = new CanvasLinearGradientBrush(ds, [
                new CanvasGradientStop { Position = 0, Color = ToColor(clear) },
                new CanvasGradientStop { Position = 0.5f, Color = ToColor(mid) },
                new CanvasGradientStop { Position = 1, Color = ToColor(clear) }])
            {
                StartPoint = new Vector2((float)(cx - dx * width / 2), (float)(cy - dy * width / 2)),
                EndPoint = new Vector2((float)(cx + dx * width / 2), (float)(cy + dy * width / 2)),
            };
            var reach = (float)(span + width) * 4;
            for (var left = strength; left > 0.001; left -= 1)
            {
                brush.Opacity = (float)Math.Min(left, 1);
                ds.FillRectangle((float)cx - reach, (float)cy - reach, 2 * reach, 2 * reach, brush);
            }
        }
        return new CompositeEffect { Mode = CanvasComposite.SourceAtop, Sources = { picture, band } };
    }

    /// <summary>A group's children, drawn in its box (a scene of its own: origin at the box's top-left, no camera).</summary>
    void DrawGroup(CanvasRenderTarget content, MotionScene scene, MotionLayer layer, double t, Matrix3x2 dm, int depth)
    {
        var sub = scene.Subscene(layer, t);
        float w = sub.Width, h = sub.Height;
        var childToDevice = Matrix3x2.CreateTranslation(-w / 2, -h / 2) * dm;
        var children = NewTarget();
        DrawScene(children, sub, t, childToDevice, depth);
        using var ds = content.CreateDrawingSession();
        using var clip = CanvasGeometry.CreateRectangle(ds, -w / 2, -h / 2, w, h).Transform(dm);
        using (ds.CreateLayer(1, clip)) ds.DrawImage(children);
    }

    /// <summary>
    /// Draws the layer flat into a bitmap at twice the device resolution (+2 device px of transparent margin, so its
    /// edges get antialiased by the resampling), then warps it: through one homography (Direct2D's 3D transform, a
    /// true perspective warp) for rotation and corner pin, or for puppet pins each cell of a grid as two triangles
    /// mapped by an affine transform. Port of <c>drawWarped</c> in <c>Renderer.swift</c>.
    /// </summary>
    void DrawWarped(CanvasRenderTarget content, MotionScene scene, MotionLayer layer, double t, Matrix3x2 dm, MeshWarp warp,
        Rect flat, int depth)
    {
        var scale = Math.Max(0.05, Math.Sqrt(Math.Abs(dm.GetDeterminant())));
        var margin = 2 / scale;
        flat = new Rect(flat.X - margin, flat.Y - margin, flat.Width + 2 * margin, flat.Height + 2 * margin);
        // Never more than 4096 px a side (a corner pin can blow a small layer up a lot).
        var k = Math.Min(scale * 2, Math.Min(4096 / Math.Max(flat.Width, 1), 4096 / Math.Max(flat.Height, 1)));
        int pw = Math.Max(1, (int)Math.Ceiling(flat.Width * k)), ph = Math.Max(1, (int)Math.Ceiling(flat.Height * k));
        // Layer px → flat bitmap px.
        var toFlat = Matrix3x2.CreateTranslation((float)-flat.X, (float)-flat.Y) * Matrix3x2.CreateScale((float)(pw / flat.Width), (float)(ph / flat.Height));
        Matrix3x2.Invert(toFlat, out var fromFlat);
        using var bitmap = new CanvasRenderTarget(_device, pw, ph, 96);
        if (layer.Type == LayerType.Group)
        {
            var child = new FrameCompositor(_device, (float)(_pixelScale * k / scale), pw, ph);
            try
            {
                using (var ds = bitmap.CreateDrawingSession()) ds.Clear(Transparent);
                child.DrawGroup(bitmap, scene, layer, t, toFlat, depth);
            }
            finally { child.DisposeTemps(); }
        }
        else
        {
            using var ds = bitmap.CreateDrawingSession();
            ds.Clear(Transparent);
            ds.Transform = toFlat;
            ContentPainter.Draw(ds, scene, layer, t);
        }

        if (warp.ProjectiveMap(flat.X, flat.Y, flat.Width, flat.Height) is { } h)
        {
            // Bitmap px → layer → warped layer (homography) → device, as one projective 4×4 matrix.
            var homography = new Matrix4x4(
                (float)h[0], (float)h[3], 0, (float)h[6],
                (float)h[1], (float)h[4], 0, (float)h[7],
                0, 0, 1, 0,
                (float)h[2], (float)h[5], 0, 1);
            // Resources a session drew are disposed only after it ends (Direct2D draws when the session closes).
            using var effect = new Transform3DEffect
            {
                Source = bitmap, TransformMatrix = Affine4(fromFlat) * homography * Affine4(dm),
                InterpolationMode = CanvasImageInterpolation.MultiSampleLinear, BorderMode = EffectBorderMode.Soft,
            };
            using (var ds = content.CreateDrawingSession()) ds.DrawImage(effect);
            return;
        }
        var clips = new List<CanvasGeometry>();
        var dsc = content.CreateDrawingSession();
        // Puppet pins: a grid of triangles, each clipped without antialiasing so neighbors share their edge pixels
        // exactly (each pixel is drawn once).
        var n = warp.Cells;
        var grid = new PathPoint[n + 1, n + 1];
        var src = new PathPoint[n + 1, n + 1];
        for (var j = 0; j <= n; j++)
            for (var i = 0; i <= n; i++)
            {
                src[j, i] = new PathPoint(flat.X + flat.Width * i / n, flat.Y + flat.Height * j / n);
                grid[j, i] = warp.Map(src[j, i]);
            }
        dsc.Antialiasing = CanvasAntialiasing.Aliased;
        void Triangle(PathPoint s0, PathPoint s1, PathPoint s2, PathPoint d0, PathPoint d1, PathPoint d2)
        {
            var det = (s1.X - s0.X) * (s2.Y - s0.Y) - (s2.X - s0.X) * (s1.Y - s0.Y);
            if (Math.Abs(det) <= 1e-9) return;
            double ia = (s2.Y - s0.Y) / det, ib = -(s2.X - s0.X) / det, ic = -(s1.Y - s0.Y) / det, id = (s1.X - s0.X) / det;
            double ux = d1.X - d0.X, uy = d1.Y - d0.Y, vx = d2.X - d0.X, vy = d2.Y - d0.Y;
            double a = ux * ia + vx * ic, b = uy * ia + vy * ic, c = ux * ib + vx * id, dd = uy * ib + vy * id;
            double tx = d0.X - a * s0.X - c * s0.Y, ty = d0.Y - b * s0.X - dd * s0.Y;
            var affine = new Matrix3x2((float)a, (float)b, (float)c, (float)dd, (float)tx, (float)ty);
            dsc.Transform = dm;
            var clip = CanvasGeometry.CreatePolygon(dsc, [V(d0), V(d1), V(d2)]);
            clips.Add(clip);
            using (dsc.CreateLayer(1, clip))
            {
                dsc.Transform = fromFlat * affine * dm;
                dsc.DrawImage(bitmap, 0, 0, bitmap.Bounds, 1, CanvasImageInterpolation.HighQualityCubic);
            }
        }
        try
        {
            for (var j = 0; j < n; j++)
                for (var i = 0; i < n; i++)
                {
                    Triangle(src[j, i], src[j, i + 1], src[j + 1, i + 1], grid[j, i], grid[j, i + 1], grid[j + 1, i + 1]);
                    Triangle(src[j, i], src[j + 1, i + 1], src[j + 1, i], grid[j, i], grid[j + 1, i + 1], grid[j + 1, i]);
                }
        }
        finally
        {
            dsc.Dispose();
            foreach (var c in clips) c.Dispose();
        }
    }

    static Vector2 V(PathPoint p) => new((float)p.X, (float)p.Y);

    static Matrix4x4 Affine4(Matrix3x2 m) => new(
        m.M11, m.M12, 0, 0,
        m.M21, m.M22, 0, 0,
        0, 0, 1, 0,
        m.M31, m.M32, 0, 1);

    /// <summary>Puts a layer's picture onto what is below with its blend mode and opacity.</summary>
    void Composite(CanvasRenderTarget acc, ICanvasImage picture, BlendMode mode, double opacity)
    {
        switch (mode)
        {
            case BlendMode.Normal:
            {
                using var ds = acc.CreateDrawingSession();
                ds.DrawImage(picture, Vector2.Zero, Frame, (float)opacity);
                return;
            }
            case BlendMode.Add:
            {
                using var ds = acc.CreateDrawingSession();
                ds.DrawImage(picture, Vector2.Zero, Frame, (float)opacity, CanvasImageInterpolation.Linear, CanvasComposite.Add);
                return;
            }
        }
        // Blend modes read what is below: blend a copy of it with the layer and write the result back.
        var below = NewTarget();
        below.CopyPixelsFromBitmap(acc);
        ICanvasImage fg = opacity < 1 ? new OpacityEffect { Source = picture, Opacity = (float)opacity } : picture;
        var blend = new BlendEffect
        {
            Background = below, Foreground = fg,
            Mode = mode switch
            {
                BlendMode.Screen => BlendEffectMode.Screen,
                BlendMode.Multiply => BlendEffectMode.Multiply,
                BlendMode.Overlay => BlendEffectMode.Overlay,
                BlendMode.Lighten => BlendEffectMode.Lighten,
                _ => BlendEffectMode.Darken,
            },
        };
        using var dsb = acc.CreateDrawingSession();
        dsb.Blend = CanvasBlend.Copy;
        dsb.DrawImage(blend);
    }

    /// <summary><c>out = m · rgb + b</c> as Direct2D's row-vector 5×4 matrix (alpha kept).</summary>
    static Matrix5x4 ToMatrix(ColorMatrix c) => new()
    {
        M11 = (float)c.M[0], M21 = (float)c.M[1], M31 = (float)c.M[2],
        M12 = (float)c.M[3], M22 = (float)c.M[4], M32 = (float)c.M[5],
        M13 = (float)c.M[6], M23 = (float)c.M[7], M33 = (float)c.M[8],
        M44 = 1,
        M51 = (float)c.B[0], M52 = (float)c.B[1], M53 = (float)c.B[2],
    };

    public static Color ToColor(Rgba c)
    {
        static byte B(double x) => (byte)Math.Round(Math.Clamp(x, 0, 1) * 255);
        return Color.FromArgb(B(c.A), B(c.R), B(c.G), B(c.B));
    }
}
