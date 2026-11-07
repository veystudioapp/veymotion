using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

/// <summary>Free stock video (Pexels and Pixabay) through the VeyMotion server (<c>/api/stock/videos</c>), which holds
/// the API keys. The server is <see cref="ServerConfig.BaseUrl"/> (<c>BASE_API_URL</c>); the video files come straight
/// from the sources' CDNs. Port of <c>StockVideo.swift</c>.</summary>
public static class StockVideoSearch
{
    public static readonly string[] RefPrefixes = ["pexels", "pixabay"];

    /// <summary>Downloads are capped at this many pixels on the long side (1080p): 4K files are hundreds of MB and the
    /// canvas never shows more than the scene size.</summary>
    public const int MaxImportSide = 1920;

    /// <summary>Blocking. <paramref name="orientation"/>: landscape, portrait or square. <paramref name="maxDuration"/>
    /// &gt; 0 leaves out longer clips.</summary>
    public static List<StockItem> Search(string q, int page, string? orientation, double? maxDuration)
    {
        var items = new List<(string, string)>
        {
            ("q", q), ("page", Math.Max(1, page).ToString(CultureInfo.InvariantCulture)), ("perPage", "20"),
        };
        if (orientation?.ToLowerInvariant() is { Length: > 0 } o && o != "any") items.Add(("orientation", o));
        var obj = Call("/api/stock/videos" + StockHttp.Query([.. items]));
        var found = (obj["results"] as JsonArray ?? []).OfType<JsonObject>().Select(ItemFrom).OfType<StockItem>().ToList();
        if (maxDuration is { } m && m > 0) found = found.Where(i => (i.Duration ?? 0) <= m + 0.5).ToList();
        return found;
    }

    /// <summary>Looks up "pexels:&lt;id&gt;" / "pixabay:&lt;id&gt;". Blocking.</summary>
    public static StockItem Item(string source, string id)
    {
        if (id.Length == 0 || !id.All(char.IsDigit)) throw new SceneException($"Bad video ref {source}:{id}");
        return ItemFrom(Call($"/api/stock/videos/{source}/{id}")) ?? throw new SceneException($"{source} video {id} has no MP4 file");
    }

    /// <summary>A server result → StockItem, downloading the largest MP4 up to <see cref="MaxImportSide"/> (else the
    /// smallest).</summary>
    public static StockItem? ItemFrom(JsonObject r)
    {
        if (StockHttp.Str(r, "ref") is not { } reference || StockHttp.Str(r, "pageUrl") is not { } pageUrl) return null;
        var files = (r["files"] as JsonArray ?? []).OfType<JsonObject>()
            .Select(f => (Url: StockHttp.Str(f, "url"), W: StockHttp.Int(f, "width"), H: StockHttp.Int(f, "height")))
            .Where(f => f.Url != null && Uri.TryCreate(f.Url, UriKind.Absolute, out _) && f.W != null && f.H != null)
            .Select(f => (Url: f.Url!, W: f.W!.Value, H: f.H!.Value))
            .OrderBy(f => (long)f.W * f.H).ToList();
        if (files.Count == 0) return null;
        var smallest = files[0];
        var chosen = files.LastOrDefault(f => Math.Max(f.W, f.H) <= MaxImportSide);
        if (chosen.Url == null) chosen = smallest;

        var sourceName = StockHttp.Str(r, "source") == "pixabay" ? "Pixabay" : "Pexels";
        var title = StockHttp.Str(r, "title") is { Length: > 0 } t ? t : $"{sourceName} video";
        var creator = StockHttp.Str(r, "creator");
        var credit = new AssetCredit
        {
            Title = title, Creator = creator, License = StockHttp.Str(r, "license") ?? $"{sourceName} License",
            LicenseURL = StockHttp.Str(r, "licenseUrl"), SourceURL = pageUrl,
            Attribution = $"Video{(creator != null ? $" by {creator}" : "")} on {sourceName}",
            RequiresAttribution = false, Ref = reference,
        };
        return new StockItem
        {
            Ref = reference, Kind = StockKind.Video, Title = title, ThumbnailUrl = StockHttp.Str(r, "thumbnail"),
            FileExtension = "mp4", Width = chosen.W, Height = chosen.H, Credit = credit,
            DownloadUrl = chosen.Url, PreviewUrl = smallest.Url, Duration = StockHttp.Double(r, "duration"),
            Tags = (StockHttp.Strings(r, "tags") ?? []).Select(x => x.ToLowerInvariant()).ToList(),
        };
    }

    static JsonObject Call(string pathAndQuery)
    {
        var baseUrl = ServerConfig.BaseUrl;
        if (!Uri.TryCreate(baseUrl + pathAndQuery, UriKind.Absolute, out var url))
            throw new SceneException($"Invalid BASE_API_URL: {baseUrl}");
        (byte[] Data, int Status, string? ContentType) result;
        try { result = StockHttp.Perform(new HttpRequestMessage(HttpMethod.Get, url), 30); }
        catch (SceneException)
        {
            throw new SceneException($"Stock video needs the VeyMotion server, which is not reachable at {baseUrl} "
                + "(start it with `cd server && bun run dev`, or set BASE_API_URL).");
        }
        JsonObject? obj = null;
        try { obj = JsonNode.Parse(result.Data) as JsonObject; } catch (JsonException) { }
        if (result.Status is < 200 or >= 300)
        {
            var message = StockHttp.Str(obj, "message");
            if (result.Status == 404 && message?.Contains("has no video") != true)
                throw new SceneException($"The VeyMotion server at {baseUrl} has no stock video route. Update and restart it.");
            var msg = message ?? (result.Data.Length > 0 ? Encoding.UTF8.GetString(result.Data, 0, Math.Min(300, result.Data.Length)) : "no details");
            throw new SceneException(result.Status == 429 ? $"Stock video is rate-limited: {msg}. Wait a minute and try again." : msg);
        }
        return obj ?? throw new SceneException("Unexpected response from the VeyMotion server");
    }
}
