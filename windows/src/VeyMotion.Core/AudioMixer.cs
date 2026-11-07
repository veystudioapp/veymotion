namespace VeyMotion.Core;

/// <summary>Decoded sound of media files: interleaved stereo float at 48 kHz (the app's Media Foundation).</summary>
public interface IAudioSource
{
    /// <summary>The whole file's sound, or null when it has none or cannot be read.</summary>
    float[]? Stereo48k(string path);
}

public static class VideoTiming
{
    /// <summary>Seconds into the source shown at scene time t (after trimIn, speed and playback), or null. Port of
    /// <c>videoTime(at:)</c> (<c>Video.swift</c>).</summary>
    public static double? VideoTime(this MotionLayer l, double t)
    {
        if (l.Type != LayerType.Video) return null;
        if (l.TimeRemap != null)
        {
            // Keyframed source time: hold before the first key, after the last, and clamp to the clip.
            var r = Math.Max(0, l.Value(AnimProperty.TimeRemap, t));
            if (l.SourceDuration is { } total0 && total0 > 0) r = Math.Min(r, Math.Max(0, total0 - 1e-4));
            return r;
        }
        var s = l.TrimIn + Math.Max(0, t - l.Start) * l.Speed;
        if (l.SourceDuration is not { } total || total <= 0) return s;
        var lastFrame = Math.Max(0, total - 1e-4);
        if (l.Playback == VideoPlayback.Loop)
        {
            var span = total - l.TrimIn;
            if (span > 1e-6 && s >= total) s = l.TrimIn + (s - l.TrimIn) % span;
        }
        return Math.Min(s, lastFrame);
    }
}

/// <summary>Offline mixer: renders the scene's audio layers (and the sound of video layers) to one stereo buffer.
/// Used by preview and export, so what you hear while editing is what gets exported. Port of <c>AudioMixer</c>
/// (<c>Audio.swift</c>).</summary>
public static class AudioMixer
{
    public const int SampleRate = 48_000;
    const double DuckRamp = 0.25;

    /// <summary>What the mixer plays: audio layers with a file, plus video layers with sound at normal speed.</summary>
    public static List<MotionLayer> SoundLayers(this MotionScene s, IAudioSource source) =>
        s.AllLayers.Where(l => l.Path != null && (l.Type == LayerType.Audio
            || (l.Type == LayerType.Video && Math.Abs(l.Speed - 1) < 1e-9 && l.TimeRemap == null && !Media.IsSequence(l.Path!)
                && source.Stereo48k(l.Path!) != null))).ToList();

    /// <summary>Gain of a layer at scene time t: volume × fades × ducking under voice.</summary>
    static float Gain(MotionLayer l, double t, double start, double end, List<(double A, double B)> voice)
    {
        var g = l.Value(AnimProperty.Volume, t);
        if (l.FadeIn > 0) g *= Math.Clamp((t - start) / l.FadeIn, 0, 1);
        if (l.FadeOut > 0) g *= Math.Clamp((end - t) / l.FadeOut, 0, 1);
        if (l.DuckTo is { } duck && l.Role == AudioRole.Music)
        {
            var amount = 0.0;
            foreach (var (a, b) in voice)
            {
                if (t >= a && t <= b) { amount = 1; break; }
                if (t < a && a - t < DuckRamp) amount = Math.Max(amount, 1 - (a - t) / DuckRamp);
                if (t > b && t - b < DuckRamp) amount = Math.Max(amount, 1 - (t - b) / DuckRamp);
            }
            g *= 1 - (1 - duck) * amount;
        }
        return (float)Math.Max(0, g);
    }

    /// <summary>Mixes scene time [t0, t1) into interleaved stereo float at 48 kHz.</summary>
    public static float[] Render(MotionScene scene, IAudioSource source, double t0 = 0, double? t1 = null)
    {
        var end = Math.Min(t1 ?? scene.Duration, scene.Duration);
        var frames = (int)Math.Max(0, Math.Round((end - t0) * SampleRate));
        var output = new float[frames * 2];
        var voice = scene.AllLayers.Where(l => l.Type == LayerType.Audio && l.Path != null && l.Role == AudioRole.Voice)
            .Select(l => (l.Start, l.EffectiveEnd(scene.Duration))).ToList();
        foreach (var l in scene.SoundLayers(source))
        {
            if (source.Stereo48k(l.Path!) is not { } pcm) continue;
            // Fades end where the sound actually stops: the layer end or the scene end, whichever is first.
            double ls = l.Start, le = Math.Min(l.EffectiveEnd(scene.Duration), scene.Duration);
            double segStart = Math.Max(ls, t0), segEnd = Math.Min(le, end);
            if (segEnd <= segStart) continue;
            var srcFrames = pcm.Length / 2;
            foreach (var (ps, pe, file) in SourcePieces(l, segStart, segEnd))
            {
                var offset = (int)Math.Round((ps - t0) * SampleRate);
                var first = (int)Math.Round(file * SampleRate);
                var count = Math.Min((int)Math.Round((pe - ps) * SampleRate), Math.Min(frames - offset, srcFrames - first));
                if (count <= 0 || first < 0) continue;
                // Gain per block of 128 frames: smooth enough, much cheaper than per sample.
                for (var i = 0; i < count; i += 128)
                {
                    var blockEnd = Math.Min(i + 128, count);
                    var g = Gain(l, ps + (double)i / SampleRate, ls, le, voice);
                    if (g <= 0) continue;
                    for (var k = i; k < blockEnd; k++)
                    {
                        output[(offset + k) * 2] += pcm[(first + k) * 2] * g;
                        output[(offset + k) * 2 + 1] += pcm[(first + k) * 2 + 1] * g;
                    }
                }
            }
        }
        // Soft safety limit.
        for (var k = 0; k < output.Length; k++) output[k] = Math.Clamp(output[k], -1, 1);
        return output;
    }

    /// <summary>The stretches of scene time [from, to) where a layer plays its file continuously, with the file
    /// time at each start. Audio is one stretch; a video stops at the end of its clip (once/hold) or starts over.</summary>
    public static List<(double Start, double End, double File)> SourcePieces(MotionLayer l, double from, double to)
    {
        var file = l.TrimIn + (from - l.Start);
        if (l.Type != LayerType.Video || l.SourceDuration is not { } total || total <= l.TrimIn) return [(from, to, file)];
        var span = total - l.TrimIn;
        if (l.Playback != VideoPlayback.Loop)
        {
            var stop = Math.Min(to, l.Start + span);
            return stop > from ? [(from, stop, file)] : [];
        }
        var output = new List<(double, double, double)>();
        for (var k = Math.Floor((from - l.Start) / span); l.Start + k * span < to; k++)
        {
            var a = l.Start + k * span;
            double s = Math.Max(from, a), e = Math.Min(to, a + span);
            if (e > s) output.Add((s, e, l.TrimIn + (s - a)));
        }
        return output;
    }

    /// <summary>16-bit PCM WAV bytes of interleaved stereo float at 48 kHz.</summary>
    public static byte[] Wav(float[] stereo)
    {
        var data = stereo.Length * 2;
        using var ms = new MemoryStream(44 + data);
        using var w = new BinaryWriter(ms);
        w.Write("RIFF"u8); w.Write(36 + data); w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)2); w.Write(SampleRate); w.Write(SampleRate * 4); w.Write((short)4); w.Write((short)16);
        w.Write("data"u8); w.Write(data);
        foreach (var v in stereo) w.Write((short)Math.Round(Math.Clamp(v, -1, 1) * 32767));
        w.Flush();
        return ms.ToArray();
    }
}
