using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Mcp;

/// <summary>
/// Minimal MCP Streamable HTTP transport: POST /mcp with a JSON-RPC message, JSON response. No SSE stream (GET
/// returns 405), which the spec allows. Bound to 127.0.0.1 only, optional bearer token (VEYMOTION_TOKEN). Port of
/// <c>MCPHTTPServer</c> (<c>Transports.swift</c>).
/// </summary>
public sealed class McpHttpServer(McpServer server, int port = McpHttpServer.DefaultPort, string? token = null) : IDisposable
{
    public const int DefaultPort = 19790;
    TcpListener? _listener;
    readonly CancellationTokenSource _stop = new();

    public string Endpoint => $"http://127.0.0.1:{port}/mcp";
    public event Action<string>? StateChanged;

    public void Start()
    {
        _listener = new TcpListener(IPAddress.Loopback, port);
        _listener.Start();
        StateChanged?.Invoke($"Listening on {Endpoint}");
        _ = AcceptLoop(_listener);
    }

    async Task AcceptLoop(TcpListener listener)
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(_stop.Token); }
            catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or SocketException) { break; }
            // Tools like export_video take a while: each connection on its own.
            _ = Task.Run(() => Serve(client));
        }
        StateChanged?.Invoke("Stopped");
    }

    async Task Serve(TcpClient client)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var buffer = new MemoryStream();
                var chunk = new byte[64 * 1024];
                int headerEnd = -1, contentLength = 0;
                while (true)
                {
                    var n = await stream.ReadAsync(chunk, _stop.Token);
                    if (n == 0) return;
                    buffer.Write(chunk, 0, n);
                    if (buffer.Length > 64 << 20) { await Send(stream, 413, []); return; }
                    var data = buffer.GetBuffer().AsSpan(0, (int)buffer.Length);
                    if (headerEnd < 0)
                    {
                        headerEnd = data.IndexOf("\r\n\r\n"u8);
                        if (headerEnd < 0) continue;
                        var head0 = Encoding.UTF8.GetString(data[..headerEnd]);
                        foreach (var line in head0.Split("\r\n").Skip(1))
                            if (line.StartsWith("content-length:", StringComparison.OrdinalIgnoreCase))
                                int.TryParse(line[15..].Trim(), out contentLength);
                    }
                    if (data.Length - headerEnd - 4 >= contentLength) break;
                }
                var all = buffer.ToArray();
                var head = Encoding.UTF8.GetString(all, 0, headerEnd).Split("\r\n");
                var requestLine = head[0].Split(' ');
                if (requestLine.Length < 2) { await Send(stream, 400, []); return; }
                var headers = head.Skip(1).Select(l => l.Split(':', 2)).Where(p => p.Length == 2)
                    .GroupBy(p => p[0].Trim().ToLowerInvariant()).ToDictionary(g => g.Key, g => g.Last()[1].Trim());
                var body = all.AsSpan(headerEnd + 4, Math.Min(contentLength, all.Length - headerEnd - 4)).ToArray();
                await Respond(stream, requestLine[0], requestLine[1], headers, body);
            }
            catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or ObjectDisposedException) { }
        }
    }

    async Task Respond(NetworkStream stream, string method, string path, Dictionary<string, string> headers, byte[] body)
    {
        if (path.Split('?')[0] != "/mcp") { await Send(stream, 404, []); return; }
        // DNS-rebinding protection: browsers send Origin; only allow local origins.
        if (headers.TryGetValue("origin", out var origin) && Uri.TryCreate(origin, UriKind.Absolute, out var o)
            && o.Host is not ("localhost" or "127.0.0.1" or "[::1]" or "::1"))
        {
            await Send(stream, 403, []);
            return;
        }
        if (token != null && (!headers.TryGetValue("authorization", out var auth) || auth != $"Bearer {token}")) { await Send(stream, 401, []); return; }
        if (method != "POST") { await Send(stream, 405, [], "Allow: POST\r\n"); return; }
        JsonNode? parsed;
        try { parsed = JsonNode.Parse(body); }
        catch (JsonException) { await SendJson(stream, McpServer.Error(null, -32700, "Parse error")); return; }
        switch (parsed)
        {
            case JsonObject msg:
                if (server.Handle(msg) is { } resp) await SendJson(stream, resp); else await Send(stream, 202, []);
                break;
            case JsonArray batch:
                var resps = batch.OfType<JsonObject>().Select(server.Handle).OfType<JsonObject>().Select(r => (JsonNode)r).ToArray();
                if (resps.Length == 0) await Send(stream, 202, []); else await SendJson(stream, new JsonArray(resps));
                break;
            default:
                await SendJson(stream, McpServer.Error(null, -32600, "Invalid request"));
                break;
        }
    }

    static Task SendJson(NetworkStream stream, JsonNode node) =>
        Send(stream, 200, Encoding.UTF8.GetBytes(node.ToJsonString(Relaxed)), "Content-Type: application/json\r\n");

    static readonly JsonSerializerOptions Relaxed = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    static async Task Send(NetworkStream stream, int status, byte[] body, string extra = "")
    {
        var reason = status switch
        {
            200 => "OK", 202 => "Accepted", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden",
            404 => "Not Found", 405 => "Method Not Allowed", 413 => "Payload Too Large", _ => "Status",
        };
        var head = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {reason}\r\n{extra}Content-Length: {body.Length}\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(head);
        await stream.WriteAsync(body);
        await stream.FlushAsync();
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener?.Stop();
    }
}
