using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

/// <summary>Blocking HTTP for searches, thumbnails and asset downloads: one shared client, everything in memory
/// (no temp files). Port of <c>HTTP</c> (<c>StockSources.swift</c>). Do not call on the UI thread.</summary>
public static class StockHttp
{
    public const string UserAgent = "VeyMotion/0.1 (Windows motion graphics editor)";

    /// <summary>Shared by every request. Timeouts are per request.</summary>
    public static readonly HttpClient Client = CreateClient();

    static HttpClient CreateClient()
    {
        var handler = new SocketsHttpHandler
        {
            MaxConnectionsPerServer = 6,
            AutomaticDecompression = DecompressionMethods.All,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            UseCookies = false,
        };
        var c = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        c.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
        return c;
    }

    /// <summary>GET; throws on HTTP errors (429 gets its own message).</summary>
    public static byte[] Get(string url, double timeout = 30) => Fetch(url, timeout).Data;

    /// <summary>GET that also returns the response's content type.</summary>
    public static (byte[] Data, int Status, string? ContentType) Fetch(string url, double timeout = 30)
    {
        var r = Perform(new HttpRequestMessage(HttpMethod.Get, url), timeout);
        var host = HostOf(url);
        if (r.Status == 429) throw new SceneException($"{host ?? "The server"} is rate-limiting requests. Wait a minute and try again.");
        if (r.Status is < 200 or >= 300) throw new SceneException($"{host ?? "Server"} returned HTTP {r.Status}");
        return r;
    }

    /// <summary>Any request. Throws only when the server cannot be reached; the caller checks the status.</summary>
    public static (byte[] Data, int Status, string? ContentType) Perform(HttpRequestMessage req, double timeout)
    {
        var url = req.RequestUri?.ToString() ?? "";
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeout + 5));
        try
        {
            using var resp = Client.Send(req, HttpCompletionOption.ResponseContentRead, cts.Token);
            using var ms = new MemoryStream();
            resp.Content.ReadAsStream(cts.Token).CopyTo(ms);
            return (ms.ToArray(), (int)resp.StatusCode, resp.Content.Headers.ContentType?.MediaType);
        }
        catch (OperationCanceledException)
        {
            throw new SceneException($"Request timed out: {HostOf(url) ?? url}");
        }
        catch (Exception e) when (e is HttpRequestException or IOException)
        {
            throw new SceneException($"Cannot reach {HostOf(url) ?? "the server"}: {e.Message}");
        }
        finally { req.Dispose(); }
    }

    /// <summary>GET of a JSON object.</summary>
    public static JsonObject Json(string url)
    {
        var data = Get(url);
        try
        {
            if (JsonNode.Parse(data) is JsonObject o) return o;
        }
        catch (JsonException) { }
        throw new SceneException($"Unexpected response from {HostOf(url) ?? "server"}");
    }

    internal static string? HostOf(string url) => Uri.TryCreate(url, UriKind.Absolute, out var u) ? u.Host : null;

    /// <summary>"?a=1&amp;b=x%20y", encoded like <c>URLComponents.queryItems</c> (keeps <c>:@,;/</c>).</summary>
    public static string Query(params (string Name, string Value)[] items) =>
        items.Length == 0 ? "" : "?" + string.Join("&", items.Select(i => Escape(i.Name) + "=" + Escape(i.Value)));

    static string Escape(string s)
    {
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            var c = (char)b;
            if (c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' || "-._~:@,;/!$'()*?".Contains(c)) sb.Append(c);
            else sb.Append('%').Append(b.ToString("X2"));
        }
        return sb.ToString();
    }

    // MARK: JSON helpers (JSONSerialization-style casts)

    internal static string? Str(JsonNode? o, string key) =>
        o?[key] is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    internal static int? Int(JsonNode? o, string key)
    {
        if (o?[key] is not JsonValue v || v.GetValueKind() != JsonValueKind.Number) return null;
        if (v.TryGetValue<long>(out var l)) return (int)Math.Clamp(l, int.MinValue, int.MaxValue);
        if (v.TryGetValue<int>(out var i)) return i;
        var d = SceneJson.ToDouble(v);
        return d == Math.Floor(d) && Math.Abs(d) < int.MaxValue ? (int)d : null;
    }

    internal static double? Double(JsonNode? o, string key) =>
        o?[key] is JsonValue v && v.GetValueKind() == JsonValueKind.Number ? SceneJson.ToDouble(v) : null;

    internal static bool? Bool(JsonNode? o, string key) =>
        o?[key] is JsonValue v && v.GetValueKind() is JsonValueKind.True or JsonValueKind.False ? v.GetValue<bool>() : null;

    internal static List<string>? Strings(JsonNode? o, string key) =>
        o?[key] is JsonArray a
            ? a.OfType<JsonValue>().Where(v => v.GetValueKind() == JsonValueKind.String).Select(v => v.GetValue<string>()).ToList()
            : null;
}

/// <summary>Where the VeyMotion (Nitro) server is. Port of <c>VieNeu.baseURL</c> and <c>DotEnv</c>.</summary>
public static class ServerConfig
{
    public const string DefaultBaseUrl = "http://localhost:3000";

    /// <summary><c>BASE_API_URL</c> from the environment, else from a <c>.env</c> file (working directory, next to the
    /// executable, or %LOCALAPPDATA%\VeyMotion\.env), else http://localhost:3000. No trailing slash.</summary>
    public static string BaseUrl
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("BASE_API_URL");
            var raw = (string.IsNullOrEmpty(env) ? null : env) ?? DotEnvValue("BASE_API_URL") ?? DefaultBaseUrl;
            var trimmed = raw.Trim().Trim('/');
            return Uri.TryCreate(trimmed, UriKind.Absolute, out _) ? trimmed : DefaultBaseUrl;
        }
    }

    /// <summary>A key from the first <c>.env</c> file that sets it (comments, <c>export </c> and quotes allowed).</summary>
    public static string? DotEnvValue(string key)
    {
        foreach (var path in DotEnvCandidates)
        {
            string text;
            try { text = File.ReadAllText(path, Encoding.UTF8); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
            foreach (var line in text.Split(['\n', '\r'], StringSplitOptions.RemoveEmptyEntries))
            {
                var s = line.Trim();
                if (s.StartsWith('#')) continue;
                if (s.StartsWith("export ")) s = s[7..];
                var eq = s.IndexOf('=');
                if (eq < 0 || s[..eq].Trim() != key) continue;
                var v = s[(eq + 1)..].Trim();
                if (v.Length >= 2 && v[0] == v[^1] && v[0] is '"' or '\'') v = v[1..^1];
                if (v.Length > 0) return v;
            }
        }
        return null;
    }

    static IEnumerable<string> DotEnvCandidates
    {
        get
        {
            yield return Path.Combine(Environment.CurrentDirectory, ".env");
            yield return Path.Combine(AppContext.BaseDirectory, ".env");
            yield return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VeyMotion", ".env");
        }
    }
}
