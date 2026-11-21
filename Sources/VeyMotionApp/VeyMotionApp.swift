import AppKit
import SwiftUI
import VeyMotionCore

@main
struct VeyMotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = SceneStore.shared
    @State private var chat = ChatStore.shared
    @State private var annotations = AnnotationStore.shared
    @AppStorage("ui.showSidebar") private var showSidebar = false
    @AppStorage("leftPanelTab") private var leftTab: LeftPanelTab = .layers
    @AppStorage("ui.showChat") private var showChat = true
    @AppStorage("showTimeline") private var showTimeline = false

    init() {
        AudioAnalysisCache.waitsOnMainThread = false
    }

    var body: some Scene {
        WindowGroup("Vey Motion") {
            ContentView()
                .environment(store)
                .environment(chat)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Vey Motion") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Vey Motion",
                        .applicationVersion: AppVersion.current,
                        .version: AppVersion.build ?? "dev",
                    ])
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
                SettingsLink { Text(LicenseStore.shared.isPro ? "Account…" : "Upgrade to VeyMotion Pro…") }
            }
            CommandGroup(replacing: .newItem) {
                Button("Projects…") { store.showProjects = true }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("New Project…") { store.showNewProject = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Project…") { store.openProjectWithPanel() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Open Recent Project") {
                    ForEach(store.recentProjects, id: \.self) { url in
                        Button(url.lastPathComponent) { store.openProject(url) }
                    }
                    if !store.recentProjects.isEmpty { Divider() }
                    Button("Clear Menu") { store.clearRecentProjects() }.disabled(store.recentProjects.isEmpty)
                }
                Button("Close Project") { store.closeProject() }.disabled(store.project == nil)
                Divider()
                Button("New Scene") { store.newScene() }.keyboardShortcut("n")
                Button("Open…") { store.open() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.save() }.keyboardShortcut("s")
                Button("Save As…") { store.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Export Video…") { store.exportVideo() }.keyboardShortcut("e")
            }
            // While marking up a frame, Undo/Redo/Delete act on the marks, not the scene.
            CommandGroup(replacing: .undoRedo) {
                if annotations.isActive {
                    Button("Undo Mark") { annotations.undo() }
                        .keyboardShortcut("z")
                        .disabled(!annotations.canUndo)
                    Button("Redo Mark") { annotations.redo() }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                        .disabled(!annotations.canRedo)
                } else {
                    Button(store.undoStack.last.map { "Undo \($0.label)" } ?? "Undo") { store.undo() }
                        .keyboardShortcut("z")
                        .disabled(!store.canUndo)
                    Button(store.redoStack.last.map { "Redo \($0.label)" } ?? "Redo") { store.redo() }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                        .disabled(!store.canRedo)
                }
            }
            CommandGroup(after: .sidebar) {
                Button(showSidebar ? "Hide Layers & Inspector" : "Show Layers & Inspector") { showSidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                // The Inspector sits under the layer list, so showing it means showing that tab.
                Button("Show Inspector") { showSidebar = true; leftTab = .layers }
                    .keyboardShortcut("i", modifiers: [.option, .command])
                Button("Show Assets") { showSidebar = true; leftTab = .assets }
                Button(showChat ? "Hide Chat" : "Show Chat") { showChat.toggle() }
                    .keyboardShortcut("l")
                Button(showTimeline ? "Hide Timeline" : "Show Timeline") { showTimeline.toggle() }
                    .keyboardShortcut("t", modifiers: [.control, .command])
                Divider()
                // The preview's zoom. Never disabled: at Fit, zooming out or fitting just does nothing.
                Button("Zoom In") { CanvasViewport.shared.zoomIn() }.keyboardShortcut("=")
                Button("Zoom Out") { CanvasViewport.shared.zoomOut() }.keyboardShortcut("-")
                Button("Zoom to Fit") { CanvasViewport.shared.reset() }.keyboardShortcut("0")
                Button(PreviewPresentation.shared.isActive ? "Exit Full Screen Preview" : "Full Screen Preview") {
                    PreviewPresentation.shared.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(store.showProjects)
                Divider()
            }
            CommandMenu("Layer") {
                Button("Add Rectangle") { store.addLayer(.rect) }
                Button("Add Ellipse") { store.addLayer(.ellipse) }
                Button("Add Path") { store.addLayer(.path) }
                Button("Add Text") { store.addLayer(.text) }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Add Image…") { store.addImageLayer() }
                Button("Add Video or Image Sequence…") { store.addVideoLayer() }
                Button("Add Audio File…") { store.addAudioLayer() }
                Menu("Add Template") {
                    ForEach(TemplateKind.allCases, id: \.self) { k in Button(k.title) { store.addTemplate(k) } }
                }
                Menu("Apply Look") {
                    ForEach(LookKind.allCases, id: \.self) { k in Button(k.title) { store.applyLook(k) } }
                }
                Menu("Add Generator") {
                    ForEach(GeneratorKind.allCases, id: \.self) { k in Button(k.title) { store.addGenerator(k) } }
                }
                Divider()
                Button("Duplicate") { store.duplicateSelected() }.keyboardShortcut("d").disabled(store.selection == nil)
                Button("Split at Playhead") { store.splitSelected() }.keyboardShortcut("b").disabled(store.selection == nil)
                Button("Group") { store.groupSelected() }.keyboardShortcut("g").disabled(store.selection == nil)
                Button("Ungroup") { store.ungroupSelected() }.keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(store.selection.flatMap { id in store.scene.layers.first { $0.id == id } }?.type != .group)
                if annotations.isActive {
                    Button(annotations.selection != nil ? "Delete Mark" : "Clear Marks") { annotations.delete() }
                        .keyboardShortcut(.delete).disabled(annotations.items.isEmpty)
                } else {
                    Button("Delete") { store.deleteSelected() }.keyboardShortcut(.delete).disabled(store.selection == nil)
                }
            }
            CommandGroup(after: .help) {
                Button("Copy Claude Code MCP Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.claudeCommand, forType: .string)
                    store.message = "Copied: \(store.claudeCommand)"
                }
            }
            // Shortcuts all use ⌘ so they never steal keystrokes from text fields.
            // Bare Space also toggles playback (AppDelegate monitor, skipped while editing text).
            CommandMenu("Playback") {
                Button(store.isPlaying ? "Pause" : "Play") { store.togglePlay() }.keyboardShortcut(.return)
                Button("Previous Frame") { store.step(frames: -1) }.keyboardShortcut(.leftArrow)
                Button("Next Frame") { store.step(frames: 1) }.keyboardShortcut(.rightArrow)
                Button("Go to Start") { store.seek(0) }.keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                Divider()
                Toggle("Cache Frames in Background", isOn: Binding(
                    get: { FrameCache.shared.fillsWhenIdle },
                    set: { FrameCache.shared.fillsWhenIdle = $0 }))
                Button("Purge Frame Cache") { FrameCache.shared.purge() }
            }
        }
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SceneStore.shared.startMCP()
        installSpaceToPlay()
        installClickOutsideToBlur()
        Updater.shared.start()
        LicenseStore.shared.start()
    }

    /// AppKit only moves focus when the clicked view accepts first responder, so clicking the canvas,
    /// timeline or empty panel space would leave a text field focused forever (and Space typed into it).
    /// Clicking anywhere outside the field being edited — or pressing Esc — ends editing.
    private func installClickOutsideToBlur() {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { e in
            guard let window = e.window, window.attachedSheet == nil,
                  let text = window.firstResponder as? NSTextView else { return e }
            if e.type == .keyDown {
                guard e.keyCode == 53 else { return e } // Esc
                window.makeFirstResponder(nil)
                return nil
            }
            // A field editor's delegate is the NSTextField it edits; a TextEditor is its own view.
            let editing: NSView = (text.isFieldEditor ? text.delegate as? NSView : nil) ?? text.enclosingScrollView ?? text
            let root = window.contentView?.superview ?? window.contentView
            if let hit = root?.hitTest(e.locationInWindow), hit.isDescendant(of: editing) { return e }
            window.makeFirstResponder(nil)
            return e
        }
    }

    /// Space toggles playback unless a text field/view is being edited (so typing spaces still works).
    private func installSpaceToPlay() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 49, // space
                  e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let window = e.window, window.attachedSheet == nil, !(window.firstResponder is NSText),
                  !AnnotationStore.shared.isActive // playing would drop the marks
            else { return e }
            SceneStore.shared.togglePlay()
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SceneStore.shared.shutdown()
        Updater.shared.installOnQuit()
    }
}
