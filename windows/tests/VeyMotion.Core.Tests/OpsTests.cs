using System.Numerics;
using VeyMotion.Core;

namespace VeyMotion.Core.Tests;

public class OpsTests
{
    [Fact]
    public void GroupAndUngroupKeepOrder()
    {
        var s = SampleScene.Create();
        var gid = s.GroupLayers(["bar-1", "bar-2"], "bars");
        Assert.Equal("bars", gid);
        Assert.Equal(["glow", "title", "subtitle", "bars", "bar-3", "bar-4", "badge"], s.Layers.Select(l => l.Id));
        Assert.Equal(["bar-1", "bar-2"], s.Layer("bars").Children.Select(c => c.Id));
        Assert.Equal(960, s.Layer("bars").X.ConstantValue);
        s.Ungroup("bars");
        Assert.Equal(["glow", "title", "subtitle", "bar-1", "bar-2", "bar-3", "bar-4", "badge"], s.Layers.Select(l => l.Id));
    }

    [Fact]
    public void SetParentKeepsTheLayerInPlace()
    {
        var s = SampleScene.Create();
        var before = Vector2.Transform(Vector2.Zero, s.WorldTransform(s.Layer("badge"), 4));
        s.SetParent("badge", "bar-4", 4);
        Assert.Equal("bar-4", s.Layer("badge").Parent);
        var after = Vector2.Transform(Vector2.Zero, s.WorldTransform(s.Layer("badge"), 4));
        Assert.Equal(before.X, after.X, 2);
        Assert.Equal(before.Y, after.Y, 2);
        Assert.Throws<SceneException>(() => s.SetParent("bar-4", "badge", 0)); // a loop
    }

    [Fact]
    public void RemovingAParentKeepsChildrenInPlace()
    {
        var s = SampleScene.Create();
        s.SetParent("badge", "bar-4", 4);
        var before = Vector2.Transform(Vector2.Zero, s.WorldTransform(s.Layer("badge"), 4));
        s.RemoveLayer("bar-4");
        Assert.Null(s.Layer("badge").Parent);
        var after = Vector2.Transform(Vector2.Zero, s.WorldTransform(s.Layer("badge"), 4));
        Assert.Equal(before.X, after.X, 1);
    }

    [Fact]
    public void TransitionsAnimateBothLayers()
    {
        var s = SampleScene.Create();
        s.Transition(TransitionType.Iris, "bar-1", "bar-2", 4, 1, null);
        Assert.Equal(WipeType.Iris, s.Layer("bar-1").WipeStyle!.Type);
        Assert.Equal(5, s.Layer("bar-1").End);
        Assert.Equal(1, s.Layer("bar-1").Value(AnimProperty.Wipe, 5), 6);
        Assert.Equal(1, s.Layer("bar-2").Value(AnimProperty.Wipe, 4), 6);
        s.Transition(TransitionType.Flash, "title", null, 2, 1, null);
        Assert.NotNull(s.FindLayer("flash"));
        Assert.Throws<SceneException>(() => s.Transition(TransitionType.Fade, null, null, 0, 1, null));
    }

    [Fact]
    public void WipeRegions()
    {
        Assert.Null(new WipeStyle().VisibleRegion(1, -50, -50, 100, 100));
        Assert.NotNull(new WipeStyle(WipeType.Iris).VisibleRegion(0.5, -50, -50, 100, 100));
        Assert.Null(new WipeStyle(WipeType.Iris).VisibleRegion(0.9999, -50, -50, 100, 100) is { } r && r.IsEmpty ? null : null);
        var blocks = new WipeStyle(WipeType.Blocks, Count: 4).VisibleRegion(0.5, 0, 0, 100, 100)!;
        Assert.InRange(blocks.Subpaths.Count, 1, 15); // about half of the 16 blocks remain
        var json = SceneJson.ToNode(SceneJson.Decode("""{"layers":[{"type":"rect","wipeStyle":"iris"}]}"""));
        Assert.Equal("iris", (string)json["layers"]![0]!["wipeStyle"]!["type"]!);
    }

    [Fact]
    public void TextPresetsAddAnimators()
    {
        var s = SampleScene.Create();
        s.ApplyPreset(Preset.TextRise, "title", 1, 2);
        s.ApplyPreset(Preset.TextOut, "title", 5, 1);
        s.ApplyPreset(Preset.TextPop, "title", 0, 1); // replaces the "in" animator
        var animators = s.Layer("title").TextAnimators;
        Assert.Equal([TextUnit.Char, TextUnit.Word], animators.Select(a => a.Unit).Order());
        var pop = animators.Single(a => a.Mode == AnimatorMode.In);
        Assert.Equal(0, pop.Scale);
        Assert.Equal(1, pop.End(TextUnits.Map(s.Layer("title").Text, TextUnit.Word).Count), 6);

        var json = SceneJson.Encode(s);
        var back = SceneJson.Decode(json).Layer("title").TextAnimators;
        Assert.Equal(animators, back);
        Assert.Throws<SceneException>(() => s.ApplyPreset(Preset.TextRise, "bar-1", 0, 1));
    }

    [Fact]
    public void TextUnitsAndGlyphStates()
    {
        var (chars, nc) = TextUnits.Map("Hi you\nall", TextUnit.Char);
        Assert.Equal(8, nc);
        Assert.Equal(-1, chars[2]);
        Assert.Equal(2, TextUnits.Map("Hi you\nall", TextUnit.Line).Count);
        Assert.Equal(3, TextUnits.Map(" Hi  you all ", TextUnit.Word).Count);

        var l = SceneJson.Decode("""{"layers":[{"type":"text","text":"abc","textAnimators":[{"unit":"char","start":0,"duration":1,"stagger":1,"y":40,"easing":"linear"}]}]}""").Layers[0];
        var st = l.GlyphStates(TextUnit.Char, 3, 1.5);
        Assert.Equal(0, st[0].Dy, 6);  // done
        Assert.Equal(20, st[1].Dy, 6); // halfway
        Assert.Equal(40, st[2].Dy, 6); // not started
        Assert.Equal(0.5, st[1].Opacity, 6);
        Assert.True(st[0].IsRest);
    }

    [Fact]
    public void MeshWarps()
    {
        var json = """{"layers":[{"type":"rect","width":100,"height":100,"cornerPin":{"tl":[-60,-50],"tr":[50,-50],"br":[50,50],"bl":[-50,50]},"pins":[{"x":0,"y":0,"dy":{"keyframes":[{"t":0,"v":0},{"t":1,"v":20}]}}]}]}""";
        var l = SceneJson.Decode(json).Layers[0];
        Assert.Equal(-60, l.CornerPin!.ConstantValue.Tl.X);
        var back = SceneJson.Decode(SceneJson.Encode(SceneJson.Decode(json))).Layers[0];
        Assert.Equal(l.CornerPin.ConstantValue, back.CornerPin!.ConstantValue);
        Assert.Equal(20, back.Pins[0].Dy.ValueAt(1), 6);

        var warp = MeshWarp.Of(l, -50, -50, 100, 100, 0)!;
        var tl = warp.Map(new PathPoint(-50, -50));
        Assert.Equal(-60, tl.X, 6);
        Assert.NotNull(warp.ProjectiveMap(-50, -50, 100, 100));

        var turned = SceneJson.Decode("""{"layers":[{"type":"rect","rotationY":180,"hideBackface":true}]}""").Layers[0];
        Assert.True(MeshWarp.Of(turned, -50, -50, 100, 100, 0)!.FacesAway);
        // One moving pin translates everything.
        var pinned = SceneJson.Decode("""{"layers":[{"type":"rect","pins":[{"x":0,"y":0,"dx":10}]}]}""").Layers[0];
        Assert.Equal(new PathPoint(15, 5), MeshWarp.Of(pinned, -50, -50, 100, 100, 0)!.Map(new PathPoint(5, 5)));
    }

    [Fact]
    public void PathOperators()
    {
        var square = PathParser.RoundedRect(-50, -50, 100, 100, 0);
        var flat = PathOps.Flatten(square);
        Assert.InRange(flat.Count, 120, 150); // about every 3 px around 400 px
        var grown = PathOps.OffsetPoints(flat, 10, true);
        Assert.InRange(grown.Max(p => p.X), 59, 61); // outward
        var zig = PathOps.ZigzagPoints(flat, 5, 20, true);
        Assert.Equal(0, zig.Count % 2);
        var taper = PathOps.TaperedStroke(square, 10, 0, 0.5, 0.5, 0);
        Assert.True(taper.Count > 10);
        Assert.Empty(PathOps.TaperedStroke(square, 10, 0.3, 0.3, 0, 0));
    }

    [Fact]
    public void ParticlesAreDeterministic()
    {
        var json = """{"width":1280,"height":720,"layers":[{"id":"fire","type":"particles","x":640,"y":600,"width":100,"height":0,"particles":{"preset":"fire","size":40}}]}""";
        var s = SceneJson.Decode(json);
        var l = s.Layers[0];
        Assert.Equal(BlendMode.Add, l.BlendMode);
        Assert.Equal(240, l.Particles.Rate);
        Assert.Equal(40, l.Particles.Size);
        var encoded = SceneJson.ToNode(s)["layers"]![0]!["particles"]!.ToJsonString();
        Assert.Equal("""{"preset":"fire","size":40}""", encoded);
        var a = s.Particles(l, 1.5);
        var b = SceneJson.Decode(json).Particles(l, 1.5);
        Assert.True(a.Count > 50);
        Assert.Equal(a.Select(p => (p.X, p.Y)), b.Select(p => (p.X, p.Y)));
        Assert.All(a, p => Assert.True(p.Y < 620)); // fire rises

        var boom = SceneJson.Decode("""{"layers":[{"id":"b","type":"particles","particles":{"preset":"explosion"}}]}""");
        Assert.Equal(260, boom.Particles(boom.Layers[0], 0.1).Count);
        Assert.Empty(boom.Particles(boom.Layers[0], 3));
    }

    [Fact]
    public void Generators()
    {
        var s = SceneJson.Decode("""{"layers":[{"id":"n","type":"generator","generator":"noise","width":100,"height":50},{"id":"c","type":"generator","generator":{"kind":"chart","chart":"pie","values":[1,2]}}]}""");
        Assert.Equal(GeneratorKind.Noise, s.Layers[0].Generator.Kind);
        Assert.Equal(ChartType.Pie, s.Layers[1].Generator.ChartValue);
        var back = SceneJson.ToNode(s)["layers"]!;
        Assert.Equal("noise", (string)back[0]!["generator"]!["kind"]!);
        Assert.Null(back[0]!["fill"]);
        Assert.Equal(16 * 8 * 4, s.Layers[0].Generator.NoisePixels(16, 8, -50, -25, 100, 50, 0, "n").Length);
        var bolt = new Generator { Kind = GeneratorKind.Lightning }.Lightning(-100, -20, 200, 40, 0, 4, 1);
        Assert.Equal(3, bolt.Count); // main + 2 branches
        Assert.Equal(65, bolt[0].Points.Count); // 6 levels of midpoint displacement
    }

    [Fact]
    public void WipePresets()
    {
        var s = SampleScene.Create();
        s.ApplyPreset(Preset.WipeIn, "title", 0, 1);
        Assert.Equal(180, s.Layer("title").WipeStyle!.Angle);
        Assert.Equal(1, s.Layer("title").Value(AnimProperty.Wipe, 0), 6);
    }
}
