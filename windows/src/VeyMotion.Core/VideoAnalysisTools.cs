using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

/// <summary>The <c>stabilize</c>, <c>track_motion</c> and <c>auto_reframe</c> tool handlers. Port of their cases in
/// <c>MCPServer.callTool</c> (<c>MCPServer.swift</c>): each returns the reply text and makes the same scene edit through
/// <paramref name="mutate"/> (label, edit). Bad arguments throw <see cref="SceneException"/>.</summary>
public static class VideoAnalysisTools
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    public static string Stabilize(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate,
        IVideoFrameReader frames)
    {
        var scene = currentScene();
        var id = Str(a, "layer");
        var layer = scene.Layer(id);
        var from = Number(a["from"]) ?? layer.Start;
        var to = Number(a["to"]) ?? layer.EffectiveEnd(scene.Duration);
        var drift = VideoTracking.Shake(layer, scene, from, to, Number(a["step"]) ?? 0, frames);
        var lockMotion = (StringValue(a["mode"]) ?? "smooth") == "lock";
        var zoom = Math.Max(1, Number(a["zoom"]) ?? 1.08);
        var window = (int)Math.Clamp(ToInt(Number(a["smoothing"]) ?? 15), int.MinValue, int.MaxValue);
        mutate("Stabilize", s => s.Stabilize(id, drift, lockMotion, window, zoom));
        var maxShift = drift.Count > 0 ? drift.Max(d => Math.Sqrt(d.X * d.X + d.Y * d.Y)) : 0;
        return $"Stabilized '{id}' ({(lockMotion ? "locked" : "smoothed")}, {drift.Count} frames, camera drifted up to {ToInt(maxShift)} px; "
            + $"scaled ×{SwiftDouble(zoom)} to hide the moving edges). Translation only: rotation shake stays.";
    }

    public static string TrackMotion(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate,
        IVideoFrameReader frames)
    {
        var scene = currentScene();
        var id = Str(a, "layer");
        var layer = scene.Layer(id);
        if (Number(a["x"]) is not { } x || Number(a["y"]) is not { } y)
            throw new SceneException("`x` and `y` (center of the object, scene px) are required");
        double bw = Number(a["width"]) ?? 120, bh = Number(a["height"]) ?? 120;
        var from = Number(a["from"]) ?? layer.Start;
        var to = Number(a["to"]) ?? layer.EffectiveEnd(scene.Duration);
        var samples = VideoTracking.Track(layer, scene, (x - bw / 2, y - bh / 2, bw, bh), from, to, Number(a["step"]) ?? 0, frames);
        var smooth = (int)Math.Clamp(ToInt(Number(a["smoothing"]) ?? 3), int.MinValue, int.MaxValue);
        var series = VideoTracking.Smoothed(samples, smooth);
        if (StringValue(a["target"]) is { Length: > 0 } target)
        {
            var keep = Bool(a["keepOffset"]) ?? true;
            var scale = Bool(a["scale"]) ?? false;
            mutate("Track Motion", s => s.Attach(target, series, keep, scale));
            var last = series[^1];
            return $"Tracked '{id}' from {SwiftDouble(from)}s to {last.T.ToString("F2", Inv)}s ({series.Count} keys) and attached '{target}': "
                + "it now follows the object" + (keep ? " keeping its offset" : "")
                + $". Lowest confidence {(series.Count > 0 ? series.Min(s => s.Confidence) : 0).ToString("F2", Inv)}.";
        }
        var lines = series.Select(s => string.Format(Inv, "{0:F2}: {1:F0}, {2:F0} ({3:F0}x{4:F0}, conf {5:F2})",
            s.T, s.X, s.Y, s.Width, s.Height, s.Confidence));
        return $"Tracked '{id}' ({series.Count} samples, scene px):\n" + string.Join("\n", lines);
    }

    public static string AutoReframe(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate,
        IVideoFrameReader frames)
    {
        var scene = currentScene();
        var id = Str(a, "layer");
        var layer = scene.Layer(id);
        if (Number(a["width"]) is not { } tw || Number(a["height"]) is not { } th || !(tw > 0) || !(th > 0))
            throw new SceneException("`width` and `height` of the target format are required (e.g. 1080 x 1920)");
        var from = Number(a["from"]) ?? layer.Start;
        var to = Number(a["to"]) ?? layer.EffectiveEnd(scene.Duration);
        var step = Math.Max(0.1, Number(a["step"]) ?? 0.5);
        var samples = VideoTracking.Saliency(layer, scene, from, to, step, frames);
        var series = VideoTracking.Smoothed(samples, (int)Math.Clamp(ToInt(Number(a["smoothing"]) ?? 3), int.MinValue, int.MaxValue));
        mutate("Auto Reframe", s => s.Reframe(id, series, tw, th));
        var l = currentScene().Layer(id);
        return $"Reframed '{id}' for {ToInt(tw)}x{ToInt(th)} with {series.Count} position keys (x now {SceneJson.CompactJson(l.X)}). "
            + $"Export with size {ToInt(tw)}x{ToInt(th)} and fit \"crop\" to get the vertical cut; the subject stays centered.";
    }

    // Argument helpers (same rules as McpServer's).

    static string Str(JsonObject a, string key) =>
        a[key] is JsonValue v && v.GetValueKind() == JsonValueKind.String && v.GetValue<string>() is { Length: > 0 } s
            ? s : throw new SceneException($"`{key}` must be a non-empty string");

    static string? StringValue(JsonNode? n) =>
        n is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    static bool? Bool(JsonNode? n) => n is JsonValue v ? v.GetValueKind() switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => null,
    } : null;

    static double? Number(JsonNode? n) => n switch
    {
        JsonValue v when v.GetValueKind() == JsonValueKind.Number => SceneJson.ToDouble(v),
        JsonValue v when v.GetValueKind() == JsonValueKind.String
            && double.TryParse(v.GetValue<string>(), NumberStyles.Float, Inv, out var d) => d,
        _ => null,
    };

    /// <summary>Swift's <c>Int(double)</c> (truncation), without trapping on NaN or overflow.</summary>
    static long ToInt(double v) => double.IsNaN(v) ? 0 : (long)Math.Clamp(Math.Truncate(v), long.MinValue, long.MaxValue);

    /// <summary>A double as Swift interpolates it ("0.0", "1.5", "1e-05").</summary>
    internal static string SwiftDouble(double v)
    {
        if (double.IsNaN(v)) return "nan";
        if (double.IsInfinity(v)) return v > 0 ? "inf" : "-inf";
        if (v == Math.Floor(v) && Math.Abs(v) < 1e16) return v.ToString("0", Inv) + ".0";
        var abs = Math.Abs(v);
        if (abs < 1e-4 || abs >= 1e16)
        {
            var e = v.ToString("R", Inv).Replace("E", "e");
            var k = e.IndexOf('e');
            if (k >= 0 && k + 2 < e.Length && char.IsDigit(e[k + 2]) && e.Length - k - 2 == 1) e = e[..(k + 2)] + "0" + e[(k + 2)..];
            return e;
        }
        return v.ToString("R", Inv);
    }
}
