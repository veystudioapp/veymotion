using System.Numerics;

namespace VeyMotion.Core;

using AnimValue = Animated<double>;
using MotionKeyframe = Keyframe<double>;

/// <summary>One analyzed moment of a video layer.</summary>
/// <param name="T">Scene time.</param>
/// <param name="X">Center x in scene pixels (before the camera).</param>
/// <param name="Y">Center y in scene pixels (before the camera).</param>
/// <param name="Width">Size in scene pixels.</param>
/// <param name="Height">Size in scene pixels.</param>
public readonly record struct VideoSample(double T, double X, double Y, double Width, double Height, double Confidence);

/// <summary>Analysis of video layers: following an object through the frames (motion tracking), finding where the eye
/// goes (saliency) to keep the subject framed in another aspect ratio (auto-reframe), and the camera's drift
/// (stabilization). Port of <c>VideoTracking</c> (<c>Tracking.swift</c>, <c>VideoML.swift</c>) with pure C# analysis in
/// place of Vision: template matching, spectral-residual + color-contrast saliency, phase correlation.</summary>
public static class VideoTracking
{
    /// <summary>Longest side of the frames object tracking works on.</summary>
    public const int TrackSide = 640;
    /// <summary>Longest side of the frames saliency works on (the map itself is 64 × 64).</summary>
    public const int SaliencySide = 256;
    /// <summary>Longest side of the frames registration works on (FFT crop ≤ 512).</summary>
    public const int RegistrationSide = 640;

    /// <summary>"~/x" → the user's folder + "/x".</summary>
    public static string ExpandPath(string path)
    {
        if (path == "~" || path.StartsWith("~/") || path.StartsWith("~\\"))
            return Path.Join(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path.Length > 1 ? path[2..] : "");
        return path;
    }

    /// <summary>Where a video layer's picture sits: its layer-local rect (x, y, w, h) for the source's pixel size.</summary>
    public static (double X, double Y, double W, double H) Placement(MotionLayer layer, (int Width, int Height) size, double t)
    {
        double iw = size.Width, ih = size.Height;
        double? setW = layer.Width?.ValueAt(t) is { } a && a > 0 ? a : null;
        double? setH = layer.Height?.ValueAt(t) is { } b && b > 0 ? b : null;
        double w = setW ?? iw, h = setH ?? ih;
        if (setW != null && setH == null) h = w * ih / iw;
        if (setH != null && setW == null) w = h * iw / ih;
        return (-w / 2, -h / 2, w, h);
    }

    /// <summary>Scene times at which to analyze: every <paramref name="step"/> seconds (at least one frame) from
    /// <paramref name="from"/> to <paramref name="to"/>.</summary>
    public static List<double> Times(MotionScene scene, MotionLayer layer, double from, double to, double step)
    {
        var dt = Math.Max(step, 1.0 / Math.Max(scene.Fps, 1));
        var o = new List<double>();
        var t = from;
        var end = Math.Min(to, layer.EffectiveEnd(scene.Duration));
        while (t <= end + 1e-6) { o.Add(t); t += dt; }
        if (o.Count > 0 && end - o[^1] > dt * 0.5) o.Add(end);
        return o;
    }

    /// <summary>A normalized box (origin top-left) on the picture → scene pixels through the layer's transform at t.</summary>
    public static ((double X, double Y) Center, (double W, double H) Size) ToScene((double X, double Y, double W, double H) box,
        MotionLayer layer, MotionScene scene, (int Width, int Height) size, double t)
    {
        var rect = Placement(layer, size, t);
        var m = scene.SceneTransform(layer, t);
        double lx = rect.X + (box.X + box.W / 2) * rect.W, ly = rect.Y + (box.Y + box.H / 2) * rect.H;
        var a = Vector2.Transform(new Vector2((float)lx, (float)ly), m);
        var b = Vector2.Transform(new Vector2((float)(lx + box.W * rect.W), (float)(ly + box.H * rect.H)), m);
        return ((a.X, a.Y), (Math.Abs(b.X - a.X), Math.Abs(b.Y - a.Y)));
    }

    static string OpenVideo(MotionLayer layer, IVideoFrameReader frames, out (int Width, int Height) size)
    {
        size = default;
        if (layer.Type != LayerType.Video || layer.Path is not { } p || frames.Size(ExpandPath(p)) is not { Width: > 0, Height: > 0 } s)
            throw new SceneException($"'{layer.Id}' is not a video layer with a readable source");
        size = s;
        return ExpandPath(p);
    }

    static Matrix3x2 Inverted(Matrix3x2 m) => Matrix3x2.Invert(m, out var inv) ? inv : m;

    /// <summary>Follows the object inside the box (scene pixels at <paramref name="from"/>) through the video layer's
    /// frames.</summary>
    public static List<VideoSample> Track(MotionLayer layer, MotionScene scene, (double X, double Y, double W, double H) box,
        double from, double to, double step, IVideoFrameReader frames)
    {
        var path = OpenVideo(layer, frames, out var size);
        var rect = Placement(layer, size, from);
        var inv = Inverted(scene.SceneTransform(layer, from));
        var lo = Vector2.Transform(new Vector2((float)box.X, (float)box.Y), inv);
        var hi = Vector2.Transform(new Vector2((float)(box.X + box.W), (float)(box.Y + box.H)), inv);
        double u0 = (Math.Min(lo.X, hi.X) - rect.X) / rect.W, u1 = (Math.Max(lo.X, hi.X) - rect.X) / rect.W;
        double v0 = (Math.Min(lo.Y, hi.Y) - rect.Y) / rect.H, v1 = (Math.Max(lo.Y, hi.Y) - rect.Y) / rect.H;
        double sx = Math.Max(0, u0), sy = Math.Max(0, v0);
        double sw = Math.Min(1, u1) - sx, sh = Math.Min(1, v1) - sy;
        if (!(sw > 0.005 && sh > 0.005)) throw new SceneException("The box must be inside the video");
        var fps = layer.Fps ?? scene.Fps;
        TemplateTracker? tracker = null;
        var o = new List<VideoSample>();
        var lost = 0;
        foreach (var t in Times(scene, layer, from, to, step))
        {
            if (layer.VideoTime(t) is not { } vt || frames.Frame(path, vt, fps, TrackSide) is not { } image
                || GrayPlane.FromBgra(image, TrackSide) is not { } gray) continue;
            tracker ??= new TemplateTracker(gray, sx, sy, sw, sh);
            if (!tracker.Update(gray, out var found, out var confidence))
            {
                lost++;
                if (lost > 5) break;
                continue;
            }
            var (c, sz) = ToScene((found.X - found.W / 2, found.Y - found.H / 2, found.W, found.H), layer, scene, size, t);
            o.Add(new VideoSample(t, c.X, c.Y, sz.W, sz.H, confidence));
        }
        if (o.Count == 0) throw new SceneException("Nothing could be tracked (no frames, or the object was lost at once)");
        return o;
    }

    /// <summary>Where attention goes in each sampled frame: the most salient region's center in scene pixels.</summary>
    public static List<VideoSample> Saliency(MotionLayer layer, MotionScene scene, double from, double to, double step,
        IVideoFrameReader frames)
    {
        var path = OpenVideo(layer, frames, out var size);
        var fps = layer.Fps ?? scene.Fps;
        var o = new List<VideoSample>();
        foreach (var t in Times(scene, layer, from, to, step))
        {
            if (layer.VideoTime(t) is not { } vt || frames.Frame(path, vt, fps, SaliencySide) is not { } image) continue;
            var regions = SaliencyMap.Regions(image);
            if (regions.Count == 0) continue;
            // The union of the salient boxes, weighted toward the strongest.
            double x0 = regions[0].X, y0 = regions[0].Y, x1 = x0 + regions[0].Width, y1 = y0 + regions[0].Height;
            foreach (var r in regions.Skip(1).Where(r => r.Confidence > 0.5))
            {
                x0 = Math.Min(x0, r.X); y0 = Math.Min(y0, r.Y);
                x1 = Math.Max(x1, r.X + r.Width); y1 = Math.Max(y1, r.Y + r.Height);
            }
            var (c, sz) = ToScene((x0, y0, x1 - x0, y1 - y0), layer, scene, size, t);
            o.Add(new VideoSample(t, c.X, c.Y, sz.W, sz.H, regions[0].Confidence));
        }
        if (o.Count == 0) throw new SceneException("No frames could be analyzed");
        return o;
    }

    /// <summary>Camera drift of each sampled frame relative to the first, in scene pixels (translation only), from
    /// frame-to-frame registration.</summary>
    public static List<VideoSample> Shake(MotionLayer layer, MotionScene scene, double from, double to, double step,
        IVideoFrameReader frames)
    {
        var path = OpenVideo(layer, frames, out var size);
        var fps = layer.Fps ?? scene.Fps;
        var o = new List<VideoSample>();
        PhaseCorrelation.Spectrum? prev = null;
        double accX = 0, accY = 0;
        var rect = Placement(layer, size, from);
        double sx = rect.W / Math.Max(size.Width, 1), sy = rect.H / Math.Max(size.Height, 1);
        var k = layer.Scale.ValueAt(from);
        foreach (var t in Times(scene, layer, from, to, step))
        {
            if (layer.VideoTime(t) is not { } vt || frames.Frame(path, vt, fps, RegistrationSide) is not { } image
                || GrayPlane.FromBgra(image, RegistrationSide) is not { } gray) continue;
            var spectrum = PhaseCorrelation.Prepare(gray)
                ?? throw new SceneException($"Registration failed at {VideoAnalysisTools.SwiftDouble(t)}s: the frame is too small");
            if (prev != null)
            {
                // How far this frame's content moved since the previous one (source px, y down).
                var (dx, dy, _) = PhaseCorrelation.Shift(prev, spectrum);
                accX += dx * size.Width / gray.W;
                accY += dy * size.Height / gray.H;
            }
            prev = spectrum;
            o.Add(new VideoSample(t, accX * sx * k, accY * sy * k, 0, 0, 1));
        }
        if (o.Count < 2) throw new SceneException("Not enough frames to stabilize");
        return o;
    }

    /// <summary>Smooths a series of positions with a centered moving average over <paramref name="window"/> samples.</summary>
    public static List<VideoSample> Smoothed(IReadOnlyList<VideoSample> samples, int window)
    {
        if (window <= 1 || samples.Count <= 2) return samples.ToList();
        var half = window / 2;
        var o = new List<VideoSample>(samples.Count);
        for (var i = 0; i < samples.Count; i++)
        {
            int lo = Math.Max(0, i - half), hi = Math.Min(samples.Count - 1, i + half);
            double x = 0, y = 0;
            for (var j = lo; j <= hi; j++) { x += samples[j].X; y += samples[j].Y; }
            var n = hi - lo + 1;
            o.Add(samples[i] with { X = x / n, Y = y / n });
        }
        return o;
    }
}

/// <summary>Scene edits driven by video analysis. Port of the <c>MotionScene</c> extensions in <c>Tracking.swift</c> and
/// <c>VideoML.swift</c>.</summary>
public static class VideoTrackingOps
{
    static Matrix3x2 Inverted(Matrix3x2 m) => Matrix3x2.Invert(m, out var inv) ? inv : m;

    /// <summary>Keyframes <paramref name="target"/>'s position (and optionally scale) to follow a tracked object in a
    /// video layer. <paramref name="keepOffset"/> keeps the target where it is relative to the object at the first
    /// sample.</summary>
    public static void Attach(this MotionScene s, string target, IReadOnlyList<VideoSample> samples, bool keepOffset, bool scale)
    {
        if (samples.Count == 0) return;
        var first = samples[0];
        var parent = Inverted(s.ParentTransform(s.Layer(target), first.T));
        s.WithLayer(target, l =>
        {
            var p0 = l.Position(first.T).Point;
            double dx = keepOffset ? p0.X - first.X : 0, dy = keepOffset ? p0.Y - first.Y : 0;
            List<MotionKeyframe> xs = [], ys = [], ss = [];
            var s0 = l.Scale.ValueAt(first.T);
            foreach (var smp in samples)
            {
                var p = Vector2.Transform(new Vector2((float)(smp.X + dx), (float)(smp.Y + dy)), parent);
                xs.Add(new MotionKeyframe(smp.T, p.X, Easing.Linear));
                ys.Add(new MotionKeyframe(smp.T, p.Y, Easing.Linear));
                if (scale && first.Width > 1) ss.Add(new MotionKeyframe(smp.T, s0 * smp.Width / first.Width, Easing.Linear));
            }
            l.MotionPath = null;
            l.X = AnimValue.Make(xs, p0.X);
            l.Y = AnimValue.Make(ys, p0.Y);
            if (scale && ss.Count > 0) l.Scale = AnimValue.Make(ss, s0);
        });
    }

    /// <summary>Moves a video layer over time so the salient point stays in the middle of a
    /// <paramref name="targetWidth"/>:<paramref name="targetHeight"/> crop of the scene (export with that size and fit
    /// "crop"), without ever showing the video's edges.</summary>
    public static void Reframe(this MotionScene s, string id, IReadOnlyList<VideoSample> samples, double targetWidth, double targetHeight)
    {
        double w = s.Width, h = s.Height;
        // The crop window centered on the scene, in scene pixels.
        double cw = w, ch = h;
        if (targetWidth / targetHeight < w / h) cw = h * targetWidth / targetHeight; else ch = w * targetHeight / targetWidth;
        double cx = w / 2, cy = h / 2;
        s.WithLayer(id, l =>
        {
            if (l.Type != LayerType.Video) throw new SceneException($"'{id}' is not a video layer");
            var t0 = samples.Count > 0 ? samples[0].T : l.Start;
            double x0 = l.X.ValueAt(t0), y0 = l.Y.ValueAt(t0);
            // The video's extent in scene pixels (its placed size times its scale).
            var sc = l.Scale.ValueAt(t0);
            var vw = (l.Width?.ValueAt(t0) ?? w) * sc * l.Value(AnimProperty.ScaleX, t0);
            var vh = (l.Height?.ValueAt(t0) ?? h) * sc * l.Value(AnimProperty.ScaleY, t0);
            List<MotionKeyframe> xs = [], ys = [];
            foreach (var smp in samples)
            {
                // Move the layer so the salient point lands on the crop center, within the limits that keep the crop
                // covered.
                double x = x0 + (cx - smp.X), y = y0 + (cy - smp.Y);
                double xMin = cx + cw / 2 - vw / 2, xMax = cx - cw / 2 + vw / 2;
                double yMin = cy + ch / 2 - vh / 2, yMax = cy - ch / 2 + vh / 2;
                x = xMin <= xMax ? Math.Min(Math.Max(x, xMin), xMax) : cx;
                y = yMin <= yMax ? Math.Min(Math.Max(y, yMin), yMax) : cy;
                xs.Add(new MotionKeyframe(smp.T, x, Easing.EaseInOut));
                ys.Add(new MotionKeyframe(smp.T, y, Easing.EaseInOut));
            }
            l.MotionPath = null;
            l.X = AnimValue.Make(xs, x0);
            l.Y = AnimValue.Make(ys, y0);
        });
    }

    /// <summary>Moves a video layer against its camera shake: <paramref name="lockMotion"/> cancels all motion, else
    /// only the jitter around a smoothed path (keeps intended pans). Scales it up by <paramref name="zoom"/> so the
    /// moving edges stay out of frame.</summary>
    public static void Stabilize(this MotionScene s, string id, IReadOnlyList<VideoSample> drift, bool lockMotion, int window, double zoom)
    {
        var smooth = VideoTracking.Smoothed(drift, Math.Max(3, window));
        s.WithLayer(id, l =>
        {
            if (l.Type != LayerType.Video) throw new SceneException($"'{id}' is not a video layer");
            var t0 = drift.Count > 0 ? drift[0].T : l.Start;
            double x0 = l.X.ValueAt(t0), y0 = l.Y.ValueAt(t0), s0 = l.Scale.ValueAt(t0);
            List<MotionKeyframe> xs = [], ys = [];
            for (var i = 0; i < Math.Min(drift.Count, smooth.Count); i++)
            {
                var d = drift[i]; var sm = smooth[i];
                var ox = lockMotion ? d.X : d.X - sm.X;
                var oy = lockMotion ? d.Y : d.Y - sm.Y;
                xs.Add(new MotionKeyframe(d.T, x0 - ox * zoom, Easing.Linear));
                ys.Add(new MotionKeyframe(d.T, y0 - oy * zoom, Easing.Linear));
            }
            l.MotionPath = null;
            l.X = AnimValue.Make(xs, x0);
            l.Y = AnimValue.Make(ys, y0);
            if (Math.Abs(zoom - 1) > 1e-6) l.Scale = s0 * zoom;
        });
    }
}
