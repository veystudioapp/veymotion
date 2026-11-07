using System.Globalization;

namespace VeyMotion.Core;

/// <summary>What kind of sound a file is (the main burst's shape). JSON names via <c>Json()</c>: hit, whoosh, …</summary>
public enum SoundShape
{
    /// <summary>Sharp attack then decay: pop, click, impact, ding.</summary>
    Hit,
    /// <summary>Swells up and fades out: whoosh, swoosh, swipe.</summary>
    Whoosh,
    /// <summary>Builds up to the end: riser, build-up, reverse cymbal.</summary>
    Riser,
    /// <summary>Steady level: ambience, loop, drone, room tone.</summary>
    Sustained,
    /// <summary>Several separate sounds in one file.</summary>
    Multiple,
    Silent,
}

public static class SoundShapeExtensions
{
    public static string Meaning(this SoundShape s) => s switch
    {
        SoundShape.Hit => "sharp hit that decays",
        SoundShape.Whoosh => "swells then fades (whoosh-like)",
        SoundShape.Riser => "builds up to the end (riser)",
        SoundShape.Sustained => "steady sound (ambience/loop)",
        SoundShape.Multiple => "several separate sounds",
        _ => "silent",
    };
}

/// <summary>The shape of a short sound (a sound effect), so an agent can choose and place one without hearing it: where
/// the sound starts after any leading silence, where it hits hardest (the moment to line up with the picture), where
/// it dies out, how many separate hits the file holds, and what kind of sound it is (hit, whoosh, riser, sustained).
/// All times are file seconds. Port of <c>SoundProfile.swift</c>.</summary>
public sealed class SoundProfile
{
    /// <summary>One separate sound in the file (hits are split by at least ~80 ms of near-silence). <c>Peak</c> is
    /// the loudest moment: line this up with the visual event. <c>Level</c> is 0…1 against the loudest burst.</summary>
    public readonly record struct Burst(double Start, double Peak, double End, double Level)
    {
        public double Length => End - Start;
    }

    /// <summary>Scene time the layer starts, file seconds skipped, scene time it stops (null = end of file).</summary>
    public record struct Placement(double Start, double TrimIn, double? End, double FadeOut, double HitTime);

    /// <summary>Envelope samples per second.</summary>
    public const double Rate = 200.0;

    public double Duration { get; init; }
    /// <summary>First and last audible moment (about 40 dB below the loudest part).</summary>
    public double SoundStart { get; init; }
    public double SoundEnd { get; init; }
    /// <summary>The main hit: the loudest burst's peak (for a riser, where it tops out).</summary>
    public double Peak { get; init; }
    public IReadOnlyList<Burst> Bursts { get; init; } = [];
    public SoundShape Shape { get; init; }
    /// <summary>Loudest sample, dBFS.</summary>
    public double PeakDB { get; init; }
    /// <summary>"low", "mid" or "bright", from the energy-weighted zero-crossing rate.</summary>
    public string Tone { get; init; } = "mid";
    /// <summary>Peak absolute amplitude per 1/Rate s (0…1 of full scale), for drawing.</summary>
    public float[] Envelope { get; init; } = [];

    /// <summary>The burst an agent means by <c>hit</c> (1-based), or the main one.</summary>
    public Burst? BurstFor(int? hit)
    {
        if (hit is { } h && h >= 1 && h <= Bursts.Count) return Bursts[h - 1];
        return MaxLevel(Bursts);
    }

    /// <summary>The loudest burst (the first of equals), or null.</summary>
    static Burst? MaxLevel(IReadOnlyList<Burst> bursts)
    {
        Burst? best = null;
        foreach (var b in bursts) if (best is not { } m || m.Level < b.Level) best = b;
        return best;
    }

    // Analysis

    /// <summary>Decodes and profiles a file (meant for sound effects; long files take a while and say little).</summary>
    public static SoundProfile Analyze(string path)
    {
        var stereo = AudioAnalysisCache.Source?.Stereo48k(path) ?? throw new SceneException($"Cannot read audio file: {path}");
        return FromStereo48k(stereo);
    }

    /// <summary>Profiles interleaved stereo float at 48 kHz, mixed to mono at 24 kHz (what <c>readMono</c> gives on macOS).</summary>
    public static SoundProfile FromStereo48k(float[] stereo)
    {
        var mono = new float[stereo.Length / 4];
        for (var i = 0; i < mono.Length; i++) mono[i] = (stereo[i * 4] + stereo[i * 4 + 1] + stereo[i * 4 + 2] + stereo[i * 4 + 3]) / 4;
        return Analyze(mono, AudioMixer.SampleRate / 2);
    }

    public static SoundProfile Analyze(float[] samples, double sr)
    {
        var duration = samples.Length / sr;
        var hop = Math.Max(1, (int)(sr / Rate));
        var count = (samples.Length + hop - 1) / hop;
        var peakEnv = new float[count];
        var rms = new float[count];
        double zcrWeighted = 0, energyTotal = 0;
        for (var w = 0; w < count; w++)
        {
            int a0 = w * hop, b0 = Math.Min(samples.Length, a0 + hop);
            float p = 0, s = 0;
            var zc = 0;
            for (var i = a0; i < b0; i++)
            {
                var v = samples[i];
                p = Math.Max(p, Math.Abs(v));
                s += v * v;
                if (i > a0 && (v >= 0) != (samples[i - 1] >= 0)) zc++;
            }
            peakEnv[w] = p;
            double e = s;
            rms[w] = MathF.Sqrt(s / Math.Max(1, b0 - a0));
            zcrWeighted += (double)zc / Math.Max(1, b0 - a0) * e;
            energyTotal += e;
        }
        var maxPeak = count > 0 ? peakEnv.Max() : 0;
        var peakDB = maxPeak > 0 ? 20 * Math.Log10(maxPeak) : -120;
        // Lightly smoothed loudness (15 ms) for finding peaks and edges.
        var loud = (float[])rms.Clone();
        if (count > 2) for (var i = 1; i < count - 1; i++) loud[i] = (rms[i - 1] + rms[i] + rms[i + 1]) / 3;
        var top = count > 0 ? loud.Max() : 0;
        if (!(top > 1e-4))
            return new SoundProfile
            {
                Duration = duration, SoundStart = 0, SoundEnd = duration, Peak = 0, Bursts = [], Shape = SoundShape.Silent,
                PeakDB = peakDB, Tone = "mid", Envelope = peakEnv,
            };
        // 40 ms centered average, for the top of slow swells.
        var smooth = new float[count];
        {
            var prefix = new float[count + 1];
            for (var i = 0; i < count; i++) prefix[i + 1] = prefix[i] + rms[i];
            const int r = 4;
            for (var i = 0; i < count; i++)
            {
                int a0 = Math.Max(0, i - r), b0 = Math.Min(count, i + r + 1);
                smooth[i] = (prefix[b0] - prefix[a0]) / (b0 - a0);
            }
        }
        float Db(float d) => top * MathF.Pow(10, d / 20);
        float audible = Db(-40), separate = Db(-26);
        var first = Array.FindIndex(loud, v => v > audible);
        if (first < 0) first = 0;
        var last = Array.FindLastIndex(loud, v => v > audible);
        if (last < 0) last = count - 1;

        // Bursts: runs above -26 dB, merged across gaps under 80 ms, widened to the -40 dB edges.
        var runs = new List<(int A, int B)>();
        for (var i = 0; i < count;)
        {
            if (!(loud[i] > separate)) { i++; continue; }
            var j = i;
            while (j + 1 < count && loud[j + 1] > separate) j++;
            if (runs.Count > 0 && (i - runs[^1].B) / Rate < 0.08) runs[^1] = (runs[^1].A, j); else runs.Add((i, j));
            i = j + 1;
        }
        var bursts = new List<Burst>();
        for (var k = 0; k < runs.Count; k++)
        {
            var run = runs[k];
            var floor = k > 0 ? runs[k - 1].B + 1 : 0;
            var ceiling = k + 1 < runs.Count ? runs[k + 1].A - 1 : count - 1;
            int a = run.A, b = run.B;
            while (a > floor && loud[a - 1] > audible && loud[a - 1] <= loud[a] * 1.05f) a--;
            while (b < ceiling && loud[b + 1] > audible) b++;
            var p = ArgMax(loud, run.A, run.B);
            // The hit: for a sharp attack (within 60 ms of the start) the strike, where the level first reaches
            // -3 dB of the peak; otherwise the top of the 40 ms-smoothed loudness (the middle of a whoosh, the end
            // of a riser), which noise cannot pull around like the raw maximum.
            int hit;
            if ((p - a) / Rate <= 0.08)
            {
                var near = loud[p] * 0.7f;
                hit = p;
                for (var q = a; q <= p; q++) if (loud[q] >= near) { hit = q; break; }
            }
            else
            {
                hit = ArgMax(smooth, a, b);
            }
            hit = Math.Min(Math.Max(hit, a), b);
            bursts.Add(new Burst(a / Rate, (hit + 0.5) / Rate, Math.Min(duration, (b + 1) / Rate), loud[p] / top));
        }
        // Drop crumbs (very short and quiet) so "3 hits" means three real ones.
        bursts = bursts.Where(x => x.Level >= 0.12 || x.Length >= 0.15).ToList();
        if (bursts.Count == 0)
        {
            var at = Array.IndexOf(loud, top);
            bursts = [new Burst(first / Rate, (at >= 0 ? at : first) / Rate, (last + 1) / Rate, 1)];
        }
        var main = MaxLevel(bursts)!.Value;

        // Shape of the main burst.
        SoundShape shape;
        double length = main.Length, attack = main.Peak - main.Start, release = main.End - main.Peak;
        var strong = bursts.Count(x => x.Level >= 0.3);
        var la = Math.Min((int)(main.Start * Rate), count - 1);
        var lb = Math.Max(la + 1, Math.Min(count, (int)(main.End * Rate)));
        var levels = loud[la..lb];
        Array.Sort(levels);
        var spread = levels[(int)(levels.Length * 0.9)] / Math.Max(levels[(int)(levels.Length * 0.2)], 1e-6f);
        if (strong >= 2)
            shape = SoundShape.Multiple;
        else if (length > 2.5 && spread < 4)
            shape = SoundShape.Sustained;
        else if (attack >= 0.6 * length && length > 0.3)
            shape = SoundShape.Riser;
        else if (attack <= 0.03 || (attack <= 0.08 && release >= 2.5 * attack))
            // Real hits (punches, slams, glitches) often take 50–80 ms to peak; what sets them apart from a
            // whoosh is that they die out much more slowly than they rise.
            shape = SoundShape.Hit;
        else
            shape = SoundShape.Whoosh;
        var hz = energyTotal > 0 ? zcrWeighted / energyTotal * sr / 2 : 0;
        var tone = hz < 600 ? "low" : hz < 2500 ? "mid" : "bright";
        return new SoundProfile
        {
            Duration = duration, SoundStart = first / Rate, SoundEnd = Math.Min(duration, (last + 1) / Rate),
            Peak = main.Peak, Bursts = bursts, Shape = shape, PeakDB = peakDB, Tone = tone, Envelope = peakEnv,
        };
    }

    /// <summary>Index of the largest value in [from, to] (the first of equals).</summary>
    static int ArgMax(float[] v, int from, int to)
    {
        var best = from;
        for (var i = from + 1; i <= to; i++) if (v[best] < v[i]) best = i;
        return best;
    }

    // Description and placement

    /// <summary>Two decimals without trailing zeros ("0.5", "1.25", "2").</summary>
    public static string Fmt(double v)
    {
        var s = v.ToString("F2", CultureInfo.InvariantCulture);
        while (s.Contains('.') && (s.EndsWith('0') || s.EndsWith('.'))) s = s[..^1];
        return s;
    }

    /// <summary>One line for agents, e.g. "whoosh (swells then fades): sound 0.05–1.1s, peak 0.62s, mid tone, -3 dBFS".</summary>
    public string Summary
    {
        get
        {
            if (Shape == SoundShape.Silent) return "silent";
            var parts = new List<string> { $"{Shape.Json()} ({Shape.Meaning()})" };
            if (Shape == SoundShape.Multiple)
            {
                var peaks = string.Join(", ", Bursts.Take(8).Select(b => Fmt(b.Peak) + "s"));
                parts.Add($"{Bursts.Count} sounds peaking at {peaks}{(Bursts.Count > 8 ? ", …" : "")} — pick one with hit");
            }
            else
            {
                parts.Add($"sound {Fmt(SoundStart)}–{Fmt(SoundEnd)}s, peak {Fmt(Peak)}s");
            }
            if (SoundStart >= 0.08) parts.Add($"near-silent until {Fmt(SoundStart)}s");
            if (Duration - SoundEnd >= 0.3) parts.Add($"silent after {Fmt(SoundEnd)}s");
            parts.Add($"{Tone} tone");
            parts.Add(PeakDB.ToString("F0", CultureInfo.InvariantCulture) + " dBFS");
            return string.Join(", ", parts);
        }
    }

    /// <summary>Where an audio layer must start so that burst <c>hit</c> (1-based, default the main one) peaks at scene
    /// time hitAt: leading silence is skipped and the layer stops after that burst (so other sounds in the file stay
    /// silent).</summary>
    public Placement? PlacementFor(double hitAt, int? hit = null)
    {
        if (BurstFor(hit) is not { } b) return null;
        var trimIn = Math.Max(0, b.Start - 0.01);
        var start = hitAt - (b.Peak - trimIn);
        if (start < 0) { trimIn = Math.Min(b.Peak, trimIn - start); start = 0; }
        var isLast = b.Start >= (Bursts.Count > 0 ? Bursts[^1].Start : 0);
        var stop = isLast ? Math.Min(Duration, Math.Max(b.End, SoundEnd) + 0.05) : Math.Min(Duration, b.End + 0.05);
        double? end = stop >= Duration - 0.01 ? null : start + (stop - trimIn);
        return new Placement(start, trimIn, end, end == null ? 0 : 0.03, start + (b.Peak - trimIn));
    }

    // Cache

    static readonly Lock Gate = new();
    static readonly Dictionary<string, (DateTime? Mtime, SoundProfile Profile)> Cache = [];

    /// <summary>Profile of a file, cached by path and modification date. Files over 60 s are not profiled (null).</summary>
    public static SoundProfile? Cached(string path)
    {
        var full = Expand(path);
        DateTime? mtime = File.Exists(full) ? File.GetLastWriteTimeUtc(full) : null;
        lock (Gate) if (Cache.TryGetValue(full, out var hit) && hit.Mtime == mtime) return hit.Profile;
        SoundProfile p;
        try
        {
            if (AudioAnalysisCache.Source?.Stereo48k(full) is not { } stereo) return null;
            if (stereo.Length / 2.0 / AudioMixer.SampleRate > 60) return null;
            p = FromStereo48k(stereo);
        }
        catch (Exception e) when (e is IOException or InvalidOperationException or ArgumentException or SceneException) { return null; }
        lock (Gate) Cache[full] = (mtime, p);
        return p;
    }

    static string Expand(string path)
    {
        if (path == "~" || path.StartsWith("~/") || path.StartsWith("~\\"))
            path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), path.Length > 2 ? path[2..] : "");
        try { return Path.GetFullPath(path); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return path; }
    }

    // Waveform sheet (drawn by the app: Core has no drawing API)
    //
    // Swift's sheet(_:columns:cellWidth:cellHeight:) is a numbered PNG grid of waveforms (defaults 2 columns, 420×84
    // cells). Per cell (inset 3 px, fill gray 0.16 on a gray 0.1 background): plot = cell inset 34 px left, 6 px right,
    // 16 px bottom, 6 px top; gray 0.28 one-pixel ticks every SheetTickStep seconds; each burst as a band of
    // rgba(0.3, 0.75, 1, 0.18); the waveform mirrored around the plot's middle in rgb(0.45, 0.85, 1), each pixel column
    // WaveformColumns(plotWidth)[c] × plot height / 2 tall each way (skipped when ≤ 0.3 px); the main peak as a 2 px
    // rgb(1, 0.55, 0.1) line; SheetLabel in Helvetica 11 pt, gray 0.85, under the plot; the 1-based number in
    // Helvetica-Bold 15 pt white at the top left. A missing profile reads "no preview (could not download or decode)"
    // (11 pt, gray 0.6).

    /// <summary>Waveform height per pixel column (0…1 on a 48 dB scale, the loudest envelope sample in each column).</summary>
    public double[] WaveformColumns(int columns)
    {
        var output = new double[Math.Max(0, columns)];
        var n = Envelope.Length;
        if (n == 0 || Duration <= 0) return output;
        for (var c = 0; c < columns; c++)
        {
            int a = c * n / columns, b = Math.Max(a + 1, (c + 1) * n / columns);
            float v = 0;
            for (var k = a; k < Math.Min(b, n); k++) v = Math.Max(v, Envelope[k]);
            output[c] = v > 0 ? Math.Max(0, (20 * Math.Log10(v) + 48) / 48) : 0;
        }
        return output;
    }

    /// <summary>Seconds between the sheet's tick lines.</summary>
    public double SheetTickStep => Duration <= 2 ? 0.25 : Duration <= 6 ? 1 : Duration <= 20 ? 2 : 5;

    /// <summary>The sheet's caption, e.g. "1.2s · hit · peak 0.01s · mid".</summary>
    public string SheetLabel => $"{Fmt(Duration)}s · {Shape.Json()} · peak {Fmt(Peak)}s · {Tone}";
}
