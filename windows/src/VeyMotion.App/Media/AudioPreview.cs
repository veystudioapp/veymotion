using VeyMotion.Core;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace VeyMotion.App.Media;

/// <summary>
/// Sound while the scene plays: the scene's mix (the same <see cref="AudioMixer"/> export uses) rendered to a WAV in
/// the background and played from the playhead. Remixed only when the sound layers change. Port target of
/// <c>AudioPreview</c> (<c>AudioPreview.swift</c>).
/// </summary>
sealed class AudioPreview : IDisposable
{
    readonly MediaPlayer _player = new() { AudioCategory = MediaPlayerAudioCategory.Media };
    string? _key;
    string? _ready; // the key whose WAV is loaded
    int _generation;
    bool _playing;
    Func<double>? _now;

    /// <summary>What decides the mix: the sound layers and the scene length.</summary>
    static string Signature(MotionScene s) =>
        $"{s.Duration}|" + string.Join("|", s.AllLayers.Where(l => l.Type is LayerType.Audio or LayerType.Video)
            .Select(l => SceneJson.Encode(LayerCodec.Encode(l), pretty: false)));

    /// <summary>Starts playing at the time <paramref name="now"/> gives once the mix is ready.</summary>
    public void Play(MotionScene scene, Func<double> now)
    {
        _playing = true;
        _now = now;
        var key = Signature(scene);
        if (key == _ready) { StartAt(now()); return; }
        if (key == _key) return; // still mixing
        _key = key;
        var generation = ++_generation;
        var snapshot = scene.Clone();
        _ = Task.Run(() =>
        {
            if (snapshot.SoundLayers(AudioDecoder.Shared).Count == 0) return null;
            var wav = AudioMixer.Wav(AudioMixer.Render(snapshot, AudioDecoder.Shared));
            var path = Path.Combine(Path.GetTempPath(), $"veymotion-mix-{Environment.ProcessId}-{generation}.wav");
            File.WriteAllBytes(path, wav);
            return path;
        }).ContinueWith(t =>
        {
            if (generation != _generation || t.Status != TaskStatus.RanToCompletion) return;
            _ready = key;
            _player.Source = t.Result is { } path ? MediaSource.CreateFromUri(new Uri(path)) : null;
            if (_playing && t.Result != null && _now != null) StartAt(_now());
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    void StartAt(double t)
    {
        if (_player.Source == null) return;
        _player.PlaybackSession.Position = TimeSpan.FromSeconds(t);
        _player.Play();
    }

    public void Pause()
    {
        _playing = false;
        _player.Pause();
    }

    public void Dispose() => _player.Dispose();
}
