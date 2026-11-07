namespace VeyMotion.Core;

/// <summary>Reads the length of audio and movie files (the app's Windows media stack).</summary>
public interface IMediaProbe
{
    /// <summary>Seconds of the file's audio (audio files) or of the movie; null when it cannot be read.</summary>
    double? Duration(string path, bool video);
}

/// <summary>Video sources and file lengths. Port of <c>VideoSource</c> (<c>Video.swift</c>) and
/// <c>refreshMediaInfo</c> (<c>Audio.swift</c>).</summary>
public static class Media
{
    static readonly HashSet<string> SequenceExtensions = ["png", "jpg", "jpeg", "tif", "tiff", "exr", "webp", "heic", "bmp", "tga"];

    /// <summary>A folder of numbered images is an image sequence.</summary>
    public static bool IsSequence(string path) => Directory.Exists(path);

    /// <summary>The images of a sequence folder in frame order (natural sort, so frame2 comes before frame10).</summary>
    public static List<string> SequenceFiles(string path)
    {
        try
        {
            return Directory.EnumerateFiles(path)
                .Where(f => !Path.GetFileName(f).StartsWith('.') && SequenceExtensions.Contains(Path.GetExtension(f).TrimStart('.').ToLowerInvariant()))
                .Order(NaturalComparer.Instance).ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    /// <summary>Fills the length of audio and video layers that have none yet (and gives an image sequence the scene
    /// fps when it has none). Returns what could not be read. Without a probe, files are left alone.</summary>
    public static List<string> RefreshMediaInfo(this MotionScene scene, IMediaProbe? probe)
    {
        var problems = new List<string>();
        foreach (var l in scene.Layers)
        {
            if (l.SourceDuration != null || l.Path is not { } p) continue;
            switch (l.Type)
            {
                case LayerType.Audio:
                    if (probe == null) continue;
                    if (probe.Duration(p, false) is { } d) l.SourceDuration = d;
                    else problems.Add($"Cannot read audio file: {p}");
                    break;
                case LayerType.Video:
                    if (!File.Exists(p) && !Directory.Exists(p)) { problems.Add($"File not found: {p}"); continue; }
                    if (IsSequence(p))
                    {
                        var files = SequenceFiles(p);
                        if (files.Count == 0) { problems.Add($"No images (png, jpg, tiff, exr…) in folder {p}"); continue; }
                        l.Fps ??= scene.Fps;
                        l.SourceDuration = files.Count / Math.Max(l.Fps ?? scene.Fps, 1);
                    }
                    else if (probe != null)
                    {
                        if (probe.Duration(p, true) is { } seconds) l.SourceDuration = seconds;
                        else problems.Add($"Cannot read movie: {p}");
                    }
                    break;
            }
        }
        return problems;
    }

    /// <summary>Finder-like order: digit runs compare as numbers, letters case-insensitively.</summary>
    sealed class NaturalComparer : IComparer<string>
    {
        public static readonly NaturalComparer Instance = new();

        public int Compare(string? a, string? b)
        {
            a = Path.GetFileName(a) ?? ""; b = Path.GetFileName(b) ?? "";
            int i = 0, j = 0;
            while (i < a.Length && j < b.Length)
            {
                if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
                {
                    int si = i, sj = j;
                    while (i < a.Length && char.IsDigit(a[i])) i++;
                    while (j < b.Length && char.IsDigit(b[j])) j++;
                    var na = a[si..i].TrimStart('0');
                    var nb = b[sj..j].TrimStart('0');
                    var c = na.Length != nb.Length ? na.Length.CompareTo(nb.Length) : string.CompareOrdinal(na, nb);
                    if (c != 0) return c;
                    continue;
                }
                var d = char.ToLowerInvariant(a[i]).CompareTo(char.ToLowerInvariant(b[j]));
                if (d != 0) return d;
                i++; j++;
            }
            return (a.Length - i).CompareTo(b.Length - j);
        }
    }
}
