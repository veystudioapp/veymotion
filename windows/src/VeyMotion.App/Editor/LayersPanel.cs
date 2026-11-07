using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using VeyMotion.Core;

namespace VeyMotion.App.Editor;

/// <summary>The sidebar's layer list: top-most layer first, group children indented. Click selects; the context menu
/// has the Layer menu's commands. Port target of the Layers panel in <c>ContentView.swift</c>.</summary>
public sealed class LayersPanel : UserControl
{
    readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single, Padding = new Thickness(0, 4, 0, 4) };
    SceneStore? _store;
    LayerCommands? _commands;
    bool _syncing;

    public LayersPanel()
    {
        Content = _list;
        _list.SelectionChanged += (_, _) =>
        {
            if (_syncing || _store == null) return;
            _store.Selection = (_list.SelectedItem as ListViewItem)?.Tag as string;
        };
    }

    public void Attach(SceneStore store, LayerCommands commands)
    {
        _store = store;
        _commands = commands;
        store.SceneChanged += Rebuild;
        store.SelectionChanged += SyncSelection;
        Rebuild();
    }

    void Rebuild()
    {
        if (_store == null) return;
        _syncing = true;
        _list.Items.Clear();
        void Add(IEnumerable<MotionLayer> layers, int depth)
        {
            foreach (var l in layers.Reverse())
            {
                _list.Items.Add(Row(l, depth));
                if (l.Type == LayerType.Group) Add(l.Children, depth + 1);
            }
        }
        Add(_store.Scene.Layers, 0);
        _syncing = false;
        SyncSelection();
    }

    void SyncSelection()
    {
        if (_store == null) return;
        _syncing = true;
        _list.SelectedItem = _list.Items.OfType<ListViewItem>().FirstOrDefault(i => (string)i.Tag == _store.Selection);
        if (_list.SelectedItem != null) _list.ScrollIntoView(_list.SelectedItem);
        _syncing = false;
    }

    ListViewItem Row(MotionLayer l, int depth)
    {
        var row = new Grid { ColumnSpacing = 8, Margin = new Thickness(depth * 16, 0, 0, 0) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(new FontIcon { Glyph = Glyph(l.Type), FontSize = 13, Opacity = 0.75 });
        var name = new TextBlock { Text = l.Name.Length > 0 ? l.Name : l.Id, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(name, 1);
        row.Children.Add(name);
        if (l.Matte != null || l.Parent != null)
        {
            var link = new FontIcon { Glyph = "", FontSize = 11, Opacity = 0.5 };
            ToolTipService.SetToolTip(link, l.Matte != null ? $"Matte: {l.Matte.Source}" : $"Parent: {l.Parent}");
            Grid.SetColumn(link, 2);
            row.Children.Add(link);
        }
        var item = new ListViewItem { Content = row, Tag = l.Id, MinHeight = 32, Padding = new Thickness(12, 0, 8, 0) };
        ToolTipService.SetToolTip(item, $"{l.Id} · {l.Type.Json()}");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, l.Name.Length > 0 ? l.Name : l.Id);
        item.ContextFlyout = Menu(l.Id);
        return item;
    }

    MenuFlyout Menu(string id)
    {
        var menu = new MenuFlyout();
        // Built when it opens, for the layer it opens on.
        menu.Items.Add(new MenuFlyoutItem { Text = "…" });
        menu.Opening += (_, _) =>
        {
            if (_store == null || _commands == null) return;
            _store.Selection = id;
            menu.Items.Clear();
            foreach (var entry in _commands.LayerMenuItems()) menu.Items.Add(entry);
        };
        return menu;
    }

    /// <summary>Segoe Fluent Icons for each layer type.</summary>
    public static string Glyph(LayerType t) => t switch
    {
        LayerType.Rect => "",
        LayerType.Ellipse => "",
        LayerType.Path => "",
        LayerType.Text => "",
        LayerType.Image => "",
        LayerType.Video => "",
        LayerType.Audio => "",
        LayerType.Particles => "",
        LayerType.Generator => "",
        _ => "",
    };
}
