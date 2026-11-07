using System.Globalization;
using System.Text.Json.Nodes;
using VeyMotion.App.Media;
using VeyMotion.App.Rendering;
using VeyMotion.Core;
using VeyMotion.Mcp;

namespace VeyMotion.App;

/// <summary>The app's services behind the tool layer (renderer, text/geometry engine, media, export).</summary>
static class AppServices
{
    public static McpServer CreateServer(ISceneHost host, Func<string?> project) => new(host, new FrameRenderer(), new Win2DPathGeometry())
    {
        Images = new ImageTools(),
        Media = new MediaProbe(),
        Fonts = new FontInfo(),
        Exporter = new VideoExporter(),
        Speech = new SpeechService(),
        Frames = new VideoFrames.Reader(),
        FontCatalog = DirectWriteFonts.Catalog,
        VieNeuVoices = () => string.Join(Environment.NewLine, VieNeu.Voices().Select(v => v.Label))
            + Environment.NewLine + "(VieNeu: Vietnamese voices; pass the id before \" — \" as `voice` with engine \"vieneu\")",
        VieNeuSynthesize = (text, voice, rate, folder) =>
        {
            var (path, duration, words) = VieNeu.Synthesize(text, voice, rate, folder, p => AudioDecoder.Shared.Stereo48k(p) is { } pcm ? pcm.Length / 2.0 / AudioMixer.SampleRate : null);
            return new VoiceResult(path, duration, words, false);
        },
        // New asset files (shatter shards…) go into the open project's assets folder, else the shared library.
        AssetDirectory = () => project() is { } p ? Path.Combine(p, "assets") : Path.Combine(AppPaths.SupportDirectory, "Assets"),
    };
}

/// <summary>
/// `VeyMotion.exe --frame|--render|--tool|--host …`: the app's renderer without a window, for the `vmotion` CLI
/// (frame, render, tools on a file that need the renderer, serve, daemon). Messages go to the `--log` file, the result
/// is the exit code (0 ok, 1 error, 2 usage).
/// </summary>
static class Headless
{
    public static bool IsHeadless(string[] args) => args.Length > 0 && args[0] is "--frame" or "--render" or "--tool" or "--host";

    static string? _log;

    static void Log(string message)
    {
        if (_log != null) File.AppendAllText(_log, message + "\n");
    }

    /// <summary>Runs a one-shot command and returns its exit code, or null for --host (keeps running).</summary>
    public static int? Run(string[] args)
    {
        var list = args.ToList();
        var li = list.IndexOf("--log");
        if (li >= 0 && li + 1 < list.Count) { _log = list[li + 1]; list.RemoveRange(li, 2); }
        try
        {
            return list[0] switch
            {
                "--frame" => Frame(list),
                "--render" => Render(list),
                "--tool" => Tool(list),
                _ => Host(list),
            };
        }
        catch (Exception e) when (e is SceneException or IOException or UnauthorizedAccessException or InvalidOperationException
            or System.Runtime.InteropServices.COMException or ArgumentException)
        {
            Log(e.Message);
            return 1;
        }
    }

    static MotionScene Load(string path)
    {
        if (ProjectStore.ProjectFor(path) is { } project) AssetStore.SetActiveLibrary(ProjectStore.AssetsPath(project));
        var scene = ProjectStore.LoadSceneFile(path);
        scene.RefreshMediaInfo(new MediaProbe());
        return scene;
    }

    static double Num(string s) => double.Parse(s, CultureInfo.InvariantCulture);

    // --frame <scene.json> <time> <out.png> [scale]
    static int Frame(List<string> a)
    {
        if (a.Count < 4) { Log("usage: vmotion frame <scene.json> <time> <out.png> [scale]"); return 2; }
        var scene = Load(a[1]);
        var png = new FrameRenderer().RenderPng(scene, Num(a[2]), a.Count > 4 ? Num(a[4]) : 1);
        File.WriteAllBytes(a[3], png);
        Log($"Wrote {a[3]}");
        return 0;
    }

    // --render <scene.json> <out.mp4> [--preset p] [--fit fit|fill] [--scale s] [--from t] [--to t]
    static int Render(List<string> a)
    {
        if (a.Count < 3) { Log("usage: vmotion render <scene.json> <out.mp4> [--preset p] [--fit fit|fill]"); return 2; }
        var scene = Load(a[1]);
        var o = new ExportOptions();
        for (var j = 3; j < a.Count; j += 2)
        {
            if (j + 1 >= a.Count) { Log($"{a[j]} needs a value"); return 2; }
            var v = a[j + 1];
            switch (a[j])
            {
                case "--preset":
                    var p = PlatformPreset.Named(v);
                    if (p == null) { Log($"Unknown preset '{v}'. Presets: {string.Join(", ", PlatformPreset.All.Select(x => x.Id))}"); return 2; }
                    o.Size = (p.Width, p.Height);
                    break;
                case "--fit":
                    if (JsonName<ExportFit>.Parse(v) is not { } f) { Log("--fit is fit or fill"); return 2; }
                    o.Fit = f;
                    break;
                case "--scale": o.Scale = Num(v); break;
                case "--from": o.Start = Num(v); break;
                case "--to": o.End = Num(v); break;
                default: Log($"Unknown option {a[j]}"); return 2;
            }
        }
        var started = DateTime.UtcNow;
        var last = -1;
        var frames = VideoExporter.Export(scene, a[2], o, new SyncProgress(p =>
        {
            var pct = (int)(p * 100);
            if (pct / 10 != last / 10) { last = pct; Log($"{pct}%"); }
        }));
        Log($"Wrote {Path.GetFullPath(a[2])} ({frames} frames, {(DateTime.UtcNow - started).TotalSeconds:0.0}s)");
        return 0;
    }

    sealed class SyncProgress(Action<double> report) : IProgress<double>
    {
        public void Report(double value) => report(value);
    }

    // --tool <scene.json> <request.json> <response.json>: one JSON-RPC message against the file, with the app's services.
    static int Tool(List<string> a)
    {
        if (a.Count < 4) return 2;
        var host = new FileSceneHost(a[1]);
        var server = AppServices.CreateServer(host, () => SceneStore.ProjectFor(a[1]));
        var request = JsonNode.Parse(File.ReadAllText(a[2])) as JsonObject ?? [];
        File.WriteAllText(a[3], (server.Handle(request) ?? []).ToJsonString());
        return 0;
    }

    // --host <scene.json> [--http port] [--pipe]: serve a file over MCP HTTP and/or the control pipe until killed.
    static int? Host(List<string> a)
    {
        if (a.Count < 2) return 2;
        var host = new FileSceneHost(a[1]);
        var server = AppServices.CreateServer(host, () => SceneStore.ProjectFor(a[1]));
        server.Log = Log;
        var hi = a.IndexOf("--http");
        if (hi >= 0)
        {
            var port = hi + 1 < a.Count && int.TryParse(a[hi + 1], out var p) ? p : McpHttpServer.DefaultPort;
            var http = new McpHttpServer(server, port, Environment.GetEnvironmentVariable("VEYMOTION_TOKEN"));
            http.StateChanged += Log;
            http.Start();
            Keep.Add(http);
        }
        if (a.Contains("--pipe"))
        {
            var pipe = new ControlPipeServer(server);
            pipe.Start();
            Keep.Add(pipe);
            Log($"Control pipe at \\\\.\\pipe\\{pipe.Name}");
        }
        return null;
    }

    static readonly List<IDisposable> Keep = [];
}
