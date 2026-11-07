using System.Text.Json.Nodes;
using VeyMotion.Core;

namespace VeyMotion.Core.Tests;

public class SceneJsonTests
{
    [Fact]
    public void SampleDecodes()
    {
        var s = SampleScene.Create();
        Assert.Equal(8, s.Layers.Count);
        Assert.Equal(6, s.Duration);
        var title = s.FindLayer("title")!;
        Assert.Equal(LayerType.Text, title.Type);
        Assert.Equal(270, title.Value(AnimProperty.Y, 0.9), 6);
        Assert.Equal(330, title.Value(AnimProperty.Y, 0), 6);
        Assert.Equal("title", title.Name); // name defaults to the id
        Assert.Equal(new Rgba(0x6C / 255.0, 0x5C / 255.0, 0xE7 / 255.0, 0x33 / 255.0), s.FindLayer("glow")!.Fill.ConstantValue);
    }

    [Fact]
    public void EncodingIsStable()
    {
        var once = SceneJson.Encode(SampleScene.Create());
        var twice = SceneJson.Encode(SceneJson.Decode(once));
        Assert.Equal(once, twice);
    }

    [Fact]
    public void WritesOnlyRelevantFields()
    {
        var rect = (JsonObject)SceneJson.ToNode(SampleScene.Create())["layers"]![3]!;
        Assert.Equal("rect", (string)rect["type"]!);
        Assert.Equal(16, (double)rect["cornerRadius"]!);
        Assert.False(rect.ContainsKey("text"));
        Assert.False(rect.ContainsKey("stroke"));
        Assert.False(rect.ContainsKey("strokeWidth"));
        Assert.Equal("spring", (string)rect["y"]!["keyframes"]![1]!["easing"]!);
        Assert.Equal("easeInOut", (string)rect["y"]!["keyframes"]![0]!["easing"]!);
    }

    [Fact]
    public void KeepsFieldsThatAreNotPortedYet()
    {
        const string json = """
        { "width": 1080, "height": 1920, "fps": 60, "duration": 4,
          "camera": { "zoom": { "keyframes": [ {"t": 0, "v": 1}, {"t": 4, "v": 1.2} ] } },
          "layers": [
            { "id": "sparks", "type": "particles", "particles": { "preset": "sparks", "rate": 80 } },
            { "id": "bars", "type": "generator", "generator": { "kind": "chart", "values": [1, 2, 3] } },
            { "id": "dot", "type": "ellipse", "motionPath": { "points": [[0, 0], [100, 100]] },
              "wiggle": { "rotation": { "amount": 10, "frequency": 2 } }, "loop": { "rotation": "cycle" } },
            { "id": "line", "type": "path", "d": "M0 0 L100 0", "stroke": "#FFFFFF" }
          ] }
        """;
        var s = SceneJson.Decode(json);
        var node = JsonNode.Parse(SceneJson.Encode(s))!;

        Assert.Equal(1.2, (double)node["camera"]!["zoom"]!["keyframes"]![1]!["v"]!);
        var sparks = node["layers"]![0]!;
        Assert.Equal("add", (string)sparks["blendMode"]!); // preset default, always written for particles
        Assert.Equal(80, (double)sparks["particles"]!["rate"]!);
        var chart = node["layers"]![1]!;
        Assert.Equal(3, chart["generator"]!["values"]!.AsArray().Count);
        Assert.NotNull(chart["color"]); // chart generators write their text color
        var dot = node["layers"]![2]!;
        Assert.Equal(2, dot["motionPath"]!["points"]!.AsArray().Count);
        Assert.Equal(10, (double)dot["wiggle"]!["rotation"]!["amount"]!);
        Assert.Equal("cycle", (string)dot["loop"]!["rotation"]!);

        var line = s.FindLayer("line")!;
        Assert.Equal(Rgba.Clear, line.Fill.ConstantValue); // stroke-only path is a line
        Assert.Equal(4, line.StrokeWidth.ConstantValue);
        Assert.Equal("M0 0 L100 0", (string)node["layers"]![3]!["d"]!);
    }

    [Fact]
    public void ExtrasAreWrittenOnlyWhenNotDefault()
    {
        var l = new MotionLayer(LayerType.Rect, "r");
        l[AnimProperty.Blur] = 0.0;
        l[AnimProperty.ShadowOpacity] = 0.5;
        var o = LayerCodec.Encode(l);
        Assert.False(o.ContainsKey("blur"));
        Assert.Equal(0.5, (double)o["shadowOpacity"]!);
        Assert.Equal("#00000099", (string)o["shadowColor"]!);
    }

    [Fact]
    public void DuplicateIdsGetSuffixes()
    {
        var s = SceneJson.Decode("""{ "layers": [ {"id": "a", "type": "rect"}, {"id": "a", "type": "rect"}, {"type": "text"} ] }""");
        Assert.Equal(["a", "a-2", "text"], s.Layers.Select(l => l.Id));
    }

    [Theory]
    [InlineData("""{ "layers": [ {"type": "rect", "x": "left"} ] }""", "scene.layers[0].x: Expected a number")]
    [InlineData("""{ "layers": [ {"type": "rect", "fill": "red"} ] }""", "scene.layers[0].fill: Expected a color")]
    [InlineData("""{ "layers": [ {"type": "blob"} ] }""", "scene.layers[0].type: Cannot initialize LayerType")]
    [InlineData("""{ "layers": [ {"type": "rect", "loop": {"spin": "cycle"}} ] }""", "scene.layers[0].loop: Unknown property 'spin'")]
    [InlineData("""{ "layers": [ {"type": "rect", "x": {"keyframes": [{"t": 0, "v": 1, "easing": "wobbly"}]}} ] }""",
        "scene.layers[0].x.keyframes[0].easing: Unknown easing 'wobbly'")]
    [InlineData("""{ "fps": 500 }""", "fps must be between 1 and 120")]
    public void ErrorsNameThePath(string json, string expected)
    {
        var e = Assert.Throws<SceneException>(() => SceneJson.Decode(json));
        Assert.StartsWith(expected, e.Message);
    }
}

public class AnimationTests
{
    [Theory]
    [InlineData("linear")]
    [InlineData("easeIn")]
    [InlineData("easeOutBack")]
    [InlineData("easeInOutElastic")]
    [InlineData("spring")]
    [InlineData("spring(3,12)")]
    [InlineData("steps(4)")]
    [InlineData("cubicBezier(0.1,0.2,0.3,1)")]
    public void EasingRoundTrips(string s) => Assert.Equal(s, Easing.Parse(s)!.Value.ToString());

    [Fact]
    public void EasingAcceptsLooseSpelling() => Assert.Equal(Easing.Named(EaseCurve.Back, EaseMode.Out), Easing.Parse("ease-out-back"));

    [Fact]
    public void EasingEndpoints()
    {
        foreach (var name in new[] { "linear", "easeIn", "easeOut", "easeInOut", "spring", "easeOutBounce", "easeInExpo" })
        {
            var e = Easing.Parse(name)!.Value;
            Assert.Equal(0, e.Apply(0), 6);
            Assert.Equal(1, e.Apply(1), 6);
        }
        Assert.Equal(0.5, Easing.Linear.Apply(0.5));
        Assert.Equal(0, Easing.Hold.Apply(0.99));
    }

    [Fact]
    public void LoopOffsetKeepsAdding()
    {
        var a = Animated<double>.Make([new(0, 0.0, Easing.Linear), new(1, 360.0, Easing.Linear)], 0);
        Assert.Equal(360 * 2.5, a.ValueAt(2.5, LoopMode.Offset), 6);
        Assert.Equal(180, a.ValueAt(2.5, LoopMode.Cycle), 6);
        Assert.Equal(180, a.ValueAt(1.5, LoopMode.Pingpong), 6);
        Assert.Equal(270, a.ValueAt(1.25, LoopMode.Pingpong), 6);
    }

    [Fact]
    public void ColorHex()
    {
        Assert.Equal("#FF7675", Rgba.FromHex("#ff7675")!.Value.Hex);
        Assert.Equal("#6C5CE733", Rgba.FromHex("6C5CE733")!.Value.Hex);
        Assert.Null(Rgba.FromHex("#12345"));
    }

    [Fact]
    public void SettingAndDeletingKeys()
    {
        var a = Animated<double>.Constant(5);
        Assert.Equal(7, a.Setting(7, 1).ConstantValue);
        var k = Animated<double>.Make([new(0, 0.0), new(2, 10.0)], 0);
        var set = k.Setting(4, 1);
        Assert.Equal(3, set.KeyframeList.Count);
        var gone = set.DeletingKey(0, 1e-3).DeletingKey(1, 1e-3).DeletingKey(2, 1e-3);
        Assert.False(gone.IsAnimated);
    }
}
