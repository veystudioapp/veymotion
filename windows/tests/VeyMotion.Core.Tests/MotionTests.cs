using System.Numerics;
using System.Text.Json.Nodes;
using VeyMotion.Core;

namespace VeyMotion.Core.Tests;

public class PathShapeTests
{
    [Fact]
    public void ParsesSvgCommands()
    {
        var p = new PathShape("M0 0 L100 0 H150 V50 C150 80 120 100 100 100 S50 80 50 50 Q25 25 0 50 T-20 80 A20 20 0 0 1 0 0 Z");
        Assert.Single(p.Subpaths);
        Assert.True(p.Subpaths[0].Closed);
        Assert.True(p.Subpaths[0].Segments.Count >= 9);
    }

    [Fact]
    public void RelativeCommandsAndImplicitLines()
    {
        var p = new PathShape("m10 10 20 0 0 20z");
        var s = p.Subpaths[0];
        Assert.Equal(new PathPoint(10, 10), s.Start);
        Assert.Equal(new PathPoint(30, 10), s.Segments[0].P);
        Assert.Equal(new PathPoint(30, 30), s.Segments[1].P);
    }

    [Theory]
    [InlineData("star(5,100,40)", 10)]
    [InlineData("polygon(6,100)", 6)]
    [InlineData("circle(50)", 4)]
    [InlineData("rect(200,100)", 4)]
    [InlineData("rect(200,100,20)", 8)]
    public void Shorthands(string text, int segments) => Assert.Equal(segments, new PathShape(text).Subpaths[0].Segments.Count);

    [Theory]
    [InlineData("10 10", "must start with a command")]
    [InlineData("M0 0 X5", "unknown path command")]
    [InlineData("blob(1)", "unknown shape")]
    [InlineData("star(5,a,3)", "must be numbers")]
    public void Errors(string text, string message) =>
        Assert.Contains(message, Assert.Throws<FormatException>(() => new PathShape(text)).Message);

    [Fact]
    public void BadPathInSceneSaysWhy()
    {
        var e = Assert.Throws<SceneException>(() => SceneJson.Decode("""{"layers":[{"type":"path","d":"M0 0 X"}]}"""));
        Assert.StartsWith("scene.layers[0].d: Bad path:", e.Message);
    }

    [Fact]
    public void MorphsBetweenShapes()
    {
        var a = new PathShape("star(5,100,40)");
        var b = new PathShape("circle(80)");
        var mid = PathShape.Lerp(a, b, 0.5);
        Assert.Equal(10, mid.Subpaths[0].Segments.Count); // the circle is subdivided to the star's count
        Assert.Same(a, PathShape.Lerp(a, b, 0));
        var d = Animated<PathShape>.Make([new(0, a), new(1, b)], PathShape.Zero);
        Assert.Equal(10, d.ValueAt(0.5).Subpaths[0].Segments.Count);
    }

    [Fact]
    public void ShapesRoundTripAsWritten()
    {
        var s = SceneJson.Decode("""{"layers":[{"id":"p","type":"path","d":{"keyframes":[{"t":0,"v":"star(5,100,40)"},{"t":1,"v":"circle(80)"}]}}]}""");
        var d = SceneJson.ToNode(s)["layers"]![0]!["d"]!;
        Assert.Equal("star(5,100,40)", (string)d["keyframes"]![0]!["v"]!);
    }
}

public class MotionTests
{
    [Fact]
    public void NoiseIsDeterministicAndBounded()
    {
        Assert.Equal(0xcbf29ce484222325UL, Noise.Hash(""));
        var a = Noise.Fractal(1.234, 42);
        Assert.Equal(a, Noise.Fractal(1.234, 42));
        for (var x = 0.0; x < 20; x += 0.37) Assert.InRange(Noise.Fractal(x, 7), -1.01, 1.01);
    }

    [Fact]
    public void WiggleAddsToTheValue()
    {
        var l = SceneJson.Decode("""{"layers":[{"id":"a","type":"rect","x":100,"wiggle":{"x":{"amount":30}}}]}""").Layers[0];
        var values = Enumerable.Range(0, 20).Select(i => l.Value(AnimProperty.X, i * 0.1)).ToList();
        Assert.Contains(values, v => Math.Abs(v - 100) > 1);
        Assert.All(values, v => Assert.InRange(v, 70, 130));
        Assert.Equal(10, (double)SceneJson.ToNode(SceneJson.Decode("""{"layers":[{"type":"rect","wiggle":{"y":{}}}]}"""))["layers"]![0]!["wiggle"]!["y"]!["amount"]!);
    }

    [Fact]
    public void MotionPathMovesByDistance()
    {
        var mp = new MotionPath([new(0, 0), new(100, 0), new(100, 100)], Smooth: false);
        Assert.Equal(new Vector2(100, 0), mp.Sample(0.5).Point);
        Assert.Equal(90, mp.Sample(0.75).Angle, 3);
        var closed = mp with { Closed = true };
        Assert.Equal(closed.Sample(0.1).Point, closed.Sample(1.1).Point);
    }

    [Fact]
    public void AnchorRotatesAroundTheAnchorPoint()
    {
        var l = new MotionLayer(LayerType.Rect, "r", x: 500, y: 500);
        l[AnimProperty.AnchorX] = 100.0;
        l.Rotation = 90.0;
        // The anchor stays at position + anchor; the layer's center swings around it.
        var anchor = Vector2.Transform(new Vector2(100, 0), l.LocalTransform(0));
        Assert.Equal(600, anchor.X, 3);
        Assert.Equal(500, anchor.Y, 3);
        var center = Vector2.Transform(Vector2.Zero, l.LocalTransform(0));
        Assert.Equal(600, center.X, 3);
        Assert.Equal(400, center.Y, 3);
    }

    [Fact]
    public void ParentsAndCamera()
    {
        var s = SceneJson.Decode("""
        { "camera": {"zoom": 2}, "layers": [
          {"id":"p","type":"rect","x":960,"y":540,"scale":2},
          {"id":"c","type":"rect","x":10,"y":0,"parent":"p"},
          {"id":"hud","type":"rect","x":100,"y":100,"fixed":true} ] }
        """);
        var c = Vector2.Transform(Vector2.Zero, s.SceneTransform(s.Layer("c"), 0));
        Assert.Equal(980, c.X, 3); // parent's scale 2 doubles the child's offset
        var framed = Vector2.Transform(Vector2.Zero, s.WorldTransform(s.Layer("c"), 0));
        Assert.Equal(1000, framed.X, 3); // zoom 2 around the frame center
        Assert.Equal(new Vector2(100, 100), Vector2.Transform(Vector2.Zero, s.WorldTransform(s.Layer("hud"), 0)));
        Assert.Equal(960, (double)SceneJson.ToNode(s)["camera"]!["x"]!); // a missing x is written as the scene center
    }

    [Fact]
    public void LinksFollowTheSource()
    {
        var s = SceneJson.Decode("""
        { "layers": [
          {"id":"a","type":"rect","x":{"keyframes":[{"t":0,"v":0},{"t":1,"v":100,"easing":"linear"}]}},
          {"id":"b","type":"rect","links":{"y":{"layer":"a","property":"x","multiply":2,"add":5,"delay":0.5}}} ] }
        """);
        Assert.Equal(105, s.Layer("b").Value(AnimProperty.Y, 1), 6);
        var json = SceneJson.ToNode(s)["layers"]![1]!["links"]!["y"]!;
        Assert.Equal(2, (double)json["multiply"]!);
        Assert.Throws<SceneException>(() => SceneJson.Decode("""{"layers":[{"type":"rect","links":{"y":{"layer":"a","property":"nope"}}}]}"""));
    }

    [Fact]
    public void GradientsAcceptColorsOrStops()
    {
        var s = SceneJson.Decode("""{"layers":[{"type":"rect","gradient":{"colors":["#FF0000","#00FF00","#0000FF"]}}]}""");
        var g = s.Layers[0].Gradient!;
        Assert.Equal([0, 0.5, 1], g.Stops.Select(x => x.Offset));
        var o = SceneJson.ToNode(s)["layers"]![0]!["gradient"]!;
        Assert.Equal("linear", (string)o["type"]!);
        Assert.Equal(90, (double)o["angle"]!);
        var e = Assert.Throws<SceneException>(() => SceneJson.Decode("""{"layers":[{"type":"rect","gradient":{"colors":["#FF0000"]}}]}"""));
        Assert.Contains("at least 2 colors", e.Message);
    }

    [Fact]
    public void RepeaterCopiesCompound()
    {
        var r = new Repeater { Count = 4, X = 10.0, OpacityEnd = 0.25 };
        var (m, opacity) = r.Copy(3, 0, Vector2.Zero);
        Assert.Equal(30, m.Translation.X, 3);
        Assert.Equal(0.25, opacity, 6);
    }

    [Theory]
    [InlineData(1234.5, 0, false, "1234")] // half to even
    [InlineData(1234.5, 1, true, "1,234.5")]
    [InlineData(1235.5, 0, true, "1,236")]
    public void Counter(double value, int decimals, bool grouping, string expected)
    {
        var l = new MotionLayer(LayerType.Text) { Text = "{n}", CounterDecimals = decimals, CounterGrouping = grouping };
        l[AnimProperty.Counter] = value;
        Assert.Equal(expected, l.DisplayText(0));
    }

    [Fact]
    public void ScrambleResolvesFromTheStart()
    {
        var l = new MotionLayer(LayerType.Text, "s") { Text = "HELLO WORLD" };
        l[AnimProperty.Scramble] = 0.5;
        var shown = l.DisplayText(0);
        Assert.StartsWith("HELL", shown);
        Assert.Equal(' ', shown[5]);
        l[AnimProperty.Scramble] = 0.0;
        Assert.Equal("HELLO WORLD", l.DisplayText(0));
    }

    [Fact]
    public void ColorMatrixComposes()
    {
        var m = ColorMatrix.Saturation(-1);
        // Grayscale keeps luminance: pure red becomes its Rec. 709 luma.
        Assert.Equal(0.2126, m.M[0], 4);
        var l = new MotionLayer(LayerType.Rect);
        Assert.Null(l.ColorMatrixAt(0));
        l[AnimProperty.Brightness] = 0.2;
        Assert.Equal(0.2, l.ColorMatrixAt(0)!.B[0], 6);
    }
}
