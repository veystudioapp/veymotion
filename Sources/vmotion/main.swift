import Foundation
import VeyMotionCore
import VeyMotionMCP

setvbuf(stdout, nil, _IOLBF, 0) // flush log lines promptly even when piped

let usage = """
vmotion — VeyMotion command line

EDIT A SCENE (talks to the running VeyMotion app, or edits a file with --scene)
  vmotion <command> ['<json-args>' | -] [--scene file.json] [--out frame.png]
                                                  (or set VEYMOTION_SCENE=file.json instead of --scene)
  vmotion tools                                   List commands and their arguments
  vmotion docs                                    Scene format reference
  vmotion --version                               Print the version

FILES
  vmotion sample <scene.json>                     Write the demo scene
  vmotion frame  <scene.json> <time> <out.png> [scale]
  vmotion render <scene.json> <out.mp4|out.mov> [--preset tiktok|shorts|reels|youtube|facebook|x|square] [--fit fit|fill]
  vmotion perf   <scene.json> [--scale s] [--frames n] [--layers]
                                                  Render time per frame (no file output); --layers times each top-level layer alone

AGENT
  vmotion chat [--model m] "prompt"               One Claude Code turn in the terminal (edits the app's scene)
  vmotion review <scene.json>... [--model m] [--brief "what was asked"] [--lint-only] [--json]
                                                  Design lint + a Claude Code art-director review of rendered frames
                                                  (scores 1–5); several files end with a table, to compare versions

SERVERS
  vmotion mcp    [scene.json]                     MCP over stdio, editing the file (without one: the running app)
  vmotion serve  <scene.json> [port]              MCP over HTTP (default port 19790)
  vmotion daemon <scene.json>                     Control socket for a file (headless app stand-in)

"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func loadScene(_ path: String) -> MotionScene {
    do {
        let url = URL(fileURLWithPath: path)
        var s = try SceneJSON.decode(MotionScene.self, from: Data(contentsOf: url))
        s.resolvePaths(relativeTo: url.deletingLastPathComponent())
        return s
    } catch {
        fail("Cannot read \(path): \(error.localizedDescription)")
    }
}

var framesDirectory: URL {
    if let p = ProcessInfo.processInfo.environment["VEYMOTION_FRAMES_DIR"], !p.isEmpty {
        return URL(fileURLWithPath: p, isDirectory: true)
    }
    // Inside the agent's working directory, where a sandboxed Claude Code Bash may write.
    return ClaudeCodeAgent.Config.defaultWorkingDirectory.appendingPathComponent("frames", isDirectory: true)
}

/// Runs one tool, either against the running app (control socket) or a scene file.
func runTool(_ tool: String, _ rest: [String]) -> Never {
    var scenePath: String?
    var outPath: String?
    var json: String?
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--scene":
            guard i + 1 < rest.count else { fail("--scene needs a path") }
            scenePath = rest[i + 1]; i += 2
        case "--out":
            guard i + 1 < rest.count else { fail("--out needs a path") }
            outPath = rest[i + 1]; i += 2
        default:
            json = rest[i]; i += 1
        }
    }
    if scenePath == nil, let env = ProcessInfo.processInfo.environment["VEYMOTION_SCENE"], !env.isEmpty {
        scenePath = env
    }
    if json == "-" {
        json = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
    }
    var arguments: [String: Any] = [:]
    if let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        do {
            guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                fail("Arguments must be a JSON object, e.g. '{\"id\": \"title\"}'", code: 2)
            }
            arguments = obj
        } catch {
            fail("Invalid JSON arguments: \(error.localizedDescription)", code: 2)
        }
    }

    let request: [String: Any] = [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": ["name": tool, "arguments": arguments],
    ]
    let response: [String: Any]
    if let scenePath {
        do {
            let host = try FileSceneHost(url: URL(fileURLWithPath: scenePath))
            response = MCPServer(host: host).handle(request) ?? [:]
        } catch { fail(error.localizedDescription) }
    } else {
        do {
            response = try ControlSocketClient.send(request)
        } catch {
            fail("VeyMotion app is not running (\(error.localizedDescription)). Open the app, or pass --scene <file.json>.", code: 3)
        }
    }

    if let err = response["error"] as? [String: Any] {
        print("Error: \(err["message"] as? String ?? "unknown")")
        exit(1)
    }
    let result = response["result"] as? [String: Any] ?? [:]
    for item in result["content"] as? [[String: Any]] ?? [] {
        switch item["type"] as? String {
        case "text":
            print(item["text"] as? String ?? "")
        case "image":
            guard let b64 = item["data"] as? String, let data = Data(base64Encoded: b64) else { continue }
            let url: URL
            if let outPath {
                url = URL(fileURLWithPath: outPath)
            } else {
                let label = (arguments["time"] as? NSNumber).map { String(format: "frame-%.2fs", $0.doubleValue) } ?? tool
                url = framesDirectory.appendingPathComponent("\(label)-\(UUID().uuidString.prefix(6)).png")
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
                print("Frame saved: \(url.path)\n(Open it with the Read tool to see it.)")
            } catch {
                print("Error: cannot save frame: \(error.localizedDescription)")
                exit(1)
            }
        default:
            break
        }
    }
    exit((result["isError"] as? Bool) == true ? 1 : 0)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

switch command {
case "help", "--help", "-h":
    print(usage)

case "version", "--version", "-v":
    print("vmotion \(AppVersion.current)")

case "tools":
    print(ToolCatalog.cliUsage)

case "docs":
    print(ToolCatalog.sceneReference)

case "sample":
    guard let out = args.first else { fail(usage) }
    do {
        try Data(MotionScene.sampleJSON.utf8).write(to: URL(fileURLWithPath: out))
        print("Wrote \(out)")
    } catch { fail(error.localizedDescription) }

case "frame":
    guard args.count >= 3, let t = Double(args[1]) else { fail(usage) }
    let scene = loadScene(args[0])
    let scale = args.count > 3 ? Double(args[3]) ?? 1 : 1
    guard let png = FrameRenderer().pngData(scene, at: t, scale: scale) else { fail("Render failed") }
    do { try png.write(to: URL(fileURLWithPath: args[2])) } catch { fail(error.localizedDescription) }
    print("Wrote \(args[2])")

case "perf":
    // vmotion perf <scene.json> [--scale s] [--frames n] [--layers] — how long frames take to draw, in-process.
    guard let path = args.first else { fail(usage) }
    var scale = 1.0, frames = 24, perLayer = false
    var j = 1
    while j < args.count {
        switch args[j] {
        case "--scale" where j + 1 < args.count: scale = Double(args[j + 1]) ?? 1; j += 2
        case "--frames" where j + 1 < args.count: frames = max(1, Int(args[j + 1]) ?? 24); j += 2
        case "--layers": perLayer = true; j += 1
        default: fail("unknown option \(args[j])")
        }
    }
    let scene = loadScene(path)
    let renderer = FrameRenderer()
    /// Median and mean milliseconds per frame over `frames` frames spread across the scene (after one warm-up frame).
    func measure(_ s: MotionScene) -> (median: Double, mean: Double) {
        _ = renderer.makeImage(s, at: 0, scale: scale)
        var ms: [Double] = []
        for i in 0..<frames {
            let t = s.duration * (Double(i) + 0.5) / Double(frames)
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = renderer.makeImage(s, at: t, scale: scale)
            ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        let sorted = ms.sorted()
        return (sorted[sorted.count / 2], ms.reduce(0, +) / Double(ms.count))
    }
    let w = Int(Double(scene.width) * scale), h = Int(Double(scene.height) * scale)
    let all = measure(scene)
    print(String(format: "%d frames at %d×%d: median %.1f ms, mean %.1f ms (%.1f fps)", frames, w, h, all.median, all.mean, 1000 / all.mean))
    if perLayer {
        var empty = scene
        empty.layers = []
        let base = measure(empty).median
        print(String(format: "  %6.1f ms  (empty frame)", base))
        for layer in scene.layers where layer.type.isVisual {
            var one = scene
            one.layers = scene.layers.filter { $0.id == layer.id || layer.matte?.source == $0.id }
            let m = measure(one).median
            print(String(format: "  %6.1f ms  %@ (%@)", m - base, layer.id, layer.type.rawValue))
        }
        print("  (each layer alone, minus the empty frame; they need not add up to the total)")
    }

case "render":
    guard args.count >= 2 else { fail(usage) }
    let scene = loadScene(args[0])
    let url = URL(fileURLWithPath: args[1])
    var options = ExportOptions()
    var j = 2
    while j < args.count {
        guard j + 1 < args.count else { fail("\(args[j]) needs a value") }
        switch args[j] {
        case "--preset":
            guard let p = PlatformPreset.named(args[j + 1]) else {
                fail("Unknown preset '\(args[j + 1])'. Presets: \(PlatformPreset.all.map(\.id).joined(separator: ", "))")
            }
            options.size = p.size
        case "--fit":
            guard let f = ExportFit(rawValue: args[j + 1]) else { fail("--fit is fit or fill") }
            options.fit = f
        default:
            fail(usage)
        }
        j += 2
    }
    let started = Date()
    var lastPct = -1
    do {
        try VideoExporter.export(scene, to: url, options: options) { p in
            let pct = Int(p * 100)
            if pct / 10 != lastPct / 10 { lastPct = pct; FileHandle.standardError.write(Data("\(pct)%\n".utf8)) }
        }
    } catch { fail(error.localizedDescription) }
    print(String(format: "Wrote %@ (%d frames, %.1fs)", url.path, scene.frameCount, Date().timeIntervalSince(started)))

case "mcp":
    guard let path = args.first else {
        MCPSocketBridge.run() // no scene file: serve the running app's scene
        exit(0)
    }
    do {
        let host = try FileSceneHost(url: URL(fileURLWithPath: path))
        let server = MCPServer(host: host)
        server.log = { FileHandle.standardError.write(Data(("[vmotion] " + $0 + "\n").utf8)) }
        MCPStdioTransport.run(server: server)
    } catch { fail(error.localizedDescription) }

case "serve":
    guard let path = args.first else { fail(usage) }
    let port = args.count > 1 ? UInt16(args[1]) ?? 19790 : 19790
    do {
        let host = try FileSceneHost(url: URL(fileURLWithPath: path))
        let server = MCPServer(host: host)
        server.log = { print("[vmotion] \($0)") }
        let http = MCPHTTPServer(server: server, port: port, token: ProcessInfo.processInfo.environment["VEYMOTION_TOKEN"])
        http.onStateChange = { print("[vmotion] \($0)") }
        try http.start()
        dispatchMain()
    } catch { fail(error.localizedDescription) }

case "daemon":
    guard let path = args.first else { fail(usage) }
    do {
        let host = try FileSceneHost(url: URL(fileURLWithPath: path))
        let server = MCPServer(host: host)
        server.log = { print("[vmotion] \($0)") }
        let sock = ControlSocketServer(server: server)
        try sock.start()
        print("[vmotion] Control socket at \(sock.path)")
        dispatchMain()
    } catch { fail(error.localizedDescription) }

case "chat":
    // vmotion chat [--model m] "prompt"   — one agent turn in the terminal, against the app or $VEYMOTION_SCENE
    var model: String?
    var words: [String] = []
    var j = 0
    while j < args.count {
        if args[j] == "--model", j + 1 < args.count { model = args[j + 1]; j += 2 } else { words.append(args[j]); j += 1 }
    }
    let prompt = words.joined(separator: " ")
    guard !prompt.isEmpty else { fail("usage: vmotion chat [--model m] \"prompt\"") }
    guard let claude = ClaudeCodeAgent.locateClaude() else { fail("Claude Code (`claude`) not found. Install it and run `claude` once to log in.") }
    let selfDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().path
    let workDir = ProcessInfo.processInfo.environment["VEYMOTION_AGENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? ClaudeCodeAgent.Config.defaultWorkingDirectory
    var env: [String: String] = [:]
    if ProcessInfo.processInfo.environment["VEYMOTION_FRAMES_DIR"] == nil {
        env["VEYMOTION_FRAMES_DIR"] = workDir.appendingPathComponent("frames").path
    }
    let agent = ClaudeCodeAgent(config: .init(claudePath: claude, vmotionDirectory: selfDir, workingDirectory: workDir,
                                              model: model, extraEnvironment: env))
    var lastWasDelta = false
    agent.onEvent = { ev in
        switch ev {
        case let .started(sid, model): print("· session \(sid.prefix(8)) · \(model)")
        case .thinking: break
        case let .toolInputProgress(name, bytes):
            if bytes > 0 && bytes % 4096 < 512 {
                FileHandle.standardError.write(Data("  … writing \(name) input \(bytes / 1024) KB\n".utf8))
            }
        case let .textDelta(_, t): print(t, terminator: ""); fflush(stdout); lastWasDelta = true
        case let .text(_, t): print(t)
        case let .toolUse(_, name, input):
            if lastWasDelta { print(""); lastWasDelta = false }
            let detail = (input["command"] as? String) ?? (input["file_path"] as? String) ?? ""
            print("▸ \(name): \(detail.prefix(200))")
        case let .toolResult(_, out, isError, image):
            let first = out.split(separator: "\n").first.map(String.init) ?? ""
            print("  \(isError ? "✗" : "✓") \(first.prefix(160))\(image != nil ? " [image]" : "")")
        case let .turnFinished(isError, _, cost, ms):
            if lastWasDelta { print("") }
            print(String(format: "· %@ · %.1fs · $%.4f", isError ? "error" : "done", Double(ms ?? 0) / 1000, cost ?? 0))
            agent.finish()
        case let .stderr(s): FileHandle.standardError.write(Data(s.utf8))
        case .resumeFailed: break
        case let .exited(code): exit(code)
        }
    }
    do { try agent.send(prompt) } catch { fail(error.localizedDescription) }
    dispatchMain()

case "review":
    // The lint and the critic the app runs after a turn, for scene files: a score sheet to compare prompt versions.
    var model: String?, brief: String?, lintOnly = false, asJSON = false
    var files: [String] = []
    var j = 0
    while j < args.count {
        switch args[j] {
        case "--model" where j + 1 < args.count: model = args[j + 1]; j += 2
        case "--brief" where j + 1 < args.count: brief = args[j + 1]; j += 2
        case "--lint-only": lintOnly = true; j += 1
        case "--json": asJSON = true; j += 1
        default: files.append(args[j]); j += 1
        }
    }
    guard !files.isEmpty else { fail(usage) }
    var claude: String?
    if !lintOnly {
        guard let found = ClaudeCodeAgent.locateClaude() else {
            fail("Claude Code (`claude`) not found. Install it and run `claude` once to log in, or pass --lint-only.")
        }
        claude = found
    }
    var results: [[String: Any]] = []
    var table: [String] = []
    var failed = false
    for file in files {
        let scene = loadScene(file)
        let issues = scene.designIssues(renderer: FrameRenderer())
        let real = issues.filter { $0.severity >= .warning }
        var entry: [String: Any] = ["file": file, "lint": issues.map { ["severity": $0.severity.rawValue, "code": $0.code, "message": $0.message, "layers": $0.layers] }]
        if !asJSON {
            print("== \(file)")
            print(MotionScene.designReport(issues))
        }
        var scores = "-"
        if let claude {
            do {
                let workDir = ProcessInfo.processInfo.environment["VEYMOTION_AGENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? ClaudeCodeAgent.Config.defaultWorkingDirectory
                let c = try DesignCritic.review(scene: scene, brief: brief, known: real, claudePath: claude, model: model,
                                                workingDirectory: workDir)
                entry["review"] = c.json
                scores = c.scoreLine
                if !asJSON { print("Review\n" + c.report()) }
            } catch {
                failed = true
                entry["reviewError"] = error.localizedDescription
                if !asJSON { print("Review failed: \(error.localizedDescription)") }
            }
        }
        results.append(entry)
        table.append("\(real.count) lint finding\(real.count == 1 ? "" : "s") · \(scores) · \(file)")
    }
    if asJSON {
        let data = (try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
        print(String(data: data, encoding: .utf8) ?? "[]")
    } else if files.count > 1 {
        print("\n" + table.joined(separator: "\n"))
    }
    exit(failed ? 1 : 0)

default:
    if let tool = ToolCatalog.toolName(for: command) {
        runTool(tool, args)
    }
    print(usage)
    fail("Unknown command '\(command)'. Run `vmotion tools` for the list.")
}
