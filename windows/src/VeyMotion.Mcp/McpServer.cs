using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using VeyMotion.Core;

namespace VeyMotion.Mcp;

/// <summary>Where the MCP server reads and writes the scene. The app routes mutations through its undo stack;
/// the CLI host writes them to a file.</summary>
public interface ISceneHost
{
    /// <summary>A snapshot; do not mutate it.</summary>
    MotionScene CurrentScene();

    /// <summary>Runs <paramref name="body"/> on a working copy of the scene and keeps the scene it returns.</summary>
    void Mutate(string label, Func<MotionScene, MotionScene> body);
}

public static class SceneHostExtensions
{
    public static void Mutate(this ISceneHost host, string label, Action<MotionScene> body) =>
        host.Mutate(label, s => { body(s); return s; });
}

/// <summary>Renders a frame to PNG (the app's Win2D renderer). The CLI has none yet.</summary>
public interface IFrameRenderer
{
    byte[] RenderPng(MotionScene scene, double time, double scale);
}

/// <summary>Renders a scene to a video file (the app's Win2D + Media Foundation).</summary>
public interface IVideoExporter
{
    /// <summary>Returns the number of frames written.</summary>
    int Export(MotionScene scene, string path, ExportOptions options);
}

/// <summary>Installed fonts (the app's DirectWrite), for warnings about text layers.</summary>
public interface IFontInfo
{
    /// <summary>Whether a family (or full font name) is installed.</summary>
    bool Exists(string name);

    /// <summary>The letters of the text the font cannot draw.</summary>
    string MissingCharacters(string text, string name, string weight);

    /// <summary>Installed families with similar names.</summary>
    IReadOnlyList<string> Suggestions(string name);
}

/// <summary>Reads pictures for image tools (the app's Win2D). The CLI has none yet.</summary>
public interface IImageTools
{
    /// <summary>The picture's natural size (an SVG's vector size) and the size of its pixels; null if unreadable.</summary>
    (double NaturalW, double NaturalH, int PixelW, int PixelH)? Info(string path);

    /// <summary>PNG of the picture clipped to the quad and cropped to the box (pixel space, y down).</summary>
    byte[] ShardPng(string path, PathPoint[] quad, double x, double y, double w, double h);
}

/// <summary>Transport-independent MCP (JSON-RPC 2.0) request handler. Port of <c>MCPServer.swift</c>.</summary>
public sealed class McpServer(ISceneHost host, IFrameRenderer? renderer = null, IPathGeometry? geometry = null)
{
    public const string ServerName = "veymotion";
    public const string ServerVersion = "0.1.0";
    static readonly string[] SupportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

    public Action<string> Log { get; set; } = _ => { };

    /// <summary>Picture access for shatter_image.</summary>
    public IImageTools? Images { get; init; }

    /// <summary>File lengths of audio and video layers.</summary>
    public IMediaProbe? Media { get; init; }

    /// <summary>Font checks for text layers.</summary>
    public IFontInfo? Fonts { get; init; }

    /// <summary>export_video.</summary>
    public IVideoExporter? Exporter { get; init; }

    /// <summary>Video frames for stabilize, track_motion and auto_reframe.</summary>
    public IVideoFrameReader? Frames { get; init; }

    /// <summary>list_voices, generate_voice, transcribe.</summary>
    public ISpeech? Speech { get; init; }

    /// <summary>Folder new asset files go to (the open project's assets, else the shared library).</summary>
    public Func<string> AssetDirectory { get; init; } = () => AssetStore.Directory;

    /// <summary>Installed and library fonts, for list_fonts and import_stock (the app's DirectWrite).</summary>
    public FontCatalog? FontCatalog { get; init; }
    /// <summary>search_stock: contact sheet of results (bitmap thumbnails) and the waveform sheet of sounds.</summary>
    public Func<IReadOnlyList<StockItem>, byte[]?>? ContactSheet { get; init; }
    public Func<IReadOnlyList<string?>, byte[]?>? SoundSheet { get; init; }

    /// <summary>Handles one JSON-RPC message. Returns null for notifications.</summary>
    public JsonObject? Handle(JsonObject message)
    {
        var id = message["id"]?.DeepClone();
        if (message["method"] is not JsonValue mv || mv.GetValueKind() != JsonValueKind.String)
            return id == null ? null : Error(id, -32600, "Invalid request");
        if (id == null) return null; // notification (e.g. notifications/initialized)
        var method = mv.GetValue<string>();
        var parameters = message["params"] as JsonObject ?? [];
        try
        {
            return new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = Dispatch(method, parameters) };
        }
        catch (MethodNotFound e) { return Error(id, -32601, $"Method not found: {e.Message}"); }
        catch (InvalidParams e) { return Error(id, -32602, e.Message); }
        catch (Exception e) { return Error(id, -32603, e.Message); }
    }

    sealed class MethodNotFound(string m) : Exception(m);
    sealed class InvalidParams(string m) : Exception(m);
    sealed class ToolError(string m) : Exception(m);

    public static JsonObject Error(JsonNode? id, int code, string message) => new()
    {
        ["jsonrpc"] = "2.0",
        ["id"] = id,
        ["error"] = new JsonObject { ["code"] = code, ["message"] = message },
    };

    JsonObject Dispatch(string method, JsonObject p)
    {
        switch (method)
        {
            case "initialize":
                var requested = (string?)p["protocolVersion"] ?? "";
                return new JsonObject
                {
                    ["protocolVersion"] = SupportedVersions.Contains(requested) ? requested : SupportedVersions[0],
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
                    ["serverInfo"] = new JsonObject { ["name"] = ServerName, ["version"] = ServerVersion },
                    ["instructions"] = Docs.Instructions,
                };
            case "ping":
                return [];
            case "tools/list":
                return new JsonObject { ["tools"] = Docs.ToolsArray };
            case "tools/call":
                if (p["name"] is not JsonValue nv || nv.GetValueKind() != JsonValueKind.String) throw new InvalidParams("missing tool name");
                var name = nv.GetValue<string>();
                var args = p["arguments"] as JsonObject ?? [];
                Log($"tool {name}");
                try { return CallTool(name, args); }
                catch (InvalidParams) { throw; }
                catch (Exception e) when (e is not MethodNotFound)
                {
                    // Tool failures are reported to the model, not as protocol errors.
                    return new JsonObject
                    {
                        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = $"Error: {e.Message}" }),
                        ["isError"] = true,
                    };
                }
            default:
                throw new MethodNotFound(method);
        }
    }

    // Tools

    JsonObject CallTool(string name, JsonObject a)
    {
        switch (name)
        {
            case "get_scene":
                return Text(SceneJson.Encode(host.CurrentScene()));

            case "set_scene":
            {
                if (a["scene"] is not JsonObject obj) throw new ToolError("`scene` must be an object");
                var scene = SceneJson.FromNode(obj);
                var problems = scene.RefreshMediaInfo(Media);
                host.Mutate("Set Scene", _ => scene);
                return Text($"Scene set: {scene.Width}x{scene.Height} @{scene.Fps}fps, {Num(scene.Duration)}s, {scene.Layers.Count} layers: "
                    + string.Join(", ", scene.Layers.Select(l => l.Id)) + Warnings([.. problems, .. FontNotes(scene.Layers)]));
            }

            case "update_scene":
            {
                if (a["changes"] is not JsonObject changes) throw new ToolError("`changes` must be an object");
                host.Mutate("Update Scene", s => s.UpdatingSettings(changes));
                var s = host.CurrentScene();
                return Text($"Scene: {s.Width}x{s.Height} @{s.Fps}fps, {Num(s.Duration)}s, background {s.Background.Hex}");
            }

            case "add_layer":
            {
                if (a["layer"] is not JsonObject obj) throw new ToolError("`layer` must be an object");
                var layer = LayerCodec.Decode(obj, "layer");
                var index = a["index"] is JsonValue iv && iv.GetValueKind() == JsonValueKind.Number ? (int?)SceneJson.ToDouble(iv) : null;
                var newId = "";
                List<string> problems = [];
                host.Mutate("Add Layer", s =>
                {
                    newId = s.AddLayer(layer, index);
                    problems = s.RefreshMediaInfo(Media);
                });
                return Text($"Added layer '{newId}'" + Warnings([.. problems, .. FontNotes([host.CurrentScene().Layer(newId)])]));
            }

            case "add_layers":
            {
                if (a["layers"] is not JsonArray { Count: > 0 } list) throw new ToolError("`layers` must be a non-empty array");
                var layers = list.Select((n, i) => LayerCodec.Decode(n, $"layers[{i}]")).ToList();
                var ids = new List<string>();
                List<string> problems = [];
                host.Mutate($"Add {layers.Count} Layers", s =>
                {
                    ids = layers.Select(l => s.AddLayer(l)).ToList();
                    problems = s.RefreshMediaInfo(Media);
                });
                var added = host.CurrentScene().Layers.Where(l => ids.Contains(l.Id)).ToList();
                return Text($"Added {ids.Count} layers: {string.Join(", ", ids)} (scene now has {host.CurrentScene().Layers.Count})"
                    + Warnings([.. problems, .. FontNotes(added)]));
            }

            case "update_layer":
            {
                var id = Str(a, "id");
                if (a["changes"] is not JsonObject changes) throw new ToolError("`changes` must be an object");
                var newId = (string?)(changes["id"] as JsonValue) ?? id;
                host.Mutate("Update Layer", s =>
                {
                    s.UpdateLayer(id, changes);
                    // A new file or image-sequence rate: re-read its length.
                    if ((changes.ContainsKey("path") || changes.ContainsKey("fps")) && s.Layers.FirstOrDefault(l => l.Id == newId) is { } changed)
                        changed.SourceDuration = null;
                    s.RefreshMediaInfo(Media);
                });
                var updated = host.CurrentScene().Layer(newId);
                return Text(SceneJson.Encode(LayerCodec.Encode(updated)) + Warnings([.. FontNotes([updated]), .. PictureML.CutoutNotes(updated, a, Frames, null)]));
            }

            case "remove_layer":
            {
                var id = Str(a, "id");
                host.Mutate("Remove Layer", s => s.RemoveLayer(id));
                return Text($"Removed '{id}'");
            }

            case "reorder_layer":
            {
                var id = Str(a, "id");
                if (a["index"] is not JsonValue iv || iv.GetValueKind() != JsonValueKind.Number) throw new ToolError("`index` must be an integer");
                var index = (int)SceneJson.ToDouble(iv);
                host.Mutate("Reorder Layer", s => s.MoveLayer(id, index));
                return Text($"Order (bottom→top): {string.Join(", ", host.CurrentScene().Layers.Select(l => l.Id))}");
            }

            case "set_keyframes":
            {
                var id = Str(a, "id");
                var property = Str(a, "property");
                if (property == "d")
                {
                    var shapes = ModelCodec.PathKeyframes(a["keyframes"] ?? new JsonArray());
                    host.Mutate("Set Keyframes", s => s.SetPathKeyframes(id, shapes));
                    return Text($"{id}.d = {ModelCodec.Encode(host.CurrentScene().Layer(id).D).ToJsonString()}");
                }
                var track = KeyTrack.FromName(property)
                    ?? throw new ToolError($"`property` must be one of [{string.Join(", ", KeyTrack.AllNames.Append("d"))}]");
                var raw = a["keyframes"] ?? new JsonArray();
                if (track.Number is { } prop)
                {
                    var kfs = SceneJson.NumberKeyframes(raw);
                    host.Mutate("Set Keyframes", s => s.SetKeyframes(id, prop, kfs));
                    return Text($"{id}.{prop.Json()} = {SceneJson.CompactJson(host.CurrentScene().Layer(id)[prop])}");
                }
                var c = track.Color!.Value;
                var ckfs = SceneJson.ColorKeyframes(raw);
                host.Mutate("Set Keyframes", s => s.SetColorKeyframes(id, c, ckfs.ToList()));
                return Text($"{id}.{c.Json()} = {SceneJson.CompactJson(host.CurrentScene().Layer(id)[c])}");
            }

            case "apply_preset":
            {
                var preset = JsonName<Preset>.Parse(Str(a, "preset"))
                    ?? throw new ToolError($"`preset` must be one of [{string.Join(", ", JsonName<Preset>.All)}]");
                var start = Number(a["start"]) ?? throw new ToolError("`start` must be a number");
                var duration = Number(a["duration"]) ?? 0.6;
                var ids = (a["ids"] as JsonArray)?.Select(x => x is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null)
                    .OfType<string>().ToList() ?? [];
                if ((string?)(a["id"] as JsonValue) is { Length: > 0 } single) ids.Insert(0, single);
                if (ids.Count == 0) throw new ToolError("Give `id` or `ids`");
                var stagger = Number(a["stagger"]) ?? 0;
                var done = new List<string>();
                host.Mutate($"Apply {preset}", s => { done = s.ApplyPreset(preset, ids, start, duration, stagger); });
                var skipped = ids.Where(i => !done.Contains(i)).ToList();
                return Text($"Applied {preset.Json()} to {string.Join(", ", done)} from {Num(start)}s for {Num(duration)}s"
                    + (done.Count > 1 ? $" (stagger {Num(stagger)}s)" : "")
                    + (skipped.Count == 0 ? "" : $"; skipped (not applicable): {string.Join(", ", skipped)}"));
            }

            case "transition":
            {
                var type = JsonName<TransitionType>.Parse(Str(a, "type"))
                    ?? throw new ToolError($"`type` must be one of [{string.Join(", ", JsonName<TransitionType>.All)}]");
                var at = Number(a["at"]) ?? throw new ToolError("`at` must be a number");
                var d = Number(a["duration"]) ?? 0.6;
                var outId = (string?)(a["out"] as JsonValue) is { Length: > 0 } o ? o : null;
                var inId = (string?)(a["in"] as JsonValue) is { Length: > 0 } i ? i : null;
                var direction = (string?)(a["direction"] as JsonValue);
                host.Mutate("Transition", s => s.Transition(type, outId, inId, at, d, direction));
                return Text($"{type.Json()} transition" + (outId != null ? $" out: {outId}" : "") + (inId != null ? $" in: {inId}" : "")
                    + $" from {Num(at)}s for {Num(d)}s");
            }

            case "group_layers":
            {
                var ids = (a["ids"] as JsonArray)?.Select(x => (string?)(x as JsonValue)).OfType<string>().ToList();
                if (ids is not { Count: > 0 }) throw new ToolError("`ids` must be a non-empty array of layer ids");
                var gid = "";
                host.Mutate("Group Layers", s => { gid = s.GroupLayers(ids, (string?)(a["id"] as JsonValue), (string?)(a["name"] as JsonValue)); });
                return Text($"Grouped {string.Join(", ", ids)} into '{gid}' (centered on the scene; children keep their coordinates)");
            }

            case "ungroup":
            {
                var id = Str(a, "id");
                var count = 0;
                host.Mutate("Ungroup", s => { count = s.Layer(id).Children.Count; s.Ungroup(id); });
                return Text($"Ungrouped '{id}': {count} layers are top-level again");
            }

            case "set_parent":
            {
                var id = Str(a, "id");
                var parent = (string?)(a["parent"] as JsonValue);
                var t = Number(a["time"]) ?? 0;
                var keep = a["keepPosition"] is JsonValue kv && kv.GetValueKind() == JsonValueKind.False ? false : true;
                host.Mutate("Set Parent", s => s.SetParent(id, parent, t, keep));
                var l = host.CurrentScene().Layer(id);
                return Text((parent != null ? $"'{id}' now follows '{parent}'" : $"'{id}' has no parent")
                    + $"; x/y: {SceneJson.CompactJson(l.X)}, {SceneJson.CompactJson(l.Y)}");
            }

            case "render_frame":
            {
                var t = Number(a["time"]) ?? throw new ToolError("`time` must be a number");
                var scale = Math.Clamp(Number(a["scale"]) ?? 0.5, 0.1, 1);
                if (renderer == null)
                    throw new ToolError("render_frame needs the VeyMotion app on Windows (the CLI cannot render yet). Open the app and run without --scene.");
                var scene = host.CurrentScene();
                var png = renderer.RenderPng(scene, t, scale);
                var visible = scene.Layers.Where(l => l.IsVisible(t, scene.Duration)).Select(l => l.Id);
                return new JsonObject
                {
                    ["content"] = new JsonArray(
                        new JsonObject { ["type"] = "image", ["data"] = Convert.ToBase64String(png), ["mimeType"] = "image/png" },
                        new JsonObject { ["type"] = "text", ["text"] = $"t={Num(t)}s, visible layers: {string.Join(", ", visible)}" }),
                };
            }

            case "shatter_image":
            {
                var scene = host.CurrentScene();
                string sourcePath, prefix;
                double px, py, start;
                double? pw, ph;
                var sourceId = (string?)(a["layer"] as JsonValue) is { Length: > 0 } sid ? sid : null;
                if (sourceId != null)
                {
                    var l = scene.Layer(sourceId);
                    if (l.Type != LayerType.Image || l.Path == null) throw new ToolError($"'{sourceId}' is not an image layer with a file");
                    sourcePath = l.Path;
                    px = l.X.ValueAt(l.Start); py = l.Y.ValueAt(l.Start);
                    pw = l.Width?.ValueAt(l.Start); ph = l.Height?.ValueAt(l.Start);
                    start = Number(a["at"]) ?? l.Start;
                    prefix = (string?)(a["id"] as JsonValue) is { Length: > 0 } pid ? pid : sourceId;
                }
                else
                {
                    sourcePath = Str(a, "path");
                    px = Number(a["x"]) ?? scene.Width / 2.0;
                    py = Number(a["y"]) ?? scene.Height / 2.0;
                    pw = Number(a["width"]); ph = Number(a["height"]);
                    start = Number(a["at"]) ?? 0;
                    prefix = (string?)(a["id"] as JsonValue) is { Length: > 0 } pid ? pid : "shatter";
                }
                var images = Images ?? throw new ToolError("shatter_image needs the VeyMotion app on Windows (the CLI cannot read images yet). Open the app and run without --scene.");
                if (!Path.IsPathRooted(sourcePath)) sourcePath = Path.Combine(AssetDirectory(), sourcePath);
                var info = images.Info(sourcePath) ?? throw new ToolError($"Cannot read image at '{sourcePath}'");
                double placedW = pw ?? info.NaturalW, placedH = ph ?? info.NaturalH;
                var duration = Math.Max(0.05, Number(a["duration"]) ?? 0.8);
                var pieces = Math.Clamp((int)(Number(a["pieces"]) ?? 40), 4, 400);
                var seed = (long)(Number(a["seed"]) ?? 0);
                var distance = Math.Max(0, Number(a["distance"]) ?? 1);
                var spin = Math.Max(0, Number(a["spin"]) ?? 1);
                var direction = (string?)(a["direction"] as JsonValue) ?? "out";
                if (direction is not ("out" or "down" or "up")) throw new ToolError("`direction` must be \"out\", \"down\" or \"up\"");
                var fadeOut = a["fadeOut"] is not JsonValue fv || fv.GetValueKind() != JsonValueKind.False;

                var cells = ImageShatter.Cells(info.PixelW, info.PixelH, pieces, seed);
                if (cells.Count == 0) throw new ToolError("Could not shatter the image");
                // Shard rects are in the picture's pixels, which for a rasterized SVG differ from its natural size.
                double scaleX = placedW / info.PixelW, scaleY = placedH / info.PixelH;
                double originX = px - placedW / 2, originY = py - placedH / 2;
                var folder = Path.Combine(AssetDirectory(), "shatter");
                Directory.CreateDirectory(folder);
                var end = start + duration;
                double icx = info.PixelW / 2.0, icy = info.PixelH / 2.0;
                var cubicOut = Easing.Named(EaseCurve.Cubic, EaseMode.Out);
                var layers = new List<MotionLayer>();
                for (var i = 0; i < cells.Count; i++)
                {
                    var cell = cells[i];
                    var id = $"{prefix}-{i + 1}";
                    var file = Path.Combine(folder, id + ".png");
                    File.WriteAllBytes(file, images.ShardPng(sourcePath, cell.Quad, cell.X, cell.Y, cell.W, cell.H));
                    double x0 = originX + (cell.X + cell.W / 2) * scaleX, y0 = originY + (cell.Y + cell.H / 2) * scaleY;
                    var key = Noise.Hash($"shatter.{prefix}.{seed}.{i}");
                    double R(int j) => Noise.Unit(j, key);
                    double dx = cell.Centroid.X - icx, dy = cell.Centroid.Y - icy;
                    var mag = Math.Sqrt(dx * dx + dy * dy);
                    if (mag < 1) { var angle = R(0) * 2 * Math.PI; dx = Math.Cos(angle); dy = Math.Sin(angle); }
                    else { dx /= mag; dy /= mag; }
                    if (direction == "down") { dy = dy * 0.4 + 0.8; dx *= 0.5; }
                    else if (direction == "up") { dy = dy * 0.4 - 0.8; dx *= 0.5; }
                    var travel = Math.Max(placedW, placedH) * distance * (0.6 + 0.8 * R(1));
                    double endX = x0 + dx * travel * scaleX, endY = y0 + dy * travel * scaleY;
                    var endRotation = (R(2) - 0.5) * 720 * spin;
                    var layer = new MotionLayer(LayerType.Image, id, id, x0, y0)
                    {
                        Path = file, Width = cell.W * scaleX, Height = cell.H * scaleY,
                        X = Animated<double>.Make([new(start, x0, Easing.Linear), new(end, endX, cubicOut)], x0),
                        Y = Animated<double>.Make([new(start, y0, Easing.Linear), new(end, endY, cubicOut)], y0),
                        Rotation = Animated<double>.Make([new(start, 0, Easing.Linear), new(end, endRotation, cubicOut)], 0),
                    };
                    if (fadeOut)
                    {
                        var fadeEnd = Math.Min(scene.Duration, end + duration * 0.7);
                        layer.Opacity = Animated<double>.Make([new(end, 1, Easing.Linear), new(fadeEnd, 0, Easing.EaseIn)], 1);
                        layer.End = fadeEnd;
                    }
                    layers.Add(layer);
                }
                host.Mutate("Shatter Image", s =>
                {
                    if (sourceId != null && s.Layers.Any(l => l.Id == sourceId)) s.RemoveLayer(sourceId);
                    foreach (var l in layers) s.AddLayer(l);
                });
                return Text($"Shattered into {layers.Count} pieces ('{prefix}-1'…'{prefix}-{layers.Count}'), exploding {direction} from {Num(start)}s over {Num(duration)}s.");
            }

            case "export_video":
            {
                var path = Str(a, "path");
                if (!Path.IsPathRooted(path)) throw new ToolError("`path` must be absolute");
                var exporter = Exporter ?? throw new ToolError("export_video needs the VeyMotion app on Windows. Open the app and run without --scene, or use `vmotion render`.");
                var scene = host.CurrentScene();
                var options = new ExportOptions();
                var note = "";
                if ((string?)(a["preset"] as JsonValue) is { Length: > 0 } presetId)
                {
                    var preset = PlatformPreset.Named(presetId)
                        ?? throw new ToolError($"Unknown preset '{presetId}'. Presets: {string.Join(", ", PlatformPreset.All.Select(p => p.Id))}");
                    options.Size = (preset.Width, preset.Height);
                    if ((string?)(a["fit"] as JsonValue) is { } f)
                        options.Fit = JsonName<ExportFit>.Parse(f) ?? throw new ToolError("`fit` is fit or fill");
                    var (w, h) = options.PixelSize(scene);
                    note = $" at {w}×{h} for {preset.Name}"
                        + (options.IsReframed(scene) ? $" ({(options.Fit == ExportFit.Fit ? "letterboxed" : "cropped")} from {scene.Width}×{scene.Height})" : "");
                    var warnings = preset.Warnings(scene, (double)options.FrameRange(scene).Count / scene.Fps, options.EstimatedBytes(scene));
                    if (warnings.Count > 0) note += ". Warning: " + string.Join(" ", warnings);
                }
                var started = DateTime.UtcNow;
                var frames = exporter.Export(scene, path, options);
                return Text($"Exported {path} ({frames} frames) in {(DateTime.UtcNow - started).TotalSeconds:0.0}s" + note);
            }

            case "get_audio_info":
            {
                var path = Str(a, "path");
                if (AudioAnalysisCache.Source?.Stereo48k(path) is not { } pcm)
                    throw new ToolError(AudioAnalysisCache.Source == null ? NeedsApp("get_audio_info") : $"Cannot read audio file: {path}");
                return Text(string.Create(CultureInfo.InvariantCulture, $"{pcm.Length / 2.0 / AudioMixer.SampleRate:0.000} seconds"));
            }

            case "analyze_audio":
                return Text(AnalyzeAudio(a));

            case "add_audio":
            {
                var path = Str(a, "path");
                if (AudioAnalysisCache.Source == null) throw new ToolError(NeedsApp("add_audio"));
                var pcm = AudioAnalysisCache.Source.Stereo48k(path) ?? throw new ToolError($"Cannot read audio file: {path}");
                var duration = pcm.Length / 2.0 / AudioMixer.SampleRate;
                var layer = new MotionLayer(LayerType.Audio, (string?)(a["id"] as JsonValue) ?? "audio", Path.GetFileName(path))
                {
                    Path = path, SourceDuration = duration, Start = Math.Max(0, Number(a["start"]) ?? 0),
                    TrimIn = Math.Max(0, Number(a["trimIn"]) ?? 0), End = Number(a["end"]),
                    FadeIn = Math.Max(0, Number(a["fadeIn"]) ?? 0), FadeOut = Math.Max(0, Number(a["fadeOut"]) ?? 0), DuckTo = Number(a["duckTo"]),
                };
                layer.Role = (string?)(a["role"] as JsonValue) is { } r ? JsonName<AudioRole>.Parse(r) ?? AudioRole.Sfx
                    : a["duckTo"] != null || duration > 20 ? AudioRole.Music : AudioRole.Sfx; // ducking implies music
                if (Number(a["volume"]) is { } vol) layer.Volume = Math.Max(0, vol);
                string? hitNote = null;
                if (Number(a["hitAt"]) is { } hitAt)
                {
                    var profile = SoundProfile.Cached(path) ?? throw new ToolError("hitAt needs a sound of at most 60 s that can be decoded; use start instead.");
                    var hit = Number(a["hit"]) is { } hv ? (int?)hv : null;
                    if (hit is { } h0 && (h0 < 1 || h0 > profile.Bursts.Count))
                        throw new ToolError($"hit must be 1…{profile.Bursts.Count}: the file has {profile.Bursts.Count} separate sound(s).");
                    var place = profile.PlacementFor(hitAt, hit) ?? throw new ToolError("The file is silent.");
                    layer.Start = place.Start;
                    if (a["trimIn"] == null) layer.TrimIn = place.TrimIn;
                    if (a["end"] == null) layer.End = place.End;
                    if (a["fadeOut"] == null) layer.FadeOut = place.FadeOut;
                    hitNote = string.Create(CultureInfo.InvariantCulture, $" Its hit lands at {place.HitTime:0.00}s.")
                        + (place.HitTime > hitAt + 0.01 ? " (It could not start early enough: the sound is cut at the scene start.)" : "");
                    if (profile.Shape == SoundShape.Sustained)
                        hitNote += " Warning: this is a sustained sound (steady level, no clear hit), so nothing is heard as an accent at hitAt"
                            + " and it plays on for its whole length. For an accent use a hit/whoosh/riser sound or generate_sfx;"
                            + " keep sustained sounds for beds (set end and fadeIn/fadeOut).";
                    if (profile.PeakDB < -12)
                        hitNote += string.Create(CultureInfo.InvariantCulture, $" The file is quiet (peak {profile.PeakDB:0} dBFS): raise volume to be heard.");
                }
                var newId = "";
                host.Mutate("Add Audio", s => { newId = s.AddLayer(layer); });
                var scene = host.CurrentScene();
                var l = scene.Layer(newId);
                var reply = string.Create(CultureInfo.InvariantCulture, $"Added {l.Role.Json()} layer '{newId}': {l.Start:0.00}s → {l.EffectiveEnd(scene.Duration):0.00}s (file {duration:0.00}s");
                reply += l.TrimIn > 0 ? string.Create(CultureInfo.InvariantCulture, $", from {l.TrimIn:0.00}s).") : ").";
                reply += hitNote ?? "";
                if (l.Role == AudioRole.Sfx && a["hitAt"] == null && duration <= 60 && SoundProfile.Cached(path) is { } p0 && p0.Shape != SoundShape.Silent)
                    reply += string.Create(CultureInfo.InvariantCulture,
                        $" Sound: {p0.Summary}. Its peak plays at {l.Start + p0.Peak - l.TrimIn:0.00}s; pass hitAt to line the peak up with the picture.");
                return Text(reply);
            }

            case "generate_sfx":
            {
                var kind = JsonName<SynthKind>.Parse(Str(a, "kind").ToLowerInvariant())
                    ?? throw new ToolError($"kind must be one of: {string.Join(", ", JsonName<SynthKind>.All)}");
                var settings = new SynthSettings(kind)
                {
                    Duration = Number(a["duration"]) is { } d ? Math.Clamp(d, 0.03, 30) : null,
                    Pitch = Math.Clamp(Number(a["pitch"]) ?? 1, 0.25, 4),
                    Variant = (int)(Number(a["variant"]) ?? 0),
                    Reverb = Number(a["reverb"]) is { } rv ? Math.Clamp(rv, 0, 1) : null,
                    Direction = (string?)(a["direction"] as JsonValue),
                    Count = Number(a["count"]) is { } c ? Math.Clamp((int)c, 1, 200) : null,
                };
                var folder = Path.Combine(AssetDirectory(), (string?)(a["folder"] as JsonValue) is { Length: > 0 } f ? f : SoundSynth.DefaultFolder);
                var result = SoundSynth.Generate(settings, folder);
                var mainHit = result.Hits.Count > 0 ? result.Hits[0] : 0;
                var lines = new List<string> { string.Create(CultureInfo.InvariantCulture, $"Generated {kind.Json()} ({result.Duration:0.00}s, hit at {mainHit:0.00}s in the file): {result.Path}") };
                if (a["add"] is not JsonValue av || av.GetValueKind() != JsonValueKind.False)
                {
                    var layer = new MotionLayer(LayerType.Audio, (string?)(a["id"] as JsonValue) ?? $"sfx-{kind.Json()}", kind.Title())
                    {
                        Role = AudioRole.Sfx, Path = result.Path, SourceDuration = result.Duration,
                    };
                    if (Number(a["volume"]) is { } vol) layer.Volume = Math.Max(0, vol);
                    if (Number(a["hitAt"]) is { } hitAt)
                    {
                        layer.Start = hitAt - mainHit;
                        if (layer.Start < 0) { layer.TrimIn = -layer.Start; layer.Start = 0; }
                    }
                    else layer.Start = Math.Max(0, Number(a["start"]) ?? 0);
                    var newId = "";
                    host.Mutate("Generate Sound Effect", s => { newId = s.AddLayer(layer); });
                    var end = layer.Start + result.Duration - layer.TrimIn;
                    lines.Add(string.Create(CultureInfo.InvariantCulture, $"Added sfx layer '{newId}': {layer.Start:0.00}s → {end:0.00}s, hit at {layer.Start + mainHit - layer.TrimIn:0.00}s."));
                    if (result.Hits.Count > 1)
                        lines.Add("Hits (scene seconds): " + string.Join(", ", result.Hits.Take(40).Select(h => (layer.Start + h - layer.TrimIn).ToString("0.00", CultureInfo.InvariantCulture)))
                            + (result.Hits.Count > 40 ? ", …" : ""));
                    if (end > host.CurrentScene().Duration + 0.01) lines.Add("Note: it runs past the scene end and is cut there.");
                }
                else lines.Add("Not added: add_audio {\"path\": …, \"role\": \"sfx\", \"hitAt\": <scene time>} places it.");
                return Text(string.Join("\n", lines));
            }

            case "sync_to_beats":
            {
                var action = JsonName<BeatAction>.Parse(Str(a, "action")) ?? throw new ToolError(BeatOps.ActionError);
                var grid = JsonName<BeatGrid>.Parse((string?)(a["every"] as JsonValue) ?? "beat") ?? BeatGrid.Beat;
                var ids = (a["ids"] as JsonArray)?.Select(x => (string?)(x as JsonValue)).OfType<string>().ToList() ?? [];
                var preset = (string?)(a["preset"] as JsonValue) is { } ps ? JsonName<Preset>.Parse(ps) : null;
                if (action == BeatAction.Preset && preset == null) throw new ToolError(BeatOps.PresetError);
                var prop = (string?)(a["property"] as JsonValue) is { } pp ? JsonName<AnimProperty>.Parse(pp) : null;
                if (action == BeatAction.Pulse && prop == null) throw new ToolError(BeatOps.PropertyError);
                if (AudioAnalysisCache.Source == null) throw new ToolError(NeedsApp("sync_to_beats"));
                var used = 0;
                List<double> times = [];
                host.Mutate("Sync to Beats", s =>
                {
                    times = s.BeatTimes((string?)(a["source"] as JsonValue), grid, Number(a["from"]), Number(a["to"]), Number(a["minStrength"]) ?? 0.4);
                    used = s.SyncToBeats(ids, action, times, preset, prop, Number(a["amount"]) ?? BeatOps.DefaultAmount(action),
                        Number(a["release"]) ?? BeatOps.DefaultRelease, Number(a["duration"]));
                });
                return Text(BeatOps.SyncReply(action, used, grid, times));
            }

            case "add_captions":
            {
                var id = Str(a, "id");
                var style = CaptionOps.Style(Number(a["fontSize"]), Number(a["y"]), (string?)(a["color"] as JsonValue), Number(a["maxChars"]),
                    a["background"] is JsonValue bv && bv.GetValueKind() is JsonValueKind.True or JsonValueKind.False ? bv.GetValue<bool>() : null);
                List<CaptionLine> lines = [];
                host.Mutate("Add Captions", s => { lines = s.AddCaptions(id, style); });
                return Text(CaptionOps.AddCaptionsReply(id, lines));
            }

            case "set_caption_texts":
            {
                var id = Str(a, "id");
                var texts = (a["texts"] as JsonArray)?.Select(x => (string?)(x as JsonValue)).OfType<string>().ToList() ?? [];
                if (texts.Count == 0) throw new ToolError(CaptionOps.TextsError);
                var from = CaptionOps.CaptionFrom(Number(a["from"]));
                host.Mutate("Edit Captions", s => s.SetCaptionTexts(id, from, texts));
                return Text(CaptionOps.SetCaptionTextsReply(id, from, texts.Count));
            }

            case "list_captions":
            {
                var id = Str(a, "id");
                return Text(CaptionOps.ListCaptionsReply(id, host.CurrentScene().Captions(id)));
            }

            case "transcribe":
            {
                var id = Str(a, "id");
                var scene = host.CurrentScene();
                var l = scene.Layer(id);
                if (l.Type is not (LayerType.Audio or LayerType.Video) || l.Path == null) throw new ToolError(CaptionOps.TranscribeTargetError(id));
                var speech = Speech ?? throw new ToolError(NeedsApp("transcribe"));
                var (from, duration) = l.PlayedSourceRange(scene.Duration);
                var r = speech.Transcribe(l.Path, from, duration ?? double.MaxValue, (string?)(a["language"] as JsonValue));
                var result = new TranscriptionResult(r.Text, r.Words, r.Language, r.OnDevice);
                host.Mutate("Transcribe", s => s.SetTranscription(id, result));
                return Text(CaptionOps.TranscribeReply(id, result, "on this PC", "by the recognition server"));
            }

            case "list_voices":
            {
                if (VoiceEngine(a) == "vieneu") return Text(VieNeuVoices?.Invoke() ?? throw new ToolError("VieNeu is not available"));
                var speech = Speech ?? throw new ToolError(NeedsApp("list_voices"));
                var lang = (string?)(a["language"] as JsonValue);
                var voices = speech.Voices(lang);
                if (voices.Count == 0)
                    return Text($"No voices{(lang != null ? $" for '{lang}'" : "")}. Voices can be added in Settings → Time & language → Speech → Manage voices.");
                return Text(string.Join("\n", voices.Select(v => $"{v.Id}  —  {v.Name}, {v.Language}, {v.Quality}"))
                    + "\n(natural voices sound much better; add more in Settings → Time & language → Speech)");
            }

            case "generate_voice":
            {
                var script = Str(a, "text");
                var start = Number(a["start"]) ?? 0;
                var rate = Math.Clamp(Number(a["rate"]) ?? 1, 0.5, 2);
                var folder = Path.Combine(AssetDirectory(), "voice");
                VoiceResult result;
                if (VoiceEngine(a) == "vieneu")
                    result = VieNeuSynthesize?.Invoke(script, (string?)(a["voice"] as JsonValue), rate, folder) ?? throw new ToolError("VieNeu is not available");
                else
                {
                    var speech = Speech ?? throw new ToolError(NeedsApp("generate_voice"));
                    result = speech.Synthesize(script, (string?)(a["voice"] as JsonValue), (string?)(a["language"] as JsonValue), rate, folder);
                }
                var layer = new MotionLayer(LayerType.Audio, (string?)(a["id"] as JsonValue) ?? "vo", "Voice")
                {
                    Role = AudioRole.Voice, Path = result.Path, Start = Math.Max(0, start), SourceDuration = result.Duration,
                    Transcript = script, Words = result.Words,
                };
                var newId = "";
                host.Mutate("Generate Voice", s => { newId = s.AddLayer(layer); });
                var scene = host.CurrentScene();
                var end = layer.Start + result.Duration;
                var lines = new List<string> { string.Create(CultureInfo.InvariantCulture, $"Added voice layer '{newId}': {layer.Start:0.00}s → {end:0.00}s (duration {result.Duration:0.00}s).") };
                if (end > scene.Duration)
                    lines.Add(string.Create(CultureInfo.InvariantCulture, $"Note: narration ends after the scene ({scene.Duration:0.00}s). Consider update_scene duration ≥ {end + 0.5:0.0}."));
                lines.Add(result.ExactTimings ? "Word times (scene seconds):" : "Word times (estimated, scene seconds):");
                var words = result.Words.Select(w => string.Create(CultureInfo.InvariantCulture, $"{layer.Start + w.T:0.00} {w.Text}")).ToList();
                lines.Add(words.Count > 160 ? string.Join(" | ", words.Take(160)) + " | …" : string.Join(" | ", words));
                return Text(string.Join("\n", lines));
            }

            case "add_template":
            {
                var kind = JsonName<TemplateKind>.Parse(Str(a, "kind"))
                    ?? throw new ToolError($"`kind` must be one of [{string.Join(", ", JsonName<TemplateKind>.All)}]");
                var o = new TemplateOptions
                {
                    Title = (string?)(a["title"] as JsonValue), Subtitle = (string?)(a["subtitle"] as JsonValue),
                    Accent = (string?)(a["accent"] as JsonValue) is { } hex ? Rgba.FromHex(hex) : null,
                    Start = Number(a["start"]) ?? 0, Duration = Number(a["duration"]) ?? 4,
                    X = Number(a["x"]), Y = Number(a["y"]), FontName = (string?)(a["fontName"] as JsonValue),
                };
                var gid = "";
                host.Mutate($"Add {kind.Title()}", s => { gid = s.AddTemplate(kind, (string?)(a["id"] as JsonValue), o); });
                var g = host.CurrentScene().Layer(gid);
                return Text($"Added {kind.Title()} '{gid}' from {Num(o.Start)}s for {Num(o.Duration)}s: a group of {string.Join(", ", g.Children.Select(c => c.Id))}. Edit its parts by id (text, colors, timing) like any layer.");
            }

            case "text_to_path":
            {
                var id = Str(a, "id");
                var letters = a["letters"] is JsonValue lv && lv.GetValueKind() == JsonValueKind.True;
                var geo = geometry ?? throw new ToolError("text_to_path needs the VeyMotion app on Windows (the CLI has no text engine yet). Open the app and run without --scene.");
                host.Mutate("Text to Path", s => s.TextToPath(id, letters, Number(a["time"]) ?? s.Layer(id).Start, geo));
                var l = host.CurrentScene().Layer(id);
                return Text(letters
                    ? $"'{id}' is now a group of {l.Children.Count} letter paths ({string.Join(", ", l.Children.Select(c => c.Id).Take(3))}…)"
                    : $"'{id}' is now a path layer: trim, morph and path operators work on it (try preset writeOn)");
            }

            case "combine_paths":
            {
                var ids = (a["ids"] as JsonArray)?.Select(x => x is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null)
                    .OfType<string>().ToList() ?? [];
                if (ids.Count < 2) throw new ToolError("`ids` must list at least two layers");
                var op = JsonName<PathCombine>.Parse((string?)(a["op"] as JsonValue) ?? "union")
                    ?? throw new ToolError($"`op` must be one of [{string.Join(", ", JsonName<PathCombine>.All)}]");
                var geo = geometry ?? throw new ToolError("combine_paths needs the VeyMotion app on Windows (the CLI has no geometry engine yet). Open the app and run without --scene.");
                var keep = a["keep"] is JsonValue kv && kv.GetValueKind() == JsonValueKind.True;
                var newId = "";
                host.Mutate("Combine Paths", s => { newId = s.CombinePaths(ids, op, (string?)(a["id"] as JsonValue), keep, Number(a["time"]) ?? 0, geo); });
                return Text($"Combined {string.Join(", ", ids)} ({op.Json()}) into path layer '{newId}'");
            }

            case "stabilize":
                return Text(VideoAnalysisTools.Stabilize(a, host.CurrentScene, (l, b) => host.Mutate(l, b), Frames ?? throw new ToolError(NeedsVideo("stabilize"))));

            case "track_motion":
                return Text(VideoAnalysisTools.TrackMotion(a, host.CurrentScene, (l, b) => host.Mutate(l, b), Frames ?? throw new ToolError(NeedsVideo("track_motion"))));

            case "auto_reframe":
                return Text(VideoAnalysisTools.AutoReframe(a, host.CurrentScene, (l, b) => host.Mutate(l, b), Frames ?? throw new ToolError(NeedsVideo("auto_reframe"))));

            case "search_stock":
                return StockTools.SearchStock(a, ContactSheet,
                    path => { try { return SoundProfile.Cached(path)?.Summary; } catch (SceneException) { return null; } },
                    SoundSheet, q => SynthKindExtensions.Matching(q)?.Json());

            case "import_stock":
                return StockTools.ImportStock(a, StockImport.Import,
                    FontCatalog == null ? null : family => { FontCatalog.Invalidate(); return FontCatalog.Faces(family); },
                    path => SoundProfile.Cached(path) is { } p ? new StockSoundInfo(p.Summary, p.Bursts.Select(b => (b.Start, b.End, b.Peak)).ToList()) : null);

            case "list_fonts":
                return StockTools.ListFonts(a, FontCatalog ?? throw new ToolError(NeedsApp("list_fonts").Replace("decode audio", "read fonts")));

            default:
                if (AssetTools.TryCall(name, a, host.CurrentScene, (label, body) => host.Mutate(label, body)) is { } asset) return asset.ToContent();
                if (Docs.MissingTools.Contains(name))
                    throw new ToolError($"{name} is not available in VeyMotion for Windows yet");
                throw new InvalidParams($"Unknown tool: {name}");
        }
    }

    static string NeedsVideo(string tool) =>
        $"{tool} needs the VeyMotion app on Windows (the CLI cannot decode video). Open the app and run without --scene.";

    static string NeedsApp(string tool) =>
        $"{tool} needs the VeyMotion app on Windows (the CLI cannot decode audio). Open the app and run without --scene.";

    /// <summary>"macos" (the system voices, kept for scripts written on a Mac), "windows" or "vieneu".</summary>
    static string VoiceEngine(JsonObject a)
    {
        var e = ((string?)(a["engine"] as JsonValue))?.ToLowerInvariant() ?? "windows";
        if (e is not ("macos" or "windows" or "system" or "vieneu")) throw new ToolError("`engine` must be \"windows\" (system voices) or \"vieneu\"");
        return e == "vieneu" ? "vieneu" : "system";
    }

    /// <summary>VieNeu voices (engine "vieneu").</summary>
    public Func<string>? VieNeuVoices { get; init; }
    public Func<string, string?, double, string, VoiceResult>? VieNeuSynthesize { get; init; }

    /// <summary>Rhythm and loudness of an audio layer or file as compact JSON. Port of <c>analyzeAudio</c>.</summary>
    string AnalyzeAudio(JsonObject a)
    {
        if (AudioAnalysisCache.Source == null) throw new ToolError(NeedsApp("analyze_audio"));
        var scene = host.CurrentScene();
        MotionLayer? layer = null;
        string path;
        if ((string?)(a["path"] as JsonValue) is { Length: > 0 } p && ((string?)(a["id"] as JsonValue) ?? "").Length == 0) path = p;
        else
        {
            layer = (string?)(a["id"] as JsonValue) is { Length: > 0 } id ? scene.Layer(id)
                : scene.AllLayers.Where(x => x.Type == LayerType.Audio && x.Path != null).OrderBy(x => x.Role == AudioRole.Music ? 0 : 1).FirstOrDefault();
            if (layer == null) throw new ToolError("The scene has no audio layer: pass an audio layer `id` or a file `path`.");
            if (layer.Type != LayerType.Audio || layer.Path == null) throw new ToolError($"'{layer.Id}' is not an audio layer with a file");
            path = layer.Path;
        }
        var an = AudioAnalysisCache.Analysis(path, wait: true) ?? throw new ToolError($"Cannot read audio file: {path}");
        // File time + offset = scene time (for a file: offset 0, the whole file).
        var offset = layer != null ? layer.Start - layer.TrimIn : 0;
        var lo = layer?.Start ?? 0;
        var hi = layer != null ? Math.Min(layer.EffectiveEnd(scene.Duration), scene.Duration) : an.Duration;
        double from = Math.Max(lo, Number(a["from"]) ?? lo), to = Math.Min(hi, Number(a["to"]) ?? hi);
        if (to <= from) throw new ToolError(string.Create(CultureInfo.InvariantCulture, $"Nothing to analyze: the audio plays {lo:0.00}–{hi:0.00}s"));
        var minStrength = Math.Clamp(Number(a["minStrength"]) ?? 0.4, 0, 1);
        static string F(double v, int digits = 3)
        {
            var s = v.ToString("F" + digits, CultureInfo.InvariantCulture);
            if (s.Contains('.')) s = s.TrimEnd('0').TrimEnd('.');
            return s == "-0" ? "0" : s;
        }
        string Times(List<double> ts) => "[" + string.Join(",", ts.Select(t => t + offset).Where(t => t >= from - 0.01 && t <= to + 0.01).Select(t => F(t))) + "]";
        var onsets = an.Onsets.Where(o => o.Strength >= minStrength && o.T + offset >= from - 0.01 && o.T + offset <= to + 0.01);
        var loudness = an.Loudness(from - offset, to - offset);
        static string Q(string s) => System.Text.Json.JsonSerializer.Serialize(s);
        var fields = new List<string>
        {
            layer != null ? $"\"layer\":{Q(layer.Id)}" : $"\"file\":{Q(path)}",
            $"\"timesAre\":\"{(layer == null ? "file seconds" : "scene seconds")}\"",
            $"\"range\":[{F(from)},{F(to)}]",
        };
        if (an.Bpm is { } bpm) { fields.Add($"\"bpm\":{F(bpm, 1)}"); fields.Add($"\"beatInterval\":{F(60 / bpm)}"); }
        else { fields.Add("\"bpm\":null"); fields.Add("\"note\":\"No steady beat found: time things to onsets and loudness instead.\""); }
        fields.Add($"\"beats\":{Times(an.Beats)}");
        fields.Add($"\"downbeats\":{Times(an.Downbeats)}");
        fields.Add("\"onsets\":[" + string.Join(",", onsets.Select(o => $"[{F(o.T + offset)},{F(o.Strength, 2)}]")) + "]");
        fields.Add($"\"loudness\":{{\"from\":{F(from)},\"step\":1,\"values\":[" + string.Join(",", loudness.Select(v => F(v, 2))) + "]}");
        if (an.Duration <= 30 && SoundProfile.Cached(path) is { } sp)
        {
            // Sound effects: the shape, in the same time base as the rest.
            var bursts = sp.Bursts.Select(b => $"[{F(b.Start + offset)},{F(b.Peak + offset)},{F(b.End + offset)}]");
            fields.Add($"\"sound\":{{\"shape\":{Q(sp.Shape.Json())},\"peak\":{F(sp.Peak + offset)},\"bursts\":[{string.Join(",", bursts)}],\"tone\":{Q(sp.Tone)},\"summary\":{Q(sp.Summary)}}}");
        }
        return "{" + string.Join(",", fields) + "}";
    }

    static string Warnings(List<string> problems) => problems.Count == 0 ? "" : "\nWarnings:\n" + string.Join("\n", problems);

    /// <summary>Problems with text layers' fonts: names that are not installed, and letters the font cannot draw.</summary>
    List<string> FontNotes(IEnumerable<MotionLayer> layers)
    {
        var notes = new List<string>();
        if (Fonts is not { } fonts) return notes;
        var reported = new HashSet<string>();
        foreach (var l in layers)
        {
            if (l.Type != LayerType.Text || l.FontName is not { } name || string.IsNullOrWhiteSpace(name)) continue;
            if (!fonts.Exists(name))
            {
                if (reported.Add(name))
                {
                    var alt = fonts.Suggestions(name);
                    notes.Add($"Font '{name}' was not found, so '{l.Id}' uses the system font"
                        + (alt.Count == 0 ? "" : $". Similar installed fonts: {string.Join(", ", alt)}")
                        + ". Install the font in Windows (fonts from the asset library are not loaded on Windows yet).");
                }
                continue;
            }
            var missing = fonts.MissingCharacters(l.Text, name, l.FontWeight);
            if (missing.Length > 0)
                notes.Add($"Font '{name}' has no letters for \"{new string(missing.Take(16).ToArray())}\" in '{l.Id}' (another font fills them in, "
                    + "which looks uneven). Use a font that has them.");
        }
        return notes;
    }

    static JsonObject Text(string s) => new()
    {
        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = s }),
    };

    static string Str(JsonObject a, string key) =>
        a[key] is JsonValue v && v.GetValueKind() == JsonValueKind.String && v.GetValue<string>() is { Length: > 0 } s
            ? s : throw new ToolError($"`{key}` must be a non-empty string");

    static double? Number(JsonNode? n) => n switch
    {
        JsonValue v when v.GetValueKind() == JsonValueKind.Number => SceneJson.ToDouble(v),
        JsonValue v when v.GetValueKind() == JsonValueKind.String
            && double.TryParse(v.GetValue<string>(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
        _ => null,
    };

    /// <summary>Numbers as Swift prints doubles ("0.5", "6.0" → "6").</summary>
    static string Num(double v) => v.ToString("0.###############", CultureInfo.InvariantCulture);
}
