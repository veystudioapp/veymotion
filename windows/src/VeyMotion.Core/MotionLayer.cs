using System.Text.Json.Nodes;

namespace VeyMotion.Core;

using AnimValue = Animated<double>;
using ColorValue = Animated<Rgba>;

/// <summary>
/// One visual element. Port of <c>MotionLayer</c> in <c>Scene.swift</c>. Position (x, y) is the layer's center in
/// scene pixels, origin top-left (relative to the parent's center when <see cref="Parent"/> is set).
/// <para>
/// Fields whose types are not ported yet (motion paths, particles, generators, gradients…) are kept as raw JSON
/// (<see cref="JsonNode"/>) and written back unchanged, so a scene made on macOS survives a round trip here.
/// </para>
/// A reference type, unlike the Swift struct: use <see cref="Clone"/> before keeping a snapshot (undo).
/// </summary>
public sealed class MotionLayer
{
    public string Id = "";
    public string Name;
    public LayerType Type;
    public double Start;
    public double? End;

    public AnimValue X = 960.0;
    public AnimValue Y = 540.0;
    public AnimValue Scale = 1.0;
    public AnimValue Rotation = 0.0;
    public AnimValue Opacity = 1.0;
    /// <summary>Text only: fraction of characters shown (0…1), for typewriter effects.</summary>
    public AnimValue Reveal = 1.0;
    /// <summary>Less common animatable properties (scaleX, skew, anchor, blur, shadow…). Missing = default value.</summary>
    public Dictionary<AnimProperty, AnimValue> Extra = [];

    public string? Parent;
    /// <summary>Per-track behavior after the last keyframe, keyed by property name ("rotation", "fill", "d"…).</summary>
    public Dictionary<string, LoopMode> Loop = [];
    public Rgba ShadowColor = new(0, 0, 0, 0.6);
    public BlendMode BlendMode = BlendMode.Normal;
    public Rgba? GlowColor;
    public Matte? Matte;
    public double MotionBlur;
    public Rgba? TintColor;
    public Rgba? KeyColor;
    public Rgba? ShineColor;
    public Rgba? OutlineColor;
    public Rgba? InnerGlowColor;
    public List<double> Dash = [];
    public bool HideBackface;
    public bool TrimSequential;
    public List<PathPoint> Curves = [];
    public List<Rgba> GradientMap = [];
    public string? Lut;
    public BackgroundRemoval? RemoveBackground;
    public FrameBlend FrameBlend = FrameBlend.Off;
    public double Depth;
    public bool Fixed;
    public List<MotionLayer> Children = [];
    public double? PosterizeTime;

    /// <summary>When set, the layer's center follows this path (x/y are ignored), driven by pathProgress.</summary>
    public MotionPath? MotionPath;
    /// <summary>Procedural noise added to numeric properties, keyed by property name.</summary>
    public Dictionary<string, Wiggle> Wiggle = [];
    /// <summary>Draws stepped copies of the layer.</summary>
    public Repeater? Repeater;
    /// <summary>Linear or radial fill (shapes, paths, text); replaces the solid fill/color.</summary>
    public Gradient? Gradient;
    /// <summary>Properties driven by another layer's property (one hop), keyed by property name.</summary>
    public Dictionary<string, PropertyLink> Links = [];
    /// <summary>Path: the shape in layer px around the layer's x/y (keyframes morph between shapes).</summary>
    public Animated<PathShape> D = PathShape.Zero;

    /// <summary>Shape of the wipe transition (null = linear, left to right).</summary>
    public WipeStyle? WipeStyle;

    /// <summary>Text: per character/word/line animations.</summary>
    public List<TextAnimator> TextAnimators = [];
    /// <summary>Text: the text runs along this path (layer px around the layer's center) instead of in lines.</summary>
    public MotionPath? TextPath;

    // Not ported yet: kept verbatim.
    /// <summary>Properties moved by the music, keyed by property name.</summary>
    public Dictionary<string, AudioReact> AudioReact = [];

    /// <summary>Generator: what it draws (spectrum, waveform, noise, lightning, grid, chart, flare).</summary>
    public Generator Generator = new();

    /// <summary>Particles: the emitter's settings (preset + overrides).</summary>
    public ParticleSystem Particles = new();

    /// <summary>Corner pin: where the four corners of the layer's box go (animatable).</summary>
    public Animated<CornerPin>? CornerPin;
    /// <summary>Puppet pins bending the layer.</summary>
    public List<PuppetPin> Pins = [];

    /// <summary>Whether the layer may be mesh-warped (cheap check, before evaluating anything).</summary>
    public bool RotationXYOrPinned =>
        CornerPin != null || Pins.Count > 0 || Extra.ContainsKey(AnimProperty.RotationX) || Extra.ContainsKey(AnimProperty.RotationY);

    // Shape (rect/ellipse) and image size. Images default to their natural size.
    public AnimValue? Width;
    public AnimValue? Height;
    public AnimValue CornerRadius = 0.0;
    public ColorValue Fill = Rgba.White;
    public ColorValue? Stroke;
    public AnimValue StrokeWidth = 0.0;
    public LineCap? LineCap;
    public LineJoin? LineJoin;
    public FillRule FillRule = FillRule.Nonzero;

    // Text
    public string Text;
    public double FontSize = 72;
    public string FontWeight = "bold";
    public string? FontName;
    public ColorValue Color = Rgba.White;
    public TextAlign Align = TextAlign.Center;
    public double? MaxWidth;
    public int CounterDecimals;
    public bool CounterGrouping;

    // Image / video / audio file (a video can also be a folder of numbered images; particles: the sprite image)
    public string? Path;

    // Video
    public double Speed = 1;
    public VideoPlayback Playback = VideoPlayback.Once;
    public double? Fps;
    public AnimValue? TimeRemap;

    // Audio
    public AnimValue Volume = 1.0;
    public AudioRole Role = AudioRole.Sfx;
    public double TrimIn;
    public double FadeIn;
    public double FadeOut;
    public double? DuckTo;
    public double? SourceDuration;
    public string? Transcript;
    public List<WordTiming>? Words;

    public MotionLayer(LayerType type, string id = "", string? name = null, double x = 960, double y = 540)
    {
        Type = type;
        Id = id;
        Name = name ?? type.Title();
        X = x;
        Y = y;
        Text = type == LayerType.Text ? "Text" : "";
    }

    public MotionLayer Clone() => LayerCodec.Decode(LayerCodec.Encode(this), "layer");

    public AnimValue this[AnimProperty p]
    {
        get => p switch
        {
            AnimProperty.X => X,
            AnimProperty.Y => Y,
            AnimProperty.Scale => Scale,
            AnimProperty.Rotation => Rotation,
            AnimProperty.Opacity => Opacity,
            AnimProperty.Reveal => Reveal,
            AnimProperty.Volume => Volume,
            AnimProperty.Width => Width ?? (Type.HasNaturalSize() ? 0.0 : p.DefaultValue()),
            AnimProperty.Height => Height ?? (Type.HasNaturalSize() ? 0.0 : p.DefaultValue()),
            AnimProperty.TimeRemap => TimeRemap ?? 0.0,
            AnimProperty.CornerRadius => CornerRadius,
            AnimProperty.StrokeWidth => StrokeWidth,
            _ => Extra.TryGetValue(p, out var v) ? v : p.DefaultValue(),
        };
        set
        {
            switch (p)
            {
                case AnimProperty.X: X = value; break;
                case AnimProperty.Y: Y = value; break;
                case AnimProperty.Scale: Scale = value; break;
                case AnimProperty.Rotation: Rotation = value; break;
                case AnimProperty.Opacity: Opacity = value; break;
                case AnimProperty.Reveal: Reveal = value; break;
                case AnimProperty.Volume: Volume = value; break;
                case AnimProperty.Width: Width = Type.HasNaturalSize() && value == AnimValue.Constant(0) ? null : value; break;
                case AnimProperty.Height: Height = Type.HasNaturalSize() && value == AnimValue.Constant(0) ? null : value; break;
                case AnimProperty.TimeRemap: TimeRemap = value; break;
                case AnimProperty.CornerRadius: CornerRadius = value; break;
                case AnimProperty.StrokeWidth: StrokeWidth = value; break;
                default:
                    if (value == AnimValue.Constant(p.DefaultValue())) Extra.Remove(p);
                    else Extra[p] = value;
                    break;
            }
        }
    }

    public ColorValue this[ColorProperty c]
    {
        get => c switch
        {
            ColorProperty.Fill => Fill,
            ColorProperty.Stroke => Stroke ?? Rgba.Clear,
            _ => Color,
        };
        set
        {
            switch (c)
            {
                case ColorProperty.Fill: Fill = value; break;
                case ColorProperty.Stroke: Stroke = value; break;
                default: Color = value; break;
            }
        }
    }

    /// <summary>Value of a property at time t, including loops, wiggle and links to other layers.</summary>
    /// <remarks>TODO(port): audioReact (needs audio analysis).</remarks>
    public double Value(AnimProperty p, double t)
    {
        var name = p.Json();
        if (Links.TryGetValue(name, out var link) && link.Track is { } track)
            return track.ValueAt(t - link.Delay) * link.Multiply + link.Add + ProceduralOffset(p, t);
        return this[p].ValueAt(t, Loop.TryGetValue(name, out var m) ? m : null) + ProceduralOffset(p, t);
    }

    /// <summary>What wiggle and audio react add to a property at time t.</summary>
    public double ProceduralOffset(AnimProperty p, double t)
    {
        var name = p.Json();
        var v = Wiggle.TryGetValue(name, out var w) && w.Amount != 0 ? w.Offset(t, Noise.Hash($"{Id}.{name}")) : 0;
        if (AudioReact.TryGetValue(name, out var r)) v += r.Offset(t);
        return v;
    }

    /// <summary>Path layers: the shape at time t (morphing between keyframes, looping under "d").</summary>
    public PathShape PathShapeAt(double t) => D.ValueAt(t, Loop.TryGetValue("d", out var m) ? m : null);

    /// <summary>Color at time t, including loops. Null for a layer without a stroke.</summary>
    public Rgba? ColorAt(ColorProperty c, double t)
    {
        if (c == ColorProperty.Stroke && Stroke == null) return null;
        return this[c].ValueAt(t, Loop.TryGetValue(c.Json(), out var m) ? m : null);
    }

    /// <summary>Properties that make sense for this layer type (inspector, timeline).</summary>
    public List<AnimProperty> ApplicableProperties
    {
        get
        {
            if (Type == LayerType.Audio) return [AnimProperty.Volume];
            List<AnimProperty> list =
            [
                AnimProperty.X, AnimProperty.Y, AnimProperty.Scale, AnimProperty.ScaleX, AnimProperty.ScaleY,
                AnimProperty.Rotation, AnimProperty.RotationX, AnimProperty.RotationY, AnimProperty.Perspective,
                AnimProperty.SkewX, AnimProperty.SkewY, AnimProperty.AnchorX, AnimProperty.AnchorY, AnimProperty.Opacity,
            ];
            switch (Type)
            {
                case LayerType.Rect:
                    list.AddRange([AnimProperty.Width, AnimProperty.Height, AnimProperty.CornerRadius, AnimProperty.StrokeWidth,
                        AnimProperty.TrimStart, AnimProperty.Trim, AnimProperty.TrimOffset]);
                    break;
                case LayerType.Ellipse:
                    list.AddRange([AnimProperty.Width, AnimProperty.Height, AnimProperty.StrokeWidth, AnimProperty.TrimStart,
                        AnimProperty.Trim, AnimProperty.TrimOffset]);
                    break;
                case LayerType.Path:
                    list.AddRange([AnimProperty.StrokeWidth, AnimProperty.TrimStart, AnimProperty.Trim, AnimProperty.TrimOffset]);
                    break;
                case LayerType.Text:
                    list.AddRange([AnimProperty.Reveal, AnimProperty.LetterSpacing, AnimProperty.StrokeWidth, AnimProperty.Scramble]);
                    if (Text.Contains("{n}")) list.Add(AnimProperty.Counter);
                    if (TextPath != null) list.Add(AnimProperty.TextOffset);
                    break;
                case LayerType.Image:
                    list.AddRange([AnimProperty.Width, AnimProperty.Height]);
                    break;
                case LayerType.Video:
                    list.AddRange([AnimProperty.Width, AnimProperty.Height, AnimProperty.Volume]);
                    if (TimeRemap != null) list.Add(AnimProperty.TimeRemap);
                    break;
                case LayerType.Particles:
                    list.AddRange([AnimProperty.Width, AnimProperty.Height, AnimProperty.Emission, AnimProperty.ParticleSpeed,
                        AnimProperty.ParticleSize]);
                    break;
                case LayerType.Generator:
                    list.AddRange([AnimProperty.Width, AnimProperty.Height, AnimProperty.CornerRadius, AnimProperty.StrokeWidth]);
                    if (Generator.Kind == Core.GeneratorKind.Chart) list.Add(AnimProperty.Reveal);
                    break;
                case LayerType.Group:
                    list.AddRange([AnimProperty.Width, AnimProperty.Height]);
                    break;
            }
            list.AddRange([AnimProperty.Blur, AnimProperty.ShadowX, AnimProperty.ShadowY, AnimProperty.ShadowBlur,
                AnimProperty.ShadowOpacity, AnimProperty.Glow, AnimProperty.GlowRadius]);
            list.AddRange([AnimProperty.Brightness, AnimProperty.Contrast, AnimProperty.Saturation, AnimProperty.Hue,
                AnimProperty.Tint, AnimProperty.Wipe, AnimProperty.LevelsBlack, AnimProperty.LevelsWhite, AnimProperty.LevelsGamma]);
            if (GradientMap.Count > 0) list.Add(AnimProperty.GradientMapAmount);
            if (Lut != null) list.Add(AnimProperty.LutAmount);
            list.AddRange([AnimProperty.Posterize, AnimProperty.Pixelate, AnimProperty.RgbSplit, AnimProperty.Glitch,
                AnimProperty.Grain, AnimProperty.Scanlines, AnimProperty.Vignette, AnimProperty.DirectionalBlur,
                AnimProperty.BlurAngle, AnimProperty.ZoomBlur, AnimProperty.WaveWarp, AnimProperty.Ripple,
                AnimProperty.WaveLength, AnimProperty.WaveSpeed, AnimProperty.Twirl, AnimProperty.Bulge,
                AnimProperty.DistortRadius, AnimProperty.Turbulence]);
            if (KeyColor != null) list.AddRange([AnimProperty.KeyTolerance, AnimProperty.KeySoftness]);
            list.AddRange([AnimProperty.Shine, AnimProperty.ShinePosition, AnimProperty.ShineAngle, AnimProperty.ShineWidth,
                AnimProperty.Rays, AnimProperty.RaysLength, AnimProperty.Outline, AnimProperty.InnerGlow,
                AnimProperty.InnerGlowRadius]);
            if (Type.IsShape())
            {
                list.AddRange([AnimProperty.OffsetPath, AnimProperty.Zigzag, AnimProperty.WigglePath, AnimProperty.Pucker,
                    AnimProperty.TaperStart, AnimProperty.TaperEnd]);
                if (Dash.Count > 0) list.Add(AnimProperty.DashOffset);
            }
            if (MotionPath != null) list.Add(AnimProperty.PathProgress);
            return list;
        }
    }

    public List<ColorProperty> ApplicableColors => Type switch
    {
        LayerType.Rect or LayerType.Ellipse or LayerType.Path => [ColorProperty.Fill, ColorProperty.Stroke],
        LayerType.Text => [ColorProperty.Color, ColorProperty.Stroke],
        LayerType.Generator => Generator.Kind switch
        {
            Core.GeneratorKind.Noise or Core.GeneratorKind.Flare => [],
            Core.GeneratorKind.Chart => [ColorProperty.Fill, ColorProperty.Color],
            _ => [ColorProperty.Fill],
        },
        _ => [],
    };

    /// <summary>Playable length of an audio layer's file after trimming.</summary>
    public double? AudioLength => SourceDuration is { } d ? Math.Max(0, d - TrimIn) : null;

    /// <summary>Scene seconds the layer can last before its source runs out: audio, and videos that play once.</summary>
    public double? MediaLength => Type switch
    {
        LayerType.Audio => AudioLength,
        LayerType.Video when Playback == VideoPlayback.Once && TimeRemap == null && SourceDuration is { } d =>
            Math.Max(0, d - TrimIn) / Math.Max(Speed, 0.01),
        _ => null,
    };

    // Track access (numbers and colors alike)

    public bool IsAnimated(KeyTrack k) => k.Number is { } p ? this[p].IsAnimated : this[k.Color!.Value].IsAnimated;

    public IEnumerable<double> KeyTimes(KeyTrack k) =>
        k.Number is { } p ? this[p].KeyframeList.Select(x => x.T) : this[k.Color!.Value].KeyframeList.Select(x => x.T);

    public IEnumerable<KeyTrack> AnimatedTracks => KeyTrack.All.Where(IsAnimated);

    public List<double> KeyframeTimes => KeyTrack.All.SelectMany(KeyTimes).Distinct().Order().ToList();

    public bool HasKey(KeyTrack k, double t, double tolerance) =>
        k.Number is { } p ? this[p].HasKey(t, tolerance) : this[k.Color!.Value].HasKey(t, tolerance);

    public void MoveKey(KeyTrack k, double t, double newT, double tolerance)
    {
        if (k.Number is { } p) this[p] = this[p].MovingKey(t, newT, tolerance);
        else this[k.Color!.Value] = this[k.Color.Value].MovingKey(t, newT, tolerance);
    }

    public void SetEasing(KeyTrack k, double t, Easing e, double tolerance)
    {
        if (k.Number is { } p) this[p] = this[p].SettingEasing(t, e, tolerance);
        else this[k.Color!.Value] = this[k.Color.Value].SettingEasing(t, e, tolerance);
    }

    public void DeleteKey(KeyTrack k, double t, double tolerance)
    {
        if (k.Number is { } p) { this[p] = this[p].DeletingKey(t, tolerance); return; }
        var c = k.Color!.Value;
        if (c == ColorProperty.Stroke && Stroke == null) return;
        this[c] = this[c].DeletingKey(t, tolerance);
    }

    /// <summary>Visual layers default to the scene end; audio layers and videos that play once to the end of their file.</summary>
    public double EffectiveEnd(double sceneDuration) =>
        End ?? (MediaLength is { } len ? Start + len : sceneDuration);

    public bool IsVisible(double t, double sceneDuration) => t >= Start && t < EffectiveEnd(sceneDuration) + 1e-9;
}
