namespace VeyMotion.Core;

/// <summary>Where the eye goes in a frame, without a neural net (stand-in for Vision's attention saliency): the mean of
/// two classic maps on a 64 × 64 version of the frame, spectral residual (Hou &amp; Zhang 2007, on luminance) and
/// frequency-tuned color contrast (Achanta et al. 2009, in CIELAB). Salient regions are the connected parts above half
/// the peak, strongest first.</summary>
public static class SaliencyMap
{
    public const int Size = 64;

    /// <summary>The saliency map (Size × Size, top row first, 0…1), or null when the frame is empty.</summary>
    public static float[]? Compute(BgraFrame frame) => Map(frame)?.P;

    internal static GrayPlane? Map(BgraFrame frame)
    {
        if (!frame.IsValid) return null;
        var (l, a, b) = Lab(frame);
        var sr = SpectralResidual(l).Normalized();
        var ft = FrequencyTuned(l, a, b).Normalized();
        var sum = new GrayPlane(Size, Size);
        for (var i = 0; i < sum.P.Length; i++) sum.P[i] = 0.5f * (sr.P[i] + ft.P[i]);
        return sum.Blurred(1).Normalized();
    }

    /// <summary>A salient region: box normalized (origin top-left) and a confidence 0…1.</summary>
    public readonly record struct Region(double X, double Y, double Width, double Height, double Confidence);

    /// <summary>Salient regions, strongest first (empty when nothing stands out).</summary>
    public static List<Region> Regions(BgraFrame frame)
    {
        var map = Map(frame);
        if (map == null) return [];
        float max = 0; double mean = 0;
        foreach (var v in map.P) { if (v > max) max = v; mean += v; }
        mean /= map.P.Length;
        if (!(max > 1e-6f)) return [];
        var threshold = 0.5f * max;
        var label = new int[map.P.Length];
        var found = new List<(double Mass, int X0, int Y0, int X1, int Y1)>();
        var stack = new Stack<int>();
        for (var start = 0; start < map.P.Length; start++)
        {
            if (label[start] != 0 || map.P[start] < threshold) continue;
            var id = found.Count + 1;
            double mass = 0;
            int x0 = Size, y0 = Size, x1 = -1, y1 = -1;
            label[start] = id;
            stack.Push(start);
            while (stack.Count > 0)
            {
                var i = stack.Pop();
                int x = i % Size, y = i / Size;
                mass += map.P[i];
                x0 = Math.Min(x0, x); x1 = Math.Max(x1, x); y0 = Math.Min(y0, y); y1 = Math.Max(y1, y);
                foreach (var (nx, ny) in (ReadOnlySpan<(int, int)>)[(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)])
                {
                    if (nx < 0 || ny < 0 || nx >= Size || ny >= Size) continue;
                    var j = ny * Size + nx;
                    if (label[j] == 0 && map.P[j] >= threshold) { label[j] = id; stack.Push(j); }
                }
            }
            found.Add((mass, x0, y0, x1, y1));
        }
        found.Sort((p, q) => q.Mass.CompareTo(p.Mass));
        var top = found[0].Mass;
        // The strongest region's confidence: how much the peak stands out of the average.
        var lead = Math.Clamp((max - mean) / max, 0, 1);
        return found.Select((f, i) => new Region((double)f.X0 / Size, (double)f.Y0 / Size,
            (double)(f.X1 - f.X0 + 1) / Size, (double)(f.Y1 - f.Y0 + 1) / Size,
            i == 0 ? lead : Math.Clamp(f.Mass / top, 0, 1) * lead)).ToList();
    }

    /// <summary>Hou &amp; Zhang: what is left of the log amplitude spectrum after removing its local average, back in
    /// image space with the original phase, squared and blurred.</summary>
    static GrayPlane SpectralResidual(GrayPlane l)
    {
        const int n = Size;
        var re = new double[n * n];
        var im = new double[n * n];
        for (var i = 0; i < re.Length; i++) re[i] = l.P[i];
        VisionFft.Transform2D(re, im, n, n, inverse: false);
        var logAmp = new double[n * n];
        for (var i = 0; i < re.Length; i++) logAmp[i] = Math.Log(Math.Sqrt(re[i] * re[i] + im[i] * im[i]) + 1e-9);
        for (var y = 0; y < n; y++)
            for (var x = 0; x < n; x++)
            {
                double avg = 0;
                for (var dy = -1; dy <= 1; dy++)
                    for (var dx = -1; dx <= 1; dx++) avg += logAmp[((y + dy + n) % n) * n + (x + dx + n) % n];
                var i = y * n + x;
                var mag = Math.Sqrt(re[i] * re[i] + im[i] * im[i]);
                var k = mag > 1e-12 ? Math.Exp(logAmp[i] - avg / 9) / mag : 0;
                re[i] *= k; im[i] *= k;
            }
        VisionFft.Transform2D(re, im, n, n, inverse: true);
        var o = new GrayPlane(n, n);
        for (var y = 0; y < n; y++)
            for (var x = 0; x < n; x++)
            {
                // The wrap-around makes the frame's border light up: fade it out.
                var edge = Math.Min(Math.Min(x, n - 1 - x), Math.Min(y, n - 1 - y));
                var fade = edge >= 3 ? 1 : edge / 3.0;
                var i = y * n + x;
                o.P[i] = (float)((re[i] * re[i] + im[i] * im[i]) * fade);
            }
        return o.Blurred(2.5);
    }

    /// <summary>Achanta: distance of each (lightly blurred) pixel's color from the frame's mean color.</summary>
    static GrayPlane FrequencyTuned(GrayPlane l, GrayPlane a, GrayPlane b)
    {
        var bl = l.Blurred(1); var ba = a.Blurred(1); var bb = b.Blurred(1);
        double ml = bl.P.Average(), ma = ba.P.Average(), mb = bb.P.Average();
        var o = new GrayPlane(Size, Size);
        for (var i = 0; i < o.P.Length; i++)
        {
            double dl = bl.P[i] - ml, da = ba.P[i] - ma, db = bb.P[i] - mb;
            o.P[i] = (float)(dl * dl + da * da + db * db);
        }
        return o;
    }

    /// <summary>CIELAB planes of the frame at Size × Size (L 0…100, a/b about ±100; premultiplied colors as is).</summary>
    static (GrayPlane L, GrayPlane A, GrayPlane B) Lab(BgraFrame f)
    {
        var count = f.Width * f.Height;
        var lp = new float[count]; var ap = new float[count]; var bp = new float[count];
        Span<float> lin = stackalloc float[256];
        for (var i = 0; i < 256; i++)
        {
            var c = i / 255.0;
            lin[i] = (float)(c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4));
        }
        static double F(double t) => t > 0.008856 ? Math.Cbrt(t) : 7.787 * t + 16.0 / 116;
        var px = f.Pixels;
        for (int i = 0, o = 0; i < count; i++, o += 4)
        {
            double r = lin[px[o + 2]], g = lin[px[o + 1]], bl = lin[px[o]];
            var x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047;
            var y = 0.2126 * r + 0.7152 * g + 0.0722 * bl;
            var z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883;
            double fx = F(x), fy = F(y), fz = F(z);
            lp[i] = (float)(116 * fy - 16);
            ap[i] = (float)(500 * (fx - fy));
            bp[i] = (float)(200 * (fy - fz));
        }
        GrayPlane Small(float[] p) => new GrayPlane(f.Width, f.Height, p).Resize(Size, Size);
        return (Small(lp), Small(ap), Small(bp));
    }
}
