using VeyMotion.Core;

namespace VeyMotion.Mcp;

/// <summary>Scene host for the CLI: loads a JSON file and writes it back after every mutation.
/// Port of <c>FileSceneHost.swift</c>.</summary>
public sealed class FileSceneHost : ISceneHost
{
    readonly string _path;
    MotionScene _scene;
    readonly Lock _lock = new();

    public FileSceneHost(string path)
    {
        _path = Path.GetFullPath(path);
        // A project's scene: its assets folder is the library, and its paths are stored relative to it.
        if (ProjectStore.ProjectFor(_path) is { } project) AssetStore.SetActiveLibrary(ProjectStore.AssetsPath(project));
        _scene = ProjectStore.LoadSceneFile(_path);
    }

    public MotionScene CurrentScene()
    {
        lock (_lock) return _scene;
    }

    public void Mutate(string label, Func<MotionScene, MotionScene> body)
    {
        lock (_lock)
        {
            var updated = body(_scene.Clone());
            updated.ResolveLinks();
            ProjectStore.SaveSceneFile(updated, _path);
            _scene = updated;
        }
    }
}
