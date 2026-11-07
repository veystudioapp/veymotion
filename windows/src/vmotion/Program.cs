using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using VeyMotion.Core;
using VeyMotion.Mcp;

// Port of Sources/vmotion/main.swift.

Console.OutputEncoding = new UTF8Encoding(false);

const string Usage = """
vmotion — VeyMotion command line (Windows)

EDIT A SCENE (talks to the running VeyMotion app, or edits a file with --scene)
  vmotion <command> ['<json-args>' | -] [--scene file.json] [--out frame.png]
                                                  (or set VEYMOTION_SCENE=file.json instead of --scene)
  vmotion tools                                   List commands and their arguments
  vmotion docs                                    Scene format reference

FILES
  vmotion sample <scene.json>                     Write the demo scene
  vmotion check  <scene.json>                     Validate a scene and print it as VeyMotion writes it
  vmotion frame  <scene.json> <time> <out.png> [scale]
  vmotion render <scene.json> <out.mp4|out.m4a> [--preset tiktok|shorts|reels|youtube|facebook|x|square] [--fit fit|fill]

AGENT
  vmotion chat [--model m] "prompt"               One Claude Code turn in the terminal (edits the app's scene)

SERVERS
  vmotion mcp    <scene.json>                     MCP over stdio, editing the file
  vmotion serve  <scene.json> [port]              MCP over HTTP (default port 19790)
  vmotion daemon <scene.json>                     Control pipe for a file (headless app stand-in)

frame, render, serve, daemon and tools that draw (render_frame, text_to_path…) on a --scene file run the
VeyMotion app's renderer without a window (VeyMotion.exe next to vmotion, or VEYMOTION_APP).
""";

static int Fail(string message, int code = 1)
{
    Console.Error.WriteLine(message);
    return code;
}

if (args.Length == 0) { Console.WriteLine(Usage); return 0; }
var command = args[0];
var rest = args[1..];

switch (command)
{
    case "help" or "--help" or "-h":
        Console.WriteLine(Usage);
        return 0;

    case "tools":
        Console.WriteLine(ToolCatalog.CliUsage);
        return 0;

    case "docs":
        Console.WriteLine(ToolCatalog.SceneReference);
        return 0;

    case "sample":
        if (rest.Length < 1) return Fail(Usage);
        try
        {
            File.WriteAllText(rest[0], SampleScene.Json);
            Console.WriteLine($"Wrote {rest[0]}");
            return 0;
        }
        catch (Exception e) { return Fail(e.Message); }

    case "check":
        if (rest.Length < 1) return Fail(Usage);
        try
        {
            Console.WriteLine(SceneJson.Encode(SceneJson.Load(rest[0])));
            return 0;
        }
        catch (Exception e) when (e is SceneException or IOException or UnauthorizedAccessException)
        {
            return Fail($"Cannot read {rest[0]}: {e.Message}");
        }

    case "mcp":
    {
        if (rest.Length < 1) return Fail(Usage);
        FileSceneHost host;
        try { host = new FileSceneHost(rest[0]); }
        catch (Exception e) when (e is SceneException or IOException or UnauthorizedAccessException) { return Fail(e.Message); }
        var server = new McpServer(host) { Log = m => Console.Error.WriteLine(m) };
        using var stdin = new StreamReader(Console.OpenStandardInput(), Encoding.UTF8);
        while (stdin.ReadLine() is { } line)
        {
            if (line.Trim().Length == 0) continue;
            JsonNode? response;
            try { response = JsonNode.Parse(line) is JsonObject obj ? server.Handle(obj) : McpServer.Error(null, -32700, "Parse error"); }
            catch (JsonException) { response = McpServer.Error(null, -32700, "Parse error"); }
            if (response != null) Console.WriteLine(response.ToJsonString());
        }
        return 0;
    }

    case "frame":
        if (rest.Length < 3) return Fail(Usage);
        return RunApp(["--frame", .. rest]);

    case "render":
        if (rest.Length < 2) return Fail(Usage);
        return RunApp(["--render", .. rest]);

    case "serve":
        if (rest.Length < 1) return Fail(Usage);
        return RunApp(["--host", rest[0], "--http", rest.Length > 1 ? rest[1] : McpHttpServer.DefaultPort.ToString(CultureInfo.InvariantCulture)], follow: true);

    case "daemon":
        if (rest.Length < 1) return Fail(Usage);
        return RunApp(["--host", rest[0], "--pipe"], follow: true);

    case "chat":
        return Chat(rest);

    default:
        if (ToolCatalog.ToolName(command) is { } tool) return RunTool(tool, rest);
        if (Docs.MissingTools.Contains(command.Replace('-', '_')))
            return Fail($"{command.Replace('-', '_')} is not available in VeyMotion for Windows yet. `vmotion tools` lists what is.");
        return Fail($"Unknown command '{command}'.\n\n{Usage}");
}

/// <summary>VeyMotion.exe: VEYMOTION_APP, next to vmotion (the bundle), or one folder up (the debug build's cli\).</summary>
static string? AppPath()
{
    if (Environment.GetEnvironmentVariable("VEYMOTION_APP") is { Length: > 0 } env && File.Exists(env)) return env;
    var dir = AppContext.BaseDirectory;
    foreach (var candidate in new[] { Path.Combine(dir, "VeyMotion.exe"), Path.Combine(dir, "..", "VeyMotion.exe") })
        if (File.Exists(candidate)) return Path.GetFullPath(candidate);
    return null;
}

/// <summary>Runs the app without a window and prints its messages. With follow, keeps printing until it is
/// stopped (Ctrl+C stops it too).</summary>
static int RunApp(string[] appArgs, bool follow = false)
{
    if (AppPath() is not { } app) return Fail("VeyMotion.exe not found next to vmotion (set VEYMOTION_APP to its path).");
    var log = Path.Combine(Path.GetTempPath(), $"vmotion-{Guid.NewGuid():N}.log");
    var psi = new System.Diagnostics.ProcessStartInfo(app) { UseShellExecute = false };
    foreach (var a in appArgs) psi.ArgumentList.Add(a);
    psi.ArgumentList.Add("--log");
    psi.ArgumentList.Add(log);
    using var p = System.Diagnostics.Process.Start(psi)!;
    Console.CancelKeyPress += (_, e) => { e.Cancel = true; try { p.Kill(); } catch (InvalidOperationException) { } };
    long shown = 0;
    void Pump()
    {
        try
        {
            if (!File.Exists(log)) return;
            using var fs = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            fs.Seek(shown, SeekOrigin.Begin);
            using var r = new StreamReader(fs);
            var text = r.ReadToEnd();
            shown = fs.Position;
            if (text.Length > 0) Console.Write(text);
        }
        catch (IOException) { }
    }
    while (!p.WaitForExit(follow ? 300 : 200)) Pump();
    Pump();
    try { File.Delete(log); } catch (IOException) { }
    return p.ExitCode;
}

/// <summary>vmotion chat [--model m] "prompt": one agent turn in the terminal, against the app or $VEYMOTION_SCENE.</summary>
static int Chat(string[] rest)
{
    string? model = null;
    var words = new List<string>();
    for (var j = 0; j < rest.Length; j++)
    {
        if (rest[j] == "--model" && j + 1 < rest.Length) model = rest[++j];
        else words.Add(rest[j]);
    }
    var prompt = string.Join(" ", words);
    if (prompt.Length == 0) return Fail("usage: vmotion chat [--model m] \"prompt\"");
    if (ClaudeCodeAgent.LocateClaude() is not { } claude) return Fail("Claude Code (`claude`) not found. Install it and run `claude` once to log in.");
    var workDir = Environment.GetEnvironmentVariable("VEYMOTION_AGENT_DIR") is { Length: > 0 } wd ? wd : AppPaths.AgentWorkingDirectory;
    var env = new Dictionary<string, string>();
    if (Environment.GetEnvironmentVariable("VEYMOTION_FRAMES_DIR") == null) env["VEYMOTION_FRAMES_DIR"] = Path.Combine(workDir, "frames");
    var agent = new ClaudeCodeAgent(new ClaudeCodeAgent.Config
    {
        ClaudePath = claude, VmotionDirectory = AppContext.BaseDirectory, WorkingDirectory = workDir, Model = model, ExtraEnvironment = env,
    });
    var done = new TaskCompletionSource<int>();
    var lastWasDelta = false;
    agent.OnEvent = ev =>
    {
        switch (ev)
        {
            case AgentEvent.Started s: Console.WriteLine($"· session {s.SessionId[..Math.Min(8, s.SessionId.Length)]} · {s.Model}"); break;
            case AgentEvent.ToolInputProgress t when t.Bytes > 0 && t.Bytes % 4096 < 512:
                Console.Error.WriteLine($"  … writing {t.Name} input {t.Bytes / 1024} KB"); break;
            case AgentEvent.TextDelta d: Console.Write(d.Chunk); lastWasDelta = true; break;
            case AgentEvent.Text t: if (!lastWasDelta) Console.WriteLine(t.Value); break;
            case AgentEvent.ToolUse u:
                if (lastWasDelta) { Console.WriteLine(); lastWasDelta = false; }
                var detail = (string?)u.Input["command"] ?? (string?)u.Input["file_path"] ?? "";
                Console.WriteLine($"▸ {u.Name}: {detail[..Math.Min(200, detail.Length)]}");
                break;
            case AgentEvent.ToolResult r:
                var first = r.Output.Split('\n').FirstOrDefault() ?? "";
                Console.WriteLine($"  {(r.IsError ? "✗" : "✓")} {first[..Math.Min(160, first.Length)]}{(r.Image != null ? " [image]" : "")}");
                break;
            case AgentEvent.TurnFinished f:
                if (lastWasDelta) Console.WriteLine();
                Console.WriteLine(string.Create(CultureInfo.InvariantCulture, $"· {(f.IsError ? "error" : "done")} · {(f.DurationMs ?? 0) / 1000.0:0.0}s · ${f.CostUsd ?? 0:0.0000}"));
                agent.Finish();
                done.TrySetResult(f.IsError ? 1 : 0);
                break;
            case AgentEvent.Stderr e: Console.Error.Write(e.Output); break;
            case AgentEvent.Exited x: done.TrySetResult(x.Code); break;
        }
    };
    try
    {
        agent.Start();
        agent.Send(prompt);
    }
    catch (Exception e) when (e is IOException or InvalidOperationException or System.ComponentModel.Win32Exception) { return Fail(e.Message); }
    return done.Task.GetAwaiter().GetResult();
}

/// <summary>Runs one tool, either against the running app (control pipe) or a scene file.</summary>
static int RunTool(string tool, string[] rest)
{
    string? scenePath = null, outPath = null, json = null;
    for (var i = 0; i < rest.Length;)
    {
        switch (rest[i])
        {
            case "--scene":
                if (i + 1 >= rest.Length) return Fail("--scene needs a path");
                scenePath = rest[i + 1]; i += 2;
                break;
            case "--out":
                if (i + 1 >= rest.Length) return Fail("--out needs a path");
                outPath = rest[i + 1]; i += 2;
                break;
            default:
                json = rest[i]; i += 1;
                break;
        }
    }
    if (scenePath == null && Environment.GetEnvironmentVariable("VEYMOTION_SCENE") is { Length: > 0 } env) scenePath = env;
    if (json == "-") json = Console.In.ReadToEnd();

    var arguments = new JsonObject();
    if (!string.IsNullOrWhiteSpace(json))
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject obj) return Fail("Arguments must be a JSON object, e.g. '{\"id\": \"title\"}'", 2);
            arguments = obj;
        }
        catch (JsonException e) { return Fail($"Invalid JSON arguments: {e.Message}", 2); }
    }

    var request = new JsonObject
    {
        ["jsonrpc"] = "2.0", ["id"] = 1, ["method"] = "tools/call",
        ["params"] = new JsonObject { ["name"] = tool, ["arguments"] = arguments.DeepClone() },
    };
    JsonObject response;
    if (scenePath != null)
    {
        try { response = new McpServer(new FileSceneHost(scenePath)).Handle(request) ?? []; }
        catch (Exception e) when (e is SceneException or IOException or UnauthorizedAccessException) { return Fail(e.Message); }
        // Tools that draw or read pictures need the app's renderer: run them through it, without a window.
        if (response["result"]?["content"]?[0]?["text"] is JsonValue tv0 && ((string?)tv0 ?? "").Contains("needs the VeyMotion app") && AppPath() != null)
        {
            var req = Path.GetTempFileName();
            var resp = Path.GetTempFileName();
            try
            {
                File.WriteAllText(req, request.ToJsonString());
                if (RunApp(["--tool", Path.GetFullPath(scenePath), req, resp]) != 0) return 1;
                response = JsonNode.Parse(File.ReadAllText(resp)) as JsonObject ?? [];
            }
            finally { File.Delete(req); File.Delete(resp); }
        }
    }
    else
    {
        try { response = ControlPipeClient.Send(request); }
        catch (Exception e) when (e is TimeoutException or IOException or UnauthorizedAccessException)
        {
            return Fail($"VeyMotion app is not running ({e.Message}). Open the app, or pass --scene <file.json>.", 3);
        }
    }

    if (response["error"] is JsonObject err)
    {
        Console.WriteLine($"Error: {(string?)err["message"] ?? "unknown"}");
        return 1;
    }
    var result = response["result"] as JsonObject ?? [];
    foreach (var item in (result["content"] as JsonArray ?? []).OfType<JsonObject>())
    {
        switch ((string?)item["type"])
        {
            case "text":
                Console.WriteLine((string?)item["text"] ?? "");
                break;
            case "image":
                if ((string?)item["data"] is not { } b64) continue;
                string path;
                if (outPath != null) path = Path.GetFullPath(outPath);
                else
                {
                    var label = arguments["time"] is JsonValue tv && tv.GetValueKind() == JsonValueKind.Number
                        ? string.Create(CultureInfo.InvariantCulture, $"frame-{SceneJson.ToDouble(tv):0.00}s") : tool;
                    path = Path.Combine(AppPaths.FramesDirectory, $"{label}-{Guid.NewGuid().ToString("N")[..6]}.png");
                }
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                    File.WriteAllBytes(path, Convert.FromBase64String(b64));
                    Console.WriteLine($"Frame saved: {path}\n(Open it with the Read tool to see it.)");
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or FormatException)
                {
                    Console.WriteLine($"Error: cannot save frame: {e.Message}");
                    return 1;
                }
                break;
        }
    }
    return result["isError"] is JsonValue ie && ie.GetValueKind() == JsonValueKind.True ? 1 : 0;
}
