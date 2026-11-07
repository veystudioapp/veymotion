namespace VeyMotion.Core;

/// <summary>
/// A project is a folder holding <c>scene.json</c> and an <c>assets/</c> library of its own:
/// <code>
/// My Video\
///   scene.json
///   assets\images\ icons\ music\ sfx\ voice\
/// </code>
/// Layer paths inside the project are saved relative to the project folder with forward slashes
/// (<c>assets/images/bg.jpg</c>, the same files open on macOS), so the folder can be moved or shared. In memory they
/// are absolute, like every other path. Port of <c>ProjectStore</c> (<c>Project.swift</c>), without the thumbnail.
/// </summary>
public static class ProjectStore
{
    public const string SceneFileName = "scene.json";
    public const string AssetsFolderName = "assets";
    /// <summary>Created in every new project. Files without a folder are put in these by type.</summary>
    public static readonly string[] StandardFolders = ["images", "icons", "music", "sfx", "voice"];
    /// <summary>The project's Claude conversation (transcript + session id).</summary>
    public const string ChatFileName = ".chat.json";
    /// <summary>The scene after each Claude prompt that changed it (the chat's Versions list).</summary>
    public const string VersionsFileName = ".versions.json";

    /// <summary>Where new projects go by default: <c>VEYMOTION_PROJECTS_DIR</c>, else <c>Documents\VeyMotion Projects</c>.</summary>
    public static string ProjectsDirectory =>
        Environment.GetEnvironmentVariable("VEYMOTION_PROJECTS_DIR") is { Length: > 0 } p
            ? AssetStore.Full(p)
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "VeyMotion Projects");

    public static string ScenePath(string project) => Path.Combine(project, SceneFileName);
    public static string ChatPath(string project) => Path.Combine(project, ChatFileName);
    public static string VersionsPath(string project) => Path.Combine(project, VersionsFileName);
    /// <summary>The project's asset library: pass it to <see cref="AssetStore.SetActiveLibrary"/> when the project opens.</summary>
    public static string AssetsPath(string project) => Path.Combine(project, AssetsFolderName);

    /// <summary>True if <paramref name="path"/> is a project folder (a folder with a scene.json).</summary>
    public static bool IsProject(string path) => Directory.Exists(path) && File.Exists(ScenePath(path));

    /// <summary>The project folder for a project folder or its <c>scene.json</c>, or null for any other path.</summary>
    public static string? ProjectFor(string path)
    {
        var p = AssetStore.Full(path);
        if (IsProject(p)) return p;
        if (string.Equals(Path.GetFileName(p), SceneFileName, StringComparison.OrdinalIgnoreCase)
            && Path.GetDirectoryName(p) is { } dir && IsProject(dir))
            return dir;
        return null;
    }

    /// <summary>A file-system-safe project name; throws when it is empty or hidden.</summary>
    static string CleanName(string name)
    {
        var clean = name.Trim();
        foreach (var c in Path.GetInvalidFileNameChars().Concat(['/', '\\', ':'])) clean = clean.Replace(c, '-');
        clean = clean.TrimEnd('.', ' ');
        if (clean.Length == 0 || clean.StartsWith('.')) throw new SceneException("Give the project a name");
        return clean;
    }

    /// <summary>Creates <c>&lt;directory&gt;\&lt;name&gt;\</c> with <paramref name="scene"/> (or an empty scene) and the
    /// standard asset folders. The name gets a " 2", " 3"… suffix if a folder with that name exists. Returns the project folder.</summary>
    public static string Create(string name, string? directory = null, MotionScene? scene = null)
    {
        var clean = CleanName(name);
        var parent = directory ?? ProjectsDirectory;
        Directory.CreateDirectory(parent);
        var folder = Path.Combine(parent, clean);
        for (var n = 2; Directory.Exists(folder) || File.Exists(folder); n++) folder = Path.Combine(parent, $"{clean} {n}");
        foreach (var sub in StandardFolders) Directory.CreateDirectory(Path.Combine(AssetsPath(folder), sub));
        Save(scene ?? new MotionScene(), folder);
        return AssetStore.Full(folder);
    }

    /// <summary>Reads a project's scene with its layer paths made absolute.</summary>
    public static MotionScene Load(string project)
    {
        var s = SceneJson.Load(ScenePath(project));
        s.ResolvePaths(project);
        return s;
    }

    /// <summary>Writes a project's scene with paths inside the project stored relative to it.</summary>
    public static void Save(MotionScene scene, string project) =>
        SceneJson.Write(SceneJson.Encode(scene.RelativizingPaths(project)), ScenePath(project));

    /// <summary>Reads any scene file, resolving relative layer paths against the file's folder (every scene load does
    /// this on macOS: project scenes store relative paths).</summary>
    public static MotionScene LoadSceneFile(string path)
    {
        var full = AssetStore.Full(path);
        var s = SceneJson.Load(full);
        s.ResolvePaths(Path.GetDirectoryName(full)!);
        return s;
    }

    /// <summary>Writes any scene file; a project's scene.json gets project-relative paths, other files keep them absolute.</summary>
    public static void SaveSceneFile(MotionScene scene, string path)
    {
        var full = AssetStore.Full(path);
        if (string.Equals(Path.GetFileName(full), SceneFileName, StringComparison.OrdinalIgnoreCase)
            && Path.GetDirectoryName(full) is { } dir && Directory.Exists(dir))
            SceneJson.Write(SceneJson.Encode(scene.RelativizingPaths(dir)), full);
        else
            SceneJson.Save(scene, full);
    }

    /// <summary>What the Projects screen shows for one project, or null if its scene cannot be read.</summary>
    public static ProjectSummary? Summary(string project)
    {
        var scenePath = ScenePath(project);
        try
        {
            var s = SceneJson.Load(scenePath);
            return new ProjectSummary(AssetStore.Full(project), File.GetLastWriteTime(scenePath), s.Width, s.Height, s.Duration, s.Layers.Count);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or SceneException) { return null; }
    }

    /// <summary>Projects in <see cref="ProjectsDirectory"/> plus <paramref name="extra"/> ones kept elsewhere (e.g.
    /// recent projects), newest first.</summary>
    public static List<ProjectSummary> List(IEnumerable<string>? extra = null)
    {
        IEnumerable<string> inFolder;
        try
        {
            inFolder = Directory.Exists(ProjectsDirectory)
                ? Directory.EnumerateDirectories(ProjectsDirectory).Where(d => !Path.GetFileName(d).StartsWith('.')).ToList()
                : [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { inFolder = []; }
        var seen = new HashSet<string>(StringComparer.FromComparison(AssetStore.PathComparison));
        return inFolder.Concat(extra ?? [])
            .Select(AssetStore.Full)
            .Where(p => IsProject(p) && seen.Add(p))
            .Select(Summary).OfType<ProjectSummary>()
            .OrderByDescending(s => s.Modified).ToList();
    }

    /// <summary>Renames a project folder. Returns its new location.</summary>
    public static string Rename(string project, string name)
    {
        var clean = CleanName(name);
        var src = AssetStore.Full(project);
        var dest = AssetStore.Full(Path.Combine(Path.GetDirectoryName(src)!, clean));
        if (string.Equals(dest, src, StringComparison.Ordinal)) return dest;
        var caseOnly = string.Equals(dest, src, StringComparison.OrdinalIgnoreCase);
        if ((Directory.Exists(dest) || File.Exists(dest)) && !caseOnly)
            throw new SceneException($"A project named {clean} already exists there");
        if (caseOnly)
        {
            var tmp = Path.Combine(Path.GetDirectoryName(src)!, $".rename-{Guid.NewGuid():N}");
            Directory.Move(src, tmp);
            Directory.Move(tmp, dest);
        }
        else Directory.Move(src, dest);
        return dest;
    }

    /// <summary>Copies a project next to itself as "&lt;name&gt; copy" (" copy 2"…). Returns the copy.</summary>
    public static string Duplicate(string project)
    {
        var src = AssetStore.Full(project);
        var parent = Path.GetDirectoryName(src)!;
        var name = Path.GetFileName(src);
        var dest = Path.Combine(parent, $"{name} copy");
        for (var n = 2; Directory.Exists(dest) || File.Exists(dest); n++) dest = Path.Combine(parent, $"{name} copy {n}");
        CopyDirectory(src, dest);
        return AssetStore.Full(dest);
    }

    static void CopyDirectory(string src, string dest)
    {
        Directory.CreateDirectory(dest);
        foreach (var f in Directory.EnumerateFiles(src)) File.Copy(f, Path.Combine(dest, Path.GetFileName(f)));
        foreach (var d in Directory.EnumerateDirectories(src))
        {
            if ((File.GetAttributes(d) & FileAttributes.ReparsePoint) != 0) continue; // do not follow links
            CopyDirectory(d, Path.Combine(dest, Path.GetFileName(d)));
        }
    }

    /// <summary>Moves a project folder to the Recycle Bin.</summary>
    public static void Trash(string project) => RecycleBin.Send(AssetStore.Full(project));
}

/// <summary>What the Projects screen shows for one project. Port of <c>ProjectSummary</c>.</summary>
/// <param name="Path">The project folder.</param>
/// <param name="Modified">When scene.json was last saved.</param>
public sealed record ProjectSummary(string Path, DateTime Modified, int Width, int Height, double Duration, int LayerCount)
{
    public string Name => System.IO.Path.GetFileName(Path);
    public string Id => Path;
}

/// <summary>Project-relative layer paths. Port of the <c>MotionScene</c> extension in <c>Project.swift</c> (top-level
/// layers, like the Swift code).</summary>
public static class ProjectPathExtensions
{
    static bool IsRootedPath(string p) =>
        p.StartsWith('~') || p.StartsWith('/') || p.StartsWith('\\') || Path.IsPathRooted(p);

    /// <summary>Makes relative layer paths absolute against <paramref name="baseDir"/> (the folder of the scene file).
    /// Accepts forward and back slashes.</summary>
    public static void ResolvePaths(this MotionScene scene, string baseDir)
    {
        foreach (var l in scene.Layers)
        {
            if (l.Path is not { Length: > 0 } p || IsRootedPath(p)) continue;
            l.Path = AssetStore.Full(Path.Combine(baseDir, p.Replace('/', Path.DirectorySeparatorChar)));
        }
    }

    /// <summary>A copy whose layer paths inside <paramref name="baseDir"/> are relative to it, with forward slashes
    /// (paths elsewhere stay absolute).</summary>
    public static MotionScene RelativizingPaths(this MotionScene scene, string baseDir)
    {
        var root = AssetStore.Full(baseDir);
        if (!Path.EndsInDirectorySeparator(root)) root += Path.DirectorySeparatorChar;
        var s = scene.Clone();
        foreach (var l in s.Layers)
        {
            if (l.Path is not { Length: > 0 } p) continue;
            string full;
            try { full = AssetStore.Full(p); }
            catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { continue; }
            if (full.StartsWith(root, AssetStore.PathComparison))
                l.Path = full[root.Length..].Replace(Path.DirectorySeparatorChar, '/');
        }
        return s;
    }
}
