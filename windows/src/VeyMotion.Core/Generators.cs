using System.Numerics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

// Generator layers draw procedural content in their width × height box, like After Effects' Generate effects: an audio
// spectrum or waveform, fractal noise, lightning, grids, charts and lens flares. Port of Generators.swift.

public enum GeneratorKind { Spectrum, Waveform, Noise, Lightning, Grid, Chart, Flare }

public enum ChartType { Bar, Line, Area, Pie, Donut }

/// <summary>How spectrum and waveform values are drawn.</summary>
public enum GeneratorShape { Bars, Line, Circle }

public sealed class Generator
{
    public GeneratorKind Kind = GeneratorKind.Spectrum;
    /// <summary>spectrum/waveform: audio layer id (null = the music layer, else the first audio layer).</summary>
    public string? Source;
    public GeneratorShape? Shape;
    public int? Count;
    public bool? Mirror;
    public double? Gain, Window, Scale;
    public int? Detail;
    public double? Speed;
    public List<Rgba>? Colors;
    /// <summary>lightning/flare: points in layer px from the layer's position.</summary>
    public PathPoint? From, To;
    public long? Seed;
    public List<double>? Values;
    public List<string>? Labels;
    public ChartType? Chart;
    /// <summary>The audio source as resolved by the scene (not saved).</summary>
    public AudioLink? Link;

    // Values with their per-kind defaults

    public bool UsesAudio => Kind is GeneratorKind.Spectrum or GeneratorKind.Waveform;
    public GeneratorShape ShapeValue => Shape ?? GeneratorShape.Bars;
    public int CountValue => Count ?? (Kind == GeneratorKind.Waveform ? 64 : 48);
    public bool MirrorValue => Mirror ?? Kind == GeneratorKind.Waveform;
    public double GainValue => Gain ?? 1;
    public double WindowValue => Window ?? 4;
    public double ScaleValue => Scale ?? Kind switch { GeneratorKind.Noise => 200, GeneratorKind.Grid => 80, _ => 40 };
    /// <summary>lightning: how far the bolt strays, by default 15% of its length.</summary>
    public double Spread(double length) => Scale ?? 0.15 * length;
    public int DetailValue => Detail ?? (Kind == GeneratorKind.Lightning ? 2 : 4);
    public double SpeedValue => Speed ?? Kind switch { GeneratorKind.Noise => 0.3, GeneratorKind.Lightning => 12, _ => 0 };
    public List<Rgba> ColorsValue => Colors ?? [new Rgba(0, 0, 0, 1), Rgba.White];
    public long SeedValue => Seed ?? 0;
    public ChartType ChartValue => Chart ?? ChartType.Bar;
    public List<double> ValuesValue => Values ?? [3, 5, 2, 8, 6];

    /// <summary>Also accepts a bare kind ("noise").</summary>
    internal static Generator Decode(JsonNode? n, string path)
    {
        if (n is JsonValue v && v.GetValueKind() == JsonValueKind.String)
        {
            var s = v.GetValue<string>();
            return new Generator
            {
                Kind = JsonName<GeneratorKind>.Parse(s) ?? throw Reader.Fail(path, $"Cannot initialize GeneratorKind from invalid String value {s}"),
            };
        }
        var r = Reader.Of(n, path);
        return new Generator
        {
            Kind = r.Enum<GeneratorKind>("kind") ?? GeneratorKind.Spectrum,
            Source = r.Str("source") is { Length: > 0 } src ? src : null,
            Shape = r.Enum<GeneratorShape>("shape"),
            Count = r.Int("count") is { } c ? Math.Clamp(c, 1, 512) : null,
            Mirror = r.Bool("mirror"),
            Gain = r.Num("gain"),
            Window = r.Num("window") is { } w ? Math.Max(w, 0.1) : null,
            Scale = r.Num("scale") is { } sc ? Math.Max(sc, 1) : null,
            Detail = r.Int("detail") is { } d ? Math.Clamp(d, 0, 8) : null,
            Speed = r.Num("speed"),
            Colors = r.List("colors", Reader.ReadColor) is { Count: > 0 } cols ? cols : null,
            From = r.Has("from") ? LayerCodec.ReadPoint(r.Obj["from"], path + ".from") : null,
            To = r.Has("to") ? LayerCodec.ReadPoint(r.Obj["to"], path + ".to") : null,
            Seed = r.Num("seed") is { } seed ? (long)seed : null,
            Values = r.List("values", Reader.ReadNum) is { Count: > 0 } vals ? vals : null,
            Labels = r.List("labels", (ln, lp) => ln is JsonValue lv && lv.GetValueKind() == JsonValueKind.String
                ? lv.GetValue<string>() : throw Reader.Fail(lp, "Expected to decode String")) is { Count: > 0 } labels ? labels : null,
            Chart = r.Enum<ChartType>("chart"),
        };
    }

    internal JsonObject Encode()
    {
        var o = new JsonObject { ["kind"] = Kind.Json() };
        if (Source != null) o["source"] = Source;
        if (Shape is { } shape) o["shape"] = shape.Json();
        if (Count is { } count) o["count"] = count;
        if (Mirror is { } mirror) o["mirror"] = mirror;
        if (Gain is { } gain) o["gain"] = gain;
        if (Window is { } window) o["window"] = window;
        if (Scale is { } scale) o["scale"] = scale;
        if (Detail is { } detail) o["detail"] = detail;
        if (Speed is { } speed) o["speed"] = speed;
        if (Colors != null) o["colors"] = new JsonArray(Colors.Select(c => (JsonNode)c.Hex).ToArray());
        if (From is { } from) o["from"] = new JsonArray(from.X, from.Y);
        if (To is { } to) o["to"] = new JsonArray(to.X, to.Y);
        if (Seed is { } seed) o["seed"] = seed;
        if (Values != null) o["values"] = new JsonArray(Values.Select(x => (JsonNode)x).ToArray());
        if (Labels != null) o["labels"] = new JsonArray(Labels.Select(x => (JsonNode)x).ToArray());
        if (Chart is { } chart) o["chart"] = chart.Json();
        return o;
    }

    /// <summary>spectrum/waveform values (0…1, before gain) at scene time t; zeros while the audio is silent or not
    /// analyzed yet.</summary>
    public double[] AudioValues(double t)
    {
        var n = CountValue;
        if (Link == null || AudioAnalysisCache.Analysis(Link.Path) is not { } a) return new double[n];
        if (Kind == GeneratorKind.Spectrum)
            return Link.FileTime(t) is { } ft ? a.SpectrumAt(ft, n) : new double[n];
        // The last window seconds of loudness, newest on the right.
        if (AudioAnalysisCache.Envelope(Link.Path, AudioBand.Level, 0.05) is not { } env) return new double[n];
        var w = WindowValue;
        return Enumerable.Range(0, n).Select(i => Link.FileTime(t - w + w * (i + 0.5) / n) is { } ft2 ? AudioAnalysis.Sample(env, ft2) : 0).ToArray();
    }

    /// <summary>Lightning: the main bolt and its branches as polylines (layer px), with their stroke widths.</summary>
    public List<(List<Vector2> Points, double Width)> Lightning(double boxX, double boxY, double boxW, double boxH, double t,
        double line, ulong salt)
    {
        var a = From is { } f ? new Vector2((float)f.X, (float)f.Y) : new Vector2((float)boxX, (float)(boxY + boxH / 2));
        var b = To is { } to ? new Vector2((float)to.X, (float)to.Y) : new Vector2((float)(boxX + boxW), (float)(boxY + boxH / 2));
        var strike = SpeedValue > 0 ? (long)Math.Floor(t * SpeedValue + 1e-6) : 0;
        var rng = Noise.Mix(salt ^ unchecked((ulong)SeedValue) ^ unchecked((ulong)strike * 0x9E3779B97F4A7C15UL));
        var k = 0;
        double Rand() => Noise.Unit(++k, rng);
        // Midpoint displacement: each split moves the middle sideways by up to spread, halving each level.
        List<Vector2> Bolt(Vector2 p, Vector2 q, double spread, int levels)
        {
            var pts = new List<Vector2> { p, q };
            var s = spread;
            for (var level = 0; level < levels; level++)
            {
                var next = new List<Vector2> { pts[0] };
                for (var i = 0; i < pts.Count - 1; i++)
                {
                    Vector2 u = pts[i], v = pts[i + 1];
                    double dx = v.X - u.X, dy = v.Y - u.Y, len = Math.Max(Math.Sqrt(dx * dx + dy * dy), 1e-6);
                    var off = (Rand() * 2 - 1) * s;
                    next.Add(new Vector2((float)((u.X + v.X) / 2 - dy / len * off), (float)((u.Y + v.Y) / 2 + dx / len * off)));
                    next.Add(v);
                }
                pts = next;
                s /= 2;
            }
            return pts;
        }
        var total = Vector2.Distance(a, b);
        var spread = Spread(total);
        var main = Bolt(a, b, spread, 6);
        var output = new List<(List<Vector2>, double)> { (main, line) };
        // Branches leave from random points of the bolt and fork away from it, thinner and shorter.
        for (var n = 0; n < DetailValue; n++)
        {
            var i = 1 + (int)(Rand() * (main.Count - 2));
            var p = main[Math.Min(i, main.Count - 1)];
            double side = Rand() < 0.5 ? -1 : 1;
            var dir = Math.Atan2(b.Y - a.Y, b.X - a.X) + side * (0.3 + Rand() * 0.6);
            var len = total * (0.15 + Rand() * 0.25);
            var q = new Vector2((float)(p.X + Math.Cos(dir) * len), (float)(p.Y + Math.Sin(dir) * len));
            output.Add((Bolt(p, q, spread * 0.5, 4), Math.Max(0.5, line * 0.45)));
        }
        return output;
    }

    /// <summary>Fractal noise over the box as premultiplied BGRA pixels, w × h samples (smooth, drawn scaled up).</summary>
    public byte[] NoisePixels(int w, int h, double boxX, double boxY, double boxW, double boxH, double t, string layerId)
    {
        var data = new byte[w * h * 4];
        var seed = Noise.Hash(layerId) ^ Noise.Mix(unchecked((ulong)SeedValue));
        var octaves = Math.Max(1, DetailValue);
        var z = t * SpeedValue;
        var cols = ColorsValue;
        // Gradient lookup table (premultiplied BGRA) over 256 levels.
        var lut = new byte[256 * 4];
        for (var i = 0; i < 256; i++)
        {
            var x = i / 255.0 * Math.Max(cols.Count - 1, 0);
            var j = Math.Min((int)x, Math.Max(cols.Count - 2, 0));
            var c = cols.Count == 1 ? cols[0] : Rgba.Lerp(cols[j], cols[Math.Min(j + 1, cols.Count - 1)], x - j);
            lut[4 * i + PixelBuffer.R] = (byte)PixelBuffer.Round(c.R * c.A * 255);
            lut[4 * i + PixelBuffer.G] = (byte)PixelBuffer.Round(c.G * c.A * 255);
            lut[4 * i + PixelBuffer.B] = (byte)PixelBuffer.Round(c.B * c.A * 255);
            lut[4 * i + PixelBuffer.A] = (byte)PixelBuffer.Round(c.A * 255);
        }
        double sx = boxW / w, sy = boxH / h, size = ScaleValue;
        var rot = Enumerable.Range(0, octaves).Select(o => { var a = 0.52 + o * 1.13; return (Math.Cos(a), Math.Sin(a)); }).ToArray();
        Parallel.For(0, h, y =>
        {
            // Row 0 is the top of the image (the box's minY in layer space, y down).
            var ly = boxY + (y + 0.5) * sy;
            for (var x = 0; x < w; x++)
            {
                var lx = boxX + (x + 0.5) * sx;
                double v = 0, amp = 1, freq = 1 / size, norm = 0;
                for (var o = 0; o < octaves; o++)
                {
                    // Each octave turned another way, so the lattice of value noise does not show as squares.
                    var (ca, sa) = rot[o];
                    double px = (lx * ca - ly * sa) * freq, py = (lx * sa + ly * ca) * freq;
                    v += amp * Noise.Value3(px, py, z + o * 7.3, unchecked(seed + (ulong)o)).V;
                    norm += amp;
                    amp *= 0.5; freq *= 2;
                }
                // Value noise sits near 0; spread it to use the whole color range.
                var u = Math.Clamp(0.5 + 0.9 * v / norm, 0, 1);
                var li = 4 * (int)(u * 255);
                var q = (y * w + x) * 4;
                data[q] = lut[li]; data[q + 1] = lut[li + 1]; data[q + 2] = lut[li + 2]; data[q + 3] = lut[li + 3];
            }
        });
        return data;
    }
}
