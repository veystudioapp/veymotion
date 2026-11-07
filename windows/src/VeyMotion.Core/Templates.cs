using System.Globalization;

namespace VeyMotion.Core;

using AnimValue = Animated<double>;
using ColorValue = Animated<Rgba>;

/// <summary>Ready-made animated pieces (like Premiere's Motion Graphics templates): each is a group of ordinary layers
/// with their entrance and exit already keyed, so they can be edited like anything else afterwards. Port of
/// <c>Templates.swift</c>.</summary>
public enum TemplateKind { LowerThird, Callout, Subscribe, EndCard, TitleCard, Quote }

public sealed class TemplateOptions
{
    public string? Title, Subtitle;
    public Rgba? Accent;
    public double Start;
    public double Duration = 4;
    /// <summary>Where the template points at or sits (scene px); each kind has a sensible default.</summary>
    public double? X, Y;
    public string? FontName;
}

public static class Templates
{
    public static string Title(this TemplateKind k) => k switch
    {
        TemplateKind.LowerThird => "Lower Third",
        TemplateKind.Callout => "Call-out",
        TemplateKind.Subscribe => "Subscribe Button",
        TemplateKind.EndCard => "End Card",
        TemplateKind.TitleCard => "Title Card",
        _ => "Quote",
    };

    static string N(double v) => v.ToString("R", CultureInfo.InvariantCulture);

    /// <summary>Adds a template as a group on top and returns its id.</summary>
    public static string AddTemplate(this MotionScene scene, TemplateKind kind, string? id, TemplateOptions o)
    {
        double w = scene.Width, h = scene.Height;
        double s = o.Start, e = o.Start + Math.Max(o.Duration, 1);
        var accent = o.Accent ?? Rgba.FromHex("#FF4D6D")!.Value;
        var baseId = id ?? kind.Json();
        // Child ids: "<group>-<part>" made unique scene-wide by AddLayer.
        var children = new List<MotionLayer>();
        static string Cap(string p) => char.ToUpperInvariant(p[0]) + p[1..];
        MotionLayer Text(string part, string str, double size, string weight = "bold", double x = 0, double y = 0,
            Rgba? color = null, TextAlign align = TextAlign.Center) => new(LayerType.Text, $"{baseId}-{part}", Cap(part), x, y)
        {
            Text = str, FontSize = size, FontWeight = weight, Color = color ?? Rgba.White, Align = align, FontName = o.FontName,
            Start = s, End = e,
        };
        MotionLayer Rect(string part, double x, double y, double rw, double rh, Rgba color, double radius = 0)
        {
            var l = new MotionLayer(LayerType.Rect, $"{baseId}-{part}", Cap(part), x, y)
            {
                Fill = color, CornerRadius = radius, Start = s, End = e,
            };
            l[AnimProperty.Width] = rw;
            l[AnimProperty.Height] = rh;
            return l;
        }
        static Keyframe<double> K(double t, double v, Easing easing) => new(t, v, easing);
        var cubicInOut = Easing.Named(EaseCurve.Cubic, EaseMode.InOut);
        var presets = new List<(string Part, Preset Preset, double Start, double Duration)>();
        switch (kind)
        {
            case TemplateKind.LowerThird:
            {
                double left = o.X ?? w * 0.06, top = o.Y ?? h * 0.78;
                var title = o.Title ?? "Your Name";
                var tw = Math.Max(new StringInfo(title).LengthInTextElements * h * 0.034, w * 0.22);
                var panel = Rect("panel", left + tw / 2 + 24, top + h * 0.04, tw + 48, h * 0.13, new Rgba(0.05, 0.06, 0.09, 0.82), 10);
                panel.WipeStyle = new WipeStyle(WipeType.Linear, 180, 30);
                children.Add(panel);
                children.Add(Rect("bar", left + 6, top + h * 0.04, 12, h * 0.13, accent, 4));
                var t1 = Text("title", title, h * 0.05, "heavy", left + 36 + tw / 2, top + h * 0.015, align: TextAlign.Left);
                t1.MaxWidth = tw;
                children.Add(t1);
                var t2 = Text("subtitle", o.Subtitle ?? "Title · Company", h * 0.028, "medium", left + 36 + tw / 2, top + h * 0.075,
                    new Rgba(0.8, 0.82, 0.88), TextAlign.Left);
                t2.MaxWidth = tw;
                children.Add(t2);
                presets = [("bar", Preset.DropIn, s, 0.5), ("panel", Preset.WipeIn, s + 0.1, 0.6), ("title", Preset.TextRise, s + 0.25, 0.7),
                    ("subtitle", Preset.FadeIn, s + 0.55, 0.5), ("panel", Preset.WipeOut, e - 0.6, 0.5),
                    ("title", Preset.FadeOut, e - 0.5, 0.4), ("subtitle", Preset.FadeOut, e - 0.55, 0.4), ("bar", Preset.SlideOutLeft, e - 0.4, 0.4)];
                break;
            }
            case TemplateKind.Callout:
            {
                double px = o.X ?? w * 0.42, py = o.Y ?? h * 0.5;
                double lx = px + w * 0.12, ly = py - h * 0.16;
                var dot = new MotionLayer(LayerType.Ellipse, $"{baseId}-dot", "Dot", px, py)
                {
                    Fill = accent, Stroke = Rgba.White, StrokeWidth = 4.0, Start = s, End = e,
                };
                dot[AnimProperty.Width] = 26.0;
                dot[AnimProperty.Height] = 26.0;
                children.Add(dot);
                var line = new MotionLayer(LayerType.Path, $"{baseId}-line", "Line", 0, 0)
                {
                    D = new PathShape($"M {N(px)} {N(py)} L {N(px + w * 0.05)} {N(ly)} L {N(lx + w * 0.11)} {N(ly)}"),
                    Fill = Rgba.Clear, Stroke = Rgba.White, StrokeWidth = 3.0, Start = s, End = e,
                };
                children.Add(line);
                children.Add(Text("title", o.Title ?? "Look here", h * 0.04, "heavy", lx + w * 0.11, ly - h * 0.035));
                children.Add(Text("subtitle", o.Subtitle ?? "A detail worth noticing", h * 0.024, "medium", lx + w * 0.11, ly + h * 0.03,
                    new Rgba(0.85, 0.87, 0.92)));
                presets = [("dot", Preset.PopIn, s, 0.4), ("line", Preset.DrawOn, s + 0.2, 0.6), ("title", Preset.TextPop, s + 0.6, 0.5),
                    ("subtitle", Preset.FadeIn, s + 0.8, 0.5), ("dot", Preset.Pulse, s + 1.4, 0.6),
                    ("title", Preset.FadeOut, e - 0.5, 0.4), ("subtitle", Preset.FadeOut, e - 0.5, 0.4), ("dot", Preset.PopOut, e - 0.4, 0.4)];
                break;
            }
            case TemplateKind.Subscribe:
            {
                double cx = o.X ?? w * 0.5, cy = o.Y ?? h * 0.82;
                double bw = w * 0.2, bh = h * 0.09;
                var red = Rgba.FromHex("#FF0033")!.Value;
                var button = Rect("button", cx, cy, bw, bh, red, bh / 2);
                var click = s + 1.3;
                button.Fill = ColorValue.Keyframes([new(click, red, Easing.Linear), new(click + 0.1, Rgba.FromHex("#3A3D46")!.Value, Easing.Hold)]);
                children.Add(button);
                var label = Text("label", o.Title ?? "SUBSCRIBE", bh * 0.4, "heavy", cx, cy);
                label.End = click + 0.1;
                children.Add(label);
                var done = Text("done", o.Subtitle ?? "SUBSCRIBED ✓", bh * 0.36, "heavy", cx, cy);
                done.Start = click + 0.1;
                children.Add(done);
                var cursor = new MotionLayer(LayerType.Path, $"{baseId}-cursor", "Cursor", cx + bw * 0.25, cy + bh * 0.9)
                {
                    D = new PathShape("M 0 0 L 0 36 L 9 28 L 16 44 L 22 41 L 15 26 L 27 26 Z"),
                    Fill = Rgba.White, Stroke = new Rgba(0, 0, 0, 1), StrokeWidth = 2.0, Start = s + 0.5, End = e,
                    X = AnimValue.Keyframes([K(s + 0.5, cx + bw * 0.6, Easing.Linear), K(click - 0.15, cx + bw * 0.2, cubicInOut)]),
                    Y = AnimValue.Keyframes([K(s + 0.5, cy + bh * 1.6, Easing.Linear), K(click - 0.15, cy + bh * 0.05, cubicInOut)]),
                };
                children.Add(cursor);
                presets = [("button", Preset.PopIn, s, 0.5), ("label", Preset.FadeIn, s + 0.2, 0.3), ("cursor", Preset.FadeIn, s + 0.5, 0.2),
                    ("button", Preset.Pulse, click - 0.05, 0.3), ("done", Preset.PopIn, click + 0.1, 0.35),
                    ("button", Preset.PopOut, e - 0.4, 0.4), ("done", Preset.FadeOut, e - 0.4, 0.3), ("cursor", Preset.FadeOut, e - 0.5, 0.3)];
                break;
            }
            case TemplateKind.EndCard:
            {
                children.Add(Text("title", o.Title ?? "Thanks for watching", h * 0.07, "heavy", o.X ?? w / 2, o.Y ?? h * 0.2));
                double cardW = w * 0.3, cardH = cardW * 9 / 16, gy = h * 0.55;
                double[] offsets = [-0.19, 0.19];
                for (var k = 0; k < offsets.Length; k++)
                {
                    var dx = offsets[k];
                    var c = Rect($"video{k + 1}", w / 2 + w * dx, gy, cardW, cardH, new Rgba(1, 1, 1, 0.08), 16);
                    c.Stroke = new Rgba(1, 1, 1, 0.5);
                    c.StrokeWidth = 3.0;
                    children.Add(c);
                    children.Add(Text($"label{k + 1}", k == 0 ? "Next video" : "Best of", h * 0.03, "semibold",
                        w / 2 + w * dx, gy + cardH / 2 + h * 0.04, new Rgba(0.8, 0.82, 0.88)));
                }
                var sub = new MotionLayer(LayerType.Ellipse, $"{baseId}-sub", "Subscribe", w / 2, h * 0.86) { Fill = accent, Start = s, End = e };
                sub[AnimProperty.Width] = h * 0.13;
                sub[AnimProperty.Height] = h * 0.13;
                children.Add(sub);
                children.Add(Text("subtext", o.Subtitle ?? "Subscribe", h * 0.025, "bold", w / 2, h * 0.86));
                presets = [("title", Preset.TextRise, s, 0.7), ("video1", Preset.ZoomIn, s + 0.3, 0.6), ("video2", Preset.ZoomIn, s + 0.45, 0.6),
                    ("label1", Preset.FadeIn, s + 0.7, 0.4), ("label2", Preset.FadeIn, s + 0.8, 0.4), ("sub", Preset.BounceIn, s + 0.9, 0.7),
                    ("subtext", Preset.FadeIn, s + 1.2, 0.3), ("sub", Preset.Heartbeat, s + 2, 1)];
                break;
            }
            case TemplateKind.TitleCard:
            {
                double cx = o.X ?? w / 2, cy = o.Y ?? h * 0.47;
                var title = Text("title", o.Title ?? "THE TITLE", h * 0.12, "black", cx, cy);
                title[AnimProperty.Shine] = 1.2;
                title[AnimProperty.ShinePosition] = AnimValue.Keyframes([K(s + 0.8, -0.3, Easing.Linear), K(s + 2, 1.3, cubicInOut)]);
                children.Add(title);
                var rule = new MotionLayer(LayerType.Path, $"{baseId}-rule", "Rule", cx, cy + h * 0.1)
                {
                    D = new PathShape($"M -{N(w * 0.16)} 0 L {N(w * 0.16)} 0"),
                    Fill = Rgba.Clear, Stroke = accent, StrokeWidth = 6.0, Start = s, End = e,
                };
                children.Add(rule);
                children.Add(Text("subtitle", o.Subtitle ?? "A short subtitle", h * 0.035, "medium", cx, cy + h * 0.16, new Rgba(0.82, 0.84, 0.9)));
                presets = [("title", Preset.TextFocus, s, 0.9), ("rule", Preset.DrawOn, s + 0.4, 0.6), ("subtitle", Preset.SlideUp, s + 0.7, 0.6),
                    ("title", Preset.TextOut, e - 0.7, 0.6), ("rule", Preset.FadeOut, e - 0.5, 0.4), ("subtitle", Preset.FadeOut, e - 0.6, 0.4)];
                break;
            }
            case TemplateKind.Quote:
            {
                double cx = o.X ?? w / 2, cy = o.Y ?? h * 0.48;
                children.Add(Text("mark", "“", h * 0.3, "black", cx - w * 0.3, cy - h * 0.15, accent));
                var body = Text("body", o.Title ?? "Simplicity is the ultimate sophistication.", h * 0.06, "semibold", cx, cy);
                body.MaxWidth = w * 0.6;
                children.Add(body);
                children.Add(Text("author", "— " + (o.Subtitle ?? "Leonardo da Vinci"), h * 0.032, "medium", cx, cy + h * 0.16,
                    new Rgba(0.8, 0.82, 0.88)));
                presets = [("mark", Preset.PopIn, s, 0.5), ("body", Preset.TextPop, s + 0.3, 1.2), ("author", Preset.FadeIn, s + 1.5, 0.6),
                    ("body", Preset.FadeOut, e - 0.6, 0.5), ("author", Preset.FadeOut, e - 0.6, 0.5), ("mark", Preset.PopOut, e - 0.5, 0.4)];
                break;
            }
        }
        // The group fills the scene, so children keep scene coordinates.
        var group = new MotionLayer(LayerType.Group, baseId, kind.Title(), w / 2, h / 2) { Children = children, Start = s, End = e };
        var wanted = children.Select(c => c.Id).ToList();
        var gid = scene.AddLayer(group);
        // Children ids may have been suffixed: map "<base>-<part>" → actual id by order.
        var actual = scene.Layer(gid).Children.Select(c => c.Id).ToList();
        var ids = wanted.Zip(actual).ToDictionary(p => p.First, p => p.Second);
        foreach (var (part, preset, start, d) in presets)
            if (ids.TryGetValue($"{baseId}-{part}", out var cid)) scene.ApplyPreset(preset, cid, Math.Max(start, s), d);
        return gid;
    }
}
