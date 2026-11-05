import AVKit
import SwiftUI
import VeyMotionCore

/// What the post will look like: the rendered video (playable) next to a mock-up of the platform's post
/// with the thumbnail, title / caption and account. A mock-up, not the platform's exact layout.
struct PostPreview: View {
    struct Post {
        var platform: SocialPlatform
        var account: String
        /// "Private", "Page name", "Only me"…
        var audience: String
        var title: String
        var description: String
        var tags: [String]
        var caption: String
        var tiktokDraft: Bool
    }

    var post: Post
    var video: URL?
    var preparing: Double?
    var error: String?
    var thumbnail: CGImage?
    var aspect: Double
    var duration: Double

    @State private var player: AVPlayer?

    private var vertical: Bool { aspect < 0.9 }

    var body: some View {
        Group {
            if vertical {
                HStack(alignment: .top, spacing: 16) {
                    videoBox.frame(width: 190, height: 190 / aspect)
                    card.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    videoBox.frame(height: min(280, 528 / aspect)).frame(maxWidth: .infinity)
                    card
                }
            }
        }
        .onAppear { loadPlayer() }
        .onChange(of: video) { _, _ in loadPlayer() }
        .onDisappear { player?.pause() }
    }

    private func loadPlayer() {
        player?.pause()
        player = video.map { AVPlayer(url: $0) }
    }

    // MARK: Video

    @ViewBuilder
    private var videoBox: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.black)
            if let player {
                PlayerView(player: player).clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(10)
            } else {
                VStack(spacing: 8) {
                    ProgressView(value: preparing ?? 0).frame(width: 140).tint(.white)
                    Text("Rendering the video… \(Int((preparing ?? 0) * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    // MARK: Mock-ups

    @ViewBuilder
    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label { Text("\(post.platform.name) preview") } icon: { SocialLogoView(platform: post.platform, size: 13) }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            switch post.platform {
            case .youtube: youtube
            case .tiktok: tiktok
            case .facebook: facebook
            case .x: x
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var youtube: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumb(width: vertical ? 200 : 240, badge: durationText)
            HStack(alignment: .top, spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.title.isEmpty ? "Untitled" : post.title).font(.callout.weight(.semibold)).lineLimit(2)
                    Text("\(post.account) · \(post.audience)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !post.description.isEmpty {
                Text(post.description).font(.caption).lineLimit(4).foregroundStyle(.secondary)
            }
            if !post.tags.isEmpty {
                Text("Tags: " + post.tags.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }

    private var tiktok: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                thumb(width: 120, badge: nil, aspectOverride: 9.0 / 16.0)
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(post.account)").font(.caption2.weight(.bold))
                    if !post.tiktokDraft {
                        Text(post.caption).font(.caption2).lineLimit(3)
                    }
                }
                .foregroundStyle(.white).shadow(radius: 2).padding(6).frame(width: 120, alignment: .leading)
            }
            if post.tiktokDraft {
                Text("Goes to your TikTok inbox: open the TikTok app to add the caption, choose the cover and post.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Who can view: \(post.audience)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var facebook: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                avatar
                VStack(alignment: .leading, spacing: 0) {
                    Text(post.account).font(.callout.weight(.semibold))
                    Text("Just now · 🌐").font(.caption2).foregroundStyle(.secondary)
                }
            }
            let text = post.description.isEmpty ? post.title : post.description
            if !text.isEmpty { Text(text).font(.caption).lineLimit(4) }
            thumb(width: vertical ? 200 : 240, badge: durationText)
            if !post.title.isEmpty, !post.description.isEmpty {
                Text(post.title).font(.caption.weight(.semibold)).lineLimit(2)
            }
        }
    }

    private var x: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                Text(post.account).font(.callout.weight(.semibold))
                if !post.caption.isEmpty { Text(post.caption).font(.caption) }
                thumb(width: vertical ? 160 : 220, badge: durationText)
                Text("X picks the video thumbnail itself.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Pieces

    private var durationText: String {
        let t = Int(duration.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var avatar: some View {
        Circle().fill(Color.accentColor.opacity(0.25)).frame(width: 28, height: 28)
            .overlay(Text(String(post.account.trimmingCharacters(in: CharacterSet(charactersIn: "@")).prefix(1)).uppercased())
                .font(.caption.weight(.bold)))
    }

    private func thumb(width: CGFloat, badge: String?, aspectOverride: Double? = nil) -> some View {
        let a = aspectOverride ?? (vertical ? aspect : 16.0 / 9.0)
        return ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(.black)
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: aspectOverride != nil ? .fill : .fit)
            }
            if let badge {
                Text(badge).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.75)))
                    .padding(4)
            }
        }
        .frame(width: width, height: width / a)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// AVKit's player view. SwiftUI's `VideoPlayer` crashes in SwiftPM builds (its AVKit overlay's view class
/// cannot find its AppKit superclass at runtime), so wrap `AVPlayerView` directly.
private struct PlayerView: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
