import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeyMotionMCP

/// The chat's input box: Return sends, ⇧Return (or ⌥Return) breaks the line, pasted images become
/// attachments, and dropped or pasted files are written in as their paths.
struct ChatComposer: View {
    @Environment(ChatStore.self) private var chat
    @State private var height: CGFloat = 54
    @State private var isTargeted = false

    var body: some View {
        @Bindable var chat = chat
        VStack(alignment: .leading, spacing: 8) {
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chat.attachments) { a in AttachmentThumb(attachment: a) }
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 4)
                }
            }
            ZStack(alignment: .topLeading) {
                if chat.input.isEmpty {
                    Text("Ask Claude to animate something…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
                ComposerTextView(text: $chat.input, height: $height,
                                 onSubmit: { chat.send() },
                                 onImageData: { chat.attachImage(data: $0) },
                                 onFiles: { chat.allowReading($0) })
                    .frame(height: height)
            }
            toolbar
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [5] : []))
                .allowsHitTesting(false)
        }
        .padding(10)
        // Files dropped next to the text (the text view handles drops on itself, at the caret).
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        chat.allowReading([url])
                        let path = ComposerTextView.pathText([url])
                        let sep = chat.input.isEmpty || chat.input.hasSuffix(" ") || chat.input.hasSuffix("\n") ? "" : " "
                        chat.input += sep + path + " "
                    }
                }
            }
            return !providers.isEmpty
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            ModelPickerButton()

            Spacer(minLength: 0)

            Button { pickImages() } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Attach images (or paste one with ⌘V, or drop files for their paths)")

            Button { chat.isBusy ? chat.stop() : chat.send() } label: {
                Image(systemName: chat.isBusy ? "stop.fill" : "arrow.up")
                    .font(.system(size: chat.isBusy ? 10 : 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .foregroundStyle(chat.isBusy || chat.canSend ? Color.primary : Color.secondary.opacity(0.6))
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(chat.canSend && !chat.isBusy ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .disabled(!chat.isBusy && !chat.canSend)
            .help(chat.isBusy ? "Stop" : "Send (Return) · New line (⇧Return)")
        }
        .font(.system(size: 12))
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose images to send to Claude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { chat.attachImage(file: url) }
    }
}

/// Logo + "Opus 5.5 · Medium ⌄"; opens `ModelPicker` in a popover.
private struct ModelPickerButton: View {
    @Environment(ChatStore.self) private var chat
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                ClaudeLogo(size: 14)
                Text(chat.modelEfforts.isEmpty || chat.effort.isEmpty
                     ? chat.modelLabel : "\(chat.modelLabel) · \(ModelPicker.effortName(chat.effort))")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(hover || open ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(chat.isBusy)
        .help("Model and effort")
        .popover(isPresented: $open, arrowEdge: .top) {
            ModelPicker(close: { open = false })
        }
    }
}

/// Popover: the main models (with 1–9 shortcuts), then Effort ›, then More models ›.
private struct ModelPicker: View {
    @Environment(ChatStore.self) private var chat
    var close: () -> Void
    @State private var page = Page.main

    enum Page { case main, effort, more }

    static func effortName(_ e: String) -> String {
        switch e {
        case "": return "Default"
        case "xhigh": return "Extra high"
        default: return e.capitalized
        }
    }

    /// Aliases (`opus`, `sonnet`…) up top; `Default` and pinned versions under More models.
    private var mainModels: [ClaudeCodeAgent.ModelInfo] {
        chat.models.filter { !$0.value.isEmpty && !$0.value.hasPrefix("claude-") }
    }
    private var moreModels: [ClaudeCodeAgent.ModelInfo] {
        chat.models.filter { $0.value.isEmpty || $0.value.hasPrefix("claude-") }
    }

    /// "Default" is checked on the model it resolves to as well, so the main list always shows one tick.
    private func isSelected(_ m: ClaudeCodeAgent.ModelInfo, inMain: Bool) -> Bool {
        if chat.model == m.value { return true }
        guard inMain, chat.model.isEmpty, let r = chat.selectedModel?.resolvedModel else { return false }
        return m.resolvedModel == r
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch page {
            case .main:
                header("Model · this session")
                ForEach(Array(mainModels.enumerated()), id: \.element.value) { i, m in
                    row(m.displayName, help: m.description, checked: isSelected(m, inMain: true),
                        trailing: i < 9 ? "\(i + 1)" : nil) { pick(m) }
                }
                if !chat.modelEfforts.isEmpty || !moreModels.isEmpty { Divider().padding(.vertical, 4) }
                if !chat.modelEfforts.isEmpty {
                    row("Effort", trailing: Self.effortName(chat.effort), chevron: true) { page = .effort }
                }
                if !moreModels.isEmpty {
                    if !chat.modelEfforts.isEmpty { Divider().padding(.vertical, 4) }
                    row("More models", chevron: true) { page = .more }
                }
            case .effort:
                back("Effort")
                ForEach(Array(([""] + chat.modelEfforts).enumerated()), id: \.element) { i, e in
                    row(Self.effortName(e), checked: chat.effort == e, trailing: i < 9 ? "\(i + 1)" : nil) {
                        chat.effort = e
                        close()
                    }
                }
            case .more:
                back("More models")
                ForEach(Array(moreModels.enumerated()), id: \.element.value) { i, m in
                    row(m.displayName, help: m.description, checked: isSelected(m, inMain: false),
                        trailing: i < 9 ? "\(i + 1)" : nil) { pick(m) }
                }
            }
        }
        .padding(8)
        .frame(width: 240)
        .font(.system(size: 13))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            if press.key == .escape, page != .main { page = .main; return .handled }
            guard let n = Int(press.characters), n >= 1 else { return .ignored }
            switch page {
            case .main: if n <= mainModels.count { pick(mainModels[n - 1]); return .handled }
            case .more: if n <= moreModels.count { pick(moreModels[n - 1]); return .handled }
            case .effort:
                let list = [""] + chat.modelEfforts
                if n <= list.count { chat.effort = list[n - 1]; close(); return .handled }
            }
            return .ignored
        }
    }

    private func pick(_ m: ClaudeCodeAgent.ModelInfo) {
        chat.model = m.value
        // Keep the effort only if the new model accepts it.
        if !chat.effort.isEmpty, !m.efforts.contains(chat.effort) { chat.effort = "" }
        close()
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    private func back(_ title: String) -> some View {
        Button { page = .main } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text(title)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ title: String, help: String = "", checked: Bool = false, trailing: String? = nil,
                     chevron: Bool = false, action: @escaping () -> Void) -> some View {
        PickerRow(title: title, checked: checked, trailing: trailing, chevron: chevron, action: action)
            .help(help)
    }
}

private struct PickerRow: View {
    let title: String
    let checked: Bool
    let trailing: String?
    let chevron: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 12)
                if chevron {
                    if let trailing { Text(trailing).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                } else if checked {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                } else if let trailing {
                    Text(trailing).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(hover ? 0.14 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct AttachmentThumb: View {
    @Environment(ChatStore.self) private var chat
    let attachment: ChatStore.Attachment
    @State private var hover = false

    var body: some View {
        Image(nsImage: attachment.image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            .overlay(alignment: .bottomLeading) {
                if let t = attachment.time { FrameTimeBadge(time: t, compact: true).padding(2) }
            }
            .overlay(alignment: .topTrailing) {
                Button { chat.removeAttachment(attachment.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .opacity(hover ? 1 : 0.7)
                .offset(x: 4, y: -4)
                .help("Remove")
            }
            .onHover { hover = $0 }
    }
}

/// The scene time a canvas frame was taken at, over its thumbnail.
struct FrameTimeBadge: View {
    let time: Double
    var compact = false

    var body: some View {
        Text(String(format: "%.2fs", time))
            .font(.system(size: compact ? 9 : 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 3 : 5)
            .padding(.vertical, compact ? 1 : 2)
            .background(Capsule().fill(.black.opacity(0.65)))
            .help(String(format: "Canvas frame at %.2fs", time))
    }
}

/// Multi-line NSTextView with chat-style keys, image paste and file-path drops.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var onSubmit: () -> Void
    var onImageData: (Data) -> Void
    var onFiles: ([URL]) -> Void
    var minLines = 3
    var maxLines = 10

    /// Paths as written into the message: space-separated, quoted when they contain spaces.
    static func pathText(_ urls: [URL]) -> String {
        urls.map { url -> String in
            let p = url.path
            return p.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" })
                ? "\"" + p.replacingOccurrences(of: "\"", with: "\\\"") + "\"" : p
        }.joined(separator: " ")
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ComposerNSTextView()
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.string = text

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tv
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            context.coordinator.recalcHeight(tv)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text, tv.markedRange().length == 0 {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.recalcHeight(tv)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recalcHeight(tv)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // While an input method is composing (Vietnamese, Japanese…), Return belongs to it.
            if textView.hasMarkedText() { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }

        func recalcHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let lineHeight = lm.defaultLineHeight(for: tv.font ?? .systemFont(ofSize: NSFont.systemFontSize))
            let used = max(lm.usedRect(for: tc).height, lineHeight)
            let h = min(max(used, lineHeight * CGFloat(parent.minLines)), lineHeight * CGFloat(parent.maxLines)).rounded(.up)
            if abs(parent.height - h) > 0.5 {
                DispatchQueue.main.async { self.parent.height = h }
            }
        }

        /// Writes paths at the caret, spaced off the text around them.
        func insertPaths(_ urls: [URL], into tv: NSTextView) {
            guard !urls.isEmpty else { return }
            parent.onFiles(urls)
            let s = tv.string as NSString
            let r = tv.selectedRange()
            let before = r.location > 0 ? s.substring(with: NSRange(location: r.location - 1, length: 1)) : ""
            let after = r.location + r.length < s.length ? s.substring(with: NSRange(location: r.location + r.length, length: 1)) : ""
            let lead = before.isEmpty || before.first!.isWhitespace ? "" : " "
            let tail = after.first?.isWhitespace == true ? "" : " "
            tv.insertText(lead + ComposerTextView.pathText(urls) + tail, replacementRange: r)
        }
    }
}

final class ComposerNSTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]

    private func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func imageData(_ pb: NSPasteboard) -> Data? {
        for t in Self.imageTypes { if let d = pb.data(forType: t) { return d } }
        return nil
    }

    // MARK: Paste

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let urls = fileURLs(pb)
        if !urls.isEmpty, let coordinator {
            coordinator.insertPaths(urls, into: self)
            return
        }
        // A screenshot copied to the clipboard (⌃⇧⌘4) or an image copied from a browser/app.
        if pb.string(forType: .string) == nil, let data = imageData(pb) {
            coordinator?.parent.onImageData(data)
            return
        }
        pasteAsPlainText(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) {
            let pb = NSPasteboard.general
            return pb.string(forType: .string) != nil || !fileURLs(pb).isEmpty || imageData(pb) != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Drop

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + Self.imageTypes + super.readablePasteboardTypes
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let urls = fileURLs(pb)
        if !urls.isEmpty, let coordinator {
            // Put the caret where the files were dropped.
            let point = convert(sender.draggingLocation, from: nil)
            let index = characterIndexForInsertion(at: point)
            setSelectedRange(NSRange(location: min(index, (string as NSString).length), length: 0))
            coordinator.insertPaths(urls, into: self)
            window?.makeFirstResponder(self)
            return true
        }
        if pb.string(forType: .string) == nil, let data = imageData(pb) {
            coordinator?.parent.onImageData(data)
            return true
        }
        return super.performDragOperation(sender)
    }
}
