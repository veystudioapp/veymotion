using System.Globalization;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

public enum TextUnit { Char, Word, Line }

public enum StaggerOrder { Forward, Reverse, Center, Edges, Random }

public enum AnimatorMode
{
    /// <summary>Units arrive from the "away" state to their normal state.</summary>
    In,
    /// <summary>Units leave from their normal state to the "away" state.</summary>
    Out,
}

/// <summary>
/// Animates each character, word or line of a text layer separately, one after another. The opacity/x/y/scale/
/// rotation/blur/color fields describe the "away" state; units animate between it and their normal look.
/// Port of <c>TextAnimator</c> in <c>Motion.swift</c>.
/// </summary>
public sealed record TextAnimator
{
    public TextUnit Unit { get; init; } = TextUnit.Char;
    public AnimatorMode Mode { get; init; } = AnimatorMode.In;
    /// <summary>Scene time when the first unit starts.</summary>
    public double Start { get; init; }
    /// <summary>Seconds each unit takes.</summary>
    public double Duration { get; init; } = 0.5;
    /// <summary>Seconds between the starts of consecutive units.</summary>
    public double Stagger { get; init; } = 0.04;
    public StaggerOrder Order { get; init; } = StaggerOrder.Forward;
    Easing? _easing;
    /// <summary>Defaults to easeOut for "in", easeIn for "out".</summary>
    public Easing Easing { get => _easing ?? (Mode == AnimatorMode.In ? Easing.EaseOut : Easing.EaseIn); init => _easing = value; }
    public double Opacity { get; init; }
    /// <summary>Offset in px (y down).</summary>
    public double X { get; init; }
    public double Y { get; init; }
    public double Scale { get; init; } = 1;
    /// <summary>Degrees.</summary>
    public double Rotation { get; init; }
    public double Blur { get; init; }
    /// <summary>Color of the away state (null = the text's own).</summary>
    public Rgba? Color { get; init; }
    public long Seed { get; init; }

    /// <summary>When the last unit finishes.</summary>
    public double End(int unitCount) => Start + Stagger * Math.Max(unitCount - 1, 0) + Duration;

    /// <summary>Position of each of n units in the stagger sequence (0 = first to move).</summary>
    public double[] Ranks(int n)
    {
        var mid = (n - 1) / 2.0;
        var r = new double[n];
        switch (Order)
        {
            case StaggerOrder.Forward: for (var i = 0; i < n; i++) r[i] = i; break;
            case StaggerOrder.Reverse: for (var i = 0; i < n; i++) r[i] = n - 1 - i; break;
            case StaggerOrder.Center: for (var i = 0; i < n; i++) r[i] = Math.Abs(i - mid); break;
            case StaggerOrder.Edges: for (var i = 0; i < n; i++) r[i] = mid - Math.Abs(i - mid); break;
            case StaggerOrder.Random:
                var seed = Noise.Mix(unchecked((ulong)Seed + 77));
                var shuffled = Enumerable.Range(0, n).OrderBy(i => Noise.Unit(i, seed)).ToList();
                for (var rank = 0; rank < n; rank++) r[shuffled[rank]] = rank;
                break;
        }
        return r;
    }

    /// <summary>0 = unit at rest, 1 = fully away (can overshoot with back/elastic/spring easings).</summary>
    public double Away(double rank, double t)
    {
        var begin = Start + rank * Stagger;
        var p = Math.Clamp((t - begin) / Math.Max(Duration, 0.001), 0, 1);
        var e = Easing.Apply(p);
        return Mode == AnimatorMode.In ? 1 - e : e;
    }

    internal static TextAnimator Decode(JsonNode? n, string path)
    {
        var r = Reader.Of(n, path);
        Easing? easing = null;
        if (r.Str("easing") is { } e)
            easing = Easing.Parse(e) ?? throw Reader.Fail(path + ".easing", $"Unknown easing '{e}'. {Easing.ParseHelp}");
        var a = new TextAnimator
        {
            Unit = r.Enum<TextUnit>("unit") ?? TextUnit.Char,
            Mode = r.Enum<AnimatorMode>("mode") ?? AnimatorMode.In,
            Start = r.Num("start") ?? 0,
            Duration = Math.Max(0.001, r.Num("duration") ?? 0.5),
            Stagger = Math.Max(0, r.Num("stagger") ?? 0.04),
            Order = r.Enum<StaggerOrder>("order") ?? StaggerOrder.Forward,
            Opacity = r.Num("opacity") ?? 0,
            X = r.Num("x") ?? 0,
            Y = r.Num("y") ?? 0,
            Scale = r.Num("scale") ?? 1,
            Rotation = r.Num("rotation") ?? 0,
            Blur = Math.Max(0, r.Num("blur") ?? 0),
            Color = r.Color("color"),
            Seed = (long)(r.Num("seed") ?? 0),
        };
        return easing is { } ez ? a with { Easing = ez } : a;
    }

    internal JsonObject Encode()
    {
        var o = new JsonObject
        {
            ["unit"] = Unit.Json(), ["mode"] = Mode.Json(), ["start"] = Start, ["duration"] = Duration, ["stagger"] = Stagger,
        };
        if (Order != StaggerOrder.Forward) o["order"] = Order.Json();
        o["easing"] = Easing.ToString();
        if (Opacity != 0) o["opacity"] = Opacity;
        if (X != 0) o["x"] = X;
        if (Y != 0) o["y"] = Y;
        if (Scale != 1) o["scale"] = Scale;
        if (Rotation != 0) o["rotation"] = Rotation;
        if (Blur != 0) o["blur"] = Blur;
        if (Color is { } c) o["color"] = c.Hex;
        if (Seed != 0) o["seed"] = Seed;
        return o;
    }
}

/// <summary>Visual state of one character/word/line, combined from all animators.</summary>
public record struct GlyphState(double Opacity = 1, double Dx = 0, double Dy = 0, double Scale = 1, double Rotation = 0,
    double Blur = 0, Rgba? Tint = null)
{
    public GlyphState() : this(1) { }

    public static GlyphState Rest => new();
    public readonly bool IsRest => this == Rest;

    /// <summary>Adds another unit's state on top (a glyph's char, word and line states).</summary>
    public void Combine(GlyphState b)
    {
        Opacity *= b.Opacity;
        Dx += b.Dx;
        Dy += b.Dy;
        Scale *= b.Scale;
        Rotation += b.Rotation;
        Blur += b.Blur;
        if (b.Tint is { } t) Tint = Tint is { } a ? Rgba.Lerp(a, t, 0.5) : t;
    }
}

public static class TextUnits
{
    /// <summary>Unit index for each UTF-16 offset of <paramref name="text"/> (-1 for whitespace), and the number of
    /// units. Line counts hard line breaks; the renderer uses laid-out lines instead.</summary>
    public static (int[] Indices, int Count) Map(string text, TextUnit unit)
    {
        var output = new int[text.Length];
        int count = 0, line = 0, at = 0;
        var inWord = false;
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext())
        {
            var element = (string)e.Current;
            var ws = element.All(char.IsWhiteSpace);
            var idx = -1;
            switch (unit)
            {
                case TextUnit.Char:
                    if (!ws) idx = count++;
                    break;
                case TextUnit.Word:
                    if (!ws)
                    {
                        if (!inWord) { count++; inWord = true; }
                        idx = count - 1;
                    }
                    else inWord = false;
                    break;
                case TextUnit.Line:
                    if (element.Any(c => c is '\n' or '\r' or '\v' or '\f' or '\u0085' or (char)0x2028 or (char)0x2029)) line++;
                    else if (!ws) { idx = line; count = line + 1; }
                    break;
            }
            for (var k = 0; k < element.Length; k++) output[at + k] = idx;
            at += element.Length;
        }
        return (output, count);
    }

    /// <summary>Combined state of each of n units (for the animators that use <paramref name="unit"/>) at time t.</summary>
    public static GlyphState[] GlyphStates(this MotionLayer l, TextUnit unit, int n, double t)
    {
        var states = new GlyphState[n];
        Array.Fill(states, GlyphState.Rest);
        foreach (var a in l.TextAnimators)
        {
            if (a.Unit != unit) continue;
            var ranks = a.Ranks(n);
            for (var i = 0; i < n; i++)
            {
                var k = a.Away(ranks[i], t);
                ref var s = ref states[i];
                s.Opacity *= Math.Clamp(1 + (a.Opacity - 1) * k, 0, 1);
                s.Dx += a.X * k;
                s.Dy += a.Y * k;
                s.Scale *= 1 + (a.Scale - 1) * k;
                s.Rotation += a.Rotation * k;
                s.Blur += a.Blur * k;
                if (a.Color is { } c && k > 0.001)
                {
                    var mixed = c with { A = c.A * Math.Min(k, 1) };
                    s.Tint = s.Tint is { } old ? Rgba.Lerp(old, mixed, 0.5) : mixed;
                }
            }
        }
        return states;
    }
}
