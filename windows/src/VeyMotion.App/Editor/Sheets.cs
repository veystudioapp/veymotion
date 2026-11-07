using System.Globalization;
using Microsoft.Graphics.Canvas;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using VeyMotion.App.Media;
using VeyMotion.Core;
using VeyMotion.Mcp;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace VeyMotion.App.Editor;

/// <summary>The Voice-over, Sound effect and Stock sheets. Ports of <c>VoiceOverSheet.swift</c>,
/// <c>SoundEffectSheet.swift</c> and <c>StockBrowser.swift</c>; each edit is one undo step.</summary>
static class Sheets
{
    static readonly MediaPlayer Preview = new();

    static void Play(string path)
    {
        Preview.Source = MediaSource.CreateFromUri(new Uri(path));
        Preview.Play();
    }

    static Task Message(XamlRoot root, string title, string text) =>
        new ContentDialog { Title = title, Content = text, CloseButtonText = "OK", XamlRoot = root }.ShowAsync().AsTask();

    // Voice-over

    public static async Task VoiceOver(XamlRoot root, SceneStore store)
    {
        var speech = new SpeechService();
        var text = new TextBox { Header = "Script", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 120, MaxHeight = 240 };
        var engine = new ComboBox { Header = "Engine", ItemsSource = new[] { "Windows voices (offline, exact word times)", "VieNeu (Vietnamese, needs the VeyMotion server)" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var voices = speech.Voices(null);
        var voice = new ComboBox { Header = "Voice", ItemsSource = voices.Select(v => $"{v.Name} ({v.Language})").ToList(), SelectedIndex = voices.Count > 0 ? 0 : -1, HorizontalAlignment = HorizontalAlignment.Stretch };
        List<VieNeu.Voice> vn = [];
        engine.SelectionChanged += async (_, _) =>
        {
            if (engine.SelectedIndex == 1)
            {
                try { vn = await Task.Run(() => VieNeu.Voices()); voice.ItemsSource = vn.Select(v => v.Label).ToList(); voice.SelectedIndex = vn.Count > 0 ? 0 : -1; }
                catch (SceneException e) { voice.ItemsSource = new[] { e.Message }; }
            }
            else { voice.ItemsSource = voices.Select(v => $"{v.Name} ({v.Language})").ToList(); voice.SelectedIndex = voices.Count > 0 ? 0 : -1; }
        };
        var rate = new Slider { Header = "Speed", Minimum = 0.5, Maximum = 2, StepFrequency = 0.05, Value = 1 };
        var status = new TextBlock { Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
        var dialog = new ContentDialog
        {
            Title = "Voice-over", PrimaryButtonText = "Add at the playhead", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = root,
            Content = new StackPanel { Spacing = 10, MinWidth = 460, Children = { text, engine, voice, rate, status } },
        };
        dialog.PrimaryButtonClick += async (d, e) =>
        {
            var deferral = e.GetDeferral();
            e.Cancel = true;
            if (text.Text.Trim().Length == 0) { status.Text = "Write the script first."; deferral.Complete(); return; }
            status.Text = "Synthesizing…";
            var script = text.Text;
            var useVn = engine.SelectedIndex == 1;
            var voiceId = useVn ? (voice.SelectedIndex >= 0 && voice.SelectedIndex < vn.Count ? vn[voice.SelectedIndex].Id : null)
                : (voice.SelectedIndex >= 0 ? voices[voice.SelectedIndex].Id : null);
            var speed = rate.Value;
            var folder = Path.Combine(AssetStore.Directory, AssetStore.Routed(null, "voice") ?? "voice");
            try
            {
                var result = await Task.Run(() => useVn
                    ? VieNeuResult(script, voiceId, speed, folder)
                    : speech.Synthesize(script, voiceId, null, speed, folder));
                var start = store.Time;
                var layer = new MotionLayer(LayerType.Audio, "vo", "Voice")
                {
                    Role = AudioRole.Voice, Path = result.Path, Start = start, SourceDuration = result.Duration, Transcript = script, Words = result.Words,
                };
                var id = "";
                store.Apply("Add Voice-over", s => { id = s.AddLayer(layer); });
                store.Selection = id;
                d.Hide();
            }
            catch (Exception ex) when (ex is SceneException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException) { status.Text = ex.Message; }
            deferral.Complete();
        };
        await dialog.ShowAsync();
    }

    static VoiceResult VieNeuResult(string text, string? voice, double speed, string folder)
    {
        var (path, duration, words) = VieNeu.Synthesize(text, voice, speed, folder, p => AudioDecoder.Shared.Stereo48k(p) is { } pcm ? pcm.Length / 2.0 / AudioMixer.SampleRate : null);
        return new VoiceResult(path, duration, words, false);
    }

    // Sound effect

    public static async Task SoundEffect(XamlRoot root, SceneStore store)
    {
        var kinds = Enum.GetValues<SynthKind>();
        var kind = new ComboBox { Header = "Sound", ItemsSource = kinds.Select(k => $"{k.Title()} — {k.Use()}").ToList(), SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var duration = new NumberBox { Header = "Duration (s, empty = default)", PlaceholderText = "default", Minimum = 0.03, Maximum = 30, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, Value = double.NaN };
        var pitch = new Slider { Header = "Pitch", Minimum = 0.25, Maximum = 4, StepFrequency = 0.05, Value = 1 };
        var variant = new NumberBox { Header = "Variant", Value = 0, Minimum = 0, Maximum = 99, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var hitAtPlayhead = new CheckBox { Content = "Put its hit on the playhead", IsChecked = true };
        var status = new TextBlock { Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
        SynthResult? last = null;
        SynthSettings Settings() => new(kinds[Math.Max(0, kind.SelectedIndex)])
        {
            Duration = double.IsNaN(duration.Value) ? null : duration.Value, Pitch = pitch.Value, Variant = (int)(double.IsNaN(variant.Value) ? 0 : variant.Value),
        };
        string Folder() => Path.Combine(AssetStore.Directory, AssetStore.Routed(null, SoundSynth.DefaultFolder) ?? SoundSynth.DefaultFolder);
        var preview = new Button { Content = "▶ Preview" };
        preview.Click += async (_, _) =>
        {
            var s = Settings();
            last = await Task.Run(() => SoundSynth.Generate(s, Folder()));
            status.Text = string.Create(CultureInfo.InvariantCulture, $"{last.Duration:0.00}s, hit at {(last.Hits.Count > 0 ? last.Hits[0] : 0):0.00}s");
            Play(last.Path);
        };
        var dialog = new ContentDialog
        {
            Title = "Sound effect", PrimaryButtonText = "Add", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = root,
            Content = new StackPanel { Spacing = 10, MinWidth = 420, Children = { kind, duration, pitch, variant, hitAtPlayhead, preview, status } },
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        var settings = Settings();
        var result = await Task.Run(() => SoundSynth.Generate(settings, Folder()));
        var hit = result.Hits.Count > 0 ? result.Hits[0] : 0;
        var layer = new MotionLayer(LayerType.Audio, $"sfx-{settings.Kind.Json()}", settings.Kind.Title()) { Role = AudioRole.Sfx, Path = result.Path, SourceDuration = result.Duration };
        if (hitAtPlayhead.IsChecked == true)
        {
            layer.Start = store.Time - hit;
            if (layer.Start < 0) { layer.TrimIn = -layer.Start; layer.Start = 0; }
        }
        else layer.Start = store.Time;
        var id = "";
        store.Apply("Add Sound Effect", s => { id = s.AddLayer(layer); });
        store.Selection = id;
    }

    // Stock

    public static async Task Stock(XamlRoot root, SceneStore store)
    {
        var kinds = new[] { StockKind.Photo, StockKind.Illustration, StockKind.Icon, StockKind.Video, StockKind.Music, StockKind.Sound, StockKind.Font };
        var query = new TextBox { PlaceholderText = "Search free photos, icons, music, sounds, fonts…", MinWidth = 300 };
        var kind = new ComboBox { ItemsSource = kinds.Select(k => k.Title()).ToList(), SelectedIndex = 0 };
        var search = new Button { Content = "Search", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        var grid = new GridView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 420, MinWidth = 640 };
        var status = new TextBlock { Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
        List<StockItem> items = [];
        async Task Run()
        {
            if (query.Text.Trim().Length == 0) return;
            status.Text = "Searching…";
            grid.Items.Clear();
            var k = kinds[Math.Max(0, kind.SelectedIndex)];
            var q = query.Text.Trim();
            try
            {
                items = await Task.Run(() => StockSearch.Search(q, k, maxDuration: k == StockKind.Sound ? 0 : null));
                status.Text = items.Count == 0 ? "Nothing found." : $"{items.Count} results. Double-click to import and add.";
                var thumbs = await Task.Run(() => StockSearch.Thumbnails(items));
                for (var i = 0; i < items.Count; i++) grid.Items.Add(await Tile(items[i], thumbs[i]));
            }
            catch (Exception e) when (e is SceneException or HttpRequestException or IOException) { status.Text = e.Message; }
        }
        search.Click += async (_, _) => await Run();
        query.KeyDown += async (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) await Run(); };
        var dialog = new ContentDialog
        {
            Title = "Stock library", PrimaryButtonText = "Import and add", CloseButtonText = "Close", XamlRoot = root,
            Content = new StackPanel { Spacing = 10, Children = { new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { query, kind, search } }, grid, status } },
        };
        async Task Import(ContentDialog d)
        {
            if (grid.SelectedIndex < 0 || grid.SelectedIndex >= items.Count) { status.Text = "Pick a result first."; return; }
            var item = items[grid.SelectedIndex];
            status.Text = "Downloading…";
            try
            {
                if (item.Kind == StockKind.Font)
                {
                    var faces = await Task.Run(() => StockSearch.ImportFont(item, StockImport.Import, null, null));
                    DirectWriteFonts.Catalog.Invalidate();
                    status.Text = $"Imported {string.Join(", ", faces.Select(f => f.Name))}. Use it as a text layer's font.";
                    return;
                }
                var asset = await Task.Run(() => StockSearch.ImportItem(item, StockImport.Import, null, null, null));
                var type = item.Kind switch { StockKind.Video => LayerType.Video, StockKind.Music or StockKind.Sound => LayerType.Audio, _ => LayerType.Image };
                store.AddLayer(type, asset.Path);
                d.Hide();
            }
            catch (Exception e) when (e is SceneException or AssetException or HttpRequestException or IOException) { status.Text = e.Message; }
        }
        grid.DoubleTapped += async (_, _) => await Import(dialog);
        dialog.PrimaryButtonClick += async (d, e) =>
        {
            var deferral = e.GetDeferral();
            e.Cancel = true;
            await Import(d);
            deferral.Complete();
        };
        await dialog.ShowAsync();
    }

    static async Task<UIElement> Tile(StockItem item, byte[]? thumb)
    {
        var panel = new StackPanel { Width = 150, Spacing = 4, Padding = new Thickness(4) };
        if (thumb != null && !item.Kind.IsAudio())
        {
            try
            {
                var image = new BitmapImage();
                using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
                await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(thumb));
                stream.Seek(0);
                if (thumb.Length > 4 && thumb[0] == '<')
                {
                    var svg = new SvgImageSource();
                    await svg.SetSourceAsync(stream);
                    panel.Children.Add(new Image { Source = svg, Height = 100, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform });
                }
                else
                {
                    await image.SetSourceAsync(stream);
                    panel.Children.Add(new Image { Source = image, Height = 100, Stretch = Microsoft.UI.Xaml.Media.Stretch.UniformToFill });
                }
            }
            catch (Exception e) when (e is ArgumentException or System.Runtime.InteropServices.COMException) { }
        }
        else panel.Children.Add(new FontIcon { Glyph = item.Kind.IsAudio() ? "" : "", FontSize = 40, Height = 100 });
        panel.Children.Add(new TextBlock { Text = item.Title, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 12 });
        panel.Children.Add(new TextBlock { Text = item.Credit.License, Opacity = 0.6, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis });
        ToolTipService.SetToolTip(panel, $"{item.Title}\n{item.Credit.Attribution}");
        return panel;
    }
}
