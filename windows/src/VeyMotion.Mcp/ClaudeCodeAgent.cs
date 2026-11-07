using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VeyMotion.Core;

namespace VeyMotion.Mcp;

/// <summary>Events emitted by <see cref="ClaudeCodeAgent"/>, decoded from Claude Code's stream-json output.</summary>
public abstract record AgentEvent
{
    public sealed record Started(string SessionId, string Model) : AgentEvent;
    public sealed record Thinking : AgentEvent;
    /// <summary>Streaming text for an assistant message.</summary>
    public sealed record TextDelta(string MessageId, string Chunk) : AgentEvent;
    /// <summary>A complete text block (only sent when it was not already streamed).</summary>
    public sealed record Text(string MessageId, string Value) : AgentEvent;
    /// <summary>The model is streaming a tool call's input (can take a while for large commands).</summary>
    public sealed record ToolInputProgress(string Name, int Bytes) : AgentEvent;
    public sealed record ToolUse(string Id, string Name, JsonObject Input) : AgentEvent;
    public sealed record ToolResult(string ToolUseId, string Output, bool IsError, byte[]? Image) : AgentEvent;
    public sealed record TurnFinished(bool IsError, string? Result, double? CostUsd, int? DurationMs) : AgentEvent;
    public sealed record Stderr(string Output) : AgentEvent;
    public sealed record Exited(int Code) : AgentEvent;
}

/// <summary>
/// Runs Claude Code headless (<c>claude -p</c> with stream-json in/out), restricted to the <c>vmotion</c> CLI and
/// Read. The process stays alive across turns; <see cref="Stop"/> kills it and the next <see cref="Send"/> resumes
/// the same session. Port of <c>ClaudeCodeAgent.swift</c>.
/// </summary>
public sealed class ClaudeCodeAgent(ClaudeCodeAgent.Config config, string? resumeSessionId = null)
{
    public sealed class Config
    {
        public required string ClaudePath { get; init; }
        /// <summary>Directory containing <c>vmotion.exe</c>; prepended to PATH.</summary>
        public required string VmotionDirectory { get; init; }
        public string WorkingDirectory { get; init; } = AppPaths.AgentWorkingDirectory;
        public string? Model { get; set; }
        /// <summary><c>--effort</c> level (low, medium, high, xhigh, max); null/empty uses Claude Code's default.</summary>
        public string? Effort { get; set; }
        public Dictionary<string, string> ExtraEnvironment { get; init; } = [];
        public string SystemPrompt { get; init; } = AgentPrompt.SystemPrompt;
        /// <summary>More folders Read may open (e.g. folders of files dropped into the chat).</summary>
        public List<string> ExtraReadDirectories { get; init; } = [];
        /// <summary>Resume into a new session id instead of continuing the original (<c>--fork-session</c>).</summary>
        public bool ForkSession { get; set; }
    }

    public Config Settings { get; } = config;
    /// <summary>Called on a background thread; hop to the UI thread for UI work.</summary>
    public Action<AgentEvent>? OnEvent { get; set; }
    public string? SessionId { get; private set; } = resumeSessionId;

    Process? _process;
    readonly HashSet<string> _streamedMessages = [];
    string _currentMessageId = "";
    string _currentToolName = "";
    int _toolInputBytes, _lastReportedBytes;
    readonly Lock _writeLock = new();

    public bool IsRunning => _process is { HasExited: false };

    /// <summary>The system prompt goes through a file: the Windows command line is limited to 32,767 characters and
    /// the prompt (with the scene reference) is larger.</summary>
    string SystemPromptFile => Path.Combine(Settings.WorkingDirectory, "system-prompt.md");

    public List<string> Arguments()
    {
        var args = new List<string>
        {
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--tools", "Bash,Read",
            "--allowedTools", "Bash(vmotion:*)", "Bash(vmotion *)", "Read",
        };
        if (Settings.ExtraReadDirectories.Count > 0) { args.Add("--add-dir"); args.AddRange(Settings.ExtraReadDirectories); }
        args.AddRange(["--strict-mcp-config", "--setting-sources", "", "--append-system-prompt-file", SystemPromptFile]);
        // TODO(port): macOS passes sandbox.network.allowUnixSockets; Claude Code's Bash sandbox does not run on
        // Windows, and named pipes need no such exception.
        if (!string.IsNullOrEmpty(Settings.Model)) args.AddRange(["--model", Settings.Model]);
        if (!string.IsNullOrEmpty(Settings.Effort)) args.AddRange(["--effort", Settings.Effort]);
        if (SessionId != null)
        {
            args.AddRange(["--resume", SessionId]);
            if (Settings.ForkSession) args.Add("--fork-session");
        }
        return args;
    }

    public void Start()
    {
        if (IsRunning) return;
        Directory.CreateDirectory(Settings.WorkingDirectory);
        File.WriteAllText(SystemPromptFile, Settings.SystemPrompt, new UTF8Encoding(false));

        var psi = new ProcessStartInfo(Settings.ClaudePath)
        {
            WorkingDirectory = Settings.WorkingDirectory,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in Arguments()) psi.ArgumentList.Add(a);
        psi.Environment["PATH"] = Settings.VmotionDirectory + Path.PathSeparator + (psi.Environment["PATH"] ?? "");
        // Claude Code runs Bash through Git Bash: keep MSYS from rewriting "/…" inside the JSON arguments as paths.
        psi.Environment["MSYS_NO_PATHCONV"] = "1";
        psi.Environment["MSYS2_ARG_CONV_EXCL"] = "*";
        foreach (var (k, v) in Settings.ExtraEnvironment) psi.Environment[k] = v;

        var p = Process.Start(psi) ?? throw new InvalidOperationException("Could not start Claude Code");
        _process = p;
        var stdout = Task.Run(async () =>
        {
            while (await p.StandardOutput.ReadLineAsync() is { } line)
            {
                if (line.Length == 0) continue;
                try { if (JsonNode.Parse(line) is JsonObject obj) HandleLine(obj); }
                catch (JsonException) { /* not a JSON line */ }
            }
        });
        _ = Task.Run(async () =>
        {
            var buffer = new char[4096];
            int n;
            while ((n = await p.StandardError.ReadAsync(buffer)) > 0) OnEvent?.Invoke(new AgentEvent.Stderr(new string(buffer, 0, n)));
        });
        _ = Task.Run(async () =>
        {
            await p.WaitForExitAsync();
            await stdout; // report everything it printed before the exit
            OnEvent?.Invoke(new AgentEvent.Exited(p.ExitCode));
        });
    }

    /// <summary>An image sent with a user message (base64 image block).</summary>
    public sealed record ImageAttachment(string MediaType, byte[] Data);

    public void Send(string text, IReadOnlyList<ImageAttachment>? images = null)
    {
        if (!IsRunning) Start();
        var content = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text });
        foreach (var image in images ?? [])
        {
            content.Add(new JsonObject
            {
                ["type"] = "image",
                ["source"] = new JsonObject { ["type"] = "base64", ["media_type"] = image.MediaType, ["data"] = Convert.ToBase64String(image.Data) },
            });
        }
        var msg = new JsonObject { ["type"] = "user", ["message"] = new JsonObject { ["role"] = "user", ["content"] = content } };
        lock (_writeLock)
        {
            _process!.StandardInput.Write(msg.ToJsonString() + "\n");
            _process.StandardInput.Flush();
        }
    }

    /// <summary>Kills the running process (interrupting the current turn). The session can be resumed.</summary>
    public void Stop()
    {
        if (_process is not { HasExited: false } p) return;
        try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
    }

    /// <summary>Closes stdin so the process exits after the current turn.</summary>
    public void Finish()
    {
        try { _process?.StandardInput.Close(); } catch (InvalidOperationException) { }
    }

    /// <summary>Forget the session; the next <see cref="Send"/> starts a fresh conversation.</summary>
    public void Reset()
    {
        Stop();
        SessionId = null;
    }

    // Parsing

    static string? S(JsonNode? n) => n is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    void HandleLine(JsonObject obj)
    {
        switch (S(obj["type"]))
        {
            case "system":
                if (S(obj["subtype"]) == "init")
                {
                    var sid = S(obj["session_id"]) ?? "";
                    if (sid.Length > 0)
                    {
                        SessionId = sid;
                        Settings.ForkSession = false; // forked now; a restart resumes this new session
                    }
                    OnEvent?.Invoke(new AgentEvent.Started(sid, S(obj["model"]) ?? ""));
                }
                break;

            case "stream_event":
                if (obj["event"] is not JsonObject ev) return;
                switch (S(ev["type"]))
                {
                    case "message_start":
                        _currentMessageId = S(ev["message"]?["id"]) ?? Guid.NewGuid().ToString();
                        break;
                    case "content_block_start":
                        var block = ev["content_block"] as JsonObject;
                        if (S(block?["type"]) == "tool_use")
                        {
                            _currentToolName = S(block?["name"]) ?? "tool";
                            _toolInputBytes = 0;
                            _lastReportedBytes = 0;
                            OnEvent?.Invoke(new AgentEvent.ToolInputProgress(_currentToolName, 0));
                        }
                        else if (S(block?["type"]) == "thinking") OnEvent?.Invoke(new AgentEvent.Thinking());
                        break;
                    case "content_block_delta":
                        var delta = ev["delta"] as JsonObject;
                        switch (S(delta?["type"]))
                        {
                            case "text_delta":
                                _streamedMessages.Add(_currentMessageId);
                                OnEvent?.Invoke(new AgentEvent.TextDelta(_currentMessageId, S(delta?["text"]) ?? ""));
                                break;
                            case "thinking_delta":
                                OnEvent?.Invoke(new AgentEvent.Thinking());
                                break;
                            case "input_json_delta":
                                _toolInputBytes += Encoding.UTF8.GetByteCount(S(delta?["partial_json"]) ?? "");
                                if (_toolInputBytes - _lastReportedBytes >= 512) // throttle UI updates
                                {
                                    _lastReportedBytes = _toolInputBytes;
                                    OnEvent?.Invoke(new AgentEvent.ToolInputProgress(_currentToolName, _toolInputBytes));
                                }
                                break;
                        }
                        break;
                }
                break;

            case "assistant":
            {
                if (obj["message"] is not JsonObject msg) return;
                var id = S(msg["id"]) ?? "";
                foreach (var b in (msg["content"] as JsonArray ?? []).OfType<JsonObject>())
                {
                    switch (S(b["type"]))
                    {
                        case "text":
                            if (!_streamedMessages.Contains(id) && S(b["text"]) is { Length: > 0 } t) OnEvent?.Invoke(new AgentEvent.Text(id, t));
                            break;
                        case "tool_use":
                            OnEvent?.Invoke(new AgentEvent.ToolUse(S(b["id"]) ?? "", S(b["name"]) ?? "",
                                b["input"]?.DeepClone() as JsonObject ?? []));
                            break;
                    }
                }
                break;
            }

            case "user":
            {
                if (obj["message"]?["content"] is not JsonArray blocks) return;
                foreach (var b in blocks.OfType<JsonObject>().Where(b => S(b["type"]) == "tool_result"))
                {
                    var text = "";
                    byte[]? image = null;
                    if (S(b["content"]) is { } s) text = s;
                    else
                    {
                        foreach (var part in (b["content"] as JsonArray ?? []).OfType<JsonObject>())
                        {
                            if (S(part["type"]) == "text") text += (text.Length == 0 ? "" : "\n") + (S(part["text"]) ?? "");
                            else if (S(part["type"]) == "image" && S(part["source"]?["data"]) is { } b64)
                            {
                                try { image = Convert.FromBase64String(b64); } catch (FormatException) { }
                            }
                        }
                    }
                    OnEvent?.Invoke(new AgentEvent.ToolResult(S(b["tool_use_id"]) ?? "", text,
                        b["is_error"] is JsonValue e && e.GetValueKind() == JsonValueKind.True, image));
                }
                break;
            }

            case "result":
                if (S(obj["session_id"]) is { Length: > 0 } rsid) SessionId = rsid;
                OnEvent?.Invoke(new AgentEvent.TurnFinished(
                    obj["is_error"] is JsonValue ie && ie.GetValueKind() == JsonValueKind.True,
                    S(obj["result"]),
                    obj["total_cost_usd"] is JsonValue c && c.GetValueKind() == JsonValueKind.Number ? SceneJson.ToDouble(c) : null,
                    obj["duration_ms"] is JsonValue d && d.GetValueKind() == JsonValueKind.Number ? (int)SceneJson.ToDouble(d) : null));
                break;
        }
    }

    // Discovery

    /// <summary>A model the user's own <c>claude</c> offers (from the CLI's <c>initialize</c> control response).</summary>
    public sealed record ModelInfo(string Value, string? ResolvedModel, string DisplayName, string Description, IReadOnlyList<string> Efforts);

    /// <summary>Asks <c>claude</c> which models this account and CLI version offer. Costs a short-lived process and
    /// no tokens. Blocking (up to <paramref name="timeout"/>); call it off the UI thread. Null on failure.</summary>
    public static List<ModelInfo>? SupportedModels(string claudePath, string workingDirectory, TimeSpan? timeout = null)
    {
        try
        {
            Directory.CreateDirectory(workingDirectory);
            var psi = new ProcessStartInfo(claudePath)
            {
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardInputEncoding = new UTF8Encoding(false),
                StandardOutputEncoding = Encoding.UTF8,
            };
            foreach (var a in new[] { "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--strict-mcp-config", "--setting-sources", "" })
                psi.ArgumentList.Add(a);
            using var p = Process.Start(psi);
            if (p == null) return null;
            _ = p.StandardError.ReadToEndAsync();
            p.StandardInput.Write("""{"type":"control_request","request_id":"veymotion-models","request":{"subtype":"initialize"}}""" + "\n");
            p.StandardInput.Flush();

            var read = Task.Run(() =>
            {
                while (p.StandardOutput.ReadLine() is { } line)
                {
                    JsonObject? obj;
                    try { obj = JsonNode.Parse(line) as JsonObject; } catch (JsonException) { continue; }
                    if (S(obj?["type"]) != "control_response" || obj?["response"] is not JsonObject response
                        || S(response["request_id"]) != "veymotion-models") continue;
                    var models = response["response"]?["models"] as JsonArray ?? [];
                    return models.OfType<JsonObject>().Select(m =>
                    {
                        var value = S(m["value"]);
                        if (value == null) return null;
                        var efforts = m["supportsEffort"] is JsonValue se && se.GetValueKind() == JsonValueKind.True
                            ? (m["supportedEffortLevels"] as JsonArray ?? []).Select(S).OfType<string>().ToList() : [];
                        return new ModelInfo(value, S(m["resolvedModel"]), S(m["displayName"]) ?? value, S(m["description"]) ?? "", efforts);
                    }).OfType<ModelInfo>().ToList();
                }
                return null;
            });
            var done = read.Wait(timeout ?? TimeSpan.FromSeconds(15));
            try { p.StandardInput.Close(); } catch (IOException) { }
            if (!p.HasExited) try { p.Kill(true); } catch (InvalidOperationException) { }
            return done && read.Result is { Count: > 0 } list ? list : null;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException or InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>Finds the <c>claude</c> executable: %VEYMOTION_CLAUDE%, the native installer's path, then PATH.</summary>
    public static string? LocateClaude()
    {
        if (Environment.GetEnvironmentVariable("VEYMOTION_CLAUDE") is { Length: > 0 } env && File.Exists(env)) return env;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = new List<string>
        {
            Path.Combine(home, ".local", "bin", "claude.exe"),
            Path.Combine(home, ".claude", "local", "claude.exe"),
        };
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            candidates.Add(Path.Combine(dir.Trim('"'), "claude.exe"));
        return candidates.FirstOrDefault(File.Exists);
    }
}
