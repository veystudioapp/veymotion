import AppKit
import CoreServices
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VeyMotionCore

/// Live view of the asset library folder and its subfolders. Watches the whole tree (FSEvents) so files added,
/// moved or removed by the agent (from the `vmotion` process or MCP) or in Finder show up immediately.
@Observable
final class AssetLibrary {
    /// The active library: the open project's assets, or the shared library.
    static let shared = AssetLibrary { AssetStore.directory }
    /// The shared library, browsed from the Assets panel while a project is open.
    static let global = AssetLibrary { AssetStore.sharedDirectory }

    /// Every file, at any depth.
    private(set) var assets: [AssetInfo] = []
    /// Every folder, e.g. `icons`, `icons/social`.
    private(set) var folders: [String] = []
    @ObservationIgnored private let root: () -> URL
    @ObservationIgnored private var watchedRoot: URL?
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var thumbnails: [String: (modified: Date, image: NSImage)] = [:]
    @ObservationIgnored private let thumbQueue = DispatchQueue(label: "veymotion.thumbnails", qos: .utility)

    private init(root: @escaping () -> URL) {
        self.root = root
        reload()
    }

    /// Re-reads and re-watches the library after its root changed (a project was opened or closed).
    func reload() {
        let dir = root()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if dir != watchedRoot {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            watchedRoot = dir
            watch(dir)
        }
        refresh()
    }

    func refresh() {
        let dir = root()
        let list = AssetStore.list(in: dir), dirs = AssetStore.folders(in: dir)
        let update = {
            if self.assets != list { self.assets = list }
            if self.folders != dirs { self.folders = dirs }
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }

    func subfolders(of folder: String) -> [String] {
        folders.filter { AssetStore.parentFolder(of: $0) == folder }
    }

    func files(in folder: String) -> [AssetInfo] {
        assets.filter { $0.folder == folder }
    }

    /// Number of files inside `folder`, at any depth.
    func fileCount(in folder: String) -> Int {
        assets.filter { $0.name.hasPrefix(folder + "/") }.count
    }

    private func watch(_ dir: URL) {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<AssetLibrary>.fromOpaque(info).takeUnretainedValue().refresh()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [dir.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    /// Cached thumbnail; nil while it is being made (the row re-renders when `assets` next changes or on `onAppear`).
    func thumbnail(for asset: AssetInfo, completion: @escaping (NSImage?) -> Void) {
        if let t = thumbnails[asset.path], t.modified == asset.modified { completion(t.image); return }
        guard asset.kind == .image else { completion(nil); return }
        thumbQueue.async {
            let cg = AssetStore.thumbnail(URL(fileURLWithPath: asset.path), maxPixels: 96)
            DispatchQueue.main.async {
                guard let cg else { completion(nil); return }
                let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.thumbnails[asset.path] = (asset.modified, img)
                completion(img)
            }
        }
    }
}

/// A row in the Assets list.
private enum AssetItem: Hashable {
    case file(String)   // asset name, e.g. icons/logo.svg
    case folder(String) // folder name, e.g. icons
}

struct AssetsPanel: View {
    @Environment(SceneStore.self) private var store
    @State private var library = AssetLibrary.shared
    @State private var sharedLibrary = AssetLibrary.global
    /// The folder being shown in each library ("" = top level).
    @AppStorage("assets.folder") private var projectFolder = ""
    @AppStorage("assets.sharedFolder") private var sharedFolder = ""
    /// Browsing the shared library while a project is open (read-only there, except "Copy to Project").
    @AppStorage("assets.showShared") private var showShared = false
    @State private var selection: AssetItem?
    @State private var renaming: AssetItem?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var confirmTrash: AssetItem?
    @State private var isDropTarget = false
    @State private var showStock = false

    private var readOnly: Bool { showShared && store.project != nil }
    private var lib: AssetLibrary { readOnly ? sharedLibrary : library }
    private var libRoot: URL { readOnly ? AssetStore.sharedDirectory : AssetStore.directory }

    private var folder: String {
        get { readOnly ? sharedFolder : projectFolder }
        nonmutating set { if readOnly { sharedFolder = newValue } else { projectFolder = newValue } }
    }

    /// Where imports into the shown folder go: nil at the top level, so a project files them by type.
    private var importTarget: String? { folder.isEmpty ? nil : folder }

    private var selectedFile: AssetInfo? {
        guard case let .file(name)? = selection else { return nil }
        return lib.assets.first { $0.name == name }
    }

    private var subfolders: [String] { lib.subfolders(of: folder) }
    private var files: [AssetInfo] { lib.files(in: folder) }

    var body: some View {
        VStack(spacing: 0) {
            if store.project != nil {
                Picker("Library", selection: $showShared) {
                    Text("Project").tag(false)
                    Text("Shared").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .help("Project: this project's own assets. Shared: files you reuse across projects — copy them in to use them.")
            }
            breadcrumb
            Divider()
            List(selection: $selection) {
                Section("\(folder.isEmpty ? rootTitle : leaf(folder)) (\(subfolders.count + files.count))") {
                    ForEach(subfolders, id: \.self) { f in
                        FolderRow(name: leaf(f), fileCount: lib.fileCount(in: f), acceptsDrops: !readOnly) { urls in
                            store.importAssets(urls, folder: f)
                        }
                        .tag(AssetItem.folder(f))
                        .draggable(URL(fileURLWithPath: libRoot.appendingPathComponent(f).path))
                    }
                    ForEach(files) { asset in
                        AssetRow(asset: asset, users: store.scene.layers(usingPath: asset.path))
                            .tag(AssetItem.file(asset.name))
                            .draggable(URL(fileURLWithPath: asset.path))
                    }
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: AssetItem.self) { items in
                menu(for: items.first)
            } primaryAction: { items in
                if case let .folder(f)? = items.first { open(f) }
            }
            .overlay {
                if subfolders.isEmpty && files.isEmpty {
                    VStack(spacing: 8) {
                        if readOnly {
                            Text("The shared library is empty.\nClose the project to manage it.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        } else if folder.isEmpty {
                            Text("Drop images or audio here,\nor ask Claude to add some.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Browse Free Assets…") { showStock = true }.controlSize(.small)
                        } else {
                            Text("This folder is empty.\nDrop files here to add them.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).opacity(isDropTarget ? 1 : 0))
            .dropDestination(for: URL.self) { urls, _ in
                guard !readOnly else { return false }
                let items = urls.filter(\.isFileURL)
                store.importAssets(items, folder: importTarget)
                return !items.isEmpty
            } isTargeted: { isDropTarget = $0 && !readOnly }
            Divider()
            HStack {
                if readOnly {
                    Button { if let a = selectedFile { store.copyToProject(a) } } label: { Image(systemName: "square.and.arrow.down") }
                        .disabled(selectedFile == nil)
                        .help("Copy to the project (filed by type)")
                } else {
                    Button { store.importAssetsWithPanel(folder: importTarget) } label: { Image(systemName: "plus") }
                        .help(folder.isEmpty && store.project != nil ? "Import files (filed by type)" : "Import files into this folder")
                    Button { newName = ""; creatingFolder = true } label: { Image(systemName: "folder.badge.plus") }
                        .help("New folder")
                    Button { if let s = selection { request(trash: s) } } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                        .help("Move to Trash")
                }
                Button { showStock = true } label: { Image(systemName: "globe") }
                    .help("Browse free photos, illustrations and icons")
                Spacer()
                Button { copySceneCredits() } label: { Image(systemName: "text.quote") }
                    .help("Copy credits for the downloaded assets used in this scene")
                Button { if let a = selectedFile { store.addFileLayer(a.path) } } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                    .disabled(selectedFile.map { ![.image, .audio, .video].contains($0.kind) } ?? true)
                    .help("Add to scene (or drag onto the canvas)")
                Button { NSWorkspace.shared.open(folder.isEmpty ? libRoot : libRoot.appendingPathComponent(folder)) } label: {
                    Image(systemName: "folder")
                }
                .help("Open this folder in Finder")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .onAppear {
            lib.refresh()
            leaveMissingFolder()
        }
        .onChange(of: lib.folders) { leaveMissingFolder() }
        .onChange(of: readOnly) { selection = nil; lib.refresh(); leaveMissingFolder() }
        // Another project's library: start at its top level.
        .onChange(of: store.project) {
            selection = nil
            renaming = nil
            confirmTrash = nil
            projectFolder = ""
        }
        .sheet(isPresented: $showStock) { StockBrowserSheet() }
        .alert(renameTitle, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Layers that use these files are updated.")
        }
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, let f = store.createAssetFolder(name, in: folder) { selection = .folder(f) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(folder.isEmpty ? "In the asset library" : "In \(folder)")
        }
        .confirmationDialog(trashTitle,
                            isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let item = confirmTrash { trash(item) }
                confirmTrash = nil
            }
        } message: {
            Text(trashMessage)
        }
    }

    // MARK: Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: 2) {
            Button { open(AssetStore.parentFolder(of: folder)) } label: { Image(systemName: "chevron.left") }
                .disabled(folder.isEmpty)
                .help("Up one folder")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    Crumb(title: rootTitle, isCurrent: folder.isEmpty, acceptsDrops: !readOnly) { open("") } onDrop: { urls in
                        store.importAssets(urls, folder: "")
                    }
                    ForEach(Array(ancestors.enumerated()), id: \.element) { i, path in
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                        Crumb(title: leaf(path), isCurrent: i == ancestors.count - 1, acceptsDrops: !readOnly) { open(path) } onDrop: { urls in
                            store.importAssets(urls, folder: path)
                        }
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// `icons/social` → ["icons", "icons/social"].
    private var ancestors: [String] {
        guard !folder.isEmpty else { return [] }
        var paths: [String] = []
        for part in folder.split(separator: "/") { paths.append(AssetStore.join(paths.last, String(part))) }
        return paths
    }

    private func leaf(_ path: String) -> String { (path as NSString).lastPathComponent }

    private var rootTitle: String {
        if readOnly { return "Shared" }
        return store.project?.lastPathComponent ?? "Assets"
    }

    private func open(_ f: String) {
        selection = nil
        folder = f
    }

    /// Goes up when the shown folder was renamed or deleted (e.g. by the agent or in Finder).
    private func leaveMissingFolder() {
        while !folder.isEmpty && !lib.folders.contains(folder) { folder = AssetStore.parentFolder(of: folder) }
    }

    // MARK: Menus

    @ViewBuilder
    private func menu(for item: AssetItem?) -> some View {
        switch item {
        case let .file(name)?:
            if let asset = lib.assets.first(where: { $0.name == name }) { fileMenu(asset) }
        case let .folder(f)? where readOnly:
            Button("Open") { open(f) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([libRoot.appendingPathComponent(f)]) }
        case let .folder(f)?:
            Button("Open") { open(f) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([AssetStore.directory.appendingPathComponent(f)])
            }
            moveMenu(excluding: f) { store.renameAssetFolder(f, to: AssetStore.join($0, leaf(f))) }
            Divider()
            Button("Rename…") { newName = leaf(f); renaming = .folder(f) }
            Button("Move to Trash", role: .destructive) { request(trash: .folder(f)) }
        case nil:
            if !readOnly {
                Button("New Folder…") { newName = ""; creatingFolder = true }
                Button("Import Files…") { store.importAssetsWithPanel(folder: importTarget) }
            }
        }
    }

    @ViewBuilder
    private func fileMenu(_ asset: AssetInfo) -> some View {
        if asset.kind == .image || asset.kind == .audio || asset.kind == .video {
            Button(readOnly ? "Add to Scene (copies into the project)" : "Add to Scene") { store.addFileLayer(asset.path) }
        }
        if readOnly {
            Button("Copy to Project") { store.copyToProject(asset) }
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.path)]) }
        if let credit = asset.credit {
            Button(credit.requiresAttribution ? "Copy Credit (required)" : "Copy Credit") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(credit.attribution, forType: .string)
                store.message = "Copied credit for \(asset.fileName)"
            }
            if let src = credit.sourceURL, let url = URL(string: src) {
                Button("Open Source Page") { NSWorkspace.shared.open(url) }
            }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(asset.path, forType: .string)
        }
        if !readOnly {
            Divider()
            moveMenu(excluding: nil) { store.moveAsset(asset, toFolder: $0) }
            Button("Rename…") { newName = asset.fileName; renaming = .file(asset.name) }
            Button("Move to Trash", role: .destructive) { request(trash: .file(asset.name)) }
        }
    }

    /// "Move To" submenu listing the library's folders, except the current one and (for a folder) itself and
    /// everything inside it.
    @ViewBuilder
    private func moveMenu(excluding moving: String?, perform: @escaping (String) -> Void) -> some View {
        let targets = ([""] + lib.folders).filter { f in
            f != folder && moving.map { f != $0 && !f.hasPrefix($0 + "/") } ?? true
        }
        Menu("Move To") {
            ForEach(targets, id: \.self) { f in
                Button(f.isEmpty ? "\(rootTitle) (top level)" : f) { perform(f) }
            }
        }
        .disabled(targets.isEmpty)
    }

    // MARK: Rename / trash

    private var renameTitle: String {
        if case .folder? = renaming { return "Rename Folder" }
        return "Rename Asset"
    }

    private func commitRename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        defer { renaming = nil }
        guard !name.isEmpty else { return }
        switch renaming {
        case let .file(n)?:
            if let a = lib.assets.first(where: { $0.name == n }), name != a.fileName { store.renameAsset(a, to: name) }
        case let .folder(f)?:
            if name != leaf(f) { store.renameAssetFolder(f, to: AssetStore.join(AssetStore.parentFolder(of: f), name)) }
        case nil:
            break
        }
    }

    private func users(of item: AssetItem) -> [String] {
        switch item {
        case let .file(n):
            return lib.assets.first { $0.name == n }.map { store.scene.layers(usingPath: $0.path) } ?? []
        case let .folder(f):
            return store.scene.layers(inFolder: libRoot.appendingPathComponent(f).path)
        }
    }

    private var trashTitle: String {
        switch confirmTrash {
        case let .file(n)?: return "Move \(leaf(n)) to the Trash?"
        case let .folder(f)?: return "Move the folder \(leaf(f)) and its \(lib.fileCount(in: f)) files to the Trash?"
        case nil: return ""
        }
    }

    private var trashMessage: String {
        guard let item = confirmTrash else { return "" }
        let used = users(of: item)
        return used.isEmpty ? "You can get it back from the Trash in Finder."
            : "Used by: \(used.joined(separator: ", ")). Those layers will show a missing-file placeholder."
    }

    /// Asks first when layers use the file(s) or the folder is not empty; otherwise the Trash is undo enough.
    private func request(trash item: AssetItem) {
        var ask = !users(of: item).isEmpty
        if case let .folder(f) = item, lib.fileCount(in: f) > 0 || !lib.subfolders(of: f).isEmpty { ask = true }
        if ask { confirmTrash = item } else { trash(item) }
    }

    private func trash(_ item: AssetItem) {
        switch item {
        case let .file(n):
            if let a = lib.assets.first(where: { $0.name == n }) { store.trashAsset(a) }
        case let .folder(f):
            store.trashAssetFolder(f)
        }
        if selection == item { selection = nil }
    }

    private func copySceneCredits() {
        let used = AssetStore.credits(usedBy: store.scene)
        guard !used.isEmpty else {
            store.message = "This scene uses no downloaded assets, so there is nothing to credit"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(used.map(\.credit.attribution).joined(separator: "\n"), forType: .string)
        let required = used.filter { $0.credit.requiresAttribution }.count
        store.message = "Copied \(used.count) credits (\(required) required) — paste them in the end card or description"
    }
}

/// One breadcrumb component; files and folders can be dropped on it to move them there.
private struct Crumb: View {
    let title: String
    let isCurrent: Bool
    var acceptsDrops = true
    let action: () -> Void
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(targeted ? 0.3 : 0)))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard acceptsDrops else { return false }
            let items = urls.filter(\.isFileURL)
            onDrop(items)
            return !items.isEmpty
        } isTargeted: { targeted = $0 && acceptsDrops }
    }
}

private struct FolderRow: View {
    let name: String
    let fileCount: Int
    let acceptsDrops: Bool
    let onDrop: ([URL]) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(targeted ? 0.35 : 0.12))
                Image(systemName: targeted ? "folder.fill.badge.plus" : "folder.fill").foregroundStyle(Color.accentColor)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text(fileCount == 1 ? "1 file" : "\(fileCount) files").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .help(acceptsDrops ? "Double-click to open. Drop files here to move them into \(name)." : "Double-click to open.")
        .dropDestination(for: URL.self) { urls, _ in
            guard acceptsDrops else { return false }
            let items = urls.filter(\.isFileURL)
            onDrop(items)
            return !items.isEmpty
        } isTargeted: { targeted = $0 && acceptsDrops }
    }
}

private struct AssetRow: View {
    let asset: AssetInfo
    let users: [String]
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit).padding(2)
                } else {
                    Image(systemName: icon).foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(asset.fileName).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(users.isEmpty ? asset.summary : "\(asset.summary) · in use")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if asset.credit?.requiresAttribution == true {
                        Text("CC BY").font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.25)))
                            .help("This asset's license requires a credit: \(asset.credit?.attribution ?? "")")
                    }
                }
            }
        }
        .help(users.isEmpty ? asset.path : "\(asset.path)\nUsed by: \(users.joined(separator: ", "))")
        .onAppear(perform: loadThumb)
        .onChange(of: asset.modified) { loadThumb() }
    }

    private func loadThumb() {
        AssetLibrary.shared.thumbnail(for: asset) { thumb = $0 }
    }

    private var icon: String {
        switch asset.kind {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .text: return "doc.text"
        case .other: return "doc"
        }
    }
}
