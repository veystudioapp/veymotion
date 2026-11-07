namespace VeyMotion.Core;

/// <summary>Follows one object through frames by template matching: normalized cross-correlation over a search window
/// around the predicted position, coarse to fine on a pyramid of the grayscale frame, with a small scale search at the
/// finest level and a slowly updated template (anchored to the first one so it cannot drift away). Stand-in for
/// Vision's <c>VNTrackObjectRequest</c>. Positions are in level-0 pixels of the planes it is given (all the same size).</summary>
internal sealed class TemplateTracker
{
    /// <summary>Largest template side (samples) at the finest matching level.</summary>
    const int MaxFineSide = 48;
    /// <summary>Smallest template side at the coarsest level.</summary>
    const int MinCoarseSide = 6;
    /// <summary>Below this correlation the object counts as lost for that frame.</summary>
    public const double MinConfidence = 0.3;

    sealed class Template
    {
        public int Nx, Ny;
        public double StepX, StepY;
        public float[] Z = [];
        public bool Flat;
    }

    readonly int w0, h0, lf, lc;
    readonly double bw, bh;
    readonly Template[] tpl, anchor;
    double cx, cy, vx, vy, scale = 1;
    int misses;

    /// <param name="first">The frame the box is drawn on.</param>
    /// <param name="x">Box left, normalized (0…1, origin top-left).</param>
    /// <param name="y">Box top, normalized.</param>
    /// <param name="w">Box width, normalized.</param>
    /// <param name="h">Box height, normalized.</param>
    public TemplateTracker(GrayPlane first, double x, double y, double w, double h)
    {
        w0 = first.W; h0 = first.H;
        bw = Math.Max(1, w * w0); bh = Math.Max(1, h * h0);
        cx = (x + w / 2) * w0; cy = (y + h / 2) * h0;
        var big = Math.Max(bw, bh);
        while (big / (1 << lf) > MaxFineSide) lf++;
        var pyr = first.Pyramid(lf + 2);
        lf = Math.Min(lf, pyr.Count - 1);
        lc = lf;
        while (lc < lf + 2 && lc + 1 < pyr.Count && Math.Min(bw, bh) / (1 << (lc + 1)) >= MinCoarseSide
               && Math.Min(pyr[lc + 1].W, pyr[lc + 1].H) >= 24) lc++;
        tpl = new Template[lc - lf + 1];
        anchor = new Template[tpl.Length];
        for (var L = lf; L <= lc; L++)
        {
            var s = (double)(1 << L);
            int nx = Math.Max(3, (int)Math.Round(bw / s)), ny = Math.Max(3, (int)Math.Round(bh / s));
            var t = new Template { Nx = nx, Ny = ny, StepX = bw / s / nx, StepY = bh / s / ny };
            SetPatch(t, Patch(pyr[L], t, cx / s, cy / s, 1));
            tpl[L - lf] = t;
            anchor[L - lf] = new Template { Nx = nx, Ny = ny, StepX = t.StepX, StepY = t.StepY, Z = (float[])t.Z.Clone(), Flat = t.Flat };
        }
    }

    /// <summary>Whether the first template has any texture to follow.</summary>
    public bool IsTrackable => !tpl[0].Flat;

    /// <summary>Finds the object in the next frame. Returns false (and keeps the last position) when it is lost.</summary>
    /// <param name="box">Center and size, normalized (origin top-left).</param>
    public bool Update(GrayPlane frame, out (double X, double Y, double W, double H) box, out double confidence)
    {
        if (frame.W != w0 || frame.H != h0) frame = frame.Resize(w0, h0);
        var pyr = frame.Pyramid(lc);
        box = default;
        confidence = 0;
        if (pyr.Count <= lc || tpl[0].Flat) return false;

        // Coarsest level: exhaustive search around the predicted position.
        var L = lc;
        var t = tpl[L - lf];
        var s = (double)(1 << L);
        double px = (cx + vx) / s, py = (cy + vy) / s;
        // Up to two box sizes away from the prediction (samples may be far apart), wider after each miss.
        var r = (int)Math.Ceiling(2 * Math.Max(t.Nx, t.Ny) * scale * (1 + 0.5 * Math.Min(misses, 4))) + 3;
        double best = -2, qx = px, qy = py;
        for (var dy = -r; dy <= r; dy++)
            for (var dx = -r; dx <= r; dx++)
            {
                var n = Ncc(pyr[L], t, px + dx, py + dy, scale);
                if (n > best) { best = n; qx = px + dx; qy = py + dy; }
            }
        // The unpredicted position too, in case the motion changed direction.
        if (vx != 0 || vy != 0)
        {
            double ux = cx / s, uy = cy / s;
            for (var dy = -2; dy <= 2; dy++)
                for (var dx = -2; dx <= 2; dx++)
                {
                    var n = Ncc(pyr[L], t, ux + dx, uy + dy, scale);
                    if (n > best) { best = n; qx = ux + dx; qy = uy + dy; }
                }
        }

        // Finer levels: refine ±2 px around the coarser match.
        for (L = lc - 1; L >= lf; L--)
        {
            qx *= 2; qy *= 2;
            t = tpl[L - lf];
            (best, qx, qy) = Refine(pyr[L], t, qx, qy, scale, 2);
        }

        // Finest level: a little scale search, then sub-pixel.
        L = lf;
        t = tpl[0];
        var newScale = scale;
        foreach (var k in (ReadOnlySpan<double>)[0.97, 1.03])
        {
            var sc = Math.Clamp(scale * k, 0.25, 4);
            var (n, x, y) = Refine(pyr[L], t, qx, qy, sc, 1);
            if (n > best + 0.01) { best = n; qx = x; qy = y; newScale = sc; }
        }
        double nl = Ncc(pyr[L], t, qx - 1, qy, newScale), nr = Ncc(pyr[L], t, qx + 1, qy, newScale);
        double nu = Ncc(pyr[L], t, qx, qy - 1, newScale), nd = Ncc(pyr[L], t, qx, qy + 1, newScale);
        qx += Parabola(nl, best, nr);
        qy += Parabola(nu, best, nd);

        confidence = Math.Clamp(best, 0, 1);
        if (confidence < MinConfidence) { vx = vy = 0; misses++; return false; }
        misses = 0;
        s = 1 << lf;
        double ncx = qx * s, ncy = qy * s;
        vx = ncx - cx; vy = ncy - cy;
        cx = Math.Clamp(ncx, 0, w0); cy = Math.Clamp(ncy, 0, h0);
        scale = newScale;
        if (confidence > 0.5) Learn(pyr);
        box = (cx / w0, cy / h0, bw * scale / w0, bh * scale / h0);
        return true;
    }

    /// <summary>Blends the current look of the object into the templates (slowly, and pulled back toward the first).</summary>
    void Learn(List<GrayPlane> pyr)
    {
        for (var L = lf; L <= lc; L++)
        {
            var s = (double)(1 << L);
            var t = tpl[L - lf];
            var a = anchor[L - lf];
            var fresh = new Template { Nx = t.Nx, Ny = t.Ny, StepX = t.StepX, StepY = t.StepY };
            SetPatch(fresh, Patch(pyr[L], t, cx / s, cy / s, scale));
            if (fresh.Flat) continue;
            var z = new float[t.Z.Length];
            for (var i = 0; i < z.Length; i++) z[i] = 0.9f * t.Z[i] + 0.05f * fresh.Z[i] + 0.05f * a.Z[i];
            SetPatch(t, z);
        }
    }

    (double N, double X, double Y) Refine(GrayPlane img, Template t, double x, double y, double sc, int r)
    {
        double best = -2, bx = x, by = y;
        for (var dy = -r; dy <= r; dy++)
            for (var dx = -r; dx <= r; dx++)
            {
                var n = Ncc(img, t, x + dx, y + dy, sc);
                if (n > best) { best = n; bx = x + dx; by = y + dy; }
            }
        return (best, bx, by);
    }

    static double Parabola(double l, double c, double r)
    {
        var d = l - 2 * c + r;
        return d < -1e-9 ? Math.Clamp(0.5 * (l - r) / d, -0.5, 0.5) : 0;
    }

    static float[] Patch(GrayPlane img, Template t, double cx, double cy, double sc)
    {
        var v = new float[t.Nx * t.Ny];
        for (var j = 0; j < t.Ny; j++)
        {
            var y = cy + (j + 0.5 - t.Ny / 2.0) * t.StepY * sc;
            for (var i = 0; i < t.Nx; i++)
                v[j * t.Nx + i] = img.Sample(cx + (i + 0.5 - t.Nx / 2.0) * t.StepX * sc, y);
        }
        return v;
    }

    /// <summary>Stores a patch as zero mean, unit norm (so NCC is one dot product).</summary>
    static void SetPatch(Template t, float[] v)
    {
        double mean = 0;
        foreach (var x in v) mean += x;
        mean /= v.Length;
        double ss = 0;
        foreach (var x in v) ss += (x - mean) * (x - mean);
        t.Flat = Math.Sqrt(ss / v.Length) < 0.004;
        var inv = t.Flat ? 0 : 1 / Math.Sqrt(ss);
        t.Z = new float[v.Length];
        for (var i = 0; i < v.Length; i++) t.Z[i] = (float)((v[i] - mean) * inv);
    }

    /// <summary>Normalized cross-correlation of the template with the picture around (cx, cy) at a relative scale.</summary>
    static double Ncc(GrayPlane img, Template t, double cx, double cy, double sc)
    {
        double sz = 0, si = 0, sii = 0;
        var n = t.Nx * t.Ny;
        for (var j = 0; j < t.Ny; j++)
        {
            var y = cy + (j + 0.5 - t.Ny / 2.0) * t.StepY * sc;
            var row = j * t.Nx;
            for (var i = 0; i < t.Nx; i++)
            {
                double v = img.Sample(cx + (i + 0.5 - t.Nx / 2.0) * t.StepX * sc, y);
                sz += t.Z[row + i] * v;
                si += v;
                sii += v * v;
            }
        }
        var varI = sii - si * si / n;
        return varI > 1e-9 ? sz / Math.Sqrt(varI) : 0;
    }
}
