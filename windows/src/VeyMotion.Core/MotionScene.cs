using System.Text.Json.Nodes;

namespace VeyMotion.Core;

public sealed class SceneException(string message) : Exception(message)
{
    public static SceneException LayerNotFound(string id) => new($"Layer '{id}' not found");
}

/// <summary>A whole scene. Port of <c>MotionScene</c> in <c>Scene.swift</c>.</summary>
public sealed class MotionScene
{
    public int Width = 1920;
    public int Height = 1080;
    public int Fps = 30;
    public double Duration = 5;
    public Rgba Background = Rgba.FromHex("#0E0E12")!.Value;
    /// <summary>Pans, zooms and turns the whole scene (null = none). Layers with depth move less or more, fixed ones not.</summary>
    public Camera? Camera;
    /// <summary>Draw order: first is bottom-most.</summary>
    public List<MotionLayer> Layers = [];

    public int FrameCount => Math.Max(1, (int)Math.Round(Duration * Fps, MidpointRounding.AwayFromZero));

    public MotionScene Clone() => SceneJson.Decode(SceneJson.Encode(this));

    public void Validate()
    {
        if (Width is < 16 or > 7680 || Height is < 16 or > 7680)
            throw new SceneException("width/height must be between 16 and 7680");
        if (Fps is < 1 or > 120) throw new SceneException("fps must be between 1 and 120");
        if (!(Duration > 0 && Duration <= 600)) throw new SceneException("duration must be in (0, 600] seconds");
    }

    /// <summary>Gives every layer (groups' children included) a unique, non-empty id.</summary>
    public void NormalizeIds()
    {
        var seen = new HashSet<string>();
        NormalizeIds(Layers, seen);
    }

    public static void NormalizeIds(List<MotionLayer> list, HashSet<string> seen)
    {
        foreach (var l in list)
        {
            var id = l.Id.Trim(' ', '\t');
            if (id.Length == 0) id = l.Type.Json();
            if (seen.Contains(id))
            {
                var n = 2;
                while (seen.Contains($"{id}-{n}")) n++;
                id = $"{id}-{n}";
            }
            seen.Add(id);
            l.Id = id;
            if (l.Type == LayerType.Group) NormalizeIds(l.Children, seen);
        }
    }

    /// <summary>Every layer in draw order, groups' children after their group.</summary>
    public IEnumerable<MotionLayer> AllLayers => Flatten(Layers);

    static IEnumerable<MotionLayer> Flatten(List<MotionLayer> list)
    {
        foreach (var l in list)
        {
            yield return l;
            if (l.Type == LayerType.Group)
                foreach (var c in Flatten(l.Children)) yield return c;
        }
    }

    /// <summary>A layer anywhere in the tree.</summary>
    public MotionLayer? FindLayer(string id) => AllLayers.FirstOrDefault(l => l.Id == id);

    /// <summary>Edits a layer anywhere in the tree.</summary>
    public void WithLayer(string id, Action<MotionLayer> body) =>
        body(FindLayer(id) ?? throw SceneException.LayerNotFound(id));

    public IEnumerable<MotionLayer> AudioLayers => Layers.Where(l => l.Type == LayerType.Audio);

    /// <summary>Points every property link at a copy of its source track (one hop), so <see cref="MotionLayer.Value"/>
    /// can follow it on its own. Called after decoding and after every edit.</summary>
    /// <remarks>TODO(port): audioReact and generator sources (need audio).</remarks>
    public void ResolveLinks()
    {
        var all = AllLayers.ToList();
        foreach (var l in all)
        {
            foreach (var link in l.Links.Values)
            {
                link.Track = null;
                if (link.Layer == l.Id || all.FirstOrDefault(x => x.Id == link.Layer) is not { } src
                    || JsonName<AnimProperty>.Parse(link.Property) is not { } p) continue;
                link.Track = new LinkedTrack(src[p], src.Loop.TryGetValue(link.Property, out var m) ? m : null,
                    src.Wiggle.GetValueOrDefault(link.Property), Noise.Hash($"{src.Id}.{link.Property}"), src.AudioReact.GetValueOrDefault(link.Property));
            }
        }
        // Audio reactions and visualizers: the file and timing of their source audio layer (default the music).
        var audio = all.Where(x => x.Type == LayerType.Audio && x.Path != null).ToList();
        var fallback = audio.FirstOrDefault(x => x.Role == AudioRole.Music) ?? audio.FirstOrDefault();
        AudioLink? LinkTo(string? id) => (id == null ? fallback : audio.FirstOrDefault(x => x.Id == id)) is { Path: { } path } s
            ? new AudioLink(path, s.Start, s.TrimIn, s.EffectiveEnd(Duration)) : null;
        foreach (var l in all)
        {
            foreach (var react in l.AudioReact.Values) react.Link = LinkTo(react.Source);
            if (l.Type == LayerType.Generator && l.Generator.UsesAudio) l.Generator.Link = LinkTo(l.Generator.Source);
        }
    }
}
