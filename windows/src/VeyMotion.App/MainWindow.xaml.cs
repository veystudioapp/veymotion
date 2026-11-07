using System.Diagnostics;
using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VeyMotion.App.Chat;
using VeyMotion.App.Editor;
using VeyMotion.App.Rendering;
using VeyMotion.Core;
using VeyMotion.Mcp;
using Windows.Foundation;
using Windows.Storage.Pickers;
using Windows.System;

namespace VeyMotion.App;

/// <summary>Editor shell: layers · canvas + transport · inspector/Claude over the timeline and status bar. Port of
/// <c>ContentView</c>.</summary>
public sealed partial class MainWindow : Window
{
    readonly SceneStore _store;
    readonly ChatStore _chat;
    readonly ControlPipeServer _pipe;
    readonly McpHttpServer _http;
    readonly PreviewRenderer _preview;
    readonly LayerCommands _commands;
    readonly Media.AudioPreview _audio = new();
    readonly AnnotationSession _annot = new();
    bool _playing;
    bool _settingScrubber;
    bool _closeConfirmed;
    readonly Stopwatch _clock = new();
    TimeSpan _lastTick;
    double _playhead; // unrounded playback time

    public MainWindow(string? path)
    {
        InitializeComponent();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1560, 940));
        ChatToggleLogo.Content = ClaudeLogo.Create(14);

        AudioAnalysisCache.NeverWaitOnThisThread();
        AudioAnalysisCache.Analyzed += _ => DispatcherQueue.TryEnqueue(() => { _preview?.Purge(); Canvas.Invalidate(); Timeline.Invalidate(); Inspector.Refresh(); });
        _store = new SceneStore(DispatcherQueue, SampleScene.Create());
        _store.SceneChanged += OnSceneChanged;
        _store.TimeChanged += OnTimeChanged;
        _store.SelectionChanged += () => { Canvas.Invalidate(); UpdateStatus(); };
        _chat = new ChatStore(_store, DispatcherQueue);
        Chat.Attach(_chat, _store, () => WinRT.Interop.WindowNative.GetWindowHandle(this));
        _preview = new PreviewRenderer(DispatcherQueue, () => { Canvas.Invalidate(); Timeline.Invalidate(); });

        _commands = new LayerCommands(_store, PickMediaFile, m => _ = ShowMessage("VeyMotion", m));
        Layers.Attach(_store, _commands);
        Assets.Attach(_store, PickAnyFile);
        Inspector.Attach(_store);
        Timeline.Attach(_store);
        Timeline.CachedFrames = () => _lastFrameSize is var (w, h) ? _preview.CachedFrames(_store.Revision, w, h) : [];
        var addMenu = _commands.AddMenu();
        addMenu.Items.Add(new MenuFlyoutSeparator());
        foreach (var (label, glyph, open) in new (string, string, Func<Task>)[]
        {
            ("Voice-over…", "", () => Editor.Sheets.VoiceOver(Content.XamlRoot, _store)),
            ("Sound Effect…", "", () => Editor.Sheets.SoundEffect(Content.XamlRoot, _store)),
            ("Stock Library…", "", () => Editor.Sheets.Stock(Content.XamlRoot, _store)),
        })
        {
            var item = new MenuFlyoutItem { Text = label, Icon = new FontIcon { Glyph = glyph } };
            item.Click += async (_, _) => await open();
            addMenu.Items.Add(item);
        }
        AddButton.Flyout = addMenu;
        var layerMenu = new MenuFlyout();
        layerMenu.Opening += (_, _) =>
        {
            layerMenu.Items.Clear();
            foreach (var item in _commands.LayerMenuItems()) layerMenu.Items.Add(item);
        };
        layerMenu.Items.Add(new MenuFlyoutItem { Text = "…" });
        LayerButton.Flyout = layerMenu;
        _commands.Blocked = () => _annot.Active;
        _commands.InstallAccelerators(Root, () => TypingInTextBox(Root));
        RestorePanels();
        BuildAnnotationBar();

        // The `vmotion` CLI (and so the agent) reaches this window's scene through the control pipe.
        var server = AppServices.CreateServer(_store, () => _store.Project);
        _pipe = new ControlPipeServer(server);
        // MCP over HTTP for other agents (Claude Desktop, Cursor…), like the macOS app.
        _http = new McpHttpServer(server, McpHttpServer.DefaultPort, Environment.GetEnvironmentVariable("VEYMOTION_TOKEN"));
        try
        {
            _pipe.Start();
            PipeStatus.Text = "● vmotion connected";
            var http = "MCP over HTTP is off (port in use)";
            try { _http.Start(); http = $"MCP: {_http.Endpoint}"; }
            catch (System.Net.Sockets.SocketException) { }
            ToolTipService.SetToolTip(PipeStatus, $@"vmotion: \\.\pipe\{_pipe.Name}" + "\n" + http);
        }
        catch (IOException)
        {
            PipeStatus.Text = "Another VeyMotion owns vmotion";
            ToolTipService.SetToolTip(PipeStatus, "Claude and vmotion edit the VeyMotion window that was opened first.");
        }

        OnSceneChanged();
        OnTimeChanged();
        if (path != null) _ = OpenAsync(path);
        AppWindow.Closing += OnClosing;
        Closed += (_, _) =>
        {
            Stop();
            _chat.Shutdown();
            _pipe.Dispose();
            _http.Dispose();
            _preview.Dispose();
            _audio.Dispose();
            Canvas.RemoveFromVisualTree();
        };
    }

    // Document

    void OnSceneChanged()
    {
        var s = _store.Scene;
        SceneTitle.Text = $"{_store.Title}{(_store.IsDirty && _store.Project == null ? " •" : "")}" + (_store.Project != null ? " · project" : "");
        Title = $"VeyMotion — {_store.Title}";
        Scrubber.Maximum = s.Duration;
        UndoButton.IsEnabled = _store.CanUndo;
        RedoButton.IsEnabled = _store.CanRedo;
        ToolTipService.SetToolTip(UndoButton, _store.UndoLabel is { } u ? $"Undo {u} (Ctrl+Z)" : "Undo (Ctrl+Z)");
        ToolTipService.SetToolTip(RedoButton, _store.RedoLabel is { } r ? $"Redo {r} (Ctrl+Shift+Z)" : "Redo (Ctrl+Shift+Z)");
        ShowInExplorerItem.IsEnabled = _store.FilePath != null;
        UpdateTimeLabel();
        UpdateStatus();
        Canvas.Invalidate();
    }

    void UpdateStatus()
    {
        var s = _store.Scene;
        var sel = _store.SelectedLayer is { } l ? $"Selected: {l.Id} ({l.Type.Json()})" : "Nothing selected";
        StatusText.Text = $"{s.Width}×{s.Height} · {s.Fps} fps · {s.Duration:0.##} s · {s.AllLayers.Count()} layers · {sel}"
            + (_store.FilePath is { } p ? $" · {p}" : "");
    }

    async Task OpenAsync(string path)
    {
        try
        {
            Stop();
            _store.Open(path);
        }
        catch (Exception e) when (e is SceneException or IOException or UnauthorizedAccessException)
        {
            await ShowMessage("Cannot open scene", e.Message);
        }
    }

    async Task ShowMessage(string title, string message)
    {
        if (Content.XamlRoot == null) await Task.Yield(); // opened from the command line before the first layout
        await new ContentDialog { Title = title, Content = message, CloseButtonText = "OK", XamlRoot = Content.XamlRoot }.ShowAsync();
    }

    nint Hwnd => WinRT.Interop.WindowNative.GetWindowHandle(this);

    async void Open_Click(object sender, RoutedEventArgs e) => await PickAndOpen();

    async void Open_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await PickAndOpen();
    }

    async Task PickAndOpen()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add(".json");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        if (await picker.PickSingleFileAsync() is { } file) await OpenAsync(file.Path);
    }

    async Task<string?> PickFolder()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        return (await picker.PickSingleFolderAsync())?.Path;
    }

    async void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        if (await PickFolder() is not { } folder) return;
        if (!File.Exists(Path.Combine(folder, SceneStore.SceneFileName)))
        {
            await ShowMessage("Not a project", $"{folder} has no {SceneStore.SceneFileName}. Use New Project to make one there.");
            return;
        }
        await OpenAsync(folder);
    }

    /// <summary>A project is a folder with scene.json and assets/ (Project.swift); it saves itself.</summary>
    async void NewProject_Click(object sender, RoutedEventArgs e)
    {
        if (await PickFolder() is not { } folder) return;
        var scenePath = Path.Combine(folder, SceneStore.SceneFileName);
        if (File.Exists(scenePath)) { await OpenAsync(folder); return; }
        try
        {
            Directory.CreateDirectory(Path.Combine(folder, "assets"));
            var scene = SceneJson.Decode("""{"width":1920,"height":1080,"fps":30,"duration":10,"background":"#0E0E12","layers":[]}""");
            SceneJson.Save(scene, scenePath);
            await OpenAsync(folder);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            await ShowMessage("Cannot create project", ex.Message);
        }
    }

    async void New_Click(object sender, RoutedEventArgs e) => await NewScene();

    async void New_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await NewScene();
    }

    /// <summary>New Scene: a size preset, frame rate and length (the sheet behind ⌘N on macOS).</summary>
    async Task NewScene()
    {
        (string Name, int W, int H)[] sizes = [("Landscape 1920×1080", 1920, 1080), ("Vertical 1080×1920 (Shorts, TikTok, Reels)", 1080, 1920),
            ("Square 1080×1080", 1080, 1080), ("Portrait 1080×1350", 1080, 1350), ("4K 3840×2160", 3840, 2160)];
        var size = new ComboBox { Header = "Size", ItemsSource = sizes.Select(s => s.Name).ToList(), SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var fps = new ComboBox { Header = "Frame rate", ItemsSource = new[] { "24", "25", "30", "50", "60" }, SelectedIndex = 2, HorizontalAlignment = HorizontalAlignment.Stretch };
        var duration = new NumberBox { Header = "Duration (s)", Value = 10, Minimum = 0.5, Maximum = 3600, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var panel = new StackPanel { Spacing = 12, MinWidth = 360, Children = { size, fps, duration } };
        var dialog = new ContentDialog
        {
            Title = "New Scene", Content = panel, PrimaryButtonText = "Create", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (_store.IsDirty && _store.FilePath != null && _store.Project == null && !await ConfirmDiscard()) return;
        var (_, w, h) = sizes[Math.Max(0, size.SelectedIndex)];
        var scene = SceneJson.Decode($$"""{"width":{{w}},"height":{{h}},"fps":{{fps.SelectedItem}},"duration":{{(double.IsNaN(duration.Value) ? 10 : duration.Value).ToString(System.Globalization.CultureInfo.InvariantCulture)}},"background":"#0E0E12","layers":[]}""");
        Stop();
        _store.NewDocument(scene);
    }

    async Task<bool> ConfirmDiscard()
    {
        var answer = await new ContentDialog
        {
            Title = $"Save changes to {_store.Title}?", PrimaryButtonText = "Save", SecondaryButtonText = "Don't Save",
            CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = Content.XamlRoot,
        }.ShowAsync();
        return answer switch
        {
            ContentDialogResult.Primary => await SaveAsync(saveAs: false),
            ContentDialogResult.Secondary => true,
            _ => false,
        };
    }

    void ShowInExplorer_Click(object sender, RoutedEventArgs e)
    {
        if (_store.FilePath is { } p) Process.Start("explorer.exe", $"/select,\"{p}\"");
    }

    async Task<string?> PickMediaFile(LayerType type)
    {
        if (type == LayerType.Video)
        {
            // A movie file, or (cancel) a folder of numbered images.
            var movie = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.VideosLibrary };
            foreach (var ext in new[] { ".mp4", ".mov", ".m4v", ".avi", ".wmv", ".mkv", ".webm" }) movie.FileTypeFilter.Add(ext);
            WinRT.Interop.InitializeWithWindow.Initialize(movie, Hwnd);
            if (await movie.PickSingleFileAsync() is { } f) return f.Path;
            return await PickFolder();
        }
        var picker = new FileOpenPicker
        {
            SuggestedStartLocation = type == LayerType.Audio ? PickerLocationId.MusicLibrary : PickerLocationId.PicturesLibrary,
        };
        var exts = type == LayerType.Audio
            ? new[] { ".wav", ".mp3", ".m4a", ".aac", ".flac", ".ogg", ".wma" }
            : new[] { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".svg" };
        foreach (var ext in exts) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        return (await picker.PickSingleFileAsync())?.Path;
    }

    async void Export_Click(object sender, RoutedEventArgs e) => await ExportVideo();

    async void Publish_Click(object sender, RoutedEventArgs e)
    {
        Stop();
        await Editor.PublishSheet.Show(Content.XamlRoot, _store);
    }

    async void Export_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await ExportVideo();
    }

    /// <summary>Export: size (the scene's, half, or a platform preset with fit/fill), range, then the file; renders in
    /// the background with progress and Cancel. Port target of <c>ExportSheet.swift</c>.</summary>
    async Task ExportVideo()
    {
        Stop();
        var scene = _store.Scene.Clone();
        var sizes = new List<(string Name, ExportOptions Options)>
        {
            ($"Scene size {scene.Width}×{scene.Height}", new ExportOptions()),
            ($"Half size {scene.Width / 2}×{scene.Height / 2}", new ExportOptions { Scale = 0.5 }),
        };
        foreach (var p in PlatformPreset.All) sizes.Add(($"{p.Name} {p.Width}×{p.Height} ({p.AspectLabel})", new ExportOptions { Size = (p.Width, p.Height) }));
        var size = new ComboBox { Header = "Size", ItemsSource = sizes.Select(s => s.Name).ToList(), SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var fit = new ComboBox { Header = "When the aspect ratio differs", ItemsSource = new[] { "Fit (bars in the background color)", "Fill (crop the edges)" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var from = new NumberBox { Header = "From (s)", Value = 0, Minimum = 0, Maximum = scene.Duration, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var to = new NumberBox { Header = "To (s)", Value = scene.Duration, Minimum = 0, Maximum = scene.Duration, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var info = new TextBlock { Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
        ExportOptions Options()
        {
            var o = sizes[Math.Max(0, size.SelectedIndex)].Options;
            var result = new ExportOptions { Scale = o.Scale, Size = o.Size, Fit = fit.SelectedIndex == 1 ? ExportFit.Fill : ExportFit.Fit };
            if (!double.IsNaN(from.Value) && from.Value > 0) result.Start = from.Value;
            if (!double.IsNaN(to.Value) && to.Value < scene.Duration) result.End = to.Value;
            return result;
        }
        void Describe()
        {
            var o = Options();
            var (w, h) = o.PixelSize(scene);
            var (_, count) = o.FrameRange(scene);
            var preset = size.SelectedIndex >= 2 ? PlatformPreset.All[size.SelectedIndex - 2] : null;
            var warnings = preset?.Warnings(scene, (double)count / scene.Fps, o.EstimatedBytes(scene)) ?? [];
            info.Text = $"MP4 (H.264 + AAC) · {w}×{h} · {count} frames · about {o.EstimatedBytes(scene) / 1_000_000.0:0.#} MB"
                + (o.IsReframed(scene) ? (o.Fit == ExportFit.Fit ? " · letterboxed" : " · cropped") : "")
                + (warnings.Count > 0 ? Environment.NewLine + string.Join(Environment.NewLine, warnings) : "");
        }
        size.SelectionChanged += (_, _) => Describe();
        fit.SelectionChanged += (_, _) => Describe();
        from.ValueChanged += (_, _) => Describe();
        to.ValueChanged += (_, _) => Describe();
        Describe();
        var dialog = new ContentDialog
        {
            Title = "Export Video", PrimaryButtonText = "Export…", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
            Content = new StackPanel { Spacing = 12, MinWidth = 420, Children = { size, fit, new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { from, to } }, info } },
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var options = Options();
        var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.VideosLibrary, SuggestedFileName = Path.GetFileNameWithoutExtension(_store.Title) };
        picker.FileTypeChoices.Add("MP4 video", [".mp4"]);
        picker.FileTypeChoices.Add("Sound only (AAC)", [".m4a"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        if (await picker.PickSaveFileAsync() is not { } file) return;

        var bar = new ProgressBar { Maximum = 1, MinWidth = 380 };
        var label = new TextBlock { Text = "Rendering…", Opacity = 0.7 };
        var cancel = new CancellationTokenSource();
        var progressDialog = new ContentDialog
        {
            Title = "Exporting", CloseButtonText = "Cancel", XamlRoot = Content.XamlRoot,
            Content = new StackPanel { Spacing = 10, Children = { bar, label } },
        };
        progressDialog.CloseButtonClick += (_, _) => cancel.Cancel();
        var progress = new Progress<double>(p => { bar.Value = p; label.Text = $"{p * 100:0}%"; });
        _preview.Paused = true;
        var shown = progressDialog.ShowAsync();
        string? error = null;
        var started = DateTime.UtcNow;
        try { await Task.Run(() => Media.VideoExporter.Export(scene, file.Path, options, progress, cancel.Token)); }
        catch (OperationCanceledException) { error = "cancelled"; }
        catch (Exception ex) when (ex is SceneException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException) { error = ex.Message; }
        _preview.Paused = false;
        progressDialog.Hide();
        await shown;
        if (error == "cancelled") return;
        if (error != null) { await ShowMessage("Export failed", error); return; }
        var done = new ContentDialog
        {
            Title = "Exported", Content = $"{file.Path}{Environment.NewLine}{(DateTime.UtcNow - started).TotalSeconds:0.0} s",
            PrimaryButtonText = "Show in Explorer", CloseButtonText = "OK", XamlRoot = Content.XamlRoot,
        };
        if (await done.ShowAsync() == ContentDialogResult.Primary) Process.Start("explorer.exe", $"/select,\"{file.Path}\"");
    }

    async void Save_Click(object sender, RoutedEventArgs e) => await SaveAsync(saveAs: false);
    async void SaveAs_Click(object sender, RoutedEventArgs e) => await SaveAsync(saveAs: true);

    async void Save_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await SaveAsync(saveAs: false);
    }

    async void SaveAs_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await SaveAsync(saveAs: true);
    }

    /// <returns>False when the user cancelled the save dialog or saving failed.</returns>
    async Task<bool> SaveAsync(bool saveAs)
    {
        try
        {
            if (_store.FilePath != null && !saveAs)
            {
                _store.Save();
                return true;
            }
            var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = "scene" };
            picker.FileTypeChoices.Add("VeyMotion scene", [".json"]);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
            if (await picker.PickSaveFileAsync() is not { } file) return false;
            _store.SaveAs(file.Path);
            return true;
        }
        catch (Exception e) when (e is SceneException or IOException or UnauthorizedAccessException)
        {
            await ShowMessage("Cannot save", e.Message);
            return false;
        }
    }

    /// <summary>A project is saved on its own; a loose file with changes asks first.</summary>
    async void OnClosing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        if (_closeConfirmed || !_store.IsDirty) return;
        if (_store.Project != null)
        {
            try { _store.Save(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException or SceneException) { }
            return;
        }
        if (_store.FilePath == null) return; // the untitled demo scene is not kept
        args.Cancel = true;
        if (!await ConfirmDiscard()) return;
        _closeConfirmed = true;
        Close();
    }

    // Undo — text boxes keep Ctrl+Z for their own text.

    static bool TypingInTextBox(UIElement root) => FocusManager.GetFocusedElement(root.XamlRoot) is TextBox;

    void Undo_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (TypingInTextBox(Root)) return;
        args.Handled = true;
        // While annotating, Undo/Redo act on the marks.
        if (_annot.Active) { _annot.Undo(); Canvas.Invalidate(); return; }
        _store.Undo();
    }

    void Redo_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (TypingInTextBox(Root)) return;
        args.Handled = true;
        if (_annot.Active) { _annot.Redo(); Canvas.Invalidate(); return; }
        _store.Redo();
    }

    // Annotation mode (Annotations.swift): pauses, draws marks in scene units over the canvas (never in the scene),
    // and "Add to chat" sends the frame with the marks to Claude.

    void Annotate_Click(object sender, RoutedEventArgs e) => SetAnnotating(AnnotateButton.IsChecked == true);

    void Annotate_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        SetAnnotating(!_annot.Active);
    }

    void SetAnnotating(bool on)
    {
        if (on) { Stop(); _annot.Active = true; } else _annot.Close();
        AnnotateButton.IsChecked = on;
        AnnotationBar.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        Canvas.Invalidate();
    }

    readonly Dictionary<AnnotationSession.Tool, ToggleButton> _toolButtons = [];

    void BuildAnnotationBar()
    {
        (AnnotationSession.Tool Tool, string Glyph, string Tip)[] tools =
        [
            (AnnotationSession.Tool.Select, "", "Select and move marks"), (AnnotationSession.Tool.Pen, "", "Draw"),
            (AnnotationSession.Tool.Rect, "", "Rectangle"), (AnnotationSession.Tool.Ellipse, "", "Ellipse"),
            (AnnotationSession.Tool.Arrow, "", "Arrow"), (AnnotationSession.Tool.Line, "", "Line"),
            (AnnotationSession.Tool.Text, "", "Text note"),
        ];
        foreach (var (tool, glyph, tip) in tools)
        {
            var b = new ToggleButton { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, IsChecked = tool == _annot.Current, Padding = new Thickness(8, 5, 8, 5) };
            ToolTipService.SetToolTip(b, tip);
            b.Click += (_, _) => { _annot.Current = tool; foreach (var (t, btn) in _toolButtons) btn.IsChecked = t == tool; };
            _toolButtons[tool] = b;
            AnnotationTools.Children.Add(b);
        }
        AnnotationTools.Children.Add(new AppBarSeparator());
        foreach (var hex in new[] { "#FF3B30", "#FFCC00", "#34C759", "#0A84FF", "#FFFFFF" })
        {
            var c = Rendering.FrameCompositor.ToColor(Rgba.FromHex(hex)!.Value);
            var swatch = new Button { Width = 24, Height = 24, Padding = new Thickness(0), Background = new SolidColorBrush(c), CornerRadius = new CornerRadius(12) };
            swatch.Click += (_, _) => { _annot.Color = c; if (_annot.Selected != null) { _annot.Record(); _annot.Selected.Color = c; Canvas.Invalidate(); } };
            AnnotationTools.Children.Add(swatch);
        }
        var width = new ComboBox { ItemsSource = new[] { "Thin", "Medium", "Thick" }, SelectedIndex = 1, MinWidth = 90 };
        width.SelectionChanged += (_, _) => _annot.Width = width.SelectedIndex switch { 0 => 3, 2 => 12, _ => 6 };
        AnnotationTools.Children.Add(width);
        AnnotationTools.Children.Add(new AppBarSeparator());
        Button Action(string glyph, string tip, Action act)
        {
            var b = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, Padding = new Thickness(8, 5, 8, 5) };
            ToolTipService.SetToolTip(b, tip);
            b.Click += (_, _) => { act(); Canvas.Invalidate(); };
            return b;
        }
        AnnotationTools.Children.Add(Action("", "Undo (Ctrl+Z)", _annot.Undo));
        AnnotationTools.Children.Add(Action("", "Redo (Ctrl+Shift+Z)", _annot.Redo));
        AnnotationTools.Children.Add(Action("", "Delete the selected mark (Del)", _annot.Delete));
        var send = new Button { Content = "Add to chat", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        send.Click += async (_, _) => await AddAnnotationToChat();
        AnnotationTools.Children.Add(send);
        AnnotationTools.Children.Add(Action("", "Close (Esc)", () => SetAnnotating(false)));
    }

    /// <summary>The frame at up to 1600 px with the marks on top, as a JPEG attachment with a note for Claude.</summary>
    async Task AddAnnotationToChat()
    {
        var scene = _store.Scene.Clone();
        var time = _store.Time;
        var marks = _annot.Items.ToList();
        var scale = Math.Min(1, 1600.0 / Math.Max(scene.Width, scene.Height));
        int pw = Math.Max(1, (int)Math.Round(scene.Width * scale)), ph = Math.Max(1, (int)Math.Round(scene.Height * scale));
        var jpeg = await Task.Run(() =>
        {
            var device = CanvasDevice.GetSharedDevice();
            using var frame = AudioAnalysisCache.WithoutWaiting(() => FrameCompositor.Render(device, scene, time, pw, ph));
            using var output = new CanvasRenderTarget(device, pw, ph, 96);
            using (var ds = output.CreateDrawingSession())
            {
                // JPEG has no alpha: transparent scenes go on black, like the exported .mp4.
                ds.Clear(Windows.UI.Color.FromArgb(255, 0, 0, 0));
                ds.DrawImage(frame);
                ds.Transform = Matrix3x2.CreateScale((float)scale);
                foreach (var m in marks) m.Draw(ds);
            }
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            output.SaveAsync(stream, CanvasBitmapFileFormat.Jpeg, 0.9f).AsTask().GetAwaiter().GetResult();
            var bytes = new byte[stream.Size];
            using var reader = new Windows.Storage.Streams.DataReader(stream.GetInputStreamAt(0));
            reader.LoadAsync((uint)stream.Size).AsTask().GetAwaiter().GetResult();
            reader.ReadBytes(bytes);
            return bytes;
        });
        var note = marks.Count == 0
            ? string.Create(System.Globalization.CultureInfo.InvariantCulture, $"[Attached: the canvas frame at {time:0.00}s.]")
            : string.Create(System.Globalization.CultureInfo.InvariantCulture, $"[Attached: the canvas frame at {time:0.00}s with my annotations drawn on top. ")
              + "The marks (outlines, arrows, scribbles, notes) point at what I mean; they are not part of the scene.]";
        await _chat.AttachImageAsync(jpeg, note, time);
        SetAnnotating(false);
        RightToggle.IsChecked = true;
        ApplyPanels();
        ShowTab(ChatTab);
    }

    Vector2 _annotFrom;

    bool AnnotationPressed(Vector2 sp)
    {
        if (!_annot.Active) return false;
        var tol = 8 / (ViewTransform()?.M11 ?? 1);
        switch (_annot.Current)
        {
            case AnnotationSession.Tool.Select:
                _annot.Selected = _annot.Items.LastOrDefault(m => m.Hit(sp, tol));
                if (_annot.Selected != null) _annot.Record();
                break;
            case AnnotationSession.Tool.Text:
                PromptText(sp);
                return true;
            case AnnotationSession.Tool.Pen:
                _annot.Draft = new Annotation { Stroke = [sp], Color = _annot.Color, Size = SceneSize(_annot.Width) };
                break;
            default:
                var kind = _annot.Current switch
                {
                    AnnotationSession.Tool.Rect => Annotation.ShapeKind.Rect,
                    AnnotationSession.Tool.Ellipse => Annotation.ShapeKind.Ellipse,
                    AnnotationSession.Tool.Arrow => Annotation.ShapeKind.Arrow,
                    _ => Annotation.ShapeKind.Line,
                };
                _annot.Draft = new Annotation { Shape = kind, A = sp, B = sp, Color = _annot.Color, Size = SceneSize(_annot.Width) };
                break;
        }
        _annotFrom = sp;
        Canvas.Invalidate();
        return true;
    }

    /// <summary>A width in screen px as scene px, so marks look the same at any zoom.</summary>
    float SceneSize(float screen) => screen / (ViewTransform()?.M11 ?? 1);

    void AnnotationMoved(Vector2 sp)
    {
        if (_annot.Draft is { } d)
        {
            if (d.Stroke != null) d.Stroke.Add(sp); else d.B = sp;
        }
        else if (_annot.Current == AnnotationSession.Tool.Select && _annot.Selected is { } m)
        {
            var moved = m.Moved(sp - _annotFrom);
            var i = _annot.Items.IndexOf(m);
            if (i >= 0) { _annot.Items[i] = moved; _annot.Selected = moved; }
            _annotFrom = sp;
        }
        Canvas.Invalidate();
    }

    void AnnotationReleased()
    {
        if (_annot.Draft is { } d)
        {
            var big = d.Stroke is { Count: > 1 } || Vector2.Distance(d.A, d.B) > 2;
            if (big) { _annot.Record(); _annot.Items.Add(d); }
            _annot.Draft = null;
        }
        Canvas.Invalidate();
    }

    void PromptText(Vector2 sp)
    {
        var box = new TextBox { PlaceholderText = "Type a note", MinWidth = 220 };
        var flyout = new Flyout { Content = box };
        void Commit()
        {
            if (box.Text.Trim().Length > 0)
            {
                _annot.Record();
                _annot.Items.Add(new Annotation { Text = box.Text.Trim(), A = sp, Color = _annot.Color, Size = SceneSize(_annot.Width * 4 + 8) });
                Canvas.Invalidate();
            }
        }
        box.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) { Commit(); flyout.Hide(); e.Handled = true; } };
        if (ViewTransform() is { } v)
        {
            var p = Vector2.Transform(sp, v);
            flyout.ShowAt(Canvas, new FlyoutShowOptions { Position = new Point(p.X, p.Y) });
        }
    }

    void Undo_Click(object sender, RoutedEventArgs e) => _store.Undo();
    void Redo_Click(object sender, RoutedEventArgs e) => _store.Redo();

    // Panels: visibility and the right side's tab persist (macOS @AppStorage).

    void RestorePanels()
    {
        SidebarToggle.IsChecked = AppSettings.GetString("panel.sidebar") != "hidden";
        TimelineToggle.IsChecked = AppSettings.GetString("panel.timeline") != "hidden";
        RightToggle.IsChecked = AppSettings.GetString("panel.right") != "hidden";
        ShowTab(AppSettings.GetString("panel.tab") == "inspector" ? InspectorTab : ChatTab);
        if (AppSettings.GetString("panel.sidebarTab") == "assets") SidebarTab_Click(AssetsTab, new RoutedEventArgs());
        ApplyPanels();
    }

    void ApplyPanels()
    {
        var sidebar = SidebarToggle.IsChecked == true;
        var timeline = TimelineToggle.IsChecked == true;
        var right = RightToggle.IsChecked == true;
        SidebarHost.Visibility = sidebar ? Visibility.Visible : Visibility.Collapsed;
        SidebarColumn.Width = new GridLength(sidebar ? 230 : 0);
        TimelineHost.Visibility = timeline ? Visibility.Visible : Visibility.Collapsed;
        TimelineRow.Height = new GridLength(timeline ? 230 : 0);
        RightHost.Visibility = right ? Visibility.Visible : Visibility.Collapsed;
        RightColumn.Width = new GridLength(right ? 380 : 0);
        AppSettings.SetString("panel.sidebar", sidebar ? null : "hidden");
        AppSettings.SetString("panel.timeline", timeline ? null : "hidden");
        AppSettings.SetString("panel.right", right ? null : "hidden");
    }

    void PanelToggle_Click(object sender, RoutedEventArgs e) => ApplyPanels();

    void Toggle(ToggleButton b, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        b.IsChecked = b.IsChecked != true;
        ApplyPanels();
    }

    void ToggleSidebar_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => Toggle(SidebarToggle, args);
    void ToggleTimeline_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => Toggle(TimelineToggle, args);
    void ToggleInspector_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => Toggle(RightToggle, args);

    void Tab_Click(object sender, RoutedEventArgs e) => ShowTab((ToggleButton)sender);

    void SidebarTab_Click(object sender, RoutedEventArgs e)
    {
        var assets = ReferenceEquals(sender, AssetsTab);
        LayersTab.IsChecked = !assets;
        AssetsTab.IsChecked = assets;
        Layers.Visibility = assets ? Visibility.Collapsed : Visibility.Visible;
        Assets.Visibility = assets ? Visibility.Visible : Visibility.Collapsed;
        AppSettings.SetString("panel.sidebarTab", assets ? "assets" : null);
    }

    async Task<string?> PickAnyFile()
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Hwnd);
        return (await picker.PickSingleFileAsync())?.Path;
    }

    void ShowTab(ToggleButton tab)
    {
        var inspector = tab == InspectorTab;
        InspectorTab.IsChecked = inspector;
        ChatTab.IsChecked = !inspector;
        Inspector.Visibility = inspector ? Visibility.Visible : Visibility.Collapsed;
        Chat.Visibility = inspector ? Visibility.Collapsed : Visibility.Visible;
        AppSettings.SetString("panel.tab", inspector ? "inspector" : null);
        if (!inspector && Chat.XamlRoot != null) Chat.FocusInput();
    }

    // Playback: advance in whole frames, wrap at the end.

    void Play_Click(object sender, RoutedEventArgs e) => TogglePlay();

    void TogglePlay()
    {
        if (_playing) Stop(); else Play();
    }

    // Transport keys from anywhere but a text box: Space/Enter play, ←/→ step a frame, Home/End (Ctrl+Shift+←)
    // jump. Handled in the tunneling phase so a focused button does not also get clicked.
    void Root_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (TypingInTextBox(Root)) return;
        if (_annot.Active)
        {
            // Annotating: Delete removes the selected mark, Esc leaves, Space does not play.
            if (e.Key is VirtualKey.Delete or VirtualKey.Back) { _annot.Delete(); Canvas.Invalidate(); e.Handled = true; }
            else if (e.Key == VirtualKey.Escape) { SetAnnotating(false); e.Handled = true; }
            else if (e.Key == VirtualKey.Space) e.Handled = true;
            return;
        }
        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var s = _store.Scene;
        switch (e.Key)
        {
            case VirtualKey.Space or VirtualKey.Enter:
                if (e.Key == VirtualKey.Enter && FocusManager.GetFocusedElement(Root.XamlRoot) is ButtonBase or ComboBox) return;
                e.Handled = true;
                if (!e.KeyStatus.WasKeyDown) TogglePlay(); // ignore auto-repeat
                break;
            case VirtualKey.Left when ctrl:
            case VirtualKey.Home:
                e.Handled = true;
                Stop();
                _store.Time = 0;
                break;
            case VirtualKey.End:
                e.Handled = true;
                Stop();
                _store.Time = s.Duration;
                break;
            case VirtualKey.Left or VirtualKey.Right:
                e.Handled = true;
                Stop();
                var frame = Math.Round(_store.Time * s.Fps) + (e.Key == VirtualKey.Right ? 1 : -1);
                _store.Time = Math.Clamp(frame / s.Fps, 0, s.Duration);
                break;
        }
    }

    void Root_PreviewKeyUp(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Space && !TypingInTextBox(Root)) e.Handled = true;
    }

    void Play()
    {
        if (_playing) return;
        if (_store.Time >= _store.Scene.Duration - 1e-6) _store.Time = 0;
        _playing = true;
        _preview.Paused = true;
        PlayIcon.Symbol = Symbol.Pause;
        _clock.Restart();
        _lastTick = TimeSpan.Zero;
        _playhead = _store.Time;
        CompositionTarget.Rendering += OnRendering;
        _audio.Play(_store.Scene, () => _store.Time);
    }

    void Stop()
    {
        if (!_playing) return;
        _playing = false;
        _preview.Paused = false;
        PlayIcon.Symbol = Symbol.Play;
        CompositionTarget.Rendering -= OnRendering;
        _audio.Pause();
        Canvas.Invalidate(); // back to full resolution
    }

    void OnRendering(object? sender, object e)
    {
        var now = _clock.Elapsed;
        _playhead += (now - _lastTick).TotalSeconds;
        _lastTick = now;
        var scene = _store.Scene;
        if (_playhead >= scene.Duration)
        {
            _playhead %= scene.Duration;
            _audio.Play(scene, () => _store.Time); // the loop starts over
        }
        _store.Time = Math.Floor(_playhead * scene.Fps) / scene.Fps;
    }

    void Scrubber_ValueChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        if (_settingScrubber) return;
        Stop();
        _store.Time = Math.Round(e.NewValue * _store.Scene.Fps) / _store.Scene.Fps;
    }

    void OnTimeChanged()
    {
        if (_playing && Math.Abs(_playhead - _store.Time) > 1.0 / _store.Scene.Fps + 1e-6) _playhead = _store.Time; // seeked from the chat
        _settingScrubber = true;
        Scrubber.Value = _store.Time;
        _settingScrubber = false;
        UpdateTimeLabel();
        Canvas.Invalidate();
    }

    void UpdateTimeLabel()
    {
        var frame = (int)Math.Round(_store.Time * _store.Scene.Fps);
        TimeLabel.Text = $"{_store.Time:00.00} / {_store.Scene.Duration:00.00}  f{frame}";
    }

    // Canvas: the frame from the background renderer, the selection on top.

    (int W, int H)? _lastFrameSize;

    /// <summary>Scene px → canvas DIPs (the scene fitted and centered).</summary>
    Matrix3x2? ViewTransform()
    {
        var s = _store.Scene;
        var view = Canvas.Size;
        var fit = Math.Min(view.Width / s.Width, view.Height / s.Height) * 0.96;
        if (!(fit > 0)) return null;
        return Matrix3x2.CreateScale((float)fit) * Matrix3x2.CreateTranslation((float)((view.Width - s.Width * fit) / 2), (float)((view.Height - s.Height * fit) / 2));
    }

    void Canvas_Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        try
        {
            var s = _store.Scene;
            if (ViewTransform() is not { } view) return;
            var ds = args.DrawingSession;
            var dest = new Rect(view.M31, view.M32, s.Width * view.M11, s.Height * view.M22);
            // While playing, at most 1.5 pixels per DIP (the macOS preview does the same).
            var dpi = sender.Dpi / 96f;
            if (_playing) dpi = Math.Min(dpi, 1.5f);
            int pw = Math.Max(1, (int)Math.Round(dest.Width * dpi)), ph = Math.Max(1, (int)Math.Round(dest.Height * dpi));
            _lastFrameSize = (pw, ph);
            if (_preview.Frame(s, _store.Revision, _store.Time, pw, ph) is { } frame) ds.DrawImage(frame, dest);
            else ds.FillRectangle(dest, Windows.UI.Color.FromArgb(255, s.Background.R is var r ? (byte)(r * 255) : (byte)0, (byte)(s.Background.G * 255), (byte)(s.Background.B * 255)));
            if (_annot.Active)
            {
                ds.Transform = view;
                foreach (var m in _annot.Items) m.Draw(ds, m == _annot.Selected);
                _annot.Draft?.Draw(ds);
                ds.Transform = Matrix3x2.Identity;
            }
            else DrawSelection(ds, view);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            // A frame that fails to render must not take the editor (and unsaved work) down with it.
            if (sender.Device.IsDeviceLost(e.HResult)) throw; // Win2D recreates the device
            try { File.AppendAllText(Path.Combine(AppPaths.SupportDirectory, "render-errors.log"), $"{DateTime.Now:O} {e}\n"); }
            catch (IOException) { }
        }
    }

    /// <summary>The selected layer's box, turned and scaled like the layer.</summary>
    void DrawSelection(CanvasDrawingSession ds, Matrix3x2 view)
    {
        if (_store.SelectedLayer is not { } l || !l.Type.IsVisual() || !l.IsVisible(_store.Time, _store.Scene.Duration)) return;
        var s = _store.Scene;
        var t = _store.Time;
        var box = ContentPainter.WipeBox(CanvasDevice.GetSharedDevice(), s, l, t);
        if (box.Width <= 0 && box.Height <= 0) return;
        var m = WorldTransformOf(l, t) * view;
        Vector2[] corners = [new((float)box.X, (float)box.Y), new((float)box.Right, (float)box.Y), new((float)box.Right, (float)box.Bottom), new((float)box.X, (float)box.Bottom)];
        var pts = corners.Select(c => Vector2.Transform(c, m)).ToArray();
        var accent = Windows.UI.Color.FromArgb(255, 77, 150, 255);
        for (var i = 0; i < 4; i++) ds.DrawLine(pts[i], pts[(i + 1) % 4], accent, 1.5f);
        foreach (var p in pts) { ds.FillRectangle(p.X - 4, p.Y - 4, 8, 8, Windows.UI.Color.FromArgb(255, 255, 255, 255)); ds.DrawRectangle(p.X - 4, p.Y - 4, 8, 8, accent); }
    }

    /// <summary>Layer px → scene px for a layer anywhere in the tree (children of groups sit in their group's box).</summary>
    Matrix3x2 WorldTransformOf(MotionLayer l, double t)
    {
        var s = _store.Scene;
        if (s.Layers.Any(x => x.Id == l.Id)) return s.WorldTransform(l, t);
        foreach (var g in s.Layers.Where(x => x.Type == LayerType.Group))
            if (FindIn(g, l.Id, s, t) is { } m) return m;
        return s.WorldTransform(l, t);
    }

    static Matrix3x2? FindIn(MotionLayer group, string id, MotionScene scene, double t)
    {
        var sub = scene.Subscene(group, t);
        var toScene = Matrix3x2.CreateTranslation(-sub.Width / 2f, -sub.Height / 2f) * scene.WorldTransform(group, t);
        foreach (var c in sub.Layers)
        {
            if (c.Id == id) return sub.WorldTransform(c, t) * toScene;
            if (c.Type == LayerType.Group && FindIn(c, id, sub, t) is { } inner) return inner * toScene;
        }
        return null;
    }

    // Canvas: click selects the top-most layer under the pointer, dragging moves it (one undo step).

    string? _dragId;
    Vector2 _dragFrom;
    double _dragX0, _dragY0;
    bool _dragging;

    Vector2? ScenePoint(Point p) => ViewTransform() is { } v && Matrix3x2.Invert(v, out var inv) ? Vector2.Transform(new Vector2((float)p.X, (float)p.Y), inv) : null;

    MotionLayer? HitTest(Vector2 sp)
    {
        var s = _store.Scene;
        var t = _store.Time;
        var device = CanvasDevice.GetSharedDevice();
        foreach (var l in Enumerable.Reverse(s.Layers))
        {
            if (!l.Type.IsVisual() || !l.IsVisible(t, s.Duration) || l.Value(AnimProperty.Opacity, t) <= 0.01) continue;
            if (!Matrix3x2.Invert(s.WorldTransform(l, t), out var inv)) continue;
            var local = Vector2.Transform(sp, inv);
            var box = ContentPainter.WipeBox(device, s, l, t);
            if (box.Contains(new Point(local.X, local.Y))) return l;
        }
        return null;
    }

    void Canvas_PointerPressed(object sender, PointerRoutedEventArgs e)
    {
        Canvas.Focus(FocusState.Pointer);
        if (ScenePoint(e.GetCurrentPoint(Canvas).Position) is not { } sp) return;
        if (AnnotationPressed(sp)) { Canvas.CapturePointer(e.Pointer); return; }
        var hit = HitTest(sp);
        _store.Selection = hit?.Id;
        if (hit == null || hit.MotionPath != null) return;
        Stop();
        _dragId = hit.Id;
        _dragFrom = sp;
        _dragX0 = hit.X.ValueAt(_store.Time);
        _dragY0 = hit.Y.ValueAt(_store.Time);
        _dragging = false;
        Canvas.CapturePointer(e.Pointer);
    }

    void Canvas_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_annot.Active)
        {
            if (e.Pointer.IsInContact && ScenePoint(e.GetCurrentPoint(Canvas).Position) is { } ap) AnnotationMoved(ap);
            return;
        }
        if (_dragId is not { } id || ScenePoint(e.GetCurrentPoint(Canvas).Position) is not { } sp) return;
        var delta = sp - _dragFrom;
        if (!_dragging)
        {
            if (delta.Length() < 3) return;
            _dragging = true;
            _store.BeginInteractive("Move Layer");
        }
        var t = _store.Time;
        _store.UpdateInteractive(s =>
        {
            if (s.FindLayer(id) is not { } l) return;
            // The pointer moves in scene px; x/y live in the parent's space.
            var d = delta;
            if (Matrix3x2.Invert(s.ParentTransform(l, t), out var inv)) d = Vector2.TransformNormal(delta, inv);
            s.SetValue(id, AnimProperty.X, Math.Round(_dragX0 + d.X, 1), t);
            s.SetValue(id, AnimProperty.Y, Math.Round(_dragY0 + d.Y, 1), t);
        });
    }

    void Canvas_PointerReleased(object sender, PointerRoutedEventArgs e)
    {
        Canvas.ReleasePointerCapture(e.Pointer);
        EndCanvasDrag();
    }

    void Canvas_PointerCaptureLost(object sender, PointerRoutedEventArgs e) => EndCanvasDrag();

    void EndCanvasDrag()
    {
        if (_annot.Active) { AnnotationReleased(); return; }
        if (_dragging) _store.EndInteractive();
        _dragging = false;
        _dragId = null;
    }
}
