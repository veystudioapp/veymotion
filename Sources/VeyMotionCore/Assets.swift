import AppKit
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The shared asset library: a folder of files (images, audio, …), optionally organized in subfolders, that layers
/// reference by absolute path. Assets are named by their path relative to the library (`icons/logo.svg`).
/// The UI and the agent tools both go through these functions.
public enum AssetKind: String, Codable, Sendable, CaseIterable {
    case image, audio, video, text, font, other
}

public struct AssetInfo: Equatable, Identifiable, Sendable {
    /// Path relative to the library folder, e.g. `logo.png` or `icons/social/logo.svg`.
    public var name: String
    public var path: String
    public var kind: AssetKind
    public var bytes: Int
    public var modified: Date
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var duration: Double?
    /// Fonts: the faces in the file, e.g. ["Be Vietnam Pro Bold"] (use the family as a text layer's fontName).
    public var fontFaces: [String]?
    /// Where the file came from and how to credit it (set for files from the free asset sources).
    public var credit: AssetCredit?

    public var id: String { name }
    /// The file name without its folder.
    public var fileName: String { (name as NSString).lastPathComponent }
    /// The folder it is in, relative to the library ("" for the top level).
    public var folder: String { AssetStore.parentFolder(of: name) }

    /// e.g. "image, 1920×1080, 245 KB" or "audio, 12.40s, 1.2 MB".
    public var summary: String {
        var parts = [kind.rawValue]
        if let w = pixelWidth, let h = pixelHeight { parts.append("\(w)×\(h)") }
        if let d = duration { parts.append(String(format: "%.2fs", d)) }
        if let f = fontFaces, !f.isEmpty { parts.append(f.joined(separator: " / ")) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        return parts.joined(separator: ", ")
    }
}

public enum AssetError: LocalizedError {
    case invalidName(String)
    case notFound(String)
    case folderNotFound(String)
    case exists(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidName(n): return "Invalid asset name '\(n)': use a file name like logo.png, optionally inside folders like icons/logo.png (no '..', no part starting with '.')."
        case let .notFound(n): return "No asset named '\(n)'. Use list_assets to see the library."
        case let .folderNotFound(n): return "No folder named '\(n)'. Use list_assets to see the library."
        case let .exists(n): return "'\(n)' already exists."
        case let .failed(m): return m
        }
    }
}

extension AssetStore {
    /// Largest file `download` accepts.
    public static let maxDownloadBytes = 500 * 1024 * 1024

    /// Checks that `raw` is a relative path inside the library: `logo.png` or `icons/logo.png`. Every part must be
    /// a plain name (no `..`, not hidden). Leading/trailing slashes and empty parts are dropped.
    public static func validName(_ raw: String) throws -> String {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty, raw.count <= 500 else { throw AssetError.invalidName(raw) }
        for part in parts {
            guard !part.isEmpty, part.count <= 200, !part.hasPrefix("."),
                  !part.contains(":"), !part.contains("\0") else {
                throw AssetError.invalidName(raw)
            }
        }
        return parts.joined(separator: "/")
    }

    /// Like `validName`, but "" (or "/") means the top level of the library.
    public static func validFolder(_ raw: String?) throws -> String {
        guard let raw, !raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).isEmpty else { return "" }
        return try validName(raw)
    }

    /// `icons/logo.png` → `icons`; `logo.png` → "".
    public static func parentFolder(of name: String) -> String {
        guard let i = name.lastIndex(of: "/") else { return "" }
        return String(name[..<i])
    }

    /// `folder` + `name`, e.g. ("icons", "logo.png") → "icons/logo.png".
    public static func join(_ folder: String?, _ name: String) -> String {
        guard let folder, !folder.isEmpty else { return name }
        return folder + "/" + name
    }

    public static func url(for name: String) throws -> URL {
        directory.appendingPathComponent(try validName(name), isDirectory: false)
    }

    /// The URL of a folder in the library ("" is the library itself).
    public static func folderURL(_ name: String) throws -> URL {
        let valid = try validFolder(name)
        return valid.isEmpty ? directory : directory.appendingPathComponent(valid, isDirectory: true)
    }

    /// Names given as an absolute path (or `~/…`) rather than relative to the library.
    private static func isAbsolute(_ nameOrPath: String) -> Bool {
        nameOrPath.hasPrefix("/") || nameOrPath.hasPrefix("~")
    }

    /// The URL of an existing asset, accepting either its name (`icons/logo.png`) or its full path.
    public static func existing(_ nameOrPath: String) throws -> URL {
        let url: URL
        if isAbsolute(nameOrPath) {
            url = expand(nameOrPath).standardizedFileURL
            guard contains(url.path) else { throw AssetError.notFound(nameOrPath) }
        } else {
            url = try self.url(for: nameOrPath)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw AssetError.notFound(nameOrPath)
        }
        return url
    }

    /// The URL of an existing folder, by name (`icons/social`) or full path.
    public static func existingFolder(_ nameOrPath: String) throws -> URL {
        let url: URL
        if isAbsolute(nameOrPath) {
            url = expand(nameOrPath).standardizedFileURL
            guard contains(url.path) else { throw AssetError.folderNotFound(nameOrPath) }
        } else {
            url = try folderURL(nameOrPath)
        }
        var isDir: ObjCBool = false
        guard url.standardizedFileURL.path != directory.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw AssetError.folderNotFound(nameOrPath)
        }
        return url
    }

    /// The asset name (path relative to the library) of `path`, or nil if it is not inside the library.
    public static func relativeName(of path: String, in library: URL? = nil) -> String? {
        let p = expand(path).standardizedFileURL.path
        let root = (library ?? directory).standardizedFileURL.path
        guard p.hasPrefix(root + "/") else { return nil }
        let rel = String(p.dropFirst(root.count + 1))
        let parts = rel.split(separator: "/")
        guard !parts.isEmpty, parts.allSatisfy({ !$0.hasPrefix(".") }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// True if `path` is inside the library folder (at any depth, not hidden).
    public static func contains(_ path: String) -> Bool {
        relativeName(of: path) != nil
    }

    public static func kind(of url: URL) -> AssetKind {
        if FontLibrary.fileExtensions.contains(url.pathExtension.lowercased()) { return .font }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .text) || type.conforms(to: .json) { return .text }
        return .other
    }

    /// Every file and folder in the library, recursively, as names relative to it.
    private static func walk(_ root: URL) -> (files: [URL], folders: [String]) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return ([], [])
        }
        var files: [URL] = [], folders: [String] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if let n = relativeName(of: url.path, in: root) { folders.append(n) }
            } else if v?.isRegularFile == true {
                files.append(url)
            }
        }
        return (files, folders)
    }

    /// All files in the library (including those in folders), sorted by name. `library` defaults to the active one.
    public static func list(in library: URL? = nil) -> [AssetInfo] {
        let root = library ?? directory
        let all = credits(in: root)
        return walk(root).files
            .compactMap { info($0, library: root, credits: all) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// All folders in the library (e.g. `icons`, `icons/social`), sorted.
    public static func folders(in library: URL? = nil) -> [String] {
        walk(library ?? directory).folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func info(_ url: URL) -> AssetInfo? { info(url, library: directory, credits: nil) }

    private static func info(_ url: URL, library: URL, credits all: [String: AssetCredit]?) -> AssetInfo? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let name = relativeName(of: url.path, in: library) ?? url.lastPathComponent
        var a = AssetInfo(name: name, path: url.path, kind: kind(of: url),
                          bytes: (attrs[.size] as? NSNumber)?.intValue ?? 0,
                          modified: attrs[.modificationDate] as? Date ?? .distantPast)
        a.credit = (all ?? credits(in: library))[name]
        switch a.kind {
        case .image:
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                a.pixelWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
                a.pixelHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            } else if let ns = NSImage(contentsOf: url) { // SVG
                a.pixelWidth = Int(ns.size.width.rounded())
                a.pixelHeight = Int(ns.size.height.rounded())
            }
        case .audio:
            a.duration = try? AudioFileInfo.duration(of: url.path)
        case .video:
            if let v = try? VideoSource.info(of: url.path) {
                a.duration = v.duration
                a.pixelWidth = v.width
                a.pixelHeight = v.height
            }
        case .font:
            a.fontFaces = FontLibrary.faces(inFile: url)
        default:
            break
        }
        return a
    }

    /// `logo.png` → `logo-2.png`, `logo-3.png`, … until the name is free (works for `icons/logo.png` too).
    public static func uniqueName(_ name: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent(name).path) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            if !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }

    /// The type folder a new file goes into in a project library when no folder is given: images/, video/, or
    /// audio/ for audio (sorted into music/ or sfx/ by `routeAudio` once it can be measured). nil = top level.
    static func autoFolder(for name: String, folder: String?) -> String? {
        guard folder == nil, isProjectLibrary, !name.contains("/") else { return folder }
        switch kind(of: URL(fileURLWithPath: name)) {
        case .image: return "images"
        case .video: return "video"
        case .audio: return "audio"
        case .font: return "fonts"
        default: return nil
        }
    }

    /// Audio routed to the temporary `audio/` folder moves to music/ (longer than 20 s) or sfx/.
    private static func routeAudio(_ url: URL) -> URL {
        guard relativeName(of: url.path).map(parentFolder) == "audio" else { return url }
        let length = (try? AudioFileInfo.duration(of: url.path)) ?? 0
        guard let moved = try? move(url.path, toFolder: length > 20 ? "music" : "sfx") else { return url }
        let audioDir = directory.appendingPathComponent("audio")
        if (try? FileManager.default.contentsOfDirectory(atPath: audioDir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: audioDir)
        }
        return URL(fileURLWithPath: moved.to)
    }

    /// Where a new asset goes: the same name (replacing) if `overwrite`, otherwise a free name. Creates its folder.
    /// A nil `folder` in a project library means the file's type folder (see `autoFolder`).
    private static func destination(_ name: String, folder: String?, overwrite: Bool) throws -> URL {
        let valid = try validName(join(try validFolder(autoFolder(for: name, folder: folder)), name))
        let url = directory.appendingPathComponent(overwrite ? valid : uniqueName(valid))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// Writes bytes as a library file. `name` may include folders (`icons/badge.svg`); `folder` is prepended.
    /// Without `overwrite`, an existing name gets a numeric suffix.
    @discardableResult
    public static func write(_ data: Data, name: String, folder: String? = nil, overwrite: Bool = false) throws -> AssetInfo {
        let url = routeAudio(try {
            let url = try destination(name, folder: folder, overwrite: overwrite)
            try SceneJSON.write(data, to: url) // temp file + rename in the same folder
            return url
        }())
        guard let a = info(url) else { throw AssetError.failed("Cannot read back \(url.path)") }
        return a
    }

    /// Copies a local file into the library (into `folder`, created if needed).
    @discardableResult
    public static func importFile(_ source: URL, name: String? = nil, folder: String? = nil,
                                  overwrite: Bool = false) throws -> AssetInfo {
        let src = source.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir), !isDir.boolValue else {
            throw AssetError.failed("No file at \(src.path)")
        }
        let url = try destination(name ?? src.lastPathComponent, folder: folder, overwrite: overwrite)
        if url.path == src.path, let a = info(url) { return a } // already in the library
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.copyItem(at: src, to: url)
        let placed = routeAudio(url)
        // Copied from the shared library into a project: bring its credit along.
        if sharedDirectory.standardizedFileURL.path != directory.standardizedFileURL.path,
           let from = relativeName(of: src.path, in: sharedDirectory), let c = credits(in: sharedDirectory)[from],
           let to = relativeName(of: placed.path) {
            setCredit(c, for: to)
        }
        guard let a = info(placed) else { throw AssetError.failed("Cannot read back \(placed.path)") }
        return a
    }

    /// Downloads an http(s) URL into the library. Blocks the calling thread; do not call on the main thread.
    @discardableResult
    public static func download(_ remote: URL, name: String? = nil, folder: String? = nil, overwrite: Bool = false,
                                timeout: TimeInterval = 120) throws -> AssetInfo {
        guard let scheme = remote.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AssetError.failed("Only http(s) URLs can be downloaded: \(remote.absoluteString)")
        }
        _ = try validFolder(folder) // fail before downloading
        // Downloaded into memory and written straight into the library: a download task would stage the file in
        // the system temp folder, which sandboxed processes (e.g. vmotion under Claude Code's sandbox) cannot use.
        let (data, response) = try HTTP.fetch(remote, timeout: timeout)
        guard data.count <= maxDownloadBytes else { throw AssetError.failed("Download is larger than 500 MB") }
        guard !data.isEmpty else { throw AssetError.failed("Download failed: empty response from \(remote.host ?? "server")") }

        var fileName = name ?? response?.suggestedFilename ?? remote.lastPathComponent
        if fileName.isEmpty || fileName == "/" { fileName = "download" }
        if (fileName as NSString).pathExtension.isEmpty,
           let mime = response?.mimeType, let ext = UTType(mimeType: mime)?.preferredFilenameExtension {
            fileName += ".\(ext)"
        }
        return try write(data, name: fileName, folder: folder, overwrite: overwrite)
    }

    /// Renames or moves a library file. `newName` is the full name relative to the library, so
    /// `icons/logo.png` moves it into `icons` (created if needed). Returns the old and new full paths
    /// (to update layers that use it).
    public static func rename(_ nameOrPath: String, to newName: String) throws -> (from: String, to: String) {
        let src = try existing(nameOrPath)
        let dest = try url(for: newName)
        guard dest.path != src.path else { return (src.path, dest.path) }
        // Allow changing only the letter case on a case-insensitive volume.
        let caseOnly = dest.path.lowercased() == src.path.lowercased()
        if FileManager.default.fileExists(atPath: dest.path), !caseOnly { throw AssetError.exists(try validName(newName)) }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: src, to: dest)
        if let from = relativeName(of: src.path), let to = relativeName(of: dest.path) {
            moveCredits { $0 == from ? to : nil }
        }
        return (src.path, dest.path)
    }

    /// Moves a library file into `folder` ("" = top level), keeping its file name.
    public static func move(_ nameOrPath: String, toFolder folder: String) throws -> (from: String, to: String) {
        let src = try existing(nameOrPath)
        return try rename(src.path, to: join(try validFolder(folder), src.lastPathComponent))
    }

    /// Moves a library file to the Trash (recoverable from Finder). Returns its old path.
    @discardableResult
    public static func trash(_ nameOrPath: String) throws -> String {
        let url = try existing(nameOrPath)
        let name = relativeName(of: url.path)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if let name { setCredit(nil, for: name) }
        return url.path
    }

    // MARK: Folders

    /// Creates a folder (and its parents). Returns its name. Fine if it already exists.
    @discardableResult
    public static func createFolder(_ name: String) throws -> String {
        let valid = try validName(name)
        let url = directory.appendingPathComponent(valid, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            throw AssetError.exists(valid)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return valid
    }

    /// Renames or moves a folder with everything in it. `newName` is relative to the library
    /// (`brand/icons` moves `icons` into `brand`). Returns the old and new folder paths (for `replaceFolder`).
    public static func renameFolder(_ nameOrPath: String, to newName: String) throws -> (from: String, to: String) {
        let src = try existingFolder(nameOrPath).standardizedFileURL
        let dest = directory.appendingPathComponent(try validName(newName), isDirectory: true).standardizedFileURL
        guard dest.path != src.path else { return (src.path, dest.path) }
        let caseOnly = dest.path.lowercased() == src.path.lowercased()
        if dest.path.lowercased().hasPrefix(src.path.lowercased() + "/") {
            throw AssetError.failed("Cannot move a folder into itself")
        }
        if FileManager.default.fileExists(atPath: dest.path), !caseOnly { throw AssetError.exists(try validName(newName)) }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: src, to: dest)
        if let from = relativeName(of: src.path), let to = relativeName(of: dest.path) {
            moveCredits { $0.hasPrefix(from + "/") ? to + $0.dropFirst(from.count) : nil }
        }
        return (src.path, dest.path)
    }

    /// Moves a folder with everything in it to the Trash. Returns its old path.
    @discardableResult
    public static func trashFolder(_ nameOrPath: String) throws -> String {
        let url = try existingFolder(nameOrPath)
        let name = relativeName(of: url.path)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if let name {
            var all = credits()
            let before = all.count
            all = all.filter { !$0.key.hasPrefix(name + "/") }
            if all.count != before { saveCredits(all) }
        }
        return url.path
    }

    /// The file's text if it is small UTF-8 text.
    public static func readText(_ url: URL, maxBytes: Int = 200_000) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { throw AssetError.failed("File is larger than \(maxBytes / 1000) KB") }
        guard let s = String(data: data, encoding: .utf8) else { throw AssetError.failed("Not UTF-8 text") }
        return s
    }

    /// Decodes an image file. `size` is its natural size for layout. ImageIO handles bitmaps; SVG (which ImageIO
    /// cannot read) goes through NSImage and is rasterized with the longer side at least `vectorPixels`, so it
    /// stays sharp when scaled up.
    public static func loadImage(_ url: URL, vectorPixels: Double = 2048) -> (image: CGImage, size: CGSize)? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return (img, CGSize(width: img.width, height: img.height))
        }
        guard let ns = NSImage(contentsOf: url), ns.size.width > 0, ns.size.height > 0 else { return nil }
        let natural = ns.size
        let factor = max(1, vectorPixels / max(natural.width, natural.height))
        let w = Int((natural.width * factor).rounded()), h = Int((natural.height * factor).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: FrameRenderer.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ns.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        return (img, natural)
    }

    /// A downscaled image (about `maxPixels` on its longer side), or nil if the file is not an image.
    public static func thumbnail(_ url: URL, maxPixels: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return thumb
        }
        return loadImage(url, vectorPixels: Double(maxPixels))?.image // SVG
    }

    /// A PNG preview of an image file, at most `maxPixels` on its longer side.
    public static func previewPNG(_ url: URL, maxPixels: Int = 1024) -> Data? {
        guard let img = thumbnail(url, maxPixels: maxPixels) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

extension MotionScene {
    /// Ids of layers whose file is `path`.
    public func layers(usingPath path: String) -> [String] {
        let target = AssetStore.expand(path).standardizedFileURL.path
        return layers.filter { l in
            guard let p = l.path else { return false }
            return AssetStore.expand(p).standardizedFileURL.path == target
        }.map(\.id)
    }

    /// Points every layer that uses `old` at `new` (after a file rename). Returns the changed layer ids.
    @discardableResult
    public mutating func replacePath(_ old: String, with new: String) -> [String] {
        let ids = Set(layers(usingPath: old))
        for i in layers.indices where ids.contains(layers[i].id) { layers[i].path = new }
        return layers.filter { ids.contains($0.id) }.map(\.id)
    }

    /// Ids of layers whose file is inside the folder at `path` (at any depth).
    public func layers(inFolder path: String) -> [String] {
        let root = AssetStore.expand(path).standardizedFileURL.path + "/"
        return layers.filter { l in
            guard let p = l.path else { return false }
            return AssetStore.expand(p).standardizedFileURL.path.hasPrefix(root)
        }.map(\.id)
    }

    /// Repoints layers whose file is inside folder `old` to the same file under `new` (after a folder rename or
    /// move). Returns the changed layer ids.
    @discardableResult
    public mutating func replaceFolder(_ old: String, with new: String) -> [String] {
        let oldRoot = AssetStore.expand(old).standardizedFileURL.path + "/"
        let newRoot = AssetStore.expand(new).standardizedFileURL.path + "/"
        var ids: [String] = []
        for i in layers.indices {
            guard let p = layers[i].path else { continue }
            let full = AssetStore.expand(p).standardizedFileURL.path
            guard full.hasPrefix(oldRoot) else { continue }
            layers[i].path = newRoot + full.dropFirst(oldRoot.count)
            ids.append(layers[i].id)
        }
        return ids
    }
}

// MARK: - Credits

/// License and attribution of a downloaded asset, kept in the library's hidden `.credits.json`.
public struct AssetCredit: Codable, Hashable, Sendable {
    public var title: String
    public var creator: String?
    public var license: String
    public var licenseURL: String?
    public var sourceURL: String?
    /// Ready-to-paste credit line.
    public var attribution: String
    /// True when the license requires crediting the author (e.g. CC BY, CC BY-SA).
    public var requiresAttribution: Bool
    /// Where it came from, e.g. "openverse:<id>" or "iconify:mdi:rocket".
    public var ref: String

    public init(title: String, creator: String?, license: String, licenseURL: String?, sourceURL: String?,
                attribution: String, requiresAttribution: Bool, ref: String) {
        self.title = title; self.creator = creator; self.license = license; self.licenseURL = licenseURL
        self.sourceURL = sourceURL; self.attribution = attribution; self.requiresAttribution = requiresAttribution
        self.ref = ref
    }
}

extension AssetStore {
    static var creditsURL: URL { directory.appendingPathComponent(".credits.json") }

    public static func credits(in library: URL? = nil) -> [String: AssetCredit] {
        let url = library.map { $0.appendingPathComponent(".credits.json") } ?? creditsURL
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: AssetCredit].self, from: data)) ?? [:]
    }

    public static func credit(for name: String) -> AssetCredit? { credits()[name] }

    public static func setCredit(_ credit: AssetCredit?, for name: String) {
        var all = credits()
        guard all[name] != credit else { return }
        all[name] = credit
        saveCredits(all)
    }

    /// Re-keys credits after a move: `rename` returns the new name for a key, or nil to leave it.
    static func moveCredits(_ rename: (String) -> String?) {
        let all = credits()
        var changed = false
        var out: [String: AssetCredit] = [:]
        for (k, v) in all {
            if let n = rename(k) { out[n] = v; changed = true } else if out[k] == nil { out[k] = v }
        }
        if changed { saveCredits(out) }
    }

    static func saveCredits(_ all: [String: AssetCredit]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(all) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? SceneJSON.write(data, to: creditsURL)
        }
    }

    /// Credits of library files used by the scene's layers, in layer order, without duplicates.
    public static func credits(usedBy scene: MotionScene) -> [(name: String, credit: AssetCredit)] {
        let libraries = Set([directory.standardizedFileURL, sharedDirectory.standardizedFileURL])
        let all = libraries.map { ($0, credits(in: $0)) }
        var seen = Set<String>()
        var result: [(String, AssetCredit)] = []
        for l in scene.layers {
            guard let p = l.path else { continue }
            for (root, credits) in all {
                guard let name = relativeName(of: p, in: root), let c = credits[name] else { continue }
                if seen.insert(root.path + "/" + name).inserted { result.append((name, c)) }
                break
            }
        }
        return result
    }
}
