using System.Collections.Frozen;

namespace VeyMotion.Core;

/// <summary>JSON names of enums: the Swift raw values, i.e. the member name with a lowercase first letter.</summary>
public static class JsonName<T> where T : struct, Enum
{
    static readonly FrozenDictionary<T, string> ToName =
        Enum.GetValues<T>().ToFrozenDictionary(v => v, v => { var s = v.ToString(); return char.ToLowerInvariant(s[0]) + s[1..]; });
    static readonly FrozenDictionary<string, T> FromName = ToName.ToFrozenDictionary(kv => kv.Value, kv => kv.Key);

    public static string Of(T v) => ToName[v];
    public static T? Parse(string s) => FromName.TryGetValue(s, out var v) ? v : null;
    public static IEnumerable<string> All => ToName.Values;
}

public static class EnumJsonExtensions
{
    public static string Json<T>(this T v) where T : struct, Enum => JsonName<T>.Of(v);
}

public enum LayerType { Rect, Ellipse, Path, Text, Image, Video, Audio, Particles, Generator, Group }

public static class LayerTypeExtensions
{
    /// <summary>Drawn in the frame (audio layers are not).</summary>
    public static bool IsVisual(this LayerType t) => t != LayerType.Audio;
    /// <summary>Images and videos: sized by their file unless width/height are set.</summary>
    public static bool HasNaturalSize(this LayerType t) => t is LayerType.Image or LayerType.Video;
    /// <summary>Filled/stroked vector shapes.</summary>
    public static bool IsShape(this LayerType t) => t is LayerType.Rect or LayerType.Ellipse or LayerType.Path;
    public static string Title(this LayerType t) => t.ToString();
}

/// <summary>What an audio layer is, used for ducking (music dips under voice) and display.</summary>
public enum AudioRole { Voice, Music, Sfx }

public enum TextAlign { Left, Center, Right }

/// <summary>How a layer's pixels combine with what is below it.</summary>
public enum BlendMode { Normal, Add, Screen, Multiply, Overlay, Lighten, Darken }

public enum FillRule { Nonzero, Evenodd }
public enum LineCap { Butt, Round, Square }
public enum LineJoin { Miter, Round, Bevel }

public enum MatteMode { Alpha, AlphaInverted, Luma, LumaInverted }

public enum VideoPlayback { Once, Hold, Loop }
public enum BackgroundRemoval { Person, Subject }
public enum FrameBlend { Off, Blend, Flow }

/// <summary>Shows a layer only through another layer (the matte), which is then not drawn on its own.</summary>
public sealed record Matte(string Source, MatteMode Mode = MatteMode.Alpha);

public readonly record struct PathPoint(double X, double Y);

/// <summary>A spoken word; <c>T</c> is seconds from the start of the file, <c>D</c> how long it is spoken.</summary>
public sealed record WordTiming(double T, string Text, double? D = null);

/// <summary>Animatable numbers of a layer. Port of <c>AnimProperty</c> in <c>Scene.swift</c>.</summary>
public enum AnimProperty
{
    X, Y, Scale, ScaleX, ScaleY, Rotation, SkewX, SkewY, AnchorX, AnchorY, Opacity,
    Width, Height, CornerRadius, StrokeWidth, Trim, TrimStart, TrimOffset,
    Reveal, LetterSpacing,
    Blur, ShadowX, ShadowY, ShadowBlur, ShadowOpacity, Glow, GlowRadius,
    PathProgress,
    Volume,
    Emission, ParticleSpeed, ParticleSize,
    Brightness, Contrast, Saturation, Hue, Tint,
    Wipe,
    KeyTolerance, KeySoftness,
    WaveWarp, Ripple, WaveLength, WaveSpeed, Twirl, Bulge, DistortRadius, Turbulence,
    Posterize, Pixelate, RgbSplit, Glitch, Grain, Scanlines, Vignette,
    DirectionalBlur, BlurAngle, ZoomBlur,
    Counter, Scramble, TextOffset,
    Shine, ShinePosition, ShineAngle, ShineWidth, Rays, RaysLength, Outline, InnerGlow, InnerGlowRadius,
    OffsetPath, Zigzag, WigglePath, Pucker, DashOffset, TaperStart, TaperEnd,
    TimeRemap,
    RotationX, RotationY, Perspective,
    LevelsBlack, LevelsWhite, LevelsGamma, GradientMapAmount, LutAmount,
}

public static class AnimPropertyInfo
{
    /// <summary>Value a layer has when the property is not set.</summary>
    public static double DefaultValue(this AnimProperty p) => p switch
    {
        AnimProperty.Scale or AnimProperty.ScaleX or AnimProperty.ScaleY or AnimProperty.Opacity or AnimProperty.Reveal
            or AnimProperty.Trim or AnimProperty.Volume or AnimProperty.Emission or AnimProperty.ParticleSpeed
            or AnimProperty.ParticleSize => 1,
        AnimProperty.X => 960,
        AnimProperty.Y => 540,
        AnimProperty.Width => 400,
        AnimProperty.Height => 240,
        AnimProperty.ShadowY => 8,
        AnimProperty.ShadowBlur => 16,
        AnimProperty.GlowRadius => 24,
        AnimProperty.KeyTolerance => 0.2,
        AnimProperty.KeySoftness => 0.1,
        AnimProperty.WaveLength => 120,
        AnimProperty.WaveSpeed => 1,
        AnimProperty.DistortRadius => 300,
        AnimProperty.Perspective => 1200,
        AnimProperty.LevelsWhite or AnimProperty.LevelsGamma or AnimProperty.GradientMapAmount or AnimProperty.LutAmount => 1,
        AnimProperty.ShineAngle => 30,
        AnimProperty.ShineWidth => 120,
        AnimProperty.ShinePosition => 0.5,
        AnimProperty.RaysLength => 0.6,
        AnimProperty.InnerGlowRadius => 20,
        _ => 0,
    };

    /// <summary>Properties stored in <see cref="MotionLayer.Extra"/> (written to JSON only when set).</summary>
    public static readonly AnimProperty[] Extras =
    [
        AnimProperty.ScaleX, AnimProperty.ScaleY, AnimProperty.SkewX, AnimProperty.SkewY, AnimProperty.AnchorX,
        AnimProperty.AnchorY, AnimProperty.Trim, AnimProperty.TrimStart, AnimProperty.TrimOffset, AnimProperty.LetterSpacing,
        AnimProperty.Blur, AnimProperty.ShadowX, AnimProperty.ShadowY, AnimProperty.ShadowBlur, AnimProperty.ShadowOpacity,
        AnimProperty.Glow, AnimProperty.GlowRadius, AnimProperty.PathProgress,
        AnimProperty.Emission, AnimProperty.ParticleSpeed, AnimProperty.ParticleSize,
        AnimProperty.Brightness, AnimProperty.Contrast, AnimProperty.Saturation, AnimProperty.Hue, AnimProperty.Tint,
        AnimProperty.Wipe, AnimProperty.KeyTolerance, AnimProperty.KeySoftness, AnimProperty.WaveWarp, AnimProperty.Ripple,
        AnimProperty.WaveLength, AnimProperty.WaveSpeed, AnimProperty.Twirl, AnimProperty.Bulge, AnimProperty.DistortRadius,
        AnimProperty.Turbulence, AnimProperty.Posterize, AnimProperty.Pixelate, AnimProperty.RgbSplit, AnimProperty.Glitch,
        AnimProperty.Grain, AnimProperty.Scanlines, AnimProperty.Vignette, AnimProperty.DirectionalBlur, AnimProperty.BlurAngle,
        AnimProperty.ZoomBlur, AnimProperty.Counter, AnimProperty.Scramble, AnimProperty.TextOffset,
        AnimProperty.Shine, AnimProperty.ShinePosition, AnimProperty.ShineAngle, AnimProperty.ShineWidth, AnimProperty.Rays,
        AnimProperty.RaysLength, AnimProperty.Outline, AnimProperty.InnerGlow, AnimProperty.InnerGlowRadius,
        AnimProperty.OffsetPath, AnimProperty.Zigzag, AnimProperty.WigglePath, AnimProperty.Pucker, AnimProperty.DashOffset,
        AnimProperty.TaperStart, AnimProperty.TaperEnd, AnimProperty.RotationX, AnimProperty.RotationY, AnimProperty.Perspective,
        AnimProperty.LevelsBlack, AnimProperty.LevelsWhite, AnimProperty.LevelsGamma, AnimProperty.GradientMapAmount,
        AnimProperty.LutAmount,
    ];

    public static string Title(this AnimProperty p) => p switch
    {
        AnimProperty.X => "X",
        AnimProperty.Y => "Y",
        AnimProperty.CornerRadius => "Radius",
        AnimProperty.Trim => "Trim End",
        AnimProperty.RgbSplit => "RGB Split",
        AnimProperty.WaveLength => "Wavelength",
        AnimProperty.TextOffset => "Path Offset",
        AnimProperty.Rays => "Light Rays",
        AnimProperty.LevelsGamma => "Gamma",
        AnimProperty.GradientMapAmount => "Gradient Map",
        AnimProperty.LutAmount => "LUT",
        _ => SplitWords(p.ToString()),
    };

    /// <summary>"ShadowOpacity" → "Shadow Opacity", "ScaleX" → "Scale X".</summary>
    static string SplitWords(string s) =>
        string.Concat(s.Select((c, i) => i > 0 && char.IsUpper(c) ? " " + c : c.ToString()));

    /// <summary>Shown with two decimals rather than as whole pixels/degrees.</summary>
    public static bool IsFractional(this AnimProperty p) => p is
        AnimProperty.Scale or AnimProperty.ScaleX or AnimProperty.ScaleY or AnimProperty.Opacity or AnimProperty.Trim
        or AnimProperty.TrimStart or AnimProperty.TrimOffset or AnimProperty.Reveal or AnimProperty.ShadowOpacity
        or AnimProperty.Glow or AnimProperty.PathProgress or AnimProperty.Volume or AnimProperty.Emission
        or AnimProperty.ParticleSpeed or AnimProperty.ParticleSize or AnimProperty.Brightness or AnimProperty.Contrast
        or AnimProperty.Saturation or AnimProperty.Tint or AnimProperty.Wipe or AnimProperty.KeyTolerance
        or AnimProperty.KeySoftness or AnimProperty.WaveSpeed or AnimProperty.Bulge or AnimProperty.Glitch
        or AnimProperty.Grain or AnimProperty.Scanlines or AnimProperty.Vignette or AnimProperty.ZoomBlur
        or AnimProperty.Scramble or AnimProperty.Shine or AnimProperty.ShinePosition or AnimProperty.Rays
        or AnimProperty.RaysLength or AnimProperty.InnerGlow or AnimProperty.Pucker or AnimProperty.TaperStart
        or AnimProperty.TaperEnd or AnimProperty.LevelsBlack or AnimProperty.LevelsWhite or AnimProperty.LevelsGamma
        or AnimProperty.GradientMapAmount or AnimProperty.LutAmount;
}

/// <summary>Animatable colors of a layer.</summary>
public enum ColorProperty { Fill, Stroke, Color }

/// <summary>One keyframe track of a layer: a number or a color.</summary>
public readonly record struct KeyTrack
{
    public AnimProperty? Number { get; }
    public ColorProperty? Color { get; }

    KeyTrack(AnimProperty? n, ColorProperty? c) { Number = n; Color = c; }

    public static KeyTrack Of(AnimProperty p) => new(p, null);
    public static KeyTrack Of(ColorProperty c) => new(null, c);

    public static KeyTrack? FromName(string name) =>
        JsonName<AnimProperty>.Parse(name) is { } p ? Of(p)
        : JsonName<ColorProperty>.Parse(name) is { } c ? Of(c) : null;

    public string Name => Number is { } p ? p.Json() : Color!.Value.Json();
    public string Title => Number is { } p ? p.Title() : Color!.Value.ToString();

    public static IEnumerable<KeyTrack> All =>
        Enum.GetValues<AnimProperty>().Select(Of).Concat(Enum.GetValues<ColorProperty>().Select(Of));
    public static IEnumerable<string> AllNames => All.Select(k => k.Name);
}
