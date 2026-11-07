using System.Numerics;

namespace VeyMotion.Core;

/// <summary>What an audioReact follows: a loudness band, or a pulse on every beat / bar.</summary>
public enum AudioBand { Level, Bass, Mid, Treble, Beat, Downbeat }

/// <summary>Where an audio layer's file plays in the scene. Filled in by ResolveLinks, not saved.</summary>
public sealed record AudioLink(string Path, double Start, double TrimIn, double End)
{
    /// <summary>File time playing at scene time t, or null when the layer is silent then.</summary>
    public double? FileTime(double t) => t >= Start && t < End ? t - Start + TrimIn : null;
}

/// <summary>Adds amount × the music's level (0…1) in a band to a property: the layer moves with the sound.</summary>
public sealed class AudioReact
{
    public const double DefaultRelease = 0.2;
    public double Amount = 0.1;
    public AudioBand Band = AudioBand.Level;
    public double Release = DefaultRelease;
    /// <summary>Audio layer id; null = the scene's music layer (or its first audio layer).</summary>
    public string? Source;
    public AudioLink? Link;

    public double Offset(double t)
    {
        if (Amount == 0 || Link?.FileTime(t) is not { } ft || AudioAnalysisCache.Envelope(Link.Path, Band, Release) is not { } env) return 0;
        return Amount * AudioAnalysis.Sample(env, ft);
    }
}

/// <summary>Rhythm and loudness of an audio file (file seconds): tempo, beats, downbeats, onsets, band envelopes and a
/// 40-band spectrum. Port of <c>AudioAnalysis.swift</c>.</summary>
public sealed class AudioAnalysis
{
    public const double FrameRate = 100;
    const double OnsetLatency = 0.01;

    public readonly record struct Onset(double T, double Strength);

    public double Duration { get; init; }
    public double? Bpm { get; init; }
    public List<double> Beats { get; init; } = [];
    public List<double> Downbeats { get; init; } = [];
    public List<Onset> Onsets { get; init; } = [];
    internal Dictionary<AudioBand, float[]> Bands { get; init; } = [];
    internal float[] Spectrum { get; set; } = [];
    internal int SpectrumBands { get; set; }

    /// <summary>Envelope of a band at FrameRate with an instant attack and an exponential release (seconds);
    /// beat/downbeat: a pulse of 1 on each that fades over the release.</summary>
    public float[] Envelope(AudioBand band, double release)
    {
        var count = (int)Math.Ceiling(Duration * FrameRate) + 1;
        var decay = (float)Math.Exp(-1 / (Math.Max(release, 0.01) * FrameRate));
        var output = new float[count];
        float v = 0;
        if (band is AudioBand.Beat or AudioBand.Downbeat)
        {
            var hits = new bool[count];
            foreach (var t in band == AudioBand.Beat ? Beats : Downbeats)
            {
                var i = (int)Math.Round(t * FrameRate);
                if (i >= 0 && i < count) hits[i] = true;
            }
            for (var i = 0; i < count; i++) output[i] = v = hits[i] ? 1 : v * decay;
        }
        else
        {
            var raw = Bands.GetValueOrDefault(band) ?? [];
            for (var i = 0; i < Math.Min(count, raw.Length); i++) output[i] = v = Math.Max(raw[i], v * decay);
        }
        return output;
    }

    /// <summary>Loudness (0…1) averaged over each step seconds.</summary>
    public List<double> Loudness(double from, double to, double step = 1)
    {
        var output = new List<double>();
        if (!Bands.TryGetValue(AudioBand.Level, out var level) || to <= from) return output;
        for (var t = from; t < to - 1e-9; t += step)
        {
            int a = Math.Max(0, (int)(t * FrameRate)), b = Math.Min(level.Length, (int)(Math.Min(t + step, to) * FrameRate));
            output.Add(b > a ? level.AsSpan(a, b - a).ToArray().Average(x => (double)x) : 0);
        }
        return output;
    }

    /// <summary>count spectrum values (0…1, low to high) at file time t; bands fall back over release seconds.</summary>
    public double[] SpectrumAt(double t, int count, double release = 0.12)
    {
        var nb = SpectrumBands;
        if (nb <= 0 || count <= 0) return new double[Math.Max(count, 0)];
        var frames = Spectrum.Length / nb;
        var f = (int)Math.Floor(t * FrameRate);
        var back = Math.Max(1, (int)(release * FrameRate * 3));
        var bands = new double[nb];
        if (f >= 0 && f < frames + back)
            for (var k = 0; k < back; k++)
            {
                var i = f - k;
                if (i < 0 || i >= frames) continue;
                var decay = Math.Exp(-k / (release * FrameRate));
                for (var j = 0; j < nb; j++) bands[j] = Math.Max(bands[j], Spectrum[i * nb + j] * decay);
            }
        return Enumerable.Range(0, count).Select(c =>
        {
            var x = count == 1 ? 0 : (double)c / (count - 1) * (nb - 1);
            var i = Math.Min((int)x, nb - 2);
            var fr = x - i;
            return nb == 1 ? bands[0] : bands[i] + (bands[i + 1] - bands[i]) * fr;
        }).ToArray();
    }

    /// <summary>Linear interpolation into an envelope at file time t.</summary>
    public static double Sample(float[] env, double t)
    {
        var x = t * FrameRate;
        if (x < 0 || env.Length == 0) return 0;
        var i = (int)x;
        if (i + 1 >= env.Length) return i < env.Length ? env[i] : 0;
        var f = (float)(x - i);
        return env[i] + (env[i + 1] - env[i]) * f;
    }

    // Analysis

    /// <summary>Analyzes stereo 48 kHz samples (mixed to mono at 24 kHz, plenty for rhythm and bands).</summary>
    public static AudioAnalysis FromStereo48k(float[] stereo)
    {
        var mono = new float[stereo.Length / 4];
        for (var i = 0; i < mono.Length; i++) mono[i] = (stereo[i * 4] + stereo[i * 4 + 1] + stereo[i * 4 + 2] + stereo[i * 4 + 3]) / 4;
        return Analyze(mono, 24_000);
    }

    public static AudioAnalysis Analyze(float[] samples, double sr)
    {
        var duration = samples.Length / sr;
        const int n = 1024, half = n / 2;
        var hop = sr / FrameRate;
        var frames = Math.Max(1, (int)(samples.Length / hop) + 1);
        var window = new float[n];
        for (var k = 0; k < n; k++) window[k] = (float)(0.5 * (1 - Math.Cos(2 * Math.PI * k / n)));
        var binHz = sr / n;
        var bassEnd = Math.Max(2, (int)(150 / binHz));
        var midEnd = Math.Max(bassEnd + 1, (int)(2000 / binHz));
        var trebleEnd = Math.Min(half, Math.Max(midEnd + 1, (int)(10_000 / binHz)));
        // Onsets on ~log-spaced bands, so a kick's few low bins count as much as a hi-hat's many high ones.
        var edges = new List<int>();
        const int bandCount = 40;
        for (var b = 0; b <= bandCount; b++)
        {
            var hz = 30 * Math.Pow(11_000.0 / 30, (double)b / bandCount);
            var k = Math.Min(trebleEnd, Math.Max(1, (int)Math.Round(hz / binHz)));
            if (edges.Count == 0 || k > edges[^1]) edges.Add(k);
        }
        float[] level = new float[frames], bass = new float[frames], mid = new float[frames], treble = new float[frames], flux = new float[frames];
        var specBands = edges.Count - 1;
        var spectrum = new float[frames * specBands];
        const float norm = n;
        var fft = new Complex[n];
        var power = new float[half];
        float[] logMag = new float[edges.Count], prevLog = new float[edges.Count];
        for (var f = 0; f < frames; f++)
        {
            var start = (int)(f * hop) - half;
            for (var k = 0; k < n; k++)
            {
                var i = start + k;
                fft[k] = new Complex(i >= 0 && i < samples.Length ? samples[i] * window[k] : 0, 0);
            }
            Fft(fft);
            // vDSP's real FFT is twice the DFT: power is |2X|².
            for (var k = 0; k < half; k++) power[k] = (float)(4 * (fft[k].Real * fft[k].Real + fft[k].Imaginary * fft[k].Imaginary));
            power[0] = 0;
            float bsum = 0, msum = 0, tsum = 0, sum = 0, fl = 0;
            for (var k = 1; k < trebleEnd; k++)
            {
                var p = power[k];
                sum += p;
                if (k < bassEnd) bsum += p; else if (k < midEnd) msum += p; else tsum += p;
            }
            for (var j = 0; j < edges.Count - 1; j++)
            {
                float p = 0;
                for (var k = edges[j]; k < edges[j + 1]; k++) p += power[k];
                logMag[j] = MathF.Log(1 + 100 * MathF.Sqrt(p) / norm);
                fl += Math.Max(0, logMag[j] - prevLog[j]);
                spectrum[f * specBands + j] = logMag[j];
            }
            (logMag, prevLog) = (prevLog, logMag);
            level[f] = MathF.Sqrt(sum) / norm;
            bass[f] = MathF.Sqrt(bsum) / norm;
            mid[f] = MathF.Sqrt(msum) / norm;
            treble[f] = MathF.Sqrt(tsum) / norm;
            flux[f] = f == 0 ? 0 : fl;
        }
        var bands = new Dictionary<AudioBand, float[]>
        {
            [AudioBand.Level] = Normalized(level), [AudioBand.Bass] = Normalized(bass),
            [AudioBand.Mid] = Normalized(mid), [AudioBand.Treble] = Normalized(treble),
        };
        for (var j = 0; j < specBands; j++)
        {
            var column = Normalized(Enumerable.Range(0, frames).Select(f => spectrum[f * specBands + j]).ToArray());
            for (var f = 0; f < frames; f++) spectrum[f * specBands + j] = column[f];
        }
        var onsetEnv = OnsetStrength(flux);
        var onsets = PickOnsets(onsetEnv);
        AudioAnalysis Finish(double? bpm, List<double> beats, List<double> downbeats) => new()
        {
            Duration = duration, Bpm = bpm, Beats = beats, Downbeats = downbeats, Onsets = onsets, Bands = bands,
            Spectrum = spectrum, SpectrumBands = specBands,
        };
        if (Tempo(onsetEnv) is not { } period) return Finish(null, [], []);
        var beatFrames = TrackBeats(onsetEnv, period);
        // Drop beats in silence at the start and end.
        var loud = bands[AudioBand.Level];
        bool Audible(int f)
        {
            int a = Math.Max(0, f - 10), b = Math.Min(loud.Length, f + 10);
            return b > a && loud.AsSpan(a, b - a).ToArray().Max() > 0.05;
        }
        while (beatFrames.Count > 0 && !Audible(beatFrames[0])) beatFrames.RemoveAt(0);
        while (beatFrames.Count > 0 && !Audible(beatFrames[^1])) beatFrames.RemoveAt(beatFrames.Count - 1);
        var beatsT = beatFrames.Select(f => f / FrameRate + OnsetLatency).ToList();
        // Tempo from the beats themselves (least squares slope of time against beat number).
        var bpmValue = 60 * FrameRate / period;
        if (beatsT.Count >= 4)
        {
            double k = beatsT.Count, mx = (k - 1) / 2, my = beatsT.Average(), num = 0, den = 0;
            for (var i = 0; i < beatsT.Count; i++) { num += (i - mx) * (beatsT[i] - my); den += (i - mx) * (i - mx); }
            if (num > 0) bpmValue = 60 / (num / den);
        }
        // Downbeats: the phase (of 4) whose beats carry the most bass and onset energy.
        var downbeatsT = new List<double>();
        if (beatFrames.Count >= 8)
        {
            var low = bands[AudioBand.Bass];
            int best = 0;
            var bestScore = float.NegativeInfinity;
            for (var phase = 0; phase < 4; phase++)
            {
                float s = 0;
                for (var i = 0; i < beatFrames.Count; i++)
                    if (i % 4 == phase && beatFrames[i] < low.Length) s += low[beatFrames[i]] + 0.5f * onsetEnv[beatFrames[i]];
                if (s > bestScore) { bestScore = s; best = phase; }
            }
            downbeatsT = beatsT.Where((_, i) => i % 4 == best).ToList();
        }
        return Finish(Math.Round(bpmValue * 10) / 10, beatsT, downbeatsT);
    }

    /// <summary>In-place radix-2 FFT.</summary>
    static void Fft(Complex[] a)
    {
        var n = a.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            var bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) (a[i], a[j]) = (a[j], a[i]);
        }
        for (var len = 2; len <= n; len <<= 1)
        {
            var ang = -2 * Math.PI / len;
            var wl = new Complex(Math.Cos(ang), Math.Sin(ang));
            for (var i = 0; i < n; i += len)
            {
                var w = Complex.One;
                for (var k = 0; k < len / 2; k++)
                {
                    var u = a[i + k];
                    var v = a[i + k + len / 2] * w;
                    a[i + k] = u + v;
                    a[i + k + len / 2] = u - v;
                    w *= wl;
                }
            }
        }
    }

    /// <summary>Scales so the loud parts (98th percentile) are 1.</summary>
    static float[] Normalized(float[] v)
    {
        if (v.Length == 0) return v;
        var sorted = v.Order().ToArray();
        var r = sorted[Math.Min(sorted.Length - 1, (int)(sorted.Length * 0.98))];
        if (r <= 1e-5) return new float[v.Length];
        return v.Select(x => Math.Min(x / r, 1)).ToArray();
    }

    /// <summary>Spectral flux minus its 1 s running mean, in standard deviations (≥ 0, deviation floored).</summary>
    static float[] OnsetStrength(float[] flux)
    {
        int n = flux.Length, r = (int)(FrameRate / 2);
        var prefix = new double[n + 1];
        for (var i = 0; i < n; i++) prefix[i + 1] = prefix[i] + flux[i];
        var o = new float[n];
        for (var i = 0; i < n; i++)
        {
            int a = Math.Max(0, i - r), b = Math.Min(n, i + r + 1);
            o[i] = Math.Max(0, flux[i] - (float)((prefix[b] - prefix[a]) / (b - a)));
        }
        var mean = o.Sum() / Math.Max(n, 1);
        var sd = MathF.Sqrt(o.Sum(x => (x - mean) * (x - mean)) / Math.Max(n, 1));
        var scale = Math.Max(sd, 0.5f);
        return o.Select(x => x / scale).ToArray();
    }

    /// <summary>Local peaks of the onset strength that stand out, at least 80 ms apart.</summary>
    static List<Onset> PickOnsets(float[] o)
    {
        var n = o.Length;
        var output = new List<Onset>();
        if (n <= 8) return output;
        var sorted = o.Order().ToArray();
        var top = Math.Max(sorted[Math.Min(n - 1, (int)(n * 0.99))], 1e-6f);
        var last = -100;
        for (var i = 0; i < n; i++)
        {
            if (o[i] <= 1) continue;
            int a = Math.Max(0, i - 3), b = Math.Min(n, i + 4);
            if (o[i] < o.AsSpan(a, b - a).ToArray().Max() || i - last < 8) continue;
            var ma = Math.Max(0, i - 10);
            var localMean = o.AsSpan(ma, b - ma).ToArray().Average();
            if (o[i] < localMean + 0.5) continue;
            output.Add(new Onset(i / FrameRate + OnsetLatency, Math.Min(o[i] / top, 1)));
            last = i;
        }
        return output;
    }

    /// <summary>Beat period in frames (60–200 BPM, favoring ~120), from the onset strength's autocorrelation.</summary>
    static double? Tempo(float[] o)
    {
        var n = o.Length;
        int minLag = (int)(FrameRate * 60 / 200), maxLag = (int)(FrameRate * 60 / 60);
        if (n <= maxLag * 4) return null;
        if (o.Order().ElementAt(n * 99 / 100) < 1.5) return null;
        var mean = o.Average();
        var c = o.Select(x => x - mean).ToArray();
        var ac = new double[maxLag + 2];
        for (var lag = minLag - 1; lag <= maxLag + 1; lag++)
        {
            double s = 0;
            for (var i = 0; i < n - lag; i++) s += c[i] * c[i + lag];
            ac[lag] = s / (n - lag);
        }
        int best = -1;
        var bestScore = 0.0;
        for (var lag = minLag; lag <= maxLag; lag++)
        {
            if (!(ac[lag] > 0 && ac[lag] >= ac[lag - 1] && ac[lag] >= ac[lag + 1])) continue;
            var bpm = 60 * FrameRate / lag;
            var weight = Math.Exp(-0.5 * Math.Pow(Math.Log2(bpm / 120), 2));
            if (ac[lag] * weight > bestScore) { bestScore = ac[lag] * weight; best = lag; }
        }
        if (best <= 0) return null;
        var avg = Enumerable.Range(minLag, maxLag - minLag + 1).Select(l => Math.Max(ac[l], 0)).Average();
        if (ac[best] <= avg * 1.3) return null;
        double y0 = ac[best - 1], y1 = ac[best], y2 = ac[best + 1];
        var d = y0 - 2 * y1 + y2;
        var shift = Math.Abs(d) > 1e-12 ? 0.5 * (y0 - y2) / d : 0;
        return best + Math.Clamp(shift, -0.5, 0.5);
    }

    /// <summary>Dynamic-programming beat tracker (Ellis 2007).</summary>
    static List<int> TrackBeats(float[] o, double period)
    {
        var n = o.Length;
        if (n == 0) return [];
        var sigma = Math.Max(1, period / 32);
        var radius = (int)Math.Ceiling(3 * sigma);
        var kernel = Enumerable.Range(-radius, 2 * radius + 1).Select(x => (float)Math.Exp(-0.5 * Math.Pow(x / sigma, 2))).ToArray();
        var local = new float[n];
        for (var i = 0; i < n; i++)
        {
            float s = 0;
            for (var j = 0; j < kernel.Length; j++)
            {
                var k = i + j - radius;
                if (k >= 0 && k < n) s += o[k] * kernel[j];
            }
            local[i] = s;
        }
        const double tightness = 100;
        int lo = (int)Math.Round(period / 2, MidpointRounding.AwayFromZero), hi = (int)Math.Round(period * 2, MidpointRounding.AwayFromZero);
        var cost = new double[hi + 1];
        for (var d = Math.Max(lo, 1); d <= hi; d++) cost[d] = tightness * Math.Pow(Math.Log(d / period), 2);
        var score = new double[n];
        var back = new int[n];
        for (var i = 0; i < n; i++)
        {
            var best = double.NegativeInfinity;
            var arg = -1;
            int from = Math.Max(0, i - hi), to = i - Math.Max(lo, 1);
            for (var j = from; j <= to; j++)
            {
                var s = score[j] - cost[i - j];
                if (s > best) { best = s; arg = j; }
            }
            if (arg >= 0 && best > 0) { score[i] = local[i] + best; back[i] = arg; }
            else { score[i] = local[i]; back[i] = -1; }
        }
        var tail = Math.Max(0, n - hi);
        var at = tail;
        for (var i = tail; i < n; i++) if (score[i] > score[at]) at = i;
        var beats = new List<int>();
        for (; at >= 0; at = back[at]) beats.Add(at);
        beats.Reverse();
        return beats;
    }
}

/// <summary>Analyses and envelopes per file, shared by the renderer (any thread), tools and the UI. Files that cannot
/// be decoded are remembered as failures. Port of <c>AudioAnalysisCache</c>.</summary>
public static class AudioAnalysisCache
{
    /// <summary>Where sound comes from (the app's decoder). Without it nothing is analyzed.</summary>
    public static IAudioSource? Source { get; set; }
    /// <summary>Raised (on a worker thread) when a background analysis finishes.</summary>
    public static event Action<string>? Analyzed;

    static readonly Lock Gate = new();
    static readonly Dictionary<string, AudioAnalysis?> Results = [];
    static readonly Dictionary<string, float[]> Envelopes = [];
    static readonly Dictionary<string, Task> InFlight = [];
    [ThreadStatic] static bool _noWait;

    /// <summary>The calling thread never waits for an analysis (the app's UI thread).</summary>
    public static void NeverWaitOnThisThread() => _noWait = true;

    /// <summary>Runs body without waiting for analyses: reactions read 0 until their file is analyzed in the
    /// background, then Analyzed is raised (the canvas preview).</summary>
    public static T WithoutWaiting<T>(Func<T> body)
    {
        var old = _noWait;
        _noWait = true;
        try { return body(); }
        finally { _noWait = old; }
    }

    /// <summary>The file's analysis (waits unless inside WithoutWaiting); null if it cannot be analyzed.</summary>
    public static AudioAnalysis? Analysis(string path, bool? wait = null)
    {
        Task task;
        lock (Gate)
        {
            if (Results.TryGetValue(path, out var hit)) return hit;
            if (!InFlight.TryGetValue(path, out task!))
            {
                task = Task.Run(() =>
                {
                    AudioAnalysis? a = null;
                    try { a = Source?.Stereo48k(path) is { } pcm ? AudioAnalysis.FromStereo48k(pcm) : null; }
                    catch (Exception e) when (e is IOException or InvalidOperationException or ArgumentException) { }
                    lock (Gate) { Results[path] = a; InFlight.Remove(path); }
                    Analyzed?.Invoke(path);
                });
                InFlight[path] = task;
            }
        }
        if (!(wait ?? !_noWait)) return null;
        task.Wait();
        lock (Gate) return Results.GetValueOrDefault(path);
    }

    public static float[]? Envelope(string path, AudioBand band, double release)
    {
        var key = $"{path}|{band}|{Math.Round(release * 1000)}";
        lock (Gate) if (Envelopes.TryGetValue(key, out var e)) return e;
        if (Analysis(path) is not { } a) return null;
        var env = a.Envelope(band, release);
        lock (Gate) Envelopes[key] = env;
        return env;
    }

    /// <summary>Forgets a file (overwritten) or everything.</summary>
    public static void Invalidate(string? path = null)
    {
        lock (Gate)
        {
            foreach (var k in Results.Keys.Where(k => path == null || k == path).ToList()) Results.Remove(k);
            foreach (var k in Envelopes.Keys.Where(k => path == null || k.StartsWith(path + "|")).ToList()) Envelopes.Remove(k);
        }
    }
}
