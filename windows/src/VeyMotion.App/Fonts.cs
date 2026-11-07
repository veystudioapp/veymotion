using System.Text;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Text;
using VeyMotion.Core;
using VeyMotion.Mcp;

namespace VeyMotion.App;

/// <summary>
/// Fonts through DirectWrite: the installed ones plus font files (.ttf/.otf/.ttc) in the active and shared asset
/// libraries, so preview, export and the CLI use the same fonts. Port target of <c>FontLibrary</c>'s CoreText side
/// (<c>Fonts.swift</c>). Library fonts are drawn by Win2D from their file ("file:///…#Family").
/// </summary>
public sealed class DirectWriteFonts : IFontSource
{
    public static readonly DirectWriteFonts Shared = new();
    public static readonly FontCatalog Catalog = new(Shared);

    sealed record Face(FontFace Info, string Family, string FullName, string? File, CanvasFontFace Native);

    readonly Lock _gate = new();
    List<Face>? _faces;
    string _libraryKey = "";
    DateTime _checked;

    /// <summary>Every face, rescanning the libraries' font files at most every 2 s.</summary>
    List<Face> Faces()
    {
        lock (_gate)
        {
            if (_faces != null && DateTime.UtcNow - _checked < TimeSpan.FromSeconds(2)) return _faces;
            _checked = DateTime.UtcNow;
            var files = LibraryFontFiles();
            var key = string.Join("|", files.Select(f => f + File.GetLastWriteTimeUtc(f).Ticks));
            if (_faces != null && key == _libraryKey) return _faces;
            _libraryKey = key;
            var list = new List<Face>();
            foreach (var f in CanvasFontSet.GetSystemFontSet().Fonts) Add(list, f, null);
            foreach (var file in files)
            {
                try
                {
                    using var set = new CanvasFontSet(new Uri(file));
                    foreach (var f in set.Fonts) Add(list, f, file);
                }
                catch (Exception e) when (e is ArgumentException or System.Runtime.InteropServices.COMException or UriFormatException) { }
            }
            _faces = list;
            Catalog.Invalidate();
            return list;
        }
    }

    static void Add(List<Face> list, CanvasFontFace f, string? file)
    {
        static string Pick(IReadOnlyDictionary<string, string> names) =>
            names.TryGetValue("en-us", out var en) ? en : names.Values.FirstOrDefault() ?? "";
        var family = Pick(f.FamilyNames);
        if (family.Length == 0) return;
        var style = Pick(f.FaceNames);
        var ps = Pick(f.GetInformationalStrings(CanvasFontInformation.PostscriptName));
        var full = Pick(f.GetInformationalStrings(CanvasFontInformation.FullName));
        if (ps.Length == 0) ps = (family + "-" + style).Replace(" ", "");
        var italic = f.Style != Windows.UI.Text.FontStyle.Normal;
        list.Add(new Face(new FontFace(ps, style, f.Weight.Weight, italic), family, full.Length > 0 ? full : $"{family} {style}", file, f));
    }

    static List<string> LibraryFontFiles()
    {
        var dirs = new[] { AssetStore.Directory, AssetStore.SharedDirectory }.Distinct(StringComparer.OrdinalIgnoreCase);
        var output = new List<string>();
        foreach (var d in dirs.Where(Directory.Exists))
        {
            try
            {
                output.AddRange(Directory.EnumerateFiles(d, "*.*", SearchOption.AllDirectories)
                    .Where(f => Path.GetExtension(f).ToLowerInvariant() is ".ttf" or ".otf" or ".ttc"));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        return output;
    }

    public IReadOnlyList<string> Families() => Faces().Select(f => f.Family).Distinct().ToList();

    public IReadOnlyList<FontFace> FacesOf(string family) => Faces().Where(f => f.Family == family).Select(f => f.Info).ToList();

    public IReadOnlyCollection<string> LibraryFamilies() => Faces().Where(f => f.File != null).Select(f => f.Family).ToHashSet();

    public string? FaceNamed(string name) =>
        Faces().FirstOrDefault(f => f.Info.PostScriptName.Equals(name, StringComparison.OrdinalIgnoreCase)
            || f.FullName.Equals(name, StringComparison.OrdinalIgnoreCase))?.Info.PostScriptName;

    public string MissingCharacters(string text, string postScriptName)
    {
        if (Faces().FirstOrDefault(f => f.Info.PostScriptName == postScriptName) is not { } face) return "";
        var missing = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var rune in text.EnumerateRunes())
            if (!Rune.IsWhiteSpace(rune) && !Rune.IsControl(rune) && !face.Native.HasCharacter((uint)rune.Value)) missing.Add(rune.ToString());
        return string.Concat(missing);
    }

    /// <summary>What Win2D should use for a layer's fontName + fontWeight: the family name of an installed face, or the
    /// file URI of a library face; null = the default font.</summary>
    public (string Family, ushort Weight, bool Italic)? Resolve(string? fontName, string fontWeight)
    {
        if (string.IsNullOrWhiteSpace(fontName) || Catalog.Resolve(fontName, fontWeight) is not { } ps) return null;
        if (Faces().FirstOrDefault(f => f.Info.PostScriptName == ps) is not { } face) return null;
        var family = face.File != null ? $"{new Uri(face.File).AbsoluteUri}#{face.Family}" : face.Family;
        return (family, (ushort)face.Info.Weight, face.Info.Italic);
    }
}

/// <summary>Font warnings for the layer tools, through the font catalog (installed + library fonts).</summary>
sealed class FontInfo : IFontInfo
{
    static FontCatalog C => DirectWriteFonts.Catalog;

    public bool Exists(string name) => C.Resolve(name, "regular") != null;

    public string MissingCharacters(string text, string name, string weight) =>
        C.Resolve(name, weight) is { } ps ? C.MissingCharacters(text, ps) : "";

    public IReadOnlyList<string> Suggestions(string name) => C.Suggestions(name);
}
