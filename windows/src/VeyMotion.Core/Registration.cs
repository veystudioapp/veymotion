namespace VeyMotion.Core;

/// <summary>Translational registration of two frames by phase correlation (stand-in for Vision's
/// <c>VNTranslationalImageRegistrationRequest</c>): the centered power-of-two crop of each grayscale frame is
/// Hann-windowed and transformed once; the normalized cross-power spectrum's peak is the shift, refined to sub-pixel
/// with a parabola through its neighbors.</summary>
internal static class PhaseCorrelation
{
    /// <summary>Largest FFT side used.</summary>
    const int MaxSide = 512;

    public sealed class Spectrum
    {
        public int N, M;
        public double[] Re = [], Im = [];
    }

    /// <summary>The frame's spectrum (null when it is smaller than 16 × 16).</summary>
    public static Spectrum? Prepare(GrayPlane p)
    {
        int n = VisionFft.FloorPowerOfTwo(Math.Min(p.W, MaxSide)), m = VisionFft.FloorPowerOfTwo(Math.Min(p.H, MaxSide));
        if (n < 16 || m < 16) return null;
        int ox = (p.W - n) / 2, oy = (p.H - m) / 2;
        double mean = 0;
        for (var y = 0; y < m; y++)
            for (var x = 0; x < n; x++) mean += p[ox + x, oy + y];
        mean /= n * m;
        var wx = Hann(n); var wy = Hann(m);
        var s = new Spectrum { N = n, M = m, Re = new double[n * m], Im = new double[n * m] };
        for (var y = 0; y < m; y++)
            for (var x = 0; x < n; x++)
                s.Re[y * n + x] = (p[ox + x, oy + y] - mean) * wx[x] * wy[y];
        VisionFft.Transform2D(s.Re, s.Im, n, m, inverse: false);
        return s;
    }

    /// <summary>How far the content moved from <paramref name="a"/> to <paramref name="b"/> (plane pixels, x right,
    /// y down), and the correlation peak's height (0…1, higher = more reliable).</summary>
    public static (double Dx, double Dy, double Peak) Shift(Spectrum a, Spectrum b)
    {
        if (a.N != b.N || a.M != b.M) return (0, 0, 0);
        int n = a.N, m = a.M;
        var re = new double[n * m];
        var im = new double[n * m];
        // A Gaussian low-pass on the cross-power spectrum turns the correlation peak into a Gaussian of PeakSigma px
        // (instead of a sinc), which a parabola through the logs fits exactly: unbiased sub-pixel shifts, and less
        // weight on the noisy high frequencies.
        const double PeakSigma = 1.0;
        var gx = new double[n]; var gy = new double[m];
        for (var k = 0; k < n; k++) { var f = (k <= n / 2 ? k : k - n) / (double)n; gx[k] = Math.Exp(-2 * Math.PI * Math.PI * PeakSigma * PeakSigma * f * f); }
        for (var k = 0; k < m; k++) { var f = (k <= m / 2 ? k : k - m) / (double)m; gy[k] = Math.Exp(-2 * Math.PI * Math.PI * PeakSigma * PeakSigma * f * f); }
        for (var i = 0; i < re.Length; i++)
        {
            // B · conj(A): peaks at +d when b(x) = a(x - d).
            var r = b.Re[i] * a.Re[i] + b.Im[i] * a.Im[i];
            var q = b.Im[i] * a.Re[i] - b.Re[i] * a.Im[i];
            var mag = Math.Sqrt(r * r + q * q);
            if (mag > 1e-12) { var g = gx[i % n] * gy[i / n] / mag; re[i] = r * g; im[i] = q * g; }
        }
        VisionFft.Transform2D(re, im, n, m, inverse: true);
        double At(int x, int y) => re[((y % m + m) % m) * n + ((x % n + n) % n)];
        var top = re.Max();
        // Several peaks: the camera's motion (the whole background) and objects moving across it, whose sharp edges
        // can make a taller peak. Camera shake between two frames is small, so of the clear local peaks (at least 40%
        // of the tallest) take the one closest to no motion.
        int bx = 0, by = 0;
        var bestDist = double.MaxValue;
        for (var i = 0; i < re.Length; i++)
        {
            if (re[i] < top * 0.4) continue;
            int x = i % n, y = i / n;
            if (re[i] < At(x - 1, y) || re[i] < At(x + 1, y) || re[i] < At(x, y - 1) || re[i] < At(x, y + 1)) continue;
            double sx = x > n / 2 ? x - n : x, sy = y > m / 2 ? y - m : y;
            var dist = sx * sx + sy * sy;
            if (dist < bestDist) { bestDist = dist; bx = x; by = y; }
        }
        var best = re[by * n + bx];
        var dx = bx + LogParabola(At(bx - 1, by), best, At(bx + 1, by));
        var dy = by + LogParabola(At(bx, by - 1), best, At(bx, by + 1));
        if (dx > n / 2.0) dx -= n;
        if (dy > m / 2.0) dy -= m;
        // Peak height relative to a perfect match (the weights' total).
        var total = gx.Sum() * gy.Sum() / (n * (double)m);
        return (dx, dy, Math.Clamp(best / total, 0, 1));
    }

    /// <summary>Vertex of the parabola through the logs of three samples of a Gaussian peak (plain parabola when a
    /// neighbor is not positive).</summary>
    static double LogParabola(double l, double c, double r)
    {
        if (l > 1e-12 && r > 1e-12 && c > 1e-12)
        {
            double ll = Math.Log(l), lc = Math.Log(c), lr = Math.Log(r);
            var d = ll - 2 * lc + lr;
            if (d < -1e-12) return Math.Clamp(0.5 * (ll - lr) / d, -0.5, 0.5);
        }
        var e = l - 2 * c + r;
        return e < -1e-12 ? Math.Clamp(0.5 * (l - r) / e, -0.5, 0.5) : 0;
    }

    static double[] Hann(int n)
    {
        var w = new double[n];
        for (var i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.Cos(2 * Math.PI * (i + 0.5) / n);
        return w;
    }
}
