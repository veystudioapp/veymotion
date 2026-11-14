import CoreGraphics
import Foundation
import VeyMotionCore

/// Where the MCP server reads and writes the scene. The app routes mutations through its undo stack;
/// the CLI host writes them to a file.
public protocol SceneHost: AnyObject {
    func currentScene() -> MotionScene
    func mutate(_ label: String, _ body: (inout MotionScene) throws -> Void) throws
    /// The asset library tool calls work on, when it is not the active one (`AssetStore.withLibrary`).
    var assetLibrary: URL? { get }
}

public extension SceneHost {
    var assetLibrary: URL? { nil }
}

/// Transport-independent MCP (JSON-RPC 2.0) request handler. Thread-safe as long as the host is.
public final class MCPServer {
    public static let serverName = "veymotion"
    public static let serverVersion = "0.1.0"
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let host: SceneHost
    public var log: (String) -> Void = { _ in }

    public init(host: SceneHost) {
        self.host = host
    }

    /// Handles one JSON-RPC message. Returns nil for notifications.
    public func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            return id == nil ? nil : Self.error(id, code: -32600, "Invalid request")
        }
        guard let id else { return nil } // notification (e.g. notifications/initialized)
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            let result = try dispatch(method, params)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let RPCError.methodNotFound(m) {
            return Self.error(id, code: -32601, "Method not found: \(m)")
        } catch let RPCError.invalidParams(m) {
            return Self.error(id, code: -32602, m)
        } catch {
            return Self.error(id, code: -32603, error.localizedDescription)
        }
    }

    enum RPCError: Error {
        case methodNotFound(String)
        case invalidParams(String)
    }

    static func error(_ id: Any?, code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private func dispatch(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            return [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
                "instructions": Docs.instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Docs.tools]
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError.invalidParams("missing tool name") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            log("tool \(name)")
            do {
                return try AssetStore.withLibrary(host.assetLibrary) { try callTool(name, args) }
            } catch let e as RPCError {
                throw e
            } catch {
                // Tool failures are reported to the model, not as protocol errors.
                return ["content": [["type": "text", "text": "Error: \(error.localizedDescription)"]], "isError": true]
            }
        default:
            throw RPCError.methodNotFound(method)
        }
    }

    // MARK: - Tools

    private func callTool(_ name: String, _ a: [String: Any]) throws -> [String: Any] {
        switch name {
        case "get_scene":
            return text(SceneJSON.string(host.currentScene()))

        case "set_scene":
            guard let obj = a["scene"] as? [String: Any] else { throw ToolError("`scene` must be an object") }
            var scene = try SceneJSON.decode(MotionScene.self, fromObject: obj)
            let problems = scene.refreshMediaInfo()
            // A flat scene gets a look by default, so a one-line prompt still comes out finished.
            let lookArg = (a["look"] as? String ?? "auto").lowercased()
            var lookNote = ""
            if lookArg != "none" && lookArg != "auto" {
                guard let kind = LookKind(rawValue: lookArg) else {
                    throw ToolError("`look` must be auto, none or one of \(LookKind.allCases.map(\.rawValue))")
                }
                try scene.applyLook(kind)
                lookNote = " Applied the \(kind.title) look."
            } else if lookArg == "auto", let kind = try scene.applyAutoLook() {
                lookNote = " The background was flat, so the \(kind.title) look was added (groups look / look-finish; apply_look to change it, remove_look or \"look\":\"none\" to drop it)."
            }
            try host.mutate("Set Scene") { $0 = scene }
            let design = scene.designIssues(renderer: FrameRenderer()).filter { $0.severity >= .warning }
            let designNote = design.isEmpty ? "" : "\n" + MotionScene.designReport(design) + "\nFix these before you finish (check_design re-checks)."
            return text("Scene set: \(scene.width)x\(scene.height) @\(scene.fps)fps, \(scene.duration)s, \(scene.layers.count) layers: \(scene.layers.map(\.id).joined(separator: ", "))." + lookNote + warnings(problems + fontNotes(scene.layers) + modelNotes(scene.layers)) + designNote)

        case "check_design":
            let scene = host.currentScene()
            let issues = scene.designIssues(renderer: FrameRenderer())
            return text(MotionScene.designReport(issues) + (scene.layers.isEmpty ? "" : "\n" + scene.reviewNote))

        case "update_scene":
            guard let changes = a["changes"] as? [String: Any] else { throw ToolError("`changes` must be an object") }
            try host.mutate("Update Scene") { try $0.updateSettings(patch: changes) }
            let s = host.currentScene()
            return text("Scene: \(s.width)x\(s.height) @\(s.fps)fps, \(s.duration)s, background \(s.background.hex)")

        case "add_layer":
            guard let obj = a["layer"] as? [String: Any] else { throw ToolError("`layer` must be an object") }
            let layer = try SceneJSON.decode(MotionLayer.self, fromObject: obj)
            var newId = ""
            var problems: [String] = []
            let into = a["group"] as? String
            try host.mutate("Add Layer") {
                if let into { newId = try $0.addLayer(layer, into: into, at: a["index"] as? Int) }
                else { newId = $0.addLayer(layer, at: a["index"] as? Int) }
                problems = $0.refreshMediaInfo()
            }
            let added = try host.currentScene().layer(newId)
            return text("Added layer '\(newId)'" + warnings(problems + fontNotes([added]) + modelNotes([added])))

        case "add_layers":
            guard let list = a["layers"] as? [Any], !list.isEmpty else { throw ToolError("`layers` must be a non-empty array") }
            let layers = try SceneJSON.decode([MotionLayer].self, fromObject: list)
            var ids: [String] = []
            var problems: [String] = []
            try host.mutate("Add \(layers.count) Layers") { s in
                ids = layers.map { s.addLayer($0) }
                problems = s.refreshMediaInfo()
            }
            let added = host.currentScene().layers.filter { ids.contains($0.id) }
            return text("Added \(ids.count) layers: \(ids.joined(separator: ", ")) (scene now has \(host.currentScene().layers.count))" + warnings(problems + fontNotes(added) + modelNotes(added)))

        case "update_layer":
            let id = try string(a, "id")
            guard let changes = a["changes"] as? [String: Any] else { throw ToolError("`changes` must be an object") }
            let newId = changes["id"] as? String ?? id
            try host.mutate("Update Layer") { s in
                try s.updateLayer(id, patch: changes)
                if changes["path"] != nil || changes["fps"] != nil, let i = s.layers.firstIndex(where: { $0.id == newId }) {
                    s.layers[i].sourceDuration = nil // new file or image-sequence rate: re-read its length
                }
                s.refreshMediaInfo()
            }
            let updated = try host.currentScene().layer(newId)
            let cutout = (updated.removeBackground != nil && (a["changes"] as? [String: Any])?["removeBackground"] != nil)
                ? PictureML.probe(updated).map { ["Background removal did not work here (\($0)); the picture is drawn whole. It needs the app (not a sandboxed CLI)."] } ?? []
                : []
            let clips = changes["model"] != nil || changes["path"] != nil ? modelNotes([updated]) : []
            return text(SceneJSON.string(updated) + warnings(fontNotes([updated]) + cutout + clips))

        case "list_fonts":
            return text(fontList(query: a["query"] as? String ?? "", vietnamese: a["vietnamese"] as? Bool ?? false,
                                 limit: Int(number(a["limit"]) ?? 80)))

        case "remove_layer":
            let id = try string(a, "id")
            try host.mutate("Remove Layer") { try $0.removeLayerAnywhere(id) }
            return text("Removed '\(id)'")

        case "reorder_layer":
            let id = try string(a, "id")
            guard let index = a["index"] as? Int else { throw ToolError("`index` must be an integer") }
            try host.mutate("Reorder Layer") { try $0.moveLayerAnywhere(id, to: index) }
            let s = host.currentScene()
            if let g = s.parentGroup(of: id), let group = s.findLayer(g) {
                return text("Order in '\(g)' (bottom→top): \(group.children.map(\.id).joined(separator: ", "))")
            }
            return text("Order (bottom→top): \(s.layers.map(\.id).joined(separator: ", "))")

        case "duplicate_layer":
            let id = try string(a, "id")
            let count = max(1, min(a["count"] as? Int ?? 1, 200))
            let ids = (a["ids"] as? [Any])?.compactMap { $0 as? String } ?? []
            var made: [String] = []
            try host.mutate("Duplicate Layer") {
                made = try $0.duplicateLayer(id, count: count, dx: number(a["offsetX"]) ?? 0, dy: number(a["offsetY"]) ?? 0,
                                             dt: number(a["timeOffset"]) ?? 0, ids: ids)
            }
            return text("Made \(made.count) cop\(made.count == 1 ? "y" : "ies") of '\(id)': \(made.joined(separator: ", ")) (each one placed right above the previous in the layer order).")

        case "shift_time":
            guard let from = number(a["from"]), let by = number(a["by"]) else { throw ToolError("`from` and `by` are seconds") }
            var touched: [String] = []
            try host.mutate("Shift Time") { touched = try $0.shiftTime(from: from, by: by, extendDuration: a["extendDuration"] as? Bool ?? true) }
            let s = host.currentScene()
            return text(String(format: "Shifted everything from %.2fs by %+.2fs: %d layer(s) (%@). Scene is now %.2fs.", from, by, touched.count,
                               touched.prefix(12).joined(separator: ", ") + (touched.count > 12 ? ", …" : ""), s.duration))

        case "import_vector":
            let source = try string(a, "source")
            let url: URL
            if source.hasPrefix("/") || source.hasPrefix("~") { url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath) }
            else { url = try AssetStore.url(for: source) }
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("No file at \(url.path)") }
            let scene0 = host.currentScene()
            var o = SVGImportOptions(x: number(a["x"]) ?? Double(scene0.width) / 2, y: number(a["y"]) ?? Double(scene0.height) / 2)
            if let id = a["id"] as? String, !id.isEmpty { o.id = id }
            else { o.id = url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-") }
            o.width = number(a["width"]); o.height = number(a["height"])
            o.flatten = a["flatten"] as? Bool ?? false
            var summary: SVGImport.Summary?
            try host.mutate("Import Vector") { summary = try $0.importVector(at: url, options: o) }
            guard let sum = summary else { throw ToolError("import failed") }
            func tree(_ l: MotionLayer, depth: Int) -> [String] {
                let pad = String(repeating: "  ", count: depth)
                let line = pad + l.id + (l.type == .group ? "/" : "") + (l.type == .path ? " (\(l.fill.value(at: 0).hex)\(l.stroke != nil ? ", stroke" : ""))" : "")
                return [line] + (depth < 3 ? l.children.flatMap { tree($0, depth: depth + 1) } : l.children.isEmpty ? [] : [pad + "  …"])
            }
            var lines = tree(sum.group, depth: 0)
            if lines.count > 60 { lines = Array(lines.prefix(60)) + ["  … (\(sum.shapes) shapes in all)"] }
            let skipped = Set(sum.skipped)
            return text("Imported '\(sum.group.id)': \(sum.shapes) path layer\(sum.shapes == 1 ? "" : "s") in \(sum.groups + 1) group\(sum.groups == 0 ? "" : "s"), centered on \(Int(o.x)),\(Int(o.y)). "
                + "Every part is a normal layer: animate, recolor or re-parent it by id (children use scene coordinates). "
                + "Each group sits at the frame center (x \(scene0.width / 2), y \(scene0.height / 2)) with its pivot (anchorX/anchorY) on the drawing: "
                + "to move a group, offset its x/y from those values (e.g. y \(scene0.height / 2 + 80) → \(scene0.height / 2) slides it up 80 px); scale and rotation turn around the drawing.\n"
                + lines.joined(separator: "\n")
                + (skipped.isEmpty ? "" : "\nSkipped elements: \(skipped.sorted().joined(separator: ", ")) (text, images, clip paths and CSS are not imported)."))

        case "set_bones":
            guard let raw = a["bones"] as? [[String: Any]] else { throw ToolError("`bones` must be an array of bone objects") }
            let list = try raw.map { try SceneJSON.decode(Bone.self, fromObject: $0) }
            try host.mutate("Set Bones") { try $0.setBones(list, replace: a["replace"] as? Bool ?? false) }
            let s = host.currentScene()
            let desc = s.bones.map { b in
                let tip = s.boneTip(b.id, at: 0).map { String(format: "%.0f,%.0f", $0.x, $0.y) } ?? "?"
                return "\(b.id)\(b.parent.map { " ← \($0)" } ?? "") length \(Int(b.length)) angle \(Int(b.angle.value(at: 0)))° (tip at \(tip))"
            }
            return text("Rig has \(s.bones.count) bone\(s.bones.count == 1 ? "" : "s"):\n" + desc.joined(separator: "\n")
                + "\nNext: bind_bone hangs layers on them; pose_bones / solve_ik move them.")

        case "bind_bone":
            let id = try string(a, "id")
            let bone = (a["bone"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let t = number(a["time"]) ?? 0
            try host.mutate(bone == nil ? "Detach from Bone" : "Bind to Bone") { try $0.bind(id, toBone: bone, at: t) }
            return text(bone.map { "'\(id)' now follows bone '\($0)' (its x/y/rotation are relative to the bone; it did not move at \(t)s)." }
                ?? "'\(id)' detached from its bone (kept where it was).")

        case "pose_bones":
            guard let raw = a["angles"] as? [String: Any] else { throw ToolError("`angles` must be {boneId: degrees}") }
            var angles: [String: Double] = [:]
            for (k, v) in raw { if let n = (v as? NSNumber)?.doubleValue { angles[k] = n } }
            let t = number(a["time"])
            try host.mutate("Pose Bones") { try $0.poseBones(angles, at: t, hold: number(a["hold"]) ?? 0.4) }
            return text("Posed \(angles.count) bone\(angles.count == 1 ? "" : "s")" + (t.map { String(format: " at %.2fs (keyframes)", $0) } ?? " (constant)") + ".")

        case "solve_ik":
            let bone = try string(a, "bone")
            guard let x = number(a["x"]), let y = number(a["y"]) else { throw ToolError("`x` and `y` are the target in scene px") }
            let t = number(a["time"])
            var solved: [String: Double] = [:]
            try host.mutate("Solve IK") {
                solved = try $0.solveIK(bone, target: CGPoint(x: x, y: y), chain: a["chain"] as? Int ?? 2, at: t, hold: number(a["hold"]) ?? 0.4)
            }
            let s = host.currentScene()
            let tip = s.boneTip(bone, at: t ?? 0).map { String(format: "%.0f,%.0f", $0.x, $0.y) } ?? "?"
            let miss = s.boneTip(bone, at: t ?? 0).map { hypot($0.x - x, $0.y - y) } ?? 0
            return text("IK: " + solved.map { "\($0.key) \(Int($0.value.rounded()))°" }.sorted().joined(separator: ", ")
                + (t.map { String(format: " keyed at %.2fs", $0) } ?? "") + ". Tip of '\(bone)' at \(tip)"
                + (miss > 2 ? String(format: " (target out of reach by %.0f px)", miss) : "") + ".")

        case "draw_frame":
            let id = try string(a, "id")
            guard let raw = a["strokes"] as? [[String: Any]] else { throw ToolError("`strokes` must be an array of {d, stroke?, strokeWidth?, fill?}") }
            let strokes = try raw.map { try SceneJSON.decode(DrawingStroke.self, fromObject: $0) }
            let frame = DrawingFrame(hold: a["hold"] as? Int ?? 1, strokes: strokes)
            try host.mutate("Draw Frame") { try $0.setDrawingFrame(id, index: a["index"] as? Int, frame: frame) }
            let l = try host.currentScene().layer(id)
            return text("'\(id)' has \(l.drawing.frames.count) frame\(l.drawing.frames.count == 1 ? "" : "s") at \(l.drawing.fps) fps (\(String(format: "%.2f", l.drawing.cycle)) s per cycle\(l.drawing.loop ? ", looping" : "")).")

        case "render_frames":
            guard let raw = a["times"] as? [Any] else { throw ToolError("`times` must be an array of seconds") }
            let times = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard !times.isEmpty, times.count <= 24 else { throw ToolError("give 1–24 times") }
            let scene = host.currentScene()
            let columns = max(1, min(a["columns"] as? Int ?? 4, 8))
            let scale = min(max(number(a["scale"]) ?? 0.25, 0.1), 0.5)
            guard let png = FrameRenderer().contactSheetPNG(scene, times: times, columns: columns, scale: scale) else {
                throw ToolError("render failed")
            }
            return ["content": [
                ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                ["type": "text", "text": "Contact sheet of \(times.count) frames, \(columns) per row, left→right then top→bottom: "
                    + times.map { String(format: "%.2fs", $0) }.joined(separator: ", ") + ". Use render_frame for a closer look at one."],
            ]]

        case "list_voices":
            if try voiceEngine(a) == "vieneu" {
                let voices = try VieNeu.voices()
                return text(voices.map(\.label).joined(separator: "\n")
                    + "\n(VieNeu: Vietnamese voices; pass the id before \" — \" as `voice` with engine \"vieneu\")")
            }
            let lang = a["language"] as? String
            let voices = VoiceSynth.voices(language: lang)
            if voices.isEmpty {
                return text("No voices\(lang.map { " for '\($0)'" } ?? ""). Voices can be added in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
            }
            let lines = voices.map { "\($0.id)  —  \($0.name), \($0.language), \($0.quality)" }
            return text(lines.joined(separator: "\n") + "\n(premium/enhanced voices sound much better; install more in System Settings → Accessibility → Spoken Content)")

        case "generate_voice":
            let script = try string(a, "text")
            let start = number(a["start"]) ?? 0
            let rate = min(max(number(a["rate"]) ?? 1, 0.5), 2)
            let folder = AssetStore.routed(nil, default: "voice")
            let result: VoiceResult
            if try voiceEngine(a) == "vieneu" {
                result = try VieNeu.synthesize(script, voice: a["voice"] as? String, speed: rate, folder: folder)
            } else {
                let url = try AssetStore.newFile(prefix: "voice", ext: "caf", folder: folder)
                result = try VoiceSynth.synthesize(script, voiceId: a["voice"] as? String,
                                                   language: a["language"] as? String,
                                                   rate: rate, to: url)
            }
            var layer = MotionLayer(id: a["id"] as? String ?? "vo", name: "Voice", type: .audio)
            layer.role = .voice
            layer.path = result.url.path
            layer.start = max(0, start)
            layer.sourceDuration = result.duration
            layer.transcript = script
            layer.words = result.words
            var newId = ""
            try host.mutate("Generate Voice") { newId = $0.addLayer(layer) }
            let scene = host.currentScene()
            let end = layer.start + result.duration
            var lines = [String(format: "Added voice layer '%@': %.2fs → %.2fs (duration %.2fs).", newId, layer.start, end, result.duration)]
            if end > scene.duration {
                lines.append(String(format: "Note: narration ends after the scene (%.2fs). Consider update_scene duration ≥ %.1f.", scene.duration, end + 0.5))
            }
            lines.append(result.exactTimings ? "Word times (scene seconds):" : "Word times (estimated, scene seconds):")
            let wordList = result.words.map { String(format: "%.2f %@", layer.start + $0.t, $0.text) }
            lines.append(wordList.count > 160 ? wordList.prefix(160).joined(separator: " | ") + " | …" : wordList.joined(separator: " | "))
            return text(lines.joined(separator: "\n"))

        case "add_audio":
            let path = (try string(a, "path") as NSString).expandingTildeInPath
            let duration = try AudioFileInfo.duration(of: path)
            var layer = MotionLayer(id: a["id"] as? String ?? "audio", name: (path as NSString).lastPathComponent, type: .audio)
            layer.path = path
            layer.sourceDuration = duration
            layer.start = max(0, number(a["start"]) ?? 0)
            if let r = a["role"] as? String {
                layer.role = AudioRole(rawValue: r) ?? .sfx
            } else {
                layer.role = (a["duckTo"] != nil || duration > 20) ? .music : .sfx // ducking implies music
            }
            if let v = number(a["volume"]) { layer.volume = .constant(max(0, v)) }
            layer.trimIn = max(0, number(a["trimIn"]) ?? 0)
            layer.end = number(a["end"])
            layer.fadeIn = max(0, number(a["fadeIn"]) ?? 0)
            layer.fadeOut = max(0, number(a["fadeOut"]) ?? 0)
            layer.duckTo = number(a["duckTo"])
            var hitNote: String?
            if let hitAt = number(a["hitAt"]) {
                guard let profile = SoundProfile.cached(path: path) else {
                    throw ToolError("hitAt needs a sound of at most 60 s that can be decoded; use start instead.")
                }
                let hit = number(a["hit"]).map { Int($0) }
                if let hit, hit < 1 || hit > profile.bursts.count {
                    throw ToolError("hit must be 1…\(profile.bursts.count): the file has \(profile.bursts.count) separate sound(s).")
                }
                guard let place = profile.placement(hitAt: hitAt, hit: hit) else { throw ToolError("The file is silent.") }
                layer.start = place.start
                if a["trimIn"] == nil { layer.trimIn = place.trimIn }
                if a["end"] == nil { layer.end = place.end }
                if a["fadeOut"] == nil { layer.fadeOut = place.fadeOut }
                hitNote = String(format: " Its hit lands at %.2fs.", place.hitTime)
                    + (place.hitTime > hitAt + 0.01 ? " (It could not start early enough: the sound is cut at the scene start.)" : "")
                if profile.shape == .sustained {
                    hitNote! += " Warning: this is a sustained sound (steady level, no clear hit), so nothing is heard as an accent at hitAt"
                        + " and it plays on for its whole length. For an accent use a hit/whoosh/riser sound or generate_sfx;"
                        + " keep sustained sounds for beds (set end and fadeIn/fadeOut)."
                }
                if profile.peakDB < -12 {
                    hitNote! += String(format: " The file is quiet (peak %.0f dBFS): raise volume to be heard.", profile.peakDB)
                }
            }
            var newId = ""
            try host.mutate("Add Audio") { newId = $0.addLayer(layer) }
            let scene = host.currentScene()
            let l = try scene.layer(newId)
            var reply = String(format: "Added %@ layer '%@': %.2fs → %.2fs (file %.2fs", l.role.rawValue, newId, l.start,
                               l.effectiveEnd(sceneDuration: scene.duration), duration)
            reply += l.trimIn > 0 ? String(format: ", from %.2fs).", l.trimIn) : ")."
            if let hitNote { reply += hitNote }
            if l.role == .sfx, a["hitAt"] == nil, duration <= 60, let p = SoundProfile.cached(path: path), p.shape != .silent {
                reply += String(format: " Sound: %@. Its peak plays at %.2fs; pass hitAt to line the peak up with the picture.",
                                p.summary, l.start + p.peak - l.trimIn)
            }
            return text(reply)

        case "generate_sfx":
            guard let kind = SynthKind(rawValue: (try string(a, "kind")).lowercased()) else {
                throw ToolError("kind must be one of: \(SynthKind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            var settings = SynthSettings(kind: kind)
            settings.duration = number(a["duration"]).map { min(max($0, 0.03), 30) }
            settings.pitch = min(max(number(a["pitch"]) ?? 1, 0.25), 4)
            settings.variant = Int(number(a["variant"]) ?? 0)
            settings.reverb = number(a["reverb"]).map { min(max($0, 0), 1) }
            settings.direction = a["direction"] as? String
            settings.count = number(a["count"]).map { max(1, min(200, Int($0))) }
            let result = try SoundSynth.generate(settings, folder: a["folder"] as? String)
            let mainHit = result.hits.first ?? 0
            var lines = [String(format: "Generated %@ (%.2fs, hit at %.2fs in the file): %@", kind.rawValue, result.duration, mainHit, result.url.path)]
            if a["add"] as? Bool ?? true {
                var layer = MotionLayer(id: a["id"] as? String ?? "sfx-\(kind.rawValue)", name: kind.title, type: .audio)
                layer.role = .sfx
                layer.path = result.url.path
                layer.sourceDuration = result.duration
                if let v = number(a["volume"]) { layer.volume = .constant(max(0, v)) }
                if let hitAt = number(a["hitAt"]) {
                    layer.start = hitAt - mainHit
                    if layer.start < 0 { layer.trimIn = -layer.start; layer.start = 0 }
                } else {
                    layer.start = max(0, number(a["start"]) ?? 0)
                }
                var newId = ""
                try host.mutate("Generate Sound Effect") { newId = $0.addLayer(layer) }
                let end = layer.start + result.duration - layer.trimIn
                lines.append(String(format: "Added sfx layer '%@': %.2fs → %.2fs, hit at %.2fs.", newId, layer.start, end,
                                    layer.start + mainHit - layer.trimIn))
                if result.hits.count > 1 {
                    let ts = result.hits.prefix(40).map { String(format: "%.2f", layer.start + $0 - layer.trimIn) }
                    lines.append("Hits (scene seconds): " + ts.joined(separator: ", ") + (result.hits.count > 40 ? ", …" : ""))
                }
                if end > host.currentScene().duration + 0.01 {
                    lines.append("Note: it runs past the scene end and is cut there.")
                }
            } else {
                lines.append("Not added: add_audio {\"path\": …, \"role\": \"sfx\", \"hitAt\": <scene time>} places it.")
            }
            return text(lines.joined(separator: "\n"))

        case "get_audio_info":
            let path = try string(a, "path")
            return text(String(format: "%.3f seconds", try AudioFileInfo.duration(of: path)))

        case "analyze_audio":
            return text(try analyzeAudio(a))

        case "add_captions":
            let id = try string(a, "id")
            var style = CaptionStyle()
            if let v = number(a["fontSize"]) { style.fontSize = v }
            if let v = number(a["y"]) { style.y = v }
            if let c = a["color"] as? String, let rgba = RGBA(hex: c) { style.color = rgba }
            if let v = number(a["maxChars"]) { style.maxChars = max(10, Int(v)) }
            if let b = a["background"] as? Bool { style.background = b }
            var lines: [CaptionLine] = []
            try host.mutate("Add Captions") { lines = try $0.addCaptions(for: id, style: style) }
            return text("Added \(lines.count) captions for '\(id)' (layers cap-\(id)-<number>):\n" + captionList(lines))

        case "transcribe":
            let id = try string(a, "id")
            let scene = host.currentScene()
            let l = try scene.layer(id)
            guard l.type == .audio || l.type == .video, let path = l.path else {
                throw ToolError("'\(id)' is not an audio or video layer with a file")
            }
            let range = l.playedSourceRange(sceneDuration: scene.duration)
            let result = try Transcriber.transcribe(path: path, from: range.from, duration: range.duration,
                                                    language: a["language"] as? String)
            try host.mutate("Transcribe") { try $0.setTranscription(id, result) }
            let how = result.onDevice ? "on this Mac" : "by Apple's servers"
            guard !result.words.isEmpty else {
                return text("No speech found in '\(id)' (recognized as \(result.language) \(how)). "
                            + "Check the language, or that the layer's file has speech.")
            }
            let body = result.text.count > 6000 ? String(result.text.prefix(6000)) + " …" : result.text
            return text("Transcribed '\(id)' as \(result.language) \(how): \(result.words.count) words.\n\(body)\n"
                        + "Next: add_captions with id '\(id)' to make timed captions.")

        case "set_caption_texts":
            let id = try string(a, "id")
            guard let texts = a["texts"] as? [String], !texts.isEmpty else { throw ToolError("`texts` must be a non-empty array of strings") }
            let from = max(1, Int(number(a["from"]) ?? 1))
            try host.mutate("Edit Captions") { try $0.setCaptionTexts(id, from: from, texts: texts) }
            return text("Set captions \(from)–\(from + texts.count - 1) of '\(id)'.")

        case "list_captions":
            let id = try string(a, "id")
            let lines = host.currentScene().captions(of: id)
            return text(lines.isEmpty ? "'\(id)' has no captions (add_captions makes them)." : captionList(lines))

        case "set_keyframes":
            let id = try string(a, "id")
            let raw = a["keyframes"] ?? [Any]()
            if a["property"] as? String == "d" {
                let kfs = try SceneJSON.decode([Keyframe<PathShape>].self, fromObject: raw)
                try host.mutate("Set Keyframes") { try $0.setPathKeyframes(id, keyframes: kfs) }
                return text("\(id).d = \(SceneJSON.string(try host.currentScene().layer(id).d, pretty: false))")
            }
            guard let track = KeyTrack(name: try string(a, "property")) else {
                throw ToolError("`property` must be one of \(KeyTrack.allNames + ["d"])")
            }
            switch track {
            case let .number(prop):
                let kfs = try SceneJSON.decode([MotionKeyframe].self, fromObject: raw)
                try host.mutate("Set Keyframes") { try $0.setKeyframes(id, property: prop, keyframes: kfs) }
                return text("\(id).\(prop.rawValue) = \(SceneJSON.string(try host.currentScene().layer(id)[prop], pretty: false))")
            case let .color(prop):
                let kfs = try SceneJSON.decode([ColorKeyframe].self, fromObject: raw)
                try host.mutate("Set Keyframes") { try $0.setColorKeyframes(id, property: prop, keyframes: kfs) }
                return text("\(id).\(prop.rawValue) = \(SceneJSON.string(try host.currentScene().layer(id)[prop], pretty: false))")
            }

        case "apply_preset":
            guard let preset = Preset(rawValue: try string(a, "preset")) else {
                throw ToolError("`preset` must be one of \(Preset.allCases.map(\.rawValue))")
            }
            guard let start = number(a["start"]) else { throw ToolError("`start` must be a number") }
            let duration = number(a["duration"]) ?? preset.defaultDuration
            var ids = (a["ids"] as? [Any])?.compactMap { $0 as? String } ?? []
            if let id = a["id"] as? String, !id.isEmpty { ids.insert(id, at: 0) }
            guard !ids.isEmpty else { throw ToolError("Give `id` or `ids`") }
            let stagger = number(a["stagger"]) ?? 0
            var done: [String] = []
            try host.mutate("Apply \(preset.title)") {
                done = try $0.applyPreset(preset, to: ids, start: start, duration: duration, stagger: stagger)
            }
            let skipped = ids.filter { !done.contains($0) }
            return text("Applied \(preset.rawValue) to \(done.joined(separator: ", ")) from \(start)s for \(duration)s"
                + (done.count > 1 ? " (stagger \(stagger)s)" : "")
                + (skipped.isEmpty ? "" : "; skipped (not applicable): \(skipped.joined(separator: ", "))"))

        case "shatter_image":
            let scene = host.currentScene()
            var sourcePath: String, px: Double, py: Double, pw: Double?, ph: Double?, start: Double, prefix: String
            if let sourceId = a["layer"] as? String, !sourceId.isEmpty {
                let l = try scene.layer(sourceId)
                guard l.type == .image, let p = l.path else { throw ToolError("'\(sourceId)' is not an image layer with a file") }
                sourcePath = p
                px = l.x.value(at: l.start); py = l.y.value(at: l.start)
                pw = l.width?.value(at: l.start); ph = l.height?.value(at: l.start)
                start = number(a["at"]) ?? l.start
                prefix = (a["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sourceId
            } else {
                sourcePath = try string(a, "path")
                px = number(a["x"]) ?? Double(scene.width) / 2
                py = number(a["y"]) ?? Double(scene.height) / 2
                pw = number(a["width"]); ph = number(a["height"])
                start = number(a["at"]) ?? 0
                prefix = (a["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "shatter"
            }
            let url = try AssetStore.existing(sourcePath)
            guard let (image, natural) = AssetStore.loadImage(url) else { throw ToolError("Cannot read image at '\(sourcePath)'") }
            let placedW = pw ?? natural.width, placedH = ph ?? natural.height
            let duration = max(0.05, number(a["duration"]) ?? 0.8)
            let pieces = min(max(Int(number(a["pieces"]) ?? 40), 4), 400)
            let seed = Int(number(a["seed"]) ?? 0)
            let distance = max(0, number(a["distance"]) ?? 1)
            let spin = max(0, number(a["spin"]) ?? 1)
            let direction = (a["direction"] as? String) ?? "out"
            guard ["out", "down", "up"].contains(direction) else { throw ToolError("`direction` must be \"out\", \"down\" or \"up\"") }
            let fadeOut = a["fadeOut"] as? Bool ?? true

            let shards = try ImageShatter.shards(of: image, count: pieces, seed: seed)
            guard !shards.isEmpty else { throw ToolError("Could not shatter the image") }
            // Shard rects are in the decoded CGImage's own pixel space, which for a rasterized SVG differs from
            // `natural` (its vector size): scale against the pixels, not the natural size used only for placement.
            let pixelW = Double(image.width), pixelH = Double(image.height)
            let scaleX = placedW / pixelW, scaleY = placedH / pixelH
            let originX = px - placedW / 2, originY = py - placedH / 2
            let folder = AssetStore.routed(nil, default: "shatter")
            let end = start + duration
            let imgCenter = CGPoint(x: pixelW / 2, y: pixelH / 2)

            var layers: [MotionLayer] = []
            for (i, shard) in shards.enumerated() {
                let id = "\(prefix)-\(i + 1)"
                let asset = try AssetStore.write(shard.png, name: "\(id).png", folder: folder)
                let x0 = originX + shard.rect.midX * scaleX, y0 = originY + shard.rect.midY * scaleY
                var l = MotionLayer(id: id, name: id, type: .image, x: x0, y: y0)
                l.path = asset.path
                l.width = .constant(shard.rect.width * scaleX)
                l.height = .constant(shard.rect.height * scaleY)

                let key = Noise.hash("shatter.\(prefix).\(seed).\(i)")
                func r(_ j: Int) -> Double { Noise.unit(j, key) }
                var dx = shard.centroid.x - imgCenter.x, dy = shard.centroid.y - imgCenter.y
                let mag = (dx * dx + dy * dy).squareRoot()
                if mag < 1 { let angle = r(0) * 2 * .pi; dx = cos(angle); dy = sin(angle) } else { dx /= mag; dy /= mag }
                switch direction {
                case "down": dy = dy * 0.4 + 0.8; dx *= 0.5
                case "up": dy = dy * 0.4 - 0.8; dx *= 0.5
                default: break
                }
                let travel = max(placedW, placedH) * distance * (0.6 + 0.8 * r(1))
                let endX = x0 + dx * travel * scaleX, endY = y0 + dy * travel * scaleY
                let endRotation = (r(2) - 0.5) * 720 * spin

                l.x = AnimValue.make([MotionKeyframe(t: start, v: x0, easing: .linear),
                                      MotionKeyframe(t: end, v: endX, easing: .curve(.cubic, .out))], fallback: x0)
                l.y = AnimValue.make([MotionKeyframe(t: start, v: y0, easing: .linear),
                                      MotionKeyframe(t: end, v: endY, easing: .curve(.cubic, .out))], fallback: y0)
                l.rotation = AnimValue.make([MotionKeyframe(t: start, v: 0, easing: .linear),
                                            MotionKeyframe(t: end, v: endRotation, easing: .curve(.cubic, .out))], fallback: 0)
                if fadeOut {
                    let fadeEnd = min(scene.duration, end + duration * 0.7)
                    l.opacity = AnimValue.make([MotionKeyframe(t: end, v: 1, easing: .linear),
                                               MotionKeyframe(t: fadeEnd, v: 0, easing: .easeIn)], fallback: 1)
                    l.end = fadeEnd
                }
                layers.append(l)
            }

            if let sourceId = a["layer"] as? String, !sourceId.isEmpty, scene.layers.contains(where: { $0.id == sourceId }) {
                try host.mutate("Shatter Image") { s in
                    try s.removeLayer(sourceId)
                    for l in layers { s.addLayer(l) }
                }
            } else {
                try host.mutate("Shatter Image") { s in for l in layers { s.addLayer(l) } }
            }
            return text("Shattered into \(layers.count) pieces ('\(prefix)-1'…'\(prefix)-\(layers.count)'), exploding \(direction) from \(start)s over \(duration)s.")

        case "sync_to_beats":
            guard let action = BeatAction(rawValue: try string(a, "action")) else {
                throw ToolError("`action` must be one of \(BeatAction.allCases.map(\.rawValue))")
            }
            let grid = BeatGrid(rawValue: a["every"] as? String ?? "beat") ?? .beat
            let ids = (a["ids"] as? [Any])?.compactMap { $0 as? String } ?? []
            let preset = (a["preset"] as? String).flatMap(Preset.init(rawValue:))
            if action == .preset, preset == nil { throw ToolError("`preset` must be one of \(Preset.allCases.map(\.rawValue))") }
            let prop = (a["property"] as? String).flatMap(AnimProperty.init(rawValue:))
            if action == .pulse, prop == nil { throw ToolError("`property` must be an animatable number (scale, brightness, glow…)") }
            var used = 0
            var times: [Double] = []
            try host.mutate("Sync to Beats") { s in
                times = try s.beatTimes(source: a["source"] as? String, grid: grid, from: number(a["from"]), to: number(a["to"]),
                                        minStrength: number(a["minStrength"]) ?? 0.4)
                used = try s.syncToBeats(ids, action: action, times: times, preset: preset, property: prop,
                                         amount: number(a["amount"]) ?? (action == .flash ? 0.6 : 0.15),
                                         release: number(a["release"]) ?? 0.25, duration: number(a["duration"]))
            }
            let shown = times.prefix(8).map { String(format: "%.2f", $0) }.joined(separator: ", ")
            return text("\(action.rawValue) on \(used) \(grid.rawValue)s (\(shown)\(times.count > 8 ? ", …" : ""))")

        case "add_template":
            guard let kind = TemplateKind(rawValue: try string(a, "kind")) else {
                throw ToolError("`kind` must be one of \(TemplateKind.allCases.map(\.rawValue))")
            }
            var o = TemplateOptions()
            o.title = a["title"] as? String
            o.subtitle = a["subtitle"] as? String
            o.accent = (a["accent"] as? String).flatMap(RGBA.init(hex:))
            o.start = number(a["start"]) ?? 0
            o.duration = number(a["duration"]) ?? 4
            o.x = number(a["x"]); o.y = number(a["y"])
            o.fontName = a["fontName"] as? String
            var gid = ""
            try host.mutate("Add \(kind.title)") { gid = try $0.addTemplate(kind, id: a["id"] as? String, options: o) }
            let g = try host.currentScene().layer(gid)
            return text("Added \(kind.title) '\(gid)' from \(o.start)s for \(o.duration)s: a group of \(g.children.map(\.id).joined(separator: ", ")). Edit its parts by id (text, colors, timing) like any layer.")

        case "apply_look":
            guard let kind = LookKind(rawValue: try string(a, "kind")) else {
                throw ToolError("`kind` must be one of \(LookKind.allCases.map(\.rawValue))")
            }
            var o = LookOptions()
            o.accent = (a["accent"] as? String).flatMap(RGBA.init(hex:))
            o.intensity = number(a["intensity"]) ?? 1
            o.particles = a["particles"] as? Bool ?? true
            o.grain = a["grain"] as? Bool ?? true
            o.vignette = a["vignette"] as? Bool ?? true
            o.cameraDrift = a["cameraDrift"] as? Bool ?? true
            var ids: [String] = []
            try host.mutate("Apply \(kind.title) Look") { ids = try $0.applyLook(kind, options: o) }
            let s = host.currentScene()
            let parts = ids.compactMap { try? s.layer($0) }.flatMap { $0.children.map(\.id) }
            return text("Applied the \(kind.title) look (\(kind.summary)): groups \(ids.joined(separator: ", ")) with \(parts.joined(separator: ", ")). \(kind.isLight ? "This is a light look: use dark text (#15171C) and shadows instead of glow." : "Dark look: near-white text (#F2F3F7), glow or soft shadows on the subject.") Render a frame to check.")

        case "remove_look":
            try host.mutate("Remove Look") { try $0.removeLook() }
            return text("Removed the look layers.")

        case "text_to_path":
            let id = try string(a, "id")
            let letters = a["letters"] as? Bool ?? false
            try host.mutate("Text to Path") { s in _ = try s.textToPath(id, letters: letters, at: number(a["time"]) ?? s.layer(id).start) }
            let l = try host.currentScene().layer(id)
            return text(letters ? "'\(id)' is now a group of \(l.children.count) letter paths (\(l.children.map(\.id).prefix(3).joined(separator: ", "))…)"
                : "'\(id)' is now a path layer: trim, morph and path operators work on it (try preset writeOn)")

        case "combine_paths":
            guard let ids = (a["ids"] as? [Any])?.compactMap({ $0 as? String }), ids.count >= 2 else {
                throw ToolError("`ids` must list at least two layers")
            }
            guard let op = PathCombine(rawValue: a["op"] as? String ?? "union") else {
                throw ToolError("`op` must be one of \(PathCombine.allCases.map(\.rawValue))")
            }
            var newId = ""
            try host.mutate("Combine Paths") { s in
                newId = try s.combinePaths(ids, op: op, id: a["id"] as? String, keep: a["keep"] as? Bool ?? false,
                                           at: number(a["time"]) ?? 0)
            }
            return text("Combined \(ids.joined(separator: ", ")) (\(op.rawValue)) into path layer '\(newId)'")

        case "stabilize":
            let scene = host.currentScene()
            let id = try string(a, "layer")
            let layer = try scene.layer(id)
            let from = number(a["from"]) ?? layer.start
            let to = number(a["to"]) ?? layer.effectiveEnd(sceneDuration: scene.duration)
            let drift = try VideoTracking.shake(layer: layer, in: scene, from: from, to: to, step: number(a["step"]) ?? 0)
            let lock = (a["mode"] as? String ?? "smooth") == "lock"
            let zoom = max(1, number(a["zoom"]) ?? 1.08)
            try host.mutate("Stabilize") { try $0.stabilize(id, drift: drift, lock: lock, window: Int(number(a["smoothing"]) ?? 15), zoom: zoom) }
            let maxShift = drift.map { hypot($0.center.x, $0.center.y) }.max() ?? 0
            return text("Stabilized '\(id)' (\(lock ? "locked" : "smoothed"), \(drift.count) frames, camera drifted up to \(Int(maxShift)) px; scaled ×\(zoom) to hide the moving edges). Translation only: rotation shake stays.")

        case "track_motion":
            let scene = host.currentScene()
            let id = try string(a, "layer")
            let layer = try scene.layer(id)
            guard let x = number(a["x"]), let y = number(a["y"]) else { throw ToolError("`x` and `y` (center of the object, scene px) are required") }
            let bw = number(a["width"]) ?? 120, bh = number(a["height"]) ?? 120
            let from = number(a["from"]) ?? layer.start
            let to = number(a["to"]) ?? layer.effectiveEnd(sceneDuration: scene.duration)
            let box = CGRect(x: x - bw / 2, y: y - bh / 2, width: bw, height: bh)
            let samples = try VideoTracking.track(layer: layer, in: scene, box: box, from: from, to: to, step: number(a["step"]) ?? 0)
            let smooth = Int(number(a["smoothing"]) ?? 3)
            let series = VideoTracking.smoothed(samples, window: smooth)
            if let target = (a["target"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                let keep = a["keepOffset"] as? Bool ?? true
                let scale = a["scale"] as? Bool ?? false
                try host.mutate("Track Motion") { try $0.attach(target, to: series, keepOffset: keep, scale: scale) }
                let last = series.last!
                return text("Tracked '\(id)' from \(from)s to \(String(format: "%.2f", last.t))s (\(series.count) keys) and attached '\(target)': it now follows the object" + (keep ? " keeping its offset" : "") + ". Lowest confidence \(String(format: "%.2f", series.map(\.confidence).min() ?? 0)).")
            }
            let lines = series.map { String(format: "%.2f: %.0f, %.0f (%.0fx%.0f, conf %.2f)", $0.t, $0.center.x, $0.center.y, $0.size.width, $0.size.height, $0.confidence) }
            return text("Tracked '\(id)' (\(series.count) samples, scene px):\n" + lines.joined(separator: "\n"))

        case "auto_reframe":
            let scene = host.currentScene()
            let id = try string(a, "layer")
            let layer = try scene.layer(id)
            guard let tw = number(a["width"]), let th = number(a["height"]), tw > 0, th > 0 else {
                throw ToolError("`width` and `height` of the target format are required (e.g. 1080 x 1920)")
            }
            let from = number(a["from"]) ?? layer.start
            let to = number(a["to"]) ?? layer.effectiveEnd(sceneDuration: scene.duration)
            let step = max(0.1, number(a["step"]) ?? 0.5)
            let samples = try VideoTracking.saliency(layer: layer, in: scene, from: from, to: to, step: step)
            let series = VideoTracking.smoothed(samples, window: Int(number(a["smoothing"]) ?? 3))
            try host.mutate("Auto Reframe") { try $0.reframe(id, samples: series, targetWidth: tw, targetHeight: th) }
            let l = try host.currentScene().layer(id)
            return text("Reframed '\(id)' for \(Int(tw))x\(Int(th)) with \(series.count) position keys (x now \(SceneJSON.string(l.x, pretty: false))). Export with size \(Int(tw))x\(Int(th)) and fit \"crop\" to get the vertical cut; the subject stays centered.")

        case "transition":
            guard let type = TransitionType(rawValue: try string(a, "type")) else {
                throw ToolError("`type` must be one of \(TransitionType.allCases.map(\.rawValue))")
            }
            guard let at = number(a["at"]) else { throw ToolError("`at` must be a number") }
            let d = number(a["duration"]) ?? 0.6
            let outId = (a["out"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let inId = (a["in"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var origin: (x: Double, y: Double)?
            if let x = number(a["x"]), let y = number(a["y"]) { origin = (x, y) }
            try host.mutate("Transition") {
                try $0.transition(type, out: outId, in: inId, at: at, duration: d, direction: a["direction"] as? String,
                                  shape: a["shape"] as? String, origin: origin)
            }
            return text("\(type.rawValue) transition" + (outId.map { " out: \($0)" } ?? "") + (inId.map { " in: \($0)" } ?? "")
                + " from \(at)s for \(d)s")

        case "group_layers":
            guard let ids = (a["ids"] as? [Any])?.compactMap({ $0 as? String }), !ids.isEmpty else {
                throw ToolError("`ids` must be a non-empty array of layer ids")
            }
            var gid = ""
            try host.mutate("Group Layers") { gid = try $0.groupLayers(ids, id: a["id"] as? String, name: a["name"] as? String) }
            return text("Grouped \(ids.joined(separator: ", ")) into '\(gid)' (centered on the scene; children keep their coordinates)")

        case "ungroup":
            let id = try string(a, "id")
            var count = 0
            try host.mutate("Ungroup") { s in count = try s.layer(id).children.count; try s.ungroup(id) }
            return text("Ungrouped '\(id)': \(count) layers are top-level again")

        case "set_parent":
            let id = try string(a, "id")
            let parent = a["parent"] as? String
            let t = number(a["time"]) ?? 0
            let keep = a["keepPosition"] as? Bool ?? true
            try host.mutate("Set Parent") { try $0.setParent(id, to: parent, at: t, keepPosition: keep) }
            let l = try host.currentScene().layer(id)
            return text((parent.map { "'\(id)' now follows '\($0)'" } ?? "'\(id)' has no parent")
                + "; x/y: \(SceneJSON.string(l.x, pretty: false)), \(SceneJSON.string(l.y, pretty: false))")

        case "list_assets":
            let kind = a["kind"] as? String
            let folder = try AssetStore.validFolder(a["folder"] as? String)
            let shared = (a["library"] as? String) == "shared"
            let root = shared ? AssetStore.sharedDirectory : AssetStore.directory
            if !folder.isEmpty, !AssetStore.folders(in: root).contains(folder) { throw AssetError.folderNotFound(folder) }
            let inFolder: (String) -> Bool = { folder.isEmpty || $0.hasPrefix(folder + "/") }
            let scene = host.currentScene()
            let assets = AssetStore.list(in: root).filter { (kind == nil || $0.kind.rawValue == kind) && inFolder($0.name) }
            let folders = AssetStore.folders(in: root).filter(inFolder)
            let title = shared ? "Shared library (read-only here — import_asset a path to copy it into the project)"
                : AssetStore.isProjectLibrary ? "Project library" : "Asset library"
            var lines = ["\(title): \(root.path)\(folder.isEmpty ? "" : " — folder \(folder)") (\(assets.count) files)"]
            if !folders.isEmpty {
                lines.append("Folders: " + folders.map { $0 + "/" }.joined(separator: ", "))
            }
            for asset in assets {
                let users = scene.layers(usingPath: asset.path)
                lines.append("\(asset.name) — \(asset.summary)\(users.isEmpty ? "" : " — used by: \(users.joined(separator: ", "))")\n    \(asset.path)"
                    + (asset.credit.map { "\n    credit: \($0.attribution)\($0.requiresAttribution ? " (required)" : "")" } ?? ""))
            }
            return text(lines.joined(separator: "\n"))

        case "import_asset":
            let source = try string(a, "source")
            let overwrite = a["overwrite"] as? Bool ?? false
            let name = a["name"] as? String
            let folder = a["folder"] as? String
            let asset: AssetInfo
            if source.hasPrefix("http://") || source.hasPrefix("https://") {
                guard let url = URL(string: source) else { throw ToolError("Invalid URL: \(source)") }
                asset = try AssetStore.download(url, name: name, folder: folder, overwrite: overwrite)
            } else {
                let path = (source as NSString).expandingTildeInPath
                guard path.hasPrefix("/") else { throw ToolError("`source` must be an absolute path or an http(s) URL") }
                asset = try AssetStore.importFile(URL(fileURLWithPath: path), name: name, folder: folder, overwrite: overwrite)
            }
            return text("Imported '\(asset.name)' (\(asset.summary))\npath: \(asset.path)")

        case "write_asset":
            let name = try string(a, "name")
            let data: Data
            if let s = a["text"] as? String {
                data = Data(s.utf8)
            } else if let b = a["base64"] as? String {
                guard let d = Data(base64Encoded: b, options: .ignoreUnknownCharacters) else { throw ToolError("`base64` is not valid base64") }
                data = d
            } else {
                throw ToolError("Give either `text` or `base64`")
            }
            let asset = try AssetStore.write(data, name: name, folder: a["folder"] as? String,
                                             overwrite: a["overwrite"] as? Bool ?? false)
            return text("Wrote '\(asset.name)' (\(asset.summary))\npath: \(asset.path)")

        case "read_asset":
            let url = try AssetStore.existing(try string(a, "name"))
            guard let asset = AssetStore.info(url) else { throw ToolError("Cannot read \(url.path)") }
            let header = "\(asset.name) — \(asset.summary)\npath: \(asset.path)"
            switch asset.kind {
            case .image:
                let maxPixels = min(max(Int(number(a["maxPixels"]) ?? 1024), 64), 2048)
                guard let png = AssetStore.previewPNG(url, maxPixels: maxPixels) else { return text(header + "\n(cannot decode image)") }
                return ["content": [
                    ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                    ["type": "text", "text": header],
                ]]
            case .text:
                return text(header + "\n\n" + (try AssetStore.readText(url)))
            default:
                if let s = try? AssetStore.readText(url, maxBytes: 50_000) { return text(header + "\n\n" + s) }
                return text(header)
            }

        case "rename_asset":
            let moved = try AssetStore.rename(try string(a, "name"), to: try string(a, "newName"))
            var ids: [String] = []
            if !host.currentScene().layers(usingPath: moved.from).isEmpty {
                try host.mutate("Rename Asset") { ids = $0.replacePath(moved.from, with: moved.to) }
            }
            return text("Renamed to '\(AssetStore.relativeName(of: moved.to) ?? moved.to)'\npath: \(moved.to)"
                + (ids.isEmpty ? "" : "\nUpdated layers: \(ids.joined(separator: ", "))"))

        case "delete_asset":
            let url = try AssetStore.existing(try string(a, "name"))
            let users = host.currentScene().layers(usingPath: url.path)
            if !users.isEmpty, a["force"] as? Bool != true {
                throw ToolError("'\(url.lastPathComponent)' is used by layers: \(users.joined(separator: ", ")). Remove or repoint those layers first, or pass \"force\": true.")
            }
            try AssetStore.trash(url.path)
            return text("Moved '\(url.lastPathComponent)' to the Trash"
                + (users.isEmpty ? "" : " (layers \(users.joined(separator: ", ")) now point to a missing file)"))

        case "create_folder":
            let name = try AssetStore.createFolder(try string(a, "name"))
            return text("Created folder '\(name)'\npath: \(AssetStore.directory.appendingPathComponent(name).path)")

        case "rename_folder":
            let moved = try AssetStore.renameFolder(try string(a, "name"), to: try string(a, "newName"))
            var ids: [String] = []
            if !host.currentScene().layers(inFolder: moved.from).isEmpty {
                try host.mutate("Rename Folder") { ids = $0.replaceFolder(moved.from, with: moved.to) }
            }
            return text("Moved folder to '\(AssetStore.relativeName(of: moved.to) ?? moved.to)'\npath: \(moved.to)"
                + (ids.isEmpty ? "" : "\nUpdated layers: \(ids.joined(separator: ", "))"))

        case "delete_folder":
            let url = try AssetStore.existingFolder(try string(a, "name"))
            let users = host.currentScene().layers(inFolder: url.path)
            if !users.isEmpty, a["force"] as? Bool != true {
                throw ToolError("Files in '\(AssetStore.relativeName(of: url.path) ?? url.path)' are used by layers: \(users.joined(separator: ", ")). Remove or repoint those layers first, or pass \"force\": true.")
            }
            try AssetStore.trashFolder(url.path)
            return text("Moved folder '\(AssetStore.relativeName(of: url.path) ?? url.path)' and its contents to the Trash"
                + (users.isEmpty ? "" : " (layers \(users.joined(separator: ", ")) now point to missing files)"))

        case "search_stock":
            let query = try string(a, "query")
            guard let kind = StockKind(rawValue: a["kind"] as? String ?? "photo") else {
                throw ToolError("`kind` must be one of \(StockKind.allCases.map(\.rawValue))")
            }
            let page = max(1, Int(number(a["page"]) ?? 1))
            let maxDuration = number(a["maxDuration"])
            var music = MusicFilter(instrumental: a["instrumental"] as? Bool ?? false, minDuration: number(a["minDuration"]))
            if let t = a["tempo"] as? String {
                guard let tempo = MusicTempo(rawValue: t.lowercased()) else {
                    throw ToolError("`tempo` must be one of \(MusicTempo.allCases.map(\.rawValue))")
                }
                music.tempo = tempo
            }
            if let s = a["source"] as? String {
                guard let source = MusicSource(rawValue: s.lowercased()) else {
                    throw ToolError("`source` must be one of \(MusicSource.allCases.map(\.rawValue)) (music only)")
                }
                music.source = source
            }
            var items = try StockSearch.search(query, kind: kind, page: page, vietnamese: a["vietnamese"] as? Bool ?? false,
                                               maxDuration: maxDuration, orientation: a["orientation"] as? String, music: music)
            if let limit = number(a["limit"]), limit > 0 { items = Array(items.prefix(Int(limit))) }
            if items.isEmpty {
                var msg = "No \(kind.rawValue) results for '\(query)'. Try a simpler or English query."
                if kind == .music, !music.isEmpty {
                    msg += " The filters narrow it a lot (tempo keeps only tracks whose tempo is known): drop tempo, source or minDuration, or use one or two words."
                }
                if kind == .sound {
                    msg += String(format: " Only sounds up to %.0f s are listed (maxDuration). generate_sfx makes whoosh/pop/click/ding/riser/impact… without searching.",
                                  maxDuration ?? StockSearch.defaultSoundMaxDuration)
                }
                return text(msg)
            }
            let preview = a["preview"] as? Bool ?? true
            let profiles = kind == .sound && preview ? StockSearch.soundProfiles(items) : [:]
            var lines = ["\(items.count) \(kind.rawValue) results for '\(query)' (page \(page)). Import one with import_stock {\"ref\": …}:"]
            if kind == .sound, let synth = SynthKind.matching(query) {
                lines.insert("Tip: generate_sfx {\"kind\": \"\(synth.rawValue)\", \"hitAt\": …} makes this sound to measure (length, pitch, exact hit) — "
                             + "prefer it unless you need a real recording.", at: 0)
            }
            if kind == .music {
                lines.append("Sources: " + MusicSource.allCases.map { "\($0.title) (\($0.note))" }.joined(separator: "; ")
                             + ". After import, analyze_audio gives the exact tempo and beats.")
            }
            for (i, item) in items.enumerated() {
                lines.append("\(i + 1). \(item.summary)")
                if let p = profiles[i] { lines.append("   sound: \(p.summary)") }
            }
            var content: [[String: Any]] = []
            if kind == .sound, !profiles.isEmpty, let png = SoundProfile.sheet(items.indices.map { profiles[$0] }) {
                lines.append("The image shows each sound's waveform (dB scale, numbered in the same order): orange = main peak, "
                             + "blue bands = separate sounds. For a one-shot effect pick a single clear shape that fits the motion: "
                             + "hit = sharp start, whoosh = swell in the middle, riser = builds to the end.")
                content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
            } else if !kind.isAudio, preview, let png = StockSearch.contactSheet(items) {
                lines.append(kind == .font ? "The image shows each font's name and a sample, numbered in the same order."
                             : "The image shows the results numbered in the same order.")
                content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
            }
            content.append(["type": "text", "text": lines.joined(separator: "\n")])
            return ["content": content]

        case "import_stock":
            let item = try StockSearch.item(ref: try string(a, "ref"))
            if item.kind == .font {
                let styles = (a["weights"] as? [Any])?.map { "\($0)" }
                let files = try StockSearch.importFont(item, styles: styles, folder: a["folder"] as? String)
                let faces = FontLibrary.faces(of: item.title)
                var lines = ["Imported the font \(item.title): \(files.map(\.name).joined(separator: ", "))",
                             "license: \(item.credit.license) (no credit needed)"]
                if faces.isEmpty {
                    lines.append("Warning: the files did not register as a font. Try another family.")
                } else {
                    let weights = faces.map { "\($0.weight)\($0.italic ? " italic" : "")" }
                    lines.append("Use it: \"fontName\": \"\(item.title)\" with fontWeight one of: \(weights.joined(separator: ", ")) (or names like regular/bold; add \" italic\" for italics).")
                }
                return text(lines.joined(separator: "\n"))
            }
            let asset = try StockSearch.importItem(item, name: a["name"] as? String, folder: a["folder"] as? String,
                                                   color: a["color"] as? String,
                                                   size: Int(number(a["size"]) ?? 512))
            var lines = ["Imported '\(asset.name)' (\(asset.summary))", "path: \(asset.path)",
                         "license: \(item.credit.license)"]
            if item.credit.requiresAttribution {
                lines.append("Credit required — include in the video or its description: \(item.credit.attribution)")
            }
            if item.kind == .video {
                lines.append("Next: add_layer {\"layer\": {\"type\": \"video\", \"path\": \"\(asset.path)\", \"start\": …}} "
                             + "(size it to cover the frame; muted with \"volume\": 0 if its sound is not wanted).")
            } else if item.kind == .music {
                lines.append("Next: add_audio {\"path\": \"\(asset.path)\", \"role\": \"music\", \"start\": 0, \"end\": <scene duration>, \"volume\": 0.6, \"fadeIn\": 0.5, \"fadeOut\": 1.5, \"duckTo\": 0.25}")
            } else if item.kind == .sound {
                if let p = SoundProfile.cached(path: asset.path) {
                    lines.append("Sound: \(p.summary)")
                    if p.shape == .multiple {
                        let list = p.bursts.enumerated().map { String(format: "%d: %.2f–%.2fs (peak %.2fs)", $0.offset + 1, $0.element.start, $0.element.end, $0.element.peak) }
                        lines.append("Separate sounds: " + list.joined(separator: "; ") + ". Choose one with \"hit\": <number>.")
                    }
                }
                lines.append("Next: add_audio {\"path\": \"\(asset.path)\", \"role\": \"sfx\", \"hitAt\": <scene time the peak should land>} "
                             + "(skips leading silence and starts early so the peak lands on that frame).")
            }
            return text(lines.joined(separator: "\n"))

        case "get_credits":
            let used = AssetStore.credits(usedBy: host.currentScene())
            if used.isEmpty { return text("The scene uses no assets from the free sources, so there is nothing to credit.") }
            let required = used.filter { $0.credit.requiresAttribution }
            var lines = ["Credits for assets used in this scene (\(required.count) required):"]
            for (_, c) in used { lines.append("- \(c.attribution)\(c.requiresAttribution ? "" : " (optional)")") }
            return text(lines.joined(separator: "\n"))

        case "render_frame":
            guard let t = number(a["time"]) else { throw ToolError("`time` must be a number") }
            let scale = min(max(number(a["scale"]) ?? 0.5, 0.1), 1)
            let scene = host.currentScene()
            guard let png = FrameRenderer().pngData(scene, at: t, scale: scale) else { throw ToolError("render failed") }
            let visible = scene.layers.filter { $0.isVisible(at: t, sceneDuration: scene.duration) }.map(\.id)
            return ["content": [
                ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                ["type": "text", "text": "t=\(t)s, visible layers: \(visible.joined(separator: ", "))"],
            ]]

        case "export_video":
            let raw = try string(a, "path")
            let path = (raw as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw ToolError("`path` must be absolute") }
            let url = URL(fileURLWithPath: path)
            let scene = host.currentScene()
            var options = ExportOptions()
            var note = ""
            if let id = a["preset"] as? String, !id.isEmpty {
                guard let preset = PlatformPreset.named(id) else {
                    throw ToolError("Unknown preset '\(id)'. Presets: \(PlatformPreset.all.map(\.id).joined(separator: ", "))")
                }
                options.size = preset.size
                if let f = a["fit"] as? String {
                    guard let fit = ExportFit(rawValue: f) else { throw ToolError("`fit` is fit or fill") }
                    options.fit = fit
                }
                let (w, h) = options.pixelSize(for: scene)
                note = " at \(w)×\(h) for \(preset.name)"
                    + (options.isReframed(for: scene) ? " (\(options.fit == .fit ? "letterboxed" : "cropped") from \(scene.width)×\(scene.height))" : "")
                let warnings = preset.warnings(for: scene, duration: Double(options.frameRange(for: scene).count) / Double(scene.fps),
                                               estimatedBytes: options.estimatedBytes(for: scene))
                if !warnings.isEmpty { note += ". Warning: " + warnings.joined(separator: " ") }
            }
            let started = Date()
            try VideoExporter.export(scene, to: url, options: options)
            if !License.isPro, !ExportFormat.infer(from: url).isAudioOnly {
                var free = options
                _ = try? License.prepareExport(scene, options: &free, format: ExportFormat.infer(from: url))
                let (w, h) = free.pixelSize(for: scene)
                note += ". Free plan: \(w)×\(h) with a \"Made with Vey Motion\" watermark (VeyMotion Pro removes it and allows 4K/ProRes)"
            }
            return text(String(format: "Exported %@ (%d frames) in %.1fs", url.path, scene.frameCount, Date().timeIntervalSince(started)) + note)

        default:
            throw RPCError.invalidParams("Unknown tool: \(name)")
        }
    }

    /// Beats, downbeats, onsets and loudness of an audio layer (scene seconds) or a file (file seconds), as JSON.
    private func analyzeAudio(_ a: [String: Any]) throws -> String {
        let scene = host.currentScene()
        var layer: MotionLayer?
        let path: String
        if let p = a["path"] as? String, !p.isEmpty, (a["id"] as? String ?? "").isEmpty {
            path = (p as NSString).expandingTildeInPath
        } else {
            if let id = a["id"] as? String, !id.isEmpty { layer = try scene.layer(id) } else { layer = scene.defaultReactSource }
            guard let l = layer else { throw ToolError("The scene has no audio layer: pass an audio layer `id` or a file `path`.") }
            guard l.type == .audio, let p = l.path else { throw ToolError("'\(l.id)' is not an audio layer with a file") }
            path = p
        }
        let an = try AudioAnalysisCache.analysis(path: path)
        // File time + offset = scene time (for a file: offset 0, the whole file).
        let offset = layer.map { $0.start - $0.trimIn } ?? 0
        let lo = layer?.start ?? 0
        let hi = layer.map { min($0.effectiveEnd(sceneDuration: scene.duration), scene.duration) } ?? an.duration
        let from = max(lo, number(a["from"]) ?? lo), to = min(hi, number(a["to"]) ?? hi)
        guard to > from else { throw ToolError(String(format: "Nothing to analyze: the audio plays %.2f–%.2fs", lo, hi)) }
        let minStrength = min(max(number(a["minStrength"]) ?? 0.4, 0), 1)

        func fmt(_ v: Double, _ digits: Int = 3) -> String {
            var s = String(format: "%.\(digits)f", v)
            while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
            return s == "-0" ? "0" : s
        }
        func times(_ ts: [Double]) -> String {
            "[" + ts.map { $0 + offset }.filter { $0 >= from - 0.01 && $0 <= to + 0.01 }.map { fmt($0) }.joined(separator: ",") + "]"
        }
        let onsets = an.onsets.filter { $0.strength >= minStrength && $0.t + offset >= from - 0.01 && $0.t + offset <= to + 0.01 }
        let loudness = an.loudness(from: from - offset, to: to - offset)
        func quoted(_ s: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
            return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        }
        var fields: [String] = []
        fields.append(layer.map { "\"layer\":\(quoted($0.id))" } ?? "\"file\":\(quoted(path))")
        fields.append("\"timesAre\":\"\(layer == nil ? "file seconds" : "scene seconds")\"")
        fields.append("\"range\":[\(fmt(from)),\(fmt(to))]")
        if let bpm = an.bpm {
            fields.append("\"bpm\":\(fmt(bpm, 1))")
            fields.append("\"beatInterval\":\(fmt(60 / bpm))")
        } else {
            fields.append("\"bpm\":null")
            fields.append("\"note\":\"No steady beat found: time things to onsets and loudness instead.\"")
        }
        fields.append("\"beats\":\(times(an.beats))")
        fields.append("\"downbeats\":\(times(an.downbeats))")
        fields.append("\"onsets\":[" + onsets.map { "[\(fmt($0.t + offset)),\(fmt($0.strength, 2))]" }.joined(separator: ",") + "]")
        fields.append("\"loudness\":{\"from\":\(fmt(from)),\"step\":1,\"values\":[" + loudness.map { fmt($0, 2) }.joined(separator: ",") + "]}")
        if an.duration <= 30, let p = SoundProfile.cached(path: path) {
            // Sound effects: the shape, in the same time base as the rest.
            let bursts = p.bursts.map { "[\(fmt($0.start + offset)),\(fmt($0.peak + offset)),\(fmt($0.end + offset))]" }
            fields.append("\"sound\":{\"shape\":\(quoted(p.shape.rawValue)),\"peak\":\(fmt(p.peak + offset)),"
                          + "\"bursts\":[\(bursts.joined(separator: ","))],\"tone\":\(quoted(p.tone)),\"summary\":\(quoted(p.summary))}")
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Problems with text layers' fonts: names that are not installed, and letters the font cannot draw.
    private func fontNotes(_ layers: [MotionLayer]) -> [String] {
        var notes: [String] = []
        var reported = Set<String>()
        for l in layers where l.type == .text || (l.type == .model && l.model.shape == .text) {
            guard let name = l.fontName, !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let ps = FontLibrary.resolve(name, weight: l.fontWeight) else {
                if reported.insert(name).inserted {
                    let alt = FontLibrary.suggestions(for: name)
                    notes.append("Font '\(name)' was not found, so '\(l.id)' uses the system font"
                        + (alt.isEmpty ? "" : ". Similar installed fonts: \(alt.joined(separator: ", "))")
                        + ". list_fonts shows what is available; search_stock kind \"font\" + import_stock adds a Google font.")
                }
                continue
            }
            let missing = FontLibrary.missingCharacters(l.text, postScriptName: ps)
            if !missing.isEmpty {
                notes.append("Font '\(name)' has no letters for \"\(String(missing.prefix(16)))\" in '\(l.id)' (another font fills them in, "
                    + "which looks uneven). Use a font that has them, e.g. list_fonts with vietnamese true, or search_stock kind \"font\" with vietnamese true.")
            }
        }
        return notes
    }

    /// The animation clips of glTF models and which one plays, so agents can pick one.
    private func modelNotes(_ layers: [MotionLayer]) -> [String] {
        layers.compactMap { l in
            let clips = l.modelAnimations
            guard !clips.isEmpty else { return nil }
            let list = clips.enumerated().map { "\($0.offset): \"\($0.element.name)\" (\(String(format: "%.2f", $0.element.duration)) s)" }
            let state: String
            if let i = l.model.clipIndex(in: clips.map(\.name)) {
                state = "it plays \"\(clips[i].name)\""
            } else if l.model.animation?.lowercased() == "none" {
                state = "it shows the rest pose"
            } else {
                state = "there is no clip \"\(l.model.animation ?? "")\", so it shows the rest pose"
            }
            return "Model '\(l.id)' has animation clips \(list.joined(separator: ", ")); \(state). Pick one with model.animation "
                + "(name or number; \"none\" = still), timing with model.animationSpeed, animationOffset, animationLoop."
        }
    }

    /// Library fonts first, then installed families, with their weights.
    private func fontList(query: String, vietnamese: Bool, limit: Int) -> String {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let library = Set(FontLibrary.libraryFamilies)
        var families = FontLibrary.listedFamilies().filter { q.isEmpty || $0.lowercased().contains(q) }
        if vietnamese { families = families.filter(FontLibrary.supportsVietnamese) }
        families.sort { (library.contains($0) ? 0 : 1, $0) < (library.contains($1) ? 0 : 1, $1) }
        func describe(_ f: String) -> String {
            let faces = FontLibrary.faces(of: f)
            let weights = Array(Set(faces.filter { !$0.italic }.map(\.weight))).sorted().map(String.init)
            let italic = faces.contains { $0.italic }
            return "- \(f) — \(weights.isEmpty ? "italic" : weights.joined(separator: " "))\(italic && !weights.isEmpty ? " + italic" : "")"
                + (library.contains(f) ? " [asset library]" : "")
        }
        guard !families.isEmpty else {
            return "No fonts match '\(query)'\(vietnamese ? " with Vietnamese letters" : ""). search_stock kind \"font\" finds Google fonts to import."
        }
        let shown = families.prefix(max(1, limit))
        var lines = ["\(families.count) font families\(vietnamese ? " with Vietnamese letters" : "")\(q.isEmpty ? "" : " matching '\(query)'")"
                     + (families.count > shown.count ? " (first \(shown.count); use query to narrow)" : "")
                     + ". Use the family as fontName and pick a weight with fontWeight (numbers are CSS weights):"]
        lines += shown.map(describe)
        return lines.joined(separator: "\n")
    }

    private func warnings(_ problems: [String]) -> String {
        problems.isEmpty ? "" : "\nWarnings:\n" + problems.joined(separator: "\n")
    }

    private func text(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]]]
    }

    /// "3 [12.40–15.10] text" per caption.
    private func captionList(_ lines: [CaptionLine]) -> String {
        lines.map { String(format: "%d [%.2f–%.2f] ", $0.number, $0.start, $0.end) + $0.text }.joined(separator: "\n")
    }

    private func string(_ a: [String: Any], _ key: String) throws -> String {
        guard let s = a[key] as? String, !s.isEmpty else { throw ToolError("`\(key)` must be a non-empty string") }
        return s
    }

    private func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// Text-to-speech engine: "macos" (default, voices built into macOS) or "vieneu" (Vietnamese cloud voices).
    private func voiceEngine(_ a: [String: Any]) throws -> String {
        let e = (a["engine"] as? String)?.lowercased() ?? "macos"
        guard e == "macos" || e == "vieneu" else { throw ToolError("`engine` must be \"macos\" or \"vieneu\"") }
        return e
    }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
