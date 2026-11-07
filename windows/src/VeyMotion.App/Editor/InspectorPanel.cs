using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VeyMotion.Core;
using Windows.UI;
using Colors = Microsoft.UI.Colors;

namespace VeyMotion.App.Editor;

/// <summary>
/// Properties of the selected layer at the playhead (or the scene's settings when nothing is selected). Number
/// fields edit the value at the playhead (a keyframe when the track is animated); the diamond adds or removes a
/// keyframe there. Every edit is one undo step. Port target of <c>InspectorView.swift</c>.
/// </summary>
public sealed class InspectorPanel : UserControl
{
    readonly StackPanel _stack = new() { Spacing = 2, Padding = new Thickness(14, 8, 14, 24) };
    readonly List<Action> _refreshers = [];
    SceneStore? _store;
    string? _shownId = "\0";
    bool _refreshing;

    public InspectorPanel()
    {
        Content = new ScrollViewer { Content = _stack, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }

    public void Attach(SceneStore store)
    {
        _store = store;
        store.SelectionChanged += Rebuild;
        store.SceneChanged += () =>
        {
            // A layer's type or id changed (undo, agent edit): its sections differ.
            if (_store.SelectedLayer is { } l && _shownId == l.Id && _shownType == l.Type) Refresh(); else Rebuild();
        };
        store.TimeChanged += Refresh;
        Rebuild();
    }

    LayerType? _shownType;

    double T => _store!.Time;

    void Rebuild()
    {
        if (_store == null) return;
        _stack.Children.Clear();
        _refreshers.Clear();
        var l = _store.SelectedLayer;
        _shownId = l?.Id;
        _shownType = l?.Type;
        if (l == null) BuildScene(); else BuildLayer(l);
        Refresh();
    }

    public void Refresh()
    {
        _refreshing = true;
        foreach (var r in _refreshers) r();
        _refreshing = false;
    }

    // Building blocks (EditorChrome.swift)

    void Section(string title)
    {
        _stack.Children.Add(new TextBlock
        {
            Text = title, Margin = new Thickness(0, 14, 0, 4), Opacity = 0.7,
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
        });
    }

    Grid Row(string label, UIElement editor, UIElement? trailing = null)
    {
        var g = new Grid { ColumnSpacing = 8, MinHeight = 34 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(104) });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(28) });
        g.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.8, TextTrimming = TextTrimming.CharacterEllipsis });
        Grid.SetColumn((FrameworkElement)editor, 1);
        g.Children.Add(editor);
        if (trailing != null)
        {
            Grid.SetColumn((FrameworkElement)trailing, 2);
            g.Children.Add(trailing);
        }
        _stack.Children.Add(g);
        return g;
    }

    static bool Focused(Control c) => c.FocusState != FocusState.Unfocused;

    void Number(string label, Func<double> get, Action<double> set, KeyTrack? track = null, string? id = null, double step = 1)
    {
        var box = new NumberBox
        {
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, SmallChange = step, LargeChange = step * 10,
            NumberFormatter = new Windows.Globalization.NumberFormatting.DecimalFormatter { FractionDigits = 0, IntegerDigits = 1, NumberRounder = new Windows.Globalization.NumberFormatting.IncrementNumberRounder { Increment = 0.001 } },
        };
        box.ValueChanged += (_, e) =>
        {
            if (_refreshing || double.IsNaN(e.NewValue) || Math.Abs(e.NewValue - get()) < 1e-9) return;
            set(e.NewValue);
        };
        Button? key = null;
        if (track is { } k && id != null) key = KeyButton(k, id);
        Row(label, box, key);
        _refreshers.Add(() =>
        {
            if (!Focused(box)) box.Value = Math.Round(get(), 3);
        });
    }

    Button KeyButton(KeyTrack k, string id)
    {
        var icon = new TextBlock { Text = "◇", FontSize = 13 };
        var b = new Button { Content = icon, Padding = new Thickness(4), Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0) };
        ToolTipService.SetToolTip(b, "Add or remove a keyframe at the playhead");
        b.Click += (_, _) => _store!.UpdateLayer(id, "Toggle Keyframe", l => ToggleKey(l, k, T));
        _refreshers.Add(() =>
        {
            if (_store!.Scene.FindLayer(id) is not { } l) return;
            var animated = l.IsAnimated(k);
            var here = animated && l.HasKey(k, T, 1e-3);
            icon.Text = here ? "◆" : "◇";
            icon.Foreground = animated ? new SolidColorBrush(Color.FromArgb(255, 255, 196, 61)) : null;
            icon.Opacity = animated ? 1 : 0.45;
        });
        return b;
    }

    /// <summary>Adds a keyframe with the current value at t, or removes the one there (a track left with one
    /// keyframe stays animated, like macOS).</summary>
    static void ToggleKey(MotionLayer l, KeyTrack k, double t)
    {
        if (l.IsAnimated(k) && l.HasKey(k, t, 1e-3)) { l.DeleteKey(k, t, 1e-3); return; }
        if (k.Number is { } p)
        {
            var v = l[p].ValueAt(t);
            l[p] = l[p].IsAnimated ? l[p].Setting(v, t) : Animated<double>.Keyframes([new(t, v)]);
        }
        else if (k.Color is { } c)
        {
            var v = l[c].ValueAt(t);
            l[c] = l[c].IsAnimated ? l[c].Setting(v, t) : Animated<Rgba>.Keyframes([new(t, v)]);
        }
    }

    void Prop(MotionLayer layer, AnimProperty p, string? label = null)
    {
        var id = layer.Id;
        Number(label ?? p.Title(), () => _store!.Scene.FindLayer(id)?[p].ValueAt(T) ?? p.DefaultValue(),
            v => _store!.Apply($"Change {p.Title()}", s => s.SetValue(id, p, v, T)),
            KeyTrack.Of(p), id, p.IsFractional() ? 0.05 : 1);
    }

    void Text(string label, Func<string> get, Action<string> set, bool multiline = false)
    {
        var box = new TextBox { AcceptsReturn = multiline, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap, MaxHeight = 140 };
        void Commit()
        {
            if (!_refreshing && box.Text != get()) set(box.Text);
        }
        box.LostFocus += (_, _) => Commit();
        box.KeyDown += (_, e) =>
        {
            var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
                .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            if (e.Key == Windows.System.VirtualKey.Enter && (!multiline || ctrl)) { Commit(); e.Handled = true; }
        };
        Row(label, box);
        _refreshers.Add(() =>
        {
            if (!Focused(box)) box.Text = get();
        });
    }

    void ColorField(MotionLayer layer, ColorProperty c, string label)
    {
        var id = layer.Id;
        Rgba? Get() => _store!.Scene.FindLayer(id)?.ColorAt(c, T);
        var swatch = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1), BorderBrush = new SolidColorBrush(Color.FromArgb(80, 255, 255, 255)) };
        var hex = new TextBox { PlaceholderText = "#RRGGBB" };
        var picker = new ColorPicker { IsAlphaEnabled = true, IsMoreButtonVisible = false, IsColorChannelTextInputVisible = false };
        var button = new Button { Content = swatch, Padding = new Thickness(2), Flyout = new Flyout { Content = picker } };
        var pickerOpen = false;
        ((Flyout)button.Flyout).Opened += (_, _) =>
        {
            pickerOpen = true;
            var v = Get() ?? Rgba.White;
            picker.Color = Rendering.FrameCompositor.ToColor(v);
            _store!.BeginInteractive($"Change {label}");
        };
        ((Flyout)button.Flyout).Closed += (_, _) =>
        {
            pickerOpen = false;
            _store!.EndInteractive();
        };
        picker.ColorChanged += (_, e) =>
        {
            if (!pickerOpen) return;
            var v = new Rgba(e.NewColor.R / 255.0, e.NewColor.G / 255.0, e.NewColor.B / 255.0, e.NewColor.A / 255.0);
            _store!.UpdateInteractive(s => s.SetColor(id, c, v, T));
        };
        void Commit()
        {
            if (_refreshing || Rgba.FromHex(hex.Text.Trim()) is not { } v || v == Get()) return;
            _store!.Apply($"Change {label}", s => s.SetColor(id, c, v, T));
        }
        hex.LostFocus += (_, _) => Commit();
        hex.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) Commit(); };
        var editor = new Grid { ColumnSpacing = 6 };
        editor.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        editor.ColumnDefinitions.Add(new ColumnDefinition());
        editor.Children.Add(button);
        Grid.SetColumn(hex, 1);
        editor.Children.Add(hex);
        Row(label, editor, KeyButton(KeyTrack.Of(c), id));
        _refreshers.Add(() =>
        {
            var v = Get();
            swatch.Background = new SolidColorBrush(v is { } col ? Rendering.FrameCompositor.ToColor(col) : Colors.Transparent);
            if (!Focused(hex)) hex.Text = v?.Hex ?? "";
        });
    }

    void Choice<T>(string label, T[] values, Func<T> get, Action<T> set, Func<T, string>? name = null)
    {
        var combo = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var v in values) combo.Items.Add(name?.Invoke(v) ?? v?.ToString() ?? "");
        combo.SelectionChanged += (_, _) =>
        {
            if (_refreshing || combo.SelectedIndex < 0) return;
            var v = values[combo.SelectedIndex];
            if (!EqualityComparer<T>.Default.Equals(v, get())) set(v);
        };
        Row(label, combo);
        _refreshers.Add(() => combo.SelectedIndex = Array.IndexOf(values, get()));
    }

    // Scene

    void BuildScene()
    {
        Section("Scene");
        var s = () => _store!.Scene;
        void Patch(string label, JsonObject patch) => _store!.Apply(label, sc => sc.UpdatingSettings(patch));
        Number("Width", () => s().Width, v => Patch("Change Width", new JsonObject { ["width"] = (int)Math.Max(16, v) }));
        Number("Height", () => s().Height, v => Patch("Change Height", new JsonObject { ["height"] = (int)Math.Max(16, v) }));
        Number("FPS", () => s().Fps, v => Patch("Change FPS", new JsonObject { ["fps"] = (int)Math.Clamp(v, 1, 240) }));
        Number("Duration", () => s().Duration, v => Patch("Change Duration", new JsonObject { ["duration"] = Math.Max(0.1, v) }), step: 0.5);
        Text("Background", () => s().Background.Hex, v =>
        {
            if (Rgba.FromHex(v.Trim()) is { } c) Patch("Change Background", new JsonObject { ["background"] = c.Hex });
        });
        _stack.Children.Add(new TextBlock
        {
            Text = "Select a layer on the canvas, in the layer list or in the timeline to edit it.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.55, Margin = new Thickness(0, 16, 0, 0),
        });
    }

    /// <summary>The emitter's main settings (ParticlesInspector.swift); every other field is in the JSON.</summary>
    void BuildParticles(MotionLayer l)
    {
        var id = l.Id;
        ParticleSystem? P() => _store!.Scene.FindLayer(id)?.Particles;
        void Edit(string label, Action<ParticleSystem> body) => _store!.UpdateLayer(id, label, x => body(x.Particles));
        Section("Particles");
        ParticlePreset?[] presets = [null, .. Enum.GetValues<ParticlePreset>().Cast<ParticlePreset?>()];
        Choice("Preset", presets, () => P()?.Preset, v => _store!.UpdateLayer(id, "Change Preset", x =>
        {
            x.Particles = ParticleSystem.Base(v);
            if (v is { } preset) x.BlendMode = ParticleSystem.DefaultBlendMode(preset);
        }), v => v?.Json() ?? "custom");
        Choice("Emitter", Enum.GetValues<EmitterShape>(), () => P()?.Emitter ?? EmitterShape.Point, v => Edit("Change Emitter", p => p.Emitter = v), v => v.Json());
        Choice("Shape", Enum.GetValues<ParticleShape>(), () => P()?.Shape ?? ParticleShape.Soft, v => Edit("Change Particle Shape", p => p.Shape = v), v => v.Json());
        Number("Rate", () => P()?.Rate ?? 0, v => Edit("Change Rate", p => p.Rate = Math.Max(0, v)), step: 5);
        Number("Lifetime", () => P()?.Lifetime ?? 0, v => Edit("Change Lifetime", p => p.Lifetime = Math.Max(0.01, v)), step: 0.1);
        Number("Speed", () => P()?.Speed ?? 0, v => Edit("Change Speed", p => p.Speed = v), step: 10);
        Number("Direction", () => P()?.Direction ?? 0, v => Edit("Change Direction", p => p.Direction = v), step: 5);
        Number("Spread", () => P()?.Spread ?? 0, v => Edit("Change Spread", p => p.Spread = Math.Clamp(v, 0, 360)), step: 5);
        Number("Gravity", () => P()?.Gravity ?? 0, v => Edit("Change Gravity", p => p.Gravity = v), step: 10);
        Number("Turbulence", () => P()?.Turbulence ?? 0, v => Edit("Change Turbulence", p => p.Turbulence = Math.Max(0, v)), step: 5);
        Number("Size", () => P()?.Size ?? 0, v => Edit("Change Size", p => p.Size = Math.Max(0, v)));
        Number("Grow", () => P()?.Grow ?? 1, v => Edit("Change Grow", p => p.Grow = Math.Max(0, v)), step: 0.1);
        Number("Trail", () => P()?.Trail ?? 0, v => Edit("Change Trail", p => p.Trail = Math.Clamp(v, 0, 3)), step: 0.05);
        Text("Colors", () => string.Join(" ", P()?.Colors.Select(c => c.Hex) ?? []), v =>
        {
            var colors = v.Split([' ', ','], StringSplitOptions.RemoveEmptyEntries).Select(Rgba.FromHex).OfType<Rgba>().ToList();
            if (colors.Count > 0) Edit("Change Colors", p => p.Colors = colors);
        });
    }

    // Layer

    void BuildLayer(MotionLayer l)
    {
        var id = l.Id;
        MotionLayer? L() => _store!.Scene.FindLayer(id);
        Section($"{char.ToUpperInvariant(l.Type.Json()[0])}{l.Type.Json()[1..]} · {l.Id}");
        Text("Name", () => L()?.Name ?? "", v => _store!.UpdateLayer(id, "Rename", x => x.Name = v));
        Number("Start", () => L()?.Start ?? 0, v => _store!.UpdateLayer(id, "Change Start", x => x.Start = Math.Max(0, v)), step: 0.1);
        Number("End", () => L()?.End ?? _store!.Scene.Duration,
            v => _store!.UpdateLayer(id, "Change End", x => x.End = v >= _store!.Scene.Duration - 1e-6 ? null : Math.Max(x.Start + 0.01, v)), step: 0.1);

        var shown = new HashSet<AnimProperty>();
        void P(AnimProperty p, string? label = null)
        {
            if (!l.ApplicableProperties.Contains(p) || !shown.Add(p)) return;
            Prop(l, p, label);
        }

        if (l.Type != LayerType.Audio)
        {
            Section("Transform");
            foreach (var p in new[] { AnimProperty.X, AnimProperty.Y, AnimProperty.Scale, AnimProperty.Rotation, AnimProperty.Opacity })
                P(p);
        }

        switch (l.Type)
        {
            case LayerType.Rect or LayerType.Ellipse or LayerType.Path:
                Section("Shape");
                P(AnimProperty.Width); P(AnimProperty.Height); P(AnimProperty.CornerRadius);
                ColorField(l, ColorProperty.Fill, "Fill");
                ColorField(l, ColorProperty.Stroke, "Stroke");
                P(AnimProperty.StrokeWidth); P(AnimProperty.Trim); P(AnimProperty.TrimStart);
                break;
            case LayerType.Text:
                Section("Text");
                Text("Text", () => L()?.Text ?? "", v => _store!.UpdateLayer(id, "Edit Text", x => x.Text = v), multiline: true);
                Number("Font Size", () => L()?.FontSize ?? 72, v => _store!.UpdateLayer(id, "Change Font Size", x => x.FontSize = Math.Max(1, v)));
                Choice("Weight", ["thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"], () => L()?.FontWeight ?? "bold",
                    v => _store!.UpdateLayer(id, "Change Weight", x => x.FontWeight = v));
                Text("Font", () => L()?.FontName ?? "", v => _store!.UpdateLayer(id, "Change Font", x => x.FontName = string.IsNullOrWhiteSpace(v) ? null : v.Trim()));
                Choice("Align", Enum.GetValues<TextAlign>(), () => L()?.Align ?? TextAlign.Center,
                    v => _store!.UpdateLayer(id, "Change Align", x => x.Align = v), v => v.Json());
                ColorField(l, ColorProperty.Color, "Color");
                ColorField(l, ColorProperty.Stroke, "Outline");
                P(AnimProperty.StrokeWidth, "Outline Width"); P(AnimProperty.Reveal); P(AnimProperty.LetterSpacing);
                break;
            case LayerType.Image or LayerType.Video or LayerType.Audio:
                Section("File");
                Text("Path", () => L()?.Path ?? "", v => _store!.UpdateLayer(id, "Change File", x => x.Path = v.Trim().Length == 0 ? null : v.Trim()));
                P(AnimProperty.Width); P(AnimProperty.Height); P(AnimProperty.Volume);
                break;
            case LayerType.Particles or LayerType.Generator or LayerType.Group:
                Section("Box");
                P(AnimProperty.Width); P(AnimProperty.Height);
                if (l.Type == LayerType.Generator) ColorField(l, ColorProperty.Fill, "Fill");
                if (l.Type == LayerType.Particles) BuildParticles(l);
                break;
        }

        if (l.Type.IsVisual())
        {
            Section("Look");
            Choice("Blend", Enum.GetValues<BlendMode>(), () => L()?.BlendMode ?? BlendMode.Normal,
                v => _store!.UpdateLayer(id, "Change Blend Mode", x => x.BlendMode = v), v => v.Json());
            Number("Motion Blur", () => L()?.MotionBlur ?? 0, v => _store!.UpdateLayer(id, "Change Motion Blur", x => x.MotionBlur = Math.Clamp(v, 0, 720)), step: 45);
        }

        // Everything else the layer type can animate, so no property needs JSON.
        var rest = l.ApplicableProperties.Where(p => !shown.Contains(p)).ToList();
        if (rest.Count > 0)
        {
            var more = new Expander { Header = $"More properties ({rest.Count})", HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 12, 0, 0) };
            var inner = new StackPanel { Spacing = 2 };
            more.Content = inner;
            _stack.Children.Add(more);
            var outer = _stack.Children.Count;
            foreach (var p in rest) Prop(l, p);
            // Move the rows just added into the expander.
            while (_stack.Children.Count > outer)
            {
                var row = _stack.Children[outer];
                _stack.Children.RemoveAt(outer);
                inner.Children.Add(row);
            }
        }
    }
}
