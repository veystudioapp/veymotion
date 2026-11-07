using System.Globalization;

namespace VeyMotion.Core;

/// <summary>sRGB color, serialized as "#RRGGBB" or "#RRGGBBAA". Port of <c>Color.swift</c>.</summary>
public readonly record struct Rgba(double R, double G, double B, double A = 1)
{
    public static readonly Rgba White = new(1, 1, 1);
    public static readonly Rgba Black = new(0, 0, 0);
    public static readonly Rgba Clear = new(0, 0, 0, 0);

    public static Rgba? FromHex(string hex)
    {
        var s = hex.Trim();
        if (s.StartsWith('#')) s = s[1..];
        if (s.Length is not (6 or 8) || !ulong.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v))
            return null;
        if (s.Length == 6)
            return new Rgba(((v >> 16) & 0xFF) / 255.0, ((v >> 8) & 0xFF) / 255.0, (v & 0xFF) / 255.0);
        return new Rgba(((v >> 24) & 0xFF) / 255.0, ((v >> 16) & 0xFF) / 255.0, ((v >> 8) & 0xFF) / 255.0, (v & 0xFF) / 255.0);
    }

    public string Hex
    {
        get
        {
            static int C(double x) => (int)Math.Round(Math.Clamp(x, 0, 1) * 255, MidpointRounding.AwayFromZero);
            var b = $"#{C(R):X2}{C(G):X2}{C(B):X2}";
            return A < 1 ? b + $"{C(A):X2}" : b;
        }
    }

    public static Rgba Lerp(Rgba a, Rgba b, double p)
    {
        double C(double x, double y) => Math.Clamp(x + (y - x) * p, 0, 1);
        return new Rgba(C(a.R, b.R), C(a.G, b.G), C(a.B, b.B), C(a.A, b.A));
    }

    public override string ToString() => Hex;
}
