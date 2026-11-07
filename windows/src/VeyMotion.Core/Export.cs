namespace VeyMotion.Core;

public enum ExportFit
{
    /// <summary>Whole scene visible, bars (scene background) on the sides.</summary>
    Fit,
    /// <summary>Fills the frame, cropping the scene's edges (centered).</summary>
    Fill,
}

/// <summary>Output settings. Port of <c>ExportOptions</c> (<c>Exporter.swift</c>).</summary>
public sealed class ExportOptions
{
    /// <summary>Output size relative to the scene size (0.5 = half resolution). Ignored when Size is set.</summary>
    public double Scale = 1;
    /// <summary>Exact output size (a platform preset); the scene is fitted or cropped into it per Fit.</summary>
    public (int W, int H)? Size;
    public ExportFit Fit = ExportFit.Fit;
    /// <summary>Time range in scene seconds; null = whole scene.</summary>
    public double? Start, End;

    /// <summary>Output pixels, even (H.264 needs it).</summary>
    public (int W, int H) PixelSize(MotionScene s)
    {
        var (w, h) = Size ?? ((int)Math.Round(s.Width * Scale), (int)Math.Round(s.Height * Scale));
        return (Math.Max(2, w / 2 * 2), Math.Max(2, h / 2 * 2));
    }

    /// <summary>True when the output frame has a different aspect ratio than the scene (bars or cropping).</summary>
    public bool IsReframed(MotionScene s)
    {
        if (Size == null) return false;
        var (w, h) = PixelSize(s);
        return Math.Abs((double)w / h / ((double)s.Width / Math.Max(s.Height, 1)) - 1) > 0.005;
    }

    /// <summary>Frame numbers to export.</summary>
    public (int First, int Count) FrameRange(MotionScene s)
    {
        var total = (int)Math.Round(s.Duration * s.Fps);
        var first = Math.Clamp((int)Math.Round((Start ?? 0) * s.Fps), 0, total);
        var last = Math.Clamp((int)Math.Round((End ?? s.Duration) * s.Fps), first, total);
        return (first, Math.Max(last - first, 0));
    }

    /// <summary>Rough H.264 file size (the exporter's bitrate × length).</summary>
    public long EstimatedBytes(MotionScene s)
    {
        var (w, h) = PixelSize(s);
        var bitrate = Math.Clamp((long)w * h * s.Fps * 0.15, 2_000_000, 80_000_000) + 192_000;
        return (long)(bitrate / 8.0 * FrameRange(s).Count / s.Fps);
    }
}

/// <summary>Output sizes and limits of common social video formats. Port of <c>PlatformPreset</c>.</summary>
public sealed record PlatformPreset(string Id, string Name, int Width, int Height, double? MaxDuration = null, long? MaxBytes = null, int MaxFps = 60)
{
    public static readonly PlatformPreset[] All =
    [
        new("tiktok", "TikTok", 1080, 1920, 600, 4L << 30),
        new("shorts", "YouTube Shorts", 1080, 1920, 180),
        new("reels", "Instagram / Facebook Reels", 1080, 1920, 180, 4L << 30),
        new("youtube", "YouTube", 1920, 1080),
        new("facebook", "Facebook feed", 1080, 1350, 240 * 60, 10L << 30),
        new("x", "X (Twitter)", 1920, 1080, 140, 512L << 20),
        new("square", "Square post", 1080, 1080),
    ];

    public static PlatformPreset? Named(string id) => All.FirstOrDefault(p => p.Id == id.ToLowerInvariant());

    /// <summary>"9:16", "16:9", "1:1", "4:5".</summary>
    public string AspectLabel
    {
        get
        {
            static int Gcd(int a, int b) => b == 0 ? a : Gcd(b, a % b);
            var g = Gcd(Width, Height);
            return $"{Width / g}:{Height / g}";
        }
    }

    /// <summary>Problems exporting the scene with this preset (too long, too many fps, likely too big).</summary>
    public List<string> Warnings(MotionScene s, double duration, long? estimatedBytes)
    {
        var output = new List<string>();
        if (MaxDuration is { } max && duration > max + 0.01)
            output.Add($"{Name} accepts videos up to {FormatDuration(max)}; this export is {FormatDuration(duration)}.");
        if (s.Fps > MaxFps) output.Add($"{Name} plays at most {MaxFps} fps; the scene is {s.Fps} fps.");
        if (MaxBytes is { } mb && estimatedBytes is { } est && est > mb)
            output.Add($"The file will be about {est / 1_000_000} MB; {Name} accepts up to {mb / 1_000_000} MB. Lower the quality.");
        return output;
    }

    public static string FormatDuration(double s)
    {
        var t = (int)Math.Round(s);
        if (t < 60) return $"{t}s";
        return t % 60 == 0 ? $"{t / 60} min" : $"{t / 60}m {t % 60}s";
    }
}
