namespace VeyMotion.Core;

/// <summary>Cuts the person or main subject out of a picture. Windows has no built-in segmentation, so the app plugs
/// one in (an ONNX model, Windows AI APIs…) through <see cref="PictureML.Remover"/>.</summary>
public interface IBackgroundRemover
{
    /// <summary>The picture with everything but the person / main subject made transparent (premultiplied BGRA, same
    /// size), or null with the reason in <paramref name="error"/>.</summary>
    BgraFrame? Remove(BgraFrame image, BackgroundRemoval mode, out string? error);
}

/// <summary>Picture work on image and video layers: background removal (through a pluggable remover), and slow-motion
/// frames in between source frames (cross-fade, or motion-compensated along a block-matching optical flow). Port of
/// <c>PictureML</c> (<c>VideoML.swift</c>); like macOS when Vision fails, everything falls back to the untouched
/// picture.</summary>
public static class PictureML
{
    /// <summary>Why removal is impossible when no remover is installed.</summary>
    public const string NoRemover = "no background remover is installed on Windows";

    /// <summary>The background remover, or null (pictures are then drawn whole).</summary>
    public static IBackgroundRemover? Remover { get; set; }

    /// <summary>Last failure message (shown by tools so agents know why nothing was cut out).</summary>
    public static string? LastError { get; set; }

    /// <summary>Tries the layer's background removal on its picture (first frame for videos): null when it works, else
    /// why not. <paramref name="loadImage"/> reads image layers' files (null = they cannot be read here).</summary>
    public static string? Probe(MotionLayer layer, IVideoFrameReader? frames, Func<string, BgraFrame?>? loadImage)
    {
        if (layer.RemoveBackground is not { } mode || layer.Path is not { } path) return null;
        if (Remover == null) return LastError = NoRemover;
        var expanded = VideoTracking.ExpandPath(path);
        BgraFrame? picture = layer.Type == LayerType.Video
            ? frames?.Frame(expanded, layer.TrimIn, layer.Fps ?? 30, 0)
            : loadImage?.Invoke(expanded);
        if (picture is not { IsValid: true } p) return "the picture could not be read";
        return RemoveBackground(p, mode) == null ? LastError ?? "segmentation failed" : null;
    }

    /// <summary>The note <c>update_layer</c> adds when <c>removeBackground</c> was just set and cannot work (port of the
    /// <c>cutout</c> lines in <c>MCPServer.swift</c>).</summary>
    public static List<string> CutoutNotes(MotionLayer updated, System.Text.Json.Nodes.JsonObject args,
        IVideoFrameReader? frames, Func<string, BgraFrame?>? loadImage)
    {
        if (updated.RemoveBackground == null || (args["changes"] as System.Text.Json.Nodes.JsonObject)?["removeBackground"] == null) return [];
        return Probe(updated, frames, loadImage) is { } why
            ? [$"Background removal did not work here ({why}); the picture is drawn whole."]
            : [];
    }

    /// <summary>The picture with everything but the person / main subject made transparent, or null on failure.</summary>
    public static BgraFrame? RemoveBackground(BgraFrame image, BackgroundRemoval mode)
    {
        if (Remover is not { } remover) { LastError = NoRemover; return null; }
        BgraFrame? result;
        string? error;
        try { result = remover.Remove(image, mode, out error); }
        catch (Exception e) { LastError = e.Message; return null; }
        if (result is not { IsValid: true } r || r.Width != image.Width || r.Height != image.Height)
        {
            LastError = error ?? "the remover found nothing to keep";
            return null;
        }
        LastError = null;
        return r;
    }

    // MARK: Frame blending

    /// <summary>For a frame-blended video layer at <paramref name="seconds"/> into the source: the two source frames to
    /// mix (times to ask the reader for) and the fraction of the second, or null to show the plain frame. Port of the
    /// timing in <c>FrameRenderer.videoFrame</c> (<c>Renderer.swift</c>).</summary>
    public static (double A, double B, double F)? FrameBlendTimes(MotionLayer layer, double seconds, double? frameDuration)
    {
        if (layer.FrameBlend == FrameBlend.Off) return null;
        var fps = layer.Fps ?? 30;
        var fd = frameDuration ?? 1 / Math.Max(fps, 1);
        if (!(fd > 0)) return null;
        var k = Math.Floor(seconds / fd + 1e-6);
        var f = seconds / fd - k;
        if (!(f > 0.02 && f < 0.98)) return null;
        return (k * fd + fd * 0.01, (k + 1) * fd + fd * 0.01, f);
    }

    /// <summary>The source frame at <paramref name="seconds"/>, or an in-between of the two nearest frames (frameBlend)
    /// for slow motion. Port of <c>FrameRenderer.videoFrame</c> for renderers that read through
    /// <see cref="IVideoFrameReader"/>.</summary>
    public static BgraFrame? VideoFrame(MotionLayer layer, IVideoFrameReader frames, string path, double seconds, int maxSide = 0)
    {
        var fps = layer.Fps ?? 30;
        if (FrameBlendTimes(layer, seconds, frames.FrameDuration(path)) is not { } plan
            || frames.Frame(path, plan.A, fps, maxSide) is not { IsValid: true } a
            || frames.Frame(path, plan.B, fps, maxSide) is not { IsValid: true } b)
            return frames.Frame(path, seconds, fps, maxSide);
        return InBetween(a, b, plan.F, layer.FrameBlend == FrameBlend.Flow) ?? a;
    }

    /// <summary>The frame between <paramref name="a"/> and <paramref name="b"/> at fraction f: a cross-fade, or both
    /// warped along the optical flow first. Null when the sizes differ.</summary>
    public static BgraFrame? InBetween(BgraFrame a, BgraFrame b, double f, bool flow)
    {
        if (!a.IsValid || !b.IsValid || a.Width != b.Width || a.Height != b.Height) return null;
        int w = a.Width, h = a.Height;
        var o = new byte[w * h * 4];
        f = Math.Clamp(f, 0, 1);
        if (flow && BlockFlow.Compute(a, b) is { } field)
        {
            // Each output pixel takes a at p - f·d and b at p + (1 - f)·d, mixed by f. The flow is known at a's
            // positions, so d solves d = flow(p - f·d) (a few fixed-point steps): moving content carries its own
            // vector instead of the background's. Solved on a 4 px grid, interpolated per pixel.
            const int Step = 4;
            int sw = w / Step + 2, sh = h / Step + 2;
            var back = new float[sw * sh * 2];
            Parallel.For(0, sh, j =>
            {
                for (var i = 0; i < sw; i++)
                {
                    double px = i * Step, py = j * Step;
                    var (dx, dy) = field.At(px, py);
                    for (var it = 0; it < 3; it++) (dx, dy) = field.At(px - f * dx, py - f * dy);
                    back[2 * (j * sw + i)] = (float)dx;
                    back[2 * (j * sw + i) + 1] = (float)dy;
                }
            });
            Parallel.For(0, h, y =>
            {
                Span<float> pa = stackalloc float[4], pb = stackalloc float[4];
                var gy = (y + 0.5) / Step;
                var j0 = Math.Min((int)gy, sh - 2);
                var fy = gy - j0;
                for (var x = 0; x < w; x++)
                {
                    var gx = (x + 0.5) / Step;
                    var i0 = Math.Min((int)gx, sw - 2);
                    var fx = gx - i0;
                    int k00 = 2 * (j0 * sw + i0), k10 = k00 + 2, k01 = k00 + 2 * sw, k11 = k01 + 2;
                    var dx = (back[k00] * (1 - fx) + back[k10] * fx) * (1 - fy) + (back[k01] * (1 - fx) + back[k11] * fx) * fy;
                    var dy = (back[k00 + 1] * (1 - fx) + back[k10 + 1] * fx) * (1 - fy) + (back[k01 + 1] * (1 - fx) + back[k11 + 1] * fx) * fy;
                    Bilinear(a, x + 0.5 - f * dx, y + 0.5 - f * dy, pa);
                    Bilinear(b, x + 0.5 + (1 - f) * dx, y + 0.5 + (1 - f) * dy, pb);
                    var o4 = 4 * (y * w + x);
                    for (var k = 0; k < 4; k++) o[o4 + k] = (byte)Math.Min(255, pa[k] * (1 - f) + pb[k] * f + 0.5);
                }
            });
            return new BgraFrame(w, h, o);
        }
        // b drawn over a at alpha f (premultiplied source-over).
        var fa = (float)f;
        for (var i = 0; i < o.Length; i += 4)
        {
            var keep = 1 - fa * b.Pixels[i + 3] / 255f;
            for (var k = 0; k < 4; k++) o[i + k] = (byte)Math.Min(255, b.Pixels[i + k] * fa + a.Pixels[i + k] * keep + 0.5f);
        }
        return new BgraFrame(w, h, o);
    }

    static void Bilinear(BgraFrame img, double x, double y, Span<float> into)
    {
        x -= 0.5; y -= 0.5;
        var fx0 = Math.Floor(x); var fy0 = Math.Floor(y);
        var fx = (float)(x - fx0); var fy = (float)(y - fy0);
        int w = img.Width, h = img.Height;
        int x0 = Math.Clamp((int)fx0, 0, w - 1), x1 = Math.Clamp((int)fx0 + 1, 0, w - 1);
        int y0 = Math.Clamp((int)fy0, 0, h - 1), y1 = Math.Clamp((int)fy0 + 1, 0, h - 1);
        int i00 = 4 * (y0 * w + x0), i10 = 4 * (y0 * w + x1), i01 = 4 * (y1 * w + x0), i11 = 4 * (y1 * w + x1);
        var p = img.Pixels;
        for (var k = 0; k < 4; k++)
        {
            var top = p[i00 + k] + (p[i10 + k] - p[i00 + k]) * fx;
            var bottom = p[i01 + k] + (p[i11 + k] - p[i01 + k]) * fx;
            into[k] = top + (bottom - top) * fy;
        }
    }
}

/// <summary>Background removal results cached per picture (a still image, or one video frame), like the renderer's
/// <c>cutoutCache</c> on macOS. Falls back to the untouched picture when removal fails.</summary>
public sealed class CutoutCache
{
    readonly Dictionary<string, BgraFrame> cache = [];
    readonly Lock gate = new();

    /// <param name="key">The picture's identity, e.g. <c>$"{layer.Path}|{layer.VideoTime(t) ?? -1}"</c>.</param>
    public BgraFrame CutOut(BgraFrame image, BackgroundRemoval mode, string key)
    {
        var k = $"{mode}|{key}|{image.Width}x{image.Height}";
        lock (gate) if (cache.TryGetValue(k, out var hit)) return hit;
        var result = PictureML.RemoveBackground(image, mode) ?? image;
        lock (gate)
        {
            if (cache.Count > 8) cache.Clear();
            cache[k] = result;
        }
        return result;
    }

    public void Clear() { lock (gate) cache.Clear(); }
}

/// <summary>Optical flow by hierarchical block matching (stand-in for Vision's <c>VNGenerateOpticalFlowRequest</c>):
/// 8 px blocks on a grayscale pyramid, a full search at the coarsest level, ±2 px refinements below, a 3 × 3 median
/// between levels and a sub-pixel parabola at the end.</summary>
internal sealed class BlockFlow
{
    const int Block = 8;
    const int MaxSide = 480;

    /// <summary>Grid size, image pixels per cell, and vectors (x, y pairs) in image pixels, y down.</summary>
    public int Gw, Gh;
    public double CellX, CellY;
    public float[] V = [];

    /// <summary>Flow at image position (x, y) (bilinear between cell centers): where the content at (x, y) in a is in b.</summary>
    public (double Dx, double Dy) At(double x, double y)
    {
        var gx = Math.Clamp(x / CellX - 0.5, 0, Gw - 1);
        var gy = Math.Clamp(y / CellY - 0.5, 0, Gh - 1);
        int x0 = (int)gx, y0 = (int)gy, x1 = Math.Min(x0 + 1, Gw - 1), y1 = Math.Min(y0 + 1, Gh - 1);
        double fx = gx - x0, fy = gy - y0;
        double Lerp(int c) =>
            (V[2 * (y0 * Gw + x0) + c] * (1 - fx) + V[2 * (y0 * Gw + x1) + c] * fx) * (1 - fy)
            + (V[2 * (y1 * Gw + x0) + c] * (1 - fx) + V[2 * (y1 * Gw + x1) + c] * fx) * fy;
        return (Lerp(0), Lerp(1));
    }

    /// <summary>Flow from a to b, or null when the frames are too small.</summary>
    public static BlockFlow? Compute(BgraFrame a, BgraFrame b)
    {
        if (GrayPlane.FromBgra(a, MaxSide) is not { } ga || GrayPlane.FromBgra(b, MaxSide) is not { } gb) return null;
        if (ga.W < 2 * Block || ga.H < 2 * Block) return null;
        var top = 0;
        while (top < 3 && Math.Min(ga.W, ga.H) >> (top + 1) >= 4 * Block) top++;
        var pa = ga.Pyramid(top); var pb = gb.Pyramid(top);
        top = Math.Min(pa.Count, pb.Count) - 1;

        float[]? prev = null;
        int pw = 0, ph = 0;
        float[] v = [];
        int gw = 0, gh = 0;
        var candidates = new List<(int X, int Y)>(10);
        for (var L = top; L >= 0; L--)
        {
            var la = pa[L]; var lb = pb[L];
            gw = (la.W + Block - 1) / Block; gh = (la.H + Block - 1) / Block;
            v = new float[gw * gh * 2];
            var last = L == 0;
            for (var gy = 0; gy < gh; gy++)
                for (var gx = 0; gx < gw; gx++)
                {
                    // Candidates: no motion, and twice the coarser level's vectors around this cell (so a small moving
                    // object's vector reaches every cell that covers it here), each refined ±1 px.
                    candidates.Clear();
                    candidates.Add((0, 0));
                    if (prev != null)
                        for (var ny = -1; ny <= 1; ny++)
                            for (var nx = -1; nx <= 1; nx++)
                            {
                                int cx = Math.Clamp(gx / 2 + nx, 0, pw - 1), cy = Math.Clamp(gy / 2 + ny, 0, ph - 1);
                                var c = ((int)Math.Round(2 * prev[2 * (cy * pw + cx)]), (int)Math.Round(2 * prev[2 * (cy * pw + cx) + 1]));
                                if (!candidates.Contains(c)) candidates.Add(c);
                            }
                    var r = prev == null ? 5 : 1;
                    var penalty = 0.001 / (1 << L);
                    double best = double.MaxValue; int bx = 0, by = 0;
                    foreach (var (ix, iy) in candidates)
                        for (var dy = -r; dy <= r; dy++)
                            for (var dx = -r; dx <= r; dx++)
                            {
                                int mx = ix + dx, my = iy + dy;
                                // Slight preference for small motion where texture does not decide.
                                var c = Sad(la, lb, gx * Block, gy * Block, mx, my) + penalty * (Math.Abs(mx) + Math.Abs(my));
                                if (c < best) { best = c; bx = mx; by = my; }
                            }
                    double sx = 0, sy = 0;
                    if (last)
                    {
                        double Cost(int mx, int my) => Sad(la, lb, gx * Block, gy * Block, mx, my) + penalty * (Math.Abs(mx) + Math.Abs(my));
                        sx = SubPixel(Cost(bx - 1, by), best, Cost(bx + 1, by));
                        sy = SubPixel(Cost(bx, by - 1), best, Cost(bx, by + 1));
                    }
                    v[2 * (gy * gw + gx)] = (float)(bx + sx);
                    v[2 * (gy * gw + gx) + 1] = (float)(by + sy);
                }
            // Outliers out at the end only: on the coarse grids a median would erase small moving objects.
            if (last) v = Median(v, gw, gh);
            prev = v; pw = gw; ph = gh;
        }
        var scale = (double)a.Width / ga.W;
        for (var i = 0; i < v.Length; i++) v[i] = (float)(v[i] * (i % 2 == 0 ? scale : (double)a.Height / ga.H));
        return new BlockFlow
        {
            Gw = gw, Gh = gh, V = v,
            CellX = Block * (double)a.Width / ga.W, CellY = Block * (double)a.Height / ga.H,
        };
    }

    /// <summary>Mean absolute difference of a's block at (x0, y0) with b's at (x0 + dx, y0 + dy).</summary>
    static double Sad(GrayPlane a, GrayPlane b, int x0, int y0, int dx, int dy)
    {
        double s = 0; var n = 0;
        var yEnd = Math.Min(y0 + Block, a.H); var xEnd = Math.Min(x0 + Block, a.W);
        for (var y = y0; y < yEnd; y++)
        {
            var by = Math.Clamp(y + dy, 0, b.H - 1) * b.W;
            var ay = y * a.W;
            for (var x = x0; x < xEnd; x++)
            {
                s += Math.Abs(a.P[ay + x] - b.P[by + Math.Clamp(x + dx, 0, b.W - 1)]);
                n++;
            }
        }
        return n > 0 ? s / n : 0;
    }

    static double SubPixel(double l, double c, double r)
    {
        var d = l - 2 * c + r;
        return d > 1e-9 ? Math.Clamp(0.5 * (l - r) / d, -0.5, 0.5) : 0;
    }

    static float[] Median(float[] v, int gw, int gh)
    {
        var o = new float[v.Length];
        Span<float> win = stackalloc float[9];
        for (var c = 0; c < 2; c++)
            for (var y = 0; y < gh; y++)
                for (var x = 0; x < gw; x++)
                {
                    var n = 0;
                    for (var dy = -1; dy <= 1; dy++)
                        for (var dx = -1; dx <= 1; dx++)
                        {
                            int xx = x + dx, yy = y + dy;
                            if (xx < 0 || yy < 0 || xx >= gw || yy >= gh) continue;
                            win[n++] = v[2 * (yy * gw + xx) + c];
                        }
                    var s = win[..n];
                    s.Sort();
                    o[2 * (y * gw + x) + c] = s[n / 2];
                }
        return o;
    }
}
