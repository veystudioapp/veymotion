using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VeyMotion.Core;
using Windows.System;

namespace VeyMotion.App.Editor;

/// <summary>The Add and Layer menus (toolbar, layer context menus and their shortcuts). Every command is one undo step
/// through the store. Port of the menus in <c>VeyMotionApp.swift</c> / <c>ContentView.swift</c>.</summary>
public sealed class LayerCommands(SceneStore store, Func<LayerType, Task<string?>> pickFile, Action<string> report)
{
    MotionLayer? Selected => store.SelectedLayer;

    bool IsTopLevel(string id) => store.Scene.Layers.Any(l => l.Id == id);

    void Run(string label, Action<MotionScene> body)
    {
        try { store.Apply(label, body); }
        catch (SceneException e) { report(e.Message); }
    }

    public void Duplicate()
    {
        if (Selected is not { } l) return;
        var id = "";
        Run("Duplicate", s => { id = s.DuplicateLayer(l.Id); });
        if (id.Length > 0) store.Selection = id;
    }

    public void Group()
    {
        if (Selected is not { } l || !IsTopLevel(l.Id)) return;
        var id = "";
        Run("Group", s => { id = s.GroupLayers([l.Id]); });
        if (id.Length > 0) store.Selection = id;
    }

    public void Ungroup()
    {
        if (Selected is not { Type: LayerType.Group } l || !IsTopLevel(l.Id)) return;
        var first = l.Children.FirstOrDefault()?.Id;
        Run("Ungroup", s => s.Ungroup(l.Id));
        store.Selection = first;
    }

    public void Delete()
    {
        if (Selected is not { } l) return;
        if (IsTopLevel(l.Id)) Run("Delete Layer", s => s.RemoveLayer(l.Id));
        else Run("Delete Layer", s => RemoveChild(s.Layers, l.Id));
    }

    static bool RemoveChild(List<MotionLayer> list, string id)
    {
        foreach (var g in list.Where(x => x.Type == LayerType.Group))
        {
            if (g.Children.RemoveAll(c => c.Id == id) > 0) return true;
            if (RemoveChild(g.Children, id)) return true;
        }
        return false;
    }

    /// <summary>Moves the selected top-level layer one step up (forward) or down the stack.</summary>
    public void Move(int step)
    {
        if (Selected is not { } l || !IsTopLevel(l.Id)) return;
        var i = store.Scene.LayerIndex(l.Id);
        var to = Math.Clamp(i + step, 0, store.Scene.Layers.Count - 1);
        if (to != i) Run(step > 0 ? "Bring Forward" : "Send Backward", s => s.MoveLayer(l.Id, to));
    }

    public IEnumerable<MenuFlyoutItemBase> LayerMenuItems()
    {
        var l = Selected;
        var top = l != null && IsTopLevel(l.Id);
        yield return Item("Duplicate", "", Duplicate, l != null, VirtualKey.D);
        yield return Item("Group", "", Group, top, VirtualKey.G);
        yield return Item("Ungroup", "", Ungroup, top && l!.Type == LayerType.Group, VirtualKey.G, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift);
        yield return new MenuFlyoutSeparator();
        yield return Item("Bring Forward", "", () => Move(1), top, (VirtualKey)221);
        yield return Item("Send Backward", "", () => Move(-1), top, (VirtualKey)219);
        yield return new MenuFlyoutSeparator();
        yield return Item("Delete", "", Delete, l != null, VirtualKey.Delete, VirtualKeyModifiers.None);
    }

    /// <summary>The Add menu: layers, particles, generators and templates.</summary>
    public MenuFlyout AddMenu()
    {
        var menu = new MenuFlyout();
        menu.Items.Add(Item("Rectangle", LayersPanel.Glyph(LayerType.Rect), () => store.AddLayer(LayerType.Rect)));
        menu.Items.Add(Item("Ellipse", LayersPanel.Glyph(LayerType.Ellipse), () => store.AddLayer(LayerType.Ellipse)));
        menu.Items.Add(Item("Path", LayersPanel.Glyph(LayerType.Path), () => store.AddLayer(LayerType.Path)));
        menu.Items.Add(Item("Text", LayersPanel.Glyph(LayerType.Text), () => store.AddLayer(LayerType.Text), key: VirtualKey.T, modifiers: VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Image…", LayersPanel.Glyph(LayerType.Image), () => _ = AddFile(LayerType.Image)));
        menu.Items.Add(Item("Video / Image Sequence…", LayersPanel.Glyph(LayerType.Video), () => _ = AddFile(LayerType.Video)));
        menu.Items.Add(Item("Audio…", LayersPanel.Glyph(LayerType.Audio), () => _ = AddFile(LayerType.Audio)));
        menu.Items.Add(new MenuFlyoutSeparator());
        var particles = new MenuFlyoutSubItem { Text = "Particles", Icon = new FontIcon { Glyph = LayersPanel.Glyph(LayerType.Particles) } };
        foreach (var p in Enum.GetValues<ParticlePreset>())
        {
            var preset = p;
            particles.Items.Add(Item(Title(p.Json()), null, () => store.AddParticles(preset)));
        }
        menu.Items.Add(particles);
        var generators = new MenuFlyoutSubItem { Text = "Generator", Icon = new FontIcon { Glyph = LayersPanel.Glyph(LayerType.Generator) } };
        foreach (var k in Enum.GetValues<GeneratorKind>())
        {
            var kind = k;
            generators.Items.Add(Item(Title(k.Json()), null, () => store.AddGenerator(kind)));
        }
        menu.Items.Add(generators);
        var templates = new MenuFlyoutSubItem { Text = "Template", Icon = new FontIcon { Glyph = "" } };
        foreach (var k in Enum.GetValues<TemplateKind>())
        {
            var kind = k;
            templates.Items.Add(Item(kind.Title(), null, () => store.AddTemplate(kind)));
        }
        menu.Items.Add(templates);
        return menu;
    }

    static string Title(string json) => char.ToUpperInvariant(json[0]) + json[1..];

    async Task AddFile(LayerType type)
    {
        if (await pickFile(type) is { } path) store.AddLayer(type, path);
    }

    static MenuFlyoutItem Item(string text, string? glyph, Action action, bool enabled = true, VirtualKey? key = null,
        VirtualKeyModifiers modifiers = VirtualKeyModifiers.Control)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        if (glyph != null) item.Icon = new FontIcon { Glyph = glyph };
        item.Click += (_, _) => action();
        // Shown as a hint only: the window's accelerators run the command.
        if (key is { } k) item.KeyboardAcceleratorTextOverride = Shortcut(k, modifiers);
        return item;
    }

    static string Shortcut(VirtualKey key, VirtualKeyModifiers m)
    {
        var parts = new List<string>();
        if (m.HasFlag(VirtualKeyModifiers.Control)) parts.Add("Ctrl");
        if (m.HasFlag(VirtualKeyModifiers.Shift)) parts.Add("Shift");
        if (m.HasFlag(VirtualKeyModifiers.Menu)) parts.Add("Alt");
        parts.Add((int)key switch { 221 => "]", 219 => "[", _ => key == VirtualKey.Delete ? "Del" : key.ToString() });
        return string.Join("+", parts);
    }

    /// <summary>True while the shortcuts must stand aside (annotation mode owns Delete).</summary>
    public Func<bool>? Blocked { get; set; }

    /// <summary>Window shortcuts for the Layer menu and Add Text; they stand aside while a text box has focus.</summary>
    public void InstallAccelerators(Microsoft.UI.Xaml.UIElement root, Func<bool> typing)
    {
        void Add(VirtualKey key, VirtualKeyModifiers m, Action action)
        {
            var acc = new KeyboardAccelerator { Key = key, Modifiers = m };
            acc.Invoked += (_, e) =>
            {
                if (typing() || Blocked?.Invoke() == true) return;
                e.Handled = true;
                action();
            };
            root.KeyboardAccelerators.Add(acc);
        }
        Add(VirtualKey.D, VirtualKeyModifiers.Control, Duplicate);
        Add(VirtualKey.G, VirtualKeyModifiers.Control, Group);
        Add(VirtualKey.G, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, Ungroup);
        Add((VirtualKey)221, VirtualKeyModifiers.Control, () => Move(1));
        Add((VirtualKey)219, VirtualKeyModifiers.Control, () => Move(-1));
        Add(VirtualKey.Delete, VirtualKeyModifiers.None, Delete);
        Add(VirtualKey.Back, VirtualKeyModifiers.None, Delete);
        Add(VirtualKey.T, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, () => store.AddLayer(LayerType.Text));
    }
}
