namespace VeyMotion.Core;

/// <summary>One face of a font family. Weight is CSS-style, 100 (thin) … 900 (black).</summary>
public readonly record struct FontFace(string PostScriptName, string Style, int Weight, bool Italic);

/// <summary>The platform's font system (DirectWrite in the app; CoreText on macOS): installed fonts plus the asset
/// libraries' font files, registered for the process.</summary>
public interface IFontSource
{
    /// <summary>Every usable family name (installed + library fonts), unsorted.</summary>
    IReadOnlyList<string> Families();

    /// <summary>Faces whose family name is exactly <paramref name="family"/> (no folding of static weight families).
    /// <see cref="FontFace.Weight"/> is the font's own weight.</summary>
    IReadOnlyList<FontFace> FacesOf(string family);

    /// <summary>Families that come from font files in the asset libraries.</summary>
    IReadOnlyCollection<string> LibraryFamilies();

    /// <summary>The PostScript name of the face with this PostScript or full name, or null.</summary>
    string? FaceNamed(string name);

    /// <summary>Characters of <paramref name="text"/> (no whitespace) the face has no glyph for, sorted, no repeats.</summary>
    string MissingCharacters(string text, string postScriptName);
}

/// <summary>Font lookup for text layers. Port of the platform-neutral part of <c>FontLibrary</c> (<c>Fonts.swift</c>):
/// listing, folding static weight families ("Be Vietnam Pro Black" is a weight of "Be Vietnam Pro"), resolving
/// <c>fontName</c> + <c>fontWeight</c>, suggestions and weight parsing. Registration, descriptors and glyph checks are
/// the <see cref="IFontSource"/>'s job. Call <see cref="Invalidate"/> after fonts are added.</summary>
public sealed class FontCatalog(IFontSource source)
{
    readonly Lock gate = new();
    readonly Dictionary<string, string?> resolved = [];
    readonly Dictionary<string, List<FontFace>> faceCache = [];
    Dictionary<string, string>? familyIndex;
    List<string>? allFamilies;

    public IFontSource Source => source;

    /// <summary>Drops cached lookups (call after registering new font files).</summary>
    public void Invalidate()
    {
        lock (gate)
        {
            resolved.Clear();
            faceCache.Clear();
            familyIndex = null;
            allFamilies = null;
        }
    }

    /// <summary>Every family that can be used (installed + library fonts), sorted.</summary>
    public List<string> AllFamilies()
    {
        lock (gate) { if (allFamilies != null) return allFamilies; }
        var list = source.Families().Where(n => !n.StartsWith('.')).Distinct()
            .OrderBy(n => n, StringComparer.OrdinalIgnoreCase).ToList();
        lock (gate) { allFamilies = list; }
        return list;
    }

    /// <summary>Families to offer: like <see cref="AllFamilies"/>, without the per-weight families of static font files.</summary>
    public List<string> ListedFamilies()
    {
        var all = AllFamilies();
        var set = all.ToHashSet();
        return all.Where(f => Subfamily(f, set) == null).ToList();
    }

    public IReadOnlyCollection<string> LibraryFamilies() => source.LibraryFamilies();

    static readonly Dictionary<string, int> SuffixWeights = new()
    {
        ["thin"] = 100, ["hairline"] = 100, ["extralight"] = 200, ["ultralight"] = 200, ["light"] = 300,
        ["book"] = 400, ["medium"] = 500, ["semibold"] = 600, ["demibold"] = 600, ["extrabold"] = 800,
        ["ultrabold"] = 800, ["black"] = 900, ["heavy"] = 900,
    };

    /// <summary>"Be Vietnam Pro Black" → ("Be Vietnam Pro", 900) when that base family exists. Static font files name
    /// weights other than regular and bold as families of their own.</summary>
    public static (string Base, int Weight)? Subfamily(string name, IReadOnlySet<string> families)
    {
        var words = name.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        foreach (var n in new[] { 1, 2 })
        {
            if (words.Length <= n) continue;
            var baseName = string.Join(" ", words[..^n]);
            var suffix = string.Concat(words[^n..]).ToLowerInvariant();
            if (SuffixWeights.TryGetValue(suffix, out var w) && families.Contains(baseName)) return (baseName, w);
        }
        return null;
    }

    /// <summary>The faces of a family (including its static weight families), lightest first.</summary>
    public List<FontFace> Faces(string family)
    {
        lock (gate) { if (faceCache.TryGetValue(family, out var cached)) return cached; }
        var sources = source.FacesOf(family).Select(f => (Face: f, Forced: (int?)null)).ToList();
        var all = AllFamilies().ToHashSet();
        foreach (var other in all)
        {
            if (!other.StartsWith(family + " ")) continue;
            if (Subfamily(other, all) is { } sub && sub.Base == family)
                sources.AddRange(source.FacesOf(other).Select(f => (Face: f, Forced: (int?)sub.Weight)));
        }
        var seen = new HashSet<string>();
        var out_ = new List<FontFace>();
        foreach (var (f, forced) in sources)
        {
            if (!seen.Add(f.PostScriptName)) continue;
            var style = f.Style.ToLowerInvariant();
            var italic = f.Italic || style.Contains("italic") || style.Contains("oblique");
            out_.Add(f with { Weight = forced ?? WeightFromStyle(f.Style) ?? f.Weight, Italic = italic });
        }
        out_ = out_.OrderBy(f => f.Weight).ThenBy(f => f.Italic ? 1 : 0).ToList();
        lock (gate) { faceCache[family] = out_; }
        return out_;
    }

    /// <summary>PostScript name for <paramref name="name"/> (family, PostScript or full name) at a
    /// <c>fontWeight</c> such as "bold", "light italic" or "600"; null when no such font exists.</summary>
    public string? Resolve(string name, string fontWeight)
    {
        var key = name + "|" + fontWeight;
        lock (gate) { if (resolved.TryGetValue(key, out var hit)) return hit; }
        var result = Lookup(name, fontWeight);
        lock (gate) { resolved[key] = result; }
        return result;
    }

    string? Lookup(string raw, string fontWeight)
    {
        var name = raw.Trim();
        if (name.Length == 0) return null;
        if (FamilyName(name) is { } family)
        {
            var want = ParseWeight(fontWeight);
            var faces = Faces(family);
            if (faces.Count > 0) return faces.MinBy(f => Score(f, want)).PostScriptName;
        }
        // PostScript or full name of one face.
        return source.FaceNamed(name);
    }

    static int Score(FontFace f, (int Weight, bool Italic) want) => Math.Abs(f.Weight - want.Weight) + (f.Italic == want.Italic ? 0 : 1000);

    /// <summary>The family whose name matches, ignoring case, spaces, "-" and "_".</summary>
    public string? FamilyName(string name)
    {
        Dictionary<string, string>? index;
        lock (gate) { index = familyIndex; }
        if (index == null)
        {
            index = [];
            foreach (var f in AllFamilies()) index.TryAdd(Squash(f), f);
            lock (gate) { familyIndex = index; }
        }
        return index.GetValueOrDefault(Squash(name));
    }

    static string Squash(string s) => new(s.ToLowerInvariant().Where(c => !char.IsWhiteSpace(c) && c != '-' && c != '_').ToArray());

    /// <summary>Families with names close to <paramref name="name"/>, best first.</summary>
    public List<string> Suggestions(string name, int limit = 5)
    {
        var q = Squash(name);
        if (q.Length == 0) return [];
        var all = ListedFamilies();
        var contains = all.Where(f => Squash(f).Contains(q) || q.Contains(Squash(f)));
        var ranked = all.OrderBy(f => Distance(q, Squash(f)));
        return contains.Concat(ranked).Distinct().Take(limit).ToList();
    }

    /// <summary>Levenshtein distance.</summary>
    public static int Distance(string a, string b)
    {
        if (a.Length == 0) return b.Length;
        var prev = Enumerable.Range(0, b.Length + 1).ToArray();
        for (var i = 1; i <= a.Length; i++)
        {
            var cur = new int[b.Length + 1];
            cur[0] = i;
            for (var j = 1; j <= b.Length; j++)
                cur[j] = Math.Min(Math.Min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
            prev = cur;
        }
        return prev[b.Length];
    }

    /// <summary>Characters of the text the font has no glyph for (another font would fill them in).</summary>
    public string MissingCharacters(string text, string postScriptName) => source.MissingCharacters(text, postScriptName);

    /// <summary>Letters a font needs for Vietnamese text.</summary>
    public const string VietnameseSample = "ĂăÂâĐđÊêÔôƠơƯưẠạẢảẤấẦầẨẩẪẫẬậẮắẰằẲẳẴẵẶặẸẹẺẻẼẽẾếỀềỂểỄễỆệỈỉỊịỌọỎỏỐốỒồỔổỖỗỘộỚớỜờỞởỠỡỢợỤụỦủỨứỪừỬửỮữỰựỲỳỴỵỶỷỸỹ";

    public bool SupportsVietnamese(string family)
    {
        var faces = Faces(family);
        if (faces.Count == 0) return false;
        var face = faces.FirstOrDefault(f => !f.Italic, faces[0]);
        return MissingCharacters(VietnameseSample, face.PostScriptName).Length == 0;
    }

    // MARK: Weights

    /// <summary>"bold" → 700, "light italic" → (300, italic), "600" → 600. Unknown words mean regular.</summary>
    public static (int Weight, bool Italic) ParseWeight(string s)
    {
        var lower = s.ToLowerInvariant();
        var italic = lower.Contains("italic") || lower.Contains("oblique");
        var digits = new string(lower.Where(char.IsDigit).ToArray());
        if (int.TryParse(digits, out var n) && n is >= 1 and <= 1000) return (n, italic);
        return (WeightFromStyle(lower) ?? 400, italic);
    }

    static readonly (string Word, int Weight)[] StyleWeights =
    [
        ("extralight", 200), ("ultralight", 200), ("hairline", 100), ("thin", 100),
        ("semibold", 600), ("demibold", 600), ("extrabold", 800), ("ultrabold", 800),
        ("light", 300), ("medium", 500), ("bold", 700), ("black", 900), ("heavy", 900),
        ("regular", 400), ("normal", 400), ("book", 400), ("roman", 400),
    ];

    /// <summary>Weight named in a style ("Semibold Italic" → 600), or null.</summary>
    public static int? WeightFromStyle(string s)
    {
        var key = s.ToLowerInvariant().Replace(" ", "").Replace("-", "");
        foreach (var (word, weight) in StyleWeights) if (key.Contains(word)) return weight;
        return null;
    }

    /// <summary>A -1…1 weight trait (CoreText) to the nearest CSS weight.</summary>
    public static int WeightFromTrait(double trait)
    {
        (double T, int W)[] table = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)];
        return table.MinBy(e => Math.Abs(e.T - trait)).W;
    }
}
