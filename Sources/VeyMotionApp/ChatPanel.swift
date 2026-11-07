import AppKit
import SwiftUI

struct ChatPanel: View {
    @Environment(ChatStore.self) private var chat
    @State private var showVersions = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ClaudeLogo(size: 16)
                Text("Claude").font(.headline)
                Spacer()
                Button { showVersions.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.borderless)
                    .help("The scene after each prompt to Claude")
                    .popover(isPresented: $showVersions, arrowEdge: .bottom) { VersionsPopover() }
                Button { chat.newChat() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New conversation")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chat.items.isEmpty { EmptyChatHint() }
                        if let problem = chat.setupProblem { NoticeView(text: problem, isError: true) }
                        ForEach(chat.items) { item in ChatItemView(item: item) }
                        if let activity = chat.activity {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(activity).font(.caption).foregroundStyle(.secondary)
                                // Elapsed time for the current phase, so long steps never look frozen.
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    let s = Int(ctx.date.timeIntervalSince(chat.activityStart))
                                    if s >= 3 {
                                        Text(s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: chat.scrollToken) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            Divider()
            ChatComposer()
        }
    }
}

private struct EmptyChatHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Describe the animation you want.").font(.callout)
            Group {
                Text("• “Make a 6s explainer: title, 3 stats popping in, end card”")
                Text("• “Slide this in from the left at the playhead”")
                Text("• “Make everything 20% faster”")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("Claude uses your Claude Code login and can only run `vmotion` commands.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}

private struct ChatItemView: View {
    @Environment(SceneStore.self) private var store
    let item: ChatStore.Item

    var body: some View {
        switch item.kind {
        case let .user(text, images):
            VStack(alignment: .trailing, spacing: 4) {
                if !images.isEmpty {
                    HStack(spacing: 4) {
                        Spacer(minLength: 30)
                        ForEach(images.indices, id: \.self) { i in
                            Image(nsImage: images[i].image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: images.count == 1 ? 200 : 90, maxHeight: images.count == 1 ? 160 : 90)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .bottomLeading) {
                                    if let t = images[i].time { FrameTimeBadge(time: t).padding(4) }
                                }
                        }
                    }
                }
                HStack {
                    Spacer(minLength: 30)
                    Text(text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        case let .assistant(text, _):
            Text(markdown(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .tool(call):
            ToolCallView(call: call)
        case let .image(image, time):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                .overlay(alignment: .bottomTrailing) {
                    if let time {
                        Text(String(format: "%.2fs", time))
                            .font(.caption2.monospaced())
                            .padding(3)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                    }
                }
                .onTapGesture { if let time { store.seek(time) } }
                .help(time == nil ? "" : "Jump to this frame")
        case let .notice(text, isError):
            NoticeView(text: text, isError: isError)
        case let .summary(text):
            Text(text).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

private struct ToolCallView: View {
    let call: ChatStore.ToolCall
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Group {
                        if !call.isDone {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: call.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(call.isError ? Color.red : Color.green)
                        }
                    }
                    .frame(width: 14)
                    Text(call.title).font(.caption.weight(.medium))
                    Text(call.detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if !call.detail.isEmpty {
                        Text(call.detail).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if !call.output.isEmpty {
                        Divider()
                        Text(call.output.prefix(4000))
                            .font(.caption.monospaced())
                            .foregroundStyle(call.isError ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct NoticeView: View {
    let text: String
    let isError: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? Color.orange : Color.secondary)
            Text(text).font(.caption).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.orange : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}
