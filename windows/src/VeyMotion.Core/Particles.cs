using System.Numerics;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

// Particle systems. Every frame is computed from scratch: particle k is born at a fixed time with fixed random numbers,
// and its state at age a comes from a closed form (or from stepping its own path from birth when it swirls or
// bounces). Scrubbing, preview and export at any fps therefore show the same particles. Port of Particles.swift.

public enum ParticleShape { Circle, Soft, Square, Spark, Image }

public enum EmitterShape { Point, Line, Rect, Ellipse }

public enum ParticleSpace { World, Local }

public enum ParticleColorMode { Life, Random }

public enum ParticlePreset { Fire, Smoke, Dust, Sparks, Snow, Rain, Confetti, Bokeh, Magic, Explosion }

public readonly record struct ParticleBurst(double T, int Count);

/// <summary>Settings of a particle layer. Angles are degrees, 0 = right, 90 = down. Fields left out of the JSON take
/// the preset's values; only fields that differ from the preset are written.</summary>
public sealed class ParticleSystem
{
    public ParticlePreset? Preset;
    public long Seed;
    public double Rate = 40;
    public List<ParticleBurst> Bursts = [];
    public double Prewarm, Lifetime = 2, LifetimeRandom = 0.3;
    public EmitterShape Emitter = EmitterShape.Point;
    public bool Edge;
    public string? From;
    public ParticleSpace Space = ParticleSpace.World;
    public double Speed = 150, SpeedRandom = 0.3, Direction = -90, Spread = 30, Inherit, Gravity, Wind, Drag;
    public double Turbulence, TurbulenceScale = 200, TurbulenceSpeed = 0.5;
    public double? Floor;
    public double Bounce = 0.4, Friction = 0.2;
    public ParticleShape Shape = ParticleShape.Soft;
    public double Size = 16, SizeRandom = 0.4, Grow = 1, Streak = 0.04, Trail;
    public bool Orient;
    public double AngleRandom = 180, Spin, SpinRandom = 0.5, Flutter;
    public List<Rgba> Colors = [Rgba.White];
    public ParticleColorMode ColorMode = ParticleColorMode.Life;
    public double FadeIn = 0.1, FadeOut = 0.4;
    public bool Tint;

    /// <summary>Emits from another layer or in world space: particles are simulated in scene pixels.</summary>
    public bool UsesWorldSpace => From != null || Space == ParticleSpace.World;

    public static BlendMode DefaultBlendMode(ParticlePreset p) =>
        p is ParticlePreset.Fire or ParticlePreset.Sparks or ParticlePreset.Magic or ParticlePreset.Explosion
            or ParticlePreset.Bokeh or ParticlePreset.Dust ? BlendMode.Add : BlendMode.Normal;

    public static ParticleSystem Base(ParticlePreset? preset)
    {
        var p = new ParticleSystem { Preset = preset };
        static Rgba H(string s) => Rgba.FromHex(s)!.Value;
        switch (preset)
        {
            case ParticlePreset.Fire:
                p.Rate = 240; p.Lifetime = 0.9; p.LifetimeRandom = 0.4; p.Emitter = EmitterShape.Line;
                p.Speed = 140; p.SpeedRandom = 0.5; p.Direction = -90; p.Spread = 20; p.Gravity = -320; p.Drag = 1.2;
                p.Turbulence = 90; p.TurbulenceScale = 70; p.TurbulenceSpeed = 2;
                p.Shape = ParticleShape.Soft; p.Size = 62; p.SizeRandom = 0.35; p.Grow = 0.12;
                p.Colors = [H("#FFE9A050"), H("#FFA83058"), H("#FF541048"), H("#A8180030"), H("#30080000")];
                p.FadeIn = 0.08; p.FadeOut = 0.35;
                break;
            case ParticlePreset.Smoke:
                p.Rate = 16; p.Lifetime = 4.5; p.LifetimeRandom = 0.3; p.Emitter = EmitterShape.Line;
                p.Speed = 70; p.SpeedRandom = 0.4; p.Direction = -90; p.Spread = 25; p.Gravity = -25; p.Drag = 0.4;
                p.Turbulence = 60; p.TurbulenceScale = 220; p.TurbulenceSpeed = 0.35;
                p.Shape = ParticleShape.Soft; p.Size = 60; p.SizeRandom = 0.4; p.Grow = 3.5;
                p.Colors = [H("#9A9AA248"), H("#7A7A8430"), H("#5A5A6000")];
                p.FadeIn = 0.15; p.FadeOut = 0.6;
                break;
            case ParticlePreset.Dust:
                p.Rate = 30; p.Prewarm = 6; p.Lifetime = 6; p.LifetimeRandom = 0.4; p.Emitter = EmitterShape.Rect;
                p.Speed = 8; p.SpeedRandom = 1; p.Spread = 360;
                p.Turbulence = 18; p.TurbulenceScale = 320; p.TurbulenceSpeed = 0.25;
                p.Shape = ParticleShape.Soft; p.Size = 6; p.SizeRandom = 0.7;
                p.Colors = [H("#FFE8C2B0")];
                p.FadeIn = 0.3; p.FadeOut = 0.3;
                break;
            case ParticlePreset.Sparks:
                p.Rate = 70; p.Lifetime = 0.9; p.LifetimeRandom = 0.5;
                p.Speed = 650; p.SpeedRandom = 0.45; p.Direction = -90; p.Spread = 70; p.Gravity = 1100; p.Drag = 0.8;
                p.Shape = ParticleShape.Spark; p.Size = 3; p.SizeRandom = 0.4; p.Grow = 0.4; p.Streak = 0.035;
                p.Colors = [H("#FFFFF0"), H("#FFD060"), H("#FF7A20"), H("#C0300000")];
                p.FadeIn = 0; p.FadeOut = 0.3;
                break;
            case ParticlePreset.Snow:
                p.Rate = 45; p.Prewarm = 9; p.Lifetime = 9; p.LifetimeRandom = 0.2; p.Emitter = EmitterShape.Line;
                p.Speed = 90; p.SpeedRandom = 0.4; p.Direction = 90; p.Spread = 20;
                p.Turbulence = 30; p.TurbulenceScale = 280; p.TurbulenceSpeed = 0.3;
                p.Shape = ParticleShape.Soft; p.Size = 10; p.SizeRandom = 0.6;
                p.Colors = [H("#FFFFFFE0")];
                p.FadeIn = 0.05; p.FadeOut = 0.1;
                break;
            case ParticlePreset.Rain:
                p.Rate = 420; p.Prewarm = 1.2; p.Lifetime = 1.2; p.LifetimeRandom = 0.1; p.Emitter = EmitterShape.Line;
                p.Speed = 1500; p.SpeedRandom = 0.15; p.Direction = 100; p.Spread = 2;
                p.Shape = ParticleShape.Spark; p.Size = 2; p.SizeRandom = 0.3; p.Streak = 0.03;
                p.Colors = [H("#B8CCFF90")];
                p.FadeIn = 0; p.FadeOut = 0.05;
                break;
            case ParticlePreset.Confetti:
                p.Rate = 70; p.Prewarm = 0; p.Lifetime = 5; p.LifetimeRandom = 0.2; p.Emitter = EmitterShape.Line;
                p.Speed = 120; p.SpeedRandom = 0.5; p.Direction = 90; p.Spread = 50; p.Gravity = 260; p.Drag = 1.4;
                p.Turbulence = 50; p.TurbulenceScale = 220; p.TurbulenceSpeed = 0.6;
                p.Shape = ParticleShape.Square; p.Size = 16; p.SizeRandom = 0.35;
                p.Spin = 360; p.SpinRandom = 0.6; p.Flutter = 2.5;
                p.Colors = [H("#FF4D6D"), H("#FFC93C"), H("#3CCF91"), H("#4D96FF"), H("#B15CFF")];
                p.ColorMode = ParticleColorMode.Random;
                p.FadeIn = 0; p.FadeOut = 0.15;
                break;
            case ParticlePreset.Bokeh:
                p.Rate = 4; p.Prewarm = 8; p.Lifetime = 8; p.LifetimeRandom = 0.3; p.Emitter = EmitterShape.Rect;
                p.Speed = 15; p.SpeedRandom = 1; p.Spread = 360;
                p.Turbulence = 10; p.TurbulenceScale = 500; p.TurbulenceSpeed = 0.15;
                p.Shape = ParticleShape.Soft; p.Size = 120; p.SizeRandom = 0.6;
                p.Colors = [H("#FFB86B50"), H("#FF6BB550"), H("#6BC8FF50")];
                p.ColorMode = ParticleColorMode.Random;
                p.FadeIn = 0.3; p.FadeOut = 0.4;
                break;
            case ParticlePreset.Magic:
                p.Rate = 120; p.Lifetime = 1.4; p.LifetimeRandom = 0.5;
                p.Speed = 40; p.SpeedRandom = 1; p.Spread = 360; p.Inherit = 0.15; p.Gravity = 40; p.Drag = 1.5;
                p.Turbulence = 30; p.TurbulenceScale = 120; p.TurbulenceSpeed = 1;
                p.Shape = ParticleShape.Soft; p.Size = 10; p.SizeRandom = 0.6; p.Grow = 0;
                p.Colors = [H("#FFFFFF"), H("#9FE8FF"), H("#B98BFF00")];
                p.FadeIn = 0; p.FadeOut = 0.5;
                break;
            case ParticlePreset.Explosion:
                p.Rate = 0; p.Bursts = [new ParticleBurst(0, 260)];
                p.Lifetime = 1.4; p.LifetimeRandom = 0.5;
                p.Speed = 900; p.SpeedRandom = 0.7; p.Spread = 360; p.Gravity = 500; p.Drag = 2.2;
                p.Shape = ParticleShape.Spark; p.Size = 4; p.SizeRandom = 0.5; p.Grow = 0.3; p.Streak = 0.05;
                p.Colors = [H("#FFFFFF"), H("#FFD27A"), H("#FF7B2A"), H("#7A1A0000")];
                p.FadeIn = 0; p.FadeOut = 0.4;
                break;
        }
        return p;
    }

    internal static ParticleSystem Decode(JsonNode? n, string path)
    {
        var r = Reader.Of(n, path);
        ParticlePreset? preset = null;
        if (r.Str("preset") is { } name)
            preset = JsonName<ParticlePreset>.Parse(name)
                ?? throw Reader.Fail(path + ".preset", $"Unknown preset '{name}'. Use one of [{string.Join(", ", JsonName<ParticlePreset>.All)}].");
        var b = Base(preset);
        double Unit(string k, double fallback) => Math.Clamp(r.Num(k) ?? fallback, 0, 1);
        var p = new ParticleSystem
        {
            Preset = preset,
            Seed = (long)(r.Num("seed") ?? b.Seed),
            Rate = Math.Max(0, r.Num("rate") ?? b.Rate),
            Bursts = r.List("bursts", (bn, bp) =>
            {
                var br = Reader.Of(bn, bp);
                return new ParticleBurst(br.Num("t") ?? throw Reader.Fail(bp + ".t", "missing required field"), Math.Max(0, br.Int("count") ?? 100));
            }) ?? b.Bursts,
            Prewarm = Math.Max(0, r.Num("prewarm") ?? b.Prewarm),
            Lifetime = Math.Max(0.01, r.Num("lifetime") ?? b.Lifetime),
            LifetimeRandom = Unit("lifetimeRandom", b.LifetimeRandom),
            Emitter = r.Enum<EmitterShape>("emitter") ?? b.Emitter,
            Edge = r.Bool("edge") ?? b.Edge,
            From = r.Str("from") is { Length: > 0 } from ? from : b.From,
            Space = r.Enum<ParticleSpace>("space") ?? b.Space,
            Speed = r.Num("speed") ?? b.Speed,
            SpeedRandom = Unit("speedRandom", b.SpeedRandom),
            Direction = r.Num("direction") ?? b.Direction,
            Spread = Math.Clamp(r.Num("spread") ?? b.Spread, 0, 360),
            Inherit = r.Num("inherit") ?? b.Inherit,
            Gravity = r.Num("gravity") ?? b.Gravity,
            Wind = r.Num("wind") ?? b.Wind,
            Drag = Math.Max(0, r.Num("drag") ?? b.Drag),
            Turbulence = Math.Max(0, r.Num("turbulence") ?? b.Turbulence),
            TurbulenceScale = Math.Max(1, r.Num("turbulenceScale") ?? b.TurbulenceScale),
            TurbulenceSpeed = Math.Max(0, r.Num("turbulenceSpeed") ?? b.TurbulenceSpeed),
            Floor = r.Num("floor") ?? b.Floor,
            Bounce = Unit("bounce", b.Bounce),
            Friction = Unit("friction", b.Friction),
            Shape = r.Enum<ParticleShape>("shape") ?? b.Shape,
            Size = Math.Max(0, r.Num("size") ?? b.Size),
            SizeRandom = Unit("sizeRandom", b.SizeRandom),
            Grow = Math.Max(0, r.Num("grow") ?? b.Grow),
            Streak = Math.Max(0, r.Num("streak") ?? b.Streak),
            Trail = Math.Min(Math.Max(0, r.Num("trail") ?? b.Trail), 3),
            Orient = r.Bool("orient") ?? b.Orient,
            AngleRandom = r.Num("angleRandom") ?? b.AngleRandom,
            Spin = r.Num("spin") ?? b.Spin,
            SpinRandom = Unit("spinRandom", b.SpinRandom),
            Flutter = Math.Max(0, r.Num("flutter") ?? b.Flutter),
            Colors = r.List("colors", Reader.ReadColor) ?? b.Colors,
            ColorMode = r.Enum<ParticleColorMode>("colorMode") ?? b.ColorMode,
            FadeIn = Unit("fadeIn", b.FadeIn),
            FadeOut = Unit("fadeOut", b.FadeOut),
            Tint = r.Bool("tint") ?? b.Tint,
        };
        if (p.Colors.Count == 0) p.Colors = [Rgba.White];
        return p;
    }

    internal JsonObject Encode()
    {
        var b = Base(Preset);
        var o = new JsonObject();
        void E<T>(string k, T v, T bv) where T : IEquatable<T>
        {
            if (!v.Equals(bv)) o[k] = JsonValue.Create(v);
        }
        void En<T>(string k, T v, T bv) where T : struct, Enum
        {
            if (!v.Equals(bv)) o[k] = v.Json();
        }
        if (Preset is { } preset) o["preset"] = preset.Json();
        E("seed", Seed, b.Seed);
        E("rate", Rate, b.Rate);
        if (!Bursts.SequenceEqual(b.Bursts))
            o["bursts"] = new JsonArray(Bursts.Select(x => (JsonNode)new JsonObject { ["t"] = x.T, ["count"] = x.Count }).ToArray());
        E("prewarm", Prewarm, b.Prewarm);
        E("lifetime", Lifetime, b.Lifetime);
        E("lifetimeRandom", LifetimeRandom, b.LifetimeRandom);
        En("emitter", Emitter, b.Emitter);
        E("edge", Edge, b.Edge);
        if (From != null) o["from"] = From;
        En("space", Space, b.Space);
        E("speed", Speed, b.Speed);
        E("speedRandom", SpeedRandom, b.SpeedRandom);
        E("direction", Direction, b.Direction);
        E("spread", Spread, b.Spread);
        E("inherit", Inherit, b.Inherit);
        E("gravity", Gravity, b.Gravity);
        E("wind", Wind, b.Wind);
        E("drag", Drag, b.Drag);
        E("turbulence", Turbulence, b.Turbulence);
        E("turbulenceScale", TurbulenceScale, b.TurbulenceScale);
        E("turbulenceSpeed", TurbulenceSpeed, b.TurbulenceSpeed);
        if (Floor is { } f) o["floor"] = f;
        E("bounce", Bounce, b.Bounce);
        E("friction", Friction, b.Friction);
        En("shape", Shape, b.Shape);
        E("size", Size, b.Size);
        E("sizeRandom", SizeRandom, b.SizeRandom);
        E("grow", Grow, b.Grow);
        E("streak", Streak, b.Streak);
        E("trail", Trail, b.Trail);
        E("orient", Orient, b.Orient);
        E("angleRandom", AngleRandom, b.AngleRandom);
        E("spin", Spin, b.Spin);
        E("spinRandom", SpinRandom, b.SpinRandom);
        E("flutter", Flutter, b.Flutter);
        if (!Colors.SequenceEqual(b.Colors)) o["colors"] = new JsonArray(Colors.Select(c => (JsonNode)c.Hex).ToArray());
        En("colorMode", ColorMode, b.ColorMode);
        E("fadeIn", FadeIn, b.FadeIn);
        E("fadeOut", FadeOut, b.FadeOut);
        E("tint", Tint, b.Tint);
        return o;
    }
}

/// <summary>One particle as drawn at a moment. Position/velocity are in scene pixels (world space) or layer pixels.</summary>
public struct Particle
{
    public double X, Y, Vx, Vy;
    /// <summary>Diameter, px.</summary>
    public double Size;
    /// <summary>Degrees.</summary>
    public double Rotation;
    /// <summary>Vertical squash, -1…1 (confetti flutter).</summary>
    public double ScaleY;
    /// <summary>Color with the particle's fades in A.</summary>
    public Rgba Color;
    /// <summary>Earlier positions, newest first (when the system has a trail).</summary>
    public List<Vector2>? Trail;
}

/// <summary>Picks an emission point on a layer (layer-local px, y down), from two random numbers in [0, 1). Null = the
/// layer has no shape to emit from here (Core samples rects and ellipses itself).</summary>
public delegate PathPoint? EmitSampler(MotionLayer source, double t, double r1, double r2, bool edge);

public static class ParticleSim
{
    public const int MaxParticles = 20_000;
    /// <summary>Emission ticks per second: births are spread inside ticks, so this only bounds the timing grid.</summary>
    const double EmitTick = 1.0 / 240;
    /// <summary>Step used when particles swirl or bounce.</summary>
    const double SimStep = 1.0 / 48;

    /// <summary>A particle layer with the preset's emitter placed and sized for a scene of the given size.</summary>
    public static MotionLayer MakeParticles(ParticlePreset preset, int sceneWidth, int sceneHeight)
    {
        double w = sceneWidth, h = sceneHeight;
        var name = preset.Json();
        var l = new MotionLayer(LayerType.Particles, name) { Name = char.ToUpperInvariant(name[0]) + name[1..] };
        l.X = w / 2; l.Y = h / 2;
        l.Particles = ParticleSystem.Base(preset);
        l.BlendMode = ParticleSystem.DefaultBlendMode(preset);
        (double W, double H) size = (400, 240);
        switch (preset)
        {
            case ParticlePreset.Fire: l.Y = h * 0.85; size = (w * 0.12, 0); l[AnimProperty.Blur] = 3.0; break;
            case ParticlePreset.Smoke: l.Y = h * 0.75; size = (w * 0.1, 0); l[AnimProperty.Blur] = 2.0; break;
            case ParticlePreset.Sparks: l.Y = h * 0.75; break;
            case ParticlePreset.Snow or ParticlePreset.Confetti: l.Y = -40.0; size = (w * 1.2, 0); break;
            case ParticlePreset.Rain: l.X = w * 0.45; l.Y = -60.0; size = (w * 1.4, 0); break;
            case ParticlePreset.Dust or ParticlePreset.Bokeh: size = (w, h); break;
        }
        l[AnimProperty.Width] = PixelBuffer.Round(size.W);
        l[AnimProperty.Height] = PixelBuffer.Round(size.H);
        return l;
    }

    /// <summary>Live particles of a particle layer at time t, oldest first.</summary>
    public static List<Particle> Particles(this MotionScene scene, MotionLayer layer, double t, EmitSampler? sampler = null)
    {
        var output = new List<Particle>();
        if (layer.Type != LayerType.Particles || t < layer.Start) return output;
        var sys = layer.Particles;
        var salt = Noise.Mix(Noise.Hash($"particles.{layer.Id}") ^ unchecked((ulong)sys.Seed));
        var maxLife = sys.Lifetime * (1 + sys.LifetimeRandom);
        var first = Math.Max(layer.Start - sys.Prewarm, t - maxLife);
        var births = new List<(double T, ulong Key)>();

        const double dt = EmitTick;
        if (sys.Rate > 0)
        {
            long j0 = (long)Math.Floor(first / dt), j1 = (long)Math.Floor(t / dt);
            for (var j = j0; j <= j1; j++)
            {
                var tick = j * dt;
                var expected = sys.Rate * Math.Max(0, layer.Value(AnimProperty.Emission, tick)) * dt;
                if (expected <= 0) continue;
                var tickKey = Noise.Mix(salt ^ unchecked((ulong)j));
                var count = (int)expected + (Noise.Unit(0, tickKey) < expected - Math.Floor(expected) ? 1 : 0);
                for (var s = 0; s < count; s++)
                {
                    var key = Noise.Mix(unchecked(tickKey + (ulong)(s + 1)));
                    var tb = (j + Noise.Unit(1, key)) * dt;
                    if (tb >= first && tb <= t) births.Add((tb, key));
                }
                if (births.Count >= MaxParticles) break;
            }
        }
        for (var bi = 0; bi < sys.Bursts.Count; bi++)
        {
            var burst = sys.Bursts[bi];
            if (burst.T < first || burst.T > t) continue;
            var bkey = Noise.Mix(salt ^ 0xB0B57000UL ^ ((ulong)bi << 24));
            for (var i = 0; i < Math.Min(burst.Count, MaxParticles); i++) births.Add((burst.T, Noise.Mix(unchecked(bkey + (ulong)i))));
        }
        if (sys.Bursts.Count > 0) births = births.OrderBy(b => b.T).ToList(); // stable, like Swift's sort of equal times
        if (births.Count > MaxParticles) births.RemoveRange(0, births.Count - MaxParticles);

        var source = sys.From is { } fromId ? scene.Layers.FirstOrDefault(l => l.Id == fromId && l.Id != layer.Id) : null;
        // Trails cost a re-evaluation per point: fewer points when there are many particles.
        var trailPoints = sys.Trail > 0 ? Math.Max(3, Math.Min(12, 30_000 / Math.Max(births.Count, 1))) : 0;
        foreach (var (tb, key) in births)
        {
            if (scene.ParticleAt(layer, sys, tb, key, t, source, sampler) is not { } p) continue;
            if (trailPoints > 0)
            {
                p.Trail = [];
                for (var k = 1; k <= trailPoints; k++)
                {
                    var tk = t - sys.Trail * k / trailPoints;
                    if (tk < tb || scene.ParticleAt(layer, sys, tb, key, tk, source, sampler) is not { } q) break;
                    p.Trail.Add(new Vector2((float)q.X, (float)q.Y));
                }
            }
            output.Add(p);
        }
        return output;
    }

    static Particle? ParticleAt(this MotionScene scene, MotionLayer layer, ParticleSystem sys, double tb, ulong key, double t,
        MotionLayer? source, EmitSampler? sampler)
    {
        double R(int i) => Noise.Unit(i, key);
        double SpreadOf(double amount, int i) => 1 + amount * (2 * R(i) - 1);
        var life = sys.Lifetime * SpreadOf(sys.LifetimeRandom, 0);
        var age = t - tb;
        if (age < 0 || age >= life) return null;

        // Where it is born, how fast it leaves and how big it is.
        Vector2 origin;
        var angle = sys.Direction + sys.Spread * (R(3) - 0.5);
        var scale = 1.0;
        var emitterVelocity = Vector2.Zero;
        if (source != null)
        {
            var local = sampler?.Invoke(source, tb, R(1), R(2), sys.Edge) ?? ShapePoint(source, tb, R(1), R(2), sys.Edge);
            origin = Vector2.Transform(new Vector2((float)local.X, (float)local.Y), scene.SceneTransform(source, tb));
            if (sys.Inherit != 0) emitterVelocity = Velocity(scene, source, tb);
        }
        else
        {
            var e = EmitterPoint(layer, sys, tb, R(1), R(2));
            origin = new Vector2((float)e.X, (float)e.Y);
            if (sys.Space == ParticleSpace.World)
            {
                var m = scene.SceneTransform(layer, tb);
                origin = Vector2.Transform(origin, m);
                angle += Math.Atan2(m.M12, m.M11) * 180 / Math.PI;
                scale = Math.Sqrt(Math.Abs(m.GetDeterminant()));
                if (sys.Inherit != 0) emitterVelocity = Velocity(scene, layer, tb);
            }
        }
        var rad = angle * Math.PI / 180;
        var speed = sys.Speed * SpreadOf(sys.SpeedRandom, 4) * layer.Value(AnimProperty.ParticleSpeed, tb) * scale;
        double x = origin.X, y = origin.Y;
        var vx = Math.Cos(rad) * speed + sys.Inherit * emitterVelocity.X;
        var vy = Math.Sin(rad) * speed + sys.Inherit * emitterVelocity.Y;
        var size0 = sys.Size * SpreadOf(sys.SizeRandom, 5) * Math.Max(0, layer.Value(AnimProperty.ParticleSize, tb)) * scale;

        // Where it is now.
        double k = sys.Drag, ax = sys.Wind, ay = sys.Gravity;
        if (sys.Turbulence <= 0 && sys.Floor == null)
        {
            if (k < 1e-6)
            {
                x += vx * age + 0.5 * ax * age * age;
                y += vy * age + 0.5 * ay * age * age;
                vx += ax * age;
                vy += ay * age;
            }
            else
            {
                var e = Math.Exp(-k * age);
                x += ax / k * age + (vx - ax / k) * (1 - e) / k;
                y += ay / k * age + (vy - ay / k) * (1 - e) / k;
                vx = ax / k + (vx - ax / k) * e;
                vy = ay / k + (vy - ay / k) * e;
            }
        }
        else
        {
            var field = Noise.Mix(Noise.Hash("turbulence") ^ unchecked((ulong)sys.Seed));
            var inv = 1 / sys.TurbulenceScale;
            double ux = 0, uy = 0, s = 0;
            while (s < age - 1e-9)
            {
                var h = Math.Min(SimStep, age - s);
                if (sys.Turbulence > 0)
                {
                    var c = Noise.Curl(x * inv, y * inv, (tb + s) * sys.TurbulenceSpeed, field);
                    ux = c.X * sys.Turbulence; uy = c.Y * sys.Turbulence;
                }
                vx += (ax - k * vx) * h;
                vy += (ay - k * vy) * h;
                x += (vx + ux) * h;
                y += (vy + uy) * h;
                if (sys.Floor is { } floorY && y > floorY && vy > 0)
                {
                    y = floorY - (y - floorY) * sys.Bounce;
                    vy = -vy * sys.Bounce;
                    vx *= 1 - sys.Friction;
                }
                s += h;
            }
            vx += ux; vy += uy;
        }

        // How it looks now.
        var u = age / life;
        var growth = sys.Grow >= 1 ? 1 - (1 - u) * (1 - u) : u * u;
        var size = size0 * (1 + (sys.Grow - 1) * growth);
        var color = sys.ColorMode == ParticleColorMode.Random
            ? sys.Colors[Math.Min((int)(R(6) * sys.Colors.Count), sys.Colors.Count - 1)]
            : GradientAt(sys.Colors, u);
        static double Smooth(double v) { var c = Math.Clamp(v, 0, 1); return c * c * (3 - 2 * c); }
        var alpha = color.A;
        if (sys.FadeIn > 0) alpha *= Smooth(u / sys.FadeIn);
        if (sys.FadeOut > 0) alpha *= Smooth((1 - u) / sys.FadeOut);
        if (alpha <= 0.002 || size <= 0.05) return null;
        double spinSign = R(8) < 0.5 ? -1 : 1;
        var rotation = sys.AngleRandom * (2 * R(7) - 1) + spinSign * sys.Spin * SpreadOf(sys.SpinRandom, 9) * age;
        if (sys.Orient) rotation = Math.Atan2(vy, vx) * 180 / Math.PI;
        var scaleY = sys.Flutter > 0 ? Math.Cos(2 * Math.PI * (sys.Flutter * SpreadOf(0.4, 10) * age + R(11))) : 1;
        return new Particle { X = x, Y = y, Vx = vx, Vy = vy, Size = size, Rotation = rotation, ScaleY = scaleY, Color = color with { A = alpha } };
    }

    /// <summary>Scene-space velocity of a layer's center, px/s.</summary>
    static Vector2 Velocity(MotionScene scene, MotionLayer layer, double t)
    {
        const double h = 1.0 / 120;
        var a = Vector2.Transform(Vector2.Zero, scene.SceneTransform(layer, t - h));
        var b = Vector2.Transform(Vector2.Zero, scene.SceneTransform(layer, t + h));
        return (b - a) / (float)(2 * h);
    }

    /// <summary>Color at fraction u of a gradient with evenly spaced stops.</summary>
    public static Rgba GradientAt(List<Rgba> colors, double u)
    {
        if (colors.Count <= 1) return colors.Count == 1 ? colors[0] : Rgba.White;
        var p = Math.Clamp(u, 0, 1) * (colors.Count - 1);
        var i = Math.Min((int)p, colors.Count - 2);
        return Rgba.Lerp(colors[i], colors[i + 1], p - i);
    }

    /// <summary>Birth point inside the layer's own emitter (layer-local px).</summary>
    static PathPoint EmitterPoint(MotionLayer layer, ParticleSystem sys, double t, double r1, double r2)
    {
        double w = Math.Max(0, layer.Value(AnimProperty.Width, t)), h = Math.Max(0, layer.Value(AnimProperty.Height, t));
        return sys.Emitter switch
        {
            EmitterShape.Point => new PathPoint(0, 0),
            EmitterShape.Line => new PathPoint((r1 - 0.5) * w, 0),
            EmitterShape.Rect => RectPoint(w, h, r1, r2, sys.Edge),
            _ => EllipsePoint(w, h, r1, r2, sys.Edge),
        };
    }

    /// <summary>Birth point on a rect or ellipse layer used as a from source (other layers: their center).</summary>
    public static PathPoint ShapePoint(MotionLayer layer, double t, double r1, double r2, bool edge)
    {
        double w = Math.Max(0, layer.Value(AnimProperty.Width, t)), h = Math.Max(0, layer.Value(AnimProperty.Height, t));
        return layer.Type switch
        {
            LayerType.Rect or LayerType.Particles => RectPoint(w, h, r1, r2, edge),
            LayerType.Ellipse => EllipsePoint(w, h, r1, r2, edge),
            _ => new PathPoint(0, 0),
        };
    }

    public static PathPoint RectPoint(double w, double h, double r1, double r2, bool edge)
    {
        if (!edge || w + h <= 0) return new PathPoint((r1 - 0.5) * w, (r2 - 0.5) * h);
        var d = r1 * 2 * (w + h);
        if (d < w) return new PathPoint(d - w / 2, -h / 2);
        d -= w;
        if (d < h) return new PathPoint(w / 2, d - h / 2);
        d -= h;
        if (d < w) return new PathPoint(w / 2 - d, h / 2);
        d -= w;
        return new PathPoint(-w / 2, h / 2 - d);
    }

    static PathPoint EllipsePoint(double w, double h, double r1, double r2, bool edge)
    {
        var a = 2 * Math.PI * r1;
        var rr = edge ? 1 : Math.Sqrt(r2);
        return new PathPoint(Math.Cos(a) * w / 2 * rr, Math.Sin(a) * h / 2 * rr);
    }
}
