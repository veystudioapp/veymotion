using System.Diagnostics;
using Microsoft.Graphics.Canvas;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using VeyMotion.App.Media;
using VeyMotion.App.Rendering;
using VeyMotion.Core;
using VeyMotion.Mcp;

namespace VeyMotion.App.Editor;

/// <summary>
/// Publish: pick a platform and account (connected through the VeyMotion server's OAuth broker; tokens in Windows
/// Credential Manager), write the title/description (or let Claude write them), then the scene is rendered at the
/// platform's size and uploaded with a thumbnail. UI-only on purpose: no MCP tool posts. Port target of
/// <c>PublishSheet.swift</c> / <c>PublishStore</c>.
/// </summary>
static class PublishSheet
{
    static readonly SocialPlatform[] Platforms = Enum.GetValues<SocialPlatform>();

    public static async Task Show(XamlRoot root, SceneStore store)
    {
        var scene = store.Scene.Clone();
        var platform = new ComboBox { Header = "Platform", ItemsSource = Platforms.Select(p => p.Name()).ToList(), HorizontalAlignment = HorizontalAlignment.Stretch };
        var account = new ComboBox { Header = "Account", HorizontalAlignment = HorizontalAlignment.Stretch };
        var connect = new Button { Content = "Connect…" };
        var disconnect = new Button { Content = "Disconnect" };
        var page = new ComboBox { Header = "Facebook Page", HorizontalAlignment = HorizontalAlignment.Stretch, Visibility = Visibility.Collapsed };
        var title = new TextBox { Header = "Title / caption", Text = Path.GetFileNameWithoutExtension(store.Title) };
        var description = new TextBox { Header = "Description", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 80, MaxHeight = 160 };
        var tags = new TextBox { Header = "Tags (comma separated)" };
        var privacy = new ComboBox { Header = "YouTube privacy", ItemsSource = new[] { "private", "unlisted", "public" }, SelectedIndex = 0 };
        var thumbAt = new NumberBox { Header = "Thumbnail frame (s)", Value = Math.Round(scene.Duration / 2, 2), Minimum = 0, Maximum = scene.Duration, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        var write = new Button { Content = "✦ Write with Claude" };
        var status = new TextBlock { Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
        var bar = new ProgressBar { Maximum = 1, Visibility = Visibility.Collapsed };
        List<SocialAccount> accounts = [];
        SocialPlatform Platform() => Platforms[Math.Max(0, platform.SelectedIndex)];

        void LoadAccounts()
        {
            var p = Platform();
            accounts = SocialAuth.Accounts(p);
            account.ItemsSource = accounts.Select(a => a.DisplayName ?? a.UserId ?? a.Key).ToList();
            var active = PublishSettings.ResolveActive(p, accounts);
            account.SelectedIndex = active == null ? (accounts.Count > 0 ? 0 : -1) : accounts.IndexOf(active);
            disconnect.IsEnabled = accounts.Count > 0;
            privacy.Visibility = p == SocialPlatform.Youtube ? Visibility.Visible : Visibility.Collapsed;
            description.Visibility = p is SocialPlatform.Youtube or SocialPlatform.Facebook ? Visibility.Visible : Visibility.Collapsed;
            UpdatePages();
            status.Text = accounts.Count == 0 ? $"Connect a {p.Name()} account to publish." : "";
        }
        void UpdatePages()
        {
            var a = account.SelectedIndex >= 0 && account.SelectedIndex < accounts.Count ? accounts[account.SelectedIndex] : null;
            var pages = a?.Pages ?? [];
            page.Visibility = Platform() == SocialPlatform.Facebook && pages.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            page.ItemsSource = pages.Select(x => x.Name).ToList();
            page.SelectedIndex = pages.Count > 0 ? 0 : -1;
        }
        platform.SelectionChanged += (_, _) => { PublishSettings.Set("publish.platform", Platform().RawValue()); LoadAccounts(); };
        account.SelectionChanged += (_, _) =>
        {
            if (account.SelectedIndex >= 0 && account.SelectedIndex < accounts.Count) PublishSettings.SetActiveAccount(Platform(), accounts[account.SelectedIndex].Key);
            UpdatePages();
        };
        connect.Click += async (_, _) =>
        {
            status.Text = "Finish signing in in your browser…";
            try
            {
                await SocialAuth.ConnectAsync(Platform(), url => { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); return true; });
                LoadAccounts();
                status.Text = "Connected.";
            }
            catch (PublishException e) { status.Text = e.Message; }
        };
        disconnect.Click += (_, _) =>
        {
            if (account.SelectedIndex >= 0 && account.SelectedIndex < accounts.Count) SocialAuth.Disconnect(accounts[account.SelectedIndex]);
            LoadAccounts();
        };
        write.Click += async (_, _) =>
        {
            status.Text = "Claude is writing…";
            write.IsEnabled = false;
            try
            {
                var draft = new PublishCopy(title.Text, description.Text, tags.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
                var copy = await PublishCopywriter.WriteAsync(scene, store.Title, Platform(), draft, "");
                title.Text = Platform() is SocialPlatform.Tiktok or SocialPlatform.X && copy.Caption.Length > 0 ? copy.Caption : copy.Title;
                description.Text = copy.Description;
                tags.Text = string.Join(", ", copy.Tags ?? []);
                status.Text = "";
            }
            catch (PublishException e) { status.Text = e.Message; }
            write.IsEnabled = true;
        };
        var saved = PublishSettings.Get("publish.platform");
        platform.SelectedIndex = Math.Max(0, Array.FindIndex(Platforms, p => p.RawValue() == saved));
        LoadAccounts();

        var dialog = new ContentDialog
        {
            Title = "Publish Video", PrimaryButtonText = "Publish", CloseButtonText = "Close", DefaultButton = ContentDialogButton.Primary, XamlRoot = root,
            Content = new ScrollViewer
            {
                MaxHeight = 620,
                Content = new StackPanel
                {
                    Spacing = 10, MinWidth = 480,
                    Children =
                    {
                        platform, new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { connect, disconnect } }, account, page,
                        title, description, tags, privacy, thumbAt, write, bar, status,
                    },
                },
            },
        };
        var cancel = new CancellationTokenSource();
        dialog.CloseButtonClick += (_, _) => cancel.Cancel();
        dialog.PrimaryButtonClick += async (d, e) =>
        {
            var deferral = e.GetDeferral();
            e.Cancel = true;
            try
            {
                var p = Platform();
                if (account.SelectedIndex < 0 || account.SelectedIndex >= accounts.Count) { status.Text = $"Connect a {p.Name()} account first."; return; }
                var key = accounts[account.SelectedIndex].Key;
                bar.Visibility = Visibility.Visible;
                bar.Value = 0;
                // The scene at the platform's size (bars when the aspect differs), then the thumbnail, then the upload.
                var file = Path.Combine(Path.GetTempPath(), $"veymotion-publish-{Guid.NewGuid():N}.mp4");
                var options = new ExportOptions();
                if (p.MatchingPreset(scene) is { } preset && (preset.Width != scene.Width || preset.Height != scene.Height)) options.Size = (preset.Width, preset.Height);
                status.Text = "Rendering…";
                var ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
                await Task.Run(() => VideoExporter.Export(scene, file, options, new Progress<double>(v => ui.TryEnqueue(() => bar.Value = v * 0.3)), cancel.Token));
                var thumb = await Task.Run(() => Thumbnail(scene, double.IsNaN(thumbAt.Value) ? scene.Duration / 2 : thumbAt.Value));
                var req = new PublishRequest(file, title.Text.Trim())
                {
                    Description = description.Text, Tags = tags.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList(),
                    YoutubePrivacy = (string)privacy.SelectedItem, Thumbnail = thumb,
                    FacebookPageId = page.SelectedIndex >= 0 ? accounts[account.SelectedIndex].Pages?[page.SelectedIndex].Id : null,
                };
                status.Text = "Uploading…";
                var result = await SocialPublisher.PublishAsync(p, key, req, (v, message) => ui.TryEnqueue(() => { bar.Value = 0.3 + v * 0.7; status.Text = message; }), cancel.Token);
                try { File.Delete(file); } catch (IOException) { }
                bar.Value = 1;
                status.Text = $"Published to {p.Name()}" + (result.Url is { } url ? $": {url}" : "") + (result.Note is { } note ? $"\n{note}" : "");
                if (result.Url is { } link) Process.Start(new ProcessStartInfo(link) { UseShellExecute = true });
            }
            catch (OperationCanceledException) { status.Text = "Publishing cancelled"; }
            catch (Exception ex) when (ex is PublishException or SceneException or IOException or System.Runtime.InteropServices.COMException) { status.Text = ex.Message; }
            finally { deferral.Complete(); }
        };
        await dialog.ShowAsync();
    }

    /// <summary>A JPEG of the frame at t, at most 1280 px and 2 MB (PublishThumbnail).</summary>
    static byte[]? Thumbnail(MotionScene scene, double t)
    {
        var device = CanvasDevice.GetSharedDevice();
        var k = Math.Min(1, (double)PublishThumbnail.MaxSide / Math.Max(scene.Width, scene.Height));
        int w = Math.Max(1, (int)(scene.Width * k)), h = Math.Max(1, (int)(scene.Height * k));
        using var frame = FrameCompositor.Render(device, scene, t, w, h);
        using var flat = new CanvasRenderTarget(device, w, h, 96);
        using (var ds = flat.CreateDrawingSession()) { ds.Clear(Windows.UI.Color.FromArgb(255, 0, 0, 0)); ds.DrawImage(frame); }
        foreach (var q in PublishThumbnail.Qualities)
        {
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            flat.SaveAsync(stream, CanvasBitmapFileFormat.Jpeg, (float)q).AsTask().GetAwaiter().GetResult();
            var bytes = new byte[stream.Size];
            using var reader = new Windows.Storage.Streams.DataReader(stream.GetInputStreamAt(0));
            reader.LoadAsync((uint)stream.Size).AsTask().GetAwaiter().GetResult();
            reader.ReadBytes(bytes);
            if (bytes.Length <= PublishThumbnail.MaxBytes) return bytes;
        }
        return null;
    }
}
