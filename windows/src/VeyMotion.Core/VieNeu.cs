using System.Text;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

/// <summary>Vietnamese text-to-speech with VieNeu (https://vieneu.io), through the VeyMotion server in <c>server/</c>
/// (<c>/api/tts/*</c>), which holds the VieNeu API key. The server address is <c>BASE_API_URL</c>
/// (<see cref="ServerConfig.BaseUrl"/>). Port of <c>VieNeu.swift</c>.</summary>
public static class VieNeu
{
    public sealed record Voice(string Id, string? Name, string? Description, string? Gender, string? Region, string? Kind)
    {
        /// <summary>"Ngọc Lan — Nữ · Bắc · …" style label for pickers and tool output.</summary>
        public string Label
        {
            get
            {
                var d = Description ?? string.Join(", ", new[] { Gender, Region }.OfType<string>());
                return d.Length == 0 ? Id : $"{Id} — {d}";
            }
        }
    }

    /// <summary>Text longer than this goes through an async job (/api/tts/jobs) instead of /api/tts/speech.</summary>
    const int SyncLimit = 1500;
    static List<Voice>? _voices;
    static readonly Lock CacheLock = new();

    /// <summary>The VieNeu voice catalogue (cached after the first successful call). Blocking.</summary>
    public static List<Voice> Voices(bool refresh = false)
    {
        lock (CacheLock) if (!refresh && _voices != null) return _voices;
        var obj = JsonNode.Parse(Call("GET", "/api/tts/voices", null, null, 20)) as JsonObject ?? [];
        var voices = (obj["voices"] as JsonArray ?? []).OfType<JsonObject>().Select(v => new Voice(
            (string?)v["id"] ?? "", (string?)v["name"], (string?)v["description"], (string?)v["gender"], (string?)v["region"], (string?)v["kind"]))
            .Where(v => v.Id.Length > 0).ToList();
        if (voices.Count == 0 && (string?)obj["error"] is { } e) throw new SceneException($"VieNeu voice list unavailable: {e}");
        lock (CacheLock) _voices = voices;
        return voices;
    }

    /// <summary>Synthesizes text into a new file in <paramref name="directory"/>. speed is 0.5–2. VieNeu gives no word
    /// timings, so they are estimated from the text. Blocking. Returns (path, duration, words).</summary>
    public static (string Path, double Duration, List<WordTiming> Words) Synthesize(string text, string? voice, double speed, string directory,
        Func<string, double?> duration)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) throw new SceneException("text is empty");
        speed = Math.Clamp(speed, 0.5, 2);
        if (string.IsNullOrEmpty(voice)) voice = null;
        Directory.CreateDirectory(directory);
        string path;
        if (trimmed.Length <= SyncLimit)
        {
            // WAV decodes everywhere; 24 kHz keeps files small.
            var body = new JsonObject { ["text"] = trimmed, ["format"] = "wav", ["sampleRate"] = 24000, ["speed"] = speed };
            if (voice != null) body["voice"] = voice;
            var audio = CallBytes("POST", "/api/tts/speech", body, null, 60 + trimmed.Length * 0.1);
            if (audio.Length == 0) throw new SceneException("VieNeu returned no audio");
            path = NewFile(directory, "voice", "wav");
            File.WriteAllBytes(path, audio);
        }
        else path = SynthesizeJob(trimmed, voice, speed, directory);
        if (duration(path) is not { } seconds)
        {
            try { File.Delete(path); } catch (IOException) { }
            throw new SceneException($"VieNeu audio could not be read ({System.IO.Path.GetFileName(path)})");
        }
        return (path, seconds, CaptionOps.EstimateTimings(trimmed, seconds));
    }

    /// <summary>Long text: submit a job, poll until it completes, then download the audio.</summary>
    static string SynthesizeJob(string text, string? voice, double speed, string directory)
    {
        var body = new JsonObject { ["text"] = text, ["speed"] = speed };
        if (voice != null) body["voiceId"] = voice;
        var job = Json(Call("POST", "/api/tts/jobs", body, new() { ["Idempotency-Key"] = Guid.NewGuid().ToString() }, 60));
        var jobId = (string?)job["jobId"] ?? throw new SceneException("VieNeu did not return a job id");
        var deadline = DateTime.UtcNow.AddSeconds(120 + text.Length * 0.05);
        while ((string?)job["status"] != "completed")
        {
            switch ((string?)job["status"])
            {
                case "failed": throw new SceneException($"VieNeu job failed: {(string?)job["error"] ?? "unknown error"}");
                case "queued" or "processing" or null: break;
                case var other: throw new SceneException($"VieNeu job has unexpected status '{other}'");
            }
            if (DateTime.UtcNow > deadline) throw new SceneException($"VieNeu job {jobId} did not finish in time");
            Thread.Sleep(1500);
            job = Json(Call("GET", $"/api/tts/jobs/{jobId}", null, null, 30));
        }
        if ((string?)job["audioUrl"] is not { } s || !Uri.TryCreate(s, UriKind.Absolute, out var audioUrl))
            throw new SceneException("VieNeu job finished without an audio URL");
        using var req = new HttpRequestMessage(HttpMethod.Get, audioUrl);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(120));
        using var resp = StockHttp.Client.Send(req, cts.Token);
        var data = resp.Content.ReadAsByteArrayAsync(cts.Token).GetAwaiter().GetResult();
        var ext = System.IO.Path.GetExtension(audioUrl.AbsolutePath).TrimStart('.').ToLowerInvariant();
        var path = NewFile(directory, "voice", ext is "mp3" or "wav" or "opus" or "ogg" or "m4a" ? ext : "mp3");
        File.WriteAllBytes(path, data);
        return path;
    }

    static string NewFile(string dir, string prefix, string ext)
    {
        for (var i = 1; ; i++)
        {
            var p = System.IO.Path.Combine(dir, $"{prefix}-{i}.{ext}");
            if (!File.Exists(p)) return p;
        }
    }

    static JsonObject Json(string s) => JsonNode.Parse(s) as JsonObject ?? throw new SceneException("Unexpected response from the TTS server");

    static string Call(string method, string path, JsonObject? json, Dictionary<string, string>? headers, double timeout) =>
        Encoding.UTF8.GetString(CallBytes(method, path, json, headers, timeout));

    static byte[] CallBytes(string method, string path, JsonObject? json, Dictionary<string, string>? headers, double timeout)
    {
        var baseUrl = ServerConfig.BaseUrl;
        using var req = new HttpRequestMessage(new HttpMethod(method), baseUrl + path);
        foreach (var (k, v) in headers ?? []) req.Headers.TryAddWithoutValidation(k, v);
        if (json != null) req.Content = new StringContent(json.ToJsonString(), Encoding.UTF8, "application/json");
        HttpResponseMessage resp;
        byte[] data;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeout));
            resp = StockHttp.Client.Send(req, cts.Token);
            data = resp.Content.ReadAsByteArrayAsync(cts.Token).GetAwaiter().GetResult();
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException)
        {
            throw new SceneException($"Cannot reach the VeyMotion TTS server at {baseUrl} (start it with `cd server && bun run dev`, or set BASE_API_URL). {e.Message}");
        }
        using (resp)
        {
            var status = (int)resp.StatusCode;
            if (status is < 200 or >= 300) throw new SceneException($"VieNeu TTS failed (HTTP {status}): {ErrorMessage(data)}");
        }
        return data;
    }

    /// <summary>The server returns { status, message, data: { code, traceId } } on errors.</summary>
    static string ErrorMessage(byte[] data)
    {
        try
        {
            if (JsonNode.Parse(data) is JsonObject o)
            {
                var msg = (string?)o["message"] ?? "no details";
                if ((string?)o["data"]?["traceId"] is { } trace) msg += $" (trace {trace})";
                return msg;
            }
        }
        catch (System.Text.Json.JsonException) { }
        return Encoding.UTF8.GetString(data.AsSpan(0, Math.Min(300, data.Length)));
    }
}
