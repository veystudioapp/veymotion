using Microsoft.Graphics.Canvas;
using VeyMotion.Core;
using VeyMotion.Mcp;
using Windows.Storage.Streams;

namespace VeyMotion.App.Rendering;

/// <summary>Offscreen frames for <c>render_frame</c>, with the same <see cref="FrameCompositor"/> as the canvas, so
/// what the agent sees matches the preview. Thread-safe: Win2D's shared device is free-threaded.</summary>
public sealed class FrameRenderer : IFrameRenderer
{
    public byte[] RenderPng(MotionScene scene, double time, double scale)
    {
        var w = Math.Max(1, (int)Math.Round(scene.Width * scale));
        var h = Math.Max(1, (int)Math.Round(scene.Height * scale));
        using var target = FrameCompositor.Render(CanvasDevice.GetSharedDevice(), scene, time, w, h);
        using var stream = new InMemoryRandomAccessStream();
        target.SaveAsync(stream, CanvasBitmapFileFormat.Png).AsTask().GetAwaiter().GetResult();
        var bytes = new byte[stream.Size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        reader.LoadAsync((uint)stream.Size).AsTask().GetAwaiter().GetResult();
        reader.ReadBytes(bytes);
        return bytes;
    }
}
