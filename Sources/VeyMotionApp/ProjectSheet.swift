import AppKit
import SwiftUI
import VeyMotionCore

/// New Project (File menu or the Projects screen): name, location and whether to start from the current scene.
struct NewProjectSheet: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("projects.location") private var location = ProjectStore.projectsDirectory.path
    @State private var name = "Untitled Project"
    @State private var keepScene = false
    /// Called after a project was created (e.g. to close the Projects screen too).
    var onCreated: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Project").font(.headline)
            Form {
                TextField("Name", text: $name)
                LabeledContent("Location") {
                    HStack {
                        Text((location as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseLocation)
                    }
                }
                Toggle("Start with the current scene", isOn: $keepScene)
                    .help("Moves the scene you are editing into the project and copies the files it uses into the project's assets.")
            }
            Text("Creates a folder with scene.json and assets/ (images, icons, music, sfx, voice). New files — yours and Claude's — are filed by type automatically.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let before = store.project
                    store.createProject(name: name, in: URL(fileURLWithPath: location, isDirectory: true), keepScene: keepScene)
                    dismiss()
                    if store.project != before, store.project != nil { onCreated?() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { keepScene = store.project == nil && store.fileURL == nil && store.isDirty }
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: location)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { location = url.path }
    }
}

/// The Projects screen: fills the window at launch and with File ▸ Projects… (⇧⌘P). Every project, with a preview,
/// to open or manage. Leaving it (opening a project or going back) shows the editor.
struct ProjectsScreen: View {
    @Environment(SceneStore.self) private var store
    @State private var projects: [ProjectSummary] = []
    @State private var search = ""
    @State private var selection: URL?
    @State private var renaming: ProjectSummary?
    @State private var newName = ""
    @State private var confirmTrash: ProjectSummary?
    @State private var creating = false

    private var shown: [ProjectSummary] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Projects").font(.largeTitle.weight(.bold))
                    Text("\(projects.count) projects · \((ProjectStore.projectsDirectory.path as NSString).abbreviatingWithTildeInPath)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search projects", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Open Other…") { store.openProjectWithPanel(); leaveIfOpened() }
                Button { creating = true } label: { Label("New Project", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .help("New project (⇧⌘N)")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            Divider()

            Group {
                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No projects yet", systemImage: "folder.badge.plus")
                    } description: {
                        Text("A project keeps a video's scene and all its files together in one folder.")
                    } actions: {
                        Button("New Project") { creating = true }.buttonStyle(.borderedProminent)
                    }
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 20, alignment: .top)], spacing: 24) {
                            ForEach(shown) { p in
                                ProjectCard(project: p, isOpen: p.url == store.project, isSelected: p.url == selection)
                                    .onTapGesture(count: 2) { open(p.url) }
                                    .onTapGesture { selection = p.url }
                                    .contextMenu { menu(for: p) }
                            }
                        }
                        .padding(28)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Button { store.showProjects = false } label: {
                    Label(store.project == nil ? "Continue Without a Project" : "Back to \(store.project!.lastPathComponent)",
                          systemImage: "chevron.left")
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Open") { if let selection { open(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Vey Motion")
        .navigationSubtitle("Projects")
        .onAppear(perform: reload)
        .sheet(isPresented: $creating) { NewProjectSheet(onCreated: { store.showProjects = false }) }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let p = renaming { store.renameProject(p.url, to: newName); reload() }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Move \(confirmTrash?.name ?? "") to the Trash?",
                            isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let p = confirmTrash { store.trashProject(p.url); reload() }
                confirmTrash = nil
            }
        } message: {
            Text("The whole folder — scene and assets — goes to the Trash. You can get it back from Finder.")
        }
    }

    @ViewBuilder
    private func menu(for p: ProjectSummary) -> some View {
        Button("Open") { open(p.url) }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
        Divider()
        Button("Rename…") { newName = p.name; renaming = p }
        Button("Duplicate") { store.duplicateProject(p.url); reload() }
        Divider()
        Button("Move to Trash", role: .destructive) { confirmTrash = p }
            .disabled(p.url == store.project)
    }

    private func reload() {
        projects = ProjectStore.list(including: store.recentProjects + [store.project].compactMap { $0 })
        if let s = selection, !projects.contains(where: { $0.url == s }) { selection = nil }
    }

    private func open(_ url: URL) {
        if url == store.project { store.showProjects = false; return }
        store.openProject(url)
        leaveIfOpened()
    }

    private func leaveIfOpened() {
        if store.project != nil { store.showProjects = false }
    }
}

private struct ProjectCard: View {
    let project: ProjectSummary
    let isOpen: Bool
    let isSelected: Bool
    @State private var thumb: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Every card uses the same 16:9 frame so grid rows stay even; the scene is fitted
            // inside it (portrait scenes get side bars instead of a tall card).
            Color.secondary.opacity(0.12)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "film").font(.title).foregroundStyle(.tertiary)
                    }
                }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if isOpen {
                    Text("Open").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            Text(project.name).font(.headline).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 4) {
                Text(project.modified, format: .relative(presentation: .named))
                Text("·")
                Text(String(format: "%.1fs · %d layers", project.duration, project.layerCount))
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(project.url.path)
        .onAppear(perform: loadThumb)
        .onChange(of: project.modified) { loadThumb() }
    }

    private func loadThumb() {
        let url = project.url
        DispatchQueue.global(qos: .userInitiated).async {
            let cg = ProjectStore.thumbnail(url)
            DispatchQueue.main.async {
                thumb = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            }
        }
    }
}
