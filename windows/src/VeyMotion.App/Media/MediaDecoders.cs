using System.Runtime.InteropServices;
using VeyMotion.Core;

namespace VeyMotion.App.Media;

/// <summary>Frames of a movie file through the Source Reader: reads forward and seeks only when asked for a time
/// before the current frame or far ahead (port of <c>MovieFrames</c>). Not thread-safe: lock it.</summary>
sealed class MovieReader : IDisposable
{
    readonly IMFSourceReader _reader;
    public readonly int Width, Height;
    readonly int _stride;
    public readonly double Duration;
    /// <summary>Seconds per source frame.</summary>
    public readonly double FrameDuration;
    byte[]? _frame;
    long _frameStart = long.MinValue, _frameEnd = long.MinValue;
    bool _ended;

    MovieReader(IMFSourceReader reader, int w, int h, int stride, double duration, double frameDuration)
    {
        _reader = reader; Width = w; Height = h; _stride = stride; Duration = duration; FrameDuration = frameDuration;
    }

    public static MovieReader? Open(string path)
    {
        try
        {
            MF.Start();
            MF.Check(MF.MFCreateAttributes(out var attrs, 2));
            MF.Check(attrs.SetUINT32(MF.EnableVideoProcessing, 1));
            MF.Check(MF.MFCreateSourceReaderFromURL(Path.GetFullPath(path), attrs, out var reader));
            MF.Check(reader.SetStreamSelection(MF.AllStreams, 0));
            MF.Check(reader.SetStreamSelection(MF.FirstVideoStream, 1));
            MF.Check(MF.MFCreateMediaType(out var type));
            MF.Check(type.SetGUID(MF.MajorType, MF.MediaTypeVideo));
            MF.Check(type.SetGUID(MF.SubType, MF.VideoRgb32));
            MF.Check(reader.SetCurrentMediaType(MF.FirstVideoStream, IntPtr.Zero, type));
            MF.Check(reader.GetCurrentMediaType(MF.FirstVideoStream, out var current));
            MF.Check(current.GetUINT64(MF.FrameSize, out var size));
            int w = (int)(size >> 32), h = (int)(size & 0xFFFFFFFF);
            var stride = current.GetUINT32(MF.DefaultStride, out var s) >= 0 ? unchecked((int)s) : w * 4;
            var fd = current.GetUINT64(MF.FrameRate, out var rate) >= 0 && (rate & 0xFFFFFFFF) != 0 && (rate >> 32) != 0
                ? (double)(rate & 0xFFFFFFFF) / (rate >> 32) : 1 / 30.0;
            var duration = reader.GetPresentationAttribute(MF.MediaSource, MF.PdDuration, out var pv) >= 0 ? pv.Value / 1e7 : 0;
            return w > 0 && h > 0 ? new MovieReader(reader, w, h, stride, duration, fd) : null;
        }
        catch (Exception e) when (e is COMException or InvalidCastException or ArgumentException or IOException) { return null; }
    }

    /// <summary>The frame shown at <paramref name="seconds"/> as top-down BGRA (alpha 255), or null.</summary>
    public byte[]? FrameAt(double seconds)
    {
        var t = (long)(Math.Max(0, seconds) * 1e7);
        if (_frame != null && t >= _frameStart && t < _frameEnd) return _frame;
        if (_frame != null && _ended && t >= _frameStart) return _frame; // past the last frame
        if (_frame == null || t < _frameStart || t > _frameEnd + 10_000_000)
        {
            var pos = PropVariant.FromLong(t);
            if (_reader.SetCurrentPosition(Guid.Empty, pos) < 0) return _frame;
            _ended = false;
            _frameStart = _frameEnd = long.MinValue;
        }
        for (var guard = 0; guard < 2000; guard++)
        {
            if (_reader.ReadSample(MF.FirstVideoStream, 0, out _, out var flags, out var time, out var sample) < 0) return _frame;
            if ((flags & MF.EndOfStream) != 0) { _ended = true; return _frame; }
            if (sample == null) continue;
            try
            {
                if (sample.GetSampleDuration(out var d) < 0 || d <= 0) d = (long)(FrameDuration * 1e7);
                // Frames before the one wanted are skipped without copying their pixels.
                if (time + d <= t) { _frameStart = time; _frameEnd = time + d; continue; }
                _frame = Copy(sample);
                _frameStart = time;
                _frameEnd = time + d;
                return _frame;
            }
            finally { Marshal.ReleaseComObject(sample); }
        }
        return _frame;
    }

    byte[] Copy(IMFSample sample)
    {
        MF.Check(sample.ConvertToContiguousBuffer(out var buffer));
        try
        {
            MF.Check(buffer.Lock(out var ptr, out _, out var length));
            try
            {
                var rowBytes = Width * 4;
                var output = new byte[rowBytes * Height];
                var stride = Math.Abs(_stride) >= rowBytes ? _stride : rowBytes;
                for (var y = 0; y < Height; y++)
                {
                    // A negative stride is a bottom-up image.
                    var src = stride > 0 ? y * stride : (Height - 1 - y) * -stride;
                    if (src + rowBytes > length) break;
                    Marshal.Copy(ptr + src, output, y * rowBytes, rowBytes);
                }
                for (var i = 3; i < output.Length; i += 4) output[i] = 255;
                return output;
            }
            finally { buffer.Unlock(); }
        }
        finally { Marshal.ReleaseComObject(buffer); }
    }

    public void Dispose() => Marshal.ReleaseComObject(_reader);
}

/// <summary>Sound of audio and movie files, decoded once to interleaved stereo float at 48 kHz and kept (most recently
/// used first, about 1 GB). Files without sound are remembered too. Port of <c>MediaAudio</c>/<c>readSegment</c>.</summary>
public sealed class AudioDecoder : IAudioSource
{
    public static readonly AudioDecoder Shared = new();
    readonly Dictionary<string, (DateTime Modified, float[]? Pcm)> _cache = [];
    readonly LinkedList<string> _order = new();
    readonly Lock _gate = new();
    long _bytes;
    const long Budget = 1_000_000_000;

    public float[]? Stereo48k(string path)
    {
        DateTime modified;
        try { modified = File.GetLastWriteTimeUtc(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
        if (!File.Exists(path)) return null;
        lock (_gate)
        {
            if (_cache.TryGetValue(path, out var hit) && hit.Modified == modified)
            {
                _order.Remove(path);
                _order.AddLast(path);
                return hit.Pcm;
            }
        }
        var pcm = Decode(path);
        lock (_gate)
        {
            if (_cache.Remove(path, out var old)) { _bytes -= (old.Pcm?.Length ?? 0) * 4L; _order.Remove(path); }
            _cache[path] = (modified, pcm);
            _order.AddLast(path);
            _bytes += (pcm?.Length ?? 0) * 4L;
            while (_bytes > Budget && _order.First is { } first && first.Value != path)
            {
                _order.RemoveFirst();
                if (_cache.Remove(first.Value, out var dropped)) _bytes -= (dropped.Pcm?.Length ?? 0) * 4L;
            }
        }
        return pcm;
    }

    /// <summary>The file's first audio stream as float, then mixed to stereo and resampled to 48 kHz (linear).</summary>
    static float[]? Decode(string path)
    {
        IMFSourceReader? reader = null;
        try
        {
            MF.Start();
            if (MF.MFCreateSourceReaderFromURL(Path.GetFullPath(path), null, out reader) < 0) return null;
            reader.SetStreamSelection(MF.AllStreams, 0);
            if (reader.SetStreamSelection(MF.FirstAudioStream, 1) < 0) return null;
            MF.Check(MF.MFCreateMediaType(out var type));
            type.SetGUID(MF.MajorType, MF.MediaTypeAudio);
            type.SetGUID(MF.SubType, MF.AudioFloat);
            if (reader.SetCurrentMediaType(MF.FirstAudioStream, IntPtr.Zero, type) < 0) return null;
            MF.Check(reader.GetCurrentMediaType(MF.FirstAudioStream, out var current));
            current.GetUINT32(MF.AudioChannels, out var channels);
            current.GetUINT32(MF.AudioSampleRate, out var rate);
            if (channels == 0 || rate == 0) return null;
            var samples = new List<float>(1 << 20);
            var chunk = Array.Empty<byte>();
            for (; ; )
            {
                if (reader.ReadSample(MF.FirstAudioStream, 0, out _, out var flags, out _, out var sample) < 0) break;
                if (sample != null)
                {
                    try
                    {
                        MF.Check(sample.ConvertToContiguousBuffer(out var buffer));
                        MF.Check(buffer.Lock(out var ptr, out _, out var length));
                        if (chunk.Length < length) chunk = new byte[length];
                        Marshal.Copy(ptr, chunk, 0, length);
                        buffer.Unlock();
                        Marshal.ReleaseComObject(buffer);
                        var floats = MemoryMarshal.Cast<byte, float>(chunk.AsSpan(0, length - length % 4));
                        foreach (var f in floats) samples.Add(f);
                    }
                    finally { Marshal.ReleaseComObject(sample); }
                }
                if ((flags & MF.EndOfStream) != 0) break;
            }
            if (samples.Count == 0) return null;
            return ToStereo48k(samples, (int)channels, (int)rate);
        }
        catch (Exception e) when (e is COMException or InvalidCastException or ArgumentException or IOException) { return null; }
        finally { if (reader != null) Marshal.ReleaseComObject(reader); }
    }

    static float[] ToStereo48k(List<float> interleaved, int channels, int rate)
    {
        var n = interleaved.Count / channels;
        var outN = (int)((long)n * AudioMixer.SampleRate / rate);
        var output = new float[outN * 2];
        var step = (double)rate / AudioMixer.SampleRate;
        for (var i = 0; i < outN; i++)
        {
            var pos = i * step;
            var j = (int)pos;
            var f = (float)(pos - j);
            var j1 = Math.Min(j + 1, n - 1);
            float L(int k) => interleaved[k * channels];
            float R(int k) => interleaved[k * channels + (channels > 1 ? 1 : 0)];
            output[i * 2] = L(j) + (L(j1) - L(j)) * f;
            output[i * 2 + 1] = R(j) + (R(j1) - R(j)) * f;
        }
        return output;
    }
}

/// <summary>Writes an H.264 MP4 with optional AAC sound through the Sink Writer (port target of the AVAssetWriter
/// part of <c>VideoExporter</c>). Frames are top-down BGRA; sound is interleaved stereo float at 48 kHz.</summary>
sealed class Mp4Writer : IDisposable
{
    readonly IMFSinkWriter _writer;
    uint _video, _audio = uint.MaxValue;
    readonly int _w, _h, _fps;
    long _audioWritten; // frames
    bool _disposed;

    public Mp4Writer(string path, int width, int height, int fps, bool withAudio, bool video = true)
    {
        MF.Start();
        _w = width; _h = height; _fps = fps;
        MF.Check(MF.MFCreateAttributes(out var attrs, 1));
        attrs.SetUINT32(MF.ReadwriteEnableHardware, 1);
        if (File.Exists(path)) File.Delete(path);
        MF.Check(MF.MFCreateSinkWriterFromURL(Path.GetFullPath(path), IntPtr.Zero, attrs, out _writer));
        _video = uint.MaxValue;
        if (video) AddVideo(width, height, fps);
        if (withAudio) AddAudio();
        MF.Check(_writer.BeginWriting());
    }

    void AddVideo(int width, int height, int fps)
    {
        MF.Check(MF.MFCreateMediaType(out var outV));
        outV.SetGUID(MF.MajorType, MF.MediaTypeVideo);
        outV.SetGUID(MF.SubType, MF.VideoH264);
        // About 0.15 bits per pixel per frame: crisp motion graphics at any size.
        outV.SetUINT32(MF.AvgBitrate, (uint)Math.Clamp((long)width * height * fps * 0.15, 2_000_000, 80_000_000));
        outV.SetUINT32(MF.InterlaceMode, 2);
        outV.SetUINT64(MF.FrameSize, MF.Pack((uint)width, (uint)height));
        outV.SetUINT64(MF.FrameRate, MF.Pack((uint)fps, 1));
        outV.SetUINT64(MF.PixelAspect, MF.Pack(1, 1));
        MF.Check(_writer.AddStream(outV, out _video));
        MF.Check(MF.MFCreateMediaType(out var inV));
        inV.SetGUID(MF.MajorType, MF.MediaTypeVideo);
        inV.SetGUID(MF.SubType, MF.VideoRgb32);
        inV.SetUINT32(MF.InterlaceMode, 2);
        inV.SetUINT64(MF.FrameSize, MF.Pack((uint)width, (uint)height));
        inV.SetUINT64(MF.FrameRate, MF.Pack((uint)fps, 1));
        inV.SetUINT64(MF.PixelAspect, MF.Pack(1, 1));
        inV.SetUINT32(MF.DefaultStride, (uint)(width * 4)); // top-down rows
        MF.Check(_writer.SetInputMediaType(_video, inV, null));
    }

    void AddAudio()
    {
        {
            MF.Check(MF.MFCreateMediaType(out var outA));
            outA.SetGUID(MF.MajorType, MF.MediaTypeAudio);
            outA.SetGUID(MF.SubType, MF.AudioAac);
            outA.SetUINT32(MF.AudioBits, 16);
            outA.SetUINT32(MF.AudioSampleRate, AudioMixer.SampleRate);
            outA.SetUINT32(MF.AudioChannels, 2);
            outA.SetUINT32(MF.AudioAvgBytes, 24000); // 192 kbit/s
            MF.Check(_writer.AddStream(outA, out _audio));
            MF.Check(MF.MFCreateMediaType(out var inA));
            inA.SetGUID(MF.MajorType, MF.MediaTypeAudio);
            inA.SetGUID(MF.SubType, MF.AudioPcm);
            inA.SetUINT32(MF.AudioBits, 16);
            inA.SetUINT32(MF.AudioSampleRate, AudioMixer.SampleRate);
            inA.SetUINT32(MF.AudioChannels, 2);
            inA.SetUINT32(MF.AudioBlockAlign, 4);
            inA.SetUINT32(MF.AudioAvgBytes, AudioMixer.SampleRate * 4);
            MF.Check(_writer.SetInputMediaType(_audio, inA, null));
        }
    }

    static IMFSample Sample(ReadOnlySpan<byte> data, long time, long duration)
    {
        MF.Check(MF.MFCreateMemoryBuffer(data.Length, out var buffer));
        MF.Check(buffer.Lock(out var ptr, out _, out _));
        unsafe { data.CopyTo(new Span<byte>((void*)ptr, data.Length)); }
        buffer.Unlock();
        buffer.SetCurrentLength(data.Length);
        MF.Check(MF.MFCreateSample(out var sample));
        sample.AddBuffer(buffer);
        sample.SetSampleTime(time);
        sample.SetSampleDuration(duration);
        Marshal.ReleaseComObject(buffer);
        return sample;
    }

    public void WriteFrame(byte[] bgra, int index)
    {
        long start = index * 10_000_000L / _fps, end = (index + 1) * 10_000_000L / _fps;
        var sample = Sample(bgra, start, end - start);
        try { MF.Check(_writer.WriteSample(_video, sample)); }
        finally { Marshal.ReleaseComObject(sample); }
    }

    /// <summary>Writes the next stretch of the soundtrack (interleaved stereo float at 48 kHz).</summary>
    public void WriteAudio(ReadOnlySpan<float> stereo)
    {
        if (_audio == uint.MaxValue || stereo.Length < 2) return;
        var frames = stereo.Length / 2;
        var pcm = new byte[frames * 4];
        var shorts = MemoryMarshal.Cast<byte, short>(pcm.AsSpan());
        for (var i = 0; i < frames * 2; i++) shorts[i] = (short)Math.Round(Math.Clamp(stereo[i], -1, 1) * 32767);
        var start = _audioWritten * 10_000_000L / AudioMixer.SampleRate;
        _audioWritten += frames;
        var end = _audioWritten * 10_000_000L / AudioMixer.SampleRate;
        var sample = Sample(pcm, start, end - start);
        try { MF.Check(_writer.WriteSample(_audio, sample)); }
        finally { Marshal.ReleaseComObject(sample); }
    }

    public void Finish() => MF.Check(_writer.DoFinalize());

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Marshal.ReleaseComObject(_writer);
    }
}
