using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace VeyMotion.Core;

/// <summary>Free asset sources. Port of <c>StockSources.swift</c>:
/// Openverse photos/illustrations and audio (Jamendo music, Freesound effects; licenses that allow commercial use and
/// modification), Iconify icons, Google Fonts (<see cref="GoogleFonts"/>) and stock video through the VeyMotion
/// server (<see cref="StockVideoSearch"/>).</summary>
public enum StockKind { Photo, Illustration, Video, Icon, Music, Sound, Font }

public static class StockKindExtensions
{
    public static readonly StockKind[] All = Enum.GetValues<StockKind>();

    /// <summary>"photo", "illustration"… (the tool value).</summary>
    public static string Raw(this StockKind k) => k.ToString().ToLowerInvariant();

    public static StockKind? Parse(string? raw) => All.Where(k => k.Raw() == raw).Select(k => (StockKind?)k).FirstOrDefault();

    public static string Title(this StockKind k) => k switch
    {
        StockKind.Photo => "Photos",
        StockKind.Illustration => "Illustrations",
        StockKind.Video => "Videos",
        StockKind.Icon => "Icons",
        StockKind.Music => "Music",
        StockKind.Sound => "Sound FX",
        _ => "Fonts",
    };

    public static bool IsAudio(this StockKind k) => k is StockKind.Music or StockKind.Sound;
}

public sealed class StockItem
{
    /// <summary>"openverse:&lt;uuid&gt;", "pexels:&lt;id&gt;" or "iconify:&lt;prefix&gt;:&lt;name&gt;". Pass it to
    /// <see cref="StockSearch.Item"/>.</summary>
    public required string Ref { get; init; }
    public required StockKind Kind { get; init; }
    public required string Title { get; init; }
    public string? ThumbnailUrl { get; set; }
    public required string FileExtension { get; init; }
    public int? Width { get; set; }
    public int? Height { get; set; }
    /// <summary>Multi-color icon (its colors are fixed; <c>color</c> does not apply).</summary>
    public bool IsMulticolor { get; set; }
    public required AssetCredit Credit { get; init; }
    /// <summary>Full-size file for photos/illustrations/audio/video (icon files are built from the ref).</summary>
    public string? DownloadUrl { get; set; }
    /// <summary>Videos: the smallest rendition, for hover previews.</summary>
    public string? PreviewUrl { get; set; }
    /// <summary>Audio and video length in seconds.</summary>
    public double? Duration { get; set; }
    /// <summary>Music genres; for fonts: category, weights and "Vietnamese ✓".</summary>
    public List<string> Genres { get; set; } = [];
    /// <summary>Keywords from the source (Freesound tags describe a sound much better than its title).</summary>
    public List<string> Tags { get; set; } = [];
    /// <summary>Fonts: available styles ("400", "700", "400i"…).</summary>
    public List<string> FontStyles { get; set; } = [];

    /// <summary>One line for agents: "openverse:abc — Title — 1024×768 jpg — CC BY 4.0 (credit required) — by Someone".</summary>
    public string Summary
    {
        get
        {
            var parts = new List<string> { Ref, Title };
            if (Kind == StockKind.Font)
                parts.Add(string.Join(", ", Genres));
            else if (Kind == StockKind.Video)
            {
                var s = Duration is { } d0 ? Clock(d0) + " " : "";
                if (Width is { } w0 && Height is { } h0) s += $"{w0}×{h0} ";
                parts.Add(s + FileExtension);
                if (Tags.Count > 0) parts.Add("tags: " + string.Join(", ", Tags.Take(8)));
            }
            else if (Duration is { } d)
            {
                parts.Add(Clock(d) + " " + FileExtension + (Genres.Count == 0 ? "" : " — " + string.Join(", ", Genres.Take(3))));
                if (Kind == StockKind.Sound && Tags.Count > 0) parts.Add("tags: " + string.Join(", ", Tags.Take(8)));
            }
            else if (Width is { } w && Height is { } h)
                parts.Add($"{w}×{h} {FileExtension}");
            else
                parts.Add(FileExtension);
            parts.Add(Credit.License + (Credit.RequiresAttribution ? " (credit required)" : ""));
            if (!string.IsNullOrEmpty(Credit.Creator)) parts.Add($"by {Credit.Creator}");
            if (IsMulticolor) parts.Add("multicolor");
            return string.Join(" — ", parts);
        }
    }

    /// <summary>95.2 → "1:35"; short sounds keep tenths: 0.45 → "0.5s".</summary>
    public static string Clock(double seconds)
    {
        if (seconds < 10) return seconds.ToString("0.0", CultureInfo.InvariantCulture) + "s";
        var s = (int)Math.Round(seconds, MidpointRounding.AwayFromZero);
        return $"{s / 60}:{s % 60:00}";
    }
}

/// <summary>A stock file to put into the asset library. The importer (asset store) must:
/// 1. resolve the folder: <c>validFolder(routed(Folder, default: TypeFolder))</c> (projects file by type when
///    <see cref="Folder"/> is null);
/// 2. when <see cref="ReuseExisting"/> and the library's credit for folder/<see cref="FileName"/> has
///    <c>Credit.Ref</c> and the file exists, return that asset without calling <see cref="Download"/>;
/// 3. write <c>Download()</c> as <see cref="FileName"/> (replacing an existing file when <see cref="Overwrite"/>, else
///    under a unique name);
/// 4. audio kinds: when the file is not decodable audio, trash it and throw <see cref="NotPlayableMessage"/>; videos:
///    when it is not a video, likewise;
/// 5. record <see cref="Credit"/> for the asset's library name.</summary>
public sealed record StockImportRequest(
    string FileName, string? Folder, string TypeFolder, StockKind Kind, string Title, AssetCredit Credit,
    bool ReuseExisting, bool Overwrite, Func<byte[]> Download)
{
    public string NotPlayableMessage => Kind == StockKind.Video
        ? $"The downloaded file for '{Title}' is not a video. Try another result."
        : $"The downloaded file for '{Title}' is not playable audio. Try another result.";
}

/// <summary>An imported asset: absolute path, library name (path relative to the library, the credits key) and its
/// one-line summary (<c>AssetInfo.summary</c>).</summary>
public sealed record StockAsset(string Path, string Name, string Summary);

/// <summary>Writes a stock download into the asset library (see <see cref="StockImportRequest"/>).</summary>
public delegate StockAsset StockImporter(StockImportRequest request);

public static class StockSearch
{
    const int IconPageSize = 48;

    /// <summary>Sound effects longer than this are left out unless a search asks for longer ones.</summary>
    public const double DefaultSoundMaxDuration = 10.0;

    static string CacheRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VeyMotion", "cache");

    // MARK: Search

    /// <summary>Blocking. <paramref name="page"/> starts at 1. <paramref name="vietnamese"/>: fonts only, keep families
    /// with Vietnamese letters. <paramref name="maxDuration"/>: audio and video, leave out longer results (sounds
    /// default to <see cref="DefaultSoundMaxDuration"/>; 0 = no limit). <paramref name="orientation"/>: videos only,
    /// landscape / portrait / square (null = any).</summary>
    public static List<StockItem> Search(string query, StockKind kind, int page = 1, bool vietnamese = false,
                                         double? maxDuration = null, string? orientation = null)
    {
        var q = query.Trim();
        if (q.Length == 0) return [];
        switch (kind)
        {
            case StockKind.Font: return GoogleFonts.Search(q, page, vietnamese);
            case StockKind.Icon: return SearchIcons(q, page);
            case StockKind.Photo or StockKind.Illustration: return SearchOpenverse(q, kind, page);
            case StockKind.Video: return StockVideoSearch.Search(q, page, orientation, maxDuration);
            default:
                var limit = maxDuration ?? (kind == StockKind.Sound ? DefaultSoundMaxDuration : 0);
                return SearchOpenverseAudio(q, kind, page, limit > 0 ? limit : null);
        }
    }

    /// <summary>Words that mark a Freesound result as a background bed rather than a one-shot effect.</summary>
    static readonly string[] BedWords = ["loop", "ambience", "ambiance", "ambient", "atmosphere", "atmos", "soundscape", "field-recording",
                                         "field recording", "drone", "music", "song", "melody", "background", "room tone"];

    static List<StockItem> SearchOpenverseAudio(string q, StockKind kind, int page, double? maxDuration)
    {
        var items = new List<(string, string)>
        {
            ("q", q), ("page", Math.Max(1, page).ToString(CultureInfo.InvariantCulture)), ("page_size", "20"),
            ("license_type", "commercial,modification"),
            // Jamendo is all music; Freesound is sound effects (its items have no category).
            ("source", kind == StockKind.Music ? "jamendo" : "freesound"),
        };
        // Openverse length buckets: shortest < 30 s, short 30 s–2 min, medium 2–10 min, long > 10 min.
        if (maxDuration is { } m)
        {
            var buckets = m <= 30 ? "shortest" : m <= 120 ? "shortest,short" : m <= 600 ? "shortest,short,medium" : null;
            if (buckets != null) items.Add(("length", buckets));
        }
        const string baseUrl = "https://api.openverse.org/v1/audio/";
        JsonObject obj;
        try { obj = StockHttp.Json(baseUrl + StockHttp.Query([.. items])); }
        catch (SceneException) when (items.Any(i => i.Item1 == "length"))
        {
            // Older API versions reject `length`: retry without it and filter by duration here.
            obj = StockHttp.Json(baseUrl + StockHttp.Query([.. items.Where(i => i.Item1 != "length")]));
        }
        var found = Results(obj).Select(r => OpenverseItem(r, kind)).OfType<StockItem>().ToList();
        if (maxDuration is { } max) found = found.Where(i => (i.Duration ?? 0) <= max + 0.05).ToList();
        if (kind != StockKind.Sound) return found;
        // One-shot effects first: beds (loops, ambiences, music) go last unless the query asks for one.
        var lowered = q.ToLowerInvariant();
        var wanted = BedWords.Where(lowered.Contains).ToList();
        bool IsBed(StockItem item)
        {
            if (wanted.Count > 0) return false;
            var text = (item.Title + " " + string.Join(" ", item.Tags)).ToLowerInvariant();
            return BedWords.Any(text.Contains);
        }
        return [.. found.Where(i => !IsBed(i)), .. found.Where(IsBed)];
    }

    static List<StockItem> SearchOpenverse(string q, StockKind kind, int page)
    {
        var url = "https://api.openverse.org/v1/images/" + StockHttp.Query(
            ("q", q), ("page", Math.Max(1, page).ToString(CultureInfo.InvariantCulture)), ("page_size", "20"),
            ("license_type", "commercial,modification"), ("category", kind == StockKind.Photo ? "photograph" : "illustration"));
        return Results(StockHttp.Json(url)).Select(r => OpenverseItem(r, kind)).OfType<StockItem>().ToList();
    }

    static IEnumerable<JsonObject> Results(JsonObject obj) => (obj["results"] as JsonArray ?? []).OfType<JsonObject>();

    static readonly string[] AudioExtensions = ["mp3", "wav", "aiff", "aif", "m4a", "aac", "caf", "flac"];

    static StockItem? OpenverseItem(JsonObject r, StockKind kind)
    {
        if (StockHttp.Str(r, "id") is not { } id || StockHttp.Str(r, "url") is not { } urlString
            || !Uri.TryCreate(urlString, UriKind.Absolute, out var uri)) return null;
        var title = StockHttp.Str(r, "title") is { Length: > 0 } t ? t : "Untitled";
        var code = (StockHttp.Str(r, "license") ?? "").ToLowerInvariant();
        var license = LicenseName(code, StockHttp.Str(r, "license_version"));
        var requires = !(code == "cc0" || code == "pdm");
        var creator = StockHttp.Str(r, "creator");
        var ext = (StockHttp.Str(r, "filetype") ?? "").ToLowerInvariant();
        if (ext.Length == 0) ext = Path.GetExtension(uri.AbsolutePath).TrimStart('.').ToLowerInvariant() is { Length: > 0 } e ? e : "jpg";
        if (ext == "jpeg") ext = "jpg";
        // Jamendo reports "mp32" (its 320k mp3 format); keep only formats the audio decoder can read.
        if (kind.IsAudio() && !AudioExtensions.Contains(ext)) ext = "mp3";
        var attribution = StockHttp.Str(r, "attribution")
            ?? $"\"{title}\"{(creator != null ? $" by {creator}" : "")} is licensed under {license}.";
        var reference = (kind.IsAudio() ? "openverse-audio:" : "openverse:") + id;
        var credit = new AssetCredit
        {
            Title = title, Creator = creator, License = license, LicenseURL = StockHttp.Str(r, "license_url"),
            SourceURL = StockHttp.Str(r, "foreign_landing_url"), Attribution = attribution, RequiresAttribution = requires,
            Ref = reference,
        };
        var item = new StockItem
        {
            Ref = reference, Kind = kind, Title = title, ThumbnailUrl = StockHttp.Str(r, "thumbnail"), FileExtension = ext,
            Width = StockHttp.Int(r, "width"), Height = StockHttp.Int(r, "height"), Credit = credit, DownloadUrl = urlString,
        };
        if (StockHttp.Double(r, "duration") is { } ms) item.Duration = ms / 1000;
        if (StockHttp.Strings(r, "genres") is { } g) item.Genres = g;
        if (r["tags"] is JsonArray tags)
        {
            var seen = new HashSet<string>();
            item.Tags = tags.OfType<JsonObject>().Select(x => StockHttp.Str(x, "name")?.ToLowerInvariant())
                .OfType<string>().Where(x => x.Length > 0 && seen.Add(x)).ToList();
        }
        return item;
    }

    static string LicenseName(string code, string? version) => code switch
    {
        "cc0" => "CC0 1.0 (public domain)",
        "pdm" => "Public Domain Mark",
        "" => "Unknown license",
        _ => $"CC {code.ToUpperInvariant()}" + (version != null ? $" {version}" : ""),
    };

    static List<StockItem> SearchIcons(string q, int page)
    {
        var url = "https://api.iconify.design/search" + StockHttp.Query(
            ("query", q), ("limit", IconPageSize.ToString(CultureInfo.InvariantCulture)),
            ("start", ((Math.Max(1, page) - 1) * IconPageSize).ToString(CultureInfo.InvariantCulture)));
        var obj = StockHttp.Json(url);
        var collections = obj["collections"] as JsonObject;
        var list = new List<StockItem>();
        foreach (var full in StockHttp.Strings(obj, "icons") ?? [])
        {
            var parts = full.Split(':', 2);
            if (parts.Length != 2) continue;
            list.Add(IconItem(parts[0], parts[1], collections?[parts[0]] as JsonObject));
        }
        return list;
    }

    static StockItem IconItem(string prefix, string name, JsonObject? collection)
    {
        var setName = StockHttp.Str(collection, "name") ?? prefix;
        var lic = collection?["license"] as JsonObject;
        var license = StockHttp.Str(lic, "title") ?? "Open source (see iconify.design)";
        var spdx = (StockHttp.Str(lic, "spdx") ?? "").ToUpperInvariant();
        var author = StockHttp.Str(collection?["author"], "name");
        var reference = $"iconify:{prefix}:{name}";
        var credit = new AssetCredit
        {
            Title = $"{name} ({setName})", Creator = author, License = license, LicenseURL = StockHttp.Str(lic, "url"),
            SourceURL = $"https://icon-sets.iconify.design/{prefix}/?icon-filter={name}",
            Attribution = $"Icon \"{name}\" from {setName}{(author != null ? $" by {author}" : "")}, {license}.",
            RequiresAttribution = spdx.StartsWith("CC-BY"), Ref = reference,
        };
        return new StockItem
        {
            Ref = reference, Kind = StockKind.Icon, Title = $"{prefix}:{name}",
            ThumbnailUrl = IconUrl(prefix, name, "#FFFFFF", 64), // shown on dark tiles
            FileExtension = "svg", Credit = credit, IsMulticolor = StockHttp.Bool(collection, "palette") ?? false,
        };
    }

    internal static string IconUrl(string prefix, string name, string? color, int height)
    {
        var q = new List<(string, string)> { ("height", height.ToString(CultureInfo.InvariantCulture)) };
        if (color != null) q.Add(("color", color));
        return $"https://api.iconify.design/{Uri.EscapeDataString(prefix)}/{Uri.EscapeDataString(name)}.svg" + StockHttp.Query([.. q]);
    }

    // MARK: Import

    /// <summary>Looks up a ref returned by <see cref="Search"/> (works across launches). Blocking.</summary>
    public static StockItem Item(string reference)
    {
        var parts = reference.Split(':', StringSplitOptions.RemoveEmptyEntries);
        switch (parts.FirstOrDefault())
        {
            case "openverse" when parts.Length == 2:
            {
                var obj = StockHttp.Json($"https://api.openverse.org/v1/images/{Uri.EscapeDataString(parts[1])}/");
                var kind = StockHttp.Str(obj, "category") == "photograph" ? StockKind.Photo : StockKind.Illustration;
                return OpenverseItem(obj, kind) ?? throw new SceneException($"Openverse has no image {parts[1]}");
            }
            case "openverse-audio" when parts.Length == 2:
            {
                var obj = StockHttp.Json($"https://api.openverse.org/v1/audio/{Uri.EscapeDataString(parts[1])}/");
                var kind = StockHttp.Str(obj, "source") == "freesound" ? StockKind.Sound : StockKind.Music;
                return OpenverseItem(obj, kind) ?? throw new SceneException($"Openverse has no audio {parts[1]}");
            }
            case "googlefonts" when parts.Length == 2:
                return GoogleFonts.Item(GoogleFonts.Family(parts[1]));
            case { } source when StockVideoSearch.RefPrefixes.Contains(source) && parts.Length == 2:
                return StockVideoSearch.Item(source, parts[1]);
            case "iconify" when parts.Length == 3:
            {
                JsonObject? info = null;
                try { info = StockHttp.Json($"https://api.iconify.design/collections?prefixes={Uri.EscapeDataString(parts[1])}"); }
                catch (SceneException) { }
                return IconItem(parts[1], parts[2], info?[parts[1]] as JsonObject);
            }
            default:
                throw new SceneException($"Unknown ref '{reference}'. Use a ref from search_stock, e.g. openverse:<id>, pexels:<id> or iconify:mdi:rocket.");
        }
    }

    /// <summary>The library folder a kind is filed in (projects), as <c>importItem</c>.</summary>
    public static string TypeFolder(StockKind kind) => kind switch
    {
        StockKind.Icon => "icons",
        StockKind.Music => "music",
        StockKind.Sound => "sfx",
        StockKind.Video => "video",
        StockKind.Font => "fonts",
        _ => "images",
    };

    /// <summary>Downloads an item into the asset library through <paramref name="import"/> (which records the
    /// credit). Icons are saved as SVG in <paramref name="color"/> (hex, default white) at <paramref name="size"/> px
    /// tall. Fonts import every upright weight (see <see cref="ImportFont"/>). Blocking.</summary>
    public static StockAsset ImportItem(StockItem item, StockImporter import, string? name = null, string? folder = null,
                                        string? color = null, int size = 512)
    {
        if (item.Kind == StockKind.Font)
            return ImportFont(item, import, null, folder).FirstOrDefault() ?? throw new SceneException("No font files");
        string url, fileName;
        if (item.Kind == StockKind.Icon)
        {
            var parts = item.Ref.Split(':', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 3) throw new SceneException($"Bad icon ref {item.Ref}");
            var hex = item.IsMulticolor ? null : NormalizedHex(color ?? "#FFFFFF");
            url = IconUrl(parts[1], parts[2], hex, Math.Clamp(size, 16, 2048));
            fileName = $"{parts[1]}-{parts[2]}" + (hex != null ? "-" + hex[1..].ToLowerInvariant() : "") + ".svg";
        }
        else
        {
            url = item.DownloadUrl ?? throw new SceneException($"No download URL for {item.Ref}");
            fileName = Slug(item.Title) + "." + item.FileExtension;
        }
        var reuse = true;
        if (!string.IsNullOrEmpty(name))
        {
            fileName = Path.GetExtension(name).Length == 0 ? $"{name}.{item.FileExtension}" : name;
            reuse = false;
        }
        var timeout = item.Kind == StockKind.Video ? 600 : 120;
        byte[] Download()
        {
            if (item.Kind.IsAudio() && CachedAudio(item) is { } cached) return File.ReadAllBytes(cached);
            return StockHttp.Get(url, timeout);
        }
        return import(new StockImportRequest(fileName, folder, TypeFolder(item.Kind), item.Kind, item.Title, item.Credit,
                                             reuse, false, Download));
    }

    /// <summary>Downloads a font family's styles ("400", "700i"…; default every upright weight) into the library.
    /// The caller should then register the library fonts (<c>FontLibrary.refresh(force:)</c>). Blocking.</summary>
    public static List<StockAsset> ImportFont(StockItem item, StockImporter import, IReadOnlyList<string>? styles = null, string? folder = null)
    {
        if (!item.Ref.StartsWith(GoogleFonts.RefPrefix)) throw new SceneException($"{item.Ref} is not a font");
        var family = GoogleFonts.Family(item.Ref[GoogleFonts.RefPrefix.Length..]);
        return GoogleFonts.ImportFamily(family, styles, folder, import);
    }

    internal static string NormalizedHex(string s)
    {
        var h = s.Trim();
        return h.StartsWith('#') ? h : "#" + h;
    }

    /// <summary>"Ảnh đẹp — Sunset!" → "anh-dep-sunset" (ASCII letters and digits, at most 48 characters).</summary>
    public static string Slug(string title)
    {
        var folded = new StringBuilder();
        foreach (var ch in title.Normalize(NormalizationForm.FormD))
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.NonSpacingMark) continue;
            folded.Append(ch is 'đ' or 'Đ' ? 'd' : char.ToLowerInvariant(ch));
        }
        var outp = new StringBuilder();
        foreach (var ch in folded.ToString())
        {
            if (ch is >= 'a' and <= 'z' or >= '0' and <= '9') outp.Append(ch);
            else if (outp.Length == 0 || outp[^1] != '-') outp.Append('-');
        }
        var trimmed = outp.ToString().Trim('-');
        trimmed = trimmed[..Math.Min(48, trimmed.Length)].Trim('-');
        return trimmed.Length == 0 ? "image" : trimmed;
    }

    // MARK: Sound previews

    static string AudioCacheDir => Path.Combine(CacheRoot, "sounds");

    static string AudioCachePath(StockItem item)
    {
        var id = item.Ref.Split(':', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? Slug(item.Title);
        return Path.Combine(AudioCacheDir, $"{id}.{item.FileExtension}");
    }

    /// <summary>The file of an audio result if a search already downloaded it.</summary>
    public static string? CachedAudio(StockItem item)
    {
        var p = AudioCachePath(item);
        return File.Exists(p) ? p : null;
    }

    /// <summary>Downloads short audio results into a cache that <see cref="ImportItem"/> reuses, so they can be
    /// profiled (<c>SoundProfile</c>). Returns each item's cached file, null when skipped (not audio, longer than
    /// <paramref name="maxDuration"/>, or the download failed). Blocking.</summary>
    public static string?[] SoundFiles(IReadOnlyList<StockItem> items, double maxDuration = 30, double timeout = 20)
    {
        Directory.CreateDirectory(AudioCacheDir);
        PruneAudioCache();
        var out_ = new string?[items.Count];
        Parallel.For(0, items.Count, new ParallelOptions { MaxDegreeOfParallelism = 6 }, i =>
        {
            var item = items[i];
            if (!item.Kind.IsAudio() || (item.Duration ?? 0) > maxDuration || item.DownloadUrl is not { } remote) return;
            var path = AudioCachePath(item);
            if (!File.Exists(path))
            {
                byte[] data;
                try { data = StockHttp.Get(remote, timeout); }
                catch (SceneException) { return; }
                if (data.Length == 0 || data.Length >= 20_000_000) return;
                var part = path + ".part" + i;
                try
                {
                    File.WriteAllBytes(part, data);
                    File.Move(part, path, overwrite: false);
                }
                catch (IOException)
                {
                    try { File.Delete(part); } catch (IOException) { }
                    if (!File.Exists(path)) return;
                }
            }
            out_[i] = path;
        });
        return out_;
    }

    /// <summary>Removes a cached sound that turned out not to decode.</summary>
    public static void DiscardCachedSound(string path)
    {
        try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Keeps the preview cache to the 400 most recent files.</summary>
    static void PruneAudioCache()
    {
        try
        {
            var files = new DirectoryInfo(AudioCacheDir).GetFiles();
            if (files.Length <= 400) return;
            foreach (var f in files.OrderByDescending(f => f.LastWriteTimeUtc).Skip(400))
                try { f.Delete(); } catch (IOException) { }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    // MARK: Previews

    /// <summary>Downloads every result's thumbnail (in parallel), by index; null where none could be loaded. The bytes are
    /// a bitmap, or SVG for icons and SVG originals. Font results have none (see <see cref="GoogleFonts.PreviewFont"/>).
    /// Blocking.</summary>
    public static byte[]?[] Thumbnails(IReadOnlyList<StockItem> items, double timeout = 20)
    {
        var out_ = new byte[]?[items.Count];
        Parallel.For(0, items.Count, new ParallelOptions { MaxDegreeOfParallelism = 6 }, i => out_[i] = LoadThumbnail(items[i], timeout));
        return out_;
    }

    /// <summary>One result's thumbnail data. Openverse cannot thumbnail SVGs (HTTP 424), so for those, and for other
    /// small originals, it falls back to the original file. Blocking.</summary>
    public static byte[]? LoadThumbnail(StockItem item, double timeout = 20)
    {
        if (item.Kind == StockKind.Font) return null;
        if (item.ThumbnailUrl is { } u)
        {
            try { if (StockHttp.Get(u, timeout) is { Length: > 0 } d) return d; }
            catch (SceneException) { }
        }
        var pixels = (long)(item.Width ?? int.MaxValue / 2) * (item.Height ?? 2);
        if (item.Kind == StockKind.Video || item.DownloadUrl is not { } original
            || !(item.FileExtension == "svg" || pixels <= 1_500_000)) return null;
        try { return StockHttp.Get(original, timeout); }
        catch (SceneException) { return null; }
    }
}
