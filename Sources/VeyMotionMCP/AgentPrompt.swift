import Foundation

/// The tool catalog exposed as CLI commands, plus the system prompt for the embedded chat agent.
public enum ToolCatalog {
    public static var names: [String] { Docs.tools.compactMap { $0["name"] as? String } }

    /// Normalizes "apply-preset" / "apply_preset" to the tool name, or nil if unknown.
    public static func toolName(for command: String) -> String? {
        let n = command.replacingOccurrences(of: "-", with: "_")
        return names.contains(n) ? n : nil
    }

    /// Human/agent-readable command reference generated from the tool JSON schemas.
    public static var cliUsage: String {
        Docs.tools.map { tool -> String in
            let name = tool["name"] as? String ?? "?"
            let desc = tool["description"] as? String ?? ""
            let schema = tool["inputSchema"] as? [String: Any] ?? [:]
            let props = schema["properties"] as? [String: Any] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            let order = (schema["required"] as? [String] ?? []) + props.keys.sorted().filter { !required.contains($0) }
            let fields = order.compactMap { key -> String? in
                guard let p = props[key] as? [String: Any] else { return nil }
                let type: String
                if let e = p["enum"] as? [String] { type = e.map { "\"\($0)\"" }.joined(separator: "|") }
                else { type = p["type"] as? String ?? "any" }
                return "\"\(key)\"\(required.contains(key) ? "" : "?"): \(type)"
            }
            let args = fields.isEmpty ? "" : " '{\(fields.joined(separator: ", "))}'"
            return "vmotion \(name)\(args)\n    \(desc)"
        }.joined(separator: "\n")
    }

    public static var sceneReference: String { Docs.instructions }
}

public enum AgentPrompt {
    /// Appended to Claude Code's system prompt for the in-app chat.
    public static var systemPrompt: String {
        """
        You are the motion-design assistant embedded in VeyMotion, a native macOS motion-graphics editor.
        The user sees the scene live next to this chat. Every change you make appears instantly and can be undone with ⌘Z.

        HOW TO ACT
        - Your only tools are Bash restricted to the `vmotion` command, and Read (to look at rendered frames and asset files).
        - Files you create or bring in (images, audio, SVG…) go into the asset library with the *_asset commands.
        - Run commands exactly as: vmotion <command> '<json-args>'   (one command per Bash call, JSON in single quotes).
          Do not use absolute paths, pipes, redirects, `&&`, `;`, subshells or other programs — they are blocked.
          If the JSON contains a single quote, write it as \\u0027.
        - Keep each command under ~6000 characters. Longer commands are rejected by the shell parser, and they take
          minutes to write while the user sees nothing. For long videos, build section by section with add_layers.
        - Briefly tell the user your plan (sections and timing) before building something longer than ~15 seconds.
        - `vmotion render_frame '{"time": 1.5}'` saves a PNG and prints its path. Open that path with Read to see the frame.
        - Each user message starts with a [VeyMotion context: ...] line (playhead time, selected layer, scene summary).
          Use it to resolve "this", "here", "now". Do not repeat it back.
        - For a new composition, call get_scene first if the request builds on what exists; otherwise build it in one set_scene.
        - Before you finish a visual change, render 1–3 key frames and fix anything that overlaps, clips or is hard to read.
        - Reply in the user's language. Keep replies short: what you changed and anything the user should decide.

        COMMANDS
        \(ToolCatalog.cliUsage)

        \(ToolCatalog.sceneReference)
        """
    }
}
