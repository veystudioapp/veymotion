using System.Numerics;
using Microsoft.Graphics.Canvas;
using VeyMotion.App.Rendering;
using VeyMotion.Core;
using VeyMotion.Mcp;

namespace VeyMotion.App.Media;

/// <summary>
/// Renders a scene (picture + mixed sound) to a file with the same renderer as the canvas, so preview matches export.
/// .mp4 = H.264/AAC, .m4a = sound only. When the output's aspect differs (a platform preset), the scene is placed per
/// <see cref="ExportFit"/>. Port of <c>VideoExporter</c> (<c>Exporter.swift</c>). ProRes .mov has no Windows encoder.
/// </summary>
public sealed class VideoExporter : IVideoExporter
{
    /// <summary>Exports; returns the number of frames written. Throws on bad paths and encoder errors.</summary>
    public static int Export(MotionScene scene, string path, ExportOptions o, IProgress<double>? progress = null, CancellationToken cancel = default)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext == ".mov") throw new SceneException(".mov (ProRes 4444) has no encoder on Windows: export .mp4 (H.264) instead");
        if (ext is not (".mp4" or ".m4v" or ".m4a")) throw new SceneException("The file must end in .mp4 or .m4a");
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var (first, count) = o.FrameRange(scene);
        double t0 = (double)first / scene.Fps, t1 = (double)(first + count) / scene.Fps;
        var hasAudio = scene.SoundLayers(AudioDecoder.Shared).Count > 0;
        var sound = hasAudio ? AudioMixer.Render(scene, AudioDecoder.Shared, t0, t1) : null;
        var temp = path + ".part" + ext; // the encoder picks the container from the extension
        try
        {
            if (ext == ".m4a")
            {
                if (sound == null) throw new SceneException("The scene has no sound to export");
                using (var w = new Mp4Writer(temp, 0, 0, scene.Fps, true, video: false))
                {
                    w.WriteAudio(sound);
                    w.Finish();
                }
                Replace(temp, path);
                progress?.Report(1);
                return 0;
            }
            var (pw, ph) = o.PixelSize(scene);
            var device = CanvasDevice.GetSharedDevice();
            using var writer = new Mp4Writer(temp, pw, ph, scene.Fps, sound != null);
            using var output = new CanvasRenderTarget(device, pw, ph, 96);
            var reframed = o.IsReframed(scene);
            // Where the scene goes in the output: fitted (bars) or covering (cropped), centered.
            var k = o.Fit == ExportFit.Fit ? Math.Min((double)pw / scene.Width, (double)ph / scene.Height) : Math.Max((double)pw / scene.Width, (double)ph / scene.Height);
            int sw = reframed ? Math.Max(1, (int)Math.Round(scene.Width * k)) : pw, sh = reframed ? Math.Max(1, (int)Math.Round(scene.Height * k)) : ph;
            var written = 0;
            for (var i = 0; i < count; i++)
            {
                cancel.ThrowIfCancellationRequested();
                var t = (double)(first + i) / scene.Fps;
                using var frame = FrameCompositor.Render(device, scene, t, sw, sh);
                byte[] pixels;
                if (!reframed) pixels = frame.GetPixelBytes();
                else
                {
                    using (var ds = output.CreateDrawingSession())
                    {
                        ds.Clear(FrameCompositor.ToColor(scene.Background with { A = 1 }));
                        ds.DrawImage(frame, (pw - sw) / 2f, (ph - sh) / 2f);
                    }
                    pixels = output.GetPixelBytes();
                }
                writer.WriteFrame(pixels, i);
                if (sound != null)
                {
                    // Keep the sound interleaved with the picture: everything up to the end of this frame.
                    var upTo = Math.Min(sound.Length / 2, (int)((long)(i + 1) * AudioMixer.SampleRate / scene.Fps));
                    var from = (int)((long)i * AudioMixer.SampleRate / scene.Fps);
                    if (upTo > from) writer.WriteAudio(sound.AsSpan(from * 2, (upTo - from) * 2));
                }
                written++;
                progress?.Report((double)written / count);
            }
            writer.Finish();
            writer.Dispose();
            Replace(temp, path);
            return written;
        }
        catch
        {
            try { File.Delete(temp); } catch (IOException) { }
            throw;
        }
    }

    static void Replace(string temp, string path)
    {
        if (File.Exists(path)) File.Delete(path);
        File.Move(temp, path);
    }

    int IVideoExporter.Export(MotionScene scene, string path, ExportOptions options) => Export(scene, path, options);
}
