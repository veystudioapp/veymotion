using System.Numerics;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using VeyMotion.Core;
using Windows.Foundation;
using Windows.UI;
using Colors = Microsoft.UI.Colors;

namespace VeyMotion.App.Editor;

/// <summary>
/// The timeline: a ruler (click or drag to seek), one row per top-level layer (top-most first) with its time bar and
/// keyframes. Drag a bar to move the layer in time (its keyframes follow), its ends to trim, a keyframe to retime it;
/// Ctrl+wheel zooms, wheel scrolls. Every drag is one undo step. Port target of <c>TimelinePanel.swift</c>.
/// </summary>
public sealed class TimelinePanel : UserControl
{
    const float Ruler = 26, RowH = 26, LabelW = 170;
    readonly CanvasControl _canvas = new() { UseSharedDevice = true, ClearColor = Color.FromArgb(255, 24, 24, 28) };
    SceneStore? _store;
    float _pxPerSec = 120;
    float _scrollX, _scrollY;
    /// <summary>Frames the RAM preview holds (drawn as a green strip on the ruler).</summary>
    public Func<IReadOnlyCollection<int>>? CachedFrames { get; set; }

    enum DragKind { None, Seek, Move, TrimStart, TrimEnd, Key }
    DragKind _drag;
    string? _dragId;
    double _dragT0, _dragKeyT, _lastKeyT;
    Point _dragStart;

    public TimelinePanel()
    {
        Content = _canvas;
        _canvas.Draw += Draw;
        _canvas.PointerPressed += Pressed;
        _canvas.PointerMoved += Moved;
        _canvas.PointerReleased += Released;
        _canvas.PointerCaptureLost += (_, _) => EndDrag();
        _canvas.PointerWheelChanged += Wheel;
        _canvas.RightTapped += KeyMenu;
        Unloaded += (_, _) => _canvas.RemoveFromVisualTree();
    }

    public void Attach(SceneStore store)
    {
        _store = store;
        store.SceneChanged += Invalidate;
        store.TimeChanged += Invalidate;
        store.SelectionChanged += Invalidate;
    }

    public void Invalidate() => _canvas.Invalidate();

    List<MotionLayer> Rows => _store == null ? [] : Enumerable.Reverse(_store.Scene.Layers).ToList();

    float X(double t) => LabelW + (float)t * _pxPerSec - _scrollX;
    double TimeAt(double x) => Math.Max(0, (x - LabelW + _scrollX) / _pxPerSec);

    static double End(MotionLayer l, MotionScene s) => l.EffectiveEnd(s.Duration);

    void Draw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        if (_store == null) return;
        var ds = args.DrawingSession;
        var s = _store.Scene;
        float w = (float)sender.Size.Width, h = (float)sender.Size.Height;
        using var small = new CanvasTextFormat { FontSize = 11, FontFamily = "Segoe UI Variable Text", WordWrapping = CanvasWordWrapping.NoWrap };
        using var label = new CanvasTextFormat { FontSize = 12, FontFamily = "Segoe UI Variable Text", WordWrapping = CanvasWordWrapping.NoWrap, TrimmingGranularity = CanvasTextTrimmingGranularity.Character };
        var dim = Color.FromArgb(255, 120, 120, 132);
        var line = Color.FromArgb(255, 44, 44, 52);

        // Rows
        var rows = Rows;
        for (var i = 0; i < rows.Count; i++)
        {
            var l = rows[i];
            var y = Ruler + i * RowH - _scrollY;
            if (y + RowH < Ruler || y > h) continue;
            var selected = l.Id == _store.Selection;
            if (selected) ds.FillRectangle(0, y, w, RowH, Color.FromArgb(255, 36, 38, 52));
            ds.DrawLine(0, y + RowH, w, y + RowH, line);
            float x0 = X(l.Start), x1 = X(End(l, s));
            var bar = l.Type switch
            {
                LayerType.Text => Color.FromArgb(255, 86, 120, 220),
                LayerType.Image or LayerType.Video => Color.FromArgb(255, 70, 150, 120),
                LayerType.Audio => Color.FromArgb(255, 150, 110, 200),
                LayerType.Group => Color.FromArgb(255, 120, 120, 140),
                LayerType.Particles or LayerType.Generator => Color.FromArgb(255, 200, 130, 70),
                _ => Color.FromArgb(255, 108, 92, 231),
            };
            if (!selected) bar.A = 170;
            ds.FillRoundedRectangle(new Rect(x0, y + 4, Math.Max(2, x1 - x0), RowH - 8), 4, 4, bar);
            // Sound: the loudness as a waveform inside the bar (once the file is analyzed).
            if (l.Type is LayerType.Audio or LayerType.Video && l.Path is { } path
                && AudioAnalysisCache.Analysis(path, wait: false) is { } an && AudioAnalysisCache.Envelope(path, AudioBand.Level, 0.05) is { } env)
            {
                var wave = Color.FromArgb(150, 255, 255, 255);
                for (var x = Math.Max(x0, LabelW); x < Math.Min(x1, w); x += 2)
                {
                    var ft = TimeAt(x) - l.Start + l.TrimIn;
                    if (ft < 0 || ft > an.Duration) continue;
                    var v = (float)AudioAnalysis.Sample(env, ft) * (RowH - 10) / 2;
                    if (v > 0.5f) ds.DrawLine(x, y + RowH / 2 - v, x, y + RowH / 2 + v, wave, 1.2f);
                }
            }
            foreach (var kt in l.KeyframeTimes)
            {
                var kx = X(kt);
                var c = new Vector2(kx, y + RowH / 2);
                var diamond = new[] { c + new Vector2(0, -5), c + new Vector2(5, 0), c + new Vector2(0, 5), c + new Vector2(-5, 0) };
                using var geo = Microsoft.Graphics.Canvas.Geometry.CanvasGeometry.CreatePolygon(ds, diamond);
                ds.FillGeometry(geo, Color.FromArgb(255, 255, 210, 90));
                ds.DrawGeometry(geo, Color.FromArgb(255, 40, 30, 10), 1);
            }
        }

        // Ruler (drawn over the rows when scrolled)
        ds.FillRectangle(0, 0, w, Ruler, Color.FromArgb(255, 30, 30, 36));
        if (CachedFrames?.Invoke() is { Count: > 0 } cached)
        {
            var fw = Math.Max(1, _pxPerSec / s.Fps);
            foreach (var f in cached) ds.FillRectangle(X((double)f / s.Fps), Ruler - 3, fw, 3, Color.FromArgb(255, 60, 200, 110));
        }
        var step = _pxPerSec >= 80 ? 1.0 : _pxPerSec >= 30 ? 2 : 5;
        for (var t = 0.0; t <= s.Duration + 1e-9; t += step / 2)
        {
            var x = X(t);
            if (x < LabelW - 1 || x > w) continue;
            var major = Math.Abs(t / step - Math.Round(t / step)) < 1e-6;
            ds.DrawLine(x, major ? 12 : 18, x, Ruler, dim);
            if (major) ds.DrawText($"{t:0}s", x + 3, 2, dim, small);
        }
        // Beats of the music (the first music layer, else the first audio layer): bars brighter, on the ruler and across.
        var music = s.AllLayers.Where(x => x.Type == LayerType.Audio && x.Path != null).OrderBy(x => x.Role == AudioRole.Music ? 0 : 1).FirstOrDefault();
        if (music != null && AudioAnalysisCache.Analysis(music.Path!, wait: false) is { } ma)
        {
            var offset = music.Start - music.TrimIn;
            var downs = ma.Downbeats.ToHashSet();
            foreach (var b in ma.Beats)
            {
                var st = b + offset;
                if (st < music.Start || st > music.EffectiveEnd(s.Duration)) continue;
                var bx = X(st);
                if (bx < LabelW || bx > w) continue;
                var strong = downs.Contains(b);
                ds.DrawLine(bx, Ruler, bx, h, Color.FromArgb((byte)(strong ? 60 : 26), 255, 210, 90), 1);
                ds.DrawLine(bx, strong ? 14 : 19, bx, Ruler, Color.FromArgb(255, 255, 210, 90), strong ? 1.5f : 1);
            }
        }
        // Scene end
        var endX = X(s.Duration);
        ds.FillRectangle(endX, Ruler, Math.Max(0, w - endX), h, Color.FromArgb(120, 0, 0, 0));

        // Labels column
        ds.FillRectangle(0, 0, LabelW, h, Color.FromArgb(255, 28, 28, 33));
        ds.DrawLine(LabelW, 0, LabelW, h, line);
        for (var i = 0; i < rows.Count; i++)
        {
            var y = Ruler + i * RowH - _scrollY;
            if (y + RowH < Ruler || y > h) continue;
            var l = rows[i];
            var color = l.Id == _store.Selection ? Colors.White : Color.FromArgb(255, 200, 200, 210);
            using var layout = new CanvasTextLayout(ds, l.Name.Length > 0 ? l.Name : l.Id, label, LabelW - 20, RowH) { TrimmingSign = CanvasTrimmingSign.Ellipsis };
            ds.DrawTextLayout(layout, 12, y + 5, color);
        }
        ds.FillRectangle(0, 0, LabelW, Ruler, Color.FromArgb(255, 30, 30, 36));
        var frame = (int)Math.Round(_store.Time * s.Fps);
        ds.DrawText($"{_store.Time:0.00}s  f{frame}", 12, 5, Colors.White, small);

        // Playhead
        var px = X(_store.Time);
        if (px >= LabelW)
        {
            ds.DrawLine(px, 0, px, h, Color.FromArgb(255, 255, 77, 109), 1.5f);
            ds.FillRectangle(px - 5, 0, 10, 8, Color.FromArgb(255, 255, 77, 109));
        }
    }

    // Interaction

    (MotionLayer? Layer, int Row) RowAt(double y)
    {
        var rows = Rows;
        var i = (int)Math.Floor((y - Ruler + _scrollY) / RowH);
        return i >= 0 && i < rows.Count ? (rows[i], i) : (null, -1);
    }

    void Pressed(object sender, PointerRoutedEventArgs e)
    {
        if (_store == null) return;
        var p = e.GetCurrentPoint(_canvas).Position;
        _canvas.CapturePointer(e.Pointer);
        _dragStart = p;
        if (p.Y < Ruler && p.X > LabelW)
        {
            _drag = DragKind.Seek;
            Seek(p.X);
            return;
        }
        var (l, row) = RowAt(p.Y);
        if (l == null) { _store.Selection = null; return; }
        _store.Selection = l.Id;
        if (p.X < LabelW) return;
        _dragId = l.Id;
        var s = _store.Scene;
        // A keyframe under the pointer, else the bar's ends, else the bar.
        var key = l.KeyframeTimes.Where(kt => Math.Abs(X(kt) - p.X) <= 6).Select(kt => (double?)kt).FirstOrDefault();
        if (key is { } kt0)
        {
            _drag = DragKind.Key;
            _dragKeyT = _lastKeyT = kt0;
            _store.BeginInteractive("Move Keyframe");
            return;
        }
        float x0 = X(l.Start), x1 = X(End(l, s));
        _dragT0 = l.Start;
        if (Math.Abs(p.X - x0) <= 6) { _drag = DragKind.TrimStart; _store.BeginInteractive("Trim Layer"); }
        else if (Math.Abs(p.X - x1) <= 6) { _drag = DragKind.TrimEnd; _store.BeginInteractive("Trim Layer"); }
        else if (p.X > x0 && p.X < x1) { _drag = DragKind.Move; _store.BeginInteractive("Move Layer in Time"); }
        else { _drag = DragKind.Seek; Seek(p.X); }
    }

    void Seek(double x)
    {
        var s = _store!.Scene;
        _store.Time = Math.Round(TimeAt(x) * s.Fps) / s.Fps;
    }

    double Snap(double t) => Math.Round(t * _store!.Scene.Fps) / _store.Scene.Fps;

    void Moved(object sender, PointerRoutedEventArgs e)
    {
        if (_store == null) return;
        var p = e.GetCurrentPoint(_canvas).Position;
        if (_drag == DragKind.None)
        {
            // Resize cursor over bar ends.
            var (l, _) = RowAt(p.Y);
            var s0 = _store.Scene;
            var overEdge = l != null && p.X > LabelW && (Math.Abs(p.X - X(l.Start)) <= 6 || Math.Abs(p.X - X(End(l, s0))) <= 6);
            ProtectedCursor = InputSystemCursor.Create(overEdge ? InputSystemCursorShape.SizeWestEast : InputSystemCursorShape.Arrow);
            return;
        }
        if (_drag == DragKind.Seek) { Seek(p.X); return; }
        var dt = (p.X - _dragStart.X) / _pxPerSec;
        var id = _dragId!;
        switch (_drag)
        {
            case DragKind.Move:
            {
                var d = Snap(Math.Max(-_dragT0, dt));
                _store.UpdateInteractive(s => { if (s.FindLayer(id) is { } l) Shift(l, d); });
                break;
            }
            case DragKind.TrimStart:
                _store.UpdateInteractive(s =>
                {
                    if (s.FindLayer(id) is not { } l) return;
                    l.Start = Math.Clamp(Snap(_dragT0 + dt), 0, l.EffectiveEnd(s.Duration) - 1.0 / s.Fps);
                });
                break;
            case DragKind.TrimEnd:
                _store.UpdateInteractive(s =>
                {
                    if (s.FindLayer(id) is not { } l) return;
                    var end = Snap(TimeAt(p.X));
                    l.End = end >= s.Duration - 1e-6 ? null : Math.Max(l.Start + 1.0 / s.Fps, end);
                });
                break;
            case DragKind.Key:
            {
                var to = Math.Max(0, Snap(_dragKeyT + dt));
                _store.UpdateInteractive(s =>
                {
                    if (s.FindLayer(id) is not { } l) return;
                    foreach (var k in l.AnimatedTracks.ToList())
                        if (l.HasKey(k, _dragKeyT, 1e-4)) l.MoveKey(k, _dragKeyT, to, 1e-4);
                });
                _lastKeyT = to;
                break;
            }
        }
    }

    /// <summary>Moves a layer in time with its keyframes.</summary>
    static void Shift(MotionLayer l, double d)
    {
        if (d == 0) return;
        l.Start += d;
        if (l.End is { } e) l.End = e + d;
        foreach (var k in l.AnimatedTracks.ToList())
        {
            if (k.Number is { } p) l[p] = l[p].Shifted(d);
            else if (k.Color is { } c) l[c] = l[c].Shifted(d);
        }
        if (l.D.IsAnimated) l.D = l.D.Shifted(d);
        for (var i = 0; i < l.TextAnimators.Count; i++) l.TextAnimators[i] = l.TextAnimators[i] with { Start = l.TextAnimators[i].Start + d };
    }

    /// <summary>Right-click on a keyframe: the easing of the segment arriving at it, or delete it.</summary>
    void KeyMenu(object sender, RightTappedRoutedEventArgs e)
    {
        if (_store == null) return;
        var p = e.GetPosition(_canvas);
        var (l, _) = RowAt(p.Y);
        if (l == null || p.X < LabelW) return;
        var kt = l.KeyframeTimes.Where(t => Math.Abs(X(t) - p.X) <= 6).Select(t => (double?)t).FirstOrDefault();
        if (kt is not { } t0) return;
        var id = l.Id;
        var menu = new MenuFlyout();
        void Ease(string name, Easing easing) =>
            menu.Items.Add(Item(name, () => _store.UpdateLayer(id, "Set Easing", x =>
            {
                foreach (var k in x.AnimatedTracks.ToList())
                    if (x.HasKey(k, t0, 1e-4)) x.SetEasing(k, t0, easing, 1e-4);
            })));
        Ease("Linear", Easing.Linear);
        Ease("Ease In", Easing.EaseIn);
        Ease("Ease Out", Easing.EaseOut);
        Ease("Ease In Out", Easing.EaseInOut);
        Ease("Hold", Easing.Hold);
        Ease("Spring", Easing.Spring);
        var more = new MenuFlyoutSubItem { Text = "More" };
        foreach (var c in Enum.GetValues<EaseCurve>())
            foreach (var m in Enum.GetValues<EaseMode>())
            {
                var easing = Easing.Named(c, m);
                more.Items.Add(Item(easing.ToString(), () => _store.UpdateLayer(id, "Set Easing", x =>
                {
                    foreach (var k in x.AnimatedTracks.ToList())
                        if (x.HasKey(k, t0, 1e-4)) x.SetEasing(k, t0, easing, 1e-4);
                })));
            }
        menu.Items.Add(more);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Delete Keyframe", () => _store.UpdateLayer(id, "Delete Keyframe", x =>
        {
            foreach (var k in x.AnimatedTracks.ToList())
                if (x.HasKey(k, t0, 1e-4)) x.DeleteKey(k, t0, 1e-4);
        })));
        menu.ShowAt(_canvas, p);
        e.Handled = true;
    }

    static MenuFlyoutItem Item(string text, Action action)
    {
        var item = new MenuFlyoutItem { Text = text };
        item.Click += (_, _) => action();
        return item;
    }

    void Released(object sender, PointerRoutedEventArgs e)
    {
        _canvas.ReleasePointerCapture(e.Pointer);
        EndDrag();
    }

    void EndDrag()
    {
        if (_drag is DragKind.Move or DragKind.TrimStart or DragKind.TrimEnd or DragKind.Key) _store?.EndInteractive();
        _drag = DragKind.None;
        _dragId = null;
    }

    void Wheel(object sender, PointerRoutedEventArgs e)
    {
        var pt = e.GetCurrentPoint(_canvas);
        var delta = pt.Properties.MouseWheelDelta;
        var ctrl = e.KeyModifiers.HasFlag(Windows.System.VirtualKeyModifiers.Control);
        var shift = e.KeyModifiers.HasFlag(Windows.System.VirtualKeyModifiers.Shift);
        if (ctrl)
        {
            // Zoom around the pointer.
            var t = TimeAt(pt.Position.X);
            _pxPerSec = Math.Clamp(_pxPerSec * (delta > 0 ? 1.15f : 1 / 1.15f), 8, 2000);
            _scrollX = Math.Max(0, (float)(t * _pxPerSec - (pt.Position.X - LabelW)));
        }
        else if (shift || pt.Properties.IsHorizontalMouseWheel) _scrollX = Math.Max(0, _scrollX - delta);
        else
        {
            var max = Math.Max(0, Rows.Count * RowH - ((float)_canvas.ActualHeight - Ruler) + 8);
            _scrollY = Math.Clamp(_scrollY - delta / 2f, 0, max);
        }
        e.Handled = true;
        Invalidate();
    }
}
