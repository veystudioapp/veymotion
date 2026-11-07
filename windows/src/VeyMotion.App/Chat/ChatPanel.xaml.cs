using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.RegularExpressions;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using VeyMotion.Mcp;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;
using Windows.System;
using Windows.UI.Core;

namespace VeyMotion.App.Chat;

/// <summary>The Claude panel: transcript, activity line and composer. Port of <c>ChatPanel.swift</c> and
/// <c>ChatComposer.swift</c>: Enter sends, Shift+Enter breaks the line, pasted images become attachments, and dropped
/// or pasted files are written in as their paths.</summary>
public sealed partial class ChatPanel : UserControl
{
    ChatStore? _chat;
    SceneStore? _scene;
    Func<nint>? _windowHandle;
    readonly Dictionary<Guid, (FrameworkElement View, Action Update)> _views = [];
    readonly StackPanel _activityRow;
    readonly TextBlock _activityText = new() { FontSize = 12, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _activityElapsed = new() { FontSize = 12, Opacity = 0.45, FontFamily = new FontFamily("Consolas"), VerticalAlignment = VerticalAlignment.Center };
    readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromSeconds(1) };
    bool _composing;
    bool _settingInput;

    public ChatPanel()
    {
        InitializeComponent();
        HeaderLogo.Content = ClaudeLogo.Create(16);
        ModelLogo.Content = ClaudeLogo.Create(14);
        _activityRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        _activityRow.Children.Add(new ProgressRing { Width = 14, Height = 14, IsActive = true });
        _activityRow.Children.Add(_activityText);
        _activityRow.Children.Add(_activityElapsed);
        _clock.Tick += (_, _) => UpdateElapsed();
    }

    /// <summary>Connects the panel to the stores. <paramref name="windowHandle"/> is for file pickers.</summary>
    public void Attach(ChatStore chat, SceneStore scene, Func<nint> windowHandle)
    {
        _chat = chat;
        _scene = scene;
        _windowHandle = windowHandle;
        chat.ItemsReset += Rebuild;
        chat.ItemAdded += item => { AddView(item); UpdateState(); ScrollToBottom(); };
        chat.ItemChanged += item => { if (_views.TryGetValue(item.Id, out var v)) v.Update(); ScrollToBottom(); };
        chat.Changed += UpdateState;
        Rebuild();
    }

    // Transcript

    void Rebuild()
    {
        if (_chat == null) return;
        ItemsPanel.Children.Clear();
        _views.Clear();
        foreach (var item in _chat.Items) AddView(item);
        UpdateState();
        ScrollToBottom();
    }

    /// <summary>Adds an item's view above the hint/activity rows that <see cref="UpdateState"/> keeps at the end.</summary>
    void AddView(ChatItem item)
    {
        var (view, update) = MakeView(item);
        _views[item.Id] = (view, update);
        var index = ItemsPanel.Children.IndexOf(_activityRow);
        if (index < 0) ItemsPanel.Children.Add(view); else ItemsPanel.Children.Insert(index, view);
    }

    void UpdateState()
    {
        if (_chat == null) return;
        // Empty-chat hint and setup problem at the top.
        ItemsPanel.Children.Remove(_hint ??= EmptyHint());
        ItemsPanel.Children.Remove(_setupNotice ?? new Border());
        if (_chat.SetupProblem is { } problem)
        {
            _setupNotice = Notice(problem, isError: true);
            ItemsPanel.Children.Insert(0, _setupNotice);
        }
        if (_chat.Items.Count == 0) ItemsPanel.Children.Insert(0, _hint);

        // Activity line at the bottom.
        ItemsPanel.Children.Remove(_activityRow);
        if (_chat.Activity is { } activity)
        {
            _activityText.Text = activity;
            ItemsPanel.Children.Add(_activityRow);
            UpdateElapsed();
            _clock.Start();
        }
        else _clock.Stop();

        // Composer.
        if (!_settingInput && InputBox.Text != _chat.Input)
        {
            _settingInput = true;
            InputBox.Text = _chat.Input;
            InputBox.SelectionStart = InputBox.Text.Length;
            _settingInput = false;
        }
        ModelLabel.Text = _chat.ModelEfforts.Count == 0 || _chat.Effort.Length == 0
            ? _chat.ModelLabel : $"{_chat.ModelLabel} · {ChatStore.EffortName(_chat.Effort)}";
        ModelButton.IsEnabled = !_chat.IsBusy;
        SendIcon.Glyph = _chat.IsBusy ? "" : ""; // Stop / Up
        SendIcon.FontSize = _chat.IsBusy ? 10 : 13;
        SendButton.IsEnabled = _chat.IsBusy || _chat.CanSend;
        SendButton.Style = _chat.CanSend && !_chat.IsBusy ? (Style)Application.Current.Resources["AccentButtonStyle"] : null;
        ToolTipService.SetToolTip(SendButton, _chat.IsBusy ? "Stop" : "Send (Enter) · New line (Shift+Enter)");
        UpdateAttachments();
    }

    FrameworkElement? _hint;
    FrameworkElement? _setupNotice;

    void UpdateElapsed()
    {
        if (_chat == null) return;
        // Elapsed time for the current phase, so long steps never look frozen.
        var s = (int)(DateTime.Now - _chat.ActivityStart).TotalSeconds;
        _activityElapsed.Text = s < 3 ? "" : s >= 60 ? $"{s / 60}m {s % 60}s" : $"{s}s";
    }

    void ScrollToBottom()
    {
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            Scroller.UpdateLayout();
            Scroller.ChangeView(null, Scroller.ScrollableHeight, null, disableAnimation: false);
        });
    }

    static FrameworkElement EmptyHint()
    {
        var p = new StackPanel { Spacing = 6, Padding = new Thickness(0, 8, 0, 8) };
        p.Children.Add(new TextBlock { Text = "Describe the animation you want.", TextWrapping = TextWrapping.Wrap });
        foreach (var example in new[]
                 {
                     "• “Make a 6s explainer: title, 3 stats popping in, end card”",
                     "• “Slide the title in from the left at the playhead”",
                     "• “Make everything 20% faster”",
                 })
            p.Children.Add(new TextBlock { Text = example, FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        p.Children.Add(new TextBlock
        {
            Text = "Claude uses your Claude Code login and can only run `vmotion` commands.",
            FontSize = 11, Opacity = 0.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
        });
        return p;
    }

    (FrameworkElement, Action) MakeView(ChatItem item)
    {
        switch (item.Kind)
        {
            case ChatItemKind.User:
            {
                var stack = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(30, 0, 0, 0) };
                if (item.Images.Count > 0)
                {
                    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right };
                    foreach (var a in item.Images)
                        row.Children.Add(Thumbnail(a.Data, item.Images.Count == 1 ? 200 : 90, item.Images.Count == 1 ? 160 : 90, a.Time));
                    stack.Children.Add(row);
                }
                stack.Children.Add(new Border
                {
                    Padding = new Thickness(10, 7, 10, 7),
                    CornerRadius = new CornerRadius(10),
                    HorizontalAlignment = HorizontalAlignment.Right,
                    Background = AccentBrush(0.18),
                    Child = new TextBlock { Text = item.Text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
                });
                return (stack, () => { });
            }

            case ChatItemKind.Assistant:
            {
                var text = new RichTextBlock { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
                void Update()
                {
                    text.Blocks.Clear();
                    text.Blocks.Add(Markdown.Paragraph(item.Text));
                }
                Update();
                return (text, Update);
            }

            case ChatItemKind.Tool:
                return ToolCallView(item.Tool!);

            case ChatItemKind.Image:
            {
                var grid = new Grid { HorizontalAlignment = HorizontalAlignment.Left, MaxWidth = 280 };
                var image = new Image { Source = Bitmap(item.ImageData!), Stretch = Stretch.Uniform };
                grid.Children.Add(new Border
                {
                    CornerRadius = new CornerRadius(6),
                    BorderThickness = new Thickness(1),
                    BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(76, 128, 128, 128)),
                    Child = image,
                });
                if (item.Time is { } t)
                {
                    grid.Children.Add(TimeBadge(t, HorizontalAlignment.Right));
                    ToolTipService.SetToolTip(grid, "Jump to this frame");
                    grid.Tapped += (_, _) => { if (_scene != null) _scene.Time = t; };
                }
                return (grid, () => { });
            }

            case ChatItemKind.Notice:
                return (Notice(item.Text, item.IsError), () => { });

            default: // Summary
                return (new TextBlock { Text = item.Text, FontSize = 11, Opacity = 0.45 }, () => { });
        }
    }

    (FrameworkElement, Action) ToolCallView(ToolCall call)
    {
        var expanded = false;
        var status = new Grid { Width = 14, Height = 14, VerticalAlignment = VerticalAlignment.Center };
        var title = new TextBlock { Text = call.Title, FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        var detail = new TextBlock
        {
            Text = call.Detail, FontSize = 12, FontFamily = new FontFamily("Consolas"), Opacity = 0.65,
            TextTrimming = TextTrimming.CharacterEllipsis, TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center,
        };
        var chevron = new FontIcon { Glyph = "", FontSize = 9, Opacity = 0.45, VerticalAlignment = VerticalAlignment.Center };
        var header = new Grid { ColumnSpacing = 6, Background = new SolidColorBrush(Colors.Transparent) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(status);
        Grid.SetColumn(title, 1); header.Children.Add(title);
        Grid.SetColumn(detail, 2); header.Children.Add(detail);
        Grid.SetColumn(chevron, 3); header.Children.Add(chevron);

        var body = new StackPanel { Spacing = 4, Padding = new Thickness(8), Visibility = Visibility.Collapsed };
        var bodyBorder = new Border
        {
            CornerRadius = new CornerRadius(6), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(20, 128, 128, 128)),
            Child = body, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 4, 0, 0),
        };
        var root = new StackPanel();
        root.Children.Add(header);
        root.Children.Add(bodyBorder);
        var card = new Border
        {
            Padding = new Thickness(8, 5, 8, 5), CornerRadius = new CornerRadius(7),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(15, 128, 128, 128)), Child = root,
        };

        void Update()
        {
            status.Children.Clear();
            if (!call.IsDone) status.Children.Add(new ProgressRing { Width = 12, Height = 12, IsActive = true });
            else status.Children.Add(new FontIcon
            {
                Glyph = call.IsError ? "" : "", FontSize = 13, // StatusErrorFull / CompletedSolid
                Foreground = new SolidColorBrush(call.IsError ? Colors.IndianRed : Colors.MediumSeaGreen),
            });
            chevron.Glyph = expanded ? "" : "";
            bodyBorder.Visibility = body.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
            body.Children.Clear();
            if (!expanded) return;
            if (call.Detail.Length > 0)
                body.Children.Add(new TextBlock
                {
                    Text = call.Detail, FontSize = 12, FontFamily = new FontFamily("Consolas"), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                });
            if (call.Output.Length > 0)
            {
                body.Children.Add(new Rectangle { Height = 1, Fill = new SolidColorBrush(Windows.UI.Color.FromArgb(50, 128, 128, 128)) });
                body.Children.Add(new TextBlock
                {
                    Text = call.Output.Length > 4000 ? call.Output[..4000] : call.Output, FontSize = 12, FontFamily = new FontFamily("Consolas"),
                    TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
                    Foreground = call.IsError ? new SolidColorBrush(Colors.IndianRed) : null, Opacity = call.IsError ? 1 : 0.7,
                });
            }
        }
        header.Tapped += (_, _) => { expanded = !expanded; Update(); };
        Update();
        return (card, Update);
    }

    static Border Notice(string text, bool isError)
    {
        var row = new Grid { ColumnSpacing = 6 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(new FontIcon
        {
            Glyph = isError ? "" : "", FontSize = 13, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0),
            Foreground = isError ? new SolidColorBrush(Colors.Orange) : null, Opacity = isError ? 1 : 0.6,
        });
        var t = new TextBlock { Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        Grid.SetColumn(t, 1);
        row.Children.Add(t);
        return new Border
        {
            Padding = new Thickness(8), CornerRadius = new CornerRadius(6), Child = row,
            Background = new SolidColorBrush(isError ? Windows.UI.Color.FromArgb(26, 255, 165, 0) : Windows.UI.Color.FromArgb(26, 128, 128, 128)),
        };
    }

    static Brush AccentBrush(double opacity)
    {
        var accent = (Windows.UI.Color)Application.Current.Resources["SystemAccentColor"];
        return new SolidColorBrush(accent) { Opacity = opacity };
    }

    static BitmapImage Bitmap(byte[] data)
    {
        var bmp = new BitmapImage();
        var stream = new InMemoryRandomAccessStream();
        stream.WriteAsync(data.AsBuffer()).AsTask().GetAwaiter().GetResult();
        stream.Seek(0);
        _ = bmp.SetSourceAsync(stream);
        return bmp;
    }

    static FrameworkElement Thumbnail(byte[] data, double maxW, double maxH, double? time)
    {
        var grid = new Grid { MaxWidth = maxW, MaxHeight = maxH };
        grid.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(6),
            Child = new Image { Source = Bitmap(data), Stretch = Stretch.Uniform },
        });
        if (time is { } t) grid.Children.Add(TimeBadge(t, HorizontalAlignment.Left));
        return grid;
    }

    /// <summary>The scene time a canvas frame was taken at, over its thumbnail.</summary>
    static Border TimeBadge(double time, HorizontalAlignment align, bool compact = false) => new()
    {
        HorizontalAlignment = align,
        VerticalAlignment = VerticalAlignment.Bottom,
        Margin = new Thickness(4),
        Padding = new Thickness(compact ? 3 : 5, compact ? 1 : 2, compact ? 3 : 5, compact ? 1 : 2),
        CornerRadius = new CornerRadius(8),
        Background = new SolidColorBrush(Windows.UI.Color.FromArgb(166, 0, 0, 0)),
        Child = new TextBlock
        {
            Text = string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{time:0.00}s"),
            FontSize = compact ? 9 : 10, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Colors.White),
        },
    };

    // Attachments

    void UpdateAttachments()
    {
        if (_chat == null) return;
        AttachmentsPanel.Children.Clear();
        foreach (var a in _chat.Attachments)
        {
            var grid = new Grid { Width = 52, Height = 52 };
            grid.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1),
                BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(76, 128, 128, 128)),
                Child = new Image { Source = Bitmap(a.Data), Stretch = Stretch.UniformToFill },
            });
            if (a.Time is { } t) grid.Children.Add(TimeBadge(t, HorizontalAlignment.Left, compact: true));
            var remove = new Button
            {
                Width = 18, Height = 18, Padding = new Thickness(0), CornerRadius = new CornerRadius(9),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, -4, -4, 0),
                Background = new SolidColorBrush(Windows.UI.Color.FromArgb(160, 0, 0, 0)), BorderThickness = new Thickness(0),
                Content = new FontIcon { Glyph = "", FontSize = 8, Foreground = new SolidColorBrush(Colors.White) },
            };
            ToolTipService.SetToolTip(remove, "Remove");
            var id = a.Id;
            remove.Click += (_, _) => _chat.RemoveAttachment(id);
            grid.Children.Add(remove);
            AttachmentsPanel.Children.Add(grid);
        }
        AttachmentsScroller.Visibility = _chat.Attachments.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    async void Attach_Click(object sender, RoutedEventArgs e)
    {
        if (_chat == null || _windowHandle == null) return;
        var picker = new FileOpenPicker { ViewMode = PickerViewMode.Thumbnail, SuggestedStartLocation = PickerLocationId.PicturesLibrary };
        foreach (var ext in new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff" }) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, _windowHandle());
        foreach (var file in await picker.PickMultipleFilesAsync()) await _chat.AttachImageFileAsync(file.Path);
    }

    // Composer

    void InputBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_chat == null || _settingInput) return;
        _chat.Input = InputBox.Text;
        _settingInput = true;
        UpdateState();
        _settingInput = false;
    }

    void InputBox_TextCompositionStarted(TextBox sender, TextCompositionStartedEventArgs args) => _composing = true;
    void InputBox_TextCompositionEnded(TextBox sender, TextCompositionEndedEventArgs args) => _composing = false;

    void InputBox_PreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter || _chat == null) return;
        // While an input method is composing (Vietnamese, Japanese…), Enter belongs to it.
        if (_composing) return;
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
        var alt = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(CoreVirtualKeyStates.Down);
        if (shift || alt) return; // new line
        e.Handled = true;
        _chat.Send();
    }

    async void InputBox_Paste(object sender, TextControlPasteEventArgs e)
    {
        if (_chat == null) return;
        var content = Clipboard.GetContent();
        if (content.Contains(StandardDataFormats.StorageItems))
        {
            e.Handled = true;
            InsertPaths((await content.GetStorageItemsAsync()).Select(i => i.Path).ToList());
            return;
        }
        // A screenshot (Win+Shift+S) or an image copied from a browser/app.
        if (!content.Contains(StandardDataFormats.Text) && content.Contains(StandardDataFormats.Bitmap))
        {
            e.Handled = true;
            var reference = await content.GetBitmapAsync();
            using var stream = await reference.OpenReadAsync();
            var bytes = new byte[stream.Size];
            using (var reader = new DataReader(stream.GetInputStreamAt(0)))
            {
                await reader.LoadAsync((uint)stream.Size);
                reader.ReadBytes(bytes);
            }
            await _chat.AttachImageAsync(bytes);
        }
    }

    /// <summary>Paths as written into the message: space-separated, quoted when they contain spaces.</summary>
    static string PathText(IEnumerable<string> paths) => string.Join(" ", paths.Select(p =>
        p.Any(c => c is ' ' or '\'' or '"') ? "\"" + p.Replace("\"", "\\\"") + "\"" : p));

    /// <summary>Writes paths at the caret, spaced off the text around them.</summary>
    void InsertPaths(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0 || _chat == null) return;
        _chat.AllowReading(paths);
        var text = InputBox.Text;
        var at = Math.Clamp(InputBox.SelectionStart, 0, text.Length);
        var end = Math.Clamp(at + InputBox.SelectionLength, 0, text.Length);
        var lead = at == 0 || char.IsWhiteSpace(text[at - 1]) ? "" : " ";
        var tail = end < text.Length && char.IsWhiteSpace(text[end]) ? "" : " ";
        var insert = lead + PathText(paths) + tail;
        InputBox.Text = text[..at] + insert + text[end..];
        InputBox.SelectionStart = at + insert.Length;
        InputBox.Focus(FocusState.Programmatic);
    }

    void Composer_DragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Copy;
        e.DragUIOverride.Caption = "Insert path";
        ComposerBorder.BorderBrush = AccentBrush(1);
        ComposerBorder.BorderThickness = new Thickness(2);
    }

    void Composer_DragLeave(object sender, DragEventArgs e) => ResetComposerBorder();

    async void Composer_Drop(object sender, DragEventArgs e)
    {
        ResetComposerBorder();
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        InsertPaths((await e.DataView.GetStorageItemsAsync()).Select(i => i.Path).ToList());
    }

    void ResetComposerBorder()
    {
        ComposerBorder.BorderBrush = (Brush)Application.Current.Resources["ControlStrokeColorDefaultBrush"];
        ComposerBorder.BorderThickness = new Thickness(1);
    }

    void SendButton_Click(object sender, RoutedEventArgs e)
    {
        if (_chat == null) return;
        if (_chat.IsBusy) _chat.Stop(); else _chat.Send();
    }

    void NewChat_Click(object sender, RoutedEventArgs e) => _chat?.NewChat();

    /// <summary>Puts the caret in the composer.</summary>
    public void FocusInput() => InputBox.Focus(FocusState.Programmatic);

    // Model picker: main models, then Effort ›, then More models ›.

    void ModelButton_Click(object sender, RoutedEventArgs e)
    {
        if (_chat == null) return;
        var chat = _chat;
        var menu = new MenuFlyout();
        menu.Items.Add(new MenuFlyoutItem { Text = "Model · this session", IsEnabled = false });
        // Aliases (opus, sonnet…) up top; Default and pinned versions under More models.
        var main = chat.Models.Where(m => m.Value.Length > 0 && !m.Value.StartsWith("claude-")).ToList();
        var more = chat.Models.Where(m => m.Value.Length == 0 || m.Value.StartsWith("claude-")).ToList();
        // "Default" is checked on the model it resolves to as well, so the main list always shows one tick.
        bool IsSelected(ClaudeCodeAgent.ModelInfo m, bool inMain) =>
            chat.Model == m.Value || (inMain && chat.Model.Length == 0 && chat.SelectedModel?.ResolvedModel is { } r && m.ResolvedModel == r);
        void Pick(ClaudeCodeAgent.ModelInfo m)
        {
            chat.Model = m.Value;
            // Keep the effort only if the new model accepts it.
            if (chat.Effort.Length > 0 && !m.Efforts.Contains(chat.Effort)) chat.Effort = "";
        }
        MenuFlyoutItemBase ModelItem(ClaudeCodeAgent.ModelInfo m, bool inMain)
        {
            var item = new ToggleMenuFlyoutItem { Text = m.DisplayName, IsChecked = IsSelected(m, inMain) };
            if (m.Description.Length > 0) ToolTipService.SetToolTip(item, m.Description);
            item.Click += (_, _) => Pick(m);
            return item;
        }
        foreach (var m in main) menu.Items.Add(ModelItem(m, true));
        if (chat.ModelEfforts.Count > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var effort = new MenuFlyoutSubItem { Text = $"Effort: {ChatStore.EffortName(chat.Effort)}" };
            foreach (var level in chat.ModelEfforts.Prepend(""))
            {
                var item = new ToggleMenuFlyoutItem { Text = ChatStore.EffortName(level), IsChecked = chat.Effort == level };
                item.Click += (_, _) => chat.Effort = level;
                effort.Items.Add(item);
            }
            menu.Items.Add(effort);
        }
        if (more.Count > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            var sub = new MenuFlyoutSubItem { Text = "More models" };
            foreach (var m in more) sub.Items.Add(ModelItem(m, false));
            menu.Items.Add(sub);
        }
        menu.ShowAt(ModelButton);
    }

    // Versions: the scene after each prompt, newest first; picking one restores it (one undo step).

    void VersionsButton_Click(object sender, RoutedEventArgs e)
    {
        if (_chat == null) return;
        var chat = _chat;
        var panel = new StackPanel { Spacing = 2, Width = 300 };
        panel.Children.Add(new TextBlock { Text = "Versions", FontWeight = FontWeights.SemiBold, Margin = new Thickness(8, 4, 8, 6) });
        var flyout = new Flyout { Content = new ScrollViewer { Content = panel, MaxHeight = 420 } };
        if (chat.Versions.Count == 0)
        {
            panel.Children.Add(new TextBlock
            {
                Text = "Each prompt that changes the scene is kept here, so you can go back to it.",
                FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8, 0, 8, 8),
            });
        }
        foreach (var v in Enumerable.Reverse(chat.Versions))
        {
            var row = new StackPanel { Spacing = 1 };
            row.Children.Add(new TextBlock
            {
                Text = v.Prompt ?? "Before Claude", TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 2, TextWrapping = TextWrapping.Wrap,
                FontStyle = v.Prompt == null ? Windows.UI.Text.FontStyle.Italic : Windows.UI.Text.FontStyle.Normal,
            });
            row.Children.Add(new TextBlock
            {
                Text = $"{v.Date:g} · {v.Scene.Layers.Count} layers", FontSize = 11, Opacity = 0.55,
            });
            var button = new Button
            {
                Content = row, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(8, 5, 8, 5),
            };
            ToolTipService.SetToolTip(button, "Restore this version (Ctrl+Z goes back)");
            button.Click += (_, _) => { chat.Restore(v); flyout.Hide(); };
            panel.Children.Add(button);
        }
        flyout.ShowAt(VersionsButton);
    }
}

/// <summary>The Claude mark (from the macOS app's ClaudeLogo SVG).</summary>
static class ClaudeLogo
{
    const string PathData = "m50.228 170.321 50.357-28.257.843-2.463-.843-1.361h-2.462l-8.426-.518-28.775-.778-24.952-1.037-24.175-1.296-6.092-1.297L0 125.796l.583-3.759 5.12-3.434 7.324.648 16.202 1.101 24.304 1.685 17.629 1.037 26.118 2.722h4.148l.583-1.685-1.426-1.037-1.101-1.037-25.147-17.045-27.22-18.017-14.258-10.37-7.713-5.25-3.888-4.925-1.685-10.758 7-7.713 9.397.649 2.398.648 9.527 7.323 20.35 15.75L94.817 91.9l3.889 3.24 1.555-1.102.195-.777-1.75-2.917-14.453-26.118-15.425-26.572-6.87-11.018-1.814-6.61c-.648-2.723-1.102-4.991-1.102-7.778l7.972-10.823L71.42 0 82.05 1.426l4.472 3.888 6.61 15.101 10.694 23.786 16.591 32.34 4.861 9.592 2.592 8.879.973 2.722h1.685v-1.556l1.36-18.211 2.528-22.36 2.463-28.776.843-8.1 4.018-9.722 7.971-5.25 6.222 2.981 5.12 7.324-.713 4.73-3.046 19.768-5.962 30.98-3.889 20.739h2.268l2.593-2.593 10.499-13.934 17.628-22.036 7.778-8.749 9.073-9.657 5.833-4.601h11.018l8.1 12.055-3.628 12.443-11.342 14.388-9.398 12.184-13.48 18.147-8.426 14.518.778 1.166 2.01-.194 30.46-6.481 16.462-2.982 19.637-3.37 8.88 4.148.971 4.213-3.5 8.62-20.998 5.184-24.628 4.926-36.682 8.685-.454.324.519.648 16.526 1.555 7.065.389h17.304l32.21 2.398 8.426 5.574 5.055 6.805-.843 5.184-12.962 6.611-17.498-4.148-40.83-9.721-14-3.5h-1.944v1.167l11.666 11.406 21.387 19.314 26.767 24.887 1.36 6.157-3.434 4.86-3.63-.518-23.526-17.693-9.073-7.972-20.545-17.304h-1.36v1.814l4.73 6.935 25.017 37.59 1.296 11.536-1.814 3.76-6.481 2.268-7.13-1.297-14.647-20.544-15.1-23.138-12.185-20.739-1.49.843-7.194 77.448-3.37 3.953-7.778 2.981-6.48-4.925-3.436-7.972 3.435-15.749 4.148-20.544 3.37-16.333 3.046-20.285 1.815-6.74-.13-.454-1.49.194-15.295 20.999-23.267 31.433-18.406 19.702-4.407 1.75-7.648-3.954.713-7.064 4.277-6.286 25.47-32.405 15.36-20.092 9.917-11.6-.065-1.686h-.583L44.07 198.125l-12.055 1.555-5.185-4.86.648-7.972 2.463-2.593 20.35-13.999-.064.065Z";

    public static FrameworkElement Create(double size)
    {
        try
        {
            var path = (Microsoft.UI.Xaml.Shapes.Path)XamlReader.Load(
                $"<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Fill='#D97757' Stretch='Uniform' Data='{PathData}'/>");
            path.Width = size;
            path.Height = size;
            return path;
        }
        catch (Exception)
        {
            return new FontIcon { Glyph = "", FontSize = size, Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 0xD9, 0x77, 0x57)) };
        }
    }
}

/// <summary>Inline markdown for assistant replies (bold, italic, code, links), like SwiftUI's
/// <c>inlineOnlyPreservingWhitespace</c>.</summary>
static partial class Markdown
{
    [GeneratedRegex(@"\*\*(.+?)\*\*|__(.+?)__|`([^`]+)`|\[([^\]]+)\]\((https?://[^)\s]+)\)|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])|(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)")]
    private static partial Regex Inline();

    public static Paragraph Paragraph(string text)
    {
        var p = new Paragraph();
        var last = 0;
        foreach (Match m in Inline().Matches(text))
        {
            if (m.Index > last) p.Inlines.Add(new Run { Text = text[last..m.Index] });
            if (m.Groups[1].Success || m.Groups[2].Success)
                p.Inlines.Add(new Bold { Inlines = { new Run { Text = m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value } } });
            else if (m.Groups[3].Success)
                p.Inlines.Add(new Run { Text = m.Groups[3].Value, FontFamily = new FontFamily("Consolas") });
            else if (m.Groups[4].Success)
            {
                var link = new Hyperlink { NavigateUri = new Uri(m.Groups[5].Value) };
                link.Inlines.Add(new Run { Text = m.Groups[4].Value });
                p.Inlines.Add(link);
            }
            else
                p.Inlines.Add(new Italic { Inlines = { new Run { Text = m.Groups[6].Success ? m.Groups[6].Value : m.Groups[7].Value } } });
            last = m.Index + m.Length;
        }
        if (last < text.Length) p.Inlines.Add(new Run { Text = text[last..] });
        return p;
    }
}
