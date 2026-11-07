using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using VeyMotion.Core;
using VeyMotion.Mcp;
using Windows.Storage.Streams;

namespace VeyMotion.App.Rendering;

/// <summary>Pictures for image tools (shatter_image), read with Win2D. SVGs are rasterized at their natural size.</summary>
public sealed class ImageTools : IImageTools
{
    static CanvasDevice Device => CanvasDevice.GetSharedDevice();

    public (double NaturalW, double NaturalH, int PixelW, int PixelH)? Info(string path)
    {
        if (ContentPainter.Picture(Device, path) is not { } pic) return null;
        using var bitmap = Pixels(pic);
        return bitmap == null ? null : (pic.Size.Width, pic.Size.Height, (int)bitmap.SizeInPixels.Width, (int)bitmap.SizeInPixels.Height);
    }

    public byte[] ShardPng(string path, PathPoint[] quad, double x, double y, double w, double h)
    {
        if (ContentPainter.Picture(Device, path) is not { } pic) throw new IOException($"Cannot read image at '{path}'");
        using var source = Pixels(pic) ?? throw new IOException($"Cannot read image at '{path}'");
        int pw = Math.Max(1, (int)Math.Ceiling(w)), ph = Math.Max(1, (int)Math.Ceiling(h));
        using var target = new CanvasRenderTarget(Device, pw, ph, 96);
        using (var ds = target.CreateDrawingSession())
        {
            ds.Clear(Windows.UI.Color.FromArgb(0, 0, 0, 0));
            using var clip = CanvasGeometry.CreatePolygon(ds, quad.Select(p => new Vector2((float)(p.X - x), (float)(p.Y - y))).ToArray());
            using (ds.CreateLayer(1, clip)) ds.DrawImage(source, (float)-x, (float)-y);
        }
        using var stream = new InMemoryRandomAccessStream();
        target.SaveAsync(stream, CanvasBitmapFileFormat.Png).AsTask().GetAwaiter().GetResult();
        var bytes = new byte[stream.Size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        reader.LoadAsync((uint)stream.Size).AsTask().GetAwaiter().GetResult();
        reader.ReadBytes(bytes);
        return bytes;
    }

    /// <summary>A PNG of a picture file scaled to at most maxPixels on its long side (read_asset previews).</summary>
    public static byte[]? PreviewPng(string path, int maxPixels)
    {
        if (ContentPainter.Picture(Device, path) is not { } pic) return null;
        using var source = Pixels(pic);
        if (source == null) return null;
        var k = Math.Min(1, maxPixels / Math.Max(source.Size.Width, source.Size.Height));
        using var target = new CanvasRenderTarget(Device, (float)Math.Max(1, source.Size.Width * k), (float)Math.Max(1, source.Size.Height * k), 96);
        using (var ds = target.CreateDrawingSession())
        {
            ds.Clear(Windows.UI.Color.FromArgb(0, 0, 0, 0));
            ds.DrawImage(source, target.Bounds, source.Bounds, 1, CanvasImageInterpolation.HighQualityCubic);
        }
        using var stream = new InMemoryRandomAccessStream();
        target.SaveAsync(stream, CanvasBitmapFileFormat.Png).AsTask().GetAwaiter().GetResult();
        var bytes = new byte[stream.Size];
        using var reader = new DataReader(stream.GetInputStreamAt(0));
        reader.LoadAsync((uint)stream.Size).AsTask().GetAwaiter().GetResult();
        reader.ReadBytes(bytes);
        return bytes;
    }

    /// <summary>The picture's pixels: its bitmap, or the SVG drawn at its natural size.</summary>
    static CanvasRenderTarget? Pixels((CanvasBitmap? Bitmap, Microsoft.Graphics.Canvas.Svg.CanvasSvgDocument? Svg, Windows.Foundation.Size Size) pic)
    {
        var size = pic.Bitmap is { } b ? new Windows.Foundation.Size(b.SizeInPixels.Width, b.SizeInPixels.Height) : pic.Size;
        if (size.Width < 1 || size.Height < 1) return null;
        var target = new CanvasRenderTarget(Device, (float)size.Width, (float)size.Height, 96);
        using var ds = target.CreateDrawingSession();
        ds.Clear(Windows.UI.Color.FromArgb(0, 0, 0, 0));
        if (pic.Bitmap is { } bmp) ds.DrawImage(bmp);
        else if (pic.Svg is { } svg) ds.DrawSvg(svg, size);
        return target;
    }
}
