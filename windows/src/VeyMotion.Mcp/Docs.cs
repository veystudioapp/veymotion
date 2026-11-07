using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;

namespace VeyMotion.Mcp;

/// <summary>
/// The scene-format reference and tool schemas, read from the macOS <c>Docs.swift</c> (embedded at build time) so
/// both apps describe the same format. Only the tools ported to Windows are listed.
/// </summary>
public static class Docs
{
    /// <summary>Tools the Windows server implements (see <see cref="McpServer"/>).</summary>
    public static readonly HashSet<string> PortedTools =
    [
        "get_scene", "set_scene", "update_scene", "add_layer", "add_layers", "update_layer", "remove_layer",
        "reorder_layer", "set_keyframes", "apply_preset", "render_frame", "transition", "group_layers", "ungroup", "set_parent",
        "add_template", "text_to_path", "combine_paths", "shatter_image", "export_video",
        "get_audio_info", "analyze_audio", "add_audio", "list_voices", "generate_voice",
        "generate_sfx", "sync_to_beats", "add_captions", "set_caption_texts", "list_captions", "transcribe",
        "search_stock", "import_stock", "list_fonts", "stabilize", "track_motion", "auto_reframe", "list_assets", "import_asset", "write_asset", "read_asset", "rename_asset",
        "delete_asset", "create_folder", "rename_folder", "delete_folder", "get_credits",
    ];

    static readonly Lazy<string> Source = new(() =>
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("Docs.swift")
            ?? throw new InvalidOperationException("Docs.swift is not embedded");
        using var r = new StreamReader(s, Encoding.UTF8);
        return r.ReadToEnd().Replace("\r\n", "\n");
    });

    static readonly Lazy<string> InstructionsText = new(() =>
        RawString("instructions").Replace("a native macOS motion-graphics editor", "a native Windows motion-graphics editor"));

    static readonly Lazy<JsonArray> AllTools = new(() => (JsonArray)JsonNode.Parse(RawString("toolsJSON"))!);

    /// <summary>Scene format reference (MCP <c>initialize</c>, <c>vmotion docs</c>, agent prompt).</summary>
    public static string Instructions => InstructionsText.Value;

    /// <summary>Schemas of the tools available here, in the macOS order.</summary>
    public static IEnumerable<JsonObject> Tools =>
        AllTools.Value.OfType<JsonObject>().Where(t => PortedTools.Contains((string)t["name"]!));

    public static JsonArray ToolsArray => new(Tools.Select(t => (JsonNode)t.DeepClone()).ToArray());

    /// <summary>Tools that exist on macOS but not here yet.</summary>
    public static IEnumerable<string> MissingTools =>
        AllTools.Value.OfType<JsonObject>().Select(t => (string)t["name"]!).Where(n => !PortedTools.Contains(n));

    /// <summary>The body of <c>static let name = #""" … """#</c>, with Swift's indentation removed.</summary>
    static string RawString(string name)
    {
        var src = Source.Value;
        var open = $"static let {name} = #\"\"\"\n";
        var start = src.IndexOf(open, StringComparison.Ordinal);
        if (start < 0) throw new InvalidOperationException($"Docs.swift has no {name}");
        start += open.Length;
        var end = src.IndexOf("\"\"\"#", start, StringComparison.Ordinal);
        // The closing delimiter's indentation is stripped from every line (Swift multi-line string rules).
        var lineStart = src.LastIndexOf('\n', end) + 1;
        var indent = end - lineStart;
        var body = src[start..lineStart].TrimEnd('\n');
        return string.Join("\n", body.Split('\n').Select(l => l.Length >= indent ? l[indent..] : l.TrimStart()));
    }
}
