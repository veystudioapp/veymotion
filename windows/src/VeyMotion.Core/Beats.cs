using System.Globalization;

namespace VeyMotion.Core;

using AnimValue = Animated<double>;
using MotionKeyframe = Keyframe<double>;

// Music-driven editing: put presets, pulses, cuts and flashes on the beats of an audio layer in one step.
// Port of Beats.swift.

public enum BeatAction
{
    /// <summary>Apply a preset at each beat, cycling through the layers (beat 1 → first layer, beat 2 → second…).</summary>
    Preset,
    /// <summary>Kick a property (scale, brightness, glow, y…) up by <c>amount</c> at each beat and let it fall back.</summary>
    Pulse,
    /// <summary>Show the layers one after another, each for one interval between beats (a slideshow cut to the music).</summary>
    Cut,
    /// <summary>A white flash over the whole frame on each beat.</summary>
    Flash,
}

/// <summary>Every beat; <c>bar</c> = first beat of each bar; <c>half</c> = every other beat; <c>onset</c> = strong hits
/// (drums, accents).</summary>
public enum BeatGrid { Beat, Bar, Half, Onset }

public static class BeatOps
{
    /// <summary>Audio layers with a file, anywhere in the tree (Swift <c>audioLayers</c>).</summary>
    public static List<MotionLayer> AudioLayersWithFile(this MotionScene s) =>
        s.AllLayers.Where(l => l.Type == LayerType.Audio && l.Path != null).ToList();

    /// <summary>The music (first audio layer with role music), else the first audio layer with a file.</summary>
    public static MotionLayer? DefaultReactSource(this MotionScene s)
    {
        var audio = s.AudioLayersWithFile();
        return audio.FirstOrDefault(l => l.Role == AudioRole.Music) ?? audio.FirstOrDefault();
    }

    /// <summary>Scene times of the chosen grid of an audio layer (default: the music) between from and to.</summary>
    public static List<double> BeatTimes(this MotionScene s, string? source, BeatGrid grid, double? from, double? to,
        double minStrength = 0.4)
    {
        var audio = s.AudioLayersWithFile();
        var src = (source != null ? audio.FirstOrDefault(l => l.Id == source) : s.DefaultReactSource())
            ?? throw new SceneException(source != null ? $"'{source}' is not an audio layer with a file" : "The scene has no audio layer");
        var path = src.Path ?? throw new SceneException($"'{src.Id}' has no file");
        // Swift throws the decoder's error; the C# cache only reports a failure.
        var a = AudioAnalysisCache.Analysis(path, wait: true)
            ?? throw new SceneException($"Could not analyze the audio of '{src.Id}'");
        var end = src.EffectiveEnd(s.Duration);
        double Scene(double ft) => src.Start + ft - src.TrimIn;
        var times = grid switch
        {
            BeatGrid.Beat => a.Beats.Select(Scene).ToList(),
            BeatGrid.Half => a.Beats.Where((_, i) => i % 2 == 0).Select(Scene).ToList(),
            BeatGrid.Bar => a.Downbeats.Select(Scene).ToList(),
            _ => a.Onsets.Where(o => o.Strength >= minStrength).Select(o => Scene(o.T)).ToList(),
        };
        double lo = Math.Max(from ?? src.Start, src.Start), hi = Math.Min(to ?? end, end);
        times = times.Where(t => t >= lo - 1e-6 && t <= hi + 1e-6).ToList();
        if (times.Count == 0)
            throw new SceneException($"No {grid.Json()}s found between {Num(lo)}s and {Num(hi)}s (is the music analyzed and rhythmic?)");
        return times;
    }

    /// <summary>Edits layers to the beats. Returns how many beats were used.</summary>
    public static int SyncToBeats(this MotionScene s, IReadOnlyList<string> ids, BeatAction action, IReadOnlyList<double> times,
        Preset? preset, AnimProperty? property, double amount, double release, double? duration)
    {
        if (times.Count == 0) return 0;
        var gaps = times.Skip(1).Zip(times, (b, a) => b - a).ToList();
        var typical = gaps.Count == 0 ? 0.5 : gaps.Order().ElementAt(gaps.Count / 2);
        switch (action)
        {
            case BeatAction.Preset:
            {
                if (preset is not { } pr) throw new SceneException("Give `preset` for action preset");
                if (ids.Count == 0) throw new SceneException("Give the layer ids");
                var d = duration ?? Math.Min(0.6, typical * 0.85);
                for (var k = 0; k < times.Count; k++) s.ApplyPreset(pr, ids[k % ids.Count], times[k], d);
                break;
            }
            case BeatAction.Pulse:
            {
                if (property is not { } p) throw new SceneException("Give `property` for action pulse (e.g. scale, brightness, glow)");
                if (ids.Count == 0) throw new SceneException("Give the layer ids");
                var rel = Math.Min(release, typical * 0.95);
                foreach (var id in ids)
                {
                    s.WithLayer(id, l =>
                    {
                        var baseTrack = l[p];
                        var track = baseTrack;
                        foreach (var t in times)
                        {
                            var b = baseTrack.ValueAt(t);
                            // Instant attack, eased fall back before the next beat.
                            MotionKeyframe[] kfs =
                            [
                                new(t - 0.001, b, Easing.Linear),
                                new(t + 0.03, b + amount, Easing.EaseOut),
                                new(t + rel, b, Easing.Named(EaseCurve.Cubic, EaseMode.Out)),
                            ];
                            track = track.Inserting(kfs, kfs[0].T, kfs[2].T);
                        }
                        l[p] = track;
                    });
                }
                break;
            }
            case BeatAction.Cut:
            {
                if (ids.Count == 0) throw new SceneException("Give the layer ids to cut between");
                // Interval k runs from beat k to beat k+1 (the last one to the end of the music).
                for (var k = 0; k < ids.Count && k < times.Count; k++)
                {
                    var st = times[k];
                    double? e = k + 1 < times.Count ? times[k + 1] : null;
                    s.WithLayer(ids[k], l =>
                    {
                        var shift = st - l.Start;
                        if (Math.Abs(shift) > 1e-6) l.ShiftKeys(shift);
                        l.Start = st;
                        l.End = e;
                    });
                }
                break;
            }
            case BeatAction.Flash:
                for (var k = 0; k < times.Count; k++)
                {
                    var t = times[k];
                    var f = new MotionLayer(LayerType.Rect, "flash", $"Beat Flash {k + 1}", s.Width / 2.0, s.Height / 2.0)
                    {
                        Width = (double)s.Width,
                        Height = (double)s.Height,
                        Fill = Rgba.White,
                        BlendMode = BlendMode.Add,
                        Start = t,
                        End = t + Math.Min(release, typical * 0.9),
                    };
                    f.Opacity = AnimValue.Keyframes([
                        new MotionKeyframe(t, Math.Min(Math.Max(amount, 0), 1), Easing.Linear),
                        new MotionKeyframe(f.End!.Value, 0, Easing.Named(EaseCurve.Quad, EaseMode.Out)),
                    ]);
                    s.AddLayer(f);
                }
                break;
        }
        return action == BeatAction.Cut ? Math.Min(ids.Count, times.Count) : times.Count;
    }

    // MCP replies (match MCPServer.swift "sync_to_beats")

    /// <summary>Error when `action` is missing or unknown.</summary>
    public static string ActionError =>
        $"`action` must be one of [{string.Join(", ", Enum.GetValues<BeatAction>().Select(a => a.Json()))}]";

    /// <summary>Error when action preset has no valid `preset`.</summary>
    public static string PresetError =>
        $"`preset` must be one of [{string.Join(", ", Enum.GetValues<Preset>().Select(p => p.Json()))}]";

    public const string PropertyError = "`property` must be an animatable number (scale, brightness, glow…)";

    /// <summary>Default `amount` when the tool call gives none.</summary>
    public static double DefaultAmount(BeatAction action) => action == BeatAction.Flash ? 0.6 : 0.15;
    public const double DefaultRelease = 0.25;

    /// <summary>"pulse on 12 beats (0.50, 1.00, …)".</summary>
    public static string SyncReply(BeatAction action, int used, BeatGrid grid, IReadOnlyList<double> times)
    {
        var shown = string.Join(", ", times.Take(8).Select(t => t.ToString("F2", CultureInfo.InvariantCulture)));
        return $"{action.Json()} on {used} {grid.Json()}s ({shown}{(times.Count > 8 ? ", …" : "")})";
    }

    /// <summary>Numbers as the port prints Swift doubles ("0.5", "6.0" → "6").</summary>
    internal static string Num(double v) => v.ToString("0.###############", CultureInfo.InvariantCulture);
}
