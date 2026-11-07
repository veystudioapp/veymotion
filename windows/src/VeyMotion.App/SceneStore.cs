using Microsoft.UI.Dispatching;
using VeyMotion.Core;
using VeyMotion.Mcp;

namespace VeyMotion.App;

/// <summary>
/// The open document. Port of the parts of <c>SceneStore.swift</c> the Windows app has so far: one mutation path
/// with undo (<see cref="Apply"/>), autosave for projects, and <see cref="ISceneHost"/> for agent edits, which run on
/// the UI thread with an "Agent: …" label so they are undoable.
/// </summary>
public sealed class SceneStore : ISceneHost
{
    public const string SceneFileName = "scene.json";
    public const string ChatFileName = ".chat.json";
    public const string VersionsFileName = ".versions.json";
    const int MaxUndo = 300;

    readonly DispatcherQueue _dispatcher;
    readonly List<(string Label, MotionScene Scene)> _undo = [];
    readonly List<(string Label, MotionScene Scene)> _redo = [];
    DispatcherQueueTimer? _autosave;

    /// <summary>The current scene. Never mutate it in place: go through <see cref="Apply"/>.</summary>
    public MotionScene Scene { get; private set; }
    public string? FilePath { get; private set; }
    public bool IsDirty { get; private set; }
    /// <summary>Bumped on every change of the scene's content (keys the RAM preview).</summary>
    public long Revision { get; private set; }

    double _time;
    public double Time
    {
        get => _time;
        set
        {
            var t = Math.Clamp(value, 0, Scene.Duration);
            if (t == _time) return;
            _time = t;
            TimeChanged?.Invoke();
        }
    }

    string? _selection;
    /// <summary>The selected layer's id (anywhere in the tree), or null.</summary>
    public string? Selection
    {
        get => _selection;
        set
        {
            if (value != null && Scene.FindLayer(value) == null) value = null;
            if (value == _selection) return;
            _selection = value;
            SelectionChanged?.Invoke();
        }
    }

    public MotionLayer? SelectedLayer => _selection is { } id ? Scene.FindLayer(id) : null;

    /// <summary>Raised on the UI thread after every scene change (edit, undo, open).</summary>
    public event Action? SceneChanged;
    public event Action? SelectionChanged;
    public event Action? TimeChanged;
    /// <summary>The project folder changed (null = loose scene). Raised before the new scene is shown.</summary>
    public event Action<string?>? ProjectChanged;

    public SceneStore(DispatcherQueue dispatcher, MotionScene scene)
    {
        _dispatcher = dispatcher;
        Scene = scene;
    }

    /// <summary>The project folder: a folder holding <c>scene.json</c> (like macOS <c>ProjectStore.project(for:)</c>).</summary>
    public string? Project => ProjectFor(FilePath);

    public static string? ProjectFor(string? path) =>
        path != null && string.Equals(Path.GetFileName(path), SceneFileName, StringComparison.OrdinalIgnoreCase)
            ? Path.GetDirectoryName(Path.GetFullPath(path)) : null;

    public string Title => FilePath == null ? "Untitled"
        : Project is { } p ? Path.GetFileName(p) : Path.GetFileName(FilePath);

    // Mutations

    /// <summary>Applies an edit to a copy of the scene; keeps it (one undo step) if anything changed.</summary>
    public void Apply(string label, Func<MotionScene, MotionScene> body)
    {
        var updated = body(Scene.Clone());
        updated.ResolveLinks();
        if (SceneJson.Encode(updated, pretty: false) == SceneJson.Encode(Scene, pretty: false)) return;
        _undo.Add((label, Scene));
        if (_undo.Count > MaxUndo) _undo.RemoveAt(0);
        _redo.Clear();
        Commit(updated);
    }

    public void Apply(string label, Action<MotionScene> body) => Apply(label, s => { body(s); return s; });

    void Commit(MotionScene s)
    {
        Scene = s;
        Revision++;
        IsDirty = true;
        if (_time > s.Duration) { _time = s.Duration; TimeChanged?.Invoke(); }
        SceneChanged?.Invoke();
        if (_selection != null && s.FindLayer(_selection) == null) Selection = null;
        ScheduleAutosave();
    }

    /// <summary>Edits one layer (anywhere in the tree) as one undo step.</summary>
    public void UpdateLayer(string id, string label, Action<MotionLayer> body) => Apply(label, s =>
    {
        if (s.FindLayer(id) is { } l) body(l);
    });

    // Interactive edits (drags): one undo step per gesture.

    MotionScene? _gestureStart;
    string _gestureLabel = "";

    public bool IsInteractive => _gestureStart != null;

    public void BeginInteractive(string label)
    {
        if (_gestureStart != null) EndInteractive();
        _gestureStart = Scene;
        _gestureLabel = label;
    }

    /// <summary>Applies the gesture's edit to the scene as it was when the gesture began, without an undo step.</summary>
    public void UpdateInteractive(Action<MotionScene> body)
    {
        if (_gestureStart == null) return;
        var updated = _gestureStart.Clone();
        body(updated);
        updated.ResolveLinks();
        Scene = updated;
        Revision++;
        SceneChanged?.Invoke();
    }

    public void EndInteractive()
    {
        if (_gestureStart is not { } start) return;
        _gestureStart = null;
        if (SceneJson.Encode(Scene, pretty: false) == SceneJson.Encode(start, pretty: false)) return;
        _undo.Add((_gestureLabel, start));
        if (_undo.Count > MaxUndo) _undo.RemoveAt(0);
        _redo.Clear();
        Commit(Scene);
    }

    // New layers, placed at the playhead and selected.

    public void AddLayer(LayerType type, string? path = null)
    {
        if (type == LayerType.Particles) { AddParticles(ParticlePreset.Fire); return; }
        if (type == LayerType.Generator) { AddGenerator(GeneratorKind.Spectrum); return; }
        var l = new MotionLayer(type, "", null, Scene.Width / 2.0, Scene.Height / 2.0);
        switch (type)
        {
            case LayerType.Rect:
                l[AnimProperty.Width] = 400.0; l[AnimProperty.Height] = 240.0; l.CornerRadius = 24.0; l.Fill = Rgba.FromHex("#6C5CE7")!.Value;
                break;
            case LayerType.Ellipse:
                l[AnimProperty.Width] = 240.0; l[AnimProperty.Height] = 240.0; l.Fill = Rgba.FromHex("#00B894")!.Value;
                break;
            case LayerType.Path:
                l.Name = "Star"; l.D = new PathShape("star(5,160,70)"); l.Fill = Rgba.FromHex("#FDCB6E")!.Value;
                break;
            case LayerType.Text: l.Text = "New Text"; break;
            case LayerType.Image: l.Path = path; l.Width = 600.0; break;
            case LayerType.Video or LayerType.Audio:
                l.Path = path;
                l.Start = Time;
                if (path != null) l.Name = Path.GetFileName(path);
                break;
            case LayerType.Group: l.Name = "Group"; break;
        }
        var id = "";
        Apply("Add Layer", s => { id = s.AddLayer(l); });
        Selection = id;
    }

    public void AddParticles(ParticlePreset preset)
    {
        var l = ParticleSim.MakeParticles(preset, Scene.Width, Scene.Height);
        l.Start = Time;
        var id = "";
        Apply($"Add {l.Name}", s => { id = s.AddLayer(l); });
        Selection = id;
    }

    /// <summary>Adds a generator sized for its kind: visualizers along the bottom, noise over the whole frame.</summary>
    public void AddGenerator(GeneratorKind kind)
    {
        double w = Scene.Width, h = Scene.Height;
        var name = kind.Json();
        var l = new MotionLayer(LayerType.Generator, name, char.ToUpperInvariant(name[0]) + name[1..], w / 2, h / 2) { Generator = new Generator { Kind = kind } };
        static Rgba H(string s) => Rgba.FromHex(s)!.Value;
        switch (kind)
        {
            case GeneratorKind.Spectrum or GeneratorKind.Waveform:
                l[AnimProperty.Width] = Math.Round(w * 0.7); l[AnimProperty.Height] = Math.Round(h * 0.25);
                l.Y = Math.Round(h * 0.75); l.Fill = H("#4FD1C5"); l.CornerRadius = 4.0;
                break;
            case GeneratorKind.Noise:
                l[AnimProperty.Width] = w; l[AnimProperty.Height] = h;
                l.Generator.Colors = [H("#0B1026"), H("#3B2C85"), H("#F0A6CA")];
                break;
            case GeneratorKind.Lightning:
                l[AnimProperty.Width] = Math.Round(w * 0.5); l[AnimProperty.Height] = Math.Round(h * 0.2);
                l.Fill = H("#CFE8FF"); l.StrokeWidth = 3.0; l[AnimProperty.Glow] = 1.5; l.GlowColor = H("#5AA9FF");
                break;
            case GeneratorKind.Grid:
                l[AnimProperty.Width] = w; l[AnimProperty.Height] = h; l.Fill = H("#FF2E9A99"); l.StrokeWidth = 2.0;
                break;
            case GeneratorKind.Chart:
                l[AnimProperty.Width] = Math.Round(w * 0.5); l[AnimProperty.Height] = Math.Round(h * 0.45);
                l.Generator.Values = [12, 30, 18, 42, 27];
                l.Generator.Labels = ["A", "B", "C", "D", "E"];
                l.Generator.Colors = [H("#4FD1C5"), H("#FFD93D"), H("#FF6B6B"), H("#A78BFA"), H("#60A5FA")];
                l.FontSize = 28; l.FontWeight = "semibold"; l.CornerRadius = 6.0;
                l.Reveal = Animated<double>.Keyframes([new(Time, 0, Easing.Linear), new(Time + 1.2, 1, Easing.EaseOut)]);
                break;
            case GeneratorKind.Flare:
                l[AnimProperty.Width] = w; l[AnimProperty.Height] = h;
                l.Generator.From = new PathPoint(-w * 0.25, -h * 0.2);
                l.BlendMode = BlendMode.Add;
                break;
        }
        l.Start = Time;
        var id = "";
        Apply($"Add {l.Name}", s => { id = s.AddLayer(l); });
        Selection = id;
    }

    public void AddTemplate(TemplateKind kind)
    {
        var o = new TemplateOptions { Start = Time, Duration = Math.Min(4, Math.Max(1, Scene.Duration - Time)) };
        var id = "";
        Apply($"Add {kind.Title()}", s => { id = s.AddTemplate(kind, null, o); });
        Selection = id;
    }

    public bool CanUndo => _undo.Count > 0;
    public bool CanRedo => _redo.Count > 0;
    public string? UndoLabel => _undo.Count > 0 ? _undo[^1].Label : null;
    public string? RedoLabel => _redo.Count > 0 ? _redo[^1].Label : null;

    public void Undo()
    {
        if (_undo.Count == 0) return;
        var last = _undo[^1];
        _undo.RemoveAt(_undo.Count - 1);
        _redo.Add((last.Label, Scene));
        Commit(last.Scene);
    }

    public void Redo()
    {
        if (_redo.Count == 0) return;
        var next = _redo[^1];
        _redo.RemoveAt(_redo.Count - 1);
        _undo.Add((next.Label, Scene));
        Commit(next.Scene);
    }

    // Documents

    /// <summary>Opens a scene file (or a project's scene.json). Throws <see cref="SceneException"/>/IO errors.</summary>
    public void Open(string path)
    {
        var full = Path.GetFullPath(path);
        if (Directory.Exists(full)) full = Path.Combine(full, SceneFileName); // a project folder
        var scene = ProjectStore.LoadSceneFile(full); // project-relative paths resolve against the project
        if (Project != null && IsDirty) Save(); // a project has a fixed place, so switching never loses work
        ReplaceDocument(scene, full);
    }

    public void NewDocument(MotionScene scene)
    {
        if (Project != null && IsDirty) Save();
        ReplaceDocument(scene, null);
    }

    /// <summary>Every document switch goes through here: cancels a pending autosave, clears undo history unless both
    /// are loose scenes, and resets the playhead.</summary>
    void ReplaceDocument(MotionScene scene, string? path)
    {
        _autosave?.Stop();
        var oldProject = Project;
        var newProject = ProjectFor(path);
        if (oldProject != null || newProject != null || path != FilePath) { _undo.Clear(); _redo.Clear(); }
        if (!string.Equals(oldProject, newProject, StringComparison.OrdinalIgnoreCase))
        {
            // Asset tools, the Assets panel and fonts switch to the project's library.
            AssetStore.SetActiveLibrary(newProject == null ? null : ProjectStore.AssetsPath(newProject));
            ProjectChanged?.Invoke(newProject);
        }
        _gestureStart = null;
        FilePath = path;
        Scene = scene;
        Revision++;
        IsDirty = false;
        _selection = null;
        SelectionChanged?.Invoke();
        _time = 0;
        TimeChanged?.Invoke();
        SceneChanged?.Invoke();
    }

    public void Save()
    {
        if (FilePath == null) throw new InvalidOperationException("No file: use SaveAs");
        ProjectStore.SaveSceneFile(Scene, FilePath); // project-internal paths are stored relative
        IsDirty = false;
        SceneChanged?.Invoke();
    }

    public void SaveAs(string path)
    {
        var old = Project;
        FilePath = Path.GetFullPath(path);
        if (!string.Equals(old, Project, StringComparison.OrdinalIgnoreCase))
        {
            AssetStore.SetActiveLibrary(Project == null ? null : ProjectStore.AssetsPath(Project));
            ProjectChanged?.Invoke(Project);
        }
        Save();
    }

    /// <summary>A project has a fixed place on disk, so its edits are written shortly after they happen. Saving only on
    /// quit loses everything when the app is killed.</summary>
    void ScheduleAutosave()
    {
        if (Project == null) return;
        _autosave ??= CreateAutosaveTimer();
        _autosave.Stop();
        _autosave.Start();
    }

    DispatcherQueueTimer CreateAutosaveTimer()
    {
        var t = _dispatcher.CreateTimer();
        t.Interval = TimeSpan.FromSeconds(1);
        t.IsRepeating = false;
        t.Tick += (_, _) =>
        {
            if (Project == null || !IsDirty) return;
            try { Save(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException or SceneException) { /* retried on the next edit */ }
        };
        return t;
    }

    // ISceneHost — called from control-pipe threads.

    public MotionScene CurrentScene() => OnMain(() => Scene);

    public void Mutate(string label, Func<MotionScene, MotionScene> body) => OnMain(() =>
    {
        Apply($"Agent: {label}", body);
        return true;
    });

    T OnMain<T>(Func<T> work)
    {
        if (_dispatcher.HasThreadAccess) return work();
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_dispatcher.TryEnqueue(() =>
            {
                try { done.SetResult(work()); }
                catch (Exception e) { done.SetException(e); }
            }))
            throw new InvalidOperationException("VeyMotion is closing");
        return done.Task.GetAwaiter().GetResult();
    }
}
