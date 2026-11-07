using Microsoft.Graphics.Canvas;
using Microsoft.UI.Dispatching;
using VeyMotion.Core;

namespace VeyMotion.App.Rendering;

/// <summary>
/// The canvas's frames, rendered on a background thread (the newest request wins, the canvas shows the last finished
/// frame meanwhile), and the RAM preview: frames kept by scene revision + pixel size + frame number, filled by the
/// canvas's own renders and, after 0.5 s idle, ahead of the playhead. Port of <c>PreviewRenderer</c>
/// (<c>ContentView.swift</c>) and <c>FrameCache.swift</c>.
/// </summary>
public sealed class PreviewRenderer : IDisposable
{
    readonly record struct Key(long Revision, int Width, int Height, int Frame);
    sealed record Request(MotionScene Scene, Key Key, double Time);

    readonly DispatcherQueue _ui;
    readonly Action _invalidate;
    readonly Lock _gate = new();
    readonly Dictionary<Key, CanvasRenderTarget> _cache = [];
    readonly LinkedList<Key> _order = new(); // oldest first
    readonly List<CanvasRenderTarget> _evicted = [];
    readonly AutoResetEvent _wake = new(false);
    readonly Thread _worker;
    Request? _wanted;
    Request? _idleFrom;
    DateTime _lastRequest = DateTime.UtcNow;
    Key? _lastKey;
    long _bytes;
    bool _disposed;
    bool _paused;
    /// <summary>The newest finished frame for the canvas.</summary>
    (Key Key, CanvasRenderTarget Frame)? _shown;

    /// <summary>RAM preview budget: a quarter of the memory, at most 1.5 GB.</summary>
    static readonly long Budget = Math.Min(GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 4, 1_500_000_000L);

    public PreviewRenderer(DispatcherQueue ui, Action invalidate)
    {
        _ui = ui;
        _invalidate = invalidate;
        _worker = new Thread(Run) { IsBackground = true, Name = "VeyMotion preview" };
        _worker.Start();
    }

    /// <summary>Stops filling ahead (while exporting or playing).</summary>
    public bool Paused
    {
        get => _paused;
        set { _paused = value; if (!value) _wake.Set(); }
    }

    /// <summary>The frame to draw for this scene state: cached or the last finished one (a render is queued when it
    /// is not ready). Call on the UI thread; draw the result before returning to the dispatcher.</summary>
    public CanvasRenderTarget? Frame(MotionScene scene, long revision, double t, int pw, int ph)
    {
        DisposeEvicted();
        var key = new Key(revision, pw, ph, (int)Math.Round(t * scene.Fps));
        lock (_gate)
        {
            // Redraws of the same frame (the timeline's green strip growing) do not count as activity.
            if (_lastKey != key) _lastRequest = DateTime.UtcNow;
            _lastKey = key;
            if (_cache.TryGetValue(key, out var hit))
            {
                Touch(key);
                _shown = (key, hit);
                _idleFrom = new Request(scene, key, t);
                return hit;
            }
            _wanted = new Request(scene, key, t);
            _idleFrom = _wanted;
        }
        _wake.Set();
        return _shown is { } s && s.Key.Width == pw && s.Key.Height == ph ? s.Frame : null;
    }

    /// <summary>Frame numbers cached for this revision and size (the green strip on the ruler).</summary>
    public IReadOnlyCollection<int> CachedFrames(long revision, int pw, int ph)
    {
        lock (_gate) return _cache.Keys.Where(k => k.Revision == revision && k.Width == pw && k.Height == ph).Select(k => k.Frame).ToHashSet();
    }

    /// <summary>Drops every cached frame (assets changed on disk, memory pressure).</summary>
    public void Purge()
    {
        lock (_gate)
        {
            foreach (var (k, f) in _cache)
                if (_shown?.Key != k) _evicted.Add(f);
            _cache.Clear();
            _order.Clear();
            _bytes = 0;
            if (_shown is { } s) { _cache[s.Key] = s.Frame; _order.AddLast(s.Key); _bytes = Size(s.Key); }
        }
    }

    void Touch(Key key)
    {
        _order.Remove(key);
        _order.AddLast(key);
    }

    static long Size(Key k) => (long)k.Width * k.Height * 4;

    void Run()
    {
        var device = CanvasDevice.GetSharedDevice();
        while (!_disposed)
        {
            Request? job;
            var idle = false;
            lock (_gate)
            {
                job = _wanted;
                _wanted = null;
                if (job == null && !_paused && _idleFrom is { } from && DateTime.UtcNow - _lastRequest > TimeSpan.FromSeconds(0.5))
                {
                    // Fill ahead: the next uncached frame after the playhead (wrapping), within the budget.
                    var total = (int)Math.Floor(from.Scene.Duration * from.Scene.Fps);
                    for (var i = 1; i <= total && job == null; i++)
                    {
                        var f = (from.Key.Frame + i) % Math.Max(total, 1);
                        var k = from.Key with { Frame = f };
                        if (!_cache.ContainsKey(k)) job = new Request(from.Scene, k, (double)f / from.Scene.Fps);
                    }
                    if (job != null && _bytes + Size(job.Key) > Budget) job = null; // full
                    idle = job != null;
                }
            }
            if (job == null) { _wake.WaitOne(idle ? 0 : 250); continue; }
            CanvasRenderTarget? frame = null;
            // Audio reactions read 0 until their file is analyzed; the frames are redrawn then (Analyzed).
            try { frame = AudioAnalysisCache.WithoutWaiting(() => FrameCompositor.Render(device, job.Scene, job.Time, job.Key.Width, job.Key.Height)); }
            catch (Exception e) when (e is not OutOfMemoryException)
            {
                if (device.IsDeviceLost(e.HResult)) device = CanvasDevice.GetSharedDevice();
                try { File.AppendAllText(Path.Combine(Mcp.AppPaths.SupportDirectory, "render-errors.log"), $"{DateTime.Now:O} {e}\n"); }
                catch (IOException) { }
            }
            if (frame == null) continue;
            lock (_gate)
            {
                if (_cache.TryGetValue(job.Key, out var old)) _evicted.Add(old);
                _cache[job.Key] = frame;
                Touch(job.Key);
                _bytes += Size(job.Key);
                // Older revisions and sizes go first, then the least recently used.
                while (_bytes > Budget && _order.First is { } oldest && oldest.Value != job.Key)
                {
                    _order.RemoveFirst();
                    if (_cache.Remove(oldest.Value, out var f)) { _bytes -= Size(oldest.Value); if (_shown?.Key != oldest.Value) _evicted.Add(f); }
                }
                foreach (var stale in _cache.Keys.Where(k => k.Revision < job.Key.Revision - 2).ToList())
                {
                    _bytes -= Size(stale);
                    _order.Remove(stale);
                    if (_cache.Remove(stale, out var f) && _shown?.Key != stale) _evicted.Add(f);
                }
                if (!idle) _shown = (job.Key, frame);
            }
            _ui.TryEnqueue(() => _invalidate());
        }
    }

    /// <summary>Evicted frames are disposed on the UI thread, never while a canvas session might still draw them.</summary>
    void DisposeEvicted()
    {
        List<CanvasRenderTarget> drop;
        lock (_gate)
        {
            if (_evicted.Count == 0) return;
            drop = [.. _evicted.Where(f => _shown?.Frame != f)];
            _evicted.RemoveAll(drop.Contains);
        }
        foreach (var f in drop) f.Dispose();
    }

    public void Dispose()
    {
        _disposed = true;
        _wake.Set();
    }
}
