using Microsoft.Graphics.Canvas;
using VeyMotion.App.Media;
using VeyMotion.Core;
using Windows.Foundation;

namespace VeyMotion.App.Rendering;

/// <summary>
/// Frames of video layers: a movie (Media Foundation, one reader per file) or a folder of numbered images (an image
/// sequence at the layer's fps). Recent frames are kept as bitmaps. Port of <c>VideoFrames</c>/<c>SequenceFrames</c>
/// (<c>Video.swift</c>) and the video part of <c>imageFrame</c> (<c>Renderer.swift</c>).
/// </summary>
static class VideoFrames
{
    sealed class Source
    {
        public MovieReader? Movie;
        public List<string>? Files;
        public Size Size;
        public DateTime Modified;
        public readonly Lock Gate = new();
    }

    static readonly Dictionary<string, Source?> Sources = [];
    static readonly Lock SourcesLock = new();
    static readonly LinkedList<(string Key, CanvasBitmap Bitmap)> Recent = new();
    static readonly Queue<CanvasBitmap> Retired = new();
    const int KeepCount = 8;

    static Source? Open(string path)
    {
        DateTime modified;
        try { modified = Directory.Exists(path) ? Directory.GetLastWriteTimeUtc(path) : File.GetLastWriteTimeUtc(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
        lock (SourcesLock)
        {
            if (Sources.TryGetValue(path, out var hit) && (hit == null || hit.Modified == modified)) return hit;
            Source? s = null;
            if (Core.Media.IsSequence(path))
            {
                var files = Core.Media.SequenceFiles(path);
                if (files.Count > 0 && ContentPainter.Picture(CanvasDevice.GetSharedDevice(), files[0]) is { } first)
                    s = new Source { Files = files, Size = first.Size, Modified = modified };
            }
            else if (File.Exists(path) && MovieReader.Open(path) is { } movie)
                s = new Source { Movie = movie, Size = new Size(movie.Width, movie.Height), Modified = modified };
            Sources[path] = s;
            return s;
        }
    }

    /// <summary>The source's pixel size, or null when it cannot be read.</summary>
    public static Size? NaturalSize(string path) => Open(path)?.Size;

    /// <summary>The picture shown at scene time t, with frame blending for slow motion; null when nothing shows.</summary>
    public static (CanvasBitmap A, CanvasBitmap? B, float Mix)? Frame(ICanvasResourceCreator rc, MotionLayer l, double t)
    {
        if (l.Path is not { } path || l.VideoTime(t) is not { } seconds || Open(path) is not { } src) return null;
        var fps = l.Fps ?? 30;
        var fd = src.Movie?.FrameDuration ?? 1 / Math.Max(fps, 1);
        if (l.FrameBlend != FrameBlend.Off)
        {
            var k = Math.Floor(seconds / fd + 1e-6);
            var f = seconds / fd - k;
            if (f > 0.02 && f < 0.98 && At(rc, path, src, k * fd + fd * 0.01, fps) is { } a && At(rc, path, src, (k + 1) * fd + fd * 0.01, fps) is { } b)
            {
                if (l.FrameBlend != FrameBlend.Flow) return (a, b, (float)f);
                // Optical flow: a motion-compensated in-between (block matching), kept like other frames.
                var key = $"{path}|flow|{k}|{Math.Round(f, 2)}";
                if (Cached(key) is { } hit) return (hit, null, 0);
                var fa = new BgraFrame((int)a.SizeInPixels.Width, (int)a.SizeInPixels.Height, a.GetPixelBytes());
                var fb = new BgraFrame((int)b.SizeInPixels.Width, (int)b.SizeInPixels.Height, b.GetPixelBytes());
                if (PictureML.InBetween(fa, fb, f, flow: true) is { } mid)
                {
                    var bmp = CanvasBitmap.CreateFromBytes(rc, mid.Pixels, mid.Width, mid.Height,
                        Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Premultiplied);
                    Keep(key, bmp);
                    return (bmp, null, 0);
                }
                return (a, b, (float)f);
            }
        }
        return At(rc, path, src, seconds, fps) is { } frame ? (frame, null, 0) : null;
    }

    static CanvasBitmap? At(ICanvasResourceCreator rc, string path, Source src, double seconds, double fps)
    {
        string key;
        if (src.Files is { } files)
        {
            var i = Math.Clamp((int)Math.Floor(seconds * fps + 1e-6), 0, files.Count - 1);
            key = files[i];
        }
        else key = $"{path}|{(long)Math.Floor(seconds / src.Movie!.FrameDuration + 1e-6)}";
        if (Cached(key) is { } cached) return cached;
        CanvasBitmap? bitmap = null;
        try
        {
            if (src.Files != null)
                bitmap = CanvasBitmap.LoadAsync(rc, key, 96).AsTask().GetAwaiter().GetResult();
            else
            {
                byte[]? px;
                lock (src.Gate) px = src.Movie!.FrameAt(seconds);
                if (px != null)
                    bitmap = CanvasBitmap.CreateFromBytes(rc, px, src.Movie!.Width, src.Movie.Height,
                        Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized, 96, CanvasAlphaMode.Premultiplied);
            }
        }
        catch (Exception e) when (e is IOException or ArgumentException or System.Runtime.InteropServices.COMException or UnauthorizedAccessException) { }
        if (bitmap == null) return null;
        Keep(key, bitmap);
        return bitmap;
    }

    static CanvasBitmap? Cached(string key)
    {
        lock (SourcesLock)
        {
            var node = Recent.First;
            while (node != null && node.Value.Key != key) node = node.Next;
            if (node != null) { Recent.Remove(node); Recent.AddFirst(node); return node.Value.Bitmap; }
            return null;
        }
    }

    static void Keep(string key, CanvasBitmap bitmap)
    {
        lock (SourcesLock)
        {
            Recent.AddFirst((key, bitmap));
            while (Recent.Count > KeepCount)
            {
                // Dropped frames are disposed a few frames later: another render may still be drawing one.
                Retired.Enqueue(Recent.Last!.Value.Bitmap);
                Recent.RemoveLast();
            }
            while (Retired.Count > KeepCount) Retired.Dequeue().Dispose();
        }
    }

    /// <summary>Frames for the tracking tools (stabilize, track_motion, auto_reframe): BGRA scaled to maxSide.</summary>
    public sealed class Reader : IVideoFrameReader
    {
        public (int Width, int Height)? Size(string path) => Open(path) is { } s ? ((int)s.Size.Width, (int)s.Size.Height) : null;

        public double? Duration(string path) => Open(path) is { } s
            ? s.Movie?.Duration ?? (s.Files is { } f ? f.Count / 30.0 : null) : null;

        public double? FrameDuration(string path) => Open(path)?.Movie?.FrameDuration;

        public BgraFrame? Frame(string path, double seconds, double fps, int maxSide)
        {
            if (Open(path) is not { } src) return null;
            byte[]? px;
            int w, h;
            if (src.Movie is { } movie)
            {
                lock (src.Gate) px = movie.FrameAt(seconds)?.ToArray();
                (w, h) = (movie.Width, movie.Height);
            }
            else
            {
                var file = src.Files![Math.Clamp((int)Math.Floor(seconds * Math.Max(fps, 1) + 1e-6), 0, src.Files.Count - 1)];
                using var bmp = CanvasBitmap.LoadAsync(CanvasDevice.GetSharedDevice(), file, 96).AsTask().GetAwaiter().GetResult();
                px = bmp.GetPixelBytes();
                (w, h) = ((int)bmp.SizeInPixels.Width, (int)bmp.SizeInPixels.Height);
            }
            if (px == null) return null;
            if (maxSide <= 0 || Math.Max(w, h) <= maxSide) return new BgraFrame(w, h, px);
            // Box-average down to maxSide on the long side.
            var k = (double)maxSide / Math.Max(w, h);
            int ow = Math.Max(1, (int)(w * k)), oh = Math.Max(1, (int)(h * k));
            var output = new byte[ow * oh * 4];
            for (var y = 0; y < oh; y++)
            {
                int y0 = y * h / oh, y1 = Math.Max(y0 + 1, (y + 1) * h / oh);
                for (var x = 0; x < ow; x++)
                {
                    int x0 = x * w / ow, x1 = Math.Max(x0 + 1, (x + 1) * w / ow);
                    int b = 0, g = 0, r = 0, a = 0, n = 0;
                    for (var yy = y0; yy < y1; yy++)
                        for (var xx = x0; xx < x1; xx++)
                        {
                            var i = (yy * w + xx) * 4;
                            b += px[i]; g += px[i + 1]; r += px[i + 2]; a += px[i + 3]; n++;
                        }
                    var o = (y * ow + x) * 4;
                    output[o] = (byte)(b / n); output[o + 1] = (byte)(g / n); output[o + 2] = (byte)(r / n); output[o + 3] = (byte)(a / n);
                }
            }
            return new BgraFrame(ow, oh, output);
        }
    }
}
