using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

using AnimValue = Animated<double>;

/// <summary>JSON for the motion types (wiggle, motion path, repeater, gradient, links, path shapes, camera), with the
/// macOS Codable defaults and "only non-default fields" encoding.</summary>
public static class ModelCodec
{
    static JsonNode Anim(AnimValue v) => SceneJson.Anim(v);

    // Wiggle: {amount = 10, frequency = 2 (≥ 0), seed = 0}; always written whole.

    public static Wiggle DecodeWiggle(JsonNode? n, string path)
    {
        var r = Reader.Of(n, path);
        return new Wiggle(r.Num("amount") ?? 10, Math.Max(0, r.Num("frequency") ?? 2), (long)(r.Num("seed") ?? 0));
    }

    public static JsonObject Encode(Wiggle w) => new() { ["amount"] = w.Amount, ["frequency"] = w.Frequency, ["seed"] = w.Seed };

    internal static Dictionary<string, Wiggle> DecodeWiggles(Reader r, string key, string path, IEnumerable<string> allowed, string allowedText)
    {
        var result = new Dictionary<string, Wiggle>();
        if (r.Dict(key) is not { } map) return result;
        var ok = allowed.ToHashSet();
        foreach (var (k, v) in map)
        {
            if (!ok.Contains(k)) throw Reader.Fail($"{path}.{key}", $"Unknown property '{k}' in {key}. Use one of {allowedText}.");
            result[k] = DecodeWiggle(v, $"{path}.{key}.{k}");
        }
        return result;
    }

    public static JsonObject Encode(Dictionary<string, Wiggle> map) =>
        new(map.Select(kv => KeyValuePair.Create(kv.Key, (JsonNode?)Encode(kv.Value))));

    // Motion path: {points (required), smooth = true, closed = false, orient = false}; written whole.

    public static MotionPath DecodeMotionPath(JsonNode? n, string path)
    {
        var r = Reader.Of(n, path);
        var points = r.List("points", LayerCodec.ReadPoint) ?? throw Reader.Fail(path + ".points", "missing required field");
        return new MotionPath(points, r.Bool("smooth") ?? true, r.Bool("closed") ?? false, r.Bool("orient") ?? false);
    }

    public static JsonObject Encode(MotionPath m) => new()
    {
        ["points"] = Points(m.Points), ["smooth"] = m.Smooth, ["closed"] = m.Closed, ["orient"] = m.Orient,
    };

    public static JsonArray Points(IEnumerable<PathPoint> pts) => new(pts.Select(p => (JsonNode)new JsonArray(p.X, p.Y)).ToArray());

    // Repeater

    public static Repeater DecodeRepeater(JsonNode? n, string path)
    {
        var r = Reader.Of(n, path);
        var rep = new Repeater { Count = Math.Clamp(r.Int("count") ?? 3, 1, Repeater.MaxCount) };
        rep.X = r.Anim("x") ?? rep.X;
        rep.Y = r.Anim("y") ?? rep.Y;
        rep.Rotation = r.Anim("rotation") ?? rep.Rotation;
        rep.Scale = r.Anim("scale") ?? rep.Scale;
        rep.PivotX = r.Num("pivotX") ?? 0;
        rep.PivotY = r.Num("pivotY") ?? 0;
        rep.OpacityEnd = Math.Clamp(r.Num("opacityEnd") ?? 1, 0, 1);
        rep.Delay = r.Num("delay") ?? 0;
        return rep;
    }

    public static JsonObject Encode(Repeater rep)
    {
        var o = new JsonObject { ["count"] = rep.Count };
        if (rep.X != AnimValue.Constant(0)) o["x"] = Anim(rep.X);
        if (rep.Y != AnimValue.Constant(0)) o["y"] = Anim(rep.Y);
        if (rep.Rotation != AnimValue.Constant(0)) o["rotation"] = Anim(rep.Rotation);
        if (rep.Scale != AnimValue.Constant(1)) o["scale"] = Anim(rep.Scale);
        if (rep.PivotX != 0) o["pivotX"] = rep.PivotX;
        if (rep.PivotY != 0) o["pivotY"] = rep.PivotY;
        if (rep.OpacityEnd != 1) o["opacityEnd"] = rep.OpacityEnd;
        if (rep.Delay != 0) o["delay"] = rep.Delay;
        return o;
    }

    // Gradient: stops as {offset, color} or plain colors spread evenly; at least 2.

    public static Gradient DecodeGradient(JsonNode? n, string path)
    {
        var r = Reader.Of(n, path);
        var g = new Gradient { Type = r.Enum<GradientType>("type") ?? GradientType.Linear };
        var key = r.Has("stops") ? "stops" : "colors";
        if (r.Obj[key] is not JsonArray list) throw Reader.Fail($"{path}.{key}", "missing required field");
        var stops = new List<GradientStop>();
        var plain = new List<Rgba>();
        for (var i = 0; i < list.Count; i++)
        {
            var item = list[i];
            if (item is JsonValue v && v.GetValueKind() == JsonValueKind.String) plain.Add(Reader.ReadColor(item, $"{path}.{key}[{i}]"));
            else
            {
                var sr = Reader.Of(item, $"{path}.{key}[{i}]");
                stops.Add(new GradientStop(sr.Num("offset") ?? throw Reader.Fail($"{path}.{key}[{i}].offset", "missing required field"),
                    sr.Color("color") ?? throw Reader.Fail($"{path}.{key}[{i}].color", "missing required field")));
            }
        }
        if (plain.Count > 0)
        {
            if (stops.Count > 0) throw Reader.Fail($"{path}.{key}", "Use either colors or {offset, color} stops, not both");
            stops = plain.Select((c, i) => new GradientStop(plain.Count > 1 ? (double)i / (plain.Count - 1) : 0, c)).ToList();
        }
        if (stops.Count < 2) throw Reader.Fail($"{path}.{key}", "A gradient needs at least 2 colors");
        g.Stops = stops.OrderBy(s => s.Offset).ToList();
        g.Angle = r.Anim("angle") ?? 90.0;
        g.Shift = r.Anim("shift") ?? 0.0;
        g.Cx = r.Num("cx") ?? 0.5;
        g.Cy = r.Num("cy") ?? 0.5;
        g.Radius = r.Anim("radius") ?? 1.0;
        return g;
    }

    public static JsonObject Encode(Gradient g)
    {
        var o = new JsonObject
        {
            ["type"] = g.Type.Json(),
            ["stops"] = new JsonArray(g.Stops.Select(s => (JsonNode)new JsonObject { ["offset"] = s.Offset, ["color"] = s.Color.Hex }).ToArray()),
        };
        if (g.Type == GradientType.Linear) o["angle"] = Anim(g.Angle);
        else
        {
            if (g.Cx != 0.5) o["cx"] = g.Cx;
            if (g.Cy != 0.5) o["cy"] = g.Cy;
            if (g.Radius != AnimValue.Constant(1)) o["radius"] = Anim(g.Radius);
        }
        if (g.Shift != AnimValue.Constant(0)) o["shift"] = Anim(g.Shift);
        return o;
    }

    // Links: {layer (required), property (an animatable number), multiply = 1, add = 0, delay = 0}

    internal static Dictionary<string, PropertyLink> DecodeLinks(Reader r, string path)
    {
        var result = new Dictionary<string, PropertyLink>();
        if (r.Dict("links") is not { } map) return result;
        var props = string.Join(", ", JsonName<AnimProperty>.All);
        foreach (var (k, v) in map)
        {
            if (JsonName<AnimProperty>.Parse(k) == null)
                throw Reader.Fail(path + ".links", $"Unknown property '{k}' in links. Use one of [{props}].");
            var p = $"{path}.links.{k}";
            var lr = Reader.Of(v, p);
            var property = lr.Str("property") ?? "";
            if (JsonName<AnimProperty>.Parse(property) == null)
                throw Reader.Fail(p + ".property", $"Unknown property '{property}'. Use one of [{props}].");
            result[k] = new PropertyLink
            {
                Layer = lr.Str("layer") ?? throw Reader.Fail(p + ".layer", "missing required field"),
                Property = property,
                Multiply = lr.Num("multiply") ?? 1,
                Add = lr.Num("add") ?? 0,
                Delay = lr.Num("delay") ?? 0,
            };
        }
        return result;
    }

    public static JsonObject Encode(Dictionary<string, PropertyLink> links) => new(links.Select(kv =>
    {
        var o = new JsonObject { ["layer"] = kv.Value.Layer, ["property"] = kv.Value.Property };
        if (kv.Value.Multiply != 1) o["multiply"] = kv.Value.Multiply;
        if (kv.Value.Add != 0) o["add"] = kv.Value.Add;
        if (kv.Value.Delay != 0) o["delay"] = kv.Value.Delay;
        return KeyValuePair.Create(kv.Key, (JsonNode?)o);
    }));

    // Path shapes: SVG path data / shorthand string, or keyframes of them.

    public static PathShape ReadShape(JsonNode? n, string path)
    {
        if (n is not JsonValue v || v.GetValueKind() != JsonValueKind.String)
            throw Reader.Fail(path, $"Expected to decode String but found {Reader.Kind(n)} instead.");
        try { return new PathShape(v.GetValue<string>()); }
        catch (FormatException e) { throw Reader.Fail(path, $"Bad path: {e.Message}"); }
    }

    internal static Animated<PathShape>? DecodeD(Reader r, string path)
    {
        if (r.Obj["d"] is not { } n) return null;
        // A string that is not valid path data says why, instead of the generic "expected …" message.
        if (n is JsonValue) return Animated<PathShape>.Constant(ReadShape(n, path + ".d"));
        return Reader.ReadAnim(n, path + ".d", ReadShape, "SVG path data or a shape like \"star(5,200,80)\"");
    }

    public static IReadOnlyList<Keyframe<PathShape>> PathKeyframes(JsonNode? n, string path = "keyframes") =>
        n == null ? [] : Reader.ReadAnim(n, path, ReadShape, "SVG path data").KeyframeList;

    public static JsonNode Encode(Animated<PathShape> d) => d.IsAnimated
        ? new JsonObject { ["keyframes"] = new JsonArray(d.KeyframeList.Select(k => (JsonNode)new JsonObject
            { ["t"] = k.T, ["v"] = k.V.ToString(), ["easing"] = k.Easing.ToString() }).ToArray()) }
        : JsonValue.Create(d.ConstantValue.ToString());

    // Camera: a missing x/y means the scene center (written as numbers, like macOS after resolving).

    public static Camera DecodeCamera(JsonNode? n, string path)
    {
        var r = Reader.Of(n, path);
        return new Camera
        {
            X = r.Anim("x"),
            Y = r.Anim("y"),
            Zoom = r.Anim("zoom") ?? 1.0,
            Rotation = r.Anim("rotation") ?? 0.0,
            Wiggle = DecodeWiggles(r, "wiggle", path, ["x", "y", "zoom", "rotation"], "x, y, zoom or rotation"),
            Focus = r.Anim("focus") ?? 0.0,
            Aperture = r.Anim("aperture") ?? 0.0,
        };
    }

    public static JsonObject Encode(Camera c, MotionScene s)
    {
        var o = new JsonObject
        {
            ["x"] = Anim(c.X ?? AnimValue.Constant(s.Width / 2.0)),
            ["y"] = Anim(c.Y ?? AnimValue.Constant(s.Height / 2.0)),
        };
        if (c.Zoom != AnimValue.Constant(1)) o["zoom"] = Anim(c.Zoom);
        if (c.Rotation != AnimValue.Constant(0)) o["rotation"] = Anim(c.Rotation);
        if (c.Wiggle.Count > 0) o["wiggle"] = Encode(c.Wiggle);
        if (c.Focus != AnimValue.Constant(0)) o["focus"] = Anim(c.Focus);
        if (c.Aperture != AnimValue.Constant(0)) o["aperture"] = Anim(c.Aperture);
        return o;
    }
}
