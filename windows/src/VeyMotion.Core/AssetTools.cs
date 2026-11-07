using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace VeyMotion.Core;

/// <summary>A tool reply: text, plus an image for read_asset on pictures.</summary>
public sealed record AssetToolResult(string Text, byte[]? Image = null, string? MimeType = null)
{
    /// <summary>The MCP <c>tools/call</c> result: the image first (when there is one), then the text.</summary>
    public JsonObject ToContent()
    {
        var content = new JsonArray();
        if (Image != null)
            content.Add(new JsonObject { ["type"] = "image", ["data"] = Convert.ToBase64String(Image), ["mimeType"] = MimeType ?? "image/png" });
        content.Add(new JsonObject { ["type"] = "text", ["text"] = Text });
        return new JsonObject { ["content"] = content };
    }
}

/// <summary>
/// The asset tools of the MCP server (list_assets, import_asset, write_asset, read_asset, rename_asset, delete_asset,
/// create_folder, rename_folder, delete_folder, get_credits), with the same replies as <c>MCPServer.swift</c>.
/// Every handler takes the tool arguments, a scene snapshot getter and a mutation (label, edit), e.g.
/// <c>(a, host.CurrentScene, (label, body) =&gt; host.Mutate(label, body))</c>. Failures throw (their message is the
/// tool error).
/// </summary>
public static class AssetTools
{
    public static readonly IReadOnlySet<string> Names = new HashSet<string>
    {
        "list_assets", "import_asset", "write_asset", "read_asset", "rename_asset", "delete_asset",
        "create_folder", "rename_folder", "delete_folder", "get_credits",
    };

    /// <summary>What the macOS replies call the place deleted files go.</summary>
    public const string TrashName = "Trash";

    /// <summary>Runs one asset tool; null when <paramref name="name"/> is not one.</summary>
    public static AssetToolResult? TryCall(string name, JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate) =>
        name switch
        {
            "list_assets" => new(ListAssets(a, currentScene, mutate)),
            "import_asset" => new(ImportAsset(a, currentScene, mutate)),
            "write_asset" => new(WriteAsset(a, currentScene, mutate)),
            "read_asset" => ReadAsset(a, currentScene, mutate),
            "rename_asset" => new(RenameAsset(a, currentScene, mutate)),
            "delete_asset" => new(DeleteAsset(a, currentScene, mutate)),
            "create_folder" => new(CreateFolder(a, currentScene, mutate)),
            "rename_folder" => new(RenameFolder(a, currentScene, mutate)),
            "delete_folder" => new(DeleteFolder(a, currentScene, mutate)),
            "get_credits" => new(GetCredits(a, currentScene, mutate)),
            _ => null,
        };

    public static string ListAssets(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate)
    {
        var kind = OptString(a, "kind");
        var folder = AssetStore.ValidFolder(OptString(a, "folder"));
        var shared = OptString(a, "library") == "shared";
        var root = shared ? AssetStore.SharedDirectory : AssetStore.Directory;
        var allFolders = AssetStore.Folders(root);
        if (folder.Length > 0)
        {
            // Folder names are not case-sensitive on Windows: use the folder's own spelling.
            folder = allFolders.FirstOrDefault(f => f == folder)
                ?? allFolders.FirstOrDefault(f => string.Equals(f, folder, StringComparison.OrdinalIgnoreCase))
                ?? throw AssetException.FolderNotFound(folder);
        }
        bool InFolder(string n) => folder.Length == 0 || n.StartsWith(folder + "/", StringComparison.Ordinal);
        var scene = currentScene();
        var assets = AssetStore.List(root).Where(x => (kind == null || x.Kind.Json() == kind) && InFolder(x.Name)).ToList();
        var folders = allFolders.Where(InFolder).ToList();
        var title = shared ? "Shared library (read-only here — import_asset a path to copy it into the project)"
            : AssetStore.IsProjectLibrary ? "Project library" : "Asset library";
        var lines = new List<string> { $"{title}: {AssetStore.Full(root)}{(folder.Length == 0 ? "" : $" — folder {folder}")} ({assets.Count} files)" };
        if (folders.Count > 0) lines.Add("Folders: " + string.Join(", ", folders.Select(f => f + "/")));
        foreach (var asset in assets)
        {
            var users = scene.LayersUsingPath(asset.Path);
            lines.Add($"{asset.Name} — {asset.Summary}{(users.Count == 0 ? "" : $" — used by: {string.Join(", ", users)}")}\n    {asset.Path}"
                + (asset.Credit is { } c ? $"\n    credit: {c.Attribution}{(c.RequiresAttribution ? " (required)" : "")}" : ""));
        }
        return string.Join("\n", lines);
    }

    public static string ImportAsset(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate)
    {
        var source = Str(a, "source");
        var overwrite = Bool(a, "overwrite") ?? false;
        var name = OptString(a, "name");
        var folder = OptString(a, "folder");
        AssetInfo asset;
        if (source.StartsWith("http://", StringComparison.Ordinal) || source.StartsWith("https://", StringComparison.Ordinal))
        {
            if (!Uri.TryCreate(source, UriKind.Absolute, out var url)) throw new AssetException($"Invalid URL: {source}");
            asset = AssetStore.Download(url, name, folder, overwrite);
        }
        else
        {
            var path = AssetStore.Expand(source);
            if (!Path.IsPathFullyQualified(path)) throw new AssetException("`source` must be an absolute path or an http(s) URL");
            asset = AssetStore.ImportFile(path, name, folder, overwrite);
        }
        return $"Imported '{asset.Name}' ({asset.Summary})\npath: {asset.Path}";
    }

    public static string WriteAsset(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate)
    {
        var name = Str(a, "name");
        byte[] data;
        if (OptString(a, "text") is { } s) data = Encoding.UTF8.GetBytes(s);
        else if (OptString(a, "base64") is { } b)
        {
            // Like Data(base64Encoded:options: .ignoreUnknownCharacters).
            var clean = Regex.Replace(b, "[^A-Za-z0-9+/=]", "");
            try { data = Convert.FromBase64String(clean); }
            catch (FormatException) { throw new AssetException("`base64` is not valid base64"); }
        }
        else throw new AssetException("Give either `text` or `base64`");
        var asset = AssetStore.Write(data, name, OptString(a, "folder"), Bool(a, "overwrite") ?? false);
        return $"Wrote '{asset.Name}' ({asset.Summary})\npath: {asset.Path}";
    }

    /// <summary>Largest picture sent as is when no <see cref="AssetStore.PreviewPng"/> hook is set.</summary>
    const int MaxRawImageBytes = 4 * 1024 * 1024;

    public static AssetToolResult ReadAsset(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate)
    {
        var path = AssetStore.Existing(Str(a, "name"));
        var asset = AssetStore.Info(path) ?? throw new AssetException($"Cannot read {path}");
        var header = $"{asset.Name} — {asset.Summary}\npath: {asset.Path}";
        switch (asset.Kind)
        {
            case AssetKind.Image:
                var maxPixels = (int)Math.Clamp(Number(a["maxPixels"]) ?? 1024, 64, 2048);
                if (AssetStore.PreviewPng?.Invoke(path, maxPixels) is { } png) return new(header, png, "image/png");
                // No decoder hook: send small pictures in a format MCP clients show as they are.
                if (AssetStore.PreviewPng == null && AssetFormat.ImageMime(path) is { } mime && asset.Bytes <= MaxRawImageBytes)
                    return new(header, File.ReadAllBytes(path), mime);
                return new(header + "\n(cannot decode image)");
            case AssetKind.Text:
                return new(header + "\n\n" + AssetStore.ReadText(path));
            default:
                try { return new(header + "\n\n" + AssetStore.ReadText(path, 50_000)); }
                catch (Exception e) when (e is AssetException or IOException or UnauthorizedAccessException) { return new(header); }
        }
    }

    public static string RenameAsset(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate)
    {
        var moved = AssetStore.Rename(Str(a, "name"), Str(a, "newName"));
        List<string> ids = [];
        if (currentScene().LayersUsingPath(moved.From).Count > 0)
            mutate("Rename Asset", s => ids = s.ReplacePath(moved.From, moved.To));
        return $"Renamed to '{AssetStore.RelativeName(moved.To) ?? moved.To}'\npath: {moved.To}"
            + (ids.Count == 0 ? "" : $"\nUpdated layers: {string.Join(", ", ids)}");
    }

    public static string DeleteAsset(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate)
    {
        var path = AssetStore.Existing(Str(a, "name"));
        var fileName = Path.GetFileName(path);
        var users = currentScene().LayersUsingPath(path);
        if (users.Count > 0 && Bool(a, "force") != true)
            throw new AssetException($"'{fileName}' is used by layers: {string.Join(", ", users)}. Remove or repoint those layers first, or pass \"force\": true.");
        AssetStore.Trash(path);
        return $"Moved '{fileName}' to the {TrashName}"
            + (users.Count == 0 ? "" : $" (layers {string.Join(", ", users)} now point to a missing file)");
    }

    public static string CreateFolder(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate)
    {
        var name = AssetStore.CreateFolder(Str(a, "name"));
        return $"Created folder '{name}'\npath: {AssetStore.FolderPath(name)}";
    }

    public static string RenameFolder(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate)
    {
        var moved = AssetStore.RenameFolder(Str(a, "name"), Str(a, "newName"));
        List<string> ids = [];
        if (currentScene().LayersInFolder(moved.From).Count > 0)
            mutate("Rename Folder", s => ids = s.ReplaceFolder(moved.From, moved.To));
        return $"Moved folder to '{AssetStore.RelativeName(moved.To) ?? moved.To}'\npath: {moved.To}"
            + (ids.Count == 0 ? "" : $"\nUpdated layers: {string.Join(", ", ids)}");
    }

    public static string DeleteFolder(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate)
    {
        var path = AssetStore.ExistingFolder(Str(a, "name"));
        var name = AssetStore.RelativeName(path) ?? path;
        var users = currentScene().LayersInFolder(path);
        if (users.Count > 0 && Bool(a, "force") != true)
            throw new AssetException($"Files in '{name}' are used by layers: {string.Join(", ", users)}. Remove or repoint those layers first, or pass \"force\": true.");
        AssetStore.TrashFolder(path);
        return $"Moved folder '{name}' and its contents to the {TrashName}"
            + (users.Count == 0 ? "" : $" (layers {string.Join(", ", users)} now point to missing files)");
    }

    public static string GetCredits(JsonObject a, Func<MotionScene> currentScene, Action<string, Action<MotionScene>> mutate)
    {
        var used = AssetStore.CreditsUsedBy(currentScene());
        if (used.Count == 0) return "The scene uses no assets from the free sources, so there is nothing to credit.";
        var required = used.Count(u => u.Credit.RequiresAttribution);
        var lines = new List<string> { $"Credits for assets used in this scene ({required} required):" };
        foreach (var (_, c) in used) lines.Add($"- {c.Attribution}{(c.RequiresAttribution ? "" : " (optional)")}");
        return string.Join("\n", lines);
    }

    // Arguments (same rules as MCPServer.swift)

    static string Str(JsonObject a, string key) =>
        OptString(a, key) is { Length: > 0 } s ? s : throw new AssetException($"`{key}` must be a non-empty string");

    static string? OptString(JsonObject a, string key) =>
        a[key] is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    static bool? Bool(JsonObject a, string key) =>
        a[key] is JsonValue v && v.GetValueKind() is JsonValueKind.True or JsonValueKind.False ? v.GetValue<bool>() : null;

    static double? Number(JsonNode? n) => n switch
    {
        JsonValue v when v.GetValueKind() == JsonValueKind.Number => SceneJson.ToDouble(v),
        JsonValue v when v.GetValueKind() == JsonValueKind.String
            && double.TryParse(v.GetValue<string>(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };
}
