import Foundation
import VeyMotionCore
import VeyMotionMCP

/// Title, description, tags and caption for a post.
struct PublishCopy {
    var title = ""
    var description = ""
    var tags: [String] = []
    /// TikTok / X post text.
    var caption = ""
}

/// Drafts publishing copy with the user's Claude Code (`claude -p`, no tools), from what is in the scene:
/// on-screen text, voice-over transcripts and media file names.
enum PublishCopywriter {
    /// Blocking; call it off the main thread.
    static func write(scene: MotionScene, name: String, platform: SocialPlatform, draft: PublishCopy,
                      notes: String) throws -> PublishCopy {
        guard let claude = ChatStore.shared.claudePath ?? ClaudeCodeAgent.locateClaude() else {
            throw PublishError("Claude Code is not installed (the `claude` command was not found). Install it from claude.com/claude-code.")
        }
        let prompt = prompt(scene: scene, name: name, platform: platform, draft: draft, notes: notes)
        let out = try ClaudeCodeAgent.structured(prompt: prompt, schema: schema, claudePath: claude,
                                                 model: ChatStore.shared.model)
        var copy = PublishCopy()
        copy.title = String((out["title"] as? String ?? "").prefix(platform == .youtube ? 100 : 255))
        copy.description = out["description"] as? String ?? ""
        copy.tags = (out["tags"] as? [String] ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .filter { !$0.isEmpty }
        copy.caption = out["caption"] as? String ?? ""
        return copy
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string", "description": "Video title (YouTube, Facebook). Empty for TikTok and X."],
            "description": ["type": "string", "description": "Video description (YouTube, Facebook). Empty for TikTok and X."],
            "tags": ["type": "array", "items": ["type": "string"], "description": "YouTube keyword tags, without #. Empty for other platforms."],
            "caption": ["type": "string", "description": "Post text with hashtags (TikTok, X). Empty for YouTube and Facebook."],
        ],
        "required": ["title", "description", "tags", "caption"],
    ]

    private static func prompt(scene: MotionScene, name: String, platform: SocialPlatform, draft: PublishCopy,
                               notes: String) -> String {
        let vertical = scene.height > scene.width
        var lines: [String] = []
        lines.append("You write the text that goes with a video when it is published on \(platform.name). Answer with the JSON fields only.")
        lines.append("")
        lines.append("VIDEO")
        lines.append("- Project name: \(name)")
        lines.append("- \(scene.width)×\(scene.height) (\(vertical ? "vertical" : scene.width == scene.height ? "square" : "horizontal")), "
            + "\(PlatformPreset.formatDuration(scene.duration)), \(scene.fps) fps")

        let layers = scene.layers.sorted { $0.start < $1.start }
        var seen = Set<String>(), texts: [String] = [], budget = 5000
        for l in layers where l.type == .text {
            let t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted, budget > 0 else { continue }
            let entry = "  [\(String(format: "%.1f", l.start))s] \(t.replacingOccurrences(of: "\n", with: " / "))"
            texts.append(String(entry.prefix(budget)))
            budget -= entry.count
        }
        if !texts.isEmpty {
            lines.append("- On-screen text, in order of appearance:")
            lines += texts
        }
        let voice = layers.compactMap { $0.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !voice.isEmpty {
            lines.append("- Voice-over:")
            lines += voice.map { "  \(String($0.prefix(4000)))" }
        }
        let media = layers.compactMap { l -> String? in
            guard let path = l.path, [.image, .video, .audio].contains(l.type) else { return nil }
            let role = l.type == .audio ? "\(l.role.rawValue) audio" : l.type.rawValue
            return "  \(role): \((path as NSString).lastPathComponent)"
        }
        if !media.isEmpty {
            lines.append("- Media files (names may hint at the song or subject):")
            lines += Array(Set(media)).sorted().prefix(30)
        }

        lines.append("")
        lines.append("RULES FOR \(platform.name.uppercased())")
        switch platform {
        case .youtube:
            lines.append("- title: at most 100 characters (aim for 40–70), specific and inviting, no all caps, no clickbait.")
            lines.append("- description: 2–4 short paragraphs saying what the video is, then 3–5 hashtags on the last line.")
            lines.append("- tags: 5–15 search keywords, under 450 characters in total.")
            if vertical && scene.duration <= 180 { lines.append("- This will be a YouTube Short: include #Shorts in the description's hashtags.") }
            lines.append("- caption: empty.")
        case .tiktok:
            lines.append("- caption: a short hook (1–2 sentences) then 3–6 relevant hashtags, under 300 characters.")
            lines.append("- title, description: empty. tags: empty.")
        case .facebook:
            lines.append("- title: at most 100 characters.")
            lines.append("- description: 1–3 short paragraphs, then 2–4 hashtags.")
            lines.append("- tags, caption: empty.")
        case .x:
            lines.append("- caption: at most 240 characters including 1–2 hashtags; punchy, no thread.")
            lines.append("- title, description: empty. tags: empty.")
        }

        lines.append("")
        lines.append("GENERAL")
        lines.append("- Write in the language of the video's text and voice-over (e.g. Vietnamese with full diacritics). "
            + "If the video has no words, use the language of the project name or the draft.")
        lines.append("- Only state what the content supports; do not invent names, dates, prices or claims.")
        lines.append("- No emoji spam: at most 2 emoji.")
        lines.append("- Never mention technical details (resolution, orientation, fps, file names, the editor used); "
            + "the details above are only context. Media file names may tell you the song or subject.")

        let draftLines = [("title", draft.title), ("description", draft.description),
                          ("tags", draft.tags.joined(separator: ", ")), ("caption", draft.caption)]
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.1 != name }
        if !draftLines.isEmpty {
            lines.append("")
            lines.append("THE USER'S DRAFT (keep its intent and any facts it states; improve the wording):")
            lines += draftLines.map { "- \($0.0): \($0.1)" }
        }
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty {
            lines.append("")
            lines.append("THE USER'S INSTRUCTIONS (follow them): \(n)")
        }
        return lines.joined(separator: "\n")
    }
}
