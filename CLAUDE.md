# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

VeyMotion is a native macOS (14+) motion-graphics editor in SwiftUI, built with Swift Package Manager (no Xcode project). It has a built-in MCP server and a `vmotion` CLI so AI agents can edit scenes. See README.md for the user-facing story and the scene JSON format.

## Commands

```bash
swift build                      # builds all targets, including the vmotion CLI
swift run VeyMotion              # run the app (run `swift build` first: the in-app chat needs vmotion next to the app binary)
bash scripts/bundle.sh           # release build -> "dist/Vey Motion.app" (ad-hoc signed) + dist/vmotion
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

**Embedded chat.** `ChatStore` runs `ClaudeCodeAgent`, a long-lived `claude -p` process using stream-json in and out. It is restricted to `--tools Bash,Read --allowedTools "Bash(vmotion:*)" ...` with `--strict-mcp-config --setting-sources ""`, and passes `--settings` with `sandbox.network.allowUnixSockets` so a sandboxed Bash can reach the control socket. Each user message gets a `[VeyMotion context: …]` line prefixed. `render_frame` results are saved as PNGs under the agent working dir (`.../VeyMotion/agent/frames`, or `VEYMOTION_FRAMES_DIR`) so the agent can `Read` them. `ChatStore` looks for `vmotion` next to `Bundle.main.executableURL`. Each project has its own conversation (`ChatStore.Session`; `ChatStore.current` is the shown one and the views read it through forwarding properties). Each agent gets its own control socket (`agent-<id>.sock`, passed as `VEYMOTION_SOCKET`) served by an `AgentSceneHost` bound to the conversation's project: while that project is open, calls go to `SceneStore`; after a switch they go to the project's `scene.json` (decided and run on the main thread, where documents switch), and `SceneHost.assetLibrary` makes asset tools use that project's library for the call (`AssetStore.withLibrary`, thread-local). So on `SceneStore.onProjectChange` a project's running turn keeps going in the background (its agent is dropped when the turn ends), while an idle agent, or a loose scene's, is stopped. The transcript is parked and the next one loaded from `<project>/.chat.json` (text-only transcript + session id, resumed with `--resume`). A chat file read from a copy of another existing project (duplicate, Save As) resumes with `--fork-session`. Loose scenes share one in-memory chat.
`ChatStore.provider` can instead be Codex (`CodexAgent.swift`; both agents conform to `ChatAgent` and emit the same
`AgentEvent`s): one `codex exec --json` process per message (`resume <thread id>` / `fork`), the user's
`config.toml` loaded (custom providers/proxies) but overridden by `-c`: read-only shell sandbox, `approval_policy=never`, `AgentPrompt.codexPrompt` as `developer_instructions`, and an MCP
server `veymotion` = `vmotion mcp` with no scene (`MCPSocketBridge`, stdio → control socket), so tool calls show up
as `mcp__veymotion__<tool>`. Models come from `codex debug models`. Model/effort are stored per provider, and each
conversation keeps one session per provider (`sessionId` / `codexSessionId` in `.chat.json`).
Setup (`AgentSetup.swift`): `ChatStore.detect` locates each CLI and asks `claude auth status --json` /
`codex login status` (a custom `model_provider` in config.toml counts as logged in); missing or logged out blocks
sending and shows `AgentSetupCard` (install/log in through a Terminal `.command` file, API key, Check Again —
also re-run when the app becomes active). `AgentSetup.classify` turns refused logins (→ `.authFailed`) and
credit/usage-limit errors into readable notices. A Claude API key is kept by `AnthropicKeyStore` (Keychain) and
passed as `ANTHROPIC_API_KEY` through `AgentCLI.extraEnvironment`; Codex keys go to `codex login --with-api-key`.
Frame annotation (`Annotations.swift`, ⇧⌘A or the pencil in the transport bar): pauses, draws marks in scene units
over the canvas (UI-only, never in the scene), and "Add to chat" renders the frame + marks to a JPEG attachment whose
`note` tells the agent what it is. While active, the menu's Undo/Redo/Delete act on the marks and Space does not play.

**UI layout.** `ContentView` is an `HSplitView` (sidebar: Layers/Assets · canvas + `TransportBar` · Inspector/Claude) over the timeline (the `StatusBar` view is not shown); panel visibility and tabs persist in `@AppStorage`. Shared inspector building blocks (`InspectorSection`, `NumberField`, `AnimField`, `AnimSlider`, `KeyframeButton`, `PanelTabBar`) live in `EditorChrome.swift` — reuse them for new properties.
The timeline's Graph mode (`GraphEditor.swift`) plots the selected top-level layer's keyframed numbers, each fitted to
its own value range; keys drag in time and value, and each segment's two handles are its easing as `cubicBezier`
(`Easing.bezierControls` gives named curves their Bezier fit; `MotionScene.setKeyHandles` edits them, also behind
Easy Ease F9 / ⇧F9 / ⌘⇧F9).

**One renderer.** `FrameRenderer` (CoreGraphics + CoreText) is used for the canvas preview, `render_frame`, and `VideoExporter` (AVAssetWriter; `.mp4` = H.264, `.mov` = ProRes 4444 with alpha), so preview matches export. The canvas renders on a background queue (`PreviewRenderer` in `ContentView.swift`, latest request wins) and at most 1.5 px/pt while playing. `FrameCache` (`FrameCache.swift`) is the RAM preview: frames at that playback size keyed by `sceneRevision` + pixel width + a generation (bumped on asset changes and `didAnalyze`), filled by the canvas's own renders and, after 0.5 s idle, by background workers (one `FrameRenderer` each, from the playhead; paused while exporting); budget ¼ of RAM ≤ 4 GB, purged on memory pressure, green strip on the ruler and mini scrubber. Playback advances `store.time` in whole frames; inspector and timeline values read `store.panelTime` (held while playing) so they don't re-render every frame — only the canvas, transport and playhead follow `store.time`.

## Model details that span files

- `Animated<V>` (`AnimValue` = numbers, `ColorValue` = `RGBA`) is either a constant or `{"keyframes":[...]}`. Keyframe `t` is absolute scene seconds, and `easing` applies to the segment *arriving* at that keyframe. A track is addressed as `KeyTrack` (`.number(AnimProperty)` / `.color(ColorProperty)`); timeline ops (`moveKeyframes`, `setEasing`, `deleteKeyframes`, `shiftLayers`) work on both.
- Render code must read values through `MotionLayer.value(_:at:)` / `color(_:at:)` (they apply `loop` and `wiggle`) and position through `MotionScene.worldTransform(of:at:)` (parents, anchor, skew, motion path), not `layer.x.value(at:)`. Layers draw in list order (first is bottom-most), except runs of 3D layers (see 3D below). On a 2D layer, `rotationX/Y` and `cornerPin` are a per-layer warp with its own perspective (see `Mesh.swift` below); the scene camera is 2D for 2D layers.
- `MotionLayer` has custom Codable: decoding fills in defaults for missing fields, and encoding writes only the fields relevant to the layer's `type` (to keep JSON compact for agents). A new layer field needs `CodingKeys`, `init(from:)`, and `encode(to:)` updated, plus `Docs.instructions`.
- To add an animatable number: add an `AnimProperty` case (+ `defaultValue`, `title`); if it isn't a stored field, add it to `AnimProperty.extras` and `CodingKeys` (it then lives in `MotionLayer.extra` and is written only when non-default). Then update `applicableProperties`, the `set_keyframes` enum in `Docs.toolsJSON`, `Docs.instructions`, and `FrameRenderer`.
- Blur renders the layer into a bitmap covering only what it can reach once blurred (`contentBounds` + blur reach; the whole frame for text with animators) and blurs it with vImage (CPU). CoreImage returned nothing in sandboxed processes. Transparency layers (opacity < 1 or shadow) are bounded the same way: an unbounded one costs a full-frame pass per layer.
- `swift build` fails inside the Claude Code sandbox (SwiftPM writes through the system temp folder). To check code there, run `swiftc` per target into `$TMPDIR`: Core as a dylib + module, then MCP, then the CLI, and the app with `-typecheck`.
- `update_layer` / `update_scene` apply an RFC 7386 merge patch through JSON round-tripping (`JSONMerge`). Exception: any object containing `keyframes` replaces the old one wholesale. `null` resets a field to its default.
- Assets: `AssetStore` (`Assets.swift`) is one shared folder with optional subfolders; an asset's `name` is its path relative to the library (`icons/logo.svg`, also the `.credits.json` key), while layers still store absolute `path`s. Folder renames/moves repoint layers via `replaceFolder`. File ops (import/write/rename/trash) are not on the undo stack. Renaming repoints layers via `replacePath`, which is undoable. SVG goes through `AssetStore.loadImage` (NSImage fallback), and the renderer's image cache is keyed by modification date. `AssetLibrary` (app) watches the whole tree with FSEvents so agent changes appear live. Free asset sources (Openverse images + audio from Jamendo/Freesound, Iconify — no keys) are in `StockSources.swift`;
  stock video (Pexels + Pixabay, `StockVideo.swift`) needs keys, so it goes through the Nitro server
  (`/api/stock/videos`, `NITRO_PEXELS_API_KEY` / `NITRO_PIXABAY_API_KEY`) and imports the largest MP4 ≤ 1920 px; all network goes through `HTTP` (one ephemeral session, in-memory downloads, because sandboxed processes cannot use the system temp folder), and credits live in the library's `.credits.json` (moved on rename, dropped on trash).
- Projects (`Project.swift`, `ProjectStore`): a folder with `scene.json` + `assets/`. Opening one calls `AssetStore.setActiveLibrary(<project>/assets)`, so `AssetStore.directory` (and every asset tool, the Assets panel, `AssetLibrary.shared`) switches to the project; `sharedDirectory` is the old global library (`AssetLibrary.global`, read-only "Shared" tab). In a project library, a nil `folder` means "file by type" (`AssetStore.autoFolder` / `routed`); pass `""` for the top level. Scene files store project-internal paths relative to the project (`relativizingPaths`) and every scene load resolves relative paths against the file's folder (`resolvePaths`). `FileSceneHost` detects project scene files and does the same. `SceneStore` saves a dirty project before switching away or quitting. Every document switch goes through `SceneStore.replaceDocument` (pauses playback, ends drags, cancels autosave, clears undo history unless both are loose scenes, resets selection/playhead) and bumps `documentRevision`, which views use to drop per-document state (timeline zoom/selection, the canvas renderer's image/video caches).
- Audio decoding: `AVAudioFile.framePosition =` raises an Objective-C exception (uncatchable crash) on files it cannot decode, so `AudioMixer.readSegment` probes with a 1-frame `read` first; `AudioFileInfo.isDecodable` does the same check for imports. Note that sandboxed test runs cannot decode MP3/AAC at all (codecs unavailable) — test the mixer with WAV there.
- Video layers (`Video.swift`): `path` is a movie or a folder of numbered images (image sequence, natural name order,
  `fps` on the layer). `MotionLayer.videoTime(at:)` maps scene time to source time (trimIn, speed, playback);
  `mediaLength` makes `once` videos end with the clip like audio, and `setTiming` trims both the same way.
  `FrameRenderer` keeps one decoder per path: `MovieFrames` (AVAssetReader, reads forward and restarts on a seek)
  or `SequenceFrames`. `refreshMediaInfo` fills `sourceDuration` (and a sequence's fps). Movie decoding fails in
  sandboxed processes (`-12911`), so `vmotion frame` there draws the placeholder: test movies in the app, or test
  with image sequences.
- Music sync (`AudioAnalysis.swift`): one FFT pass gives band envelopes, an onset curve (flux over log-spaced bands, so
  kicks are not drowned by hi-hats), tempo (autocorrelation) and beats (dynamic programming). `AudioAnalysisCache`
  caches per path (failures too) and is shared by `analyze_audio`, the timeline (`BeatCache` warms it) and the
  renderer. `audioReact` is evaluated inside `MotionLayer.value`, which has no scene: `MotionScene.layers`/`duration`
  `didSet` call `resolveAudioLinks`, which stores each reaction's source file and timing in `AudioReact.link`
  (not saved). Renaming an audio layer repoints `source` in `updateLayer`. The canvas renders inside
  `AudioAnalysisCache.withoutWaiting` and the app's main thread never waits (`waitsOnMainThread = false`): reactions
  read 0 until the file is analyzed in the background, then `didAnalyze` triggers a redraw. Export and the CLI wait.
- Video sound and transcription (`Transcribe.swift`): `MediaAudio.read` decodes any file's sound (AVAudioFile first,
  AVAssetReader for movies; the latter decodes nothing in sandboxed processes, so test the mixer with WAV there).
  `soundLayers` (audio layers + video layers with an audio track at speed 1) is what `AudioMixer` plays; `audioLayers`
  stays audio-only (audioReact, ducking). `Transcriber` uses SFSpeechRecognizer on 16 kHz mono, cut into < 50 s pieces
  at quiet points (server limit), and fills `words` (with durations `d`) + `transcript` on audio/video layers, so
  `addCaptions(for:)` works on them; `setCaptionTexts` swaps caption text (translations). Speech recognition needs
  `NSSpeechRecognitionUsageDescription` (only the bundled app has it); without it `Transcriber` throws instead of
  letting macOS kill the process, so the debug build and `vmotion --scene` cannot transcribe.
- Text-to-speech has two engines behind `generate_voice` / `list_voices` (`engine`) and the Voice-over sheet:
  `VoiceSynth` (macOS, exact word timings) and `VieNeu` (`VieNeu.swift`), which calls the Nitro server in
  `server/` (`/api/tts/*`; it holds the VieNeu key) at `BASE_API_URL` (env, else a `.env` in the working dir /
  next to the binary / Application Support). VieNeu gives no word timings, so `VoiceSynth.estimateTimings` fills them.
  Short text uses `/api/tts/speech` (WAV); text over 1500 characters goes through `/api/tts/jobs` and polling.
- Social video (`Platforms.swift`, `Publish.swift`): `PlatformPreset` sizes feed `ExportOptions.size`; when the
  aspect differs, `VideoExporter` renders the scene into its own bitmap and places it per `ExportFit` (bars or crop).
  Publishing: OAuth is brokered by `server/server/api/social/*` (secrets stay there; the app opens `/connect` with a
  random state + sha256 challenge and polls `/session` with the secret), tokens live in the keychain
  (`SocialKeychain`, one item per account keyed `platform:userId`; the active one per platform is in UserDefaults), and `SocialPublisher` uploads straight to YouTube (resumable), TikTok (Content Posting API),
  Facebook Pages (resumable upload API) and X (media upload v2). Publishing is UI-only on purpose: no MCP tool posts.
  The sheet goes Edit → Preview (`PublishStore.prepare` renders the scene once, reused while unchanged) → Publish.
  Thumbnails (`PublishThumbnail`, JPEG ≤ 2 MB) are set after the upload and never fail the post; TikTok gets
  `video_cover_timestamp_ms` instead. "Write with Claude" (`PublishCopy.swift`) runs `ClaudeCodeAgent.structured`
  (`claude -p --tools "" --json-schema`).
  Logos are svgl.app SVGs embedded as strings in `SocialLogos.swift` (the app has no resource bundle).
  Sandboxed runs cannot encode video at all, and the Nitro server cannot read `server/.env` or listen there.
- Particles (`Particles.swift`): a `particles` layer is an emitter (width/height = its area) with a `ParticleSystem`
  (preset + overrides; only fields that differ from the preset are encoded). Nothing is carried between frames:
  births sit on a fixed 1/240 s grid with per-tick random counts, each particle's random numbers come from its key,
  and its state at age a is a closed form, or a fixed 1/48 s walk from birth when it has turbulence (curl of 3D value
  noise) or a floor. So any frame renders alone and preview matches export. World-space particles are drawn without
  the layer transform. Emitting `from` a text uses the glyph outlines from `FrameRenderer.glyphOutline`. A sprite
  image is the layer's `path`. `emission`/`particleSpeed`/`particleSize` are multipliers read at each birth.
- Layer pipeline in `FrameRenderer`: `renderLayer` (track matte clip + repeater copies, each copy at
  `t - i·delay`) → `drawCopy` (motion blur: averages `motionBlurSamples` sub-frame renders in an offscreen bitmap)
  → `drawLayer` (transform, shadow, opacity, blur, then glow). Offscreen work uses `offscreen(area:)`, a window onto the
  full frame in device pixels, so nested effects compose. A layer used as another's `matte` is not drawn on its own;
  the matte is rendered to a gray mask (alpha or luma) and clipped in device space. Shapes live in `Shapes.swift`:
  `PathShape` is an `Interpolatable` (so `d` uses `Animated` keyframes/loop like any track) that stores every
  segment as a cubic; morphing subdivides the shorter path and aligns closed loops (start point + direction) before
  lerping. Trim paths stroke each subpath with a dash pattern computed from its flattened length.
- Fonts (`Fonts.swift`, `GoogleFonts.swift`): `fontName` is resolved by `FontLibrary.resolve` (family, PostScript or
  full name + `fontWeight` such as "bold", "light italic" or "600"; cached, misses recheck the libraries at most every
  2 s). Font files (.ttf/.otf/.ttc, asset kind `font`, `fonts/` in projects) in the active and shared libraries are
  registered with CoreText for the process, so preview, CLI and export match. Static font files name weights other
  than regular/bold as families of their own ("Be Vietnam Pro Black"); `faces(of:)` folds them into the base family
  and `listedFamilies` hides them. Google Fonts needs no key: the family list is fonts.google.com/metadata/fonts
  (cached a week under Application Support/VeyMotion/cache), files come from the css2 API (static TTFs for non-browser
  user agents), and search previews use `text=` subset fonts. Layer tools report fonts that are missing or lack
  letters of the text (`fontNotes` in `MCPServer`).
- Layer effects in the AE sense are plain `AnimProperty` extras (so keyframes, wiggle, audioReact and the timeline
  work on them), with their non-animated settings in fields (`tintColor`, `wipeStyle`, `keyColor`, `posterizeTime`).
  `Effects.swift`: color correction folds into one `ColorMatrix` (vImage, premultiplied: offsets go in the alpha
  column); `WipeStyle.visibleRegion` is an even-odd path in layer space that `drawLayer` clips to (feathered = a
  blurred gray mask). `PixelEffects.swift`: keying, distort (one inverse mapping, bilinear), posterize/pixelate,
  directional/zoom blur (log-step doubling passes), RGB split/glitch/grain/scanlines/vignette, run in
  `blurredLayer`'s bitmap before and after the gaussian; their reach widens that bitmap. Any active effect sends
  the layer through that bitmap path, so keep new ones off by default (0). Random looks are seeded by layer id and
  frame number, never carried between frames.
- `generator` layers (`Generators.swift`): one type, `generator.kind` = spectrum | waveform | noise | lightning |
  grid. Shapes come back as one filled `CGPath` (lines are stroked outlines) so fill/gradient apply; noise is an
  image at ~1/3 device resolution. Audio kinds get their source through `MotionScene.resolveAudioLinks` (like
  `audioReact`) and read `AudioAnalysis.spectrum` (40 log bands, each normalized on its own).
- Camera, groups and links (`Camera.swift`): `MotionScene.camera` is applied last in `worldTransform`
  (`sceneTransform` = without it; world-space particles live there). `parentTransform` includes the camera, so
  repeater copies and `setParent` stay right. A `group` layer's `children` render through `drawGroup` as a sub-scene
  (`subscene(of:)`: the group's box, no camera); ids are unique scene-wide, and `findLayer`/`withLayer`/`allLayers`
  reach children, so keyframe/preset/update tools work on them (removing/reordering is top-level only).
  `links` copy their source track into `PropertyLink.track` during `resolveLinks` (one hop, like `AudioReact.link`).
- Text extras: `FrameRenderer.displayText` swaps "{n}" for `counter` and applies `scramble` before layout; text
  outlines are stroked at twice the width *behind* the fill (stroking on top shows the inner contours of SF/variable
  glyphs), hollow text cuts the fill out; every context the renderer draws in turns off CoreText's subpixel
  quantization (`unquantizeText`), else slowly moving/zooming 2D text steps whole pixels and its letters wobble; `textPath` lays glyphs along a `MotionPath` (`drawTextOnPath`); animator
  blur goes through a small per-glyph bitmap.
- `PathOps.swift`: offset/zigzag/wiggle/pucker work on flattened polylines and give back a `PathShape` (trim and
  gradients still apply); tapered strokes are filled polygons. Light effects: shine is a gradient drawn `sourceAtop` in
  the processed bitmap; rays/outline/inner glow are `PixelBuffer` passes. Generators `chart` and `flare` draw directly
  (`drawChart`, `drawFlare`).
- `Tracking.swift`: Vision `VNTrackObjectRequest` (track_motion) and attention saliency (auto_reframe) read frames
  through `VideoFrames`. Saliency needs the neural engine, which sandboxed processes cannot use ("check process
  entitlements"): test it in the app. Object tracking works in the sandbox on image sequences. `timeRemap` overrides
  `videoTime` (and silences the clip's sound).
- Mesh warps (`Mesh.swift`): when a layer has `rotationX/Y`, `cornerPin` or moving `pins`
  (`rotationXYOrPinned` is the cheap pre-check), `drawContent` draws it flat into a bitmap at 2× device resolution
  (+2 device px transparent margin). Without moving pins the warp (corner pin homography → 3D rotation + projection)
  is one homography (`MeshWarp.projectiveMap`), and `drawProjective` maps every device pixel back through it
  (2×2 bilinear samples): no seams. Pins (MLS) go through a 20×20 grid of triangles, clipped *without*
  antialiasing so each pixel is drawn once (antialiased clips leave hairline seams; grown to overlap, they draw the
  seams twice and notch every glyph edge). `contentBounds` returns
  the warped bounds; `wipeBox`/`meshBox` must use `flatContentBounds` (calling `contentBounds` from them recurses).
- 3D (`Space3D.swift`, `Model3D.swift`, `Raster3D.swift`, the `// MARK: - 3D` extension at the end of `Renderer.swift`):
  `threeD` layers, `model` layers and every child of a 3D group with 3D children (`keepsChildren3D` → `drawGroup3D`,
  which sets `space3D` so children get the group's matrix as a prefix) live in one 3D space: x/y scene px, z away from
  the viewer. `localMatrix` (AE order: scale, X, Y, Z rotation around the anchor) × parents → `View3D` (camera
  orbitX/Y, distance, lens, z; defaults show z 0 as drawn) → `LayerProjection`, whose plane homography is NOT
  normalized (w = camera depth, so pixels behind the camera are rejected). The renderer gives a 3D layer an affine
  stand-in transform (`place3D`: projected origin + uniform scale) so the 2D pipeline (blur, shadow, glow, effects,
  bounds) runs unchanged, and `drawContent` projects it through `MeshWarp(projective:)` / `drawProjective`. Runs of
  consecutive 3D layers are sorted far to near (`drawOrder`) and share a frame `DepthBuffer` (`Mesh.swift`) while
  drawn straight into the frame (not inside offscreen bitmaps or flat groups); a 2D layer resets it. Wipes of 3D
  layers are cut on their plane in `drawWarped`. Models: `MeshBuilder` primitives, extrusion (`CGPath.normalized`,
  then `Earcut` with holes; a bevel insets each contour with `offsetContour`, which collapses edges that turn around
  so the outline never crosses itself, and is capped per solid part by its measured stroke thickness), lathe (`d`
  turned around the layer's vertical center line, x = radius) and files (OBJ/MTL, STL and glTF/GLB parsed here; usdz/usd/ply via ModelIO, which loads nothing in
  sandboxed processes), cached in `meshCache`. `MeshBuilder.load` returns a `ModelFile` (fit from the rest pose, cached in
  `modelFileCache`); animated glTF (`GLTF.swift`) keeps vertices in node/skin space in a `GLTFRig` (TRS channels with
  step/linear/cubic, ≤ 4 joints per vertex, no morph targets) and `posed` re-skins on the CPU per frame (`poseCache`,
  last pose per layer); the clip and its time come from `model.animation*` via `MotionLayer.modelClip(at:in:)`; `Raster3D` is a CPU z-buffer rasterizer (doubles for edge functions,
  `modelSupersampling`² samples, Blinn-Phong + sky reflection for metals, `MotionScene.lights` or `Light.defaults`).
- Grading (`Grading.swift`) runs in `PixelEffects.applyBeforeBlur` after the color matrix: one 256-entry tone table
  (levels + Fritsch–Carlson curve), gradient map, then a trilinear .cube LUT (`CubeLUT.load`, cached by mtime).
  Camera `focus`/`aperture` add `focusBlur` to a layer's blur (and to `motionBounds` padding).
- `text_to_path` / `combine_paths` (`PathOps.swift`) bake outlines with `FrameRenderer.glyphPaths` and macOS 14
  `CGPath` boolean ops; `trimSequential` trims a path's pieces end to end. `Beats.swift` (`sync_to_beats`) and
  `LayerTreeOps.swift` reaches into groups (`removeLayerAnywhere`, `addLayer(_:into:)`, `moveLayerAnywhere`,
  `duplicateLayer(_:count:dx:dy:dt:ids:)`), shifts a stretch of the timeline (`shiftTime(from:by:)`: whole layers
  after `from`, later keyframes of spanning ones, the camera; `Animated.shifted(after:by:)`) and makes contact sheets
  (`FrameRenderer.contactSheetPNG`, `render_frames`). `SVGImport.swift` (`import_vector`) parses SVG with XMLParser
  into path layers (one per shape, transforms baked by `PathShape.applying`, inline styles, gradients by `url(#id)`,
  nested `<g>` → groups) scaled to a box and centered on x/y; text/image/use/clip/CSS are skipped and reported.
  `Rig.swift`: `MotionScene.bones` (a `Bone` chain: root x/y, length, relative `angle`, limits; `boneTransform` maps
  bone space to scene px and `ancestorsTransform` uses it for layers with `bone` set, instead of layer parents),
  `bind(_:toBone:at:)` (keeps the place, like `setParent`), `poseBones` / `solveIK` (CCD, keyframes via `keyed`:
  the previous pose is held `hold` s before a new key on a constant track); `Drawing` / `DrawingFrame` /
  `DrawingStroke` for `drawing` layers (frames of path strokes with holds at `drawing.fps`, `frameIndex(at:)`),
  drawn by `drawDrawing` with a path cache; bounds cover every frame. Groups with `localTime` give their children a
  clock that starts at the group's start (`drawGroup`/`drawGroup3D` shift `t`; `shiftTree`/`shiftLate` leave their
  children alone; `DesignCheck` offsets them). Effects added as extras: `longShadow`/`longShadowAngle`
  (+ `longShadowColor`, `drawLongShadow`: alpha swept by `PixelBuffer.smear`, doubling passes), `goo` (blur radius +
  `alphaContrast` after the gaussian: metaballs), `halftone` (`PixelBuffer.halftone`), `inertia` / `squash`
  (evaluated inside `MotionLayer.value`: damped overshoot after a key where the velocity drops, stretch along the
  velocity), `fontWeightAxis` / `fontWidth` (+ `fontVariations`, `FrameRenderer.variant` sets CoreText variation
  axes; text animators carry `fontWeightAxis`/`fontWidth` per unit through `GlyphState.weightAxis/widthAxis`),
  `textHighlights` (`TextHighlight`, marker bands behind words from the CTLine offsets, swept by `start`/`duration`),
  `Gradient` `.conic` (wedges, `Gradient.color(at:)`), `Repeater` `colors` + `randomX/Y/Rotation/Scale` + `seed`,
  and transition types `circle` / `shape` (a growing matte path, through copies of the layers for the span) and
  `match` (`shapeTransition` / `matchTransition` in `SceneOps.swift`).
  `Templates.swift` (`add_template`, groups whose parts are keyed with presets; text/ink colors and card style follow
  the background's luminance) are pure scene edits. `Looks.swift` (`apply_look` / `remove_look`, Add → Look in the app)
  builds the "finished" layers from ordinary ones: a `look` group at the bottom (radial-gradient backdrop, two blurred
  drifting blobs, dust/bokeh) and `look-finish` on top (vignette gradient, mid-gray overlay rect with `grain`), plus a
  camera zoom 1 → 1.04 when the scene has none; re-applying replaces both groups by id. `Docs.instructions` opens with
  a LOOK & DESIGN section (depth, light, secondary motion, type hierarchy, palette, self-check list) that the agent
  prompt points at, and `Sample.swift` is written to follow it, so keep the three in step.
  Quality is enforced in code, not only in the prompt (`DesignCheck.swift`): `designIssues(renderer:)` is a
  deterministic lint (flat background, pure white on black, system font, flat type sizes, unlit layers, ≥ 2 s
  stretches with no motion, text within 80 px of the edge, linear entrances, "only text and boxes" hint) behind the
  `check_design` tool; `set_scene` runs it and, unless `look` is "none", `applyAutoLook` adds a look to a scene whose
  background is flat (`hasBackgroundDepth`), picking the kind from the background's luminance. In the app,
  `ChatStore` puts `design=` (the lint summary) and `style=` (the project's `ChatStyle`: look + font pairing,
  chosen in the composer's Style popover, saved in `.chat.json`) on every context line, and `autoDesignCheck`
  sends warnings back to the agent once per user message after a turn that changed the scene
  (`agent.designCheck` default off switch in the same popover).
- `VideoML.swift`: background removal (Vision person segmentation / foreground instance mask, cached per frame in
  `FrameRenderer.cutoutCache`), `frameBlend` in-betweens (cross-fade or Vision optical flow) and `stabilize`
  (translational registration). Like saliency, the neural requests fail in sandboxed processes; they fall back to
  the untouched picture, and `update_layer` reports why (`PictureML.probe`). Registration works in the sandbox.
- Spatial position (`Spatial.swift`): with `spatial` set, `MotionLayer.position` builds one cubic Bezier per pair of
  x/y key times (auto tangents: neighbor chord direction, ⅓ of each side's length; end keys aim at the neighbor's
  handle; `handles` override per key time and move with the keys in `moveKey`/`shiftKeys`) and maps the arriving key's
  easing onto arc length (overshoot continues along the end tangent). Falls back to per-axis when x/y are linked.
- Motion blur: `drawCopy` samples [open, open + angle] (`motionBlurPhase`, nil = centered); the sample count goes from
  `motionBlurSamples` up to `motionBlurMaxSamples` by how far the layer's bounds corners travel (~1.5 device px each).
- Particle `trail` re-evaluates each particle at earlier times (closed form, so it stays frame-independent).
- `blendMode` applies to every visual layer (set on the context before drawing; particles skip the opacity
  transparency layer and take opacity per particle, so they keep adding up).
- Sound effects (`SoundProfile.swift`, `SoundSynth.swift`): `SoundProfile` splits a short file into bursts (runs
  above -26 dB, gaps ≥ 80 ms) and finds each one's hit (the strike for a sharp attack, else the top of a 40 ms
  smoothed loudness), its shape (hit/whoosh/riser/sustained/multiple) and tone; `placement(hitAt:)` is what
  `add_audio` `hitAt` uses, and `sheet` draws the waveform image `search_stock` kind "sound" returns (it downloads the
  results into `Application Support/VeyMotion/cache/sounds`, which `importItem` reuses). Sound search defaults to
  ≤ 10 s for agents (Openverse `length` + a client filter) and puts loops/ambiences last; the app's browser passes
  `maxDuration: 0`. `SoundSynth` renders `SynthKind`s deterministically (seeded by kind + variant) to a 16-bit WAV
  named by a settings hash and reports exact hit times. Files are written to a `.part` and moved, never `.atomic`
  (that stages in the system temp folder, which sandboxed processes cannot use).
- Version and updates: `AppVersion.marketing` (Core) is the only place the version is written; `bundle.sh` and
  `release.sh` read it with sed. `Updater` (app) polls `AppRelease.latest()` (`/api/app/latest`, served from GitHub
  Releases by `server/server/utils/releases.ts`), stages the zip under Application Support/VeyMotion/updates
  (checks bundle id, version, `codesign --verify`, SHA-256 from the asset digest), and `installOnQuit` (called from
  `applicationWillTerminate`, after `SceneStore.shutdown`) starts a detached `/bin/sh` that waits for the pid, swaps
  the bundle and optionally reopens it. `installBlockedReason` covers `swift run`, App Translocation, disk images and
  unwritable folders.
- Layer ids are unique: `addLayer` / `duplicateLayer` auto-suffix them (`title-2`), and renaming to a taken id throws.
- Plans (`License.swift`, `server/server/utils/license.ts`, `AccountViews.swift`): Free and Pro. Pro is a Polar license
  key; `POST /api/license/activate` activates it on one Mac (Polar enforces the device limit, `conditions.device` =
  `License.deviceId`) and returns a token `base64url(payload).base64url(Ed25519 sig)` valid 14 days, refreshed daily
  (`refreshIfDue`, at launch and on app activation). No database: Polar holds keys/activations. The token lives in
  Application Support/VeyMotion/license.json (not the keychain: the CLI reads it too) and is checked offline against
  `License.publicKeyBase64` (empty = everyone is Free). Gates: `License.require(.feature)` sits in Core entry points
  (VieNeu synthesis, stock video, publishing, tracking/saliency/shake, `addTemplate`), so UI and MCP tools share it;
  the server checks the token on TTS/stock/social routes too (`requirePro`, Polar re-checked hourly).
  `VideoExporter` calls `License.prepareExport`: Free refuses ProRes and Pro content (`proContent`: 3D/models,
  removeBackground), fits into 1080p and draws `Watermark`. Debug builds only: `VEYMOTION_PRO=1` forces Pro and
  `VEYMOTION_LICENSE_PUBLIC_KEY` overrides the key.
