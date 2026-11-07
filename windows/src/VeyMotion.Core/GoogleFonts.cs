using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

/// <summary>Google Fonts (keyless): the family list comes from fonts.google.com/metadata/fonts (cached for a week) and
/// the font files from the CSS API, which serves static TrueType files per weight to clients that are not browsers.
/// Port of <c>GoogleFonts.swift</c> (the preview image is drawn by the app: see <see cref="PreviewFont"/>).</summary>
public static class GoogleFonts
{
    public sealed record FontFamily(string Name, string Category, IReadOnlyList<string> Styles, IReadOnlyList<string> Subsets,
                                    int Popularity, IReadOnlyList<string> Designers)
    {
        /// <summary>"400", "700", "400i"…</summary>
        public bool Vietnamese => Subsets.Contains("vietnamese");
        public List<int> Upright => Styles.Where(s => !s.EndsWith('i')).Select(s => int.TryParse(s, out var n) ? (int?)n : null)
            .OfType<int>().Order().ToList();
        public bool HasItalic => Styles.Any(s => s.EndsWith('i'));
    }

    public const string RefPrefix = "googlefonts:";
    static readonly Lock Gate = new();
    static List<FontFamily>? memory;
    static readonly TimeSpan MaxAge = TimeSpan.FromDays(7);

    static string CacheFile => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                                            "VeyMotion", "cache", "google-fonts.json");

    /// <summary>Every family, from memory, the disk cache or the network. Blocking.</summary>
    public static List<FontFamily> Families()
    {
        lock (Gate) { if (memory != null) return memory; }
        List<FontFamily>? list = null;
        try
        {
            var info = new FileInfo(CacheFile);
            if (info.Exists && DateTime.UtcNow - info.LastWriteTimeUtc < MaxAge) list = Parse(File.ReadAllBytes(CacheFile));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or SceneException) { }
        if (list == null || list.Count == 0)
        {
            var fresh = StockHttp.Get("https://fonts.google.com/metadata/fonts", 60);
            list = Parse(fresh);
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(CacheFile)!);
                var part = CacheFile + ".part";
                File.WriteAllBytes(part, fresh);
                File.Move(part, CacheFile, overwrite: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        lock (Gate) { memory = list; }
        return list;
    }

    public static List<FontFamily> Parse(byte[] data)
    {
        // The response may start with an anti-JSON-hijacking prefix.
        var start = Array.IndexOf(data, (byte)'{');
        JsonArray? list = null;
        if (start >= 0)
        {
            try { list = (JsonNode.Parse(data.AsSpan(start)) as JsonObject)?["familyMetadataList"] as JsonArray; }
            catch (JsonException) { }
        }
        if (list == null) throw new SceneException("Unexpected font list from Google Fonts");
        var out_ = new List<FontFamily>();
        foreach (var f in list.OfType<JsonObject>())
        {
            if (StockHttp.Str(f, "family") is not { } name || !(StockHttp.Bool(f, "isOpenSource") ?? true)) continue;
            var styles = f["fonts"] is JsonObject fonts ? fonts.Select(kv => kv.Key).ToList() : ["400"];
            styles.Sort(StyleCompare);
            out_.Add(new FontFamily(name, StockHttp.Str(f, "category") ?? "", styles, StockHttp.Strings(f, "subsets") ?? [],
                                    StockHttp.Int(f, "popularity") ?? 99_999, StockHttp.Strings(f, "designers") ?? []));
        }
        return out_;
    }

    /// <summary>Numeric-aware order ("100" &lt; "100i" &lt; "200" … &lt; "1000"), like <c>localizedStandardCompare</c>.</summary>
    static int StyleCompare(string a, string b)
    {
        static (long, string) Split(string s)
        {
            var n = 0;
            while (n < s.Length && char.IsDigit(s[n])) n++;
            return (n > 0 && long.TryParse(s[..n], out var v) ? v : -1, s[n..]);
        }
        var (na, ra) = Split(a);
        var (nb, rb) = Split(b);
        var c = na.CompareTo(nb);
        return c != 0 ? c : string.Compare(ra, rb, StringComparison.OrdinalIgnoreCase);
    }

    public static FontFamily Family(string name)
    {
        var key = Squash(name);
        return Families().FirstOrDefault(f => Squash(f.Name) == key)
            ?? throw new SceneException($"Google Fonts has no family '{name}'. Use search_stock kind \"font\".");
    }

    static string Squash(string s) => new(s.ToLowerInvariant().Where(c => !char.IsWhiteSpace(c)).ToArray());

    // MARK: Search

    static readonly Dictionary<string, string> CategoryWords = new()
    {
        ["serif"] = "Serif", ["sans"] = "Sans Serif", ["sansserif"] = "Sans Serif", ["sans-serif"] = "Sans Serif",
        ["display"] = "Display", ["decorative"] = "Display", ["handwriting"] = "Handwriting", ["handwritten"] = "Handwriting",
        ["script"] = "Handwriting", ["cursive"] = "Handwriting", ["calligraphy"] = "Handwriting", ["brush"] = "Handwriting",
        ["mono"] = "Monospace", ["monospace"] = "Monospace", ["code"] = "Monospace", ["terminal"] = "Monospace",
        // Moods
        ["elegant"] = "Serif", ["luxury"] = "Serif", ["classic"] = "Serif", ["editorial"] = "Serif", ["wedding"] = "Handwriting",
        ["modern"] = "Sans Serif", ["clean"] = "Sans Serif", ["minimal"] = "Sans Serif", ["tech"] = "Sans Serif",
        ["corporate"] = "Sans Serif", ["geometric"] = "Sans Serif", ["playful"] = "Display", ["fun"] = "Display",
        ["poster"] = "Display", ["headline"] = "Display", ["retro"] = "Display", ["cute"] = "Handwriting", ["signature"] = "Handwriting",
    };
    static readonly HashSet<string> VietnameseWords = ["vietnamese", "vietnam", "việt", "viet", "tiếng"];
    static readonly HashSet<string> AnyWords = ["*", "any", "all", "popular", "font", "fonts", "typeface"];

    /// <summary>Matches family names, categories ("serif", "handwriting"…) and moods ("elegant", "playful"…), most used
    /// first. Blocking.</summary>
    public static List<StockItem> Search(string query, int page, bool vietnamese, int pageSize = 20) =>
        Matching(query, Families(), vietnamese).Skip((Math.Max(1, page) - 1) * pageSize).Take(pageSize).Select(Item).ToList();

    public static List<FontFamily> Matching(string query, IReadOnlyList<FontFamily> all, bool vietnamese)
    {
        var words = query.ToLowerInvariant().Split([' ', ','], StringSplitOptions.RemoveEmptyEntries).ToList();
        var vi = vietnamese;
        var categories = new HashSet<string>();
        words.RemoveAll(w =>
        {
            if (VietnameseWords.Contains(w)) { vi = true; return true; }
            if (CategoryWords.TryGetValue(w, out var c)) { categories.Add(c); return true; }
            return AnyWords.Contains(w);
        });
        var list = all.Where(f => !vi || f.Vietnamese).ToList();
        if (words.Count > 0)
        {
            var phrase = string.Join(" ", words);
            var byName = list.Where(f =>
            {
                var n = f.Name.ToLowerInvariant();
                return n.Contains(phrase) || words.All(n.Contains);
            }).ToList();
            // Unknown words with a category: just the category.
            list = byName.Count == 0 && categories.Count > 0 ? list : byName;
        }
        var inCategory = list.Where(f => categories.Contains(f.Category)).ToList();
        if (inCategory.Count > 0) list = inCategory;
        // Names that start with (or contain) the whole query come first, then the most used.
        var full = query.ToLowerInvariant().Trim();
        int Rank(FontFamily f)
        {
            var n = f.Name.ToLowerInvariant();
            return n.StartsWith(full) ? 0 : n.Contains(full) ? 1 : 2;
        }
        return list.OrderBy(Rank).ThenBy(f => f.Popularity).ToList();
    }

    public static StockItem Item(FontFamily f)
    {
        var up = f.Upright;
        var weights = up.Count == 0 ? "italic only" : up.Count == 1 ? $"weight {up[0]}" : $"weights {up[0]}–{up[^1]}";
        if (f.HasItalic && up.Count > 0) weights += " + italic";
        var by = string.Join(", ", f.Designers.Take(3));
        var credit = new AssetCredit
        {
            Title = $"{f.Name} font", Creator = by.Length == 0 ? null : by,
            License = "Open font license (OFL / Apache, via Google Fonts)",
            LicenseURL = "https://fonts.google.com/attribution",
            SourceURL = "https://fonts.google.com/specimen/" + f.Name.Replace(" ", "+"),
            Attribution = $"Font \"{f.Name}\"{(by.Length == 0 ? "" : $" by {by}")}, from Google Fonts.",
            RequiresAttribution = false, Ref = RefPrefix + f.Name,
        };
        var genres = new List<string> { f.Category, weights };
        if (f.Vietnamese) genres.Add("Vietnamese ✓");
        return new StockItem
        {
            Ref = RefPrefix + f.Name, Kind = StockKind.Font, Title = f.Name, FileExtension = "ttf", Credit = credit,
            Genres = genres, FontStyles = [.. f.Styles],
        };
    }

    // MARK: Files

    /// <summary>CSS API URL for some styles ("400", "700i"…), optionally only for the glyphs of <paramref name="text"/>
    /// (a tiny preview font).</summary>
    public static string CssUrl(string family, IEnumerable<string> styles, string? text = null)
    {
        var parsed = styles.Select(s =>
        {
            var italic = s.EndsWith('i');
            return int.TryParse(italic ? s[..^1] : s, out var w) ? ((int Ital, int W)?)(italic ? 1 : 0, w) : null;
        }).OfType<(int Ital, int W)>().OrderBy(p => p.Ital).ThenBy(p => p.W).ToList();
        var spec = family;
        if (parsed.Any(p => p.Ital == 1))
            spec += ":ital,wght@" + string.Join(";", parsed.Select(p => $"{p.Ital},{p.W}"));
        else if (!(parsed.Count == 1 && parsed[0].W == 400))
            spec += ":wght@" + string.Join(";", parsed.Select(p => p.W.ToString()));
        var q = new List<(string, string)> { ("family", spec) };
        if (text != null) q.Add(("text", text));
        return "https://fonts.googleapis.com/css2" + StockHttp.Query([.. q]);
    }

    /// <summary>The @font-face rules of a CSS API response.</summary>
    public static List<(int Weight, bool Italic, string Url)> ParseCss(string css)
    {
        var out_ = new List<(int, bool, string)>();
        foreach (var block in css.Split("@font-face").Skip(1))
        {
            string? Value(string key)
            {
                var i = block.IndexOf(key + ":", StringComparison.Ordinal);
                if (i < 0) return null;
                var rest = block[(i + key.Length + 1)..];
                var end = rest.IndexOf(';');
                return (end < 0 ? rest : rest[..end]).Trim(' ', '\t');
            }
            if (Value("src") is not { } src) continue;
            var open = src.IndexOf("url(", StringComparison.Ordinal);
            if (open < 0) continue;
            var close = src.IndexOf(')', open + 4);
            if (close < 0) continue;
            var url = src[(open + 4)..close];
            if (!Uri.TryCreate(url, UriKind.Absolute, out _)) continue;
            var weight = int.TryParse(Value("font-weight") ?? "400", out var w) ? w : 400;
            out_.Add((weight, Value("font-style") == "italic", url));
        }
        return out_;
    }

    static readonly Dictionary<int, string> StyleNames = new()
    {
        [100] = "Thin", [200] = "ExtraLight", [300] = "Light", [400] = "Regular", [500] = "Medium",
        [600] = "SemiBold", [700] = "Bold", [800] = "ExtraBold", [900] = "Black",
    };

    /// <summary>Downloads a family's styles (default: every upright weight) into the library through
    /// <paramref name="import"/> (type folder "fonts", replacing older files). Register the fonts afterwards. Blocking.</summary>
    public static List<StockAsset> ImportFamily(FontFamily f, IReadOnlyList<string>? requested, string? folder, StockImporter import)
    {
        var wanted = (requested is { Count: > 0 } ? requested : f.Styles.Where(s => !s.EndsWith('i')))
            .Select(s => s.ToLowerInvariant().Replace("italic", "i").Replace(" ", "")).ToList();
        if (wanted.Count == 0) wanted = [.. f.Styles];
        var missing = wanted.Where(s => !f.Styles.Contains(s)).ToList();
        if (missing.Count > 0)
            throw new SceneException($"{f.Name} has no style {string.Join(", ", missing)}. Available: {string.Join(", ", f.Styles)} (i = italic).");
        var faces = ParseCss(Encoding.UTF8.GetString(StockHttp.Get(CssUrl(f.Name, wanted))));
        if (faces.Count == 0) throw new SceneException($"Google Fonts returned no files for {f.Name}");
        var baseName = new string(f.Name.Where(char.IsLetterOrDigit).ToArray());
        var item = Item(f);
        var out_ = new List<StockAsset>();
        foreach (var face in faces)
        {
            var style = StyleNames.TryGetValue(face.Weight, out var sn) ? sn : face.Weight.ToString();
            var fileName = $"{baseName}-{(face.Italic ? (face.Weight == 400 ? "Italic" : style + "Italic") : style)}.ttf";
            var url = face.Url;
            out_.Add(import(new StockImportRequest(fileName, folder, "fonts", StockKind.Font, f.Name, item.Credit,
                                                   ReuseExisting: true, Overwrite: true, () => StockHttp.Get(url, 60))));
        }
        return out_;
    }

    // MARK: Preview

    /// <summary>What the app needs to draw a font result's preview (macOS draws it with CoreText): the family name, a
    /// sample line, and a tiny subset font (TTF) with just their glyphs. White on dark, 640×170 in Swift. Blocking.</summary>
    public static (string Name, string Sample, byte[] FontData)? PreviewFont(StockItem item, double timeout = 20)
    {
        if (!item.Ref.StartsWith(RefPrefix)) return null;
        var name = item.Ref[RefPrefix.Length..];
        var sample = item.Genres.Contains("Vietnamese ✓") ? "Chữ Việt đẹp quá" : "The quick brown fox";
        var upright = item.FontStyles.Where(s => !s.EndsWith('i')).ToList();
        var style = upright.Contains("400") ? "400" : upright.FirstOrDefault() ?? item.FontStyles.FirstOrDefault() ?? "400";
        try
        {
            var css = Encoding.UTF8.GetString(StockHttp.Get(CssUrl(name, [style], name + sample), timeout));
            if (ParseCss(css).FirstOrDefault() is not { Url: { } fontUrl }) return null;
            return (name, sample, StockHttp.Get(fontUrl, timeout));
        }
        catch (SceneException) { return null; }
    }
}
