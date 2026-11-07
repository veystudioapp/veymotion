namespace VeyMotion.Core;

/// <summary>
/// Retiming operations used by the timeline (drag keyframes, move/trim layers, easing).
/// A keyframe is addressed by (layer, track, time); <c>track == null</c> means "every track
/// that has a keyframe at that time" (the summary diamonds on a layer row). Port of <c>TimelineOps.swift</c>.
/// </summary>
public static class TimelineOps
{
    public const double KeyTimeTolerance = 1e-3;

    static List<KeyTrack> Tracks(MotionLayer layer, KeyTrack? k, double t) =>
        k is { } one ? [one] : KeyTrack.All.Where(x => layer.HasKey(x, t, KeyTimeTolerance)).ToList();

    /// <summary>Moves the keyframe(s) at t to newT.</summary>
    public static void MoveKeyframes(this MotionScene s, string id, KeyTrack? track, double t, double newT)
    {
        var l = s.Layers[s.LayerIndex(id)];
        var target = Math.Min(Math.Max(newT, 0), s.Duration);
        foreach (var k in Tracks(l, track, t)) l.MoveKey(k, t, target, KeyTimeTolerance);
    }

    /// <summary>Sets the easing of the segment arriving at the keyframe(s) at t.</summary>
    public static void SetEasing(this MotionScene s, string id, KeyTrack? track, double t, Easing easing)
    {
        var l = s.Layers[s.LayerIndex(id)];
        foreach (var k in Tracks(l, track, t)) l.SetEasing(k, t, easing, KeyTimeTolerance);
    }

    /// <summary>Deletes the keyframe(s) at t. A track left without keyframes becomes constant at that value.</summary>
    public static void DeleteKeyframes(this MotionScene s, string id, KeyTrack? track, double t)
    {
        var l = s.Layers[s.LayerIndex(id)];
        foreach (var k in Tracks(l, track, t)) l.DeleteKey(k, t, KeyTimeTolerance);
    }

    /// <summary>Shifts layers in time (start, end, every keyframe and text animator) by dt, never before 0.</summary>
    public static void ShiftLayers(this MotionScene s, IEnumerable<string> ids, double dt)
    {
        var idx = ids.Select(s.LayerIndex).ToList();
        if (idx.Count == 0) return;
        var earliest = idx.Select(i => Math.Min(s.Layers[i].Start, s.Layers[i].EarliestKeyTime() ?? s.Layers[i].Start)).Min();
        var d = Math.Max(dt, -earliest);
        if (d == 0) return;
        foreach (var i in idx)
        {
            var l = s.Layers[i];
            l.Start += d;
            if (l.End is { } e) l.End = e + d;
            l.ShiftKeys(d);
        }
    }

    /// <summary>Sets a layer's visible range. Pass null to leave a side unchanged.</summary>
    public static void SetTiming(this MotionScene s, string id, double? start, double? end)
    {
        var i = s.LayerIndex(id);
        var l = s.Layers[i];
        var minLen = 1.0 / Math.Max(s.Fps, 1);
        if (l.Type is LayerType.Audio or LayerType.Video)
        {
            SetMediaTiming(s, l, start, end, minLen);
            return;
        }
        var st = Math.Max(0, start ?? l.Start);
        var e = Math.Min(end ?? l.EffectiveEnd(s.Duration), s.Duration);
        if (start != null && end == null)
            st = Math.Max(0, Math.Min(st, e - minLen)); // trimming the start stops at the end
        else
            e = Math.Max(e, st + minLen);               // trimming the end stops at the start
        l.Start = st;
        l.End = end == null && l.End == null ? null : e;
    }

    /// <summary>Audio and video trim like a video editor: moving the start also moves the in-point inside the file, so
    /// the content stays where it was; the end can't extend past the end of the file (videos that hold or loop can).</summary>
    static void SetMediaTiming(MotionScene s, MotionLayer l, double? start, double? end, double minLen)
    {
        var oldStart = l.Start;
        var curEnd = l.EffectiveEnd(s.Duration);
        var rate = l.Type == LayerType.Video ? Math.Max(l.Speed, 0.01) : 1; // source seconds per scene second
        if (start is { } st0)
        {
            var st = Math.Max(Math.Max(0, st0), oldStart - l.TrimIn / rate); // can't reveal media before the file starts
            st = Math.Min(st, curEnd - minLen);
            l.TrimIn = Math.Max(0, l.TrimIn + (st - oldStart) * rate);
            l.Start = st;
        }
        if (end is { } e0)
        {
            var e = Math.Max(e0, l.Start + minLen);
            if (l.MediaLength is { } len) e = Math.Min(e, l.Start + len);
            if (l.Type == LayerType.Video) e = Math.Min(e, s.Duration);
            l.End = e;
        }
    }

    /// <summary>Moves every keyframe-like time of the layer by d: tracks, path shape, text animators, particle bursts,
    /// gradient, repeater, corner pin, pins (time remap via its track). Port of <c>MotionLayer.shiftKeys(by:)</c>.</summary>
    public static void ShiftKeys(this MotionLayer l, double d)
    {
        foreach (var p in Enum.GetValues<AnimProperty>()) if (l[p].IsAnimated) l[p] = l[p].Shifted(d);
        foreach (var c in Enum.GetValues<ColorProperty>())
        {
            if (c == ColorProperty.Stroke && l.Stroke == null) continue;
            if (l[c].IsAnimated) l[c] = l[c].Shifted(d);
        }
        for (var i = 0; i < l.TextAnimators.Count; i++) l.TextAnimators[i] = l.TextAnimators[i] with { Start = l.TextAnimators[i].Start + d };
        for (var i = 0; i < l.Particles.Bursts.Count; i++) l.Particles.Bursts[i] = l.Particles.Bursts[i] with { T = l.Particles.Bursts[i].T + d };
        l.D = l.D.Shifted(d);
        if (l.Gradient is { } g)
        {
            g.Angle = g.Angle.Shifted(d); g.Shift = g.Shift.Shifted(d); g.Radius = g.Radius.Shifted(d);
        }
        if (l.Repeater is { } r)
        {
            r.X = r.X.Shifted(d); r.Y = r.Y.Shifted(d); r.Rotation = r.Rotation.Shifted(d); r.Scale = r.Scale.Shifted(d);
        }
        l.CornerPin = l.CornerPin?.Shifted(d);
        l.Pins = l.Pins.Select(p => p with { Dx = p.Dx.Shifted(d), Dy = p.Dy.Shifted(d) }).ToList();
        // timeRemap is an AnimProperty, so the loop above already moved it (Swift shifts it a second time here).
    }

    /// <summary>Earliest keyframe, text-animator or particle-burst time, if any.</summary>
    public static double? EarliestKeyTime(this MotionLayer l)
    {
        var all = l.KeyframeTimes.Take(1).Concat(l.TextAnimators.Select(a => a.Start)).Concat(l.Particles.Bursts.Select(b => b.T)).ToList();
        return all.Count == 0 ? null : all.Min();
    }
}
