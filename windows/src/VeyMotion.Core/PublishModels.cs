using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

// Publishing exported videos to YouTube, TikTok, Facebook Pages and X. Port of Publish.swift.
//
// OAuth goes through the VeyMotion server (`server/api/social/*`, at `BASE_API_URL`), which holds the client
// secrets: the app registers a connection (`/start`), opens the returned consent page in the browser, polls
// `/session` for the tokens, and refreshes them through `/refresh`. Tokens are kept in the Windows Credential
// Manager. Uploads go straight to each platform.

/// <summary>A publishing failure with a message meant for the user. Port of <c>PublishError</c>.</summary>
public class PublishException(string message) : Exception(message);

/// <summary>Thrown when the caller's cancellation token fires ("Publishing cancelled" / "Connection cancelled").</summary>
public sealed class PublishCancelledException(string message) : PublishException(message);

public sealed record FacebookPage(string Id, string Name, string AccessToken)
{
    internal JsonObject ToJson() => new() { ["id"] = Id, ["name"] = Name, ["accessToken"] = AccessToken };

    internal static FacebookPage? FromJson(JsonNode? n) =>
        StockHttp.Str(n, "id") is { } id && StockHttp.Str(n, "accessToken") is { } t
            ? new FacebookPage(id, StockHttp.Str(n, "name") ?? id, t) : null;
}

/// <summary>A connected account, stored in the Credential Manager (one per platform user).</summary>
public sealed class SocialAccount
{
    public SocialPlatform Platform { get; set; }
    public string AccessToken { get; set; } = "";
    public string? RefreshToken { get; set; }
    public DateTimeOffset? ExpiresAt { get; set; }
    public string? Scope { get; set; }
    public string? UserId { get; set; }
    /// <summary>Channel title, display name or @username.</summary>
    public string? DisplayName { get; set; }
    /// <summary>X: @username, used to build post links.</summary>
    public string? Username { get; set; }
    /// <summary>Facebook: Pages the user can post to.</summary>
    public List<FacebookPage>? Pages { get; set; }
    public DateTimeOffset ConnectedAt { get; set; } = DateTimeOffset.UtcNow;

    internal bool IsExpiring => ExpiresAt is { } e && e < DateTimeOffset.UtcNow.AddSeconds(120);

    /// <summary>Credential key: one item per platform user (a YouTube channel, a TikTok / X / Facebook user).
    /// Also what <see cref="PublishSettings.ActiveAccount"/> stores.</summary>
    public string Key => $"{Platform.RawValue()}:{UserId ?? "default"}";

    /// <summary>Whether the user granted <paramref name="s"/> (TikTok scopes are comma-separated, the others space-separated).</summary>
    public bool HasScope(string s) => (Scope ?? "").Split([',', ' '], StringSplitOptions.RemoveEmptyEntries).Contains(s);

    internal string ToJsonString()
    {
        var o = new JsonObject { ["platform"] = Platform.RawValue(), ["accessToken"] = AccessToken };
        if (RefreshToken != null) o["refreshToken"] = RefreshToken;
        if (ExpiresAt is { } e) o["expiresAt"] = e.ToUnixTimeMilliseconds() / 1000.0;
        if (Scope != null) o["scope"] = Scope;
        if (UserId != null) o["userId"] = UserId;
        if (DisplayName != null) o["displayName"] = DisplayName;
        if (Username != null) o["username"] = Username;
        if (Pages != null) o["pages"] = new JsonArray(Pages.Select(p => (JsonNode)p.ToJson()).ToArray());
        o["connectedAt"] = ConnectedAt.ToUnixTimeMilliseconds() / 1000.0;
        return o.ToJsonString();
    }

    internal static SocialAccount? FromJsonString(string json)
    {
        JsonObject? o;
        try { o = JsonNode.Parse(json) as JsonObject; }
        catch (JsonException) { return null; }
        if (o == null || SocialPlatformExtensions.ParseSocialPlatform(StockHttp.Str(o, "platform")) is not { } platform
            || StockHttp.Str(o, "accessToken") is not { } token) return null;
        static DateTimeOffset? Time(JsonObject o, string k) =>
            StockHttp.Double(o, k) is { } s ? DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(s * 1000)) : null;
        return new SocialAccount
        {
            Platform = platform,
            AccessToken = token,
            RefreshToken = StockHttp.Str(o, "refreshToken"),
            ExpiresAt = Time(o, "expiresAt"),
            Scope = StockHttp.Str(o, "scope"),
            UserId = StockHttp.Str(o, "userId"),
            DisplayName = StockHttp.Str(o, "displayName"),
            Username = StockHttp.Str(o, "username"),
            Pages = o["pages"] is JsonArray a ? a.Select(FacebookPage.FromJson).OfType<FacebookPage>().ToList() : null,
            ConnectedAt = Time(o, "connectedAt") ?? DateTimeOffset.UtcNow,
        };
    }
}

public enum TikTokMode
{
    /// <summary>Upload to the creator's TikTok inbox; they finish and post it in the TikTok app.</summary>
    Draft,
    /// <summary>Post directly (needs the <c>video.publish</c> scope; unaudited apps can only post privately).</summary>
    Direct,
}

public sealed class PublishRequest(string file, string title)
{
    /// <summary>Path of the video file (MP4, or MOV except for X).</summary>
    public string File { get; set; } = file;
    /// <summary>YouTube / Facebook title; TikTok and X caption.</summary>
    public string Title { get; set; } = title;
    /// <summary>YouTube / Facebook description.</summary>
    public string Description { get; set; } = "";
    public List<string> Tags { get; set; } = [];
    /// <summary>YouTube: private, unlisted or public.</summary>
    public string YoutubePrivacy { get; set; } = "private";
    public TikTokMode TiktokMode { get; set; } = TikTokMode.Draft;
    /// <summary>One of <see cref="TikTokCreatorInfo.PrivacyOptions"/> (direct posts).</summary>
    public string? TiktokPrivacy { get; set; }
    public bool DisableComments { get; set; }
    public bool DisableDuet { get; set; }
    public bool DisableStitch { get; set; }
    public string? FacebookPageId { get; set; }
    /// <summary>Custom thumbnail: JPEG bytes, at most <see cref="PublishThumbnail.MaxBytes"/> (the caller encodes it),
    /// set on YouTube and Facebook after the upload. A failure to set it never fails the post.</summary>
    public byte[]? Thumbnail { get; set; }
    /// <summary>TikTok direct posts: the frame used as the cover, in seconds into the video.</summary>
    public double? CoverTime { get; set; }
}

public sealed record PublishResult(SocialPlatform Platform, string Id, string? Url, string? Note);

/// <summary>What TikTok allows this creator to post (shown before a direct post, as TikTok requires).</summary>
public sealed record TikTokCreatorInfo(
    string Nickname, string? Username, IReadOnlyList<string> PrivacyOptions,
    bool CommentDisabled, bool DuetDisabled, bool StitchDisabled, double? MaxDuration);

/// <summary>Thumbnail limits (YouTube's). Encoding is the app's job (Win2D / WIC): a JPEG with the longer side at
/// most <see cref="MaxSide"/> px, re-encoded at qualities 0.9, 0.8, 0.65, 0.5, 0.35 until it fits <see cref="MaxBytes"/>.</summary>
public static class PublishThumbnail
{
    public const int MaxSide = 1280;
    public const int MaxBytes = 2_000_000;
    public static readonly double[] Qualities = [0.9, 0.8, 0.65, 0.5, 0.35];

    /// <summary>Whether <paramref name="data"/> looks like a JPEG small enough to upload.</summary>
    public static bool IsValid(byte[]? data) =>
        data is { Length: > 3 and <= MaxBytes } && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF;
}
