namespace VeyMotion.Core;

/// <summary>Platforms VeyMotion can publish to (see <see cref="SocialPublisher"/>). Port of <c>SocialPlatform</c>
/// (<c>Platforms.swift</c>).</summary>
public enum SocialPlatform { Youtube, Tiktok, Facebook, X }

public static class SocialPlatformExtensions
{
    public static readonly SocialPlatform[] All = [SocialPlatform.Youtube, SocialPlatform.Tiktok, SocialPlatform.Facebook, SocialPlatform.X];

    /// <summary>"youtube", "tiktok", "facebook", "x" (server routes, credential names, settings keys).</summary>
    public static string RawValue(this SocialPlatform p) => p switch
    {
        SocialPlatform.Youtube => "youtube",
        SocialPlatform.Tiktok => "tiktok",
        SocialPlatform.Facebook => "facebook",
        _ => "x",
    };

    public static SocialPlatform? ParseSocialPlatform(string? raw) => raw switch
    {
        "youtube" => SocialPlatform.Youtube,
        "tiktok" => SocialPlatform.Tiktok,
        "facebook" => SocialPlatform.Facebook,
        "x" => SocialPlatform.X,
        _ => null,
    };

    public static string Name(this SocialPlatform p) => p switch
    {
        SocialPlatform.Youtube => "YouTube",
        SocialPlatform.Tiktok => "TikTok",
        SocialPlatform.Facebook => "Facebook",
        _ => "X",
    };

    /// <summary>Longest caption / title the platform accepts.</summary>
    public static int TitleLimit(this SocialPlatform p) => p switch
    {
        SocialPlatform.Youtube => 100,
        SocialPlatform.Tiktok => 2200,
        SocialPlatform.Facebook => 255,
        _ => 280,
    };

    /// <summary>Largest upload in bytes through the API.</summary>
    public static long MaxBytes(this SocialPlatform p) => p switch
    {
        SocialPlatform.Youtube => 256L << 30,
        SocialPlatform.Tiktok => 4L << 30,
        SocialPlatform.Facebook => 10L << 30,
        _ => 512L << 20,
    };

    /// <summary>Containers each API accepts (X takes MP4 only).</summary>
    public static bool Accepts(this SocialPlatform p, string path)
    {
        var ext = System.IO.Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        return p == SocialPlatform.X ? ext == "mp4" : ext is "mp4" or "mov";
    }

    /// <summary>The platform a <see cref="PlatformPreset"/> publishes to (Swift's <c>PlatformPreset.platform</c>,
    /// which the C# preset record does not carry).</summary>
    public static SocialPlatform? PlatformOf(PlatformPreset preset) => preset.Id switch
    {
        "tiktok" => SocialPlatform.Tiktok,
        "shorts" or "youtube" => SocialPlatform.Youtube,
        "reels" or "facebook" => SocialPlatform.Facebook,
        "x" => SocialPlatform.X,
        _ => null,
    };

    /// <summary>The preset of <paramref name="p"/> closest to the scene's aspect ratio (YouTube: Shorts for vertical
    /// scenes), whose limits apply when the scene is published there as it is. Port of <c>PlatformPreset.matching</c>.</summary>
    public static PlatformPreset? MatchingPreset(this SocialPlatform p, MotionScene scene)
    {
        var aspect = (double)scene.Width / Math.Max(scene.Height, 1);
        return PlatformPreset.All.Where(x => PlatformOf(x) == p)
            .OrderBy(x => Math.Abs(Math.Log((double)x.Width / x.Height / aspect)))
            .FirstOrDefault();
    }
}
