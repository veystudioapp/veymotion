using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

using AnimValue = Animated<double>;
using ColorValue = Animated<Rgba>;

/// <summary>
/// Scene JSON, compatible with the macOS app (<c>SceneJSON</c> and the Codable code in <c>Scene.swift</c>):
/// the same defaults on decode, the same "only the fields relevant to the type" on encode, and errors that name the
/// failing path ("scene.layers[2].x: …").
/// </summary>
public static class SceneJson
{
    static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true, NewLine = "\n", Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    static readonly JsonSerializerOptions Compact = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    static readonly JsonDocumentOptions ReadOptions = new() { AllowTrailingCommas = false };

    public static string Encode(MotionScene scene, bool pretty = true) => ToNode(scene).ToJsonString(pretty ? Pretty : Compact);

    public static string Encode(JsonNode node, bool pretty = true) => node.ToJsonString(pretty ? Pretty : Compact);

    public static MotionScene Decode(string json)
    {
        JsonNode? node;
        try { node = JsonNode.Parse(json, documentOptions: ReadOptions); }
        catch (JsonException e) { throw new SceneException($"The data couldn't be read because it isn't valid JSON: {e.Message}"); }
        return FromNode(node);
    }

    public static MotionScene Load(string path) => Decode(File.ReadAllText(path));

    /// <summary>Atomic write through a sibling temp file and a rename.</summary>
    public static void Write(string json, string path)
    {
        var full = System.IO.Path.GetFullPath(path);
        var tmp = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(full)!,
            $".{System.IO.Path.GetFileName(full)}.{Guid.NewGuid().ToString("N")[..8]}.tmp");
        File.WriteAllText(tmp, json);
        try { File.Move(tmp, full, overwrite: true); }
        catch (Exception e)
        {
            try { File.Delete(tmp); } catch { /* best effort */ }
            throw new SceneException($"Cannot write {full}: {e.Message}");
        }
    }

    public static void Save(MotionScene scene, string path) => Write(Encode(scene), path);

    public static JsonObject ToNode(MotionScene s)
    {
        var o = new JsonObject
        {
            ["width"] = s.Width,
            ["height"] = s.Height,
            ["fps"] = s.Fps,
            ["duration"] = s.Duration,
            ["background"] = s.Background.Hex,
        };
        if (s.Camera != null) o["camera"] = ModelCodec.Encode(s.Camera, s);
        o["layers"] = new JsonArray(s.Layers.Select(l => (JsonNode)LayerCodec.Encode(l)).ToArray());
        return o;
    }

    public static MotionScene FromNode(JsonNode? node)
    {
        var r = Reader.Of(node, "scene");
        var s = new MotionScene();
        s.Width = r.Int("width") ?? s.Width;
        s.Height = r.Int("height") ?? s.Height;
        s.Fps = r.Int("fps") ?? s.Fps;
        s.Duration = r.Num("duration") ?? s.Duration;
        s.Background = r.Color("background") ?? s.Background;
        s.Layers = r.List("layers", LayerCodec.Decode) ?? [];
        s.Camera = r.Obj["camera"] is { } cam ? ModelCodec.DecodeCamera(cam, "scene.camera") : null;
        s.Validate();
        s.NormalizeIds();
        s.ResolveLinks();
        return s;
    }

    // Values shared by the layer codec

    /// <summary>A JSON number as a double, whether parsed or built in memory (<c>JsonValue.Create(1920)</c> holds an
    /// int, which <c>GetValue&lt;double&gt;</c> refuses).</summary>
    public static double ToDouble(JsonValue v) =>
        v.TryGetValue(out double d) ? d
        : double.Parse(v.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture);

    /// <summary>A keyframe list such as <c>set_keyframes</c> takes (an array, or {"keyframes": [...]}).</summary>
    public static IReadOnlyList<Keyframe<double>> NumberKeyframes(JsonNode? n, string path = "keyframes") =>
        n == null ? [] : Reader.ReadAnim(n, path, Reader.ReadNum, "a number").KeyframeList;

    public static IReadOnlyList<Keyframe<Rgba>> ColorKeyframes(JsonNode? n, string path = "keyframes") =>
        n == null ? [] : Reader.ReadAnim(n, path, Reader.ReadColor, "a color \"#RRGGBB[AA]\"").KeyframeList;

    public static string CompactJson(AnimValue v) => Anim(v).ToJsonString(Compact);
    public static string CompactJson(ColorValue v) => Anim(v).ToJsonString(Compact);

    internal static JsonNode Anim(AnimValue v) => v.IsAnimated
        ? new JsonObject { ["keyframes"] = new JsonArray(v.KeyframeList.Select(k => (JsonNode)new JsonObject
            { ["t"] = k.T, ["v"] = k.V, ["easing"] = k.Easing.ToString() }).ToArray()) }
        : JsonValue.Create(v.ConstantValue);

    internal static JsonNode Anim(ColorValue v) => v.IsAnimated
        ? new JsonObject { ["keyframes"] = new JsonArray(v.KeyframeList.Select(k => (JsonNode)new JsonObject
            { ["t"] = k.T, ["v"] = k.V.Hex, ["easing"] = k.Easing.ToString() }).ToArray()) }
        : JsonValue.Create(v.ConstantValue.Hex);
}

/// <summary>Reads one JSON object with Swift-like defaults (missing or null = not present) and path-named errors.</summary>
internal readonly struct Reader
{
    public readonly JsonObject Obj;
    public readonly string Path;

    Reader(JsonObject obj, string path) { Obj = obj; Path = path; }

    public static Reader Of(JsonNode? node, string path) =>
        node is JsonObject o ? new Reader(o, path) : throw Fail(path, $"Expected to decode an object but found {Kind(node)} instead.");

    public static SceneException Fail(string path, string message) => new($"{path}: {message}");

    public static string Kind(JsonNode? n) => n?.GetValueKind() switch
    {
        null or JsonValueKind.Null => "null",
        JsonValueKind.String => "a string",
        JsonValueKind.Number => "a number",
        JsonValueKind.True or JsonValueKind.False => "a bool",
        JsonValueKind.Array => "an array",
        _ => "a dictionary",
    };

    string At(string key) => $"{Path}.{key}";

    public bool Has(string key) => Obj[key] != null;

    JsonNode? Get(string key) => Obj.TryGetPropertyValue(key, out var n) ? n : null;

    public static double ReadNum(JsonNode? n, string path) =>
        n is JsonValue v && v.GetValueKind() == JsonValueKind.Number ? SceneJson.ToDouble(v)
            : throw Fail(path, $"Expected to decode Double but found {Kind(n)} instead.");

    public double? Num(string key) => Get(key) is { } n ? ReadNum(n, At(key)) : null;

    public int? Int(string key)
    {
        if (Get(key) is not { } n) return null;
        var d = ReadNum(n, At(key));
        if (d != Math.Floor(d) || d is > int.MaxValue or < int.MinValue)
            throw Fail(At(key), $"Parsed JSON number <{d.ToString(CultureInfo.InvariantCulture)}> does not fit in Int.");
        return (int)d;
    }

    public string? Str(string key) => Get(key) switch
    {
        null => null,
        JsonValue v when v.GetValueKind() == JsonValueKind.String => v.GetValue<string>(),
        var n => throw Fail(At(key), $"Expected to decode String but found {Kind(n)} instead."),
    };

    public bool? Bool(string key) => Get(key) switch
    {
        null => null,
        JsonValue v when v.GetValueKind() is JsonValueKind.True or JsonValueKind.False => v.GetValue<bool>(),
        var n => throw Fail(At(key), $"Expected to decode Bool but found {Kind(n)} instead."),
    };

    public static Rgba ReadColor(JsonNode? n, string path)
    {
        if (n is not JsonValue v || v.GetValueKind() != JsonValueKind.String)
            throw Fail(path, $"Expected to decode String but found {Kind(n)} instead.");
        var s = v.GetValue<string>();
        return Rgba.FromHex(s) ?? throw Fail(path, $"Invalid color '{s}'. Expected #RRGGBB or #RRGGBBAA.");
    }

    public Rgba? Color(string key) => Get(key) is { } n ? ReadColor(n, At(key)) : null;

    public T? Enum<T>(string key) where T : struct, System.Enum
    {
        if (Str(key) is not { } s) return null;
        return JsonName<T>.Parse(s)
            ?? throw Fail(At(key), $"Cannot initialize {typeof(T).Name} from invalid String value {s}");
    }

    public AnimValue? Anim(string key) => Get(key) is { } n ? ReadAnim(n, At(key), ReadNum, "a number") : null;

    public ColorValue? ColorAnim(string key) => Get(key) is { } n ? ReadAnim(n, At(key), ReadColor, "a color \"#RRGGBB[AA]\"") : null;

    internal static Animated<V> ReadAnim<V>(JsonNode n, string path, Func<JsonNode?, string, V> value, string what) where V : notnull
    {
        Keyframe<V> Key(JsonNode? k, string p)
        {
            var r = Of(k, p);
            if (!r.Has("t")) throw Fail(p + ".t", "missing required field");
            if (!r.Has("v")) throw Fail(p + ".v", "missing required field");
            var easing = Easing.EaseInOut;
            if (r.Str("easing") is { } e)
                easing = Easing.Parse(e) ?? throw Fail(p + ".easing", $"Unknown easing '{e}'. {Easing.ParseHelp}");
            return new Keyframe<V>(ReadNum(r.Obj["t"], p + ".t"), value(r.Obj["v"], p + ".v"), easing);
        }
        List<Keyframe<V>> Keys(JsonArray a, string p) => a.Select((k, i) => Key(k, $"{p}[{i}]")).ToList();

        switch (n)
        {
            case JsonObject o when o["keyframes"] is JsonArray a:
                return Animated<V>.Make(Keys(a, path + ".keyframes"), Interp.Zero<V>());
            case JsonArray a:
                return Animated<V>.Make(Keys(a, path), Interp.Zero<V>());
            case JsonValue or JsonObject: // objects: corner pins
                try { return Animated<V>.Constant(value(n, path)); }
                catch (SceneException) { break; }
        }
        throw Fail(path, $"Expected {what} or {{\"keyframes\": [{{\"t\", \"v\", \"easing\"?}}]}}");
    }

    public List<T>? List<T>(string key, Func<JsonNode?, string, T> item)
    {
        var at = At(key);
        return Get(key) switch
        {
            null => null,
            JsonArray a => a.Select((n, i) => item(n, $"{at}[{i}]")).ToList(),
            var n => throw Fail(at, $"Expected to decode Array but found {Kind(n)} instead."),
        };
    }

    public Dictionary<string, JsonNode?>? Dict(string key) => Get(key) switch
    {
        null => null,
        JsonObject o => o.ToDictionary(kv => kv.Key, kv => kv.Value),
        var n => throw Fail(At(key), $"Expected to decode Dictionary but found {Kind(n)} instead."),
    };

    /// <summary>A field whose type is not ported yet: a detached copy, or null.</summary>
    public JsonNode? Raw(string key) => Get(key)?.DeepClone();
}

/// <summary>Port of <c>MotionLayer.init(from:)</c> and <c>encode(to:)</c>.</summary>
public static class LayerCodec
{
    public static MotionLayer Decode(JsonNode? node, string path)
    {
        var r = Reader.Of(node, path);
        var type = r.Enum<LayerType>("type") ?? throw Reader.Fail(path + ".type", "missing required field");
        var l = new MotionLayer(type);
        l.Id = r.Str("id") ?? "";
        l.Name = r.Str("name") ?? (l.Id.Length == 0 ? type.Title() : l.Id);
        l.Start = r.Num("start") ?? l.Start;
        l.End = r.Num("end");
        l.X = r.Anim("x") ?? l.X;
        l.Y = r.Anim("y") ?? l.Y;
        l.Scale = r.Anim("scale") ?? l.Scale;
        l.Rotation = r.Anim("rotation") ?? l.Rotation;
        l.Opacity = r.Anim("opacity") ?? l.Opacity;
        l.Reveal = r.Anim("reveal") ?? l.Reveal;
        foreach (var p in AnimPropertyInfo.Extras)
            if (r.Anim(p.Json()) is { } v) l[p] = v;
        l.Parent = r.Str("parent") is { Length: > 0 } parent ? parent : null;
        l.MotionPath = r.Obj["motionPath"] is { } mp ? ModelCodec.DecodeMotionPath(mp, path + ".motionPath") : null;

        if (r.Dict("loop") is { } loop)
            foreach (var (k, v) in loop)
            {
                if (KeyTrack.FromName(k) == null && k != "d")
                    throw Reader.Fail(path + ".loop", $"Unknown property '{k}' in loop. Use one of [{string.Join(", ", KeyTrack.AllNames.Append("d"))}].");
                var s = v is JsonValue jv && jv.GetValueKind() == JsonValueKind.String ? jv.GetValue<string>() : null;
                l.Loop[k] = (s == null ? null : JsonName<LoopMode>.Parse(s))
                    ?? throw Reader.Fail($"{path}.loop.{k}", $"Cannot initialize LoopMode from invalid value {v?.ToJsonString()}");
            }
        l.Wiggle = ModelCodec.DecodeWiggles(r, "wiggle", path, JsonName<AnimProperty>.All, $"[{string.Join(", ", JsonName<AnimProperty>.All)}]");
        l.AudioReact = [];
        if (CheckedPropertyMap(r, "audioReact", path) is JsonObject reacts)
            foreach (var (k, v) in reacts)
            {
                var rr = Reader.Of(v, $"{path}.audioReact.{k}");
                l.AudioReact[k] = new AudioReact
                {
                    Amount = rr.Num("amount") ?? 0.1, Band = rr.Enum<AudioBand>("band") ?? AudioBand.Level,
                    Release = Math.Max(0.01, rr.Num("release") ?? AudioReact.DefaultRelease),
                    Source = rr.Str("source") is { Length: > 0 } src ? src : null,
                };
            }

        l.ShadowColor = r.Color("shadowColor") ?? l.ShadowColor;
        l.Particles = r.Has("particles") ? ParticleSystem.Decode(r.Obj["particles"], path + ".particles") : new ParticleSystem();
        l.Generator = r.Has("generator") ? Generator.Decode(r.Obj["generator"], path + ".generator") : new Generator();
        // A particle layer without a blendMode takes its preset's.
        l.BlendMode = r.Enum<BlendMode>("blendMode")
            ?? (type == LayerType.Particles && l.Particles.Preset is { } preset ? ParticleSystem.DefaultBlendMode(preset) : BlendMode.Normal);
        l.GlowColor = r.Color("glowColor");
        l.Matte = DecodeMatte(r, path);
        l.Repeater = r.Obj["repeater"] is { } rep ? ModelCodec.DecodeRepeater(rep, path + ".repeater") : null;
        l.MotionBlur = Math.Clamp(r.Num("motionBlur") ?? 0, 0, 720);
        l.Gradient = r.Obj["gradient"] is { } grad ? ModelCodec.DecodeGradient(grad, path + ".gradient") : null;
        l.TintColor = r.Color("tintColor");
        l.WipeStyle = r.Obj["wipeStyle"] is { } ws ? WipeStyle.Decode(ws, path + ".wipeStyle") : null;
        l.KeyColor = r.Color("keyColor");
        l.ShineColor = r.Color("shineColor");
        l.OutlineColor = r.Color("outlineColor");
        l.InnerGlowColor = r.Color("innerGlowColor");
        l.CornerPin = r.Has("cornerPin") ? Reader.ReadAnim(r.Obj["cornerPin"]!, path + ".cornerPin", Core.CornerPin.Read,
            "a corner pin {\"tl\",\"tr\",\"br\",\"bl\"}") : null;
        l.Pins = r.List("pins", PuppetPin.Read) ?? [];
        l.HideBackface = r.Bool("hideBackface") ?? false;
        l.TrimSequential = r.Bool("trimSequential") ?? false;
        l.Curves = (r.List("curves", ReadPoint) ?? [])
            .Select(p => new PathPoint(Math.Clamp(p.X, 0, 1), Math.Clamp(p.Y, 0, 1))).OrderBy(p => p.X).ToList();
        l.GradientMap = r.List("gradientMap", Reader.ReadColor) ?? [];
        l.Lut = r.Str("lut") is { Length: > 0 } lut ? lut : null;
        l.RemoveBackground = r.Enum<BackgroundRemoval>("removeBackground");
        l.FrameBlend = r.Enum<FrameBlend>("frameBlend") ?? FrameBlend.Off;
        l.Dash = (r.List("dash", Reader.ReadNum) ?? []).Select(d => Math.Max(0, d)).ToList();
        if (l.Dash.All(d => d <= 0)) l.Dash = [];
        l.Depth = Math.Max(-0.9, r.Num("depth") ?? 0);
        l.Fixed = r.Bool("fixed") ?? false;
        l.Links = ModelCodec.DecodeLinks(r, path);
        l.Children = r.List("children", Decode) ?? [];
        l.PosterizeTime = r.Num("posterizeTime") is > 0 and var pt ? pt : null;
        l.Width = r.Anim("width");
        l.Height = r.Anim("height");
        l.CornerRadius = r.Anim("cornerRadius") ?? l.CornerRadius;
        l.Stroke = r.ColorAnim("stroke");
        // A path with only a stroke is a line: no fill unless one is given.
        l.Fill = r.ColorAnim("fill") ?? (type == LayerType.Path && l.Stroke != null ? Rgba.Clear : l.Fill);
        l.StrokeWidth = r.Anim("strokeWidth") ?? (l.Stroke == null ? 0.0 : 4.0);
        l.LineCap = r.Enum<LineCap>("lineCap");
        l.LineJoin = r.Enum<LineJoin>("lineJoin");
        l.D = ModelCodec.DecodeD(r, path) ?? l.D;
        l.FillRule = r.Enum<FillRule>("fillRule") ?? FillRule.Nonzero;
        l.Text = r.Str("text") ?? l.Text;
        l.FontSize = r.Num("fontSize") ?? l.FontSize;
        l.FontWeight = r.Str("fontWeight") ?? l.FontWeight;
        l.FontName = r.Str("fontName");
        l.Color = r.ColorAnim("color") ?? l.Color;
        l.Align = r.Enum<TextAlign>("align") ?? l.Align;
        l.MaxWidth = r.Num("maxWidth");
        l.TextAnimators = r.List("textAnimators", TextAnimator.Decode) ?? [];
        l.CounterDecimals = Math.Clamp(r.Int("counterDecimals") ?? 0, 0, 6);
        l.CounterGrouping = r.Bool("counterGrouping") ?? false;
        // A text path needs at least two points.
        l.TextPath = r.Has("textPath") && ModelCodec.DecodeMotionPath(r.Obj["textPath"], path + ".textPath") is { Points.Count: >= 2 } tp ? tp : null;
        l.Path = r.Str("path");
        l.Speed = r.Num("speed") ?? 1;
        if (!(l.Speed > 0)) throw Reader.Fail(path + ".speed", "speed must be greater than 0");
        l.Playback = r.Enum<VideoPlayback>("playback") ?? VideoPlayback.Once;
        l.Fps = r.Num("fps") is > 0 and var fps ? fps : null;
        l.TimeRemap = r.Anim("timeRemap");
        l.Volume = r.Anim("volume") ?? l.Volume;
        l.Role = r.Enum<AudioRole>("role") ?? l.Role;
        l.TrimIn = Math.Max(0, r.Num("trimIn") ?? 0);
        l.FadeIn = Math.Max(0, r.Num("fadeIn") ?? 0);
        l.FadeOut = Math.Max(0, r.Num("fadeOut") ?? 0);
        l.DuckTo = r.Num("duckTo");
        l.SourceDuration = r.Num("sourceDuration");
        l.Transcript = r.Str("transcript");
        l.Words = r.List("words", ReadWord);
        return l;
    }

    /// <summary>A raw map keyed by animatable property names (wiggle, audioReact, links), with its keys checked.</summary>
    static JsonNode? CheckedPropertyMap(Reader r, string key, string path)
    {
        if (r.Dict(key) is not { } map) return null;
        foreach (var k in map.Keys)
            if (JsonName<AnimProperty>.Parse(k) == null)
                throw Reader.Fail($"{path}.{key}",
                    $"Unknown property '{k}' in {key}. Use one of [{string.Join(", ", JsonName<AnimProperty>.All)}].");
        return map.Count == 0 ? null : r.Raw(key);
    }

    static Matte? DecodeMatte(Reader r, string path)
    {
        var p = path + ".matte";
        Matte? m = r.Obj["matte"] switch
        {
            null => null,
            JsonValue v when v.GetValueKind() == JsonValueKind.String => new Matte(v.GetValue<string>()),
            var n => Reader.Of(n, p) is var mr
                ? new Matte(mr.Str("source") ?? throw Reader.Fail(p + ".source", "missing required field"),
                    mr.Enum<MatteMode>("mode") ?? MatteMode.Alpha)
                : null,
        };
        return m is { Source.Length: > 0 } ? m : null;
    }

    internal static PathPoint ReadPoint(JsonNode? n, string path)
    {
        if (n is JsonArray a)
        {
            if (a.Count < 2) throw Reader.Fail(path, "Unkeyed container is at end.");
            return new PathPoint(Reader.ReadNum(a[0], path + "[0]"), Reader.ReadNum(a[1], path + "[1]"));
        }
        var r = Reader.Of(n, path);
        return new PathPoint(r.Num("x") ?? throw Reader.Fail(path + ".x", "missing required field"),
            r.Num("y") ?? throw Reader.Fail(path + ".y", "missing required field"));
    }

    static WordTiming ReadWord(JsonNode? n, string path)
    {
        var r = Reader.Of(n, path);
        return new WordTiming(r.Num("t") ?? throw Reader.Fail(path + ".t", "missing required field"),
            r.Str("text") ?? throw Reader.Fail(path + ".text", "missing required field"), r.Num("d"));
    }

    // Encoding

    static void Put(JsonObject o, string key, JsonNode? value)
    {
        if (value != null) o[key] = value;
    }

    static JsonNode? Raw(JsonNode? n) => n?.DeepClone();

    static void EncodePaint(JsonObject o, MotionLayer l)
    {
        o["fill"] = SceneJson.Anim(l.Fill);
        if (l.Stroke != null)
        {
            o["stroke"] = SceneJson.Anim(l.Stroke);
            o["strokeWidth"] = SceneJson.Anim(l.StrokeWidth);
        }
        Put(o, "lineCap", l.LineCap?.Json());
        Put(o, "lineJoin", l.LineJoin?.Json());
    }

    static JsonObject LoopNode(MotionLayer l) => new(l.Loop.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)kv.Value.Json())));

    static JsonArray WordsNode(List<WordTiming> words) => new(words.Select(w =>
    {
        var o = new JsonObject { ["t"] = w.T, ["text"] = w.Text };
        if (w.D is { } d) o["d"] = d;
        return (JsonNode)o;
    }).ToArray());

    /// <summary>Only writes fields relevant to the layer type, so JSON stays compact for humans and agents.</summary>
    public static JsonObject Encode(MotionLayer l)
    {
        var o = new JsonObject
        {
            ["id"] = l.Id,
            ["name"] = l.Name,
            ["type"] = l.Type.Json(),
            ["start"] = l.Start,
        };
        Put(o, "end", l.End);
        if (l.Type == LayerType.Audio)
        {
            Put(o, "path", l.Path);
            o["role"] = l.Role.Json();
            o["volume"] = SceneJson.Anim(l.Volume);
            if (l.TrimIn > 0) o["trimIn"] = l.TrimIn;
            if (l.FadeIn > 0) o["fadeIn"] = l.FadeIn;
            if (l.FadeOut > 0) o["fadeOut"] = l.FadeOut;
            Put(o, "duckTo", l.DuckTo);
            Put(o, "sourceDuration", l.SourceDuration);
            Put(o, "transcript", l.Transcript);
            if (l.Words != null) o["words"] = WordsNode(l.Words);
            if (l.Loop.ContainsKey("volume")) o["loop"] = LoopNode(l);
            if (l.Wiggle.ContainsKey("volume")) o["wiggle"] = ModelCodec.Encode(l.Wiggle);
            return o;
        }
        o["x"] = SceneJson.Anim(l.X);
        o["y"] = SceneJson.Anim(l.Y);
        o["scale"] = SceneJson.Anim(l.Scale);
        o["rotation"] = SceneJson.Anim(l.Rotation);
        o["opacity"] = SceneJson.Anim(l.Opacity);
        foreach (var p in AnimPropertyInfo.Extras)
            if (l.Extra.TryGetValue(p, out var v) && v != Animated<double>.Constant(p.DefaultValue()))
                o[p.Json()] = SceneJson.Anim(v);
        if (l.Extra.ContainsKey(AnimProperty.ShadowOpacity)) o["shadowColor"] = l.ShadowColor.Hex;
        // Particles always write it: a missing blendMode takes the preset's default.
        if (l.BlendMode != BlendMode.Normal || l.Type == LayerType.Particles) o["blendMode"] = l.BlendMode.Json();
        if (l.Extra.ContainsKey(AnimProperty.Glow)) Put(o, "glowColor", l.GlowColor?.Hex);
        if (l.Matte != null) o["matte"] = new JsonObject { ["source"] = l.Matte.Source, ["mode"] = l.Matte.Mode.Json() };
        if (l.Repeater != null) o["repeater"] = ModelCodec.Encode(l.Repeater);
        if (l.MotionBlur > 0) o["motionBlur"] = l.MotionBlur;
        // Written even before tint/wipe are set, so a patch that only sets the style survives the next round trip.
        Put(o, "tintColor", l.TintColor?.Hex);
        if (l.WipeStyle != null) o["wipeStyle"] = l.WipeStyle.Encode();
        Put(o, "keyColor", l.KeyColor?.Hex);
        Put(o, "shineColor", l.ShineColor?.Hex);
        Put(o, "outlineColor", l.OutlineColor?.Hex);
        Put(o, "innerGlowColor", l.InnerGlowColor?.Hex);
        if (l.Dash.Count > 0 && l.Type.IsShape()) o["dash"] = new JsonArray(l.Dash.Select(d => (JsonNode)d).ToArray());
        if (l.CornerPin is { } cp)
            o["cornerPin"] = cp.IsAnimated
                ? new JsonObject { ["keyframes"] = new JsonArray(cp.KeyframeList.Select(k => (JsonNode)new JsonObject
                    { ["t"] = k.T, ["v"] = k.V.ToJson(), ["easing"] = k.Easing.ToString() }).ToArray()) }
                : cp.ConstantValue.ToJson();
        if (l.Pins.Count > 0) o["pins"] = new JsonArray(l.Pins.Select(p => (JsonNode)p.ToJson()).ToArray());
        if (l.HideBackface) o["hideBackface"] = true;
        if (l.TrimSequential && l.Type.IsShape()) o["trimSequential"] = true;
        if (l.Curves.Count > 0) o["curves"] = new JsonArray(l.Curves.Select(p => (JsonNode)new JsonArray(p.X, p.Y)).ToArray());
        if (l.GradientMap.Count > 0) o["gradientMap"] = new JsonArray(l.GradientMap.Select(c => (JsonNode)c.Hex).ToArray());
        Put(o, "lut", l.Lut);
        if (l.Type.HasNaturalSize()) Put(o, "removeBackground", l.RemoveBackground?.Json());
        if (l.Type == LayerType.Video && l.FrameBlend != FrameBlend.Off) o["frameBlend"] = l.FrameBlend.Json();
        if (l.Depth != 0) o["depth"] = l.Depth;
        if (l.Fixed) o["fixed"] = true;
        if (l.Links.Count > 0) o["links"] = ModelCodec.Encode(l.Links);
        Put(o, "posterizeTime", l.PosterizeTime);
        if ((l.Type.IsShape() || l.Type is LayerType.Text or LayerType.Generator) && l.Gradient != null) o["gradient"] = ModelCodec.Encode(l.Gradient);
        Put(o, "parent", l.Parent);
        if (l.MotionPath != null) o["motionPath"] = ModelCodec.Encode(l.MotionPath);
        if (l.Loop.Count > 0) o["loop"] = LoopNode(l);
        if (l.Wiggle.Count > 0) o["wiggle"] = ModelCodec.Encode(l.Wiggle);
        if (l.AudioReact.Count > 0)
            o["audioReact"] = new JsonObject(l.AudioReact.Select(kv =>
            {
                var ro = new JsonObject { ["amount"] = kv.Value.Amount, ["band"] = kv.Value.Band.Json(), ["release"] = kv.Value.Release };
                if (kv.Value.Source != null) ro["source"] = kv.Value.Source;
                return KeyValuePair.Create(kv.Key, (JsonNode?)ro);
            }));

        switch (l.Type)
        {
            case LayerType.Rect or LayerType.Ellipse:
                o["width"] = SceneJson.Anim(l[AnimProperty.Width]);
                o["height"] = SceneJson.Anim(l[AnimProperty.Height]);
                if (l.Type == LayerType.Rect) o["cornerRadius"] = SceneJson.Anim(l.CornerRadius);
                EncodePaint(o, l);
                break;
            case LayerType.Path:
                o["d"] = ModelCodec.Encode(l.D);
                EncodePaint(o, l);
                if (l.FillRule != FillRule.Nonzero) o["fillRule"] = l.FillRule.Json();
                break;
            case LayerType.Text:
                o["reveal"] = SceneJson.Anim(l.Reveal);
                o["text"] = l.Text;
                o["fontSize"] = l.FontSize;
                o["fontWeight"] = l.FontWeight;
                Put(o, "fontName", l.FontName);
                o["color"] = SceneJson.Anim(l.Color);
                o["align"] = l.Align.Json();
                Put(o, "maxWidth", l.MaxWidth);
                if (l.TextAnimators.Count > 0) o["textAnimators"] = new JsonArray(l.TextAnimators.Select(a => (JsonNode)a.Encode()).ToArray());
                if (l.Stroke != null)
                {
                    o["stroke"] = SceneJson.Anim(l.Stroke);
                    o["strokeWidth"] = SceneJson.Anim(l.StrokeWidth);
                }
                if (l.CounterDecimals != 0) o["counterDecimals"] = l.CounterDecimals;
                if (l.CounterGrouping) o["counterGrouping"] = true;
                if (l.TextPath != null) o["textPath"] = ModelCodec.Encode(l.TextPath);
                break;
            case LayerType.Image:
                Put(o, "path", l.Path);
                if (l.Width != null) o["width"] = SceneJson.Anim(l.Width);
                if (l.Height != null) o["height"] = SceneJson.Anim(l.Height);
                break;
            case LayerType.Video:
                Put(o, "path", l.Path);
                if (l.Width != null) o["width"] = SceneJson.Anim(l.Width);
                if (l.Height != null) o["height"] = SceneJson.Anim(l.Height);
                if (l.TrimIn > 0) o["trimIn"] = l.TrimIn;
                if (l.Speed != 1) o["speed"] = l.Speed;
                o["playback"] = l.Playback.Json();
                Put(o, "fps", l.Fps);
                if (l.TimeRemap != null) o["timeRemap"] = SceneJson.Anim(l.TimeRemap);
                Put(o, "sourceDuration", l.SourceDuration);
                if (l.Volume != Animated<double>.Constant(1)) o["volume"] = SceneJson.Anim(l.Volume);
                Put(o, "transcript", l.Transcript);
                if (l.Words != null) o["words"] = WordsNode(l.Words);
                break;
            case LayerType.Particles:
                o["width"] = SceneJson.Anim(l[AnimProperty.Width]);
                o["height"] = SceneJson.Anim(l[AnimProperty.Height]);
                o["particles"] = l.Particles.Encode();
                Put(o, "path", l.Path);
                break;
            case LayerType.Group:
                o["children"] = new JsonArray(l.Children.Select(c => (JsonNode)Encode(c)).ToArray());
                if (l.Width != null) o["width"] = SceneJson.Anim(l.Width);
                if (l.Height != null) o["height"] = SceneJson.Anim(l.Height);
                break;
            case LayerType.Generator:
                o["generator"] = l.Generator.Encode();
                o["width"] = SceneJson.Anim(l[AnimProperty.Width]);
                o["height"] = SceneJson.Anim(l[AnimProperty.Height]);
                var kind = l.Generator.Kind;
                if (kind is not (GeneratorKind.Noise or GeneratorKind.Flare)) o["fill"] = SceneJson.Anim(l.Fill);
                if (kind == GeneratorKind.Chart)
                {
                    o["reveal"] = SceneJson.Anim(l.Reveal);
                    o["color"] = SceneJson.Anim(l.Color);
                    o["fontSize"] = l.FontSize;
                    o["fontWeight"] = l.FontWeight;
                    Put(o, "fontName", l.FontName);
                }
                if (l.StrokeWidth != Animated<double>.Constant(0)) o["strokeWidth"] = SceneJson.Anim(l.StrokeWidth);
                if (l.CornerRadius != Animated<double>.Constant(0)) o["cornerRadius"] = SceneJson.Anim(l.CornerRadius);
                break;
        }
        return o;
    }
}
