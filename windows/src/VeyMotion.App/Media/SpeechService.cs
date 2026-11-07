using System.Globalization;
using VeyMotion.Core;
using VeyMotion.Mcp;
using Windows.Media.SpeechSynthesis;
using Windows.Storage.Streams;

namespace VeyMotion.App.Media;

/// <summary>
/// Windows speech: the voices installed in Settings → Time &amp; language → Speech (offline, free, exact word times
/// from the synthesizer's word boundaries), and recognition with the installed System.Speech recognizers. Port target
/// of <c>VoiceSynth</c> (<c>Voice.swift</c>) and <c>Transcriber</c> (<c>Transcribe.swift</c>).
/// </summary>
public sealed class SpeechService : ISpeech
{
    public IReadOnlyList<VoiceInfo> Voices(string? language) =>
        SpeechSynthesizer.AllVoices
            .Where(v => language == null || v.Language.StartsWith(language, StringComparison.OrdinalIgnoreCase))
            .OrderBy(v => v.Language).ThenBy(v => v.DisplayName)
            .Select(v => new VoiceInfo(v.DisplayName, v.DisplayName, v.Language, v.Description.Contains("Natural", StringComparison.OrdinalIgnoreCase) ? "natural" : "standard"))
            .ToList();

    public VoiceResult Synthesize(string text, string? voiceId, string? language, double rate, string directory)
    {
        var script = text.Trim();
        if (script.Length == 0) throw new SceneException("text is empty");
        using var synth = new SpeechSynthesizer();
        var voice = voiceId is { Length: > 0 }
            ? SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Id == voiceId || v.DisplayName.Equals(voiceId, StringComparison.OrdinalIgnoreCase)
                || v.DisplayName.Contains(voiceId, StringComparison.OrdinalIgnoreCase))
                ?? throw new SceneException($"No voice '{voiceId}'. list_voices shows the installed ones.")
            : language is { Length: > 0 }
                ? SpeechSynthesizer.AllVoices.FirstOrDefault(v => v.Language.StartsWith(language, StringComparison.OrdinalIgnoreCase))
                    ?? throw new SceneException($"No voice for '{language}'. Add one in Settings → Time & language → Speech.")
                : SpeechSynthesizer.DefaultVoice;
        synth.Voice = voice;
        synth.Options.SpeakingRate = Math.Clamp(rate, 0.5, 2);
        synth.Options.IncludeWordBoundaryMetadata = true;
        using var stream = synth.SynthesizeTextToStreamAsync(script).AsTask().GetAwaiter().GetResult();
        var words = new List<WordTiming>();
        foreach (var track in stream.TimedMetadataTracks)
            foreach (var cue in track.Cues.OfType<Windows.Media.Core.SpeechCue>())
                if (!string.IsNullOrWhiteSpace(cue.Text))
                    words.Add(new WordTiming(cue.StartTime.TotalSeconds, cue.Text, cue.Duration.TotalSeconds > 0 ? cue.Duration.TotalSeconds : null));
        words = words.OrderBy(w => w.T).ToList();
        Directory.CreateDirectory(directory);
        var path = NewFile(directory, "voice", "wav");
        var bytes = new byte[stream.Size];
        using (var reader = new DataReader(stream.GetInputStreamAt(0)))
        {
            reader.LoadAsync((uint)stream.Size).AsTask().GetAwaiter().GetResult();
            reader.ReadBytes(bytes);
        }
        File.WriteAllBytes(path + ".part", bytes);
        File.Move(path + ".part", path, true);
        var duration = WavDuration(bytes);
        return new VoiceResult(path, duration, words, true);
    }

    /// <summary>"voice-1.wav", "voice-2.wav"… the first name free in the folder.</summary>
    static string NewFile(string dir, string prefix, string ext)
    {
        for (var i = 1; ; i++)
        {
            var p = Path.Combine(dir, $"{prefix}-{i}.{ext}");
            if (!File.Exists(p)) return p;
        }
    }

    /// <summary>Seconds of a PCM WAV from its header.</summary>
    static double WavDuration(byte[] wav)
    {
        if (wav.Length < 44) return 0;
        var byteRate = BitConverter.ToInt32(wav, 28);
        // The data chunk: walk the chunks after "WAVE".
        for (var i = 12; i + 8 <= wav.Length;)
        {
            var id = System.Text.Encoding.ASCII.GetString(wav, i, 4);
            var size = BitConverter.ToInt32(wav, i + 4);
            if (id == "data") return byteRate > 0 ? Math.Min(size, wav.Length - i - 8) / (double)byteRate : 0;
            i += 8 + size + (size & 1);
        }
        return 0;
    }

    public Transcription Transcribe(string path, double from, double duration, string? language)
    {
        var recognizers = System.Speech.Recognition.SpeechRecognitionEngine.InstalledRecognizers();
        if (recognizers.Count == 0) throw new SceneException("No speech recognizer is installed on this PC (Settings → Time & language → Speech).");
        var info = language is { Length: > 0 }
            ? recognizers.FirstOrDefault(r => r.Culture.Name.StartsWith(language, StringComparison.OrdinalIgnoreCase))
                ?? throw new SceneException($"No speech recognizer for '{language}'. Installed: {string.Join(", ", recognizers.Select(r => r.Culture.Name))}.")
            : recognizers.FirstOrDefault(r => r.Culture.Equals(CultureInfo.CurrentUICulture)) ?? recognizers[0];
        var pcm = AudioDecoder.Shared.Stereo48k(path) ?? throw new SceneException($"Cannot read the sound of {path}");
        // 16 kHz mono 16-bit for the recognizer.
        int first = Math.Max(0, (int)(from * AudioMixer.SampleRate)), count = (int)Math.Min(pcm.Length / 2 - first, Math.Min(duration, 3600 * 4) * AudioMixer.SampleRate);
        if (count <= 0) return new Transcription("", [], info.Culture.Name, true);
        var samples = new short[count / 3];
        for (var i = 0; i < samples.Length; i++)
        {
            var k = (first + i * 3) * 2;
            samples[i] = (short)Math.Clamp((pcm[k] + pcm[k + 1]) * 0.5f * 32767, short.MinValue, short.MaxValue);
        }
        var wav = Path.Combine(Path.GetTempPath(), $"veymotion-asr-{Guid.NewGuid():N}.wav");
        WriteWav(wav, samples, 16_000);
        var words = new List<WordTiming>();
        try
        {
            // On a worker thread: System.Speech raises its events through the caller's synchronization context,
            // which would deadlock on the UI thread.
            var seconds = samples.Length / 16_000.0;
            Task.Run(() =>
            {
                using var engine = new System.Speech.Recognition.SpeechRecognitionEngine(info);
                engine.LoadGrammar(new System.Speech.Recognition.DictationGrammar());
                engine.SetInputToWaveFile(wav);
                engine.EndSilenceTimeout = TimeSpan.FromSeconds(0.4);
                var done = new ManualResetEventSlim();
                engine.SpeechRecognized += (_, e) =>
                {
                    // Word positions are relative to their phrase.
                    var phrase = e.Result.Audio?.AudioPosition.TotalSeconds ?? 0;
                    lock (words)
                        foreach (var w in e.Result.Words)
                        {
                            var audio = e.Result.GetAudioForWordRange(w, w);
                            words.Add(new WordTiming(phrase + audio.AudioPosition.TotalSeconds, w.Text, audio.Duration.TotalSeconds));
                        }
                };
                engine.RecognizeCompleted += (_, _) => done.Set();
                engine.RecognizeAsync(System.Speech.Recognition.RecognizeMode.Multiple);
                if (!done.Wait(TimeSpan.FromSeconds(Math.Max(60, seconds * 4)))) engine.RecognizeAsyncCancel();
            }).GetAwaiter().GetResult();
            words.Sort((x, y) => x.T.CompareTo(y.T));
        }
        finally { if (Environment.GetEnvironmentVariable("VEYMOTION_KEEP_ASR") == null) try { File.Delete(wav); } catch (IOException) { } }
        return new Transcription(string.Join(" ", words.Select(w => w.Text)), words, info.Culture.Name, true);
    }

    static void WriteWav(string path, short[] samples, int rate)
    {
        using var w = new BinaryWriter(File.Create(path));
        w.Write("RIFF"u8); w.Write(36 + samples.Length * 2); w.Write("WAVE"u8);
        w.Write("fmt "u8); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write("data"u8); w.Write(samples.Length * 2);
        foreach (var s in samples) w.Write(s);
    }
}
