using Microsoft.Graphics.Canvas;
using VeyMotion.Core;
using Windows.Foundation;

namespace VeyMotion.App.Rendering;

/// <summary>The canvas preview: the frame rendered by <see cref="FrameCompositor"/> at the view's pixel size, fitted
/// and centered. The canvas must use the shared device (resources are shared with offscreen frames).</summary>
public static class SceneRenderer
{
    /// <summary>Draws the scene at time t fitted in a view of the given size (DIPs) at <paramref name="dpiScale"/>
    /// pixels per DIP.</summary>
    public static void Draw(CanvasDrawingSession ds, MotionScene scene, double t, Size view, float dpiScale)
    {
        var fit = Math.Min(view.Width / scene.Width, view.Height / scene.Height) * 0.96;
        if (fit <= 0) return;
        var dest = new Rect((view.Width - scene.Width * fit) / 2, (view.Height - scene.Height * fit) / 2,
            scene.Width * fit, scene.Height * fit);
        var pw = Math.Max(1, (int)Math.Round(dest.Width * dpiScale));
        var ph = Math.Max(1, (int)Math.Round(dest.Height * dpiScale));
        using var frame = FrameCompositor.Render(CanvasDevice.GetSharedDevice(), scene, t, pw, ph);
        ds.DrawImage(frame, dest);
    }
}
