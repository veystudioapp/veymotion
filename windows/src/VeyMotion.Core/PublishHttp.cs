using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

/// <summary>HTTP for the platform APIs. Port of <c>PublishHTTP</c>.</summary>
internal static class PublishHttp
{
    internal sealed class Result(byte[] data, int status, Dictionary<string, string> headers)
    {
        public byte[] Data { get; } = data;
        public int Status { get; } = status;
        /// <summary>Response and content headers, case-insensitive (read by enumeration: <c>HttpResponseHeaders</c>
        /// refuses to look up request-header names such as YouTube's <c>Range</c>).</summary>
        public Dictionary<string, string> Headers { get; } = headers;

        JsonObject? _json;
        public JsonObject Json => _json ??= Parse(Data);

        static JsonObject Parse(byte[] d)
        {
            try { return JsonNode.Parse(d) as JsonObject ?? []; }
            catch (JsonException) { return []; }
        }
    }

    /// <summary>For uploads: never follows redirects, so YouTube's 308 "Resume Incomplete" comes back as it is.</summary>
    static readonly HttpClient UploadClient = CreateUploadClient();

    static HttpClient CreateUploadClient()
    {
        var c = new HttpClient(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            UseCookies = false,
        }) { Timeout = Timeout.InfiniteTimeSpan };
        c.DefaultRequestHeaders.UserAgent.ParseAdd(StockHttp.UserAgent);
        return c;
    }

    /// <summary>JSON / form API call; non-2xx statuses throw with the platform's error message.</summary>
    public static async Task<Result> CallAsync(string method, string url, CancellationToken ct, string? bearer = null,
        JsonObject? json = null, IReadOnlyDictionary<string, string>? form = null, byte[]? body = null, string? contentType = null,
        IReadOnlyDictionary<string, string>? headers = null)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u)) throw new PublishException($"Invalid URL {url}");
        var req = new HttpRequestMessage(new HttpMethod(method), u);
        if (bearer != null) req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {bearer}");
        if (json != null)
        {
            req.Content = new ByteArrayContent(Encoding.UTF8.GetBytes(json.ToJsonString()));
            req.Content.Headers.TryAddWithoutValidation("Content-Type", "application/json; charset=UTF-8");
        }
        else if (form != null)
        {
            req.Content = new FormUrlEncodedContent(form);
        }
        else if (body != null)
        {
            req.Content = new ByteArrayContent(body);
            req.Content.Headers.TryAddWithoutValidation("Content-Type", contentType ?? "application/octet-stream");
        }
        foreach (var (k, v) in headers ?? new Dictionary<string, string>())
            if (!req.Headers.TryAddWithoutValidation(k, v)) req.Content?.Headers.TryAddWithoutValidation(k, v);
        var res = await SendAsync(req, ct, timeout: 60, client: StockHttp.Client);
        if (res.Status is < 200 or >= 300) throw new PublishException($"{u.Host} (HTTP {res.Status}): {ErrorText(res.Data)}");
        return res;
    }

    /// <summary>Sends one request (disposing it), reporting bytes sent while it uploads (when the content is a
    /// <see cref="ProgressContent"/>). Throws only on network errors, timeouts and cancellation.</summary>
    public static async Task<Result> SendAsync(HttpRequestMessage req, CancellationToken ct, double timeout,
        Action<long>? onProgress = null, HttpClient? client = null)
    {
        var host = req.RequestUri?.Host ?? "";
        if (req.Content is ProgressContent pc) pc.OnProgress = onProgress;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(timeout + 10));
        try
        {
            using var resp = await (client ?? UploadClient).SendAsync(req, HttpCompletionOption.ResponseContentRead, cts.Token);
            var data = await resp.Content.ReadAsByteArrayAsync(cts.Token);
            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var (k, v) in resp.Headers.Concat(resp.Content.Headers)) headers[k] = string.Join(", ", v);
            if (resp.Headers.Location is { } loc && !headers.ContainsKey("Location")) headers["Location"] = loc.ToString();
            return new Result(data, (int)resp.StatusCode, headers);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw new PublishCancelledException("Publishing cancelled");
        }
        catch (OperationCanceledException)
        {
            throw new PublishException($"Request timed out: {host}");
        }
        catch (Exception e) when (e is HttpRequestException or IOException)
        {
            throw new PublishException($"Cannot reach {(host.Length > 0 ? host : "the server")}: {e.Message}");
        }
        finally { req.Dispose(); }
    }

    /// <summary>The readable part of an API error body (Google, TikTok, Meta, X all differ).</summary>
    public static string ErrorText(byte[] data)
    {
        JsonObject? obj = null;
        try { obj = JsonNode.Parse(data) as JsonObject; }
        catch (JsonException) { }
        if (obj == null)
        {
            var text = Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 300));
            return text.Length == 0 ? "no details" : text;
        }
        if (obj["error"] is JsonObject e)
        {
            return (StockHttp.Str(e, "message") ?? StockHttp.Str(e, "code") ?? "error")
                + (StockHttp.Str(e, "error_user_msg") is { } um ? $" — {um}" : "");
        }
        if (StockHttp.Str(obj, "error") is { } es) return StockHttp.Str(obj, "error_description") ?? es;
        if (obj["errors"] is JsonArray { Count: > 0 } errors && errors[0] is JsonObject first)
            return StockHttp.Str(first, "message") ?? StockHttp.Str(first, "detail") ?? "error";
        return StockHttp.Str(obj, "detail") ?? StockHttp.Str(obj, "title") ?? StockHttp.Str(obj, "message") ?? "no details";
    }

    /// <summary>multipart/form-data body with text fields and one file; returns (body, Content-Type).</summary>
    public static (byte[] Body, string ContentType) Multipart(IReadOnlyDictionary<string, string> fields,
        (string Name, string FileName, string Type, byte[] Data) file)
    {
        var boundary = $"veymotion-{Guid.NewGuid().ToString().ToUpperInvariant()}";
        using var ms = new MemoryStream();
        void Append(string s) { var b = Encoding.UTF8.GetBytes(s); ms.Write(b); }
        foreach (var (k, v) in fields.OrderBy(f => f.Key, StringComparer.Ordinal))
            Append($"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n");
        Append($"--{boundary}\r\nContent-Disposition: form-data; name=\"{file.Name}\"; filename=\"{file.FileName}\"\r\n"
            + $"Content-Type: {file.Type}\r\n\r\n");
        ms.Write(file.Data);
        Append($"\r\n--{boundary}--\r\n");
        return (ms.ToArray(), $"multipart/form-data; boundary={boundary}");
    }
}

/// <summary>Request content that streams a byte array or a file region in 64 KB blocks and reports how many bytes
/// have been written (Swift polled <c>countOfBytesSent</c> instead).</summary>
internal sealed class ProgressContent : HttpContent
{
    readonly byte[]? _data;
    readonly string? _file;
    readonly long _offset, _length;
    public Action<long>? OnProgress { get; set; }

    public ProgressContent(byte[] data, string? contentType = null)
    {
        _data = data;
        _length = data.Length;
        if (contentType != null) Headers.TryAddWithoutValidation("Content-Type", contentType);
    }

    public ProgressContent(string file, long offset, long length, string? contentType = null)
    {
        _file = file;
        _offset = offset;
        _length = length;
        if (contentType != null) Headers.TryAddWithoutValidation("Content-Type", contentType);
    }

    protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
        SerializeToStreamAsync(stream, context, CancellationToken.None);

    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken ct)
    {
        const int block = 64 * 1024;
        long sent = 0;
        OnProgress?.Invoke(0);
        if (_data != null)
        {
            while (sent < _length)
            {
                var n = (int)Math.Min(block, _length - sent);
                await stream.WriteAsync(_data.AsMemory((int)sent, n), ct);
                sent += n;
                OnProgress?.Invoke(sent);
            }
            return;
        }
        await using var fs = new FileStream(_file!, FileMode.Open, FileAccess.Read, FileShare.Read, block, useAsync: true);
        fs.Seek(_offset, SeekOrigin.Begin);
        var buffer = new byte[block];
        while (sent < _length)
        {
            var n = await fs.ReadAsync(buffer.AsMemory(0, (int)Math.Min(block, _length - sent)), ct);
            if (n == 0) throw new IOException("The video file ended early.");
            await stream.WriteAsync(buffer.AsMemory(0, n), ct);
            sent += n;
            OnProgress?.Invoke(sent);
        }
    }

    protected override bool TryComputeLength(out long length)
    {
        length = _length;
        return true;
    }
}

internal static class ContentRangeExtensions
{
    /// <summary>"bytes first-last/total".</summary>
    public static void SetRange(this HttpContent c, long first, long length, long total) =>
        c.Headers.ContentRange = new ContentRangeHeaderValue(first, first + length - 1, total);
}
