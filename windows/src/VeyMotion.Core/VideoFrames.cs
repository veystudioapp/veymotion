namespace VeyMotion.Core;

/// <summary>One decoded picture: premultiplied BGRA, top row first, stride = 4 × <see cref="Width"/>.</summary>
public readonly record struct BgraFrame(int Width, int Height, byte[] Pixels)
{
    public bool IsValid => Width > 0 && Height > 0 && Pixels != null && Pixels.Length >= Width * Height * 4;
}

/// <summary>Frames of video layers for analysis (tracking, saliency, stabilization) and for frame blending. The app
/// implements it with Media Foundation (movies) and its image loader (image sequences). Stand-in for
/// <c>VideoFrames</c> / <c>VideoFramesFactory</c> (<c>Video.swift</c>).</summary>
public interface IVideoFrameReader
{
    /// <summary>The source's pixel size, or null when the file (or sequence folder) cannot be read.</summary>
    (int Width, int Height)? Size(string path);

    /// <summary>The frame shown at <paramref name="seconds"/> into the source (<paramref name="fps"/> is what image
    /// sequences play at), scaled down so its longer side is at most <paramref name="maxSide"/> (0 = full size).
    /// Null when it cannot be decoded.</summary>
    BgraFrame? Frame(string path, double seconds, double fps, int maxSide);

    /// <summary>Seconds of the movie (or of the sequence), or null.</summary>
    double? Duration(string path);

    /// <summary>Seconds between two source frames, or null when unknown.</summary>
    double? FrameDuration(string path);
}

/// <summary>A one-channel float picture (0…1), top row first. Pixel (i, j) covers [i, i+1) × [j, j+1), so its center
/// is at (i + 0.5, j + 0.5) in the continuous coordinates <see cref="Sample"/> takes.</summary>
internal sealed class GrayPlane
{
    public readonly int W, H;
    public readonly float[] P;

    public GrayPlane(int w, int h) : this(w, h, new float[w * h]) { }
    public GrayPlane(int w, int h, float[] p) { W = w; H = h; P = p; }

    public float this[int x, int y] => P[y * W + x];

    /// <summary>Luminance (Rec. 601) of a frame, scaled down to at most <paramref name="maxSide"/> (0 = as is).</summary>
    public static GrayPlane? FromBgra(BgraFrame f, int maxSide)
    {
        if (!f.IsValid) return null;
        var p = new float[f.Width * f.Height];
        var px = f.Pixels;
        for (int i = 0, o = 0; i < p.Length; i++, o += 4)
            p[i] = (0.114f * px[o] + 0.587f * px[o + 1] + 0.299f * px[o + 2]) * (1 / 255f);
        return new GrayPlane(f.Width, f.Height, p).Fit(maxSide);
    }

    /// <summary>Scaled down (area average) so the longer side is at most <paramref name="maxSide"/>.</summary>
    public GrayPlane Fit(int maxSide)
    {
        var m = Math.Max(W, H);
        if (maxSide <= 0 || m <= maxSide) return this;
        var s = (double)maxSide / m;
        return Resize(Math.Max(1, (int)Math.Round(W * s)), Math.Max(1, (int)Math.Round(H * s)));
    }

    /// <summary>Resampled to w × h: area average when shrinking, bilinear when growing.</summary>
    public GrayPlane Resize(int w, int h)
    {
        if (w == W && h == H) return this;
        var o = new GrayPlane(w, h);
        if (w <= W && h <= H)
        {
            var count = new int[w * h];
            for (var y = 0; y < H; y++)
            {
                var dy = (int)((long)y * h / H) * w;
                for (var x = 0; x < W; x++)
                {
                    var d = dy + (int)((long)x * w / W);
                    o.P[d] += P[y * W + x];
                    count[d]++;
                }
            }
            for (var i = 0; i < o.P.Length; i++) if (count[i] > 0) o.P[i] /= count[i];
            return o;
        }
        double sx = (double)W / w, sy = (double)H / h;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                o.P[y * w + x] = Sample((x + 0.5) * sx, (y + 0.5) * sy);
        return o;
    }

    /// <summary>Half size (2 × 2 average).</summary>
    public GrayPlane Half()
    {
        int w = Math.Max(1, W / 2), h = Math.Max(1, H / 2);
        var o = new GrayPlane(w, h);
        for (var y = 0; y < h; y++)
        {
            int y0 = Math.Min(2 * y, H - 1), y1 = Math.Min(2 * y + 1, H - 1);
            for (var x = 0; x < w; x++)
            {
                int x0 = Math.Min(2 * x, W - 1), x1 = Math.Min(2 * x + 1, W - 1);
                o.P[y * w + x] = 0.25f * (P[y0 * W + x0] + P[y0 * W + x1] + P[y1 * W + x0] + P[y1 * W + x1]);
            }
        }
        return o;
    }

    /// <summary>Levels 0…<paramref name="top"/>, each half the previous (stops early when a level gets tiny).</summary>
    public List<GrayPlane> Pyramid(int top)
    {
        var list = new List<GrayPlane> { this };
        while (list.Count <= top)
        {
            var last = list[^1];
            if (last.W < 4 || last.H < 4) break;
            list.Add(last.Half());
        }
        return list;
    }

    /// <summary>Bilinear value at continuous coordinates (edges extend).</summary>
    public float Sample(double x, double y)
    {
        x -= 0.5; y -= 0.5;
        var fx0 = Math.Floor(x); var fy0 = Math.Floor(y);
        var fx = (float)(x - fx0); var fy = (float)(y - fy0);
        int x0 = (int)fx0, y0 = (int)fy0;
        int xa = Math.Clamp(x0, 0, W - 1), xb = Math.Clamp(x0 + 1, 0, W - 1);
        int ya = Math.Clamp(y0, 0, H - 1) * W, yb = Math.Clamp(y0 + 1, 0, H - 1) * W;
        var top = P[ya + xa] + (P[ya + xb] - P[ya + xa]) * fx;
        var bottom = P[yb + xa] + (P[yb + xb] - P[yb + xa]) * fx;
        return top + (bottom - top) * fy;
    }

    /// <summary>Gaussian blur (separable, edges extend).</summary>
    public GrayPlane Blurred(double sigma)
    {
        if (sigma <= 0.1) return new GrayPlane(W, H, (float[])P.Clone());
        var r = Math.Max(1, (int)Math.Ceiling(sigma * 3));
        var k = new float[2 * r + 1];
        float sum = 0;
        for (var i = -r; i <= r; i++) sum += k[i + r] = (float)Math.Exp(-i * i / (2 * sigma * sigma));
        for (var i = 0; i < k.Length; i++) k[i] /= sum;
        var tmp = new float[W * H];
        for (var y = 0; y < H; y++)
            for (var x = 0; x < W; x++)
            {
                float v = 0;
                for (var i = -r; i <= r; i++) v += k[i + r] * P[y * W + Math.Clamp(x + i, 0, W - 1)];
                tmp[y * W + x] = v;
            }
        var o = new GrayPlane(W, H);
        for (var y = 0; y < H; y++)
            for (var x = 0; x < W; x++)
            {
                float v = 0;
                for (var i = -r; i <= r; i++) v += k[i + r] * tmp[Math.Clamp(y + i, 0, H - 1) * W + x];
                o.P[y * W + x] = v;
            }
        return o;
    }

    /// <summary>Scaled to 0…1 (all zero when flat).</summary>
    public GrayPlane Normalized()
    {
        float lo = float.MaxValue, hi = float.MinValue;
        foreach (var v in P) { if (v < lo) lo = v; if (v > hi) hi = v; }
        var o = new GrayPlane(W, H);
        if (!(hi - lo > 1e-12f)) return o;
        var s = 1 / (hi - lo);
        for (var i = 0; i < P.Length; i++) o.P[i] = (P[i] - lo) * s;
        return o;
    }
}

/// <summary>In-place radix-2 FFT on split real/imaginary arrays (1D and 2D, row-major).</summary>
internal static class VisionFft
{
    public static bool IsPowerOfTwo(int n) => n > 0 && (n & (n - 1)) == 0;

    /// <summary>Largest power of two ≤ n (0 for n &lt; 1).</summary>
    public static int FloorPowerOfTwo(int n)
    {
        if (n < 1) return 0;
        var p = 1;
        while (p * 2 <= n) p *= 2;
        return p;
    }

    /// <summary>2D transform of an n (row length) × m image. The inverse is scaled by 1/(n·m).</summary>
    public static void Transform2D(double[] re, double[] im, int n, int m, bool inverse)
    {
        var rr = new double[Math.Max(n, m)];
        var ri = new double[rr.Length];
        for (var y = 0; y < m; y++)
        {
            Array.Copy(re, y * n, rr, 0, n);
            Array.Copy(im, y * n, ri, 0, n);
            Transform(rr, ri, n, inverse);
            Array.Copy(rr, 0, re, y * n, n);
            Array.Copy(ri, 0, im, y * n, n);
        }
        for (var x = 0; x < n; x++)
        {
            for (var y = 0; y < m; y++) { rr[y] = re[y * n + x]; ri[y] = im[y * n + x]; }
            Transform(rr, ri, m, inverse);
            for (var y = 0; y < m; y++) { re[y * n + x] = rr[y]; im[y * n + x] = ri[y]; }
        }
        if (inverse)
        {
            var s = 1.0 / ((double)n * m);
            for (var i = 0; i < n * m; i++) { re[i] *= s; im[i] *= s; }
        }
    }

    /// <summary>Unscaled 1D transform of the first <paramref name="n"/> entries.</summary>
    public static void Transform(double[] re, double[] im, int n, bool inverse)
    {
        for (int i = 1, j = 0; i < n; i++)
        {
            var bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) { (re[i], re[j]) = (re[j], re[i]); (im[i], im[j]) = (im[j], im[i]); }
        }
        for (var len = 2; len <= n; len <<= 1)
        {
            var ang = 2 * Math.PI / len * (inverse ? 1 : -1);
            double wr = Math.Cos(ang), wi = Math.Sin(ang);
            for (var i = 0; i < n; i += len)
            {
                double cr = 1, ci = 0;
                for (var k = 0; k < len / 2; k++)
                {
                    int a = i + k, b = a + len / 2;
                    var tr = re[b] * cr - im[b] * ci;
                    var ti = re[b] * ci + im[b] * cr;
                    re[b] = re[a] - tr; im[b] = im[a] - ti;
                    re[a] += tr; im[a] += ti;
                    var ncr = cr * wr - ci * wi;
                    ci = cr * wi + ci * wr;
                    cr = ncr;
                }
            }
        }
    }
}
