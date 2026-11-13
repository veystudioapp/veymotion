import Foundation
import VeyMotionCore

// A second pair of eyes for what the lint cannot measure. The agent that built a scene judges its own frames
// kindly: it knows what each shape is meant to be. The critic is a separate `claude -p` turn that gets only the
// pictures (a contact sheet for pacing and variety, a few frames at full size for detail), the user's request and
// the on-screen text, and answers with scores and a short list of concrete fixes. The app sends the major findings
// back to the building agent once per user message (`ChatStore`); `vmotion review` prints the same thing, so the
// scores can be compared from one version of the prompt to the next.

public struct DesignCritique: Sendable {
    public struct Finding: Sendable {
        /// Scene time of the frame where it shows (nil = the whole piece).
        public var time: Double?
        /// Which element or area.
        public var place: String
        public var problem: String
        public var fix: String
        public var major: Bool
        /// A change of concept, palette, content or structure across the piece: for the author to decide, never
        /// sent to the agent on its own. Otherwise a repair at one frame that keeps the design as it is.
        public var direction: Bool

        public var line: String {
            let at = time.map { String(format: "%.1fs", $0) }
            let head = [at, place.isEmpty ? nil : place].compactMap { $0 }.joined(separator: ", ")
            return "[\(direction ? "direction" : major ? "major" : "minor")] \(head.isEmpty ? "" : head + ": ")\(problem) → \(fix)"
        }
    }

    /// 1 (draft) … 5 (studio work) for each of `DesignCritic.dimensions`, in that order.
    public var scores: [(name: String, value: Int)]
    public var summary: String
    public var findings: [Finding]

    public var overall: Double {
        scores.isEmpty ? 0 : Double(scores.reduce(0) { $0 + $1.value }) / Double(scores.count)
    }

    public var scoreLine: String {
        scores.map { "\($0.name) \($0.value)" }.joined(separator: ", ") + String(format: " (%.1f / 5)", overall)
    }

    /// Repairs worth another pass by the agent: major, and local to a frame.
    public var fixes: [Finding] { findings.filter { $0.major && !$0.direction } }
    /// Ideas about the piece as a whole, for the author.
    public var directions: [Finding] { findings.filter(\.direction) }

    /// Scores, the verdict and the findings as text (`fixesOnly`: what the agent is asked to repair).
    public func report(fixesOnly: Bool = false) -> String {
        let list = fixesOnly ? fixes : findings
        return (["Scores: " + scoreLine, summary] + list.map { "- " + $0.line }).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public var json: [String: Any] {
        [
            "scores": Dictionary(uniqueKeysWithValues: scores.map { ($0.name, $0.value) }),
            "overall": (overall * 100).rounded() / 100,
            "summary": summary,
            "findings": findings.map { f -> [String: Any] in
                var o: [String: Any] = ["where": f.place, "problem": f.problem, "fix": f.fix, "severity": f.major ? "major" : "minor",
                                        "kind": f.direction ? "direction" : "fix"]
                if let t = f.time { o["time"] = t }
                return o
            },
        ]
    }
}

public enum DesignCritic {
    public struct Failure: LocalizedError {
        public var errorDescription: String?
    }

    /// What is scored, and what each score looks at.
    public static let dimensions: [(name: String, question: String)] = [
        ("composition", "Is there one clear focal point per frame and a deliberate layout (grid, alignment, margins, balance, use of the whole frame)? Or is everything centered at one size?"),
        ("typography", "Hierarchy, a font that fits the tone, spacing, line breaks, readable at a glance."),
        ("color", "A limited palette used on purpose, enough contrast, text easy to read over what is behind it."),
        ("craft", "Do objects and illustrations look like what they are, drawn well (not placeholder boxes and triangles)? Do parts join? Are details finished: shadows that touch their object, no stray shapes, nothing clipped or overlapping by accident?"),
        ("variety", "Across the contact sheet, do sections differ in layout, scale and treatment while staying one piece? Or is every frame the same card with other words on it?"),
        ("originality", "Is there an idea that belongs to this subject (a visual metaphor, a treatment of its own), or could the same pictures carry any other text? Does it avoid the look every generated video has (dark gradient, glowing blobs, centered title, rounded cards)?"),
    ]

    /// The frames the critic gets: times of the contact sheet, and of the full-size frames.
    public static func frameTimes(_ scene: MotionScene) -> (sheet: [Double], close: [Double]) {
        let n = max(6, min(16, Int((scene.duration / 0.75).rounded(.up))))
        let sheet = (0..<n).map { ((Double($0) + 0.5) * scene.duration / Double(n) * 100).rounded() / 100 }
        return (sheet, scene.reviewTimes(limit: 5))
    }

    /// Renders the frames, asks Claude Code for a review and returns it. Blocking (a minute or so); call it off
    /// the main thread. `brief` is what the user asked for; `known` are lint findings the builder already has.
    /// The frames live in a folder of their own under `workingDirectory` for the length of the call.
    public static func review(scene: MotionScene, brief: String?, known: [DesignIssue] = [], claudePath: String,
                              model: String? = nil, workingDirectory: URL = ClaudeCodeAgent.Config.defaultWorkingDirectory,
                              isCancelled: @escaping () -> Bool = { false }) throws -> DesignCritique {
        guard !scene.layers.isEmpty, scene.duration > 0 else { throw Failure(errorDescription: "The scene is empty.") }
        let dir = workingDirectory
            .appendingPathComponent("critic", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let renderer = FrameRenderer()
        let times = frameTimes(scene)
        let long = Double(max(scene.width, scene.height))
        let vertical = scene.height > scene.width
        guard let sheet = renderer.contactSheetPNG(scene, times: times.sheet, columns: vertical ? 6 : 4, scale: min(0.5, 480 / long)) else {
            throw Failure(errorDescription: "Could not render the frames.")
        }
        try sheet.write(to: dir.appendingPathComponent("sheet.png"))
        var close: [(file: String, time: Double)] = []
        for (i, t) in times.close.enumerated() {
            if isCancelled() { throw Failure(errorDescription: "Cancelled") }
            guard let png = renderer.pngData(scene, at: t, scale: min(1, 1280 / long)) else { continue }
            let name = "frame-\(i + 1).png"
            try png.write(to: dir.appendingPathComponent(name))
            close.append((name, t))
        }

        let text = prompt(scene: scene, brief: brief, known: known, sheetTimes: times.sheet, close: close)
        let out = try ClaudeCodeAgent.structured(prompt: text, schema: schema, claudePath: claudePath, model: model,
                                                 workingDirectory: dir, readsFiles: true, timeout: 300, isCancelled: isCancelled)
        return parse(out)
    }

    /// A field's text without stray markup (a model sometimes closes a tag inside a string) and outer space.
    static func clean(_ value: Any?) -> String {
        ((value as? String) ?? "")
            .replacingOccurrences(of: "</?[A-Za-z_][A-Za-z0-9_:.-]*>", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ out: [String: Any]) -> DesignCritique {
        let raw = out["scores"] as? [String: Any] ?? [:]
        let scores = dimensions.map { d in (d.name, min(5, max(1, (raw[d.name] as? NSNumber)?.intValue ?? 3))) }
        let findings = (out["findings"] as? [[String: Any]] ?? []).compactMap { f -> DesignCritique.Finding? in
            let problem = clean(f["problem"])
            guard !problem.isEmpty else { return nil }
            let time = (f["time"] as? NSNumber)?.doubleValue
            return DesignCritique.Finding(time: time.flatMap { $0 >= 0 ? $0 : nil },
                                          place: clean(f["where"]),
                                          problem: problem,
                                          fix: clean(f["fix"]),
                                          major: (f["severity"] as? String ?? "").lowercased() == "major",
                                          direction: (f["kind"] as? String ?? "").lowercased() == "direction")
        }
        // Repairs first (major, then minor), ideas about the whole piece last.
        func rank(_ f: DesignCritique.Finding) -> Int { f.direction ? 2 : f.major ? 0 : 1 }
        let ordered = findings.prefix(6).enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
        return DesignCritique(scores: scores, summary: clean(out["summary"]), findings: ordered.map(\.element))
    }

    static var schema: [String: Any] {
        let score: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 5]
        return [
            "type": "object",
            "properties": [
                "scores": [
                    "type": "object",
                    "properties": Dictionary(uniqueKeysWithValues: dimensions.map { ($0.name, score) }),
                    "required": dimensions.map(\.name),
                ],
                "summary": ["type": "string", "description": "One or two sentences: the verdict a senior motion designer would give."],
                "findings": [
                    "type": "array",
                    "maxItems": 6,
                    "items": [
                        "type": "object",
                        "properties": [
                            "time": ["type": "number", "description": "Seconds: the frame where it shows. -1 when it is about the whole piece."],
                            "where": ["type": "string", "description": "The element or area (quote on-screen text when it helps)."],
                            "problem": ["type": "string", "description": "What a viewer sees, concretely."],
                            "fix": ["type": "string", "description": "One concrete change: what, where, how big, which color."],
                            "severity": ["type": "string", "enum": ["major", "minor"]],
                            "kind": ["type": "string", "enum": ["fix", "direction"],
                                     "description": "fix = a repair at that frame that keeps the design; direction = a change of concept, palette, content or structure across the piece."],
                        ],
                        "required": ["time", "where", "problem", "fix", "severity", "kind"],
                    ],
                ],
            ],
            "required": ["scores", "summary", "findings"],
        ]
    }

    static func prompt(scene: MotionScene, brief: String?, known: [DesignIssue], sheetTimes: [Double],
                       close: [(file: String, time: Double)]) -> String {
        func clock(_ t: Double) -> String { String(format: "%g", (t * 100).rounded() / 100) }
        var lines: [String] = []
        lines.append("""
            You are a senior motion designer reviewing a motion-graphics video someone else made. You see only the \
            result. Judge it the way a viewer who has seen thousands of these would: does it pass as the work of a good \
            designer, or does it look generated: generic, templated, placeholder art, the same look as every other \
            AI-made video? Be exact and honest. Praise is not needed; inventing problems is worse than finding none.
            """)
        lines.append("")
        lines.append("FIRST read every one of these image files with the Read tool (they are in the current directory):")
        lines.append("- sheet.png: \(sheetTimes.count) small frames in order, left to right then top to bottom, at "
            + sheetTimes.map(clock).joined(separator: ", ") + " s. Use it for pacing, variety between sections and consistency.")
        for c in close { lines.append("- \(c.file): the full frame at \(clock(c.time)) s. Use these for detail.") }

        lines.append("")
        lines.append("THE VIDEO")
        let shape = scene.height > scene.width ? "vertical" : scene.width == scene.height ? "square" : "horizontal"
        lines.append("- \(scene.width)×\(scene.height) (\(shape)), \(clock(scene.duration)) s")
        let b = (brief ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty { lines.append("- What was asked for: \(String(b.prefix(1500)))") }
        var seen = Set<String>(), budget = 2500, texts: [String] = []
        for l in scene.allLayers.filter({ $0.type == .text }).sorted(by: { $0.start < $1.start }) {
            let t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t).inserted, budget > 0 else { continue }
            let entry = "  \(t.replacingOccurrences(of: "\n", with: " / "))"
            texts.append(String(entry.prefix(budget)))
            budget -= entry.count
        }
        if !texts.isEmpty {
            lines.append("- Its on-screen text (so you can tell a word that is hard to read from one you cannot know):")
            lines += texts
        }
        if !known.isEmpty {
            lines.append("- An automatic check already reported these; do not repeat them: " + known.map(\.code).joined(separator: ", "))
        }

        lines.append("")
        lines.append("SCORES, each 1–5: 5 = a studio would ship it, 4 = good, 3 = acceptable but forgettable, 2 = amateur, 1 = a draft. "
            + "Most generated videos are a 2 or a 3; give a 4 or 5 only when you would not change anything that matters.")
        for d in dimensions { lines.append("- \(d.name): \(d.question)") }

        lines.append("")
        lines.append("""
            FINDINGS: at most 6, the most damaging first; fewer or none when the piece is good.
            - time: the time of the frame where it shows (one of the times above), or -1 for the whole piece.
            - where: the element or the area of the frame.
            - problem: what a viewer sees ("the plane is a gray kite shape with no wings", "the subtitle touches the \
            card's edge", "every section is a centered title on the same blue gradient").
            - fix: one change a motion designer would make, concrete enough to carry out without asking: what, where, \
            how big, which color. Not "improve the contrast".
            - severity: "major" when a viewer would notice and it makes the piece look amateur or generated; else "minor".
            - kind: "fix" for a repair at one frame that keeps the design as it is (move, resize, recolor or redraw one \
            element, separate two that collide, finish a detail). "direction" for anything that changes the concept, the \
            palette, the content or the structure of the whole piece: the author decides those, so give at most two, and \
            put the repairs first.
            Do not judge what stills cannot show (easing, timing of moves, sound), and do not ask for more effects for \
            their own sake: restraint is a quality.
            Answer with the JSON only.
            """)
        return lines.joined(separator: "\n")
    }
}
