using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

/// <summary>A downloaded sound's profile for the <c>import_stock</c> reply (<c>SoundProfile.summary</c>; the bursts
/// only when its shape is "multiple").</summary>
public sealed record StockSoundInfo(string Summary, IReadOnlyList<(double Start, double End, double Peak)> SeparateSounds);

/// <summary>The <c>search_stock</c>, <c>import_stock</c> and <c>list_fonts</c> tool handlers (port of their cases in
/// <c>MCPServer.swift</c>). Each returns the MCP <c>tools/call</c> result (<c>{"content": [...]}</c>) and throws
/// <see cref="SceneException"/> for tool errors.</summary>
public static class StockTools
{
    /// <summary><c>search_stock</c>. Optional platform parts:
    /// <paramref name="contactSheet"/>: results → numbered PNG grid (<c>StockSearch.contactSheet</c>; use
    /// <see cref="StockSearch.Thumbnails"/> and <see cref="GoogleFonts.PreviewFont"/>);
    /// <paramref name="soundSummary"/>: cached sound file → <c>SoundProfile.cached(path)?.summary</c>, null when it does
    /// not decode (the file is then dropped from the cache);
    /// <paramref name="soundSheet"/>: the profiled files by result (null = none) → <c>SoundProfile.sheet</c> PNG;
    /// <paramref name="synthKindMatching"/>: query → <c>SynthKind.matching(query)?.rawValue</c>.</summary>
    public static JsonObject SearchStock(JsonObject a,
                                         Func<IReadOnlyList<StockItem>, byte[]?>? contactSheet = null,
                                         Func<string, string?>? soundSummary = null,
                                         Func<IReadOnlyList<string?>, byte[]?>? soundSheet = null,
                                         Func<string, string?>? synthKindMatching = null)
    {
        var query = Str(a, "query");
        var kind = StockKindExtensions.Parse(StockHttp.Str(a, "kind") ?? "photo")
            ?? throw new SceneException("`kind` must be one of [" + string.Join(", ", StockKindExtensions.All.Select(k => $"\"{k.Raw()}\"")) + "]");
        var page = Math.Max(1, (int)(Number(a["page"]) ?? 1));
        var maxDuration = Number(a["maxDuration"]);
        var items = StockSearch.Search(query, kind, page, StockHttp.Bool(a, "vietnamese") ?? false, maxDuration, StockHttp.Str(a, "orientation"));
        if (Number(a["limit"]) is { } limit && limit > 0) items = items.Take((int)limit).ToList();
        if (items.Count == 0)
        {
            var msg = $"No {kind.Raw()} results for '{query}'. Try a simpler or English query.";
            if (kind == StockKind.Sound)
                msg += $" Only sounds up to {(maxDuration ?? StockSearch.DefaultSoundMaxDuration).ToString("0", CultureInfo.InvariantCulture)} s are listed (maxDuration). "
                    + "generate_sfx makes whoosh/pop/click/ding/riser/impact… without searching.";
            return Text(msg);
        }
        var preview = StockHttp.Bool(a, "preview") ?? true;
        // Sound profiles: files downloaded into the cache, then profiled.
        var profiled = new string?[items.Count];
        var summaries = new string?[items.Count];
        if (kind == StockKind.Sound && preview && soundSummary != null)
        {
            var files = StockSearch.SoundFiles(items);
            for (var i = 0; i < items.Count; i++)
            {
                if (files[i] is not { } f) continue;
                if (soundSummary(f) is { } s) { summaries[i] = s; profiled[i] = f; }
                else StockSearch.DiscardCachedSound(f);
            }
        }
        var lines = new List<string> { $"{items.Count} {kind.Raw()} results for '{query}' (page {page}). Import one with import_stock {{\"ref\": …}}:" };
        if (kind == StockKind.Sound && synthKindMatching?.Invoke(query) is { } synth)
            lines.Insert(0, $"Tip: generate_sfx {{\"kind\": \"{synth}\", \"hitAt\": …}} makes this sound to measure (length, pitch, exact hit) — "
                         + "prefer it unless you need a real recording.");
        for (var i = 0; i < items.Count; i++)
        {
            lines.Add($"{i + 1}. {items[i].Summary}");
            if (summaries[i] is { } s) lines.Add($"   sound: {s}");
        }
        var content = new JsonArray();
        if (kind == StockKind.Sound && profiled.Any(p => p != null) && soundSheet?.Invoke(profiled) is { } sheet)
        {
            lines.Add("The image shows each sound's waveform (dB scale, numbered in the same order): orange = main peak, "
                      + "blue bands = separate sounds. For a one-shot effect pick a single clear shape that fits the motion: "
                      + "hit = sharp start, whoosh = swell in the middle, riser = builds to the end.");
            content.Add(Image(sheet));
        }
        else if (!kind.IsAudio() && preview && contactSheet?.Invoke(items) is { } png)
        {
            lines.Add(kind == StockKind.Font ? "The image shows each font's name and a sample, numbered in the same order."
                      : "The image shows the results numbered in the same order.");
            content.Add(Image(png));
        }
        content.Add(new JsonObject { ["type"] = "text", ["text"] = string.Join("\n", lines) });
        return new JsonObject { ["content"] = content };
    }

    /// <summary><c>import_stock</c>. <paramref name="importAsset"/> writes files into the asset library (see
    /// <see cref="StockImportRequest"/>). Optional: <paramref name="fontFaces"/>: family → its faces once the imported
    /// files are registered (<c>FontLibrary.faces(of:)</c>; register/refresh inside it); without it the downloaded styles
    /// are listed. <paramref name="soundInfo"/>: imported file → its <c>SoundProfile</c> summary.</summary>
    public static JsonObject ImportStock(JsonObject a, StockImporter importAsset,
                                         Func<string, IReadOnlyList<FontFace>>? fontFaces = null,
                                         Func<string, StockSoundInfo?>? soundInfo = null)
    {
        var item = StockSearch.Item(Str(a, "ref"));
        var folder = StockHttp.Str(a, "folder");
        if (item.Kind == StockKind.Font)
        {
            var styles = (a["weights"] as JsonArray)?.Where(n => n != null).Select(n => n!.ToString()).ToList();
            var files = StockSearch.ImportFont(item, importAsset, styles, folder);
            var lines = new List<string>
            {
                $"Imported the font {item.Title}: {string.Join(", ", files.Select(f => f.Name))}",
                $"license: {item.Credit.License} (no credit needed)",
            };
            List<string> weights;
            if (fontFaces != null)
                weights = fontFaces(item.Title).Select(f => $"{f.Weight}{(f.Italic ? " italic" : "")}").ToList();
            else
            {
                var chosen = styles is { Count: > 0 } ? styles : item.FontStyles.Where(s => !s.EndsWith('i')).ToList();
                weights = chosen.Select(s => s.ToLowerInvariant().Replace("italic", "i").Replace(" ", ""))
                    .Select(s => s.EndsWith('i') ? s[..^1] + " italic" : s).ToList();
            }
            if (weights.Count == 0)
                lines.Add("Warning: the files did not register as a font. Try another family.");
            else
                lines.Add($"Use it: \"fontName\": \"{item.Title}\" with fontWeight one of: {string.Join(", ", weights)} (or names like regular/bold; add \" italic\" for italics).");
            return Text(string.Join("\n", lines));
        }
        var asset = StockSearch.ImportItem(item, importAsset, StockHttp.Str(a, "name"), folder, StockHttp.Str(a, "color"),
                                           (int)(Number(a["size"]) ?? 512));
        var reply = new List<string> { $"Imported '{asset.Name}' ({asset.Summary})", $"path: {asset.Path}", $"license: {item.Credit.License}" };
        if (item.Credit.RequiresAttribution)
            reply.Add($"Credit required — include in the video or its description: {item.Credit.Attribution}");
        var path = JsonString(asset.Path);
        if (item.Kind == StockKind.Video)
            reply.Add($"Next: add_layer {{\"layer\": {{\"type\": \"video\", \"path\": {path}, \"start\": …}}}} "
                      + "(size it to cover the frame; muted with \"volume\": 0 if its sound is not wanted).");
        else if (item.Kind == StockKind.Music)
            reply.Add($"Next: add_audio {{\"path\": {path}, \"role\": \"music\", \"start\": 0, \"end\": <scene duration>, \"volume\": 0.6, \"fadeIn\": 0.5, \"fadeOut\": 1.5, \"duckTo\": 0.25}}");
        else if (item.Kind == StockKind.Sound)
        {
            if (soundInfo?.Invoke(asset.Path) is { } p)
            {
                reply.Add($"Sound: {p.Summary}");
                if (p.SeparateSounds.Count > 0)
                {
                    var list = p.SeparateSounds.Select((b, i) => string.Format(CultureInfo.InvariantCulture, "{0}: {1:0.00}–{2:0.00}s (peak {3:0.00}s)",
                                                                                 i + 1, b.Start, b.End, b.Peak));
                    reply.Add("Separate sounds: " + string.Join("; ", list) + ". Choose one with \"hit\": <number>.");
                }
            }
            reply.Add($"Next: add_audio {{\"path\": {path}, \"role\": \"sfx\", \"hitAt\": <scene time the peak should land>}} "
                      + "(skips leading silence and starts early so the peak lands on that frame).");
        }
        return Text(string.Join("\n", reply));
    }

    /// <summary><c>list_fonts</c>: library fonts first, then installed families, with their weights.</summary>
    public static JsonObject ListFonts(JsonObject a, FontCatalog fonts) =>
        Text(FontList(StockHttp.Str(a, "query") ?? "", StockHttp.Bool(a, "vietnamese") ?? false, (int)(Number(a["limit"]) ?? 80), fonts));

    public static string FontList(string query, bool vietnamese, int limit, FontCatalog fonts)
    {
        var q = query.ToLowerInvariant().Trim();
        var library = fonts.LibraryFamilies().ToHashSet();
        var families = fonts.ListedFamilies().Where(f => q.Length == 0 || f.ToLowerInvariant().Contains(q)).ToList();
        if (vietnamese) families = families.Where(fonts.SupportsVietnamese).ToList();
        families = families.OrderBy(f => library.Contains(f) ? 0 : 1).ThenBy(f => f, StringComparer.Ordinal).ToList();
        string Describe(string f)
        {
            var faces = fonts.Faces(f);
            var weights = faces.Where(x => !x.Italic).Select(x => x.Weight).Distinct().Order().Select(w => w.ToString()).ToList();
            var italic = faces.Any(x => x.Italic);
            return $"- {f} — {(weights.Count == 0 ? "italic" : string.Join(" ", weights))}{(italic && weights.Count > 0 ? " + italic" : "")}"
                + (library.Contains(f) ? " [asset library]" : "");
        }
        if (families.Count == 0)
            return $"No fonts match '{query}'{(vietnamese ? " with Vietnamese letters" : "")}. search_stock kind \"font\" finds Google fonts to import.";
        var shown = families.Take(Math.Max(1, limit)).ToList();
        var lines = new List<string>
        {
            $"{families.Count} font families{(vietnamese ? " with Vietnamese letters" : "")}{(q.Length == 0 ? "" : $" matching '{query}'")}"
            + (families.Count > shown.Count ? $" (first {shown.Count}; use query to narrow)" : "")
            + ". Use the family as fontName and pick a weight with fontWeight (numbers are CSS weights):",
        };
        lines.AddRange(shown.Select(Describe));
        return string.Join("\n", lines);
    }

    // MARK: Helpers

    static JsonObject Text(string s) => new() { ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = s }) };

    static JsonObject Image(byte[] png) => new() { ["type"] = "image", ["data"] = Convert.ToBase64String(png), ["mimeType"] = "image/png" };

    /// <summary>A path as a JSON string (Windows backslashes escaped), so the suggested tool call is valid JSON.</summary>
    static string JsonString(string s) => JsonSerializer.Serialize(s, RelaxedJson);

    static readonly JsonSerializerOptions RelaxedJson = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    static string Str(JsonObject a, string key) =>
        StockHttp.Str(a, key) is { Length: > 0 } s ? s : throw new SceneException($"`{key}` must be a non-empty string");

    static double? Number(JsonNode? n) => n switch
    {
        JsonValue v when v.GetValueKind() == JsonValueKind.Number => SceneJson.ToDouble(v),
        JsonValue v when v.GetValueKind() == JsonValueKind.String
            && double.TryParse(v.GetValue<string>(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };
}
