using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Graphics.Canvas;
using Microsoft.UI.Dispatching;
using VeyMotion.Core;
using VeyMotion.Mcp;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Storage.Streams;

namespace VeyMotion.App.Chat;

public enum ChatItemKind { User, Assistant, Tool, Image, Notice, Summary }

public sealed class ToolCall
{
    public required string Id;
    public required string Title;
    public required string Detail;
    public bool IsDone;
    public bool IsError;
    public string Output = "";
}

/// <summary>An image waiting in the composer, or sent with a message.</summary>
public sealed class ChatAttachment
{
    public Guid Id { get; } = Guid.NewGuid();
    public required byte[] Data;
    public required string MediaType;
    /// <summary>Told to Claude with the message (not shown in the transcript).</summary>
    public string? Note;
    /// <summary>Scene time of a canvas frame, shown as a badge on the image.</summary>
    public double? Time;
}

public sealed class ChatItem
{
    public Guid Id { get; } = Guid.NewGuid();
    public ChatItemKind Kind;
    public string Text = "";
    public string MessageId = "";
    public List<ChatAttachment> Images = [];
    public ToolCall? Tool;
    public byte[]? ImageData;
    public double? Time;
    public bool IsError;
}

/// <summary>
/// State of the embedded Claude Code chat. Port of <c>ChatStore.swift</c>. Claude edits the scene through the
/// <c>vmotion</c> CLI, which reaches <see cref="SceneStore"/> over the control pipe, so every agent change is live and
/// undoable. Each project has its own conversation (transcript and Claude session) in <c>&lt;project&gt;\.chat.json</c>;
/// loose scenes share one in-memory conversation. All members are used on the UI thread.
/// </summary>
public sealed class ChatStore
{
    public static readonly string[] AllEfforts = ["low", "medium", "high", "xhigh", "max"];

    /// <summary>Used until (or if) <c>claude</c> has answered which models it offers.</summary>
    public static readonly List<ClaudeCodeAgent.ModelInfo> FallbackModels =
    [
        new("", null, "Default (recommended)", "", AllEfforts),
        new("opus", null, "Opus", "", AllEfforts),
        new("sonnet", null, "Sonnet", "", AllEfforts),
        new("haiku", null, "Haiku", "", []),
    ];

    public List<ClaudeCodeAgent.ModelInfo> Models { get; private set; } = FallbackModels;
    public ClaudeCodeAgent.ModelInfo? SelectedModel => Models.FirstOrDefault(m => m.Value == Model);

    /// <summary>Short name for the picker: "Default" resolves to the model it stands for (e.g. "Opus 5.5").</summary>
    public string ModelLabel
    {
        get
        {
            if (SelectedModel is not { } m) return Model.Length == 0 ? "Default" : Model;
            if (m.Value.Length == 0 && m.ResolvedModel is { } r && Models.FirstOrDefault(x => x.Value.Length > 0 && x.ResolvedModel == r) is { } same)
                return same.DisplayName;
            return m.DisplayName;
        }
    }

    /// <summary>Effort levels the selected model accepts (all of them while the list is unknown).</summary>
    public IReadOnlyList<string> ModelEfforts => SelectedModel?.Efforts ?? AllEfforts;

    public static string EffortName(string e) => e switch
    {
        "" => "Default",
        "xhigh" => "Extra high",
        _ => CultureInfo.InvariantCulture.TextInfo.ToTitleCase(e),
    };

    public List<ChatItem> Items { get; private set; } = [];
    public string Input = "";
    public List<ChatAttachment> Attachments { get; private set; } = [];
    public bool IsBusy { get; private set; }
    public string? Activity { get; private set; }
    public DateTime ActivityStart { get; private set; } = DateTime.Now;
    public string? ClaudePath { get; private set; }
    public string? SetupProblem { get; private set; }

    string _model = AppSettings.GetString("agent.model") ?? "";
    public string Model
    {
        get => _model;
        set
        {
            if (_model == value) return;
            _model = value;
            AppSettings.SetString("agent.model", value);
            _needsRestart = true; // the next message restarts the process with the new model (session resumes)
            Changed?.Invoke();
        }
    }

    string _effort = AppSettings.GetString("agent.effort") ?? "";
    public string Effort
    {
        get => _effort;
        set
        {
            if (_effort == value) return;
            _effort = value;
            AppSettings.SetString("agent.effort", value);
            _needsRestart = true;
            Changed?.Invoke();
        }
    }

    /// <summary>The whole transcript was replaced (project switch, new chat).</summary>
    public event Action? ItemsReset;
    public event Action<ChatItem>? ItemAdded;
    public event Action<ChatItem>? ItemChanged;
    /// <summary>Busy state, activity, attachments, models, setup or input changed.</summary>
    public event Action? Changed;

    readonly SceneStore _scene;
    readonly DispatcherQueue _dispatcher;
    ClaudeCodeAgent? _agent;
    bool _stoppedByUser;
    string _stderrTail = "";
    double? _pendingRenderTime;
    string? _lastSentText;
    List<ClaudeCodeAgent.ImageAttachment> _lastSentImages = [];
    /// <summary>Folders of files dropped into the chat, so the agent's Read can open them.</summary>
    readonly List<string> _readDirectories = [];
    bool _needsRestart;
    bool _retriedFresh;

    /// <summary>The scene as one prompt left it. <c>Prompt</c> is null for the scene before the first prompt.</summary>
    public sealed record Version(Guid Id, DateTime Date, string? Prompt, MotionScene Scene);
    public const int MaxVersions = 100;
    /// <summary>Snapshots taken after each prompt that changed the scene, oldest first.</summary>
    public List<Version> Versions { get; private set; } = [];
    (string Prompt, MotionScene Scene)? _turnStart;

    /// <summary>One project's conversation while another project is open.</summary>
    sealed class Conversation
    {
        public List<ChatItem> Items = [];
        public string Input = "";
        public List<ChatAttachment> Attachments = [];
        public string? SessionId;
        public bool ForkSession;
        public List<Version> Versions = [];
    }

    /// <summary>The project the shown conversation belongs to (null = loose scene).</summary>
    string? _project;
    readonly Dictionary<string, Conversation> _parked = [];
    string? _resumeSessionId;
    bool _forkNextSession;

    public ChatStore(SceneStore scene, DispatcherQueue dispatcher)
    {
        _scene = scene;
        _dispatcher = dispatcher;
        _project = scene.Project;
        RestoreConversation();
        scene.ProjectChanged += ProjectChanged;
        Task.Run(() =>
        {
            var path = ClaudeCodeAgent.LocateClaude();
            _dispatcher.TryEnqueue(() => { ClaudePath = path; CheckSetup(); Changed?.Invoke(); });
            if (path == null) return;
            var models = ClaudeCodeAgent.SupportedModels(path, AppPaths.AgentWorkingDirectory);
            if (models == null) return;
            // The CLI's `default` is stored as "" (no --model).
            var mapped = models.Select(m => m.Value == "default" ? m with { Value = "" } : m).ToList();
            _dispatcher.TryEnqueue(() => { Models = mapped; Changed?.Invoke(); });
        });
    }

    // Setup

    static string? VmotionDirectory
    {
        get
        {
            var dirs = new List<string>();
            if (Environment.GetEnvironmentVariable("VEYMOTION_CLI_DIR") is { Length: > 0 } env) dirs.Add(env);
            dirs.Add(AppContext.BaseDirectory);
            dirs.Add(Path.Combine(AppContext.BaseDirectory, "cli")); // debug builds copy it there
            return dirs.FirstOrDefault(d => File.Exists(Path.Combine(d, "vmotion.exe")));
        }
    }

    void CheckSetup()
    {
        if (ClaudePath == null)
            SetupProblem = "Claude Code (`claude`) was not found. Install it, run `claude` once in a terminal to log in, then reopen VeyMotion.";
        else if (VmotionDirectory == null)
            SetupProblem = "The `vmotion` CLI was not found next to the app. Build everything with `make build` (or `make bundle`).";
        else
            SetupProblem = null;
    }

    ClaudeCodeAgent? MakeAgent(string? resume)
    {
        CheckSetup();
        if (ClaudePath is not { } claude || VmotionDirectory is not { } dir) return null;
        var config = new ClaudeCodeAgent.Config
        {
            ClaudePath = claude,
            VmotionDirectory = dir,
            Model = Model,
            Effort = Effort,
            ExtraReadDirectories = [.. _readDirectories, .. (_project is { } p ? new[] { p } : Array.Empty<string>())],
            ForkSession = _forkNextSession,
            ExtraEnvironment = new()
            {
                ["VEYMOTION_FRAMES_DIR"] = AppPaths.FramesDirectory,
                ["VEYMOTION_PIPE"] = ControlPipe.DefaultName,
            },
        };
        var a = new ClaudeCodeAgent(config, resume);
        // Events still queued from a replaced agent (another project's) must not reach this conversation.
        a.OnEvent = ev => _dispatcher.TryEnqueue(() =>
        {
            if (ReferenceEquals(_agent, a)) Handle(ev);
        });
        return a;
    }

    // Actions

    public bool CanSend => !IsBusy && (Input.Trim().Length > 0 || Attachments.Count > 0);

    public void Send()
    {
        var text = Input.Trim();
        if (!CanSend) return;
        if (_needsRestart) RestartAgent();
        _agent ??= MakeAgent(_resumeSessionId);
        if (_agent is not { } agent)
        {
            Append(new ChatItem { Kind = ChatItemKind.Notice, Text = SetupProblem ?? "Claude Code is not available.", IsError = true });
            return;
        }
        var sent = Attachments;
        if (text.Length == 0) text = $"(see the attached image{(sent.Count == 1 ? "" : "s")})";
        var images = sent.Select(a => new ClaudeCodeAgent.ImageAttachment(a.MediaType, a.Data)).ToList();
        var notes = sent.Select(a => a.Note).OfType<string>().ToList();
        var agentText = notes.Count == 0 ? text : string.Join("\n", notes.Append(text));
        Input = "";
        Attachments = [];
        Append(new ChatItem { Kind = ChatItemKind.User, Text = text, Images = sent });
        IsBusy = true;
        _stoppedByUser = false;
        _retriedFresh = false;
        _lastSentText = agentText;
        _lastSentImages = images;
        _stderrTail = "";
        SetActivity("Thinking…");
        _turnStart = (text, _scene.Scene);
        try
        {
            agent.Send(ContextLine() + "\n" + agentText, images);
        }
        catch (Exception e) when (e is IOException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            IsBusy = false;
            Activity = null;
            _turnStart = null;
            Append(new ChatItem { Kind = ChatItemKind.Notice, Text = $"Could not start Claude Code: {e.Message}", IsError = true });
        }
        Changed?.Invoke();
    }

    // Versions

    /// <summary>Keeps the scene as the finished (or stopped) prompt left it, if the prompt changed it.</summary>
    void RecordVersion()
    {
        if (_turnStart is not { } start) return;
        _turnStart = null;
        var now = _scene.Scene;
        if (SceneJson.Encode(now, false) == SceneJson.Encode(start.Scene, false)) return;
        if (Versions.Count == 0) Versions.Add(new Version(Guid.NewGuid(), DateTime.Now, null, start.Scene));
        Versions.Add(new Version(Guid.NewGuid(), DateTime.Now, start.Prompt, now));
        if (Versions.Count > MaxVersions) Versions.RemoveRange(0, Versions.Count - MaxVersions);
        SaveVersions();
    }

    /// <summary>Puts a version's scene back (one undo step).</summary>
    public void Restore(Version version) => _scene.Apply("Restore Version", _ => version.Scene.Clone());

    static readonly DateTime ReferenceDate = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    /// <summary>Same JSON as the macOS <c>Version</c> Codable (dates as seconds since 2001, Swift's default).</summary>
    void SaveVersions()
    {
        if (_project is not { } project) return;
        var path = Path.Combine(project, SceneStore.VersionsFileName);
        try
        {
            if (Versions.Count == 0) { File.Delete(path); return; }
            var arr = new JsonArray(Versions.Select(v =>
            {
                var o = new JsonObject
                {
                    ["id"] = v.Id.ToString().ToUpperInvariant(),
                    ["date"] = (v.Date.ToUniversalTime() - ReferenceDate).TotalSeconds,
                };
                if (v.Prompt != null) o["prompt"] = v.Prompt;
                o["scene"] = SceneJson.ToNode(v.Scene);
                return (JsonNode)o;
            }).ToArray());
            SceneJson.Write(SceneJson.Encode(arr, pretty: false), path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or SceneException) { }
    }

    static List<Version> LoadVersions(string project)
    {
        try
        {
            var path = Path.Combine(project, SceneStore.VersionsFileName);
            if (!File.Exists(path) || JsonNode.Parse(File.ReadAllText(path)) is not JsonArray arr) return [];
            return arr.OfType<JsonObject>().Select(o => new Version(
                Guid.TryParse((string?)o["id"], out var g) ? g : Guid.NewGuid(),
                o["date"] is JsonValue d && d.TryGetValue(out double secs) ? ReferenceDate.AddSeconds(secs).ToLocalTime() : DateTime.Now,
                (string?)o["prompt"],
                SceneJson.FromNode(o["scene"]))).ToList();
        }
        catch (Exception e) when (e is IOException or JsonException or SceneException or UnauthorizedAccessException) { return []; }
    }

    // Attachments

    static readonly string[] Sendable = ["image/png", "image/jpeg", "image/gif", "image/webp"];

    /// <summary>Adds an image from raw bytes (pasted or picked). Formats the API does not take are re-encoded as PNG,
    /// and large images are scaled down so a message stays well under the API's size limit.</summary>
    public async Task AttachImageAsync(byte[] data, string? note = null, double? time = null)
    {
        try
        {
            var device = CanvasDevice.GetSharedDevice();
            using var input = new InMemoryRandomAccessStream();
            await input.WriteAsync(data.AsBuffer());
            input.Seek(0);
            using var bitmap = await CanvasBitmap.LoadAsync(device, input);
            var px = Math.Max(bitmap.SizeInPixels.Width, bitmap.SizeInPixels.Height);
            var type = MediaType(data);
            if (type != null && Sendable.Contains(type) && data.Length <= 3_500_000 && px <= 2000)
            {
                Attachments.Add(new ChatAttachment { Data = data, MediaType = type, Note = note, Time = time });
            }
            else
            {
                var scale = Math.Min(1, 2000.0 / px);
                var w = Math.Max(1, (int)Math.Round(bitmap.SizeInPixels.Width * scale));
                var h = Math.Max(1, (int)Math.Round(bitmap.SizeInPixels.Height * scale));
                using var target = new CanvasRenderTarget(device, w, h, 96);
                using (var ds = target.CreateDrawingSession())
                    ds.DrawImage(bitmap, new Windows.Foundation.Rect(0, 0, w, h));
                using var output = new InMemoryRandomAccessStream();
                await target.SaveAsync(output, CanvasBitmapFileFormat.Png);
                var png = new byte[output.Size];
                using var reader = new DataReader(output.GetInputStreamAt(0));
                await reader.LoadAsync((uint)output.Size);
                reader.ReadBytes(png);
                Attachments.Add(new ChatAttachment { Data = png, MediaType = "image/png", Note = note, Time = time });
            }
            Changed?.Invoke();
        }
        catch (Exception e) when (e is IOException or ArgumentException or System.Runtime.InteropServices.COMException)
        {
            // Not an image Win2D can read.
        }
    }

    public async Task AttachImageFileAsync(string path)
    {
        try { await AttachImageAsync(await File.ReadAllBytesAsync(path)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public void RemoveAttachment(Guid id)
    {
        Attachments.RemoveAll(a => a.Id == id);
        Changed?.Invoke();
    }

    /// <summary>Lets the agent's Read open files dropped into the chat. Takes effect when the process next starts, so
    /// an idle agent is restarted (the session resumes).</summary>
    public void AllowReading(IEnumerable<string> paths)
    {
        var added = false;
        foreach (var path in paths)
        {
            var dir = Directory.Exists(path) ? path : Path.GetDirectoryName(path);
            if (dir == null) continue;
            var covered = _readDirectories.Concat(_project is { } p ? [p] : Array.Empty<string>());
            if (covered.Any(c => dir.Equals(c, StringComparison.OrdinalIgnoreCase)
                    || dir.StartsWith(c.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase))) continue;
            _readDirectories.Add(dir);
            added = true;
        }
        if (!added) return;
        if (IsBusy) _needsRestart = true; else RestartAgent();
    }

    /// <summary>Replaces the agent with one started with the current Read folders, resuming the same session.
    /// The old process is detached first so its exit is not reported as an error.</summary>
    void RestartAgent()
    {
        _needsRestart = false;
        if (_agent is not { } old) return;
        var session = old.SessionId ?? _resumeSessionId;
        old.OnEvent = null;
        old.Stop();
        _agent = MakeAgent(session);
    }

    static string? MediaType(byte[] b)
    {
        if (b.Length >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return "image/png";
        if (b.Length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return "image/jpeg";
        if (b.Length >= 3 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return "image/gif";
        if (b.Length >= 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) return "image/webp";
        return null;
    }

    public void Stop()
    {
        if (!IsBusy) return;
        _stoppedByUser = true;
        _agent?.Stop();
        RecordVersion();
        IsBusy = false;
        Activity = null;
        Append(new ChatItem { Kind = ChatItemKind.Notice, Text = "Stopped. Your next message continues the same conversation." });
        Changed?.Invoke();
    }

    public void NewChat()
    {
        RecordVersion();
        _stoppedByUser = true;
        _agent?.Reset();
        _agent = null;
        _resumeSessionId = null;
        _forkNextSession = false;
        Items = [];
        Attachments = [];
        IsBusy = false;
        Activity = null;
        SaveConversation();
        ItemsReset?.Invoke();
        Changed?.Invoke();
    }

    /// <summary>Saves the open project's conversation (call when the app closes).</summary>
    public void Shutdown()
    {
        SaveConversation();
        if (_agent is { } a) { a.OnEvent = null; a.Stop(); }
    }

    // Per-project conversations

    void ProjectChanged(string? project)
    {
        if (string.Equals(project, _project, StringComparison.OrdinalIgnoreCase)) return;
        ParkConversation();
        _project = project;
        RestoreConversation();
    }

    static string Key(string? project) => project?.ToLowerInvariant() ?? "";

    /// <summary>Stops the agent (its <c>vmotion</c> calls would otherwise edit the next project's scene) and stores
    /// the conversation, in memory and in the project folder. The session resumes when the project is reopened.</summary>
    void ParkConversation()
    {
        var session = _agent?.SessionId ?? _resumeSessionId;
        if (_agent is { } a) { a.OnEvent = null; a.Stop(); }
        _agent = null;
        RecordVersion();
        if (IsBusy)
            Append(new ChatItem { Kind = ChatItemKind.Notice, Text = "Stopped because you switched projects. Your next message here continues the conversation." });
        IsBusy = false;
        Activity = null;
        _pendingRenderTime = null;
        _needsRestart = false;
        _resumeSessionId = session;
        SaveConversation();
        _parked[Key(_project)] = new Conversation
        {
            Items = Items, Input = Input, Attachments = Attachments, SessionId = session, ForkSession = _forkNextSession, Versions = Versions,
        };
    }

    /// <summary>Shows the open project's conversation: from this run if it was open before, else from its folder.</summary>
    void RestoreConversation()
    {
        Conversation c;
        if (_parked.Remove(Key(_project), out var parked)) c = parked;
        else if (_project is { } p)
        {
            c = LoadConversation(p) ?? new Conversation();
            c.Versions = LoadVersions(p);
        }
        else c = new Conversation();
        Items = c.Items;
        Versions = c.Versions;
        Input = c.Input;
        Attachments = c.Attachments;
        _resumeSessionId = c.SessionId;
        _forkNextSession = c.ForkSession;
        _stderrTail = "";
        ItemsReset?.Invoke();
        Changed?.Invoke();
    }

    static readonly JsonSerializerOptions PrettyJson = new() { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>Writes the open project's conversation to its folder (nothing for loose scenes). On disk: text only
    /// (images are dropped), long tool outputs shortened; the same JSON as macOS.</summary>
    void SaveConversation()
    {
        if (_project is not { } project) return;
        var path = Path.Combine(project, SceneStore.ChatFileName);
        var session = _agent?.SessionId ?? _resumeSessionId;
        try
        {
            if (Items.Count == 0 && session == null) { File.Delete(path); return; }
            var saved = new JsonArray();
            foreach (var item in Items.TakeLast(500))
            {
                // Keys sorted, optionals left out, like the macOS encoder (sortedKeys).
                JsonObject o = item.Kind switch
                {
                    ChatItemKind.User => new() { ["kind"] = "user", ["text"] = item.Text },
                    ChatItemKind.Assistant => new() { ["kind"] = "assistant", ["text"] = item.Text },
                    ChatItemKind.Tool => new()
                    {
                        ["detail"] = item.Tool!.Detail, ["isError"] = item.Tool.IsError, ["kind"] = "tool",
                        ["output"] = item.Tool.Output.Length > 4000 ? item.Tool.Output[..4000] : item.Tool.Output, ["text"] = item.Tool.Title,
                    },
                    ChatItemKind.Notice => new() { ["isError"] = item.IsError, ["kind"] = "notice", ["text"] = item.Text },
                    ChatItemKind.Summary => new() { ["kind"] = "summary", ["text"] = item.Text },
                    _ => null!,
                };
                if (o != null) saved.Add(o);
            }
            var chat = new JsonObject();
            if (_forkNextSession) chat["forkSession"] = true;
            chat["items"] = saved;
            chat["project"] = project;
            if (session != null) chat["sessionId"] = session;
            File.WriteAllText(path, chat.ToJsonString(PrettyJson));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    static Conversation? LoadConversation(string project)
    {
        try
        {
            var path = Path.Combine(project, SceneStore.ChatFileName);
            if (!File.Exists(path) || JsonNode.Parse(File.ReadAllText(path)) is not JsonObject chat) return null;
            var items = new List<ChatItem>();
            var i = 0;
            foreach (var s in (chat["items"] as JsonArray ?? []).OfType<JsonObject>())
            {
                var text = (string?)s["text"] ?? "";
                var isError = (bool?)s["isError"] ?? false;
                ChatItem? item = (string?)s["kind"] switch
                {
                    "user" => new() { Kind = ChatItemKind.User, Text = text },
                    "assistant" => new() { Kind = ChatItemKind.Assistant, Text = text, MessageId = $"saved-{i}" },
                    "tool" => new()
                    {
                        Kind = ChatItemKind.Tool,
                        Tool = new ToolCall { Id = $"saved-{i}", Title = text, Detail = (string?)s["detail"] ?? "", IsDone = true, IsError = isError, Output = (string?)s["output"] ?? "" },
                    },
                    "notice" => new() { Kind = ChatItemKind.Notice, Text = text, IsError = isError },
                    "summary" => new() { Kind = ChatItemKind.Summary, Text = text },
                    _ => null,
                };
                if (item != null) items.Add(item);
                i++;
            }
            var sessionId = (string?)chat["sessionId"];
            var savedProject = (string?)chat["project"] ?? project;
            // Read from another folder that is a project too, it is a copy (duplicated, or Save As), so that copy's
            // conversation forks the session instead of continuing the original's.
            var copied = !string.Equals(savedProject, project, StringComparison.OrdinalIgnoreCase)
                && File.Exists(Path.Combine(savedProject, SceneStore.SceneFileName));
            return new Conversation
            {
                Items = items, SessionId = sessionId,
                ForkSession = sessionId != null && (copied || ((bool?)chat["forkSession"] ?? false)),
            };
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException) { return null; }
    }

    /// <summary>Prefixed to every message so "this"/"here"/"now" resolve against the editor state.</summary>
    string ContextLine()
    {
        var s = _scene.Scene;
        var ids = s.Layers.Select(l => l.Id).ToList();
        if (ids.Count > 30) ids = [.. ids.Take(30), "…"];
        var project = _scene.Project is { } p ? $"; project={Path.GetFileName(p)}" : "";
        var selected = _scene.SelectedLayer is { } l ? $"{l.Id} ({l.Type.Json()})" : "none";
        return string.Create(CultureInfo.InvariantCulture,
            $"[VeyMotion context: playhead={_scene.Time:0.00}s; selected={selected}; scene={s.Width}x{s.Height} {s.Fps}fps {s.Duration:0.00}s; layers (bottom→top)={string.Join(", ", ids)}{project}]");
    }

    // Events

    void Handle(AgentEvent ev)
    {
        switch (ev)
        {
            case AgentEvent.Started started:
                // A copied project's conversation has forked by now: later restarts resume the new session.
                _forkNextSession = false;
                if (started.SessionId.Length > 0) _resumeSessionId = started.SessionId;
                break;

            case AgentEvent.Thinking:
                if (IsBusy && Activity != "Thinking…") SetActivity("Thinking…");
                break;

            case AgentEvent.ToolInputProgress progress:
            {
                if (!IsBusy) break;
                var label = progress.Name == "Bash" ? "Writing command" : $"Preparing {progress.Name}";
                var size = progress.Bytes >= 1024 ? string.Create(CultureInfo.InvariantCulture, $"{progress.Bytes / 1024.0:0.0} KB") : $"{progress.Bytes} B";
                if (progress.Bytes == 0) SetActivity($"{label}…"); else Activity = $"{label} ({size})…";
                break;
            }

            case AgentEvent.TextDelta delta:
                Activity = null;
                if (Items.Count > 0 && Items[^1] is { Kind: ChatItemKind.Assistant } last && last.MessageId == delta.MessageId)
                {
                    last.Text += delta.Chunk;
                    ItemChanged?.Invoke(last);
                }
                else Append(new ChatItem { Kind = ChatItemKind.Assistant, Text = delta.Chunk, MessageId = delta.MessageId });
                break;

            case AgentEvent.Text text:
                Activity = null;
                Append(new ChatItem { Kind = ChatItemKind.Assistant, Text = text.Value, MessageId = text.MessageId });
                break;

            case AgentEvent.ToolUse use:
            {
                var call = Describe(use.Id, use.Name, use.Input);
                SetActivity($"Running {call.Title}…");
                Append(new ChatItem { Kind = ChatItemKind.Tool, Tool = call });
                break;
            }

            case AgentEvent.ToolResult result:
            {
                if (Items.LastOrDefault(i => i.Tool?.Id == result.ToolUseId) is { } item)
                {
                    item.Tool!.IsDone = true;
                    item.Tool.IsError = result.IsError;
                    item.Tool.Output = result.Output;
                    ItemChanged?.Invoke(item);
                }
                if (result.Image != null)
                {
                    Append(new ChatItem { Kind = ChatItemKind.Image, ImageData = result.Image, Time = _pendingRenderTime });
                    _pendingRenderTime = null;
                }
                if (IsBusy) SetActivity("Thinking…"); else Activity = null;
                break;
            }

            case AgentEvent.TurnFinished finished:
            {
                if (finished.IsError && _stderrTail.Contains("No conversation found")) return; // handled on exit (fresh-session retry)
                IsBusy = false;
                Activity = null;
                _retriedFresh = false;
                RecordVersion();
                if (finished.IsError)
                    Append(new ChatItem { Kind = ChatItemKind.Notice, Text = finished.Result ?? "Claude Code reported an error.", IsError = true });
                var parts = new List<string>();
                if (finished.DurationMs is { } ms) parts.Add(string.Create(CultureInfo.InvariantCulture, $"{ms / 1000.0:0.0}s"));
                if (finished.CostUsd is > 0 and var cost) parts.Add(string.Create(CultureInfo.InvariantCulture, $"${cost:0.000}"));
                if (parts.Count > 0) Append(new ChatItem { Kind = ChatItemKind.Summary, Text = string.Join(" · ", parts) });
                SaveConversation();
                break;
            }

            case AgentEvent.Stderr err:
                _stderrTail = (_stderrTail + err.Output) is var tail && tail.Length > 2000 ? tail[^2000..] : tail;
                break;

            case AgentEvent.Exited exited:
            {
                var wasBusy = IsBusy;
                IsBusy = false;
                Activity = null;
                // Resume failed (session file missing): start a fresh session and resend once.
                if (!_stoppedByUser && _stderrTail.Contains("No conversation found") && _lastSentText is { } text && !_retriedFresh)
                {
                    _retriedFresh = true;
                    _agent?.Reset();
                    _resumeSessionId = null;
                    _forkNextSession = false;
                    Append(new ChatItem { Kind = ChatItemKind.Notice, Text = "Couldn't resume the previous conversation, so a new one was started." });
                    IsBusy = true;
                    SetActivity("Thinking…");
                    _stderrTail = "";
                    try { _agent?.Send(ContextLine() + "\n" + text, _lastSentImages); }
                    catch (Exception e) when (e is IOException or InvalidOperationException or System.ComponentModel.Win32Exception)
                    {
                        IsBusy = false;
                        Activity = null;
                        Append(new ChatItem { Kind = ChatItemKind.Notice, Text = $"Could not start Claude Code: {e.Message}", IsError = true });
                    }
                    break;
                }
                RecordVersion();
                if (!_stoppedByUser && (exited.Code != 0 || wasBusy))
                {
                    var detail = _stderrTail.Trim();
                    Append(new ChatItem { Kind = ChatItemKind.Notice, Text = $"Claude Code exited (code {exited.Code}).{(detail.Length == 0 ? "" : "\n" + detail)}", IsError = true });
                }
                break;
            }
        }
        Changed?.Invoke();
    }

    ToolCall Describe(string id, string name, JsonObject input)
    {
        if (name == "Bash" && (string?)input["command"] is { } cmd)
        {
            var trimmed = cmd.Trim();
            foreach (var prefix in new[] { "vmotion ", "vmotion.exe " })
            {
                if (!trimmed.StartsWith(prefix, StringComparison.Ordinal)) continue;
                var rest = trimmed[prefix.Length..];
                var sub = rest.Split(' ', 2)[0];
                var detail = rest[sub.Length..].Trim();
                if (detail.Length >= 2 && detail[0] == '\'' && detail[^1] == '\'') detail = detail[1..^1];
                if (sub is "render_frame" or "render-frame")
                {
                    try
                    {
                        if (JsonNode.Parse(detail)?["time"] is JsonValue t && t.GetValueKind() == JsonValueKind.Number) _pendingRenderTime = SceneJson.ToDouble(t);
                    }
                    catch (JsonException) { }
                }
                return new ToolCall { Id = id, Title = sub.Replace('_', ' '), Detail = detail };
            }
            return new ToolCall { Id = id, Title = "Bash", Detail = cmd };
        }
        if (name == "Read" && (string?)input["file_path"] is { } path)
            return new ToolCall { Id = id, Title = "look at frame", Detail = Path.GetFileName(path) };
        return new ToolCall { Id = id, Title = name, Detail = "" };
    }

    /// <summary>Sets a new activity phase and restarts its elapsed-time clock.</summary>
    void SetActivity(string text)
    {
        Activity = text;
        ActivityStart = DateTime.Now;
    }

    void Append(ChatItem item)
    {
        Items.Add(item);
        ItemAdded?.Invoke(item);
    }
}
