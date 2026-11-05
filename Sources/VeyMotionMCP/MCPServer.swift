import Foundation
import VeyMotionCore

/// Where the MCP server reads and writes the scene. The app routes mutations through its undo stack;
/// the CLI host writes them to a file.
public protocol SceneHost: AnyObject {
    func currentScene() -> MotionScene
    func mutate(_ label: String, _ body: (inout MotionScene) throws -> Void) throws
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
                return try callTool(name, args)
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
            try host.mutate("Set Scene") { $0 = scene }
            return text("Scene set: \(scene.width)x\(scene.height) @\(scene.fps)fps, \(scene.duration)s, \(scene.layers.count) layers: \(scene.layers.map(\.id).joined(separator: ", "))" + warnings(problems))

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
            try host.mutate("Add Layer") {
                newId = $0.addLayer(layer, at: a["index"] as? Int)
                problems = $0.refreshMediaInfo()
            }
            return text("Added layer '\(newId)'" + warnings(problems))

        case "add_layers":
            guard let list = a["layers"] as? [Any], !list.isEmpty else { throw ToolError("`layers` must be a non-empty array") }
            let layers = try SceneJSON.decode([MotionLayer].self, fromObject: list)
            var ids: [String] = []
            var problems: [String] = []
            try host.mutate("Add \(layers.count) Layers") { s in
                ids = layers.map { s.addLayer($0) }
                problems = s.refreshMediaInfo()
            }
            return text("Added \(ids.count) layers: \(ids.joined(separator: ", ")) (scene now has \(host.currentScene().layers.count))" + warnings(problems))

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
            return text(SceneJSON.string(try host.currentScene().layer(newId)))

        case "remove_layer":
            let id = try string(a, "id")
            try host.mutate("Remove Layer") { try $0.removeLayer(id) }
            return text("Removed '\(id)'")

        case "reorder_layer":
            let id = try string(a, "id")
            guard let index = a["index"] as? Int else { throw ToolError("`index` must be an integer") }
            try host.mutate("Reorder Layer") { try $0.moveLayer(id, to: index) }
            return text("Order (bottom→top): \(host.currentScene().layers.map(\.id).joined(separator: ", "))")

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
            var newId = ""
            try host.mutate("Add Audio") { newId = $0.addLayer(layer) }
            let scene = host.currentScene()
            let l = try scene.layer(newId)
            return text(String(format: "Added %@ layer '%@': %.2fs → %.2fs (file %.2fs).", l.role.rawValue, newId, l.start,
                               l.effectiveEnd(sceneDuration: scene.duration), duration))

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
            var ids: [String] = []
            try host.mutate("Add Captions") { ids = try $0.addCaptions(forVoice: id, style: style) }
            return text("Added \(ids.count) caption layers: \(ids.joined(separator: ", "))")

        case "set_keyframes":
            let id = try string(a, "id")
            guard let track = KeyTrack(name: try string(a, "property")) else {
                throw ToolError("`property` must be one of \(KeyTrack.allNames)")
            }
            let raw = a["keyframes"] ?? [Any]()
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
            let duration = number(a["duration"]) ?? 0.6
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
            var items = try StockSearch.search(query, kind: kind, page: page)
            if let limit = number(a["limit"]), limit > 0 { items = Array(items.prefix(Int(limit))) }
            if items.isEmpty { return text("No \(kind.rawValue) results for '\(query)'. Try a simpler or English query.") }
            var lines = ["\(items.count) \(kind.rawValue) results for '\(query)' (page \(page)). Import one with import_stock {\"ref\": …}:"]
            for (i, item) in items.enumerated() { lines.append("\(i + 1). \(item.summary)") }
            var content: [[String: Any]] = []
            if !kind.isAudio, a["preview"] as? Bool ?? true, let png = StockSearch.contactSheet(items) {
                lines.append("The image shows the results numbered in the same order.")
                content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
            }
            content.append(["type": "text", "text": lines.joined(separator: "\n")])
            return ["content": content]

        case "import_stock":
            let item = try StockSearch.item(ref: try string(a, "ref"))
            let asset = try StockSearch.importItem(item, name: a["name"] as? String, folder: a["folder"] as? String,
                                                   color: a["color"] as? String,
                                                   size: Int(number(a["size"]) ?? 512))
            var lines = ["Imported '\(asset.name)' (\(asset.summary))", "path: \(asset.path)",
                         "license: \(item.credit.license)"]
            if item.credit.requiresAttribution {
                lines.append("Credit required — include in the video or its description: \(item.credit.attribution)")
            }
            if item.kind == .music {
                lines.append("Next: add_audio {\"path\": \"\(asset.path)\", \"role\": \"music\", \"start\": 0, \"end\": <scene duration>, \"volume\": 0.6, \"fadeIn\": 0.5, \"fadeOut\": 1.5, \"duckTo\": 0.25}")
            } else if item.kind == .sound {
                lines.append("Next: add_audio {\"path\": \"\(asset.path)\", \"role\": \"sfx\", \"start\": <moment it should play>}")
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
            let camera = scene.activeCamera(at: t).map { ", camera: \($0.id)" } ?? ""
            return ["content": [
                ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                ["type": "text", "text": "t=\(t)s, visible layers: \(visible.joined(separator: ", "))\(camera)"],
            ]]

        case "export_video":
            let raw = try string(a, "path")
            let path = (raw as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw ToolError("`path` must be absolute") }
            let url = URL(fileURLWithPath: path)
            let scene = host.currentScene()
            let started = Date()
            try VideoExporter.export(scene, to: url)
            return text(String(format: "Exported %@ (%d frames) in %.1fs", url.path, scene.frameCount, Date().timeIntervalSince(started)))

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
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func warnings(_ problems: [String]) -> String {
        problems.isEmpty ? "" : "\nWarnings:\n" + problems.joined(separator: "\n")
    }

    private func text(_ s: String) -> [String: Any] {
        ["content": [["type": "text", "text": s]]]
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
