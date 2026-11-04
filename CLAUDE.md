# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

VeyMotion is a native macOS (14+) motion-graphics editor in SwiftUI, built with Swift Package Manager (no Xcode project). It has a built-in MCP server and a `vmotion` CLI so AI agents can edit scenes. See README.md for the user-facing story and the scene JSON format.

## Commands

```bash
swift build                      # builds all targets, including the vmotion CLI
swift run VeyMotion              # run the app (run `swift build` first: the in-app chat needs vmotion next to the app binary)
bash scripts/bundle.sh           # release build -> dist/VeyMotion.app (ad-hoc signed) + dist/vmotion
```

There is no test target and no linter configured. To check Core/MCP changes without the GUI, use the CLI against a scene file:

```bash
.build/debug/vmotion sample $TMPDIR/s.json                    # write the demo scene
.build/debug/vmotion frame  $TMPDIR/s.json 2.5 $TMPDIR/f.png  # render one frame (then look at the PNG)
.build/debug/vmotion apply_preset '{"id":"title","preset":"popIn","start":0.5}' --scene $TMPDIR/s.json
.build/debug/vmotion render $TMPDIR/s.json $TMPDIR/out.mp4
.build/debug/vmotion tools                                    # command list generated from the tool schemas
```

Without `--scene` (or `VEYMOTION_SCENE`), tool commands go to the running app over the control socket at `~/Library/Application Support/VeyMotion/control.sock` and fail with exit code 3 if the app is not open.

## Architecture

Targets: `VeyMotionCore` (model, ops, rendering, export) ← `VeyMotionMCP` (tool layer, transports, Claude Code agent) ← `VeyMotionApp` (SwiftUI) and `vmotion` (CLI).

**One mutation path.** Every scene change is a `mutating` extension on `MotionScene` in `SceneOps.swift` / `TimelineOps.swift`. The UI calls them via `SceneStore.apply(label) { ... }`, which snapshots the whole scene onto the undo stack (max 300); drags use `beginInteractive/updateInteractive/endInteractive` to make one undo step per gesture. Put new mutation logic in Core, not in views or in `MCPServer`.

**SceneHost abstraction.** `MCPServer` (in `VeyMotionMCP/MCPServer.swift`) is transport-independent JSON-RPC and only talks to a `SceneHost`:
- `SceneStore` (app): `mutate` hops to the main thread synchronously and goes through `apply` with an `"Agent: …"` label, so agent edits are undoable.
- `FileSceneHost` (CLI): loads a JSON file and writes it back after every mutation.

The same `MCPServer` is served three ways: HTTP on `127.0.0.1:19790/mcp` (`Transports.swift`, optional `VEYMOTION_TOKEN` bearer auth), stdio (`vmotion mcp`), and the unix control socket (`ControlSocket.swift`, newline-delimited JSON-RPC). The CLI's `vmotion <tool> '<json>'` just wraps a `tools/call` request and sends it to either the socket or a `FileSceneHost`.

**Tool schemas are the single source of truth.** `Docs.toolsJSON` (`VeyMotionMCP/Docs.swift`) drives MCP `tools/list`, the CLI command names and `vmotion tools` output (`ToolCatalog`), and the embedded agent's system prompt (`AgentPrompt`). `Docs.instructions` is the scene-format reference sent to agents (MCP `initialize`, `vmotion docs`, agent prompt). To add a tool: add its schema to `toolsJSON` and a case in `MCPServer.callTool`. The CLI picks it up automatically (`-` and `_` are interchangeable in command names). Tool failures are returned as `isError` content, not as JSON-RPC errors.

**Embedded chat.** `ChatStore` runs `ClaudeCodeAgent`, a long-lived `claude -p` process using stream-json in and out. It is restricted to `--tools Bash,Read --allowedTools "Bash(vmotion:*)" ...` with `--strict-mcp-config --setting-sources ""`, and passes `--settings` with `sandbox.network.allowUnixSockets` so a sandboxed Bash can reach the control socket. Each user message gets a `[VeyMotion context: …]` line prefixed. `render_frame` results are saved as PNGs under the agent working dir (`.../VeyMotion/agent/frames`, or `VEYMOTION_FRAMES_DIR`) so the agent can `Read` them. `ChatStore` looks for `vmotion` next to `Bundle.main.executableURL`.

**UI layout.** `ContentView` is an `HSplitView` (sidebar: Layers/Assets · canvas + `TransportBar` · Inspector/Claude) over the timeline and status bar; panel visibility and tabs persist in `@AppStorage`. Shared inspector building blocks (`InspectorSection`, `NumberField`, `AnimField`, `AnimSlider`, `KeyframeButton`, `PanelTabBar`) live in `EditorChrome.swift` — reuse them for new properties.

**One renderer.** `FrameRenderer` (CoreGraphics + CoreText) is used for the canvas preview, `render_frame`, and `VideoExporter` (AVAssetWriter; `.mp4` = H.264, `.mov` = ProRes 4444 with alpha), so preview matches export.

## Model details that span files

- `Animated<V>` (`AnimValue` = numbers, `ColorValue` = `RGBA`) is either a constant or `{"keyframes":[...]}`. Keyframe `t` is absolute scene seconds, and `easing` applies to the segment *arriving* at that keyframe. A track is addressed as `KeyTrack` (`.number(AnimProperty)` / `.color(ColorProperty)`); timeline ops (`moveKeyframes`, `setEasing`, `deleteKeyframes`, `shiftLayers`) work on both.
- Render code must read values through `MotionLayer.value(_:at:)` / `color(_:at:)` (they apply `loop` and `wiggle`) and position through `MotionScene.screenTransform(of:at:)` (parents, anchor, skew, motion path, then the camera), not `layer.x.value(at:)`. `worldTransform` is the pre-camera scene-plane transform (used by `setParent`).
- Camera (2.5D, `Motion.swift`): `type: "camera"` layers are not drawn; the topmost one visible at t is active (`activeCamera`), else `CameraView.default`. Layers have a depth `z` (adds up through parents); the projection of a camera-facing plane is uniform scale + translation, so everything stays a `CGAffineTransform`. The renderer sorts by depth (farthest first, list order breaks ties) and adds `CameraView.depthBlur` to the layer blur. With no camera and all z = 0 output is unchanged. True 3D rotation (rotationX/Y) is out of scope: CoreGraphics has no perspective warp.
- `MotionLayer` has custom Codable: decoding fills in defaults for missing fields, and encoding writes only the fields relevant to the layer's `type` (to keep JSON compact for agents). A new layer field needs `CodingKeys`, `init(from:)`, and `encode(to:)` updated, plus `Docs.instructions`.
- To add an animatable number: add an `AnimProperty` case (+ `defaultValue`, `title`); if it isn't a stored field, add it to `AnimProperty.extras` and `CodingKeys` (it then lives in `MotionLayer.extra` and is written only when non-default). Then update `applicableProperties`, the `set_keyframes` enum in `Docs.toolsJSON`, `Docs.instructions`, and `FrameRenderer`.
- Blur renders the layer into a frame-sized bitmap and blurs it with vImage (CPU). CoreImage returned nothing in sandboxed processes.
- `swift build` fails inside the Claude Code sandbox (SwiftPM writes through the system temp folder). To check code there, run `swiftc` per target into `$TMPDIR`: Core as a dylib + module, then MCP, then the CLI, and the app with `-typecheck`.
- `update_layer` / `update_scene` apply an RFC 7386 merge patch through JSON round-tripping (`JSONMerge`). Exception: any object containing `keyframes` replaces the old one wholesale. `null` resets a field to its default.
- Assets: `AssetStore` (`Assets.swift`) is one shared folder with optional subfolders; an asset's `name` is its path relative to the library (`icons/logo.svg`, also the `.credits.json` key), while layers still store absolute `path`s. Folder renames/moves repoint layers via `replaceFolder`. File ops (import/write/rename/trash) are not on the undo stack. Renaming repoints layers via `replacePath`, which is undoable. SVG goes through `AssetStore.loadImage` (NSImage fallback), and the renderer's image cache is keyed by modification date. `AssetLibrary` (app) watches the whole tree with FSEvents so agent changes appear live. Free asset sources (Openverse images + audio from Jamendo/Freesound, Iconify — no keys) are in `StockSources.swift`; all network goes through `HTTP` (one ephemeral session, in-memory downloads, because sandboxed processes cannot use the system temp folder), and credits live in the library's `.credits.json` (moved on rename, dropped on trash).
- Projects (`Project.swift`, `ProjectStore`): a folder with `scene.json` + `assets/`. Opening one calls `AssetStore.setActiveLibrary(<project>/assets)`, so `AssetStore.directory` (and every asset tool, the Assets panel, `AssetLibrary.shared`) switches to the project; `sharedDirectory` is the old global library (`AssetLibrary.global`, read-only "Shared" tab). In a project library, a nil `folder` means "file by type" (`AssetStore.autoFolder` / `routed`); pass `""` for the top level. Scene files store project-internal paths relative to the project (`relativizingPaths`) and every scene load resolves relative paths against the file's folder (`resolvePaths`). `FileSceneHost` detects project scene files and does the same. `SceneStore` saves a dirty project before switching away or quitting.
- Audio decoding: `AVAudioFile.framePosition =` raises an Objective-C exception (uncatchable crash) on files it cannot decode, so `AudioMixer.readSegment` probes with a 1-frame `read` first; `AudioFileInfo.isDecodable` does the same check for imports. Note that sandboxed test runs cannot decode MP3/AAC at all (codecs unavailable) — test the mixer with WAV there.
- Layer ids are unique: `addLayer` / `duplicateLayer` auto-suffix them (`title-2`), and renaming to a taken id throws.
