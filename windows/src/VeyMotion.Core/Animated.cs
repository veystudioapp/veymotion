namespace VeyMotion.Core;

/// <summary>How a track continues after its last keyframe.</summary>
public enum LoopMode { Cycle, Pingpong, Offset }

public readonly record struct Keyframe<TValue>(double T, TValue V, Easing Easing) where TValue : notnull
{
    public Keyframe(double t, TValue v) : this(t, v, Easing.EaseInOut) { }
}

/// <summary>Per-type math for keyframed values (numbers and colors).</summary>
public static class Interp
{
    public static V Lerp<V>(V a, V b, double p) => (a, b) switch
    {
        (double x, double y) => (V)(object)(x + (y - x) * p),
        (Rgba x, Rgba y) => (V)(object)Rgba.Lerp(x, y, p),
        (PathShape x, PathShape y) => (V)(object)PathShape.Lerp(x, y, p),
        (CornerPin x, CornerPin y) => (V)(object)CornerPin.Lerp(x, y, p),
        _ => throw new NotSupportedException(typeof(V).Name),
    };

    public static V Zero<V>() => typeof(V) == typeof(double) ? (V)(object)0.0
        : typeof(V) == typeof(Rgba) ? (V)(object)Rgba.Clear
        : typeof(V) == typeof(PathShape) ? (V)(object)PathShape.Zero
        : typeof(V) == typeof(CornerPin) ? (V)(object)CornerPin.Zero
        : throw new NotSupportedException(typeof(V).Name);

    /// <summary><paramref name="v"/> moved on by <paramref name="cycles"/> repetitions of first→last (loop "offset").
    /// Colors do not accumulate.</summary>
    public static V Extrapolate<V>(V v, V first, V last, double cycles) => (v, first, last) switch
    {
        (double x, double f, double l) => (V)(object)(x + (l - f) * cycles),
        _ => v,
    };
}

/// <summary>
/// An animatable value. Port of <c>AnimValue.swift</c>. JSON form is either a plain value (constant)
/// or <c>{"keyframes": [{"t": 0, "v": 0}, {"t": 1, "v": 100, "easing": "easeOut"}]}</c>.
/// Immutable: every edit returns a new value.
/// </summary>
public sealed class Animated<V> : IEquatable<Animated<V>> where V : notnull
{
    readonly V _constant;
    readonly Keyframe<V>[]? _keys;

    Animated(V constant, Keyframe<V>[]? keys) { _constant = constant; _keys = keys; }

    public static Animated<V> Constant(V v) => new(v, null);
    public static Animated<V> Keyframes(IEnumerable<Keyframe<V>> keys) => new(Interp.Zero<V>(), keys.ToArray());

    public bool IsAnimated => _keys != null;
    public IReadOnlyList<Keyframe<V>> KeyframeList => _keys ?? [];
    /// <summary>The constant value (meaningless when animated).</summary>
    public V ConstantValue => _constant;

    public V ValueAt(double t)
    {
        if (_keys == null) return _constant;
        if (_keys.Length == 0) return Interp.Zero<V>();
        var first = _keys[0]; var last = _keys[^1];
        if (t <= first.T) return first.V;
        if (t >= last.T) return last.V;
        for (var i = 0; i < _keys.Length - 1; i++)
        {
            var a = _keys[i]; var b = _keys[i + 1];
            if (t >= a.T && t < b.T)
            {
                var span = b.T - a.T;
                var p = span > 0 ? (t - a.T) / span : 1;
                return Interp.Lerp(a.V, b.V, b.Easing.Apply(p));
            }
        }
        return last.V;
    }

    /// <summary>Value with the track repeating after its last keyframe.</summary>
    public V ValueAt(double t, LoopMode? loop)
    {
        if (loop is not { } mode || _keys is not { Length: >= 2 } k) return ValueAt(t);
        var first = k[0]; var last = k[^1];
        if (!(last.T - first.T > 1e-6) || !(t > last.T)) return ValueAt(t);
        var span = last.T - first.T;
        var elapsed = t - first.T;
        var cycles = Math.Floor(elapsed / span);
        var local = elapsed - cycles * span;
        return mode switch
        {
            LoopMode.Cycle => ValueAt(first.T + local),
            LoopMode.Pingpong => ValueAt((long)cycles % 2 == 1 ? last.T - local : first.T + local),
            _ => Interp.Extrapolate(ValueAt(first.T + local), first.V, last.V, cycles),
        };
    }

    /// <summary>Normalizes keyframes: sorted by time (stable), collapsing an empty list to a constant.</summary>
    public static Animated<V> Make(IEnumerable<Keyframe<V>> keys, V fallback)
    {
        var sorted = keys.OrderBy(k => k.T).ToArray();
        return sorted.Length == 0 ? Constant(fallback) : new(Interp.Zero<V>(), sorted);
    }

    /// <summary>Replaces keyframes inside [lo, hi] with <paramref name="added"/>, keeping the rest.</summary>
    public Animated<V> Inserting(IEnumerable<Keyframe<V>> added, double lo, double hi)
    {
        var kept = KeyframeList.Where(k => k.T < lo - 1e-6 || k.T > hi + 1e-6);
        return Make(kept.Concat(added), ValueAt(lo));
    }

    /// <summary>Sets the value at time t: updates the constant, or upserts a keyframe if animated.</summary>
    public Animated<V> Setting(V v, double t)
    {
        if (_keys == null) return Constant(v);
        var list = _keys.ToList();
        var i = list.FindIndex(k => Math.Abs(k.T - t) < 1e-4);
        if (i >= 0) list[i] = list[i] with { V = v };
        else list.Add(new Keyframe<V>(t, v));
        return Make(list, v);
    }

    // Timeline edits (a key is addressed by its time)

    public bool HasKey(double t, double tolerance) => KeyframeList.Any(k => Math.Abs(k.T - t) < tolerance);

    public Animated<V> MovingKey(double t, double newT, double tolerance)
    {
        var list = KeyframeList.ToList();
        var i = list.FindIndex(k => Math.Abs(k.T - t) < tolerance);
        if (i < 0) return this;
        list[i] = list[i] with { T = newT };
        return Make(list, list[i].V);
    }

    public Animated<V> SettingEasing(double t, Easing easing, double tolerance)
    {
        if (_keys == null) return this;
        return new(Interp.Zero<V>(), _keys.Select(k => Math.Abs(k.T - t) < tolerance ? k with { Easing = easing } : k).ToArray());
    }

    /// <summary>Deletes the key at t. A track left without keys becomes constant at its value at t.</summary>
    public Animated<V> DeletingKey(double t, double tolerance) =>
        Make(KeyframeList.Where(k => Math.Abs(k.T - t) >= tolerance), ValueAt(t));

    public Animated<V> Shifted(double d) =>
        _keys == null ? this : new(Interp.Zero<V>(), _keys.Select(k => k with { T = k.T + d }).ToArray());

    public bool Equals(Animated<V>? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        if (_keys == null || other._keys == null)
            return _keys == null && other._keys == null && EqualityComparer<V>.Default.Equals(_constant, other._constant);
        return _keys.AsSpan().SequenceEqual(other._keys);
    }

    public override bool Equals(object? obj) => Equals(obj as Animated<V>);

    public override int GetHashCode()
    {
        if (_keys == null) return _constant.GetHashCode();
        var h = new HashCode();
        foreach (var k in _keys) h.Add(k);
        return h.ToHashCode();
    }

    public static bool operator ==(Animated<V>? a, Animated<V>? b) => a?.Equals(b) ?? b is null;
    public static bool operator !=(Animated<V>? a, Animated<V>? b) => !(a == b);

    public static implicit operator Animated<V>(V v) => Constant(v);
}
