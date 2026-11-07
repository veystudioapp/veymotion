using System.Globalization;

namespace VeyMotion.Core;

/// <summary>Shape of a named easing family (the "Back" in easeOutBack).</summary>
public enum EaseCurve { Sine, Quad, Cubic, Quart, Quint, Expo, Circ, Back, Elastic, Bounce }

public enum EaseMode { In, Out, InOut }

public enum EasingKind { Linear, EaseIn, EaseOut, EaseInOut, Hold, Spring, Curve, SpringWith, Steps, CubicBezier }

/// <summary>
/// Easing curve applied to the segment that *arrives* at a keyframe. Port of <c>Easing.swift</c>.
/// Serialized as a string: "linear", "easeIn", "easeOut", "easeInOut", "hold", "spring",
/// "ease&lt;In|Out|InOut&gt;&lt;Sine|…|Bounce&gt;", "spring(damping,frequency)", "steps(n)" or "cubicBezier(x1,y1,x2,y2)".
/// </summary>
public readonly record struct Easing(
    EasingKind Kind,
    EaseCurve Curve = default,
    EaseMode Mode = default,
    double P1 = 0, double P2 = 0, double P3 = 0, double P4 = 0)
{
    public static readonly Easing Linear = new(EasingKind.Linear);
    public static readonly Easing EaseIn = new(EasingKind.EaseIn);
    public static readonly Easing EaseOut = new(EasingKind.EaseOut);
    public static readonly Easing EaseInOut = new(EasingKind.EaseInOut);
    public static readonly Easing Hold = new(EasingKind.Hold);
    public static readonly Easing Spring = new(EasingKind.Spring);

    public static Easing Named(EaseCurve c, EaseMode m) => new(EasingKind.Curve, c, m);
    public static Easing SpringWith(double damping, double frequency) => new(EasingKind.SpringWith, P1: damping, P2: frequency);
    public static Easing Steps(int n) => new(EasingKind.Steps, P1: n);
    public static Easing Bezier(double x1, double y1, double x2, double y2) => new(EasingKind.CubicBezier, P1: x1, P2: y1, P3: x2, P4: y2);

    public const string ParseHelp =
        "Use linear, easeIn, easeOut, easeInOut, hold, spring, "
        + "ease<In|Out|InOut><Sine|Quad|Cubic|Quart|Quint|Expo|Circ|Back|Elastic|Bounce> (e.g. easeOutBack), "
        + "spring(damping,frequency), steps(n) or cubicBezier(x1,y1,x2,y2).";

    public static Easing? Parse(string raw)
    {
        var s = raw.Trim();
        var key = s.ToLowerInvariant().Replace("-", "").Replace("_", "").Replace(" ", "");
        switch (key)
        {
            case "linear": return Linear;
            case "easein": return EaseIn;
            case "easeout": return EaseOut;
            case "easeinout" or "ease": return EaseInOut;
            case "hold" or "step": return Hold;
            case "spring": return Spring;
        }
        if (key.StartsWith("ease"))
        {
            var rest = key[4..];
            EaseMode mode;
            if (rest.StartsWith("inout")) { mode = EaseMode.InOut; rest = rest[5..]; }
            else if (rest.StartsWith("in")) { mode = EaseMode.In; rest = rest[2..]; }
            else if (rest.StartsWith("out")) { mode = EaseMode.Out; rest = rest[3..]; }
            else return null;
            foreach (var c in Enum.GetValues<EaseCurve>())
                if (c.ToString().ToLowerInvariant() == rest) return Named(c, mode);
            return null;
        }
        int open = s.IndexOf('('), close = s.LastIndexOf(')');
        if (open < 0 || close < 0 || open >= close) return null;
        var name = key.Split('(')[0];
        var nums = s[(open + 1)..close].Split(',')
            .Select(x => double.TryParse(x.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? (double?)d : null)
            .Where(d => d.HasValue).Select(d => d!.Value).ToArray();
        return name switch
        {
            "cubicbezier" when nums.Length == 4 => Bezier(nums[0], nums[1], nums[2], nums[3]),
            "spring" when nums.Length == 2 && nums[0] > 0 && nums[1] >= 0 => SpringWith(nums[0], nums[1]),
            "steps" when nums.Length == 1 && nums[0] >= 1 => Steps((int)nums[0]),
            _ => null,
        };
    }

    public override string ToString() => Kind switch
    {
        EasingKind.Linear => "linear",
        EasingKind.EaseIn => "easeIn",
        EasingKind.EaseOut => "easeOut",
        EasingKind.EaseInOut => "easeInOut",
        EasingKind.Hold => "hold",
        EasingKind.Spring => "spring",
        EasingKind.Curve => $"ease{Mode}{Curve}",
        EasingKind.SpringWith => $"spring({Num(P1)},{Num(P2)})",
        EasingKind.Steps => $"steps({(int)P1})",
        EasingKind.CubicBezier => $"cubicBezier({Num(P1)},{Num(P2)},{Num(P3)},{Num(P4)})",
        _ => "linear",
    };

    static string Num(double v) =>
        v == Math.Round(v) && Math.Abs(v) < 1e9 ? ((long)v).ToString(CultureInfo.InvariantCulture) : v.ToString("G6", CultureInfo.InvariantCulture); // like Swift's %g

    /// <summary>Maps linear progress p in [0, 1] to eased progress. Back, elastic and spring overshoot [0, 1].</summary>
    public double Apply(double p)
    {
        p = Math.Clamp(p, 0, 1);
        switch (Kind)
        {
            case EasingKind.Linear: return p;
            case EasingKind.Hold: return p >= 1 ? 1 : 0;
            case EasingKind.EaseIn: return BezierAt(0.55, 0, 0.75, 0.2, p);
            case EasingKind.EaseOut: return BezierAt(0.22, 1, 0.36, 1, p);
            case EasingKind.EaseInOut: return BezierAt(0.65, 0, 0.35, 1, p);
            case EasingKind.Spring: return SpringAt(p, 6, 10);
            case EasingKind.SpringWith: return SpringAt(p, P1, P2);
            case EasingKind.Curve:
                return Mode switch
                {
                    EaseMode.In => CurveIn(Curve, p),
                    EaseMode.Out => 1 - CurveIn(Curve, 1 - p),
                    _ => p < 0.5 ? CurveIn(Curve, 2 * p) / 2 : 1 - CurveIn(Curve, 2 - 2 * p) / 2,
                };
            case EasingKind.Steps:
                var n = Math.Max(P1, 1);
                return p >= 1 ? 1 : Math.Floor(p * n) / n;
            case EasingKind.CubicBezier: return BezierAt(P1, P2, P3, P4, p);
            default: return p;
        }
    }

    /// <summary>The ease-in form; out and inOut are derived from it.</summary>
    static double CurveIn(EaseCurve c, double p)
    {
        switch (c)
        {
            case EaseCurve.Sine: return 1 - Math.Cos(p * Math.PI / 2);
            case EaseCurve.Quad: return p * p;
            case EaseCurve.Cubic: return p * p * p;
            case EaseCurve.Quart: return p * p * p * p;
            case EaseCurve.Quint: return p * p * p * p * p;
            case EaseCurve.Expo: return p <= 0 ? 0 : Math.Pow(2, 10 * p - 10);
            case EaseCurve.Circ: return 1 - Math.Sqrt(1 - p * p);
            case EaseCurve.Back:
                const double c1 = 1.70158, c3 = c1 + 1;
                return c3 * p * p * p - c1 * p * p;
            case EaseCurve.Elastic:
                if (p <= 0 || p >= 1) return p;
                return -Math.Pow(2, 10 * p - 10) * Math.Sin((10 * p - 10.75) * (2 * Math.PI / 3));
            case EaseCurve.Bounce: return 1 - BounceOut(1 - p);
            default: return p;
        }
    }

    static double BounceOut(double p)
    {
        const double n1 = 7.5625, d1 = 2.75;
        if (p < 1 / d1) return n1 * p * p;
        if (p < 2 / d1) { var q = p - 1.5 / d1; return n1 * q * q + 0.75; }
        if (p < 2.5 / d1) { var q = p - 2.25 / d1; return n1 * q * q + 0.9375; }
        var r = p - 2.625 / d1;
        return n1 * r * r + 0.984375;
    }

    /// <summary>Damped oscillation that starts at 0 and lands exactly on 1 at p = 1.</summary>
    static double SpringAt(double p, double damping, double frequency)
    {
        if (p <= 0) return 0;
        if (p >= 1) return 1;
        var tail = Math.Exp(-damping) * Math.Cos(frequency);
        return 1 - (Math.Exp(-damping * p) * Math.Cos(frequency * p) - p * tail);
    }

    /// <summary>CSS-style cubic bezier with endpoints (0,0) and (1,1).</summary>
    static double BezierAt(double x1, double y1, double x2, double y2, double x)
    {
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        static double Sample(double a1, double a2, double t) { var u = 1 - t; return 3 * u * u * t * a1 + 3 * u * t * t * a2 + t * t * t; }
        static double Slope(double a1, double a2, double t) { var u = 1 - t; return 3 * u * u * a1 + 6 * u * t * (a2 - a1) + 3 * t * t * (1 - a2); }
        // Newton-Raphson, falling back to bisection.
        var t = x;
        for (var i = 0; i < 8; i++)
        {
            var err = Sample(x1, x2, t) - x;
            if (Math.Abs(err) < 1e-6) return Sample(y1, y2, t);
            var d = Slope(x1, x2, t);
            if (Math.Abs(d) < 1e-6) break;
            t -= err / d;
        }
        double lo = 0, hi = 1;
        t = x;
        for (var i = 0; i < 40; i++)
        {
            var v = Sample(x1, x2, t);
            if (Math.Abs(v - x) < 1e-7) break;
            if (v < x) lo = t; else hi = t;
            t = (lo + hi) / 2;
        }
        return Sample(y1, y2, t);
    }
}
