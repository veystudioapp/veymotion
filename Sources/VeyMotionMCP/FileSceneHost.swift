import Foundation
import VeyMotionCore

/// Scene host backed by a JSON file: every mutation is written back to disk. Used by the CLI.
public final class FileSceneHost: SceneHost {
    public let url: URL
    private var scene: MotionScene
    private let lock = NSLock()

    /// Set when the file is a project's scene.json: its assets folder becomes the active library and paths inside
    /// the project are saved relative to it.
    public let project: URL?

    /// `activatesLibrary: false` leaves the active library alone (the app, for a project that is not open).
    public init(url: URL, activatesLibrary: Bool = true) throws {
        self.url = url
        project = ProjectStore.project(for: url)
        if activatesLibrary, let project { AssetStore.setActiveLibrary(ProjectStore.assetsURL(project)) }
        if FileManager.default.fileExists(atPath: url.path) {
            scene = try SceneJSON.decode(MotionScene.self, from: Data(contentsOf: url))
            scene.resolvePaths(relativeTo: url.deletingLastPathComponent())
        } else {
            scene = MotionScene()
            try SceneJSON.write(SceneJSON.encode(scene), to: url)
        }
    }

    public func currentScene() -> MotionScene {
        lock.lock(); defer { lock.unlock() }
        return scene
    }

    public func mutate(_ label: String, _ body: (inout MotionScene) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var s = scene
        try body(&s)
        let stored = project.map { s.relativizingPaths(to: $0) } ?? s
        try SceneJSON.write(SceneJSON.encode(stored), to: url)
        scene = s
    }
}
