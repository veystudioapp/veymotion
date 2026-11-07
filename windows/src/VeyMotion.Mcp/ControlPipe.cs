using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Mcp;

/// <summary>
/// Local control channel between the <c>vmotion</c> CLI and a running VeyMotion app: a named pipe (the Windows
/// counterpart of the macOS unix socket), current user only, one newline-terminated JSON-RPC message per connection,
/// handled by the same <see cref="McpServer"/> tool layer the MCP transports use.
/// </summary>
public static class ControlPipe
{
    /// <summary>Pipe name: <c>VEYMOTION_PIPE</c>, else one per user.</summary>
    public static string DefaultName =>
        Environment.GetEnvironmentVariable("VEYMOTION_PIPE") is { Length: > 0 } n ? n : $"veymotion-control-{Environment.UserName}";

    static readonly UTF8Encoding Utf8 = new(false);

    internal static async Task WriteLineAsync(Stream s, JsonNode message, CancellationToken ct = default)
    {
        var bytes = Utf8.GetBytes(message.ToJsonString() + "\n");
        await s.WriteAsync(bytes, ct);
        await s.FlushAsync(ct);
    }

    /// <summary>Reads until a newline or EOF (at most 64 MB).</summary>
    internal static async Task<string> ReadLineAsync(Stream s, CancellationToken ct = default)
    {
        var buffer = new MemoryStream();
        var chunk = new byte[65536];
        while (buffer.Length < 64 << 20)
        {
            var n = await s.ReadAsync(chunk, ct);
            if (n == 0) break;
            var nl = Array.IndexOf(chunk, (byte)'\n', 0, n);
            buffer.Write(chunk, 0, nl >= 0 ? nl : n);
            if (nl >= 0) break;
        }
        return Utf8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length);
    }
}

public sealed class ControlPipeServer(McpServer server, string? name = null) : IDisposable
{
    public string Name { get; } = name ?? ControlPipe.DefaultName;
    readonly CancellationTokenSource _cts = new();

    /// <summary>Starts accepting connections on background tasks. Throws if another app already owns the pipe.</summary>
    public void Start()
    {
        // Creating the first instance up front surfaces "already in use" (another VeyMotion) to the caller.
        var first = Create(firstInstance: true);
        _ = Task.Run(() => AcceptLoop(first));
    }

    NamedPipeServerStream Create(bool firstInstance = false) => new(
        Name, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances, PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly | (firstInstance ? PipeOptions.FirstPipeInstance : 0));

    async Task AcceptLoop(NamedPipeServerStream pipe)
    {
        while (!_cts.IsCancellationRequested)
        {
            try { await pipe.WaitForConnectionAsync(_cts.Token); }
            catch { pipe.Dispose(); return; }
            var connected = pipe;
            _ = Task.Run(() => Serve(connected));
            try { pipe = Create(); }
            catch { return; }
        }
        pipe.Dispose();
    }

    async Task Serve(NamedPipeServerStream pipe)
    {
        await using var _ = pipe;
        try
        {
            var line = await ControlPipe.ReadLineAsync(pipe, _cts.Token);
            JsonNode response;
            try
            {
                response = JsonNode.Parse(line) is JsonObject obj ? server.Handle(obj) ?? [] : McpServer.Error(null, -32700, "Parse error");
            }
            catch (JsonException) { response = McpServer.Error(null, -32700, "Parse error"); }
            await ControlPipe.WriteLineAsync(pipe, response, _cts.Token);
            if (OperatingSystem.IsWindows()) pipe.WaitForPipeDrain();
        }
        catch (IOException) { /* client went away */ }
        catch (OperationCanceledException) { }
    }

    public void Dispose() => _cts.Cancel();
}

public static class ControlPipeClient
{
    public static JsonObject Send(JsonObject message, string? name = null, int timeoutMs = 2000)
    {
        using var pipe = new NamedPipeClientStream(".", name ?? ControlPipe.DefaultName, PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        pipe.Connect(timeoutMs);
        ControlPipe.WriteLineAsync(pipe, message).GetAwaiter().GetResult();
        var reply = ControlPipe.ReadLineAsync(pipe).GetAwaiter().GetResult();
        return JsonNode.Parse(reply) as JsonObject ?? throw new IOException("invalid reply");
    }
}
