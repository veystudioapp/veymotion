using VeyMotion.Core;

namespace VeyMotion.Mcp;

public sealed record VoiceInfo(string Id, string Name, string Language, string Quality);

/// <summary>A synthesized voice file. Port of <c>VoiceResult</c> (<c>Voice.swift</c>).</summary>
public sealed record VoiceResult(string Path, double Duration, List<WordTiming> Words, bool ExactTimings);

/// <summary>Recognized speech: the text and each word's time (file seconds from the start of the range).</summary>
public sealed record Transcription(string Text, List<WordTiming> Words, string Language, bool OnDevice);

/// <summary>The operating system's speech (the app's Windows.Media.SpeechSynthesis and System.Speech).</summary>
public interface ISpeech
{
    IReadOnlyList<VoiceInfo> Voices(string? language);

    /// <summary>Writes a WAV into <paramref name="directory"/>; rate 0.5–2 (1 = normal).</summary>
    VoiceResult Synthesize(string text, string? voiceId, string? language, double rate, string directory);

    /// <summary>Recognizes speech in [from, from + duration) of a file's sound.</summary>
    Transcription Transcribe(string path, double from, double duration, string? language);
}
