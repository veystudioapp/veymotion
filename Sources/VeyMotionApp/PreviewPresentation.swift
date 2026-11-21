import AppKit
import SwiftUI

/// Full screen preview: a borderless window of its own over the whole screen (Dock and menu bar hidden), showing only
/// the picture on black with floating controls that hide while playing. Not macOS full screen: that keeps a hidden
/// title bar/toolbar over the content, which flickered. UI only, never part of the scene. Esc, ⇧⌘F or the controls'
/// button leave it.
@Observable
final class PreviewPresentation {
    static let shared = PreviewPresentation()

    private(set) var isActive = false
    /// The floating controls (and the pointer) hide after a moment of stillness while playing.
    private(set) var controlsShown = true
    /// The pointer is over the controls: they stay.
    @ObservationIgnored var overControls = false

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private weak var editorWindow: NSWindow?
    @ObservationIgnored private var savedOptions: NSApplication.PresentationOptions?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// Borderless windows cannot take the keyboard unless they say so (Space, Esc, the menus' shortcuts).
    private final class PresentationWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    func toggle() { isActive ? exit() : enter() }

    func enter() {
        guard !isActive, let editor = NSApp.keyWindow ?? NSApp.mainWindow,
              let screen = editor.screen ?? NSScreen.main else { return }
        AnnotationStore.shared.close()
        CanvasViewport.shared.reset()
        editorWindow = editor
        isActive = true

        let w = PresentationWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.collectionBehavior = [.fullScreenAuxiliary]
        // The notch's strip stays black: the picture goes under the menu bar's height only where there is no notch.
        w.contentView = NSHostingView(rootView: PresentationView(topInset: screen.safeAreaInsets.top)
            .environment(SceneStore.shared))
        w.setFrame(screen.frame, display: true)
        // An editor already in macOS full screen has the Dock and menu bar out of the way.
        if !editor.styleMask.contains(.fullScreen) {
            savedOptions = NSApp.presentationOptions
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; w.animator().alphaValue = 1 }
        window = w

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isActive, e.keyCode == 53, // Esc
                  e.window === self.window else { return e }
            self.exit()
            return nil
        }
        poke()
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        hideTask?.cancel()
        controlsShown = true
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if let saved = savedOptions { NSApp.presentationOptions = saved }
        savedOptions = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        editorWindow?.makeKeyAndOrderFront(nil)
        editorWindow = nil
    }

    /// The pointer moved or playback started/stopped: show the controls, and hide them again in a moment if playing.
    func poke() {
        if !controlsShown { controlsShown = true }
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, self.isActive, SceneStore.shared.isPlaying, !self.overControls
            else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.controlsShown = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// The full screen preview window's content: the canvas edge to edge, the controls over its bottom.
private struct PresentationView: View {
    let topInset: CGFloat

    var body: some View {
        CanvasView(presenting: true)
            .overlay(alignment: .bottom) { PresentationControls() }
            .onContinuousHover { _ in PreviewPresentation.shared.poke() }
            .padding(.top, topInset)
            .background(Color.black)
            .ignoresSafeArea()
    }
}

/// Over the bottom of the full screen preview: scrubber, timecode, play/pause and the way out.
struct PresentationControls: View {
    @Environment(SceneStore.self) private var store
    private let presentation = PreviewPresentation.shared

    var body: some View {
        let s = store.scene
        VStack(spacing: 6) {
            MiniScrubber()
            ZStack {
                HStack {
                    Text("\(timecode(store.time, fps: s.fps)) / \(timecode(s.duration, fps: s.fps))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { presentation.exit() } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .help("Exit full screen preview (Esc)")
                }
                HStack(spacing: 12) {
                    Button { store.seek(0) } label: {
                        Image(systemName: "backward.end.fill").frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .help("Go to start (⇧⌘←)")
                    Button { store.togglePlay() } label: {
                        Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color.primary.opacity(0.12)))
                            .contentShape(Circle())
                    }
                    .help("Play / pause (Space)")
                    Color.clear.frame(width: 28, height: 28)
                }
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
        .onHover { presentation.overControls = $0; presentation.poke() }
        .opacity(presentation.controlsShown ? 1 : 0)
        .allowsHitTesting(presentation.controlsShown)
        .onChange(of: store.isPlaying) { presentation.poke() }
    }

    /// mm:ss:ff
    private func timecode(_ t: Double, fps: Int) -> String {
        let frames = Int((t * Double(fps)).rounded())
        let f = max(fps, 1)
        return String(format: "%02d:%02d:%02d", frames / f / 60, frames / f % 60, frames % f)
    }
}
