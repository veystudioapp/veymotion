import AppKit
import SwiftUI
import VeyMotionCore

@main
struct VeyMotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = SceneStore.shared
    @State private var chat = ChatStore.shared

    init() {
        AudioAnalysisCache.waitsOnMainThread = false
    }

    var body: some Scene {
        WindowGroup("VeyMotion") {
            ContentView()
                .environment(store)
                .environment(chat)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .commands {
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
                Button("Publish Video…") { store.showPublish = true }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(store.undoStack.last.map { "Undo \($0.label)" } ?? "Undo") { store.undo() }
                    .keyboardShortcut("z")
                    .disabled(!store.canUndo)
                Button(store.redoStack.last.map { "Redo \($0.label)" } ?? "Redo") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
            }
            CommandMenu("Layer") {
                Button("Add Rectangle") { store.addLayer(.rect) }
                Button("Add Ellipse") { store.addLayer(.ellipse) }
                Button("Add Path") { store.addLayer(.path) }
                Button("Add Text") { store.addLayer(.text) }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Add Image…") { store.addImageLayer() }
                Button("Add Video or Image Sequence…") { store.addVideoLayer() }
                Button("Add Audio File…") { store.addAudioLayer() }
                Divider()
                Button("Duplicate") { store.duplicateSelected() }.keyboardShortcut("d").disabled(store.selection == nil)
                Button("Delete") { store.deleteSelected() }.keyboardShortcut(.delete).disabled(store.selection == nil)
            }
            // Shortcuts all use ⌘ so they never steal keystrokes from text fields.
            // Bare Space also toggles playback (AppDelegate monitor, skipped while editing text).
            CommandMenu("Playback") {
                Button(store.isPlaying ? "Pause" : "Play") { store.togglePlay() }.keyboardShortcut(.return)
                Button("Previous Frame") { store.step(frames: -1) }.keyboardShortcut(.leftArrow)
                Button("Next Frame") { store.step(frames: 1) }.keyboardShortcut(.rightArrow)
                Button("Go to Start") { store.seek(0) }.keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            }
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
                  let window = e.window, window.attachedSheet == nil, !(window.firstResponder is NSText)
            else { return e }
            SceneStore.shared.togglePlay()
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        SceneStore.shared.shutdown()
    }
}
