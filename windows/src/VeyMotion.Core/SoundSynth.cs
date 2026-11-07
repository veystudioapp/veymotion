using System.Globalization;

namespace VeyMotion.Core;

/// <summary>Built-in sound effects, synthesized (no network, no license): whooshes, pops, clicks, dings, risers,
/// impacts… Each one is made to measure (duration, pitch, direction) and knows exactly where its hit is, so it can be
/// placed on the frame where the picture moves. The same settings always give the same file. JSON names via
/// <c>Json()</c>: whoosh, swoosh, …. Port of <c>SoundSynth.swift</c>.</summary>
public enum SynthKind { Whoosh, Swoosh, Pop, Blip, Click, Tick, Ding, Chime, Sparkle, Riser, Impact, Thud, Drop, Glitch, Typing }

public static class SynthKindExtensions
{
    public static string Title(this SynthKind k) => k.ToString();

    /// <summary>What it sounds like and what it suits (for agents and the UI).</summary>
    public static string Use(this SynthKind k) => k switch
    {
        SynthKind.Whoosh => "air rushing past; slides, zooms, camera moves, big transitions (peaks mid-way)",
        SynthKind.Swoosh => "short fast whoosh; quick cuts, flicks, small elements flying in",
        SynthKind.Pop => "bubbly pop; things scaling in or appearing, bubbles, icons",
        SynthKind.Blip => "rising digital blip; UI elements, toggles, notifications, small reveals",
        SynthKind.Click => "crisp click; buttons, cursor clicks, things snapping into place",
        SynthKind.Tick => "soft high tick; counters, each step of a list, clock ticks (use count)",
        SynthKind.Ding => "bright bell; success, check marks, highlights, key numbers",
        SynthKind.Chime => "three rising bell notes; reveals, achievements, happy endings",
        SynthKind.Sparkle => "glittery shimmer; magic, shine sweeps, stars, premium feel",
        SynthKind.Riser => "build-up that tops out at its end; tension before a reveal or drop (hit = the end)",
        SynthKind.Impact => "deep cinematic hit; title slams, logo landings, big drops",
        SynthKind.Thud => "soft low thump; objects landing, cards dropping, subtle accents",
        SynthKind.Drop => "falling tone; exits, errors, things falling away",
        SynthKind.Glitch => "digital stutter; glitch transitions, tech/error moments",
        _ => "keyboard typing; typewriter text (set duration to the typing time, or count = keystrokes)",
    };

    /// <summary>Default length in seconds.</summary>
    public static double DefaultDuration(this SynthKind k) => k switch
    {
        SynthKind.Whoosh => 0.8,
        SynthKind.Swoosh => 0.35,
        SynthKind.Pop => 0.18,
        SynthKind.Blip => 0.14,
        SynthKind.Click => 0.06,
        SynthKind.Tick => 0.05,
        SynthKind.Ding => 1.6,
        SynthKind.Chime => 1.5,
        SynthKind.Sparkle => 1.0,
        SynthKind.Riser => 2,
        SynthKind.Impact => 1.6,
        SynthKind.Thud => 0.45,
        SynthKind.Drop => 0.7,
        SynthKind.Glitch => 0.45,
        _ => 1.5,
    };

    static readonly (SynthKind Kind, string[] Words)[] Table =
    [
        (SynthKind.Riser, ["riser", "risers", "buildup", "build-up", "uplifter", "tension"]),
        (SynthKind.Whoosh, ["whoosh", "woosh", "swoosh", "swish", "swipe", "swosh", "transition"]),
        (SynthKind.Pop, ["pop", "pops", "bubble", "plop"]),
        (SynthKind.Blip, ["blip", "beep", "notification"]),
        (SynthKind.Click, ["click", "clicks", "button", "snap"]),
        (SynthKind.Tick, ["tick", "ticks", "counter"]),
        (SynthKind.Chime, ["chime", "chimes"]),
        (SynthKind.Ding, ["ding", "bell", "success"]),
        (SynthKind.Sparkle, ["sparkle", "shimmer", "glitter", "magic", "twinkle"]),
        (SynthKind.Impact, ["impact", "boom", "slam", "punch", "hit", "hits"]),
        (SynthKind.Thud, ["thud", "thump", "landing"]),
        (SynthKind.Drop, ["drop", "fall", "falling", "downer"]),
        (SynthKind.Glitch, ["glitch", "glitches", "digital"]),
        (SynthKind.Typing, ["typing", "keyboard", "typewriter", "keystroke"]),
    ];

    /// <summary>The synthesized kind a stock-sound search is looking for, if any ("deep whoosh" → whoosh, "bell" → ding).</summary>
    public static SynthKind? Matching(string query)
    {
        var words = new List<string>();
        var current = new System.Text.StringBuilder();
        foreach (var ch in query.ToLowerInvariant())
        {
            if (char.IsLetter(ch)) { current.Append(ch); continue; }
            if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); }
        }
        if (current.Length > 0) words.Add(current.ToString());
        foreach (var (kind, list) in Table) if (list.Any(words.Contains)) return kind;
        return null;
    }

    /// <summary>Kinds whose length follows duration (others have a natural length and only repeat to fill it).</summary>
    public static bool Stretches(this SynthKind k) =>
        k is SynthKind.Whoosh or SynthKind.Swoosh or SynthKind.Riser or SynthKind.Drop or SynthKind.Glitch or SynthKind.Typing or SynthKind.Sparkle;

    /// <summary>Kinds that can repeat count times over duration.</summary>
    public static bool Repeats(this SynthKind k) =>
        k is SynthKind.Pop or SynthKind.Blip or SynthKind.Click or SynthKind.Tick or SynthKind.Thud or SynthKind.Ding;

    public static double DefaultReverb(this SynthKind k) => k switch
    {
        SynthKind.Ding or SynthKind.Chime => 0.3,
        SynthKind.Impact => 0.25,
        SynthKind.Sparkle => 0.2,
        _ => 0,
    };
}

/// <summary>Settings of a synthesized sound. Duration: seconds (stretching kinds), or the span Count repeats are spread
/// over. Pitch: frequency multiplier, 0.5…2 (lower = bigger/heavier). Variant: different random detail for the same
/// settings. Reverb: 0…1; null = the kind's default. Direction: whoosh/swoosh/riser moves "left" (right → left) or
/// "right" (left → right); null = centered. Count: repeat a short sound this many times over Duration (tick, click,
/// pop, blip, thud, ding); typing keystrokes.</summary>
public record struct SynthSettings(SynthKind Kind, double? Duration = null, double Pitch = 1, int Variant = 0,
    double? Reverb = null, string? Direction = null, int? Count = null)
{
    /// <summary>Stable short hash of the settings (file names: same settings → same file).</summary>
    internal readonly string Key
    {
        get
        {
            var inv = CultureInfo.InvariantCulture;
            var s = string.Join("|", Kind.Json(), Duration?.ToString("F3", inv) ?? "-", Pitch.ToString("F3", inv),
                Variant.ToString(inv), Reverb?.ToString("F2", inv) ?? "-", Direction ?? "-", Count?.ToString(inv) ?? "-");
            var h = Noise.Hash(s);
            return ((uint)(h ^ (h >> 32))).ToString("x8", inv);
        }
    }
}

/// <summary>A generated file. Hits: file seconds of the hit(s), the moment to line up with the picture (first = main one).</summary>
public sealed record SynthResult(string Path, double Duration, IReadOnlyList<double> Hits);

public static class SoundSynth
{
    public const double SampleRate = 48_000.0;
    /// <summary>The asset folder generated sounds go to by default (<c>sfx/</c> in projects).</summary>
    public const string DefaultFolder = "sfx";

    /// <summary>Renders to stereo samples (left, right) and the hit times.</summary>
    public static (float[] Left, float[] Right, List<double> Hits) Render(SynthSettings s)
    {
        var r = new Renderer(s);
        r.Run();
        return (r.Left, r.Right, r.Hits);
    }

    /// <summary>Writes a 16-bit stereo WAV into directory (the caller routes it: the asset library, <c>sfx/</c> in
    /// projects) and returns it. Same settings reuse the same file.</summary>
    public static SynthResult Generate(SynthSettings s, string directory)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, $"{s.Kind.Json()}-{s.Key}.wav");
        var output = Render(s);
        if (!File.Exists(path))
        {
            // Not an atomic temp-file write: that stages the file in the system temp folder, which sandboxed
            // processes cannot use.
            var part = path + ".part";
            File.WriteAllBytes(part, Wav(output.Left, output.Right));
            File.Move(part, path, overwrite: true);
        }
        return new SynthResult(path, output.Left.Length / SampleRate, output.Hits);
    }

    /// <summary>16-bit PCM WAV data (stereo, 48 kHz).</summary>
    public static byte[] Wav(float[] left, float[] right)
    {
        var frames = Math.Min(left.Length, right.Length);
        using var ms = new MemoryStream(44 + frames * 4);
        using var w = new BinaryWriter(ms);
        w.Write("RIFF"u8); w.Write((uint)(36 + frames * 4));
        w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16u); w.Write((ushort)1); w.Write((ushort)2); w.Write((uint)SampleRate); w.Write((uint)SampleRate * 4);
        w.Write((ushort)4); w.Write((ushort)16);
        w.Write("data"u8); w.Write((uint)(frames * 4));
        for (var i = 0; i < frames; i++)
        {
            w.Write((short)(Math.Max(-1, Math.Min(1, left[i])) * 32767));
            w.Write((short)(Math.Max(-1, Math.Min(1, right[i])) * 32767));
        }
        w.Flush();
        return ms.ToArray();
    }

    // DSP

    struct Rng(ulong state)
    {
        ulong _state = state;

        public ulong Next()
        {
            unchecked
            {
                _state += 0x9e3779b97f4a7c15UL;
                var z = _state;
                z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9UL;
                z = (z ^ (z >> 27)) * 0x94d049bb133111ebUL;
                return z ^ (z >> 31);
            }
        }

        public double Unit() => (Next() >> 11) / (double)(1UL << 53);
        public double Noise() => Unit() * 2 - 1;
        public double Range(double a, double b) => a + (b - a) * Unit();
    }

    /// <summary>Topology-preserving state-variable filter (stable at any cutoff).</summary>
    struct Svf
    {
        double _ic1, _ic2;

        public (double Lp, double Bp, double Hp) Run(double x, double cutoff, double q)
        {
            var g = Math.Tan(Math.PI * Math.Min(Math.Max(cutoff, 10), SampleRate * 0.45) / SampleRate);
            var k = 1 / Math.Max(q, 0.1);
            double a1 = 1 / (1 + g * (g + k)), a2 = g * a1, a3 = g * a2;
            var v3 = x - _ic2;
            var v1 = a1 * _ic1 + a2 * v3;
            var v2 = _ic2 + a2 * _ic1 + a3 * v3;
            _ic1 = 2 * v1 - _ic1;
            _ic2 = 2 * v2 - _ic2;
            return (v2, v1, x - k * v1 - v2);
        }
    }

    /// <summary>Small stereo Schroeder reverb.</summary>
    sealed class Reverb
    {
        readonly double[][] _combs, _aps;
        readonly int[] _combPos = new int[4], _apPos = new int[2];
        readonly double[] _combLP = new double[4];

        public Reverb(double offsetMs)
        {
            _combs = new[] { 29.7, 37.1, 41.1, 43.7 }.Select(ms => new double[(int)((ms + offsetMs) * SampleRate / 1000)]).ToArray();
            _aps = new[] { 5.0, 1.7 }.Select(ms => new double[(int)((ms + offsetMs * 0.3) * SampleRate / 1000)]).ToArray();
        }

        public double Run(double x)
        {
            var y = 0.0;
            for (var i = 0; i < _combs.Length; i++)
            {
                var output = _combs[i][_combPos[i]];
                _combLP[i] = output * 0.75 + _combLP[i] * 0.25;
                _combs[i][_combPos[i]] = x + _combLP[i] * 0.8;
                _combPos[i] = (_combPos[i] + 1) % _combs[i].Length;
                y += output;
            }
            y *= 0.25;
            for (var i = 0; i < _aps.Length; i++)
            {
                var buf = _aps[i][_apPos[i]];
                var v = y + buf * 0.6;
                _aps[i][_apPos[i]] = v;
                y = buf - v * 0.6;
                _apPos[i] = (_apPos[i] + 1) % _aps[i].Length;
            }
            return y;
        }
    }

    sealed class Renderer
    {
        readonly SynthSettings _s;
        readonly double _pitch;
        readonly double _length;
        Rng _rng;
        public float[] Left = [];
        public float[] Right = [];
        public readonly List<double> Hits = [];

        public Renderer(SynthSettings s)
        {
            _s = s;
            _pitch = Math.Min(Math.Max(s.Pitch, 0.25), 4);
            _length = Math.Min(Math.Max(s.Duration ?? s.Kind.DefaultDuration(), 0.02), 30);
            var seed = 0x5eedUL;
            foreach (var b in System.Text.Encoding.UTF8.GetBytes($"{s.Kind.Json()}#{s.Variant.ToString(CultureInfo.InvariantCulture)}"))
                seed = unchecked((seed ^ b) * 0x100000001b3UL);
            _rng = new Rng(seed);
        }

        static int N(double seconds) => (int)(seconds * SampleRate);

        /// <summary>Adds a mono voice with a pan (-1…1, per sample) at offset seconds.</summary>
        void Add(double[] mono, double offset, Func<int, double>? pan = null)
        {
            var o = Math.Max(0, N(offset));
            var need = o + mono.Length;
            if (Left.Length < need)
            {
                Array.Resize(ref Left, need);
                Array.Resize(ref Right, need);
            }
            for (var i = 0; i < mono.Length; i++)
            {
                var p = Math.Min(Math.Max(pan?.Invoke(i) ?? 0, -1), 1);
                var angle = (p + 1) * Math.PI / 4;
                Left[o + i] += (float)(mono[i] * Math.Cos(angle) * 1.414);
                Right[o + i] += (float)(mono[i] * Math.Sin(angle) * 1.414);
            }
        }

        public void Run()
        {
            var k = _s.Kind;
            if (k.Repeats() && _s.Count is { } c && c > 1)
            {
                var span = _s.Duration ?? c * 0.12;
                for (var j = 0; j < c; j++)
                {
                    var t = span * j / c;
                    var jitter = 1 + _rng.Range(-0.03, 0.03);
                    One(k, t, _pitch * jitter, j == 0 ? 1 : _rng.Range(0.8, 1));
                }
            }
            else
            {
                One(k, 0, _pitch, 1);
            }
            Hits.Sort();
            Finish();
        }

        void One(SynthKind k, double t0, double p, double gain)
        {
            switch (k)
            {
                case SynthKind.Whoosh: Whoosh(_length, 0.55, 250, 2900, 1.1, 0.35, p); break;
                case SynthKind.Swoosh: Whoosh(_length, 0.42, 700, 6500, 0.8, 0.1, p); break;
                case SynthKind.Riser: Riser(p); break;
                case SynthKind.Drop: Drop(p); break;
                case SynthKind.Glitch: Glitch(p); break;
                case SynthKind.Typing: Typing(p); break;
                case SynthKind.Sparkle: Sparkle(p); break;
                case SynthKind.Chime: Chime(p); break;
                default:
                    var (mono, hit) = ShortSound(k, p);
                    Add(mono.Select(v => v * gain).ToArray(), t0);
                    Hits.Add(t0 + hit);
                    break;
            }
        }

        // Sounds

        void Whoosh(double d, double pk, double low, double high, double q, double rumble, double p)
        {
            var count = N(d);
            Svf bp = new(), lp = new();
            var mono = new double[count];
            for (var i = 0; i < count; i++)
            {
                var u = (double)i / count;
                var env = u < pk ? Math.Pow(Math.Sin(Math.PI / 2 * u / pk), 2.2) : Math.Pow(Math.Cos(Math.PI / 2 * (u - pk) / (1 - pk)), 2.6);
                // Brighter while approaching (a bit of Doppler), darker going away.
                var doppler = u < pk ? 1.0 : 1 - 0.35 * (u - pk) / (1 - pk);
                var cut = p * (low + (high - low) * env) * doppler;
                var x = _rng.Noise();
                var band = bp.Run(x, cut, q).Bp;
                var body = lp.Run(x, 160 * p, 0.7).Lp;
                mono[i] = (band * 1.4 + body * rumble * 2.5) * env;
            }
            var dir = Direction;
            Add(mono, 0, i => dir * ((double)i / count * 2 - 1) * 0.8);
            Hits.Add(d * pk);
        }

        double Direction => _s.Direction?.ToLowerInvariant() switch
        {
            "left" => -1,
            "right" => 1,
            _ => 0,
        };

        void Riser(double p)
        {
            var d = _length;
            var count = N(d);
            var bp = new Svf();
            var mono = new double[count];
            double phase = 0, trem = 0;
            for (var i = 0; i < count; i++)
            {
                var t = i / SampleRate;
                var u = t / d;
                var env = Math.Pow(u, 2.2) * Math.Min(1, (1 - u) * d / 0.012 + 0.02);
                var cut = p * 220 * Math.Pow(36, Math.Pow(u, 1.4));
                var air = bp.Run(_rng.Noise(), cut, 1.6).Bp * 1.6;
                var f = p * 110 * Math.Pow(8, u * u);
                phase += 2 * Math.PI * f / SampleRate;
                trem += 2 * Math.PI * (4 + 14 * u) / SampleRate;
                var tone = (Math.Sin(phase) + 0.3 * Math.Sin(2 * phase)) * (0.75 + 0.25 * Math.Sin(trem)) * 0.35;
                mono[i] = (air + tone) * env;
            }
            var dir = Direction;
            Add(mono, 0, i => dir * ((double)i / count * 2 - 1) * 0.6);
            Hits.Add(d);
        }

        void Drop(double p)
        {
            var d = _length;
            var count = N(d);
            var bp = new Svf();
            var mono = new double[count];
            var phase = 0.0;
            for (var i = 0; i < count; i++)
            {
                var t = i / SampleRate;
                var u = t / d;
                var env = Math.Min(1, t / 0.005) * Math.Pow(1 - u, 1.5);
                var f = p * 900 * Math.Pow(0.08, u);
                phase += 2 * Math.PI * f / SampleRate;
                var noise = bp.Run(_rng.Noise(), f * 2, 2).Bp * 0.5;
                mono[i] = (Math.Sin(phase) * 0.8 + noise) * env;
            }
            Add(mono, 0);
            Hits.Add(0.01);
        }

        void Glitch(double p)
        {
            var d = _length;
            var count = N(d);
            var mono = new double[count];
            var i = 0;
            double[] last = [];
            while (i < count)
            {
                var segLen = Math.Min(count - i, N(_rng.Range(0.015, 0.055)));
                var seg = new double[segLen];
                var kind = _rng.Unit();
                var amp = _rng.Range(0.5, 1);
                if (kind < 0.18)
                {
                    // silence
                }
                else if (kind < 0.35 && last.Length > 0)
                {
                    for (var j = 0; j < segLen; j++) seg[j] = last[j % last.Length]; // stutter
                }
                else if (kind < 0.65)
                {
                    var f = p * _rng.Range(80, 1800);
                    for (var j = 0; j < segLen; j++) seg[j] = (Math.Sin(2 * Math.PI * f * j / SampleRate) >= 0 ? 0.6 : -0.6) * amp;
                }
                else
                {
                    var hold = (int)_rng.Range(4, 40);
                    var v = 0.0;
                    for (var j = 0; j < segLen; j++)
                    {
                        if (j % hold == 0) v = Math.Round(_rng.Noise() * 4, MidpointRounding.AwayFromZero) / 4;
                        seg[j] = v * amp * 0.8;
                    }
                }
                // 2 ms edges so cuts click on purpose but do not crackle.
                var edge = Math.Min(segLen / 2, N(0.002));
                for (var j = 0; j < edge; j++) { var g = (double)j / Math.Max(edge, 1); seg[j] *= g; seg[segLen - 1 - j] *= g; }
                for (var j = 0; j < segLen; j++) mono[i + j] = seg[j];
                if (!seg.All(v => v == 0)) last = seg;
                i += segLen;
            }
            Add(mono, 0, j => Math.Sin(j / SampleRate * 37) * 0.4);
            Hits.Add(0);
        }

        void Typing(double p)
        {
            var d = _length;
            var times = new List<double>();
            if (_s.Count is { } c && c > 0)
            {
                for (var j = 0; j < c; j++) times.Add(d * j / c + (j == 0 ? 0 : _rng.Range(-0.012, 0.012)));
            }
            else
            {
                var t = 0.0;
                while (t < d - 0.04)
                {
                    times.Add(t);
                    t += _rng.Unit() < 0.08 ? _rng.Range(0.2, 0.3) : _rng.Range(0.06, 0.15);
                }
            }
            foreach (var t in times)
            {
                var count = N(0.06);
                var bp = new Svf();
                var f = p * _rng.Range(1800, 3200);
                var thock = p * _rng.Range(150, 220);
                var amp = _rng.Range(0.55, 1);
                var mono = new double[count];
                for (var i = 0; i < count; i++)
                {
                    var tt = i / SampleRate;
                    var click = bp.Run(_rng.Noise(), f, 1.4).Bp * Math.Exp(-tt / 0.006) * 2;
                    var low = Math.Sin(2 * Math.PI * thock * tt) * Math.Exp(-tt / 0.014) * 0.45;
                    mono[i] = (click + low) * amp * Math.Min(1, tt / 0.0005);
                }
                var pan = _rng.Range(-0.25, 0.25);
                Add(mono, Math.Max(0, t), _ => pan);
                Hits.Add(Math.Max(0, t) + 0.001);
            }
        }

        void Sparkle(double p)
        {
            var d = _length;
            var pings = (int)(18 * d) + 4;
            for (var j = 0; j < pings; j++)
            {
                var t = Math.Pow(_rng.Unit(), 1.6) * d * 0.7 + (j == 0 ? 0 : 0.01);
                var at = j == 0 ? 0 : t;
                var f = p * _rng.Range(2600, 8000);
                var decay = _rng.Range(0.04, 0.16);
                var n = N(decay * 5);
                var amp = _rng.Range(0.15, 0.4) * (j == 0 ? 1.6 : 1);
                var ping = new double[n];
                for (var i = 0; i < n; i++)
                {
                    var tt = i / SampleRate;
                    ping[i] = Math.Sin(2 * Math.PI * f * tt) * Math.Exp(-tt / decay) * amp * Math.Min(1, tt / 0.001);
                }
                var pan = _rng.Range(-0.8, 0.8);
                Add(ping, at, _ => pan);
            }
            // A soft airy shimmer under the pings.
            var count = N(d);
            var hp = new Svf();
            var bed = new double[count];
            for (var i = 0; i < count; i++)
            {
                var u = (double)i / count;
                bed[i] = hp.Run(_rng.Noise(), 7000 * p, 0.7).Hp * Math.Sin(Math.PI * Math.Min(1, u * 1.4)) * 0.12;
            }
            Add(bed, 0);
            Hits.Add(0.002);
        }

        void Chime(double p)
        {
            // Rising major arpeggio; the variant picks the root.
            double[] roots = [1046.5, 1174.7, 1318.5, 880.0];
            var root = roots[Math.Abs(_s.Variant) % roots.Length] * p;
            double[] ratios = [1.0, 1.26, 1.5];
            for (var j = 0; j < ratios.Length; j++)
            {
                var (mono, _) = Bell(root * ratios[j], 0.7, _length - j * 0.1);
                var gain = j == 2 ? 1 : 0.8;
                var pan = (j - 1) * 0.3;
                Add(mono.Select(v => v * gain).ToArray(), j * 0.1, _ => pan);
            }
            Hits.Add(0.002);
        }

        static (double[] Mono, double Hit) Bell(double f0, double decay, double d)
        {
            var count = N(Math.Max(0.05, d));
            var mono = new double[count];
            (double R, double A, double Dk)[] partials = [(1, 1, 1), (2.0, 0.45, 0.6), (3.01, 0.22, 0.4), (4.17, 0.14, 0.25), (5.43, 0.08, 0.16)];
            for (var i = 0; i < count; i++)
            {
                var t = i / SampleRate;
                var v = 0.0;
                foreach (var (r, a, dk) in partials) v += Math.Sin(2 * Math.PI * f0 * r * t) * a * Math.Exp(-t / (decay * dk));
                mono[i] = v * 0.45 * Math.Min(1, t / 0.002);
            }
            return (mono, 0.002);
        }

        /// <summary>Fixed-length one-shots. Returns the sound and its hit time.</summary>
        (double[] Mono, double Hit) ShortSound(SynthKind k, double p)
        {
            switch (k)
            {
                case SynthKind.Pop:
                {
                    var count = N(0.18);
                    var phase = 0.0;
                    var hp = new Svf();
                    var mono = new double[count];
                    for (var i = 0; i < count; i++)
                    {
                        var t = i / SampleRate;
                        var f = p * (240 + 760 * Math.Exp(-t / 0.012));
                        phase += 2 * Math.PI * f / SampleRate;
                        var body = Math.Sin(phase) * Math.Exp(-t / 0.035) * (1 - Math.Exp(-t / 0.0012));
                        var click = hp.Run(_rng.Noise(), 2500 * p, 0.7).Hp * Math.Exp(-t / 0.002) * 0.35;
                        mono[i] = body + click;
                    }
                    return (mono, 0.004);
                }
                case SynthKind.Blip:
                {
                    var count = N(0.14);
                    var phase = 0.0;
                    var mono = new double[count];
                    for (var i = 0; i < count; i++)
                    {
                        var t = i / SampleRate;
                        var f = p * 520 * Math.Pow(2.6, Math.Min(1, t / 0.06));
                        phase += 2 * Math.PI * f / SampleRate;
                        mono[i] = (Math.Sin(phase) + 0.25 * Math.Sin(3 * phase)) * 0.7 * Math.Min(1, t / 0.003) * Math.Exp(-Math.Max(0, t - 0.03) / 0.03);
                    }
                    return (mono, 0.03);
                }
                case SynthKind.Click:
                {
                    var count = N(0.06);
                    var bp = new Svf();
                    var mono = new double[count];
                    for (var i = 0; i < count; i++)
                    {
                        var t = i / SampleRate;
                        var noise = bp.Run(_rng.Noise(), 3500 * p, 1.8).Bp * Math.Exp(-t / 0.004) * 2.2;
                        var tone = Math.Sin(2 * Math.PI * 1800 * p * t) * Math.Exp(-t / 0.006) * 0.5;
                        mono[i] = (noise + tone) * Math.Min(1, t / 0.0003);
                    }
                    return (mono, 0.001);
                }
                case SynthKind.Tick:
                {
                    var count = N(0.05);
                    var hp = new Svf();
                    var mono = new double[count];
                    for (var i = 0; i < count; i++)
                    {
                        var t = i / SampleRate;
                        var tone = Math.Sin(2 * Math.PI * 4200 * p * t) * Math.Exp(-t / 0.004) * 0.55;
                        var noise = hp.Run(_rng.Noise(), 6000 * p, 0.7).Hp * Math.Exp(-t / 0.0015) * 0.35;
                        mono[i] = (tone + noise) * Math.Min(1, t / 0.0003);
                    }
                    return (mono, 0.001);
                }
                case SynthKind.Ding:
                    return Bell(1318.5 * p, 1.1, _length);
                case SynthKind.Thud:
                {
                    var count = N(0.45);
                    var phase = 0.0;
                    var lp = new Svf();
                    var mono = new double[count];
                    for (var i = 0; i < count; i++)
                    {
                        var t = i / SampleRate;
                        var f = p * (55 + 70 * Math.Exp(-t / 0.03));
                        phase += 2 * Math.PI * f / SampleRate;
                        var body = Math.Sin(phase) * Math.Exp(-t / 0.12);
                        var knock = lp.Run(_rng.Noise(), 900 * p, 0.8).Lp * Math.Exp(-t / 0.025) * 0.9;
                        mono[i] = Math.Tanh((body + knock) * 1.4) * Math.Min(1, t / 0.001);
                    }
                    return (mono, 0.006);
                }
                default: // impact
                {
                    var count = N(Math.Max(0.6, _length));
                    var phase = 0.0;
                    Svf lp = new(), hp = new();
                    var mono = new double[count];
                    for (var i = 0; i < count; i++)
                    {
                        var t = i / SampleRate;
                        var f = p * (42 + 110 * Math.Exp(-t / 0.045));
                        phase += 2 * Math.PI * f / SampleRate;
                        var sub = Math.Sin(phase) * Math.Exp(-t / 0.5);
                        var x = _rng.Noise();
                        var crunch = lp.Run(x, p * (200 + 2600 * Math.Exp(-t / 0.05)), 0.9).Lp * Math.Exp(-t / 0.09) * 1.2;
                        var snap = hp.Run(x, 3000 * p, 0.7).Hp * Math.Exp(-t / 0.004) * 0.6;
                        mono[i] = Math.Tanh((sub + crunch + snap) * 1.6) * Math.Min(1, t / 0.0008);
                    }
                    return (mono, 0.006);
                }
            }
        }

        // Finish

        void Finish()
        {
            if (Left.Length == 0) { Left = [0]; Right = [0]; return; }
            var amount = Math.Min(Math.Max(_s.Reverb ?? _s.Kind.DefaultReverb(), 0), 1);
            if (amount > 0)
            {
                var tail = N(0.4 + 1.2 * amount);
                Array.Resize(ref Left, Left.Length + tail);
                Array.Resize(ref Right, Right.Length + tail);
                Reverb rl = new(0), rr = new(1.3);
                var wet = 0.5 * amount;
                for (var i = 0; i < Left.Length; i++)
                {
                    double l = Left[i], r = Right[i];
                    Left[i] = (float)(l + rl.Run(l) * wet);
                    Right[i] = (float)(r + rr.Run(r) * wet);
                }
            }
            // Remove DC, normalize to -1 dBFS, fade the very end.
            foreach (var x in new[] { Left, Right })
            {
                float prevIn = 0, prevOut = 0;
                for (var i = 0; i < x.Length; i++)
                {
                    var y = x[i] - prevIn + 0.9995f * prevOut;
                    prevIn = x[i]; prevOut = y; x[i] = y;
                }
            }
            float peak = 0;
            foreach (var v in Left) peak = Math.Max(peak, Math.Abs(v));
            foreach (var v in Right) peak = Math.Max(peak, Math.Abs(v));
            if (peak > 1e-6f)
            {
                var g = 0.89f / peak;
                for (var i = 0; i < Left.Length; i++) { Left[i] *= g; Right[i] *= g; }
            }
            // Trim trailing near-silence, then a 10 ms fade-out.
            const float floor = 0.0005f;
            var end = Left.Length;
            while (end > 1 && Math.Abs(Left[end - 1]) < floor && Math.Abs(Right[end - 1]) < floor) end--;
            end = Math.Min(Left.Length, end + N(0.01));
            Array.Resize(ref Left, end);
            Array.Resize(ref Right, end);
            var fade = Math.Min(Left.Length, N(0.01));
            for (var j = 0; j < fade; j++)
            {
                var g = (float)j / Math.Max(fade, 1);
                Left[^(1 + j)] *= g;
                Right[^(1 + j)] *= g;
            }
        }
    }
}
