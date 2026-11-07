using VeyMotion.Core;

namespace VeyMotion.Core.Tests;

public class MediaTests
{
    sealed class FakeAudio(Dictionary<string, float[]> files) : IAudioSource
    {
        public float[]? Stereo48k(string path) => files.GetValueOrDefault(path);
    }

    [Fact]
    public void TempoOfClicks()
    {
        // A kick every 0.5 s (120 BPM) for 12 s at 24 kHz.
        const int sr = 24_000;
        var s = new float[sr * 12];
        for (var b = 0.25; b < 12; b += 0.5)
            for (var i = 0; i < 600; i++)
                s[(int)(b * sr) + i] = (float)(Math.Sin(2 * Math.PI * 60 * i / sr) * Math.Exp(-i / 150.0));
        var a = AudioAnalysis.Analyze(s, sr);
        Assert.NotNull(a.Bpm);
        Assert.InRange(a.Bpm!.Value, 118, 122);
        Assert.InRange(a.Beats.Count, 20, 24);
        Assert.True(a.Onsets.Count >= 20);
        Assert.InRange(a.SpectrumAt(0.27, 8).Max(), 0.1, 1.5);
    }

    [Fact]
    public void MixerPlacesAndFadesSound()
    {
        var tone = new float[AudioMixer.SampleRate * 2 * 2];
        Array.Fill(tone, 0.5f);
        var scene = SceneJson.Decode("""{"duration":3,"layers":[{"id":"a","type":"audio","path":"x.wav","start":1,"fadeIn":0.5,"volume":0.5}]}""");
        var mix = AudioMixer.Render(scene, new FakeAudio(new() { ["x.wav"] = tone }));
        Assert.Equal(3 * AudioMixer.SampleRate * 2, mix.Length);
        Assert.Equal(0, mix[(int)(0.5 * AudioMixer.SampleRate) * 2]);          // before the layer
        Assert.InRange(mix[(int)(2.0 * AudioMixer.SampleRate) * 2], 0.24f, 0.26f); // 0.5 × 0.5 after the fade
        Assert.InRange(mix[(int)(1.25 * AudioMixer.SampleRate) * 2], 0.1f, 0.15f); // halfway through the fade
    }

    [Fact]
    public void VideoTimes()
    {
        var once = SceneJson.Decode("""{"layers":[{"type":"video","path":"m.mp4","start":1,"sourceDuration":2,"trimIn":0.5}]}""").Layers[0];
        Assert.Equal(1.5, once.VideoTime(2)!.Value, 6);
        Assert.Equal(2 - 1e-4, once.VideoTime(10)!.Value, 6);
        var loop = SceneJson.Decode("""{"layers":[{"type":"video","path":"m.mp4","sourceDuration":2,"playback":"loop","speed":2}]}""").Layers[0];
        Assert.Equal(1, loop.VideoTime(1.5)!.Value, 6); // 3 s of source → wraps to 1
    }

    [Fact]
    public void ExportOptionsAreEven()
    {
        var scene = SceneJson.Decode("""{"width":1001,"height":563,"fps":30,"duration":2}""");
        Assert.Equal((1000, 562), new ExportOptions().PixelSize(scene));
        var o = new ExportOptions { Size = (1080, 1920), Start = 0.5, End = 1.5 };
        Assert.True(o.IsReframed(scene));
        Assert.Equal((15, 30), o.FrameRange(scene));
        Assert.Contains("TikTok accepts", string.Join(" ", PlatformPreset.Named("tiktok")!.Warnings(scene, 700, null)));
    }
}
