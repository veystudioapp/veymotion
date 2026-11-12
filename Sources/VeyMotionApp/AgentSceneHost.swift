import Foundation
import VeyMotionCore
import VeyMotionMCP

/// The scene one chat agent edits, served on that agent's own control socket. While the agent's project (or loose
/// scene) is open, calls go to `SceneStore` (live and undoable); once the user has switched to another project,
/// they go to the agent's project folder on disk, so a turn that is still running finishes there instead of
/// editing the project now open.
///
/// Every call decides and runs on the main thread, where documents are switched, so an edit is never written to
/// a file that is being opened (or saved) at the same moment.
final class AgentSceneHost: SceneHost {
    private let store: SceneStore
    private let lock = NSLock()
    private var _project: URL?

    init(store: SceneStore, project: URL?) {
        self.store = store
        _project = project?.standardizedFileURL
    }

    /// The project the conversation belongs to (nil = the loose scene). Changes when the open project is renamed.
    var project: URL? {
        get { lock.lock(); defer { lock.unlock() }; return _project }
        set { lock.lock(); _project = newValue?.standardizedFileURL; lock.unlock() }
    }

    var assetLibrary: URL? { project.map(ProjectStore.assetsURL) }

    /// Main thread only.
    private var isOpen: Bool { store.project?.standardizedFileURL.path == project?.path }

    func currentScene() -> MotionScene {
        onMain {
            if isOpen { return store.scene }
            return (try? fileHost().currentScene()) ?? MotionScene()
        }
    }

    func mutate(_ label: String, _ body: (inout MotionScene) throws -> Void) throws {
        try onMain {
            if isOpen { return try store.mutate(label, body) }
            try fileHost().mutate(label, body)
        }
    }

    /// The project's scene file, read again for every call (the user may have opened, edited and left it since).
    private func fileHost() throws -> FileSceneHost {
        guard let project else { throw SceneError.invalid("The scene this conversation was editing is closed.") }
        let url = ProjectStore.sceneURL(project)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SceneError.invalid("The project \(project.lastPathComponent) is no longer at \(project.path).")
        }
        return try FileSceneHost(url: url, activatesLibrary: false)
    }

    private func onMain<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }
}
