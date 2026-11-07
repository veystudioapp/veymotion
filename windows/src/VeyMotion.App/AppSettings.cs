using System.Text.Json;
using System.Text.Json.Nodes;
using VeyMotion.Mcp;

namespace VeyMotion.App;

/// <summary>Small persisted preferences (macOS: UserDefaults), in %LOCALAPPDATA%\VeyMotion\settings.json.
/// Unpackaged apps have no ApplicationData.Current.</summary>
public static class AppSettings
{
    static readonly string FilePath = Path.Combine(AppPaths.SupportDirectory, "settings.json");
    static readonly Lock Gate = new();
    static JsonObject? _values;

    static JsonObject Values
    {
        get
        {
            if (_values != null) return _values;
            try { _values = File.Exists(FilePath) ? JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject : null; }
            catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
            return _values ??= [];
        }
    }

    public static string? GetString(string key)
    {
        lock (Gate) return Values[key] is JsonValue v && v.TryGetValue(out string? s) ? s : null;
    }

    public static void SetString(string key, string? value)
    {
        lock (Gate)
        {
            if (value == null) Values.Remove(key); else Values[key] = value;
            try
            {
                Directory.CreateDirectory(AppPaths.SupportDirectory);
                File.WriteAllText(FilePath, Values.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
    }
}
