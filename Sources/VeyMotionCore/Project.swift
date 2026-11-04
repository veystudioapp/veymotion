import CoreGraphics
import Foundation

/// A project is a folder holding `scene.json` and an `assets/` library of its own:
///
///     My Video/
///       scene.json
///       assets/images/ icons/ music/ sfx/ voice/
///
/// Layer paths inside the project are saved relative to the project folder (`assets/images/bg.jpg`), so the folder
/// can be moved or shared. In memory they are absolute, like every other path.
public enum ProjectStore {
    public static let sceneFileName = "scene.json"
    public static let assetsFolderName = "assets"
    /// Created in every new project. Files without a folder are put in these by type.
    public static let standardFolders = ["images", "icons", "music", "sfx", "voice"]

    /// Where new projects go by default.
    public static var projectsDirectory: URL {
        if let p = ProcessInfo.processInfo.environment["VEYMOTION_PROJECTS_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/VeyMotion Projects", isDirectory: true)
    }

    public static func sceneURL(_ project: URL) -> URL { project.appendingPathComponent(sceneFileName) }
    public static func assetsURL(_ project: URL) -> URL {
        project.appendingPathComponent(assetsFolderName, isDirectory: true)
    }

    /// True if `url` is a project folder.
    public static func isProject(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            && FileManager.default.fileExists(atPath: sceneURL(url).path)
    }

    /// The project folder for a project folder, its `scene.json`, or nil for any other file.
    public static func project(for url: URL) -> URL? {
        let u = url.standardizedFileURL
        if isProject(u) { return u }
        if u.lastPathComponent == sceneFileName, isProject(u.deletingLastPathComponent()) {
            return u.deletingLastPathComponent()
        }
        return nil
    }

    /// Creates `<directory>/<name>/` with `scene` (or an empty scene) and the standard asset folders.
    /// The name gets a " 2", " 3"… suffix if a folder with that name exists. Returns the project folder.
    public static func create(name: String, in directory: URL? = nil, scene: MotionScene = MotionScene()) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty, !clean.hasPrefix(".") else { throw SceneError.invalid("Give the project a name") }
        let parent = directory ?? projectsDirectory
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var folder = parent.appendingPathComponent(clean, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(clean) \(n)", isDirectory: true)
            n += 1
        }
        for sub in standardFolders {
            try fm.createDirectory(at: assetsURL(folder).appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try save(scene, to: folder)
        return folder.standardizedFileURL
    }

    /// Reads a project's scene with its layer paths made absolute.
    public static func load(_ project: URL) throws -> MotionScene {
        var s = try SceneJSON.decode(MotionScene.self, from: Data(contentsOf: sceneURL(project)))
        s.resolvePaths(relativeTo: project)
        return s
    }

    /// Writes a project's scene with paths inside the project stored relative to it.
    public static func save(_ scene: MotionScene, to project: URL) throws {
        try SceneJSON.write(SceneJSON.encode(scene.relativizingPaths(to: project)), to: sceneURL(project))
    }
}

/// What the Projects screen shows for one project.
public struct ProjectSummary: Identifiable, Hashable, Sendable {
    public var url: URL
    public var name: String { url.lastPathComponent }
    /// When scene.json was last saved.
    public var modified: Date
    public var width: Int
    public var height: Int
    public var duration: Double
    public var layerCount: Int
    public var id: String { url.path }
}

extension ProjectStore {
    public static func summary(_ project: URL) -> ProjectSummary? {
        let scene = sceneURL(project)
        guard let s = try? SceneJSON.decode(MotionScene.self, from: Data(contentsOf: scene)) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: scene.path)[.modificationDate] as? Date) ?? nil
        return ProjectSummary(url: project.standardizedFileURL, modified: modified ?? .distantPast, width: s.width,
                              height: s.height, duration: s.duration, layerCount: s.layers.count)
    }

    /// Projects in `projectsDirectory` plus `extra` ones kept elsewhere (e.g. recent projects), newest first.
    public static func list(including extra: [URL] = []) -> [ProjectSummary] {
        let inFolder = (try? FileManager.default.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? []
        var seen = Set<String>()
        return (inFolder + extra)
            .map(\.standardizedFileURL)
            .filter { isProject($0) && seen.insert($0.path).inserted }
            .compactMap(summary)
            .sorted { $0.modified > $1.modified }
    }

    /// A frame from the middle of the project's scene, about `maxWidth` pixels wide.
    public static func thumbnail(_ project: URL, maxWidth: Double = 360) -> CGImage? {
        guard let s = try? load(project) else { return nil }
        let scale = min(1, maxWidth / Double(max(s.width, 1)))
        return FrameRenderer().makeImage(s, at: s.duration / 2, scale: scale)
    }

    /// Renames a project folder. Returns its new location.
    public static func rename(_ project: URL, to name: String) throws -> URL {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty, !clean.hasPrefix(".") else { throw SceneError.invalid("Give the project a name") }
        let dest = project.deletingLastPathComponent().appendingPathComponent(clean, isDirectory: true).standardizedFileURL
        guard dest.path != project.standardizedFileURL.path else { return dest }
        let caseOnly = dest.path.lowercased() == project.standardizedFileURL.path.lowercased()
        if FileManager.default.fileExists(atPath: dest.path), !caseOnly {
            throw SceneError.invalid("A project named \(clean) already exists there")
        }
        try FileManager.default.moveItem(at: project, to: dest)
        return dest
    }

    /// Copies a project next to itself as "<name> copy" (" copy 2"…). Returns the copy.
    public static func duplicate(_ project: URL) throws -> URL {
        let parent = project.deletingLastPathComponent()
        var dest = parent.appendingPathComponent("\(project.lastPathComponent) copy", isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = parent.appendingPathComponent("\(project.lastPathComponent) copy \(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.copyItem(at: project, to: dest)
        return dest.standardizedFileURL
    }

    /// Moves a project folder to the Trash.
    public static func trash(_ project: URL) throws {
        try FileManager.default.trashItem(at: project, resultingItemURL: nil)
    }
}

extension MotionScene {
    /// Makes relative layer paths absolute against `base` (the folder of the scene file).
    public mutating func resolvePaths(relativeTo base: URL) {
        for i in layers.indices {
            guard let p = layers[i].path, !p.isEmpty, !p.hasPrefix("/"), !p.hasPrefix("~") else { continue }
            layers[i].path = base.appendingPathComponent(p).standardizedFileURL.path
        }
    }

    /// A copy whose layer paths inside `base` are relative to it (paths elsewhere stay absolute).
    public func relativizingPaths(to base: URL) -> MotionScene {
        let root = base.standardizedFileURL.path + "/"
        var s = self
        for i in s.layers.indices {
            guard let p = s.layers[i].path else { continue }
            let full = AssetStore.expand(p).standardizedFileURL.path
            if full.hasPrefix(root) { s.layers[i].path = String(full.dropFirst(root.count)) }
        }
        return s
    }
}
