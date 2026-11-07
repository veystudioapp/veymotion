using System.Net.Http.Headers;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

/// <summary>What an asset file is, by extension. Port of <c>AssetKind</c> (<c>Assets.swift</c>).</summary>
public enum AssetKind { Image, Audio, Video, Text, Font, Other }

/// <summary>One library file. Port of <c>AssetInfo</c> (<c>Assets.swift</c>).</summary>
public sealed class AssetInfo
{
    /// <summary>Path relative to the library folder with forward slashes, e.g. <c>logo.png</c> or <c>icons/social/logo.svg</c>.</summary>
    public string Name = "";
    /// <summary>Absolute file path (native separators).</summary>
    public string Path = "";
    public AssetKind Kind;
    public long Bytes;
    public DateTime Modified;
    public int? PixelWidth;
    public int? PixelHeight;
    public double? Duration;
    /// <summary>Fonts: the faces in the file, e.g. ["Be Vietnam Pro Bold"].</summary>
    public List<string>? FontFaces;
    /// <summary>Where the file came from and how to credit it (files from the free asset sources).</summary>
    public AssetCredit? Credit;

    public string Id => Name;
    /// <summary>The file name without its folder.</summary>
    public string FileName => Name[(Name.LastIndexOf('/') + 1)..];
    /// <summary>The folder it is in, relative to the library ("" for the top level).</summary>
    public string Folder => AssetStore.ParentFolder(Name);

    /// <summary>e.g. "image, 1920×1080, 245 KB" or "audio, 12.40s, 1.2 MB".</summary>
    public string Summary
    {
        get
        {
            var parts = new List<string> { Kind.Json() };
            if (PixelWidth is { } w && PixelHeight is { } h) parts.Add($"{w}×{h}");
            if (Duration is { } d) parts.Add(d.ToString("F2", System.Globalization.CultureInfo.InvariantCulture) + "s");
            if (FontFaces is { Count: > 0 } f) parts.Add(string.Join(" / ", f));
            parts.Add(AssetFormat.ByteCount(Bytes));
            return string.Join(", ", parts);
        }
    }
}

/// <summary>Asset library errors, worded like <c>AssetError</c> (<c>Assets.swift</c>).</summary>
public sealed class AssetException(string message) : Exception(message)
{
    public static AssetException InvalidName(string n) =>
        new($"Invalid asset name '{n}': use a file name like logo.png, optionally inside folders like icons/logo.png (no '..', no part starting with '.').");
    public static AssetException NotFound(string n) => new($"No asset named '{n}'. Use list_assets to see the library.");
    public static AssetException FolderNotFound(string n) => new($"No folder named '{n}'. Use list_assets to see the library.");
    public static AssetException Exists(string n) => new($"'{n}' already exists.");
    public static AssetException Failed(string m) => new(m);
}

/// <summary>License and attribution of a downloaded asset, kept in the library's hidden <c>.credits.json</c>.
/// Port of <c>AssetCredit</c> (<c>Assets.swift</c>); same JSON keys.</summary>
public sealed record AssetCredit
{
    public string Title { get; init; } = "";
    public string? Creator { get; init; }
    public string License { get; init; } = "";
    public string? LicenseURL { get; init; }
    public string? SourceURL { get; init; }
    /// <summary>Ready-to-paste credit line.</summary>
    public string Attribution { get; init; } = "";
    /// <summary>True when the license requires crediting the author (e.g. CC BY, CC BY-SA).</summary>
    public bool RequiresAttribution { get; init; }
    /// <summary>Where it came from, e.g. "openverse:&lt;id&gt;" or "iconify:mdi:rocket".</summary>
    public string Ref { get; init; } = "";

    public JsonObject ToNode()
    {
        // Sorted keys, nil fields left out (like the Swift encoder with .sortedKeys).
        var o = new JsonObject { ["attribution"] = Attribution };
        if (Creator != null) o["creator"] = Creator;
        o["license"] = License;
        if (LicenseURL != null) o["licenseURL"] = LicenseURL;
        o["ref"] = Ref;
        o["requiresAttribution"] = RequiresAttribution;
        if (SourceURL != null) o["sourceURL"] = SourceURL;
        o["title"] = Title;
        return o;
    }

    /// <summary>Null when a required field is missing.</summary>
    public static AssetCredit? FromNode(JsonNode? node)
    {
        if (node is not JsonObject o) return null;
        static string? S(JsonObject o, string k) =>
            o[k] is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;
        if (S(o, "title") is not { } title || S(o, "license") is not { } license || S(o, "attribution") is not { } attribution
            || S(o, "ref") is not { } r || o["requiresAttribution"] is not JsonValue rv
            || rv.GetValueKind() is not (JsonValueKind.True or JsonValueKind.False)) return null;
        return new AssetCredit
        {
            Title = title, Creator = S(o, "creator"), License = license, LicenseURL = S(o, "licenseURL"),
            SourceURL = S(o, "sourceURL"), Attribution = attribution, RequiresAttribution = rv.GetValue<bool>(), Ref = r,
        };
    }
}

/// <summary>
/// The asset library: the shared library, or the open project's <c>assets/</c> folder while a project is open. A folder
/// of files (images, audio, …), optionally in subfolders, that layers reference by absolute path. Assets are named by
/// their path relative to the library with forward slashes (<c>icons/logo.svg</c>). Port of <c>AssetStore</c>
/// (<c>Audio.swift</c> + <c>Assets.swift</c>). File operations are not undoable; layer repointing is (it goes through
/// a scene mutation).
/// </summary>
public static class AssetStore
{
    /// <summary>Largest file <see cref="Download"/> accepts.</summary>
    public const int MaxDownloadBytes = 500 * 1024 * 1024;

    // Platform hooks (Core has no media stack). All optional.

    /// <summary>Audio/movie lengths for <see cref="AssetInfo.Duration"/> and the music/sfx routing of new audio.</summary>
    public static IMediaProbe? MediaProbe { get; set; }
    /// <summary>Pixel size of images the built-in header reader does not know (TIFF, HEIC…) and of videos.</summary>
    public static Func<string, (int Width, int Height)?>? PixelSizeReader { get; set; }
    /// <summary>Faces of a font file, e.g. ["Be Vietnam Pro Bold"].</summary>
    public static Func<string, List<string>?>? FontFacesReader { get; set; }
    /// <summary>A PNG preview of an image file, at most the given pixels on its longer side (read_asset).</summary>
    public static Func<string, int, byte[]?>? PreviewPng { get; set; }

    // Libraries

    /// <summary>The shared library, used when no project is open (and browsable from projects).
    /// <c>VEYMOTION_ASSETS_DIR</c>, else <c>%LOCALAPPDATA%\VeyMotion\Assets</c>.</summary>
    public static string SharedDirectory =>
        Environment.GetEnvironmentVariable("VEYMOTION_ASSETS_DIR") is { Length: > 0 } p
            ? Full(p)
            : System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VeyMotion", "Assets");

    static readonly Lock ActiveLock = new();
    static string? _active;

    /// <summary>The library that asset tools and the Assets panel work on.</summary>
    public static string Directory { get { lock (ActiveLock) return _active ?? SharedDirectory; } }

    /// <summary>Switches to a project's assets folder (null = back to the shared library).</summary>
    public static void SetActiveLibrary(string? path) { lock (ActiveLock) _active = path == null ? null : Full(path); }

    /// <summary>True while a project's library is active. New files then go into type folders (images/, music/, …) by default.</summary>
    public static bool IsProjectLibrary { get { lock (ActiveLock) return _active != null; } }

    /// <summary><paramref name="folder"/> if given; otherwise <paramref name="fallback"/> inside a project library, null
    /// (top level) in the shared one.</summary>
    public static string? Routed(string? folder, string fallback) => folder ?? (IsProjectLibrary ? fallback : null);

    /// <summary>A new, uniquely named file for generated content. <paramref name="folder"/> is created if needed.</summary>
    public static string NewFile(string prefix, string ext, string? folder = null)
    {
        var dir = Directory;
        if (!string.IsNullOrEmpty(folder)) dir = Native(dir, ValidName(folder));
        System.IO.Directory.CreateDirectory(dir);
        return System.IO.Path.Combine(dir, $"{prefix}-{Guid.NewGuid().ToString("N")[..8].ToUpperInvariant()}.{ext}");
    }

    // Paths

    /// <summary>Paths are compared without case on Windows and macOS.</summary>
    public static readonly StringComparison PathComparison =
        OperatingSystem.IsWindows() || OperatingSystem.IsMacOS() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>Expands a leading <c>~</c> to the user's profile folder.</summary>
    public static string Expand(string path) =>
        path == "~" ? Home
        : path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith("~\\", StringComparison.Ordinal) ? System.IO.Path.Combine(Home, path[2..])
        : path;

    /// <summary>Absolute, normalized, without a trailing separator (like <c>standardizedFileURL.path</c>).</summary>
    public static string Full(string path)
    {
        var f = System.IO.Path.GetFullPath(Expand(path));
        return System.IO.Path.GetPathRoot(f) == f ? f : System.IO.Path.TrimEndingDirectorySeparator(f);
    }

    public static bool SamePath(string a, string b) => string.Equals(Full(a), Full(b), PathComparison);

    /// <summary>A library-relative name ("icons/logo.png") under <paramref name="root"/>, with native separators.</summary>
    static string Native(string root, string name) =>
        System.IO.Path.Combine(root, name.Replace('/', System.IO.Path.DirectorySeparatorChar));

    static string WithSeparator(string dir) =>
        System.IO.Path.EndsInDirectorySeparator(dir) ? dir : dir + System.IO.Path.DirectorySeparatorChar;

    // Names

    static readonly char[] BadChars = ['<', '>', '"', '|', '?', '*', ':', '\0'];
    static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>Checks that <paramref name="raw"/> is a relative path inside the library: <c>logo.png</c> or
    /// <c>icons/logo.png</c>. Every part must be a plain name (no <c>..</c>, not hidden, no characters Windows forbids).
    /// Backslashes count as slashes; leading/trailing slashes and empty parts are dropped.</summary>
    public static string ValidName(string raw)
    {
        var parts = raw.Trim().Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Trim(' ', '\t')).ToList();
        if (parts.Count == 0 || raw.Length > 500) throw AssetException.InvalidName(raw);
        foreach (var part in parts)
        {
            if (part.Length == 0 || part.Length > 200 || part.StartsWith('.') || part.EndsWith('.')
                || part.IndexOfAny(BadChars) >= 0 || part.Any(c => c < ' ')
                || Reserved.Contains(part.Split('.')[0]))
                throw AssetException.InvalidName(raw);
        }
        return string.Join('/', parts);
    }

    /// <summary>Like <see cref="ValidName"/>, but null, "" (or "/") means the top level of the library.</summary>
    public static string ValidFolder(string? raw) =>
        raw == null || raw.Trim('/', '\\', ' ').Length == 0 ? "" : ValidName(raw);

    /// <summary><c>icons/logo.png</c> → <c>icons</c>; <c>logo.png</c> → "".</summary>
    public static string ParentFolder(string name) => name.LastIndexOf('/') is var i and >= 0 ? name[..i] : "";

    /// <summary><paramref name="folder"/> + <paramref name="name"/>, e.g. ("icons", "logo.png") → "icons/logo.png".</summary>
    public static string Join(string? folder, string name) => string.IsNullOrEmpty(folder) ? name : folder + "/" + name;

    /// <summary>The path of a library file by name (it need not exist).</summary>
    public static string PathFor(string name) => Native(Directory, ValidName(name));

    /// <summary>The path of a folder in the library ("" is the library itself).</summary>
    public static string FolderPath(string name)
    {
        var valid = ValidFolder(name);
        return valid.Length == 0 ? Directory : Native(Directory, valid);
    }

    /// <summary>Names given as an absolute path (or <c>~\…</c>) rather than relative to the library.</summary>
    static bool IsAbsolute(string nameOrPath) => nameOrPath.StartsWith('~') || System.IO.Path.IsPathFullyQualified(nameOrPath);

    /// <summary>The path of an existing asset, accepting either its name (<c>icons/logo.png</c>) or its full path.</summary>
    public static string Existing(string nameOrPath)
    {
        string path;
        if (IsAbsolute(nameOrPath))
        {
            path = Full(nameOrPath);
            if (!Contains(path)) throw AssetException.NotFound(nameOrPath);
        }
        else path = PathFor(nameOrPath);
        if (!File.Exists(path)) throw AssetException.NotFound(nameOrPath);
        return path;
    }

    /// <summary>The path of an existing folder (not the library itself), by name (<c>icons/social</c>) or full path.</summary>
    public static string ExistingFolder(string nameOrPath)
    {
        string path;
        if (IsAbsolute(nameOrPath))
        {
            path = Full(nameOrPath);
            if (!Contains(path)) throw AssetException.FolderNotFound(nameOrPath);
        }
        else path = FolderPath(nameOrPath);
        if (SamePath(path, Directory) || !System.IO.Directory.Exists(path)) throw AssetException.FolderNotFound(nameOrPath);
        return path;
    }

    /// <summary>The asset name (forward slashes, relative to the library) of <paramref name="path"/>, or null if it is
    /// not inside the library or any part of it is hidden.</summary>
    public static string? RelativeName(string path, string? library = null)
    {
        string p, root;
        try { p = Full(path); root = WithSeparator(Full(library ?? Directory)); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return null; }
        if (!p.StartsWith(root, PathComparison) || p.Length == root.Length) return null;
        var parts = p[root.Length..].Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0 || parts.Any(x => x.StartsWith('.'))) return null;
        return string.Join('/', parts);
    }

    /// <summary>True if <paramref name="path"/> is inside the library folder (at any depth, not hidden).</summary>
    public static bool Contains(string path) => RelativeName(path) != null;

    public static AssetKind KindOf(string path) => AssetFormat.Kind(path);

    // Listing

    /// <summary>Every file and folder under <paramref name="root"/>, skipping hidden ones (dot names, Hidden/System).</summary>
    static void Walk(string dir, string root, List<string> files, List<string> folders)
    {
        IEnumerable<string> entries;
        try { entries = System.IO.Directory.EnumerateFileSystemEntries(dir).ToList(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
        foreach (var e in entries)
        {
            if (System.IO.Path.GetFileName(e).StartsWith('.')) continue;
            FileAttributes attrs;
            try { attrs = File.GetAttributes(e); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { continue; }
            if ((attrs & (FileAttributes.Hidden | FileAttributes.System)) != 0) continue;
            if ((attrs & FileAttributes.Directory) != 0)
            {
                if (RelativeName(e, root) is { } n) folders.Add(n);
                if ((attrs & FileAttributes.ReparsePoint) == 0) Walk(e, root, files, folders);
            }
            else files.Add(e);
        }
    }

    /// <summary>All files in the library (including those in folders), sorted by name. <paramref name="library"/>
    /// defaults to the active one.</summary>
    public static List<AssetInfo> List(string? library = null)
    {
        var root = library ?? Directory;
        var all = Credits(root);
        List<string> files = [], folders = [];
        Walk(root, root, files, folders);
        return files.Select(f => Info(f, root, all)).OfType<AssetInfo>()
            .OrderBy(a => a.Name, AssetFormat.NaturalOrder).ToList();
    }

    /// <summary>All folders in the library (e.g. <c>icons</c>, <c>icons/social</c>), sorted.</summary>
    public static List<string> Folders(string? library = null)
    {
        var root = library ?? Directory;
        List<string> files = [], folders = [];
        Walk(root, root, files, folders);
        return folders.Order(AssetFormat.NaturalOrder).ToList();
    }

    public static AssetInfo? Info(string path) => Info(path, Directory, null);

    static AssetInfo? Info(string path, string library, Dictionary<string, AssetCredit>? all)
    {
        var fi = new FileInfo(path);
        if (!fi.Exists) return null;
        var name = RelativeName(fi.FullName, library) ?? fi.Name;
        var a = new AssetInfo { Name = name, Path = fi.FullName, Kind = KindOf(fi.FullName), Bytes = fi.Length, Modified = fi.LastWriteTime };
        a.Credit = (all ?? Credits(library)).GetValueOrDefault(name);
        try
        {
            switch (a.Kind)
            {
                case AssetKind.Image:
                    if ((ImageHeader.Size(fi.FullName) ?? PixelSizeReader?.Invoke(fi.FullName)) is { } s)
                    { a.PixelWidth = s.Width; a.PixelHeight = s.Height; }
                    break;
                case AssetKind.Audio:
                    a.Duration = MediaProbe?.Duration(fi.FullName, false);
                    break;
                case AssetKind.Video:
                    a.Duration = MediaProbe?.Duration(fi.FullName, true);
                    if (PixelSizeReader?.Invoke(fi.FullName) is { } v) { a.PixelWidth = v.Width; a.PixelHeight = v.Height; }
                    break;
                case AssetKind.Font:
                    a.FontFaces = FontFacesReader?.Invoke(fi.FullName);
                    break;
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* metadata is optional */ }
        return a;
    }

    // Adding files

    /// <summary><c>logo.png</c> → <c>logo-2.png</c>, <c>logo-3.png</c>, … until the name is free (works for
    /// <c>icons/logo.png</c> too).</summary>
    public static string UniqueName(string name)
    {
        bool Taken(string n) { var p = Native(Directory, n); return File.Exists(p) || System.IO.Directory.Exists(p); }
        if (!Taken(name)) return name;
        var slash = name.LastIndexOf('/');
        var dot = name.LastIndexOf('.');
        var hasExt = dot > slash + 1 && dot < name.Length - 1;
        var (stem, ext) = hasExt ? (name[..dot], name[(dot + 1)..]) : (name, "");
        for (var n = 2; ; n++)
        {
            var candidate = hasExt ? $"{stem}-{n}.{ext}" : $"{stem}-{n}";
            if (!Taken(candidate)) return candidate;
        }
    }

    /// <summary>The type folder a new file goes into in a project library when no folder is given: images/, video/,
    /// fonts/, or audio/ for audio (sorted into music/ or sfx/ by <see cref="RouteAudio"/>). null = top level.</summary>
    public static string? AutoFolder(string name, string? folder)
    {
        if (folder != null || !IsProjectLibrary || name.Contains('/') || name.Contains('\\')) return folder;
        return KindOf(name) switch
        {
            AssetKind.Image => "images",
            AssetKind.Video => "video",
            AssetKind.Audio => "audio",
            AssetKind.Font => "fonts",
            _ => null,
        };
    }

    /// <summary>Audio routed to the temporary <c>audio/</c> folder moves to music/ (longer than 20 s) or sfx/.</summary>
    static string RouteAudio(string path)
    {
        if (RelativeName(path) is not { } rel || ParentFolder(rel) != "audio") return path;
        var length = MediaProbe?.Duration(path, false) ?? 0;
        string moved;
        try { moved = Move(path, length > 20 ? "music" : "sfx").To; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or AssetException) { return path; }
        var audioDir = System.IO.Path.Combine(Directory, "audio");
        try { if (System.IO.Directory.Exists(audioDir) && !System.IO.Directory.EnumerateFileSystemEntries(audioDir).Any()) System.IO.Directory.Delete(audioDir); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* leave it */ }
        return moved;
    }

    /// <summary>Where a new asset goes: the same name (replacing) if <paramref name="overwrite"/>, otherwise a free
    /// name. Creates its folder. A null <paramref name="folder"/> in a project library means the file's type folder.</summary>
    static string Destination(string name, string? folder, bool overwrite)
    {
        var valid = ValidName(Join(ValidFolder(AutoFolder(name, folder)), name));
        var path = Native(Directory, overwrite ? valid : UniqueName(valid));
        System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        return path;
    }

    /// <summary>Writes through a sibling temp file and a rename (never the system temp folder).</summary>
    public static void WriteAtomic(byte[] data, string path)
    {
        var full = System.IO.Path.GetFullPath(path);
        var tmp = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(full)!,
            $".{System.IO.Path.GetFileName(full)}.{Guid.NewGuid().ToString("N")[..8]}.part");
        File.WriteAllBytes(tmp, data);
        try { File.Move(tmp, full, overwrite: true); }
        catch
        {
            try { File.Delete(tmp); } catch { /* best effort */ }
            throw;
        }
    }

    /// <summary>Writes bytes as a library file. <paramref name="name"/> may include folders (<c>icons/badge.svg</c>);
    /// <paramref name="folder"/> is prepended. Without <paramref name="overwrite"/>, an existing name gets a numeric suffix.</summary>
    public static AssetInfo Write(byte[] data, string name, string? folder = null, bool overwrite = false)
    {
        var dest = Destination(name, folder, overwrite);
        WriteAtomic(data, dest);
        var placed = RouteAudio(dest);
        return Info(placed) ?? throw AssetException.Failed($"Cannot read back {placed}");
    }

    /// <summary>Copies a local file into the library (into <paramref name="folder"/>, created if needed).</summary>
    public static AssetInfo ImportFile(string source, string? name = null, string? folder = null, bool overwrite = false)
    {
        var src = Full(source);
        if (!File.Exists(src)) throw AssetException.Failed($"No file at {src}");
        var dest = Destination(name ?? System.IO.Path.GetFileName(src), folder, overwrite);
        if (string.Equals(dest, src, PathComparison) && Info(dest) is { } same) return same; // already in the library
        File.Copy(src, dest, overwrite: true);
        var placed = RouteAudio(dest);
        // Copied from the shared library into a project: bring its credit along.
        var shared = SharedDirectory;
        if (!SamePath(shared, Directory) && RelativeName(src, shared) is { } from
            && Credits(shared).GetValueOrDefault(from) is { } c && RelativeName(placed) is { } to)
            SetCredit(c, to);
        return Info(placed) ?? throw AssetException.Failed($"Cannot read back {placed}");
    }

    static readonly HttpClient Http = CreateHttp();

    static HttpClient CreateHttp()
    {
        var h = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        h.DefaultRequestHeaders.UserAgent.ParseAdd("VeyMotion/1.0");
        return h;
    }

    /// <summary>Downloads an http(s) URL into the library (in memory, then written straight into the library).
    /// Blocks the calling thread; do not call on the UI thread.</summary>
    public static AssetInfo Download(Uri remote, string? name = null, string? folder = null, bool overwrite = false, double timeout = 120)
    {
        if (!remote.IsAbsoluteUri || remote.Scheme is not ("http" or "https"))
            throw AssetException.Failed($"Only http(s) URLs can be downloaded: {remote}");
        _ = ValidFolder(folder); // fail before downloading
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeout));
        byte[] data;
        HttpContentHeaders headers;
        try
        {
            using var response = Http.GetAsync(remote, HttpCompletionOption.ResponseHeadersRead, cts.Token).GetAwaiter().GetResult();
            if (!response.IsSuccessStatusCode)
                throw AssetException.Failed($"Download failed: HTTP {(int)response.StatusCode} from {remote.Host}");
            headers = response.Content.Headers;
            if (headers.ContentLength > MaxDownloadBytes) throw AssetException.Failed("Download is larger than 500 MB");
            using var stream = response.Content.ReadAsStream(cts.Token);
            using var buffer = new MemoryStream();
            var chunk = new byte[81920];
            int read;
            while ((read = stream.Read(chunk, 0, chunk.Length)) > 0)
            {
                buffer.Write(chunk, 0, read);
                if (buffer.Length > MaxDownloadBytes) throw AssetException.Failed("Download is larger than 500 MB");
            }
            data = buffer.ToArray();
        }
        catch (OperationCanceledException) { throw AssetException.Failed($"Download timed out: {remote}"); }
        catch (HttpRequestException e) { throw AssetException.Failed($"Download failed: {e.Message}"); }
        if (data.Length == 0) throw AssetException.Failed($"Download failed: empty response from {remote.Host}");

        var fileName = name ?? SuggestedFileName(headers.ContentDisposition) ?? Uri.UnescapeDataString(remote.Segments.LastOrDefault() ?? "");
        fileName = fileName.Trim();
        if (fileName.Length == 0 || fileName == "/") fileName = "download";
        var last = fileName[(fileName.LastIndexOfAny(['/', '\\']) + 1)..];
        if (!last.Contains('.') && AssetFormat.ExtensionForMime(headers.ContentType?.MediaType) is { } ext) fileName += "." + ext;
        return Write(data, fileName, folder, overwrite);
    }

    static string? SuggestedFileName(ContentDispositionHeaderValue? cd) =>
        (cd?.FileNameStar ?? cd?.FileName)?.Trim('"', ' ') is { Length: > 0 } n ? n : null;

    // Renaming and trashing

    /// <summary>Moves a file or folder, also when only the letter case changes.</summary>
    static void MoveItem(string src, string dest, bool directory)
    {
        System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(dest)!);
        if (string.Equals(src, dest, StringComparison.OrdinalIgnoreCase))
        {
            // Case-only change on a case-insensitive volume: go through a temporary name.
            var tmp = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(src)!, $".rename-{Guid.NewGuid():N}");
            if (directory) { System.IO.Directory.Move(src, tmp); System.IO.Directory.Move(tmp, dest); }
            else { File.Move(src, tmp); File.Move(tmp, dest); }
            return;
        }
        if (directory) System.IO.Directory.Move(src, dest); else File.Move(src, dest);
    }

    /// <summary>Renames or moves a library file. <paramref name="newName"/> is the full name relative to the library,
    /// so <c>icons/logo.png</c> moves it into <c>icons</c> (created if needed). Returns the old and new full paths
    /// (to update layers that use it, see <see cref="AssetSceneExtensions.ReplacePath"/>).</summary>
    public static (string From, string To) Rename(string nameOrPath, string newName)
    {
        var src = Existing(nameOrPath);
        var dest = PathFor(newName);
        if (string.Equals(dest, src, StringComparison.Ordinal)) return (src, dest);
        var caseOnly = string.Equals(dest, src, StringComparison.OrdinalIgnoreCase);
        if ((File.Exists(dest) || System.IO.Directory.Exists(dest)) && !caseOnly) throw AssetException.Exists(ValidName(newName));
        MoveItem(src, dest, directory: false);
        if (RelativeName(src) is { } from && RelativeName(dest) is { } to)
            MoveCredits(k => k == from ? to : null);
        return (src, dest);
    }

    /// <summary>Moves a library file into <paramref name="folder"/> ("" = top level), keeping its file name.</summary>
    public static (string From, string To) Move(string nameOrPath, string folder)
    {
        var src = Existing(nameOrPath);
        return Rename(src, Join(ValidFolder(folder), System.IO.Path.GetFileName(src)));
    }

    /// <summary>Moves a library file to the Recycle Bin. Returns its old path.</summary>
    public static string Trash(string nameOrPath)
    {
        var path = Existing(nameOrPath);
        var name = RelativeName(path);
        RecycleBin.Send(path);
        if (name != null) SetCredit(null, name);
        return path;
    }

    // Folders

    /// <summary>Creates a folder (and its parents). Returns its name. Fine if it already exists.</summary>
    public static string CreateFolder(string name)
    {
        var valid = ValidName(name);
        var path = Native(Directory, valid);
        if (File.Exists(path)) throw AssetException.Exists(valid);
        System.IO.Directory.CreateDirectory(path);
        return valid;
    }

    /// <summary>Renames or moves a folder with everything in it. <paramref name="newName"/> is relative to the library
    /// (<c>brand/icons</c> moves <c>icons</c> into <c>brand</c>). Returns the old and new folder paths (for
    /// <see cref="AssetSceneExtensions.ReplaceFolder"/>).</summary>
    public static (string From, string To) RenameFolder(string nameOrPath, string newName)
    {
        var src = Full(ExistingFolder(nameOrPath));
        var dest = Full(Native(Directory, ValidName(newName)));
        if (string.Equals(dest, src, StringComparison.Ordinal)) return (src, dest);
        var caseOnly = string.Equals(dest, src, StringComparison.OrdinalIgnoreCase);
        if (dest.StartsWith(WithSeparator(src), StringComparison.OrdinalIgnoreCase))
            throw AssetException.Failed("Cannot move a folder into itself");
        if ((File.Exists(dest) || System.IO.Directory.Exists(dest)) && !caseOnly) throw AssetException.Exists(ValidName(newName));
        MoveItem(src, dest, directory: true);
        if (RelativeName(src) is { } from && RelativeName(dest) is { } to)
            MoveCredits(k => k.StartsWith(from + "/", StringComparison.Ordinal) ? to + k[from.Length..] : null);
        return (src, dest);
    }

    /// <summary>Moves a folder with everything in it to the Recycle Bin. Returns its old path.</summary>
    public static string TrashFolder(string nameOrPath)
    {
        var path = ExistingFolder(nameOrPath);
        var name = RelativeName(path);
        RecycleBin.Send(path);
        if (name != null)
        {
            var all = Credits();
            var kept = all.Where(kv => !kv.Key.StartsWith(name + "/", StringComparison.Ordinal)).ToDictionary();
            if (kept.Count != all.Count) SaveCredits(kept);
        }
        return path;
    }

    // Reading

    /// <summary>The file's text if it is small UTF-8 text.</summary>
    public static string ReadText(string path, int maxBytes = 200_000)
    {
        var data = File.ReadAllBytes(path);
        if (data.Length > maxBytes) throw AssetException.Failed($"File is larger than {maxBytes / 1000} KB");
        try
        {
            var s = new UTF8Encoding(false, true).GetString(data);
            return s.StartsWith('﻿') ? s[1..] : s;
        }
        catch (DecoderFallbackException) { throw AssetException.Failed("Not UTF-8 text"); }
    }

    // Credits

    static readonly JsonSerializerOptions CreditsJson = new()
    {
        WriteIndented = true, NewLine = "\n", Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static string CreditsPath => System.IO.Path.Combine(Directory, ".credits.json");

    /// <summary>The credits of a library (default the active one), keyed by asset name. Entries that cannot be read
    /// are skipped.</summary>
    public static Dictionary<string, AssetCredit> Credits(string? library = null)
    {
        var path = library != null ? System.IO.Path.Combine(library, ".credits.json") : CreditsPath;
        var result = new Dictionary<string, AssetCredit>();
        try
        {
            if (JsonNode.Parse(File.ReadAllText(path)) is JsonObject o)
                foreach (var (k, v) in o)
                    if (AssetCredit.FromNode(v) is { } c) result[k] = c;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        return result;
    }

    public static AssetCredit? Credit(string name) => Credits().GetValueOrDefault(name);

    /// <summary>Sets or (null) removes the credit of an asset name in the active library.</summary>
    public static void SetCredit(AssetCredit? credit, string name)
    {
        var all = Credits();
        if (all.GetValueOrDefault(name) == credit) return;
        if (credit == null) all.Remove(name); else all[name] = credit;
        SaveCredits(all);
    }

    /// <summary>Re-keys credits after a move: <paramref name="rename"/> returns the new name for a key, or null to leave it.</summary>
    public static void MoveCredits(Func<string, string?> rename)
    {
        var all = Credits();
        var changed = false;
        var result = new Dictionary<string, AssetCredit>();
        foreach (var (k, v) in all)
        {
            if (rename(k) is { } n) { result[n] = v; changed = true; }
            else result.TryAdd(k, v);
        }
        if (changed) SaveCredits(result);
    }

    public static void SaveCredits(Dictionary<string, AssetCredit> all)
    {
        var o = new JsonObject();
        foreach (var (k, v) in all.OrderBy(kv => kv.Key, StringComparer.Ordinal)) o[k] = v.ToNode();
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            WriteAtomic(Encoding.UTF8.GetBytes(o.ToJsonString(CreditsJson)), CreditsPath);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* like `try?` in Swift */ }
    }

    /// <summary>Credits of library files (active and shared library) used by the scene's top-level layers, in layer
    /// order, without duplicates.</summary>
    public static List<(string Name, AssetCredit Credit)> CreditsUsedBy(MotionScene scene)
    {
        var roots = new List<string> { Full(Directory) };
        var shared = Full(SharedDirectory);
        if (!roots.Any(r => string.Equals(r, shared, PathComparison))) roots.Add(shared);
        var all = roots.Select(r => (Root: r, Credits: Credits(r))).ToList();
        var seen = new HashSet<string>(StringComparer.FromComparison(PathComparison));
        var result = new List<(string, AssetCredit)>();
        foreach (var l in scene.Layers)
        {
            if (l.Path is not { } p) continue;
            foreach (var (root, credits) in all)
            {
                if (RelativeName(p, root) is not { } name || !credits.TryGetValue(name, out var c)) continue;
                if (seen.Add(root + "/" + name)) result.Add((name, c));
                break;
            }
        }
        return result;
    }
}

/// <summary>Layer repointing after file and folder renames. Port of the <c>MotionScene</c> extension in
/// <c>Assets.swift</c>; like the Swift code, only top-level layers are looked at.</summary>
public static class AssetSceneExtensions
{
    static string? TryFull(string p)
    {
        try { return AssetStore.Full(p); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return null; }
    }

    /// <summary>Ids of layers whose file is <paramref name="path"/>.</summary>
    public static List<string> LayersUsingPath(this MotionScene scene, string path)
    {
        var target = AssetStore.Full(path);
        return scene.Layers.Where(l => l.Path is { } p && string.Equals(TryFull(p), target, AssetStore.PathComparison))
            .Select(l => l.Id).ToList();
    }

    /// <summary>Points every layer that uses <paramref name="old"/> at <paramref name="new"/> (after a file rename).
    /// Returns the changed layer ids.</summary>
    public static List<string> ReplacePath(this MotionScene scene, string old, string @new)
    {
        var ids = scene.LayersUsingPath(old).ToHashSet();
        foreach (var l in scene.Layers) if (ids.Contains(l.Id)) l.Path = @new;
        return scene.Layers.Where(l => ids.Contains(l.Id)).Select(l => l.Id).ToList();
    }

    static string Root(string folder)
    {
        var f = AssetStore.Full(folder);
        return Path.EndsInDirectorySeparator(f) ? f : f + Path.DirectorySeparatorChar;
    }

    /// <summary>Ids of layers whose file is inside the folder at <paramref name="path"/> (at any depth).</summary>
    public static List<string> LayersInFolder(this MotionScene scene, string path)
    {
        var root = Root(path);
        return scene.Layers.Where(l => l.Path is { } p && TryFull(p) is { } full && full.StartsWith(root, AssetStore.PathComparison))
            .Select(l => l.Id).ToList();
    }

    /// <summary>Repoints layers whose file is inside folder <paramref name="old"/> to the same file under
    /// <paramref name="new"/> (after a folder rename or move). Returns the changed layer ids.</summary>
    public static List<string> ReplaceFolder(this MotionScene scene, string old, string @new)
    {
        var oldRoot = Root(old);
        var newRoot = Root(@new);
        var ids = new List<string>();
        foreach (var l in scene.Layers)
        {
            if (l.Path is not { } p || TryFull(p) is not { } full || !full.StartsWith(oldRoot, AssetStore.PathComparison)) continue;
            l.Path = newRoot + full[oldRoot.Length..];
            ids.Add(l.Id);
        }
        return ids;
    }
}
