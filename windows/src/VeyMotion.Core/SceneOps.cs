using System.Text.Json.Nodes;

namespace VeyMotion.Core;

using AnimValue = Animated<double>;
using ColorValue = Animated<Rgba>;
using MotionKeyframe = Keyframe<double>;

/// <summary>Animation presets. Port of <c>Preset</c> in <c>SceneOps.swift</c>.</summary>
public enum Preset
{
    // Entrances
    FadeIn, SlideUp, SlideDown, SlideInLeft, SlideInRight, PopIn, ZoomIn, BlurIn, BounceIn, DropIn, FlipIn, RotateIn, WipeIn,
    // Exits
    FadeOut, SlideOutUp, SlideOutDown, SlideOutLeft, SlideOutRight, PopOut, ZoomOut, BlurOut, FlipOut, WipeOut,
    // Emphasis
    Spin, Pulse, Heartbeat, Shake, Wobble, Jello, GlitchBurst,
    // Shapes
    DrawOn, WriteOn,
    // Text
    Typewriter, TextRise, TextPop, TextDrop, TextLines, TextOut, Decode, TextBlurIn, TextFocus,
}

public enum PresetGroup { Entrance, Exit, Emphasis, Shape, Text }

public static class PresetInfo
{
    public static PresetGroup Group(this Preset p) => p switch
    {
        <= Preset.WipeIn => PresetGroup.Entrance,
        <= Preset.WipeOut => PresetGroup.Exit,
        <= Preset.GlitchBurst => PresetGroup.Emphasis,
        <= Preset.WriteOn => PresetGroup.Shape,
        _ => PresetGroup.Text,
    };

    /// <summary>Whether the preset can be applied to a layer of this type.</summary>
    public static bool AppliesTo(this Preset p, LayerType type) => p.Group() switch
    {
        PresetGroup.Text => type == LayerType.Text,
        PresetGroup.Shape => type.IsShape(),
        _ => type.IsVisual(),
    };

}

/// <summary>
/// All scene mutations live here so the UI and the MCP server share exactly the same behavior.
/// Port of the <c>MotionScene</c> extension in <c>SceneOps.swift</c>.
/// </summary>
public static class SceneOps
{
    public static int LayerIndex(this MotionScene s, string id)
    {
        var i = s.Layers.FindIndex(l => l.Id == id);
        return i >= 0 ? i : throw SceneException.LayerNotFound(id);
    }

    /// <summary>A layer anywhere in the tree (groups' children included).</summary>
    public static MotionLayer Layer(this MotionScene s, string id) => s.FindLayer(id) ?? throw SceneException.LayerNotFound(id);

    public static string UniqueId(this MotionScene s, string baseId)
    {
        var cleaned = baseId.Trim(' ', '\t');
        var b = cleaned.Length == 0 ? "layer" : cleaned;
        var ids = s.AllLayers.Select(l => l.Id).ToHashSet();
        if (!ids.Contains(b)) return b;
        var n = 2;
        while (ids.Contains($"{b}-{n}")) n++;
        return $"{b}-{n}";
    }

    /// <summary>Adds a layer on top (or at <paramref name="index"/>), returning its final id.</summary>
    public static string AddLayer(this MotionScene s, MotionLayer layer, int? index = null)
    {
        layer.Id = s.UniqueId(layer.Id.Length == 0 ? layer.Type.Json() : layer.Id);
        if (layer.Name.Length == 0) layer.Name = layer.Id;
        if (layer.Type == LayerType.Group)
        {
            // Children's ids must be unique scene-wide too.
            var seen = s.AllLayers.Select(l => l.Id).ToHashSet();
            seen.Add(layer.Id);
            MotionScene.NormalizeIds(layer.Children, seen);
        }
        var i = Math.Clamp(index ?? s.Layers.Count, 0, s.Layers.Count);
        s.Layers.Insert(i, layer);
        return layer.Id;
    }

    /// <summary>Removes a top-level layer; its children move to its parent and keep where they are.</summary>
    public static void RemoveLayer(this MotionScene s, string id)
    {
        var removed = s.Layers[s.LayerIndex(id)];
        foreach (var child in s.Layers.Where(l => l.Parent == id).Select(l => l.Id).ToList())
            s.SetParent(child, removed.Parent, removed.Start);
        s.Layers.RemoveAt(s.LayerIndex(id));
        foreach (var l in s.Layers.Where(l => l.Matte?.Source == id)) l.Matte = null;
    }

    /// <summary>Links a layer to a parent (null = unlink). With keepPosition, the layer's position is converted so it
    /// stays where it is at time t.</summary>
    public static void SetParent(this MotionScene s, string id, string? parent, double t, bool keepPosition = true)
    {
        var i = s.LayerIndex(id);
        parent = string.IsNullOrEmpty(parent) ? null : parent;
        if (parent != null)
        {
            s.LayerIndex(parent);
            if (parent == id || s.IsAncestor(id, parent))
                throw new SceneException($"'{parent}' cannot be the parent of '{id}' (that would make a loop)");
        }
        if (keepPosition)
        {
            var l = s.Layers[i];
            var pos = l.Position(t).Point;
            var world = System.Numerics.Vector2.Transform(pos, s.ParentTransform(l, t));
            var oldParent = l.Parent;
            l.Parent = parent;
            System.Numerics.Matrix3x2.Invert(s.ParentTransform(l, t), out var inverse);
            l.Parent = oldParent;
            var local = System.Numerics.Vector2.Transform(world, inverse);
            double dx = local.X - pos.X, dy = local.Y - pos.Y;
            if (l.MotionPath is { } mp)
                l.MotionPath = mp with { Points = mp.Points.Select(p => new PathPoint(p.X + dx, p.Y + dy)).ToList() };
            else
            {
                l.X = l.X.Offsetting(dx);
                l.Y = l.Y.Offsetting(dy);
            }
        }
        s.Layers[i].Parent = parent;
    }

    /// <summary>Every value (constant or keyframes) moved by d.</summary>
    public static AnimValue Offsetting(this AnimValue v, double d) => v.IsAnimated
        ? AnimValue.Keyframes(v.KeyframeList.Select(k => k with { V = k.V + d }))
        : AnimValue.Constant(v.ConstantValue + d);

    /// <summary>Moves top-level layers (in their draw order) into a new group placed where the topmost of them was.
    /// The group is centered on the scene, so children keep scene coordinates.</summary>
    public static string GroupLayers(this MotionScene s, IReadOnlyCollection<string> ids, string? id = null, string? name = null)
    {
        var wanted = ids.ToHashSet();
        if (wanted.Count == 0) throw new SceneException("Give the ids of the layers to group");
        foreach (var x in ids) s.LayerIndex(x);
        var members = s.Layers.Where(l => wanted.Contains(l.Id)).ToList();
        var top = s.Layers.FindLastIndex(l => wanted.Contains(l.Id));
        var group = new MotionLayer(LayerType.Group, id ?? "group", name ?? "Group", s.Width / 2.0, s.Height / 2.0)
        {
            Children = members,
            Start = members.Min(m => m.Start),
        };
        var ends = members.Select(m => m.EffectiveEnd(s.Duration)).ToList();
        group.End = ends.All(e => e >= s.Duration) ? null : ends.Max();
        // A member that followed a layer outside the group loses that parent (it would be out of reach).
        foreach (var c in group.Children.Where(c => c.Parent != null && !wanted.Contains(c.Parent))) c.Parent = null;
        group.Id = s.UniqueId(group.Id);
        var kept = s.Layers.Where(l => !wanted.Contains(l.Id)).ToList();
        kept.Insert(Math.Clamp(top - members.Count + 1, 0, kept.Count), group);
        foreach (var l in kept.Where(l => l.Parent != null && wanted.Contains(l.Parent))) l.Parent = null;
        s.Layers = kept;
        return group.Id;
    }

    /// <summary>Puts a group's children back at the group's place (dropping the group's own transform and effects).</summary>
    public static void Ungroup(this MotionScene s, string id)
    {
        var i = s.LayerIndex(id);
        if (s.Layers[i].Type != LayerType.Group) throw new SceneException($"'{id}' is not a group");
        var children = s.Layers[i].Children;
        s.Layers.RemoveAt(i);
        foreach (var c in children)
        {
            c.Id = s.UniqueId(c.Id);
            s.Layers.Insert(i++, c);
        }
    }

    public static string DuplicateLayer(this MotionScene s, string id)
    {
        var i = s.LayerIndex(id);
        var copy = s.Layers[i].Clone();
        copy.Id = s.UniqueId(copy.Id);
        copy.Name += " copy";
        if (copy.Type == LayerType.Group)
        {
            var seen = s.AllLayers.Select(l => l.Id).ToHashSet();
            seen.Add(copy.Id);
            MotionScene.NormalizeIds(copy.Children, seen);
        }
        s.Layers.Insert(i + 1, copy);
        return copy.Id;
    }

    /// <summary>Moves a layer to a draw-order index (0 = bottom).</summary>
    public static void MoveLayer(this MotionScene s, string id, int index)
    {
        var i = s.LayerIndex(id);
        var l = s.Layers[i];
        s.Layers.RemoveAt(i);
        s.Layers.Insert(Math.Clamp(index, 0, s.Layers.Count), l);
    }

    public static void SetKeyframes(this MotionScene s, string id, AnimProperty property, IEnumerable<MotionKeyframe> keyframes) =>
        s.WithLayer(id, l => l[property] = AnimValue.Make(keyframes, l[property].ValueAt(0)));

    public static void SetColorKeyframes(this MotionScene s, string id, ColorProperty c, IReadOnlyCollection<Keyframe<Rgba>> keyframes) =>
        s.WithLayer(id, l =>
        {
            l[c] = ColorValue.Make(keyframes, l[c].ValueAt(0));
            if (c == ColorProperty.Stroke && l.StrokeWidth.ValueAt(0) <= 0 && keyframes.Count > 0) l.StrokeWidth = 4.0;
        });

    /// <summary>Path layers: replaces the shape keyframes (a morph between them); an empty list keeps the shape at 0 s.</summary>
    public static void SetPathKeyframes(this MotionScene s, string id, IEnumerable<Keyframe<PathShape>> keyframes) =>
        s.WithLayer(id, l =>
        {
            if (l.Type != LayerType.Path) throw new SceneException($"'{id}' is not a path layer");
            l.D = Animated<PathShape>.Make(keyframes, l.D.ValueAt(0));
        });

    public static void SetValue(this MotionScene s, string id, AnimProperty property, double value, double t) =>
        s.WithLayer(id, l => l[property] = l[property].Setting(value, t));

    public static void SetColor(this MotionScene s, string id, ColorProperty c, Rgba value, double t) =>
        s.WithLayer(id, l =>
        {
            if (c == ColorProperty.Stroke && l.Stroke == null)
            {
                l.Stroke = value;
                if (l.StrokeWidth.ValueAt(t) <= 0) l.StrokeWidth = 4.0;
                return;
            }
            l[c] = l[c].Setting(value, t);
        });

    /// <summary>Applies a merge patch (RFC 7386 style) to one layer (anywhere in the tree).</summary>
    public static void UpdateLayer(this MotionScene s, string id, JsonObject patch)
    {
        var old = s.Layer(id);
        var updated = LayerCodec.Decode(JsonMerge.Merge(LayerCodec.Encode(old), patch), "layer");
        if (updated.Id != old.Id)
        {
            if (updated.Id.Length == 0 || s.AllLayers.Any(l => l.Id != old.Id && l.Id == updated.Id))
                throw new SceneException($"id '{updated.Id}' is empty or already used");
        }
        if (updated.Name.Length == 0) updated.Name = updated.Id;
        var isTop = s.Layers.Any(l => l.Id == old.Id);
        if (updated.Parent is { } p && (p == updated.Id
            || (isTop && (!s.Layers.Any(l => l.Id == p) || s.IsAncestor(old.Id, p)))))
            throw new SceneException($"parent '{p}' must be another existing layer that is not a child of '{updated.Id}'");
        if (updated.Matte is { } m && (m.Source == old.Id || m.Source == updated.Id || s.FindLayer(m.Source) == null))
            throw new SceneException($"matte '{m.Source}' must be another existing layer");
        if (updated.Type == LayerType.Group)
        {
            // Ids used elsewhere in the scene (the group's own subtree may keep its ids).
            var mine = new MotionScene { Layers = [old] }.AllLayers.Select(l => l.Id).ToHashSet();
            var seen = s.AllLayers.Select(l => l.Id).Where(x => !mine.Contains(x)).ToHashSet();
            seen.Add(updated.Id);
            MotionScene.NormalizeIds(updated.Children, seen);
        }
        Replace(s.Layers, old, updated);
        if (updated.Id != old.Id)
        {
            foreach (var l in s.Layers)
            {
                if (l.Parent == old.Id) l.Parent = updated.Id;
                if (l.Matte?.Source == old.Id) l.Matte = l.Matte with { Source = updated.Id };
                foreach (var react in l.AudioReact.Values.Where(x => x.Source == old.Id)) react.Source = updated.Id;
                if (l.Particles.From == old.Id) l.Particles.From = updated.Id;
                if (l.Generator.Source == old.Id) l.Generator.Source = updated.Id;
            }
        }
    }

    static bool Replace(List<MotionLayer> list, MotionLayer old, MotionLayer updated)
    {
        for (var i = 0; i < list.Count; i++)
        {
            if (ReferenceEquals(list[i], old)) { list[i] = updated; return true; }
            if (list[i].Type == LayerType.Group && Replace(list[i].Children, old, updated)) return true;
        }
        return false;
    }

    /// <summary>Whether <paramref name="ancestor"/> is <paramref name="id"/>'s parent, grandparent…</summary>
    public static bool IsAncestor(this MotionScene s, string ancestor, string id)
    {
        var seen = new HashSet<string>();
        var current = s.FindLayer(id)?.Parent;
        while (current != null && seen.Add(current))
        {
            if (current == ancestor) return true;
            current = s.FindLayer(current)?.Parent;
        }
        return false;
    }

    /// <summary>Patches scene settings (width, height, fps, duration, background, camera). <c>layers</c> is ignored.
    /// Returns the patched scene (a new object, so callers swap it in).</summary>
    public static MotionScene UpdatingSettings(this MotionScene s, JsonObject patch)
    {
        var p = (JsonObject)patch.DeepClone();
        p.Remove("layers");
        return SceneJson.FromNode(JsonMerge.Merge(SceneJson.ToNode(s), p));
    }

    // Presets

    public static void ApplyPreset(this MotionScene s, Preset preset, string id, double start, double duration)
    {
        if (!(duration > 0)) throw new SceneException("duration must be > 0");
        var l = s.Layer(id).Clone();
        if (!preset.AppliesTo(l.Type))
        {
            var what = preset.Group() switch { PresetGroup.Text => "text", PresetGroup.Shape => "rect/ellipse/path", _ => "visual" };
            throw new SceneException($"{preset.Json()} only applies to {what} layers");
        }
        double st = start, d = duration, e = start + duration;
        void Put(AnimProperty p, params MotionKeyframe[] kfs) => l[p] = l[p].Inserting(kfs, st, e);
        static MotionKeyframe K(double t, double v, Easing? easing = null) => new(t, v, easing ?? Easing.EaseInOut);
        var opacityIn = Math.Max(l.Opacity.ValueAt(e), 0.01);
        var opacityOut = l.Opacity.ValueAt(st);
        void FadeIn(double fraction) => Put(AnimProperty.Opacity, K(st, 0, Easing.Linear), K(st + d * fraction, opacityIn, Easing.EaseOut));
        void FadeOut(double fraction) => Put(AnimProperty.Opacity, K(st + d * fraction, opacityOut, Easing.Linear), K(e, 0, Easing.EaseIn));
        // Decaying oscillation around the current value (shake, wobble, jello).
        void Oscillate(AnimProperty p, double amplitude, int count = 7)
        {
            var b = l[p].ValueAt(st);
            var kfs = new List<MotionKeyframe> { K(st, b, Easing.Linear) };
            for (var k = 1; k <= count; k++)
            {
                var decay = 1 - (double)(k - 1) / count;
                kfs.Add(K(st + d * k / (count + 1), b + amplitude * decay * (k % 2 == 1 ? 1 : -1), Easing.Named(EaseCurve.Sine, EaseMode.InOut)));
            }
            kfs.Add(K(e, b, Easing.Named(EaseCurve.Sine, EaseMode.InOut)));
            Put(p, [.. kfs]);
        }
        Easing C(EaseCurve c, EaseMode m) => Easing.Named(c, m);

        switch (preset)
        {
            case Preset.FadeIn:
                Put(AnimProperty.Opacity, K(st, 0, Easing.Linear), K(e, opacityIn, Easing.EaseOut));
                break;
            case Preset.FadeOut:
                Put(AnimProperty.Opacity, K(st, opacityOut), K(e, 0, Easing.EaseIn));
                break;
            case Preset.SlideUp or Preset.SlideDown:
            {
                var y = l.Y.ValueAt(e);
                Put(AnimProperty.Y, K(st, y + (preset == Preset.SlideUp ? 120 : -120), Easing.Linear), K(e, y, Easing.EaseOut));
                FadeIn(0.6);
                break;
            }
            case Preset.SlideInLeft or Preset.SlideInRight:
            {
                var x = l.X.ValueAt(e);
                Put(AnimProperty.X, K(st, x + (preset == Preset.SlideInLeft ? -300 : 300), Easing.Linear), K(e, x, Easing.EaseOut));
                FadeIn(0.6);
                break;
            }
            case Preset.SlideOutUp or Preset.SlideOutDown:
            {
                var y = l.Y.ValueAt(st);
                Put(AnimProperty.Y, K(st, y, Easing.Linear), K(e, y + (preset == Preset.SlideOutUp ? -120 : 120), Easing.EaseIn));
                FadeOut(0.4);
                break;
            }
            case Preset.SlideOutLeft or Preset.SlideOutRight:
            {
                var x = l.X.ValueAt(st);
                Put(AnimProperty.X, K(st, x, Easing.Linear), K(e, x + (preset == Preset.SlideOutLeft ? -300 : 300), Easing.EaseIn));
                FadeOut(0.4);
                break;
            }
            case Preset.PopIn:
            {
                var sc = l.Scale.ValueAt(e);
                Put(AnimProperty.Scale, K(st, 0, Easing.Linear), K(st + d * 0.7, sc * 1.08, Easing.EaseOut), K(e, sc, Easing.EaseInOut));
                FadeIn(0.3);
                break;
            }
            case Preset.PopOut:
            {
                var sc = l.Scale.ValueAt(st);
                Put(AnimProperty.Scale, K(st, sc, Easing.Linear), K(st + d * 0.3, sc * 1.08, Easing.EaseOut), K(e, 0, Easing.EaseIn));
                FadeOut(0.5);
                break;
            }
            case Preset.ZoomIn:
            {
                var sc = l.Scale.ValueAt(e);
                Put(AnimProperty.Scale, K(st, sc * 1.6, Easing.Linear), K(e, sc, C(EaseCurve.Expo, EaseMode.Out)));
                FadeIn(0.5);
                break;
            }
            case Preset.ZoomOut:
            {
                var sc = l.Scale.ValueAt(st);
                Put(AnimProperty.Scale, K(st, sc, Easing.Linear), K(e, sc * 1.6, C(EaseCurve.Expo, EaseMode.In)));
                FadeOut(0.3);
                break;
            }
            case Preset.BlurIn:
                Put(AnimProperty.Blur, K(st, 40, Easing.Linear), K(e, 0, C(EaseCurve.Cubic, EaseMode.Out)));
                FadeIn(0.6);
                break;
            case Preset.BlurOut:
                Put(AnimProperty.Blur, K(st, 0, Easing.Linear), K(e, 40, C(EaseCurve.Cubic, EaseMode.In)));
                FadeOut(0.4);
                break;
            case Preset.BounceIn:
            {
                var sc = l.Scale.ValueAt(e);
                Put(AnimProperty.Scale, K(st, 0, Easing.Linear), K(e, sc, C(EaseCurve.Elastic, EaseMode.Out)));
                FadeIn(0.15);
                break;
            }
            case Preset.DropIn:
            {
                var y = l.Y.ValueAt(e);
                Put(AnimProperty.Y, K(st, y - 260, Easing.Linear), K(e, y, C(EaseCurve.Bounce, EaseMode.Out)));
                FadeIn(0.2);
                break;
            }
            case Preset.FlipIn:
                Put(AnimProperty.ScaleX, K(st, 0, Easing.Linear), K(e, l.Value(AnimProperty.ScaleX, e), C(EaseCurve.Back, EaseMode.Out)));
                FadeIn(0.3);
                break;
            case Preset.FlipOut:
                Put(AnimProperty.ScaleX, K(st, l.Value(AnimProperty.ScaleX, st), Easing.Linear), K(e, 0, C(EaseCurve.Back, EaseMode.In)));
                FadeOut(0.6);
                break;
            case Preset.RotateIn:
            {
                double r = l.Rotation.ValueAt(e), sc = l.Scale.ValueAt(e);
                Put(AnimProperty.Rotation, K(st, r - 90, Easing.Linear), K(e, r, Easing.SpringWith(7, 9)));
                Put(AnimProperty.Scale, K(st, sc * 0.5, Easing.Linear), K(e, sc, C(EaseCurve.Back, EaseMode.Out)));
                FadeIn(0.4);
                break;
            }
            case Preset.WipeIn:
                // Without a wipe style, a soft edge sweeping left to right (the edge travels left as wipe goes 0 → 1).
                l.WipeStyle ??= new WipeStyle(WipeType.Linear, 180, 40);
                Put(AnimProperty.Wipe, K(st, 1, Easing.Linear), K(e, 0, C(EaseCurve.Cubic, EaseMode.InOut)));
                break;
            case Preset.WipeOut:
                l.WipeStyle ??= new WipeStyle(WipeType.Linear, 0, 40);
                Put(AnimProperty.Wipe, K(st, 0, Easing.Linear), K(e, 1, C(EaseCurve.Cubic, EaseMode.InOut)));
                break;
            case Preset.Spin:
            {
                var r = l.Rotation.ValueAt(st);
                Put(AnimProperty.Rotation, K(st, r, Easing.Linear), K(e, r + 360, Easing.EaseInOut));
                break;
            }
            case Preset.Pulse:
            {
                var sc = l.Scale.ValueAt(st);
                Put(AnimProperty.Scale, K(st, sc, Easing.Linear), K(st + d / 2, sc * 1.12, Easing.EaseOut), K(e, sc, Easing.EaseInOut));
                break;
            }
            case Preset.Heartbeat:
            {
                var sc = l.Scale.ValueAt(st);
                Put(AnimProperty.Scale, K(st, sc, Easing.Linear), K(st + d * 0.15, sc * 1.15, Easing.EaseOut), K(st + d * 0.3, sc, Easing.EaseIn),
                    K(st + d * 0.45, sc * 1.1, Easing.EaseOut), K(e, sc, Easing.EaseInOut));
                break;
            }
            case Preset.Shake: Oscillate(AnimProperty.X, 24, 8); break;
            case Preset.Wobble: Oscillate(AnimProperty.Rotation, 10, 6); break;
            case Preset.Jello: Oscillate(AnimProperty.SkewX, 14, 6); break;
            case Preset.GlitchBurst:
                Put(AnimProperty.Glitch, K(st, 0, Easing.Linear), K(st + d * 0.1, 0.9, Easing.Hold), K(st + d * 0.45, 0.35, Easing.Hold),
                    K(st + d * 0.7, 0.8, Easing.Hold), K(e, 0, Easing.Hold));
                Put(AnimProperty.RgbSplit, K(st, 0, Easing.Linear), K(st + d * 0.1, 8, Easing.Hold), K(e, 0, Easing.Hold));
                break;
            case Preset.DrawOn:
                if (l.Stroke == null)
                {
                    l.Stroke = l.Fill.ValueAt(st);
                    l.Fill = Rgba.Clear;
                }
                if (l.StrokeWidth.ValueAt(st) <= 0) l.StrokeWidth = 6.0;
                Put(AnimProperty.Trim, K(st, 0, Easing.Linear), K(e, 1, C(EaseCurve.Cubic, EaseMode.InOut)));
                break;
            case Preset.WriteOn:
            {
                // Handwriting: the outline writes piece by piece, then the fill fades in.
                var color = l.Fill.ValueAt(e);
                l.Stroke ??= color.A > 0 ? color : Rgba.White;
                if (l.StrokeWidth.ValueAt(st) <= 0) l.StrokeWidth = 3.0;
                l.TrimSequential = true;
                Put(AnimProperty.Trim, K(st, 0, Easing.Linear), K(st + d * 0.8, 1, Easing.Linear));
                var clear = color with { A = 0 };
                l.Fill = l.Fill.Inserting([new(st, clear, Easing.Linear), new(st + d * 0.7, clear, Easing.Hold), new(e, color, Easing.EaseOut)], st, e);
                break;
            }
            case Preset.Typewriter:
                Put(AnimProperty.Reveal, K(st, 0, Easing.Linear), K(e, 1, Easing.Linear));
                break;
            case Preset.Decode:
                Put(AnimProperty.Scramble, K(st, 1, Easing.Linear), K(e, 0, Easing.Linear));
                break;
            case Preset.TextRise or Preset.TextPop or Preset.TextDrop or Preset.TextLines or Preset.TextOut
                or Preset.TextBlurIn or Preset.TextFocus:
            {
                var a = preset switch
                {
                    Preset.TextBlurIn => new TextAnimator { Unit = TextUnit.Char, Easing = C(EaseCurve.Cubic, EaseMode.Out), Blur = 24 },
                    Preset.TextFocus => new TextAnimator { Unit = TextUnit.Word, Easing = C(EaseCurve.Quad, EaseMode.Out), Scale = 1.6, Blur = 16 },
                    Preset.TextPop => new TextAnimator { Unit = TextUnit.Word, Easing = C(EaseCurve.Back, EaseMode.Out), Scale = 0 },
                    Preset.TextDrop => new TextAnimator { Unit = TextUnit.Char, Easing = C(EaseCurve.Back, EaseMode.Out), Y = -70, Rotation = -25 },
                    Preset.TextLines => new TextAnimator { Unit = TextUnit.Line, Easing = C(EaseCurve.Expo, EaseMode.Out), X = -60, Y = 30 },
                    Preset.TextOut => new TextAnimator { Unit = TextUnit.Char, Mode = AnimatorMode.Out, Easing = C(EaseCurve.Cubic, EaseMode.In), Y = -40 },
                    _ => new TextAnimator { Unit = TextUnit.Char, Easing = C(EaseCurve.Cubic, EaseMode.Out), Y = 50 },
                };
                var n = Math.Max(1, TextUnits.Map(l.Text, a.Unit).Count);
                var unitDur = n <= 1 ? d : Math.Min(Math.Max(d * 0.35, Math.Min(0.6, d * 0.6)), d);
                a = a with { Start = st, Duration = unitDur, Stagger = n <= 1 ? 0 : Math.Max(0, (d - unitDur) / (n - 1)) };
                l.TextAnimators.RemoveAll(x => x.Mode == a.Mode);
                l.TextAnimators.Add(a);
                break;
            }
        }
        var original = s.Layer(id);
        Replace(s.Layers, original, l);
    }

    /// <summary>Applies a preset to several layers, each starting <paramref name="stagger"/> seconds after the previous
    /// one. Layers the preset doesn't apply to are skipped; returns the ids it was applied to.</summary>
    public static List<string> ApplyPreset(this MotionScene s, Preset preset, IEnumerable<string> ids, double start, double duration, double stagger)
    {
        var done = new List<string>();
        foreach (var id in ids)
        {
            if (!preset.AppliesTo(s.Layer(id).Type)) continue;
            s.ApplyPreset(preset, id, start + stagger * done.Count, duration);
            done.Add(id);
        }
        if (done.Count == 0) throw new SceneException($"{preset.Json()} does not apply to any of these layers");
        return done;
    }
}

public static class JsonMerge
{
    /// <summary>RFC 7386 JSON merge patch: objects merge recursively, null deletes, anything else replaces.
    /// Keyframe objects replace wholesale so stale keyframes never linger. Returns a new node.</summary>
    public static JsonNode? Merge(JsonNode? target, JsonNode? patch)
    {
        if (patch is not JsonObject p) return patch?.DeepClone();
        if (p.ContainsKey("keyframes")) return p.DeepClone();
        var t = target as JsonObject is { } obj ? (JsonObject)obj.DeepClone() : new JsonObject();
        foreach (var (k, v) in p)
        {
            if (v == null) t.Remove(k);
            else t[k] = Merge(t[k], v);
        }
        return t;
    }
}
