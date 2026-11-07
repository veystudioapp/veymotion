using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using VeyMotion.Core;

namespace VeyMotion.App.Editor;

/// <summary>
/// The sidebar's asset library: the active library (the open project's assets, else the shared one) and, inside a
/// project, the read-only Shared tab. Watches the folders so files the agent writes appear live. Double-click adds an
/// asset to the scene at the playhead. Port target of <c>AssetsPanel.swift</c> + <c>AssetLibrary</c>.
/// </summary>
public sealed class AssetsPanel : UserControl
{
    readonly ListView _list = new() { SelectionMode = ListViewSelectionMode.Single };
    readonly ToggleButton _mine = new() { Content = "Library", IsChecked = true };
    readonly ToggleButton _shared = new() { Content = "Shared" };
    readonly TextBlock _empty = new() { Opacity = 0.6, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(14, 8, 14, 0) };
    SceneStore? _store;
    Func<Task<string?>>? _pickFile;
    FileSystemWatcher? _watch, _watchShared;
    DispatcherQueueTimer? _debounce;

    bool ShowingShared => _shared.IsChecked == true && AssetStore.IsProjectLibrary;
    string Library => ShowingShared ? AssetStore.SharedDirectory : AssetStore.Directory;

    public AssetsPanel()
    {
        var import = new Button { Content = new FontIcon { Glyph = "", FontSize = 13 }, Padding = new Thickness(8, 4, 8, 4) };
        ToolTipService.SetToolTip(import, "Import files into the library");
        import.Click += async (_, _) => await Import();
        var open = new Button { Content = new FontIcon { Glyph = "", FontSize = 13 }, Padding = new Thickness(8, 4, 8, 4) };
        ToolTipService.SetToolTip(open, "Show the library folder in Explorer");
        open.Click += (_, _) => { Directory.CreateDirectory(Library); Process.Start("explorer.exe", $"\"{Library}\""); };
        _mine.Click += (_, _) => { _mine.IsChecked = true; _shared.IsChecked = false; Rebuild(); };
        _shared.Click += (_, _) => { _shared.IsChecked = true; _mine.IsChecked = false; Rebuild(); };
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(10, 8, 10, 4), Children = { _mine, _shared, import, open } };
        var root = new Grid { RowDefinitions = { new RowDefinition { Height = GridLength.Auto }, new RowDefinition { Height = GridLength.Auto }, new RowDefinition() } };
        root.Children.Add(bar);
        Grid.SetRow(_empty, 1);
        root.Children.Add(_empty);
        Grid.SetRow(_list, 2);
        root.Children.Add(_list);
        Content = root;
        _list.DoubleTapped += (_, _) => AddSelected();
    }

    public void Attach(SceneStore store, Func<Task<string?>> pickFile)
    {
        _store = store;
        _pickFile = pickFile;
        _debounce = DispatcherQueue.CreateTimer();
        _debounce.Interval = TimeSpan.FromMilliseconds(300);
        _debounce.IsRepeating = false;
        _debounce.Tick += (_, _) => Rebuild();
        store.ProjectChanged += _ => DispatcherQueue.TryEnqueue(() => { Watch(); Rebuild(); });
        store.SceneChanged += () => _shared.Visibility = AssetStore.IsProjectLibrary ? Visibility.Visible : Visibility.Collapsed;
        Watch();
        Rebuild();
    }

    /// <summary>Live updates when files change on disk (FSEvents on macOS).</summary>
    void Watch()
    {
        FileSystemWatcher? Make(string dir)
        {
            try
            {
                Directory.CreateDirectory(dir);
                var w = new FileSystemWatcher(dir) { IncludeSubdirectories = true, EnableRaisingEvents = true };
                void Changed(object? s, EventArgs e) => DispatcherQueue.TryEnqueue(() => { _debounce?.Stop(); _debounce?.Start(); });
                w.Created += Changed; w.Deleted += Changed; w.Renamed += Changed; w.Changed += Changed;
                return w;
            }
            catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException) { return null; }
        }
        _watch?.Dispose();
        _watchShared?.Dispose();
        _watch = Make(AssetStore.Directory);
        _watchShared = AssetStore.IsProjectLibrary ? Make(AssetStore.SharedDirectory) : null;
    }

    void Rebuild()
    {
        _shared.Visibility = AssetStore.IsProjectLibrary ? Visibility.Visible : Visibility.Collapsed;
        if (!AssetStore.IsProjectLibrary) { _mine.IsChecked = true; _shared.IsChecked = false; }
        _mine.Content = AssetStore.IsProjectLibrary ? "Project" : "Library";
        List<AssetInfo> assets;
        try { assets = AssetStore.List(ShowingShared ? AssetStore.SharedDirectory : null); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { assets = []; }
        _list.Items.Clear();
        foreach (var group in assets.GroupBy(a => a.Folder).OrderBy(g => g.Key))
        {
            if (group.Key.Length > 0)
                _list.Items.Add(new ListViewItem { Content = new TextBlock { Text = group.Key, Opacity = 0.6, FontSize = 12 }, IsEnabled = false, MinHeight = 24 });
            foreach (var a in group) _list.Items.Add(Row(a));
        }
        _empty.Text = assets.Count == 0
            ? (ShowingShared ? "The shared library is empty." : "No assets yet. Import files, or ask Claude to find images, icons, music or fonts.")
            : "";
        _empty.Visibility = assets.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    static string Glyph(AssetKind k) => k switch
    {
        AssetKind.Image => "", AssetKind.Video => "", AssetKind.Audio => "", AssetKind.Font => "", AssetKind.Text => "", _ => "",
    };

    ListViewItem Row(AssetInfo a)
    {
        var g = new Grid { ColumnSpacing = 8 };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition());
        g.Children.Add(new FontIcon { Glyph = Glyph(a.Kind), FontSize = 13, Opacity = 0.75 });
        var text = new StackPanel { Children = { new TextBlock { Text = a.FileName, TextTrimming = TextTrimming.CharacterEllipsis },
            new TextBlock { Text = a.Summary, FontSize = 11, Opacity = 0.55, TextTrimming = TextTrimming.CharacterEllipsis } } };
        Grid.SetColumn(text, 1);
        g.Children.Add(text);
        var item = new ListViewItem { Content = g, Tag = a, Padding = new Thickness(12, 2, 8, 2) };
        ToolTipService.SetToolTip(item, a.Path);
        var menu = new MenuFlyout();
        void Add(string label, Action act, bool enabled = true)
        {
            var mi = new MenuFlyoutItem { Text = label, IsEnabled = enabled };
            mi.Click += (_, _) => act();
            menu.Items.Add(mi);
        }
        Add("Add to Scene", () => AddAsset(a), a.Kind is AssetKind.Image or AssetKind.Video or AssetKind.Audio or AssetKind.Font);
        Add("Show in Explorer", () => Process.Start("explorer.exe", $"/select,\"{a.Path}\""));
        if (!ShowingShared)
        {
            Add("Rename…", async () => await Rename(a));
            Add("Move to Recycle Bin", () => Trash(a));
        }
        item.ContextFlyout = menu;
        return item;
    }

    void AddSelected()
    {
        if ((_list.SelectedItem as ListViewItem)?.Tag is AssetInfo a) AddAsset(a);
    }

    /// <summary>Pictures, movies and sounds become layers at the playhead; a font sets the selected text's font (or adds a
    /// text in it), like the macOS Assets panel.</summary>
    void AddAsset(AssetInfo a)
    {
        if (_store == null) return;
        switch (a.Kind)
        {
            case AssetKind.Image: _store.AddLayer(LayerType.Image, a.Path); break;
            case AssetKind.Video: _store.AddLayer(LayerType.Video, a.Path); break;
            case AssetKind.Audio: _store.AddLayer(LayerType.Audio, a.Path); break;
            case AssetKind.Font when DirectWriteFonts.Catalog.AllFamilies().FirstOrDefault(f => a.FontFaces?.Any(x => x.StartsWith(f, StringComparison.OrdinalIgnoreCase)) == true) is { } family:
                if (_store.SelectedLayer is { Type: LayerType.Text } t) _store.UpdateLayer(t.Id, "Change Font", l => l.FontName = family);
                else
                {
                    _store.AddLayer(LayerType.Text);
                    if (_store.SelectedLayer is { } added) _store.UpdateLayer(added.Id, "Change Font", l => { l.FontName = family; l.Text = family; l.FontWeight = "regular"; });
                }
                break;
        }
    }

    async Task Import()
    {
        if (_pickFile == null || await _pickFile() is not { } path) return;
        try { AssetStore.ImportFile(path); }
        catch (Exception e) when (e is AssetException or IOException or UnauthorizedAccessException) { await Message("Cannot import", e.Message); }
        Rebuild();
    }

    async Task Rename(AssetInfo a)
    {
        var box = new TextBox { Text = a.FileName, SelectionStart = 0, SelectionLength = Path.GetFileNameWithoutExtension(a.FileName).Length };
        var dialog = new ContentDialog { Title = "Rename", Content = box, PrimaryButtonText = "Rename", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || box.Text.Trim().Length == 0) return;
        try
        {
            var (from, to) = AssetStore.Rename(a.Path, AssetStore.Join(a.Folder, box.Text.Trim()));
            // Layers follow the file (one undo step), like macOS replacePath.
            _store?.Apply("Rename Asset", s => s.ReplacePath(from, to));
        }
        catch (Exception e) when (e is AssetException or IOException or UnauthorizedAccessException) { await Message("Cannot rename", e.Message); }
        Rebuild();
    }

    void Trash(AssetInfo a)
    {
        try { AssetStore.Trash(a.Path); }
        catch (Exception e) when (e is AssetException or IOException or UnauthorizedAccessException) { _ = Message("Cannot delete", e.Message); }
        Rebuild();
    }

    Task Message(string title, string text) =>
        new ContentDialog { Title = title, Content = text, CloseButtonText = "OK", XamlRoot = XamlRoot }.ShowAsync().AsTask();
}
