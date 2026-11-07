using System.Text.Json.Nodes;
using VeyMotion.Core;
using VeyMotion.Mcp;

namespace VeyMotion.Core.Tests;

/// <summary>In-memory host with the app's semantics: mutate a copy, keep what the body returns.</summary>
sealed class MemoryHost(MotionScene scene) : ISceneHost
{
    public MotionScene Scene = scene;
    public List<string> Labels = [];
    public MotionScene CurrentScene() => Scene;
    public void Mutate(string label, Func<MotionScene, MotionScene> body)
    {
        Scene = body(Scene.Clone());
        Labels.Add(label);
    }
}

public class McpTests
{
    static (McpServer, MemoryHost) Server()
    {
        var host = new MemoryHost(SampleScene.Create());
        return (new McpServer(host), host);
    }

    static JsonObject Call(McpServer s, string tool, string args) =>
        (JsonObject)s.Handle(new JsonObject
        {
            ["jsonrpc"] = "2.0", ["id"] = 1, ["method"] = "tools/call",
            ["params"] = new JsonObject { ["name"] = tool, ["arguments"] = JsonNode.Parse(args) },
        })!["result"]!;

    static string TextOf(JsonObject result) => (string)result["content"]![0]!["text"]!;

    [Fact]
    public void DocsComeFromTheSwiftSource()
    {
        Assert.StartsWith("VeyMotion is a native Windows motion-graphics editor", Docs.Instructions);
        Assert.Equal(Docs.PortedTools.Count, Docs.Tools.Count()); // every ported tool has a schema
        Assert.DoesNotContain("export_video", Docs.MissingTools);
        Assert.Contains("vmotion apply_preset", ToolCatalog.CliUsage);
        Assert.DoesNotContain("\n    \"name\"", Docs.ToolsArray.ToJsonString()); // indentation stripped
    }

    [Fact]
    public void ToolsListAndInitialize()
    {
        var (s, _) = Server();
        var init = s.Handle(JsonNode.Parse("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}""")!.AsObject())!;
        Assert.Equal("2025-06-18", (string)init["result"]!["protocolVersion"]!);
        var list = s.Handle(JsonNode.Parse("""{"jsonrpc":"2.0","id":2,"method":"tools/list"}""")!.AsObject())!;
        Assert.Equal(Docs.PortedTools.Count, list["result"]!["tools"]!.AsArray().Count);
        Assert.Null(s.Handle(JsonNode.Parse("""{"jsonrpc":"2.0","method":"notifications/initialized"}""")!.AsObject()));
    }

    [Fact]
    public void Templates()
    {
        var (s, host) = Server();
        foreach (var kind in JsonName<TemplateKind>.All)
            Assert.StartsWith("Added", TextOf(Call(s, "add_template", $$"""{"kind":"{{kind}}","start":1}""")));
        var lower = host.CurrentScene().Layer("lowerThird");
        Assert.Equal(LayerType.Group, lower.Type);
        Assert.Contains(lower.Children, c => c.Id == "lowerThird-title" && c.TextAnimators.Count == 1);
        Assert.Equal(1, lower.Children.First(c => c.Id == "lowerThird-panel").Value(AnimProperty.Wipe, 1.1), 6);
        // Without the app there is no text engine or image reader.
        Assert.Contains("needs the VeyMotion app", TextOf(Call(s, "text_to_path", """{"id":"title"}""")));
        Assert.Contains("needs the VeyMotion app", TextOf(Call(s, "shatter_image", """{"path":"C:/x.png"}""")));
    }

    [Fact]
    public void ShatterCellsTileThePicture()
    {
        var cells = ImageShatter.Cells(400, 200, 32, 7);
        Assert.Equal(32, cells.Count); // 8 × 4
        Assert.Equal(400 * 200, cells.Sum(c =>
        {
            // Shoelace area of each quad: together they cover the picture exactly.
            var q = c.Quad;
            double area = 0;
            for (var i = 0; i < 4; i++) area += q[i].X * q[(i + 1) % 4].Y - q[(i + 1) % 4].X * q[i].Y;
            return Math.Abs(area) / 2;
        }), 3);
    }

    [Fact]
    public void AddUpdateRemove()
    {
        var (s, host) = Server();
        Assert.Equal("Added layer 'title-2'", TextOf(Call(s, "add_layer", """{"layer":{"id":"title","type":"text","text":"Hi"}}""")));
        Call(s, "update_layer", """{"id":"title-2","changes":{"id":"hello","fill":null,"x":{"keyframes":[{"t":0,"v":1}]}}}""");
        var l = host.Scene.Layer("hello");
        Assert.True(l.X.IsAnimated);
        Assert.Equal("Removed 'hello'", TextOf(Call(s, "remove_layer", """{"id":"hello"}""")));
        Assert.Null(host.Scene.FindLayer("hello"));
        Assert.Equal(["Add Layer", "Update Layer", "Remove Layer"], host.Labels);
    }

    [Fact]
    public void UpdateSceneKeepsLayers()
    {
        var (s, host) = Server();
        Assert.StartsWith("Scene: 1080x1920 @60fps, 8s", TextOf(Call(s, "update_scene", """{"changes":{"width":1080,"height":1920,"fps":60,"duration":8,"layers":[]}}""")));
        Assert.Equal(8, host.Scene.Layers.Count);
    }

    [Fact]
    public void KeyframesAndPresets()
    {
        var (s, host) = Server();
        Assert.Equal("""bar-1.fill = {"keyframes":[{"t":0,"v":"#FF0000","easing":"easeInOut"},{"t":1,"v":"#0000FF","easing":"linear"}]}""",
            TextOf(Call(s, "set_keyframes", """{"id":"bar-1","property":"fill","keyframes":[{"t":0,"v":"#FF0000"},{"t":1,"v":"#0000FF","easing":"linear"}]}""")));
        Assert.Equal("Applied popIn to bar-1, bar-2 from 1s for 0.5s (stagger 0.2s)",
            TextOf(Call(s, "apply_preset", """{"ids":["bar-1","bar-2"],"preset":"popIn","start":1,"duration":0.5,"stagger":0.2}""")));
        Assert.Equal(0, host.Scene.Layer("bar-2").Value(AnimProperty.Scale, 1.2), 6);
    }

    [Theory]
    [InlineData("remove_layer", """{"id":"nope"}""", "Error: Layer 'nope' not found")]
    [InlineData("apply_preset", """{"id":"bar-1","preset":"textRise","start":0}""", "Error: textRise does not apply to any of these layers")]
    [InlineData("apply_preset", """{"id":"glow","preset":"typewriter","start":0}""", "Error: typewriter does not apply to any of these layers")]
    [InlineData("render_frame", """{"time":1}""", "Error: render_frame needs the VeyMotion app")]
    [InlineData("export_video", """{"path":"C://x.mp4"}""", "Error: export_video needs the VeyMotion app on Windows. Open the app and run without --scene, or use `vmotion render`.")]
    public void ToolErrorsGoToTheModel(string tool, string args, string expected)
    {
        var (s, _) = Server();
        var r = Call(s, tool, args);
        Assert.True((bool)r["isError"]!);
        Assert.StartsWith(expected, TextOf(r));
    }

    [Fact]
    public void RenamingRepointsParentsAndMattes()
    {
        var s = SampleScene.Create();
        s.Layer("badge").Parent = "bar-4";
        s.Layer("bar-3").Matte = new Matte("bar-4");
        s.UpdateLayer("bar-4", new JsonObject { ["id"] = "last" });
        Assert.Equal("last", s.Layer("badge").Parent);
        Assert.Equal("last", s.Layer("bar-3").Matte!.Source);
        Assert.Throws<SceneException>(() => s.UpdateLayer("last", new JsonObject { ["id"] = "title" }));
    }
}
