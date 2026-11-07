using System.Globalization;
using System.Text;

namespace VeyMotion.Core;

// Captions from word timings, transcription results and the TTS timing fallback.
// Port of the caption part of Audio.swift, the scene part of Transcribe.swift and VoiceSynth.estimateTimings (Voice.swift).

public sealed class CaptionStyle
{
    public double FontSize = 46;
    public double? Y;
    public Rgba Color = Rgba.White;
    public int MaxChars = 42;
    public bool Background = true;
}

/// <summary>One caption as created by AddCaptions: its number (for SetCaptionTexts), layer id, scene times and text.</summary>
public sealed record CaptionLine(int Number, string Id, double Start, double End, string Text);

/// <summary>What speech recognition gives back (the recognizer itself is not part of Core).</summary>
/// <param name="Text">The recognized text, with punctuation where the recognizer adds it.</param>
/// <param name="Words">Word timings in file seconds (with durations).</param>
/// <param name="Language">Locale used, e.g. "en-US".</param>
/// <param name="OnDevice">True when recognition ran on this machine; false when it went through a server.</param>
public sealed record TranscriptionResult(string Text, List<WordTiming> Words, string Language, bool OnDevice);

public static class CaptionOps
{
    /// <summary>Turns the word timings of a voice-over or a transcribed audio/video layer into caption text layers
    /// (ids "cap-&lt;layer&gt;-&lt;n&gt;"). Replaces existing captions for that layer.</summary>
    public static List<CaptionLine> AddCaptions(this MotionScene s, string id, CaptionStyle? style = null)
    {
        style ??= new CaptionStyle();
        var source = s.Layer(id);
        if (source.Type is not (LayerType.Audio or LayerType.Video))
            throw new SceneException($"'{id}' is not an audio or video layer");
        if (source.Words is not { Count: > 0 } words)
            throw new SceneException($"'{id}' has no word timings: generate a voice-over, or transcribe the layer first");
        var prefix = $"cap-{id}-";
        var rate = source.Type == LayerType.Video ? source.Speed : 1;
        var sourceEnd = source.EffectiveEnd(s.Duration);
        double SceneTime(double fileTime) => source.Start + (fileTime - source.TrimIn) / rate;

        // Group words into readable chunks: break at sentence ends, at pauses, or when the line gets long.
        var chunks = new List<List<WordTiming>>();
        var cur = new List<WordTiming>();
        var chars = 0;
        foreach (var w in words)
        {
            if (!(SceneTime(w.T) >= source.Start - 0.01 && SceneTime(w.T) < sourceEnd)) continue;
            var len = Length(w.Text);
            if (cur.Count > 0)
            {
                var prev = cur[^1];
                var pause = prev.D is { } pd && SceneTime(w.T) - SceneTime(prev.T + pd) > 0.7;
                if (pause || chars + len + 1 > style.MaxChars) { chunks.Add(cur); cur = []; chars = 0; }
            }
            cur.Add(w);
            chars += len + 1;
            if (w.Text.Length > 0 && ".!?…。！？".Contains(w.Text[^1])) { chunks.Add(cur); cur = []; chars = 0; }
        }
        if (cur.Count > 0) chunks.Add(cur);

        var lines = new List<CaptionLine>();
        for (var n = 0; n < chunks.Count; n++)
        {
            var chunk = chunks[n];
            if (chunk.Count == 0) continue;
            WordTiming first = chunk[0], last = chunk[^1];
            var start = SceneTime(first.T);
            var next = n + 1 < chunks.Count ? SceneTime(chunks[n + 1][0].T) : sourceEnd;
            var end = n + 1 < chunks.Count ? next : Math.Min(sourceEnd, SceneTime(last.T) + 0.8);
            if (last.D is { } d)
            {
                // Leave shortly after the last word is spoken, but give short lines time to be read.
                end = Math.Min(next, Math.Max(SceneTime(last.T + d) + 0.5, start + 1));
            }
            lines.Add(new CaptionLine(n + 1, $"{prefix}{n + 1}", start, Math.Max(end, start + 0.3),
                JoinWords(chunk.Select(x => x.Text))));
        }

        // Replace the old captions in one assignment.
        var all = s.Layers.Where(l => !l.Id.StartsWith(prefix, StringComparison.Ordinal)).ToList();
        var y = style.Y ?? s.Height - 110.0;
        if (style.Background)
        {
            // One bar per run of back-to-back captions, so no empty bar stays up during long pauses.
            var runs = new List<(double Start, double End)>();
            foreach (var l in lines)
            {
                if (runs.Count > 0 && l.Start - runs[^1].End < 0.3) runs[^1] = (runs[^1].Start, Math.Max(runs[^1].End, l.End));
                else runs.Add((l.Start, l.End));
            }
            for (var k = 0; k < runs.Count; k++)
            {
                all.Add(new MotionLayer(LayerType.Rect, prefix + (k == 0 ? "bg" : $"bg{k + 1}"), "Caption background", s.Width / 2.0, y)
                {
                    Width = Math.Min(s.Width - 160.0, style.MaxChars * style.FontSize * 0.55 + 80),
                    Height = style.FontSize * 1.9,
                    CornerRadius = 14.0,
                    Fill = new Rgba(0, 0, 0, 0.55),
                    Start = runs[k].Start,
                    End = runs[k].End,
                });
            }
        }
        foreach (var l in lines)
        {
            all.Add(new MotionLayer(LayerType.Text, l.Id, $"Caption {l.Number}", s.Width / 2.0, y)
            {
                Text = l.Text,
                FontSize = style.FontSize,
                FontWeight = "semibold",
                Color = style.Color,
                MaxWidth = s.Width - 240.0,
                Start = l.Start,
                End = l.End,
            });
        }
        s.Layers = all;
        return lines;
    }

    /// <summary>Replaces the text of captions number from, from + 1, … of a layer (numbers as listed by AddCaptions),
    /// e.g. with a translation. Timing and style stay. Nothing changes if one is missing.</summary>
    public static void SetCaptionTexts(this MotionScene s, string id, int from, IReadOnlyList<string> texts)
    {
        var targets = new List<MotionLayer>();
        for (var k = 0; k < texts.Count; k++)
        {
            var cid = $"cap-{id}-{from + k}";
            targets.Add(s.Layers.FirstOrDefault(l => l.Id == cid)
                ?? throw new SceneException($"No caption '{cid}' (add_captions lists the caption numbers of '{id}')"));
        }
        for (var k = 0; k < texts.Count; k++) targets[k].Text = texts[k];
    }

    /// <summary>The caption layers of an audio/video layer, in order.</summary>
    public static List<CaptionLine> Captions(this MotionScene s, string id)
    {
        var prefix = $"cap-{id}-";
        return s.Layers
            .Where(l => l.Type == LayerType.Text && l.Id.StartsWith(prefix, StringComparison.Ordinal))
            .Select(l => int.TryParse(l.Id.AsSpan(prefix.Length), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n)
                ? new CaptionLine(n, l.Id, l.Start, l.EffectiveEnd(s.Duration), l.Text) : null)
            .OfType<CaptionLine>()
            .OrderBy(c => c.Number)
            .ToList();
    }

    /// <summary>Joins recognized words with spaces, except between Chinese / Japanese characters.</summary>
    public static string JoinWords(IEnumerable<string> words)
    {
        static bool IsCJK(Rune? r)
        {
            if (r is not { } rune) return false;
            var v = rune.Value;
            return v is (>= 0x3040 and <= 0x30FF) or (>= 0x3400 and <= 0x9FFF) or (>= 0xFF00 and <= 0xFFEF) or (>= 0x3000 and <= 0x303F);
        }
        var out_ = new StringBuilder();
        foreach (var w in words)
        {
            if (out_.Length > 0 && !(IsCJK(FirstRuneOfLastElement(out_.ToString())) && IsCJK(FirstRune(w)))) out_.Append(' ');
            out_.Append(w);
        }
        return out_.ToString();
    }

    static Rune? FirstRune(string s) => s.Length > 0 && Rune.TryGetRuneAt(s, 0, out var r) ? r : null;

    static Rune? FirstRuneOfLastElement(string s)
    {
        if (s.Length == 0) return null;
        var starts = StringInfo.ParseCombiningCharacters(s);
        return Rune.TryGetRuneAt(s, starts[^1], out var r) ? r : null;
    }

    /// <summary>Characters as a reader counts them (grapheme clusters, like Swift's String.count).</summary>
    static int Length(string s) => new StringInfo(s).LengthInTextElements;

    /// <summary>The part of the source file a layer plays: file start and length (null = to the end of the file).</summary>
    public static (double From, double? Duration) PlayedSourceRange(this MotionLayer l, double sceneDuration)
    {
        var rate = l.Type == LayerType.Video ? l.Speed : 1;
        var len = (l.EffectiveEnd(sceneDuration) - l.Start) * rate;
        // Looping videos replay the same source; anything else stops at the end of the file.
        return (l.TrimIn, l.Type == LayerType.Video && l.Playback == VideoPlayback.Loop ? null : Math.Max(0, len));
    }

    /// <summary>Stores a transcription on an audio or video layer (transcript + words), so AddCaptions can use it.</summary>
    public static void SetTranscription(this MotionScene s, string id, TranscriptionResult result)
    {
        var l = s.Layers[s.LayerIndex(id)];
        if (l.Type is not (LayerType.Audio or LayerType.Video))
            throw new SceneException($"'{id}' is not an audio or video layer");
        l.Transcript = result.Text;
        l.Words = result.Words;
    }

    /// <summary>Fallback when a speech engine gives no word timings: spreads words over the duration in proportion to
    /// their length (pauses at punctuation). Port of <c>VoiceSynth.estimateTimings</c>.</summary>
    public static List<WordTiming> EstimateTimings(string text, double duration)
    {
        var tokens = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (tokens.Length == 0) return [];
        var weights = tokens.Select(w =>
        {
            double x = Length(w) + 1;
            if (",;:".Contains(w[^1])) x += 3;
            if (".!?".Contains(w[^1])) x += 6;
            return x;
        }).ToList();
        var total = weights.Sum();
        var t = 0.0;
        var result = new List<WordTiming>();
        for (var i = 0; i < tokens.Length; i++)
        {
            result.Add(new WordTiming(t, tokens[i]));
            t += duration * weights[i] / total;
        }
        return result;
    }

    // MCP replies (match MCPServer.swift add_captions / list_captions / set_caption_texts / transcribe)

    /// <summary>"3 [12.40–15.10] text" per caption.</summary>
    public static string CaptionList(IEnumerable<CaptionLine> lines) =>
        string.Join("\n", lines.Select(l => string.Format(CultureInfo.InvariantCulture, "{0} [{1:F2}–{2:F2}] ", l.Number, l.Start, l.End) + l.Text));

    /// <summary>Applies the add_captions arguments the MCP tool reads (maxChars is at least 10).</summary>
    public static CaptionStyle Style(double? fontSize, double? y, string? colorHex, double? maxChars, bool? background)
    {
        var style = new CaptionStyle();
        if (fontSize is { } f) style.FontSize = f;
        if (y is { } yy) style.Y = yy;
        if (colorHex != null && Rgba.FromHex(colorHex) is { } c) style.Color = c;
        if (maxChars is { } m) style.MaxChars = Math.Max(10, (int)m);
        if (background is { } b) style.Background = b;
        return style;
    }

    public static string AddCaptionsReply(string id, IReadOnlyCollection<CaptionLine> lines) =>
        $"Added {lines.Count} captions for '{id}' (layers cap-{id}-<number>):\n" + CaptionList(lines);

    public static string ListCaptionsReply(string id, IReadOnlyCollection<CaptionLine> lines) =>
        lines.Count == 0 ? $"'{id}' has no captions (add_captions makes them)." : CaptionList(lines);

    public const string TextsError = "`texts` must be a non-empty array of strings";

    /// <summary>set_caption_texts reads `from` as max(1, Int(from ?? 1)).</summary>
    public static int CaptionFrom(double? from) => Math.Max(1, (int)(from ?? 1));

    public static string SetCaptionTextsReply(string id, int from, int count) =>
        $"Set captions {from}–{from + count - 1} of '{id}'.";

    /// <summary>Error when the transcribe target has no sound file.</summary>
    public static string TranscribeTargetError(string id) => $"'{id}' is not an audio or video layer with a file";

    /// <summary>transcribe reply. Swift says "on this Mac" / "by Apple's servers"; pass the wording for the recognizer used.</summary>
    public static string TranscribeReply(string id, TranscriptionResult result, string onDeviceText = "on this machine",
        string serverText = "by the recognition server")
    {
        var how = result.OnDevice ? onDeviceText : serverText;
        if (result.Words.Count == 0)
            return $"No speech found in '{id}' (recognized as {result.Language} {how}). "
                + "Check the language, or that the layer's file has speech.";
        var info = new StringInfo(result.Text);
        var body = info.LengthInTextElements > 6000 ? info.SubstringByTextElements(0, 6000) + " …" : result.Text;
        return $"Transcribed '{id}' as {result.Language} {how}: {result.Words.Count} words.\n{body}\n"
            + $"Next: add_captions with id '{id}' to make timed captions.";
    }
}
