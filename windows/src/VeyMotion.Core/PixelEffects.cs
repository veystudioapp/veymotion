namespace VeyMotion.Core;

/// <summary>
/// Pixel effects of a layer (keying, distortions, color grading, stylize, directional and zoom blur, light), run on
/// the CPU over the bitmap the renderer draws the layer into. Every amount is an animatable property; 0 turns an effect
/// off. Nothing is carried between frames: random looks (grain, glitch) are seeded by the layer id and the frame
/// number. Port of <c>PixelEffects.swift</c>.
/// </summary>
public sealed class PixelEffects
{
    public readonly Rgba? KeyColor;
    public readonly double KeyTolerance, KeySoftness;
    public readonly double Wave, Ripple, WaveLength, WaveSpeed, Twirl, Bulge, Radius, Turbulence;
    public readonly ColorMatrix? Colors;
    public readonly double Posterize, Pixelate, DirectionalBlur, BlurAngle, ZoomBlur;
    public readonly double RgbSplit, Glitch, Grain, Scanlines, Vignette;
    public readonly double Rays, RaysLength, Outline, InnerGlow, InnerGlowRadius, Shine;
    public readonly Rgba OutlineColor, InnerGlowColor;
    public readonly Grading? Grading;
    public readonly double Time;
    public readonly int Frame;
    public readonly ulong Seed;

    public PixelEffects(MotionLayer layer, double t, int fps)
    {
        double V(AnimProperty p) => layer.Value(p, t);
        KeyColor = layer.KeyColor;
        KeyTolerance = Math.Max(0, V(AnimProperty.KeyTolerance)); KeySoftness = Math.Max(0, V(AnimProperty.KeySoftness));
        Wave = V(AnimProperty.WaveWarp); Ripple = V(AnimProperty.Ripple);
        WaveLength = Math.Max(4, V(AnimProperty.WaveLength)); WaveSpeed = V(AnimProperty.WaveSpeed);
        Twirl = V(AnimProperty.Twirl); Bulge = Math.Clamp(V(AnimProperty.Bulge), -0.95, 0.95);
        Radius = Math.Max(1, V(AnimProperty.DistortRadius)); Turbulence = V(AnimProperty.Turbulence);
        Colors = layer.ColorMatrixAt(t);
        Posterize = V(AnimProperty.Posterize); Pixelate = Math.Max(0, V(AnimProperty.Pixelate));
        DirectionalBlur = Math.Max(0, V(AnimProperty.DirectionalBlur)); BlurAngle = V(AnimProperty.BlurAngle);
        ZoomBlur = Math.Clamp(V(AnimProperty.ZoomBlur), 0, 0.95);
        RgbSplit = V(AnimProperty.RgbSplit); Glitch = Math.Clamp(V(AnimProperty.Glitch), 0, 1);
        Grain = Math.Clamp(V(AnimProperty.Grain), 0, 1); Scanlines = Math.Clamp(V(AnimProperty.Scanlines), 0, 1);
        Vignette = Math.Clamp(V(AnimProperty.Vignette), 0, 1);
        Rays = Math.Clamp(V(AnimProperty.Rays), 0, 4); RaysLength = Math.Clamp(V(AnimProperty.RaysLength), 0, 0.95);
        Outline = Math.Max(0, V(AnimProperty.Outline)); OutlineColor = layer.OutlineColor ?? Rgba.White;
        InnerGlow = Math.Clamp(V(AnimProperty.InnerGlow), 0, 4); InnerGlowRadius = Math.Max(1, V(AnimProperty.InnerGlowRadius));
        InnerGlowColor = layer.InnerGlowColor ?? Rgba.White;
        Shine = Math.Clamp(V(AnimProperty.Shine), 0, 4);
        Grading = Grading.Of(layer, t);
        Time = t;
        Frame = (int)Math.Floor(t * Math.Max(fps, 1) + 1e-6);
        Seed = Noise.Hash(layer.Id);
    }

    public bool Distorts => Wave != 0 || Ripple != 0 || Twirl != 0 || Bulge != 0 || Turbulence != 0;

    /// <summary>Whether the layer has to go through a bitmap on the CPU. (A color matrix alone runs on the GPU.)</summary>
    public bool NeedsPixels =>
        KeyColor != null || Distorts || Posterize >= 2 || Pixelate >= 1 || DirectionalBlur >= 1
        || ZoomBlur > 0.001 || RgbSplit != 0 || Glitch > 0.001 || Grain > 0.001 || Scanlines > 0.001
        || Vignette > 0.001 || Rays > 0.001 || Outline >= 0.5 || InnerGlow > 0.001 || Grading != null;

    /// <summary>Effects that run after the gaussian blur.</summary>
    public bool HasAfterBlur(double scale) =>
        DirectionalBlur * scale >= 1 || ZoomBlur > 0.001 || Rays > 0.001 || RgbSplit != 0 || Glitch > 0.001
        || Grain > 0.001 || Scanlines > 0.001 || Vignette > 0.001;

    /// <summary>How far, in layer px, the effects can move pixels outside the layer (<paramref name="width"/> = the
    /// area's width in layer px).</summary>
    public double Reach(double width)
    {
        var r = Math.Abs(Wave) + Math.Abs(Ripple) + Math.Abs(Turbulence) + DirectionalBlur / 2 + Math.Abs(RgbSplit) + Outline + 2;
        if (Glitch > 0) r += Glitch * 0.12 * width + 6 * Glitch;
        return r;
    }

    /// <summary>Effects before the gaussian blur. <paramref name="cx"/>/<paramref name="cy"/> = the layer's origin in
    /// bitmap pixels (y down); <paramref name="scale"/> = bitmap pixels per layer px.</summary>
    public void ApplyBeforeBlur(PixelBuffer buf, double cx, double cy, double scale)
    {
        if (KeyColor is { } key) buf.Key(key, KeyTolerance, KeySoftness);
        if (Distorts) Distort(buf, cx, cy, scale);
        if (Colors != null) buf.ApplyColors(Colors);
        Grading?.Apply(buf);
        if (Posterize >= 2) buf.Posterize(Math.Min(Posterize, 64));
        if (Pixelate * scale >= 1.5) buf.Pixelate(Pixelate * scale, cx, cy);
        if (InnerGlow > 0.001) buf.InnerGlow(InnerGlow, InnerGlowRadius * scale, InnerGlowColor);
        if (Outline * scale >= 0.5) buf.Outline(Outline * scale, OutlineColor);
    }

    /// <summary>Effects after the gaussian blur; <paramref name="pixelScale"/> = bitmap pixels per scene px.</summary>
    public void ApplyAfterBlur(PixelBuffer buf, double cx, double cy, double scale, double pixelScale)
    {
        if (DirectionalBlur * scale >= 1) buf.DirectionalBlur(DirectionalBlur * scale, BlurAngle);
        if (ZoomBlur > 0.001) buf.ZoomBlur(ZoomBlur, cx, cy);
        if (Rays > 0.001) buf.LightRays(Rays, RaysLength, cx, cy);
        if (RgbSplit != 0) buf.RgbSplit((int)PixelBuffer.Round(RgbSplit * scale));
        if (Glitch > 0.001) buf.Glitch(Glitch, Frame, Seed, pixelScale);
        if (Grain > 0.001) buf.Grain(Grain, Frame, Seed);
        if (Scanlines > 0.001) buf.Scanlines(Scanlines, Math.Max(2, (int)PixelBuffer.Round(3 * pixelScale)));
        if (Vignette > 0.001) buf.Vignette(Vignette);
    }

    /// <summary>Wave warp, ripple, twirl, bulge and turbulent displacement, as one inverse mapping (where each output
    /// pixel takes its color from), sampled bilinearly.</summary>
    void Distort(PixelBuffer buf, double cx, double cy, double scale)
    {
        double amp = Wave * scale, rip = Ripple * scale, turb = Turbulence * scale;
        double lambda = WaveLength * scale, phase = 2 * Math.PI * WaveSpeed * Time;
        double r0 = Radius * scale, twist = Twirl * Math.PI / 180, bulge = Bulge;
        // Turbulence is smooth: evaluate the noise on a coarse grid and interpolate.
        const int cell = 8;
        int gw = buf.W / cell + 2, gh = buf.H / cell + 2;
        var field = Array.Empty<double>();
        if (turb != 0)
        {
            field = new double[gw * gh * 2];
            var z = Time * WaveSpeed * 0.5;
            for (var gy = 0; gy < gh; gy++)
                for (var gx = 0; gx < gw; gx++)
                {
                    double x = (gx * cell - cx) / lambda, y = (gy * cell - cy) / lambda;
                    var i = 2 * (gy * gw + gx);
                    field[i] = turb * Noise.Value3(x, y, z, Seed).V;
                    field[i + 1] = turb * Noise.Value3(x + 31.7, y - 12.9, z, unchecked(Seed + 7)).V;
                }
        }
        buf.Remap((x, y) =>
        {
            double px = x, py = y;
            if (twist != 0 || bulge != 0)
            {
                double dx = px - cx, dy = py - cy;
                var r = Math.Sqrt(dx * dx + dy * dy);
                if (r < r0)
                {
                    var k = 1 - r / r0;
                    double sx = dx, sy = dy;
                    if (bulge != 0)
                    {
                        var f = 1 - bulge * k * k;
                        sx *= f; sy *= f;
                    }
                    if (twist != 0)
                    {
                        var a = -twist * k * k;
                        double ca = Math.Cos(a), sa = Math.Sin(a);
                        (sx, sy) = (sx * ca - sy * sa, sx * sa + sy * ca);
                    }
                    px = cx + sx; py = cy + sy;
                }
            }
            if (rip != 0)
            {
                double dx = px - cx, dy = py - cy;
                var r = Math.Sqrt(dx * dx + dy * dy);
                if (r > 0.5)
                {
                    var d = rip * Math.Sin(2 * Math.PI * r / lambda - phase);
                    px += dx / r * d; py += dy / r * d;
                }
            }
            if (amp != 0) py += amp * Math.Sin(2 * Math.PI * (x - cx) / lambda - phase);
            if (turb != 0)
            {
                double fx = Math.Clamp(x / cell, 0, gw - 2), fy = Math.Clamp(y / cell, 0, gh - 2);
                int ix = (int)fx, iy = (int)fy;
                double tx = fx - ix, ty = fy - iy;
                for (var k = 0; k < 2; k++)
                {
                    double a = field[2 * (iy * gw + ix) + k], b = field[2 * (iy * gw + ix + 1) + k];
                    double c = field[2 * ((iy + 1) * gw + ix) + k], d = field[2 * ((iy + 1) * gw + ix + 1) + k];
                    var v = (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty;
                    if (k == 0) px += v; else py += v;
                }
            }
            return (px, py);
        });
    }
}

/// <summary>Premultiplied BGRA8 pixels (Direct2D's B8G8R8A8 layout); row 0 is the top. Port of <c>PixelBuffer</c>
/// in <c>PixelEffects.swift</c> (which is RGBA: the channel offsets below take care of the difference).</summary>
public sealed class PixelBuffer(byte[] pixels, int w, int h)
{
    public const int B = 0, G = 1, R = 2, A = 3;
    public readonly byte[] P = pixels;
    public readonly int W = w, H = h;
    int Rb => W * 4;

    /// <summary>Swift's <c>rounded()</c>: halves away from zero.</summary>
    public static double Round(double v) => Math.Round(v, MidpointRounding.AwayFromZero);

    static byte Clamp255(double v) => (byte)Math.Clamp(v, 0, 255);

    byte[] Copy() => (byte[])P.Clone();

    byte[] AlphaPlane()
    {
        var output = new byte[W * H];
        for (var i = 0; i < W * H; i++) output[i] = P[i * 4 + A];
        return output;
    }

    /// <summary>Box-blurs a plane in place (three passes ≈ gaussian), edges extended.</summary>
    static void BlurPlane(byte[] plane, int w, int h, double sigma)
    {
        var size = (int)Round(Math.Sqrt(12 * sigma * sigma / 3 + 1));
        if (size % 2 == 0) size++;
        if (size < 3) return;
        var half = size / 2;
        var tmp = new byte[w * h];
        for (var pass = 0; pass < 3; pass++)
        {
            // Horizontal into tmp, vertical back into plane (a size×size box).
            Parallel.For(0, h, y =>
            {
                var row = y * w;
                var sum = 0;
                for (var k = -half; k <= half; k++) sum += plane[row + Math.Clamp(k, 0, w - 1)];
                for (var x = 0; x < w; x++)
                {
                    tmp[row + x] = (byte)((sum + half) / size);
                    sum += plane[row + Math.Min(x + half + 1, w - 1)] - plane[row + Math.Max(x - half, 0)];
                }
            });
            Parallel.For(0, w, x =>
            {
                var sum = 0;
                for (var k = -half; k <= half; k++) sum += tmp[Math.Clamp(k, 0, h - 1) * w + x];
                for (var y = 0; y < h; y++)
                {
                    plane[y * w + x] = (byte)((sum + half) / size);
                    sum += tmp[Math.Min(y + half + 1, h - 1) * w + x] - tmp[Math.Max(y - half, 0) * w + x];
                }
            });
        }
    }

    /// <summary>A colored band around the layer's shape: the alpha dilated by radius, drawn behind the pixels.</summary>
    public void Outline(double radius, Rgba color)
    {
        var k = Math.Max(1, (int)Round(radius * 2) | 1);
        var half = k / 2;
        var alpha = AlphaPlane();
        // Max filter, separable (rows then columns).
        var tmp = new byte[W * H];
        var dil = new byte[W * H];
        Parallel.For(0, H, y =>
        {
            for (var x = 0; x < W; x++)
            {
                byte m = 0;
                for (int xx = Math.Max(0, x - half), x1 = Math.Min(W - 1, x + half); xx <= x1; xx++) m = Math.Max(m, alpha[y * W + xx]);
                tmp[y * W + x] = m;
            }
        });
        Parallel.For(0, W, x =>
        {
            for (var y = 0; y < H; y++)
            {
                byte m = 0;
                for (int yy = Math.Max(0, y - half), y1 = Math.Min(H - 1, y + half); yy <= y1; yy++) m = Math.Max(m, tmp[yy * W + x]);
                dil[y * W + x] = m;
            }
        });
        // Soften the band's outer edge by a pixel so it is not jagged.
        BlurPlane(dil, W, H, 0.7);
        double cr = color.R * color.A, cg = color.G * color.A, cb = color.B * color.A;
        for (var i = 0; i < W * H; i++)
        {
            var m = dil[i] / 255.0 * color.A;
            if (m <= 0) continue;
            var q = i * 4;
            var inv = 1 - P[q + A] / 255.0; // behind the layer
            P[q + R] = Clamp255(P[q + R] + cr * m * inv * 255);
            P[q + G] = Clamp255(P[q + G] + cg * m * inv * 255);
            P[q + B] = Clamp255(P[q + B] + cb * m * inv * 255);
            P[q + A] = Clamp255(P[q + A] + m * inv * 255);
        }
    }

    /// <summary>Light inside the layer's edges: the blurred outside, masked by the layer, added over it.</summary>
    public void InnerGlow(double strength, double radius, Rgba color)
    {
        var alpha = AlphaPlane();
        var outside = alpha.Select(a => (byte)(255 - a)).ToArray();
        BlurPlane(outside, W, H, radius / 2);
        for (var i = 0; i < W * H; i++)
        {
            var a = alpha[i] / 255.0;
            if (a <= 0) continue;
            var m = Math.Min(1, outside[i] / 255.0 * strength * color.A) * a;
            var q = i * 4;
            P[q + R] = Clamp255(P[q + R] * (1 - m) + color.R * m * 255);
            P[q + G] = Clamp255(P[q + G] * (1 - m) + color.G * m * 255);
            P[q + B] = Clamp255(P[q + B] * (1 - m) + color.B * m * 255);
        }
    }

    /// <summary>Rays streaking out of the bright parts: a copy keeps only bright pixels, is zoom-blurred from the
    /// center and added on top.</summary>
    public void LightRays(double strength, double length, double cx, double cy)
    {
        var scratch = new PixelBuffer(Copy(), W, H);
        var s = scratch.P;
        // Threshold: luma above 0.45 (of alpha) stays, scaled up.
        for (var q = 0; q < s.Length; q += 4)
        {
            double a = s[q + A];
            if (a <= 0) continue;
            var luma = (0.2126 * s[q + R] + 0.7152 * s[q + G] + 0.0722 * s[q + B]) / a;
            var k = Math.Clamp((luma - 0.45) / 0.4, 0, 1);
            s[q + R] = (byte)(s[q + R] * k); s[q + G] = (byte)(s[q + G] * k); s[q + B] = (byte)(s[q + B] * k);
            s[q + A] = (byte)(a * k);
        }
        scratch.ZoomBlur(length, cx, cy);
        for (var i = 0; i < P.Length; i++) P[i] = (byte)Math.Min(255, P[i] + (int)(s[i] * strength));
    }

    // Per pixel

    /// <summary>Removes pixels close to the color in chroma (green/blue screen) and its spill on the edges.</summary>
    public void Key(Rgba color, double tolerance, double softness)
    {
        const double lr = 0.2126, lg = 0.7152, lb = 0.0722;
        static (double, double, double) Ycc(double r, double g, double b)
        {
            // Chroma relative to brightness: a shadow on the screen has the same color as its lit part.
            double y = lr * r + lg * g + lb * b, n = 1 / (y + 0.15);
            return (y, (b - y) * n, (r - y) * n);
        }
        var (ky, kcb, kcr) = Ycc(color.R, color.G, color.B);
        // Spill only matters for a colored screen (green, blue), not for keying out black or white.
        var spill = Math.Sqrt(kcb * kcb + kcr * kcr) > 0.25;
        var dom = color.G >= color.R && color.G >= color.B ? 1 : color.B >= color.R ? 2 : 0;
        double lo = tolerance, hi = tolerance + Math.Max(softness, 0.001);
        Parallel.For(0, H, y =>
        {
            for (int x = 0, q = y * Rb; x < W; x++, q += 4)
            {
                double a = P[q + A];
                if (a <= 0) continue;
                double r = P[q + R] / a, g = P[q + G] / a, b = P[q + B] / a;
                var (yy, cb, cr) = Ycc(r, g, b);
                var dl = 0.5 * (yy - ky);
                var dist = Math.Sqrt((cb - kcb) * (cb - kcb) + (cr - kcr) * (cr - kcr) + dl * dl);
                var t = Math.Clamp((dist - lo) / (hi - lo), 0, 1);
                var keep = t * t * (3 - 2 * t);
                if (spill)
                    switch (dom)
                    {
                        case 0: r = Math.Min(r, Math.Max(g, b)); break;
                        case 1: g = Math.Min(g, Math.Max(r, b)); break;
                        default: b = Math.Min(b, Math.Max(r, g)); break;
                    }
                var na = a * keep;
                P[q + R] = (byte)Round(Math.Min(Math.Max(r * na, 0), na));
                P[q + G] = (byte)Round(Math.Min(Math.Max(g * na, 0), na));
                P[q + B] = (byte)Round(Math.Min(Math.Max(b * na, 0), na));
                P[q + A] = (byte)Round(na);
            }
        });
    }

    public void Posterize(double levels)
    {
        var n = (double)(int)levels - 1;
        for (var q = 0; q < P.Length; q += 4)
        {
            double a = P[q + A];
            if (a <= 0) continue;
            for (var k = 0; k < 3; k++)
            {
                var c = Round(P[q + k] / a * n) / n;
                P[q + k] = (byte)Round(Math.Min(c * a, a));
            }
        }
    }

    /// <summary>Averages square blocks of size pixels, the grid anchored on the center so it moves with the layer.</summary>
    public void Pixelate(double size, double cx, double cy)
    {
        var s = Math.Max(2, (int)Round(size));
        int ox = ((int)Round(cx) % s + s) % s - s, oy = ((int)Round(cy) % s + s) % s - s;
        for (var by = oy; by < H; by += s)
        {
            int y0 = Math.Max(by, 0), y1 = Math.Min(by + s, H);
            for (var bx = ox; bx < W; bx += s)
            {
                int x0 = Math.Max(bx, 0), x1 = Math.Min(bx + s, W);
                int s0 = 0, s1 = 0, s2 = 0, s3 = 0;
                for (var y = y0; y < y1; y++)
                    for (var x = x0; x < x1; x++)
                    {
                        var q = y * Rb + 4 * x;
                        s0 += P[q]; s1 += P[q + 1]; s2 += P[q + 2]; s3 += P[q + 3];
                    }
                var n = Math.Max(1, (y1 - y0) * (x1 - x0));
                byte a0 = (byte)(s0 / n), a1 = (byte)(s1 / n), a2 = (byte)(s2 / n), a3 = (byte)(s3 / n);
                for (var y = y0; y < y1; y++)
                    for (var x = x0; x < x1; x++)
                    {
                        var q = y * Rb + 4 * x;
                        P[q] = a0; P[q + 1] = a1; P[q + 2] = a2; P[q + 3] = a3;
                    }
            }
        }
    }

    /// <summary>Color matrix on premultiplied pixels: offsets scale with alpha, so see-through parts stay
    /// see-through; channels are kept at or below alpha.</summary>
    public void ApplyColors(ColorMatrix cm)
    {
        var m = cm.M;
        var b = cm.B;
        Parallel.For(0, H, y =>
        {
            for (int x = 0, q = y * Rb; x < W; x++, q += 4)
            {
                double a = P[q + A];
                if (a <= 0) continue;
                double r = P[q + R], g = P[q + G], bl = P[q + B];
                var nr = m[0] * r + m[1] * g + m[2] * bl + b[0] * a;
                var ng = m[3] * r + m[4] * g + m[5] * bl + b[1] * a;
                var nb = m[6] * r + m[7] * g + m[8] * bl + b[2] * a;
                P[q + R] = (byte)Math.Clamp(Round(nr), 0, a);
                P[q + G] = (byte)Math.Clamp(Round(ng), 0, a);
                P[q + B] = (byte)Math.Clamp(Round(nb), 0, a);
            }
        });
    }

    // Resampling

    /// <summary>Moves pixels: each output pixel takes the bilinear sample at source(x, y) (pixel centers, y down).</summary>
    public void Remap(Func<double, double, (double X, double Y)> source)
    {
        var src = Copy();
        Parallel.For(0, H, y =>
        {
            for (var x = 0; x < W; x++)
            {
                var (sx, sy) = source(x, y);
                Sample(src, sx, sy, y * Rb + 4 * x);
            }
        });
    }

    /// <summary>Bilinear sample of s (a copy of this buffer) into P at q; outside is transparent.</summary>
    void Sample(byte[] s, double x, double y, int q)
    {
        double fx = Math.Floor(x), fy = Math.Floor(y);
        int ix = (int)fx, iy = (int)fy;
        double tx = x - fx, ty = y - fy;
        double a0 = 0, a1 = 0, a2 = 0, a3 = 0;
        void Add(int xx, int yy, double wgt)
        {
            if (wgt <= 0 || xx < 0 || yy < 0 || xx >= W || yy >= H) return;
            var i = yy * Rb + 4 * xx;
            a0 += s[i] * wgt; a1 += s[i + 1] * wgt; a2 += s[i + 2] * wgt; a3 += s[i + 3] * wgt;
        }
        Add(ix, iy, (1 - tx) * (1 - ty)); Add(ix + 1, iy, tx * (1 - ty));
        Add(ix, iy + 1, (1 - tx) * ty); Add(ix + 1, iy + 1, tx * ty);
        P[q] = (byte)Math.Min(a0 + 0.5, 255); P[q + 1] = (byte)Math.Min(a1 + 0.5, 255);
        P[q + 2] = (byte)Math.Min(a2 + 0.5, 255); P[q + 3] = (byte)Math.Min(a3 + 0.5, 255);
    }

    /// <summary>Motion-style blur along a line: averaging with shifted copies of itself at halving distances gives a
    /// box of 2^k evenly spaced taps in k passes.</summary>
    public void DirectionalBlur(double length, double degrees)
    {
        var angle = degrees * Math.PI / 180;
        double ux = Math.Cos(angle), uy = Math.Sin(angle);
        for (var step = length / 2; step >= 0.75; step /= 2)
        {
            var s = Copy();
            int dx = (int)Round(ux * step), dy = (int)Round(uy * step);
            // Centered: the two copies sit half a step either side.
            int hx = dx / 2, hy = dy / 2;
            Parallel.For(0, H, y =>
            {
                for (var x = 0; x < W; x++)
                {
                    var q = y * Rb + 4 * x;
                    int ax = x - hx, ay = y - hy, bx = x - hx + dx, by = y - hy + dy;
                    var aIn = ax >= 0 && ay >= 0 && ax < W && ay < H;
                    var bIn = bx >= 0 && by >= 0 && bx < W && by < H;
                    for (var k = 0; k < 4; k++)
                    {
                        var va = aIn ? s[ay * Rb + 4 * ax + k] : 0;
                        var vb = bIn ? s[by * Rb + 4 * bx + k] : 0;
                        P[q + k] = (byte)((va + vb + 1) / 2);
                    }
                }
            });
        }
    }

    /// <summary>Radial (zoom) blur toward the center: averaging with copies scaled toward it, halving the zoom each pass.</summary>
    public void ZoomBlur(double amount, double cx, double cy)
    {
        var f = 1 - amount; // the farthest sample is at this fraction of the distance to the center
        for (var pass = 0; pass < 6; pass++)
        {
            var src = Copy();
            var ff = f;
            Parallel.For(0, H, y =>
            {
                for (var x = 0; x < W; x++)
                {
                    var q = y * Rb + 4 * x;
                    Sample(src, cx + (x - cx) * ff, cy + (y - cy) * ff, q);
                    for (var k = 0; k < 4; k++) P[q + k] = (byte)((P[q + k] + src[q + k] + 1) / 2);
                }
            });
            f = Math.Sqrt(f);
            if (f > 0.999) break;
        }
    }

    // Stylize

    /// <summary>Red shifted right by d pixels, blue left (negative d swaps them).</summary>
    public void RgbSplit(int d)
    {
        if (d == 0) return;
        var s = Copy();
        for (var y = 0; y < H; y++)
        {
            var row = y * Rb;
            for (var x = 0; x < W; x++)
            {
                var q = row + 4 * x;
                int xr = x - d, xb = x + d;
                var (r, ra) = xr >= 0 && xr < W ? (s[row + 4 * xr + R], s[row + 4 * xr + A]) : ((byte)0, (byte)0);
                var (b, ba) = xb >= 0 && xb < W ? (s[row + 4 * xb + B], s[row + 4 * xb + A]) : ((byte)0, (byte)0);
                var (g, ga) = (s[q + G], s[q + A]);
                P[q + R] = r; P[q + G] = g; P[q + B] = b;
                P[q + A] = Math.Max(ra, Math.Max(ga, ba));
            }
        }
    }

    /// <summary>Digital glitch: random horizontal bands jump sideways with their colors split, changing ~12 times a second.</summary>
    public void Glitch(double amount, int frame, ulong seed, double pixelScale)
    {
        var s = Copy();
        var tick = (ulong)(frame / 2); // hold each glitch for two frames
        var salt = Noise.Mix(seed ^ unchecked(tick * 0x9E3779B97F4A7C15UL));
        for (int y = 0, band = 0; y < H; band++)
        {
            var height = Math.Max(2, (int)((4 + 36 * Noise.Unit(band * 3, salt)) * pixelScale));
            var hit = Noise.Unit(band * 3 + 1, salt) < amount * 0.6;
            var shift = hit ? (int)Round((Noise.Unit(band * 3 + 2, salt) * 2 - 1) * amount * 0.12 * W) : 0;
            var split = hit ? Math.Max(1, (int)(6 * amount * pixelScale)) : 0;
            if (hit)
                for (var yy = y; yy < Math.Min(y + height, H); yy++)
                {
                    var row = yy * Rb;
                    int Px(int sx, int k) => sx >= 0 && sx < W ? s[row + 4 * sx + k] : 0;
                    for (var x = 0; x < W; x++)
                    {
                        var q = row + 4 * x;
                        var xs = x - shift;
                        int ar = Px(xs - split, A), ag = Px(xs, A), ab = Px(xs + split, A);
                        P[q + R] = (byte)Px(xs - split, R); P[q + G] = (byte)Px(xs, G); P[q + B] = (byte)Px(xs + split, B);
                        P[q + A] = (byte)Math.Max(ar, Math.Max(ag, ab));
                    }
                }
            y += height;
        }
    }

    /// <summary>Film grain: monochrome noise, new every frame, only where the layer is.</summary>
    public void Grain(double amount, int frame, ulong seed)
    {
        unchecked
        {
            var salt = Noise.Mix(seed ^ (ulong)frame * 0xD1B54A32D192ED03UL);
            var strength = amount * 0.35;
            for (var y = 0; y < H; y++)
            {
                var hsh = Noise.Mix(salt ^ (ulong)y * 0x9E3779B97F4A7C15UL);
                for (int x = 0, q = y * Rb; x < W; x++, q += 4)
                {
                    hsh = hsh * 6364136223846793005UL + 1442695040888963407UL;
                    int a = P[q + A];
                    if (a <= 0) continue;
                    var n = (int)(hsh >> 56) / 127.5 - 1; // -1…1
                    var d = (int)Round(n * strength * a);
                    for (var k = 0; k < 3; k++) P[q + k] = (byte)Math.Clamp(P[q + k] + d, 0, a);
                }
            }
        }
    }

    /// <summary>Darker every other band of period / 2 rows, like a CRT.</summary>
    public void Scanlines(double amount, int period)
    {
        var f = 1 - amount * 0.6;
        for (var y = 0; y < H; y++)
        {
            if (y % period >= period / 2) continue;
            for (int x = 0, q = y * Rb; x < W; x++, q += 4)
                for (var k = 0; k < 3; k++) P[q + k] = (byte)(P[q + k] * f);
        }
    }

    /// <summary>Darkens toward the edges of the bitmap (the layer's area).</summary>
    public void Vignette(double amount)
    {
        double cx = W / 2.0, cy = H / 2.0;
        for (var y = 0; y < H; y++)
        {
            var ny = (y + 0.5 - cy) / cy;
            for (int x = 0, q = y * Rb; x < W; x++, q += 4)
            {
                var nx = (x + 0.5 - cx) / cx;
                var r = Math.Sqrt(nx * nx + ny * ny) / 1.414;
                var t = Math.Clamp((r - 0.35) / 0.65, 0, 1);
                var f = 1 - amount * t * t * (3 - 2 * t);
                for (var k = 0; k < 3; k++) P[q + k] = (byte)(P[q + k] * f);
            }
        }
    }
}

/// <summary>A parsed 3D LUT: size³ RGB entries, red varying fastest (the .cube order). Port of <c>CubeLUT</c>.</summary>
public sealed class CubeLut
{
    public readonly int Size;
    readonly float[] _data;
    readonly double[] _lo, _hi;

    CubeLut(int size, float[] data, double[] lo, double[] hi) { Size = size; _data = data; _lo = lo; _hi = hi; }

    /// <summary>Parses a .cube file (LUT_3D_SIZE, optional DOMAIN_MIN/MAX, then size³ lines of "r g b").</summary>
    public static CubeLut Parse(string text)
    {
        var size = 0;
        float[] lo = [0, 0, 0], hi = [1, 1, 1];
        var values = new List<float>();
        static float? F(string s) => float.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : null;
        foreach (var raw in text.Split('\n', '\r'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var parts = line.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            switch (parts[0])
            {
                case "LUT_3D_SIZE": size = int.TryParse(parts[^1], out var n) ? n : 0; break;
                case "DOMAIN_MIN": lo = parts.Skip(1).Select(F).OfType<float>().ToArray(); break;
                case "DOMAIN_MAX": hi = parts.Skip(1).Select(F).OfType<float>().ToArray(); break;
                case "TITLE" or "LUT_1D_SIZE" or "LUT_3D_INPUT_RANGE": break;
                default:
                    var nums = parts.Select(F).OfType<float>().ToArray();
                    if (nums.Length == 3) values.AddRange(nums);
                    break;
            }
        }
        if (size is < 2 or > 256) throw new SceneException("Not a 3D .cube LUT (missing or bad LUT_3D_SIZE)");
        if (values.Count < size * size * size * 3)
            throw new SceneException($"The .cube LUT has {values.Count / 3} entries, expected {size * size * size}");
        var domainOk = lo.Length == 3 && hi.Length == 3 && lo.Zip(hi).All(p => p.Second > p.First);
        return new CubeLut(size, values.Take(size * size * size * 3).ToArray(),
            domainOk ? lo.Select(v => (double)v).ToArray() : [0, 0, 0], domainOk ? hi.Select(v => (double)v).ToArray() : [1, 1, 1]);
    }

    static readonly Dictionary<string, (CubeLut? Lut, DateTime Modified)> Cache = [];
    static readonly Lock CacheLock = new();

    /// <summary>The LUT at a path, cached until the file changes; null if unreadable.</summary>
    public static CubeLut? Load(string path)
    {
        DateTime modified;
        try { modified = File.GetLastWriteTimeUtc(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
        lock (CacheLock)
            if (Cache.TryGetValue(path, out var hit) && hit.Modified == modified) return hit.Lut;
        CubeLut? lut = null;
        try { lut = Parse(File.ReadAllText(path)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or SceneException) { }
        lock (CacheLock) Cache[path] = (lut, modified);
        return lut;
    }

    /// <summary>Trilinear lookup of a color in 0…1.</summary>
    public (double R, double G, double B) Apply(double r, double g, double b)
    {
        var n = Size - 1;
        double Norm(double v, int k) => Math.Clamp((v - _lo[k]) / (_hi[k] - _lo[k]), 0, 1) * n;
        double fr = Norm(r, 0), fg = Norm(g, 1), fb = Norm(b, 2);
        int r0 = Math.Min((int)fr, n - 1), g0 = Math.Min((int)fg, n - 1), b0 = Math.Min((int)fb, n - 1);
        double tr = fr - r0, tg = fg - g0, tb = fb - b0;
        double o0 = 0, o1 = 0, o2 = 0;
        for (var db = 0; db <= 1; db++)
            for (var dg = 0; dg <= 1; dg++)
                for (var dr = 0; dr <= 1; dr++)
                {
                    var w = (dr == 1 ? tr : 1 - tr) * (dg == 1 ? tg : 1 - tg) * (db == 1 ? tb : 1 - tb);
                    if (w <= 0) continue;
                    var i = 3 * ((r0 + dr) + (g0 + dg) * Size + (b0 + db) * Size * Size);
                    o0 += w * _data[i]; o1 += w * _data[i + 1]; o2 += w * _data[i + 2];
                }
        return (o0, o1, o2);
    }
}

/// <summary>Color grading beyond the color matrix: input levels + a tone curve (one 256-entry table), a gradient map,
/// and 3D LUTs from .cube files. Port of <c>Grading</c> in <c>Grading.swift</c>.</summary>
public sealed class Grading
{
    byte[]? _tone;
    List<Rgba> _gradientMap = [];
    double _gradientAmount;
    CubeLut? _lut;
    double _lutAmount;

    public static Grading? Of(MotionLayer layer, double t)
    {
        var g = new Grading();
        double black = layer.Value(AnimProperty.LevelsBlack, t), white = layer.Value(AnimProperty.LevelsWhite, t);
        var gamma = Math.Max(0.05, layer.Value(AnimProperty.LevelsGamma, t));
        var levels = Math.Abs(black) > 1e-4 || Math.Abs(white - 1) > 1e-4 || Math.Abs(gamma - 1) > 1e-4;
        if (levels || layer.Curves.Count >= 2)
        {
            var curve = CurveTable(layer.Curves);
            g._tone = Enumerable.Range(0, 256).Select(i =>
            {
                var v = i / 255.0;
                if (levels) v = Math.Pow(Math.Clamp((v - black) / Math.Max(white - black, 1e-4), 0, 1), 1 / gamma);
                if (curve != null) v = curve[Math.Min(255, (int)PixelBuffer.Round(v * 255))];
                return (byte)PixelBuffer.Round(Math.Clamp(v, 0, 1) * 255);
            }).ToArray();
        }
        if (layer.GradientMap.Count >= 1)
        {
            g._gradientMap = layer.GradientMap;
            g._gradientAmount = Math.Clamp(layer.Value(AnimProperty.GradientMapAmount, t), 0, 1);
        }
        if (layer.Lut is { } path && CubeLut.Load(path) is { } cube)
        {
            g._lut = cube;
            g._lutAmount = Math.Clamp(layer.Value(AnimProperty.LutAmount, t), 0, 1);
        }
        return g._tone != null || g._gradientAmount > 0.001 || (g._lut != null && g._lutAmount > 0.001) ? g : null;
    }

    /// <summary>A smooth monotone curve through the points (Fritsch–Carlson), sampled at 256 steps.</summary>
    public static double[]? CurveTable(List<PathPoint> pts)
    {
        if (pts.Count < 2) return null;
        var xs = pts.Select(p => p.X).ToArray();
        var ys = pts.Select(p => p.Y).ToArray();
        var n = xs.Length;
        var d = new double[n - 1];
        for (var i = 0; i < n - 1; i++) d[i] = (ys[i + 1] - ys[i]) / Math.Max(xs[i + 1] - xs[i], 1e-6);
        var m = new double[n];
        m[0] = d[0]; m[n - 1] = d[n - 2];
        for (var i = 1; i < n - 1; i++) m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
        for (var i = 0; i < n - 1; i++) if (d[i] == 0) { m[i] = 0; m[i + 1] = 0; }
        return Enumerable.Range(0, 256).Select(k =>
        {
            var x = k / 255.0;
            if (x <= xs[0]) return ys[0];
            if (x >= xs[n - 1]) return ys[n - 1];
            var i = 0;
            while (i < n - 2 && x > xs[i + 1]) i++;
            var h = Math.Max(xs[i + 1] - xs[i], 1e-6);
            var u = (x - xs[i]) / h;
            double h00 = 2 * u * u * u - 3 * u * u + 1, h10 = u * u * u - 2 * u * u + u;
            double h01 = -2 * u * u * u + 3 * u * u, h11 = u * u * u - u * u;
            return h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1];
        }).ToArray();
    }

    public void Apply(PixelBuffer buf)
    {
        const int R = PixelBuffer.R, G = PixelBuffer.G, B = PixelBuffer.B, A = PixelBuffer.A;
        var p = buf.P;
        var gm = _gradientMap;
        Parallel.For(0, buf.H, y =>
        {
            for (int x = 0, q = y * buf.W * 4; x < buf.W; x++, q += 4)
            {
                double a = p[q + A];
                if (a <= 0) continue;
                double r = p[q + R] / a, g = p[q + G] / a, b = p[q + B] / a;
                if (_tone is { } tone)
                {
                    r = tone[Math.Min(255, (int)(r * 255 + 0.5))] / 255.0;
                    g = tone[Math.Min(255, (int)(g * 255 + 0.5))] / 255.0;
                    b = tone[Math.Min(255, (int)(b * 255 + 0.5))] / 255.0;
                }
                if (_gradientAmount > 0.001 && gm.Count > 0)
                {
                    var l = Math.Clamp(0.2126 * r + 0.7152 * g + 0.0722 * b, 0, 1);
                    Rgba c;
                    if (gm.Count == 1) c = gm[0];
                    else
                    {
                        var f = l * (gm.Count - 1);
                        var i = Math.Min((int)f, gm.Count - 2);
                        c = Rgba.Lerp(gm[i], gm[i + 1], f - i);
                    }
                    r += (c.R - r) * _gradientAmount; g += (c.G - g) * _gradientAmount; b += (c.B - b) * _gradientAmount;
                }
                if (_lut != null && _lutAmount > 0.001)
                {
                    var (lr, lg, lb) = _lut.Apply(r, g, b);
                    r += (lr - r) * _lutAmount; g += (lg - g) * _lutAmount; b += (lb - b) * _lutAmount;
                }
                p[q + R] = (byte)(Math.Clamp(r, 0, 1) * a + 0.5);
                p[q + G] = (byte)(Math.Clamp(g, 0, 1) * a + 0.5);
                p[q + B] = (byte)(Math.Clamp(b, 0, 1) * a + 0.5);
            }
        });
    }
}
