import AppKit
import SwiftUI
import VeyMotionCore

/// Frame sizes a new project can start with.
struct ProjectSize: Hashable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let width: Int, height: Int

    static let all: [ProjectSize] = [
        ProjectSize(id: "landscape", title: "16:9", detail: "YouTube", width: 1920, height: 1080),
        ProjectSize(id: "portrait", title: "9:16", detail: "TikTok · Reels", width: 1080, height: 1920),
        ProjectSize(id: "square", title: "1:1", detail: "Square", width: 1080, height: 1080),
        ProjectSize(id: "feed", title: "4:5", detail: "Feed", width: 1080, height: 1350),
        ProjectSize(id: "uhd", title: "4K", detail: "16:9 UHD", width: 3840, height: 2160),
    ]
}

/// New Project (File menu or the Projects screen): name, location and what to start with (an empty scene of a
/// chosen size, the sample scene, or the scene being edited).
struct NewProjectSheet: View {
    private enum Start: String, CaseIterable, Identifiable {
        case blank, sample, current
        var id: String { rawValue }
        var title: String {
            switch self {
            case .blank: return "Empty"
            case .sample: return "Sample"
            case .current: return "Current scene"
            }
        }
        var symbol: String {
            switch self {
            case .blank: return "rectangle.dashed"
            case .sample: return "sparkles"
            case .current: return "square.and.arrow.down.on.square"
            }
        }
        var detail: String {
            switch self {
            case .blank: return "A blank canvas"
            case .sample: return "A demo to remix"
            case .current: return "Keep what you made"
            }
        }
    }

    private static let lengths: [Double] = [6, 10, 15, 30, 60]

    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("projects.location") private var location = ProjectStore.projectsDirectory.path
    @AppStorage("projects.lastSize") private var sizeId = ProjectSize.all[0].id
    @State private var name = "Untitled Project"
    @State private var start = Start.blank
    @State private var duration = 10.0
    /// Called after a project was created (e.g. to close the Projects screen too).
    var onCreated: (() -> Void)?

    private var size: ProjectSize { ProjectSize.all.first { $0.id == sizeId } ?? ProjectSize.all[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Project").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                TextField("Project name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text((location as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Change…", action: chooseLocation).buttonStyle(.link)
                }
                .font(.callout).foregroundStyle(.secondary)
                .help("A folder with scene.json and assets/. New files — yours and Claude's — are filed by type.")
            }

            section("Start with") {
                HStack(spacing: 10) {
                    ForEach(Start.allCases) { s in
                        Button { start = s } label: {
                            VStack(spacing: 6) {
                                Image(systemName: s.symbol).font(.title2).frame(height: 28)
                                    .foregroundStyle(start == s ? Color.accentColor : .secondary)
                                VStack(spacing: 1) {
                                    Text(s.title).fontWeight(.medium)
                                    Text(s.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12).padding(.horizontal, 6)
                        }
                        .buttonStyle(ChoiceTileStyle(selected: start == s))
                    }
                }
            }

            switch start {
            case .blank:
                section("Format") {
                    HStack(spacing: 8) {
                        ForEach(ProjectSize.all) { s in
                            Button { sizeId = s.id } label: { formatTile(s) }
                                .buttonStyle(ChoiceTileStyle(selected: sizeId == s.id))
                                .help("\(s.width) × \(s.height)")
                        }
                    }
                }
                section("Length") {
                    HStack(spacing: 6) {
                        ForEach(Self.lengths, id: \.self) { v in
                            Button("\(Int(v)) s") { duration = v }
                                .buttonStyle(ChoiceTileStyle(selected: duration == v, capsule: true))
                        }
                        Spacer(minLength: 12)
                        TextField("", value: $duration, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            case .sample:
                note("A short demo (a title, a chart, a finished look) to play with, re-style or ask Claude to change.")
            case .current:
                note("Moves the scene you are editing into the project and copies the files it uses into the project's assets.")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button("Create Project") {
                    let before = store.project
                    let how: SceneStore.ProjectStart
                    switch start {
                    case .blank: how = .blank(width: size.width, height: size.height, duration: max(1, duration))
                    case .sample: how = .sample
                    case .current: how = .currentScene
                    }
                    store.createProject(name: name, in: URL(fileURLWithPath: location, isDirectory: true), start: how)
                    dismiss()
                    if store.project != before, store.project != nil { onCreated?() }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            if store.project == nil && store.fileURL == nil && store.isDirty { start = .current }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private func formatTile(_ s: ProjectSize) -> some View {
        let box = 34.0, longest = Double(max(s.width, s.height))
        return VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(sizeId == s.id ? Color.accentColor : .secondary, lineWidth: 1.5)
                .frame(width: box * Double(s.width) / longest, height: box * Double(s.height) / longest)
                .frame(width: box, height: box)
            VStack(spacing: 1) {
                Text(s.title).fontWeight(.medium)
                Text(s.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10).padding(.horizontal, 4)
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

/// A selectable card or chip: accent outline and tint when selected.
private struct ChoiceTileStyle: ButtonStyle {
    var selected: Bool
    var capsule = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: capsule ? 100 : 10, style: .continuous)
        configuration.label
            .padding(.horizontal, capsule ? 12 : 0).padding(.vertical, capsule ? 5 : 0)
            .frame(maxWidth: capsule ? nil : .infinity)
            .contentShape(shape)
            .background(shape.fill(selected ? Color.accentColor.opacity(0.12)
                                            : Color.primary.opacity(configuration.isPressed ? 0.08 : 0.04)))
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1),
                                        lineWidth: selected ? 1.5 : 1))
            .foregroundStyle(selected && capsule ? Color.accentColor : .primary)
    }
}

/// The Projects screen: fills the window at launch and with File ▸ Projects… (⇧⌘P). A sidebar (Home, All Projects,
/// formats, search, the plan) and, on Home, the project being edited (or the latest one) as a large banner over
/// shelves of the others. Leaving it (opening a project) shows the editor.
struct ProjectsScreen: View {
    fileprivate enum Filter: String, Hashable, Identifiable {
        case home, all, landscape, portrait, square
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: "Home"
            case .all: "All Projects"
            case .landscape: "Landscape"
            case .portrait: "Portrait"
            case .square: "Square"
            }
        }
        var symbol: String {
            switch self {
            case .home: "house"
            case .all: "square.grid.2x2"
            case .landscape: "rectangle"
            case .portrait: "rectangle.portrait"
            case .square: "square"
            }
        }
        func includes(_ p: ProjectSummary) -> Bool {
            let w = Double(p.width), h = Double(p.height)
            switch self {
            case .home, .all: return true
            case .landscape: return w > h * 1.05
            case .portrait: return h > w * 1.05
            case .square: return w <= h * 1.05 && h <= w * 1.05
            }
        }
        /// The shape of this format's cards on Home: posters for portrait scenes.
        var cardAspect: CGFloat {
            switch self {
            case .portrait: 9 / 16
            case .square: 1
            default: 16 / 9
            }
        }
    }

    @Environment(SceneStore.self) private var store
    @State private var projects: [ProjectSummary] = []
    @State private var search = ""
    @State private var filter: Filter? = .home
    @State private var selection: URL?
    @State private var renaming: ProjectSummary?
    @State private var newName = ""
    @State private var confirmTrash: ProjectSummary?
    @State private var creating = false

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    /// The banner on Home: the project being edited, else the one saved last.
    private var featured: ProjectSummary? {
        projects.first { $0.url == store.project } ?? projects.first
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Other…") { store.openProjectWithPanel(); leaveIfOpened() }
                Button { creating = true } label: { Label("New Project", systemImage: "plus").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent)
                    .help("New project (⇧⌘N)")
            }
        }
        .navigationTitle("Vey Motion")
        .modifier(HiddenWindowTitle())
        .onAppear(perform: reload)
        .onChange(of: filter) { if filter != nil { search = "" } }
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

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section {
                ForEach([Filter.home, .all]) { f in
                    Label(f.title, systemImage: f.symbol).tag(f)
                }
            }
            Section("Formats") {
                ForEach([Filter.landscape, .portrait, .square]) { f in
                    Label(f.title, systemImage: f.symbol)
                        .badge(projects.filter(f.includes).count)
                        .tag(f)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { PlanRow().padding(10) }
        .opaqueColumn()
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if projects.isEmpty {
            welcome
        } else if !query.isEmpty {
            let found = projects.filter { $0.name.localizedCaseInsensitiveContains(query) }
            gridPage(title: "Results for “\(query)”", items: found)
        } else if let f = filter, f != .home {
            gridPage(title: f.title, items: projects.filter(f.includes))
        } else {
            home
        }
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                if let hero = featured {
                    ProjectHero(project: hero, isOpen: hero.url == store.project, open: { open(hero.url) }) {
                        menu(for: hero)
                    }
                }
                let others = projects.filter { $0.url != featured?.url }
                if !others.isEmpty {
                    shelf("Recent", target: .all, aspect: 16 / 9, width: 280, items: Array(others.prefix(12)))
                }
                ForEach([Filter.landscape, .portrait, .square]) { f in
                    let items = projects.filter(f.includes)
                    // A format shelf only says something when the projects come in more than one shape.
                    if !items.isEmpty, items.count < projects.count {
                        shelf(f.title, target: f, aspect: f.cardAspect, width: f == .portrait ? 160 : f == .square ? 210 : 280,
                              items: Array(items.prefix(16)))
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .ignoresSafeArea(edges: .top)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }

    private func shelf(_ title: String, target: Filter, aspect: CGFloat, width: CGFloat,
                       items: [ProjectSummary]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { filter = target } label: {
                HStack(spacing: 5) {
                    Text(title).font(.title2.weight(.bold))
                    Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 20) {
                    ForEach(items) { p in card(p, aspect: aspect).frame(width: width) }
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 8)
            }
            .scrollClipDisabled()
        }
    }

    private func gridPage(title: String, items: [ProjectSummary]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle.weight(.bold))
                    Text(items.count == 1 ? "1 project" : "\(items.count) projects")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if items.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No projects here" : "No results",
                                           systemImage: query.isEmpty ? "film.stack" : "magnifyingglass")
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 22, alignment: .top)],
                              spacing: 26) {
                        ForEach(items) { p in card(p, aspect: 16 / 9) }
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
        }
    }

    private func card(_ p: ProjectSummary, aspect: CGFloat) -> some View {
        ProjectCard(project: p, isOpen: p.url == store.project, isSelected: p.url == selection, aspect: aspect)
            .onTapGesture(count: 2) { open(p.url) }
            .onTapGesture { selection = p.url }
            .contextMenu { menu(for: p) }
    }

    /// No projects yet: one banner that says what a project is and starts one.
    private var welcome: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                Color.black
                RadialGradient(colors: [Color.indigo.opacity(0.9), .clear], center: UnitPoint(x: 0.8, y: 0.15),
                               startRadius: 0, endRadius: 700)
                RadialGradient(colors: [Color.pink.opacity(0.55), .clear], center: UnitPoint(x: 0.25, y: 0.95),
                               startRadius: 0, endRadius: 600)
            }
            .modifier(ExtendsUnderSidebar())
            VStack(alignment: .leading, spacing: 14) {
                Text("Welcome to Vey Motion").font(.system(size: 46, weight: .bold))
                Text("A project keeps a video's scene and all its files together in one folder. Start with the sample to see what a finished piece is made of, then describe your own video in the chat.")
                    .font(.title3).foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        store.createProject(name: "Sample", in: ProjectStore.projectsDirectory, start: .sample)
                        leaveIfOpened()
                    } label: { Label("Open the Sample Project", systemImage: "play.fill") }
                        .buttonStyle(HeroButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                    Button { creating = true } label: { Label("New Project", systemImage: "plus") }
                        .buttonStyle(HeroButtonStyle(prominent: false))
                }
                .padding(.top, 8)
            }
            .foregroundStyle(.white)
            .padding(48)
        }
        .ignoresSafeArea()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .environment(\.colorScheme, .dark)
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

/// The large banner at the top of Home: the project's frame edge to edge, darkened toward its title and buttons.
private struct ProjectHero<Actions: View>: View {
    let project: ProjectSummary
    let isOpen: Bool
    let open: () -> Void
    @ViewBuilder let actions: () -> Actions

    private var isWide: Bool { Double(project.width) >= Double(project.height) * 1.3 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                Color.black
                artwork
                LinearGradient(stops: [.init(color: .black.opacity(0.9), location: 0),
                                       .init(color: .black.opacity(0.35), location: 0.45),
                                       .init(color: .clear, location: 0.8)],
                               startPoint: .bottom, endPoint: .top)
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .center)
            }
            .modifier(ExtendsUnderSidebar())

            VStack(alignment: .leading, spacing: 10) {
                Text(isOpen ? "EDITING NOW" : "CONTINUE WHERE YOU LEFT OFF")
                    .font(.caption.weight(.semibold)).tracking(1.2)
                    .foregroundStyle(.white.opacity(0.65))
                Text(project.name)
                    .font(.system(size: 44, weight: .bold))
                    .lineLimit(2)
                    .frame(maxWidth: 640, alignment: .leading)
                HStack(spacing: 6) {
                    Text("\(project.width)×\(project.height)")
                    Text("·")
                    Text(String(format: "%.1f s", project.duration))
                    Text("·")
                    Text(project.layerCount == 1 ? "1 layer" : "\(project.layerCount) layers")
                    Text("·")
                    Text("edited \(project.modified, format: .relative(presentation: .named))")
                }
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 12) {
                    Button(action: open) {
                        Label(isOpen ? "Back to Editing" : "Open", systemImage: "play.fill")
                    }
                    .buttonStyle(HeroButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    Menu { actions() } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(.white.opacity(0.18)))
                            .contentShape(Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.top, 10)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .containerRelativeFrame(.vertical) { h, _ in min(max(h * 0.66, 340), 660) }
        .clipped()
        .environment(\.colorScheme, .dark)
        .onTapGesture(count: 2, perform: open)
        .contextMenu { actions() }
    }

    @ViewBuilder
    private var artwork: some View {
        if isWide {
            Color.clear.overlay { ProjectThumb(project: project, size: .large, mode: .fill) }.clipped()
        } else {
            // A tall or square frame would be mostly cropped: show it whole on the right, over a blur of itself.
            Color.clear
                .overlay { ProjectThumb(project: project, size: .large, mode: .fill).blur(radius: 50).opacity(0.7) }
                .overlay(alignment: .trailing) {
                    ProjectThumb(project: project, size: .large, mode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                        .padding(.vertical, 60)
                        .padding(.trailing, 80)
                }
                .clipped()
        }
    }
}

private struct HeroButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 22)
            .frame(height: 40)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.18)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// The account at the foot of the sidebar: the plan, opening the Account panel.
private struct PlanRow: View {
    @Bindable var license = LicenseStore.shared
    @State private var showPanel = false

    var body: some View {
        Button { if license.info == nil { license.presentUpgrade() } else { showPanel.toggle() } } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(license.info?.name ?? license.info?.email ?? "Vey Motion")
                        .font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        if license.isPro { ProBadge() } else { Text("Free plan · Upgrade") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPanel, arrowEdge: .top) {
            AccountPanel().padding(16).frame(width: 400)
        }
    }
}

private struct ProjectCard: View {
    let project: ProjectSummary
    let isOpen: Bool
    let isSelected: Bool
    var aspect: CGFloat = 16 / 9
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Every card in a row has the same frame so rows stay even; the scene is fitted inside it, over a blur
            // of itself where the shapes differ.
            Color.black
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay { ProjectThumb(project: project, size: .small, mode: .fill).blur(radius: 18).opacity(0.6) }
                .overlay { ProjectThumb(project: project, size: .small, mode: .fit) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.08),
                                      lineWidth: isSelected ? 3 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if isOpen {
                        Text("Editing").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.32 : 0.14), radius: hovering ? 14 : 5, y: hovering ? 8 : 2)
                .scaleEffect(hovering ? 1.03 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.headline).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(project.modified, format: .relative(presentation: .named))
                    Text("·")
                    Text(String(format: "%.1fs", project.duration))
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .help(project.url.path)
        .onHover { h in withAnimation(.easeOut(duration: 0.16)) { hovering = h } }
    }
}

/// A project's middle frame, from `ProjectThumbnails`.
private struct ProjectThumb: View {
    let project: ProjectSummary
    var size: ProjectThumbnails.Size
    var mode: ContentMode

    var body: some View {
        if let image = ProjectThumbnails.shared.image(for: project, size: size) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: mode)
        } else {
            Image(systemName: "film").font(.title).foregroundStyle(.white.opacity(0.3))
        }
    }
}

/// Rendered project frames, one per project, save and size; rendered off the main thread on first use.
@MainActor @Observable
private final class ProjectThumbnails {
    enum Size: Double { case small = 480, large = 1600 }

    static let shared = ProjectThumbnails()
    private var images: [String: NSImage] = [:]
    @ObservationIgnored private var requested = Set<String>()

    private func key(_ p: ProjectSummary, _ size: Size) -> String {
        "\(p.id)|\(p.modified.timeIntervalSinceReferenceDate)|\(Int(size.rawValue))"
    }

    /// The image if it is ready (a large request falls back on the small one meanwhile); starts rendering it if not.
    func image(for p: ProjectSummary, size: Size) -> NSImage? {
        let k = key(p, size)
        if let image = images[k] { return image }
        if !requested.contains(k) {
            requested.insert(k)
            let url = p.url, maxWidth = size.rawValue
            // GCD's global queues give worker threads a small stack, which deeply nested groups can overflow
            // while decoding/resolving the scene (see MotionScene.resolveLinks). Use a thread with a full stack.
            let thread = Thread {
                let cg = ProjectStore.thumbnail(url, maxWidth: maxWidth)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if let cg {
                            ProjectThumbnails.shared.images[k] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                        }
                    }
                }
            }
            thread.stackSize = 8 * 1024 * 1024
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        return size == .large ? image(for: p, size: .small) : nil
    }
}

/// On macOS 26 the content behind the sidebar is a mirrored blur of this view (shows only where the sidebar lets it).
private struct ExtendsUnderSidebar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.backgroundExtensionEffect()
        } else {
            content
        }
    }
}

/// The Projects screen shows no window title: the sidebar says where you are.
private struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
