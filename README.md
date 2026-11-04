# VeyMotion

Native macOS motion-graphics editor (SwiftUI) with a built-in MCP server, so AI agents
(Claude Code, Cursor, …) can build and edit animations that you then tweak by hand.

**Status:** MVP. Shapes, text, images; keyframes with easing; presets; live preview; MP4/MOV export; MCP.

## Run

```bash
swift build && swift run VeyMotion   # dev run; `swift build` first so the vmotion CLI exists for the chat
bash scripts/bundle.sh               # build dist/VeyMotion.app (+ vmotion inside it)
open dist/VeyMotion.app
```

Requires macOS 14+. The Claude chat needs [Claude Code](https://claude.com/claude-code) installed and logged in.

## Claude chat inside the app (no MCP needed)

Open the **Claude** tab (⌘L) on the right and describe what you want. Under the hood:

```
Chat panel ──► claude -p (stream-json, your Claude Code login)
                 tools: Bash restricted to `vmotion …`, Read
                   │
                   ▼
               vmotion <command> '<json>' ──unix socket──► running app (live, undoable)
               vmotion render_frame → PNG → Read → Claude checks its own work
```

- Works even where an organization only allows approved MCP servers: it uses Claude Code's
  ordinary Bash tool with a `vmotion`-only allowlist (`--tools Bash,Read --allowedTools "Bash(vmotion:*)" Read`).
- If Claude Code's Bash sandbox is on (e.g. by policy), the app passes
  `--settings {"sandbox":{"network":{"allowUnixSockets":["<control.sock>"]}}}` so `vmotion` can reach the app,
  and frames are written inside the agent's working directory.
- Every message is prefixed with the editor context (playhead, selected layer, layer ids).
- Files: `~/Library/Application Support/VeyMotion/` (`control.sock`, `agent/`, `agent/frames/`).

Same agent in the terminal: `vmotion chat "make the title bounce in"`.

## Audio & voice-over

- **Audio layers** (`type: "audio"`): music, sound effects or recorded voice. Volume is animatable;
  `trimIn`, `fadeIn`/`fadeOut`, and `duckTo` (music dips while a voice speaks). Waveforms show in the timeline;
  dragging the left edge trims the file like a video editor.
- **Voice-over** (Add Layer → Voice-over…, or the `generate_voice` tool): macOS text-to-speech, offline and free.
  Returns per-word timings, used for **captions** (`add_captions`) and so Claude can time visuals to the narration.
  Better voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.
- Preview plays the mix in sync with the playhead; export writes it into the file
  (`.mp4` AAC, `.mov` PCM, audio-only `.m4a` / `.wav`). Preview and export share one mixer (`AudioMixer`).
- Generated voice files live in `~/Library/Application Support/VeyMotion/assets/`.

## Projects

The **Projects** screen fills the window when the app starts (and with **File ▸ Projects…**, ⇧⌘P, or the grid button
in the toolbar): every project in the projects folder plus recent ones elsewhere, with a preview frame, search, and
Open / Rename / Duplicate / Move to Trash. Opening a project switches the window to the editor.

**File ▸ New Project…** (⇧⌘N) creates a folder (default `~/Documents/VeyMotion Projects/`, or
`VEYMOTION_PROJECTS_DIR`) with `scene.json` and its own `assets/` library (`images/ icons/ music/ sfx/ voice/`).
While a project is open, the Assets panel shows the project's files, and every new file — imported, dropped,
downloaded, generated or added by Claude — is filed by type automatically (audio over 20 s → `music/`, shorter →
`sfx/`). Files added to the scene from elsewhere are copied into the project. Paths are saved relative to the
project, so the folder can be moved or shared. ⌘S saves the project (it is also saved when you switch away or quit);
Save As copies the whole folder. The **Shared** tab in the Assets panel shows the shared library (below) for
reuse across projects: *Copy to Project* or drag a file onto the canvas.

`vmotion <tool> --scene <project>/scene.json` works on a project the same way.

## Assets

The **Assets** tab (left panel) shows the shared library in `~/Library/Application Support/VeyMotion/assets/`
(or `VEYMOTION_ASSETS_DIR`). Drop files on it to import, drag an asset (or a Finder file) onto the canvas to add a layer,
right-click to rename, move or put in the Trash. Organize files in folders: the folder button creates one, double-click
opens it, the breadcrumb goes back up, and dropping files on a folder or breadcrumb moves them there (layers that use
moved files are repointed). Claude manages the same folder with the `*_asset` / `*_folder` tools, and the panel
updates live. Images can be PNG/JPEG/HEIC/… or SVG (rendered sharp at any size).

**Free assets** (globe button in the Assets tab, or ask Claude): search and import without an account or API key.

- Photos and illustrations from [Openverse](https://openverse.org), limited to licenses that allow commercial use and
  changes (CC0, Public Domain, CC BY, CC BY-SA).
- Icons from [Iconify](https://iconify.design): 200k+ open-source SVG icons, imported in the color you pick.
- Music from [Jamendo](https://www.jamendo.com) and sound effects from [Freesound](https://freesound.org) (via Openverse,
  same license filter), with in-app preview. **Use as Background** adds a track from 0s to the scene end with
  fades, at 60% volume, ducked under voice-overs.
- License and credit are saved with each file (`.credits.json` in the library). CC BY / BY-SA items must be credited:
  right-click an asset → Copy Credit, or the quote button copies the credits for everything the scene uses
  (`get_credits` for agents). Logos and trademarks found in search results are not covered by those licenses.

## Connect an external agent over MCP

While the app is open it serves MCP at `http://127.0.0.1:19790/mcp` (localhost only).

```bash
claude mcp add --transport http veymotion http://127.0.0.1:19790/mcp
```

(The status bar has a button that copies this command.) Then ask, e.g.:
*"Make a 6-second explainer: title, three stats that pop in one by one, end card. Check frames before finishing."*

Agent edits show up live and can be undone with ⌘Z (they're labelled "Agent: …" in the Edit menu).

Optional: set `VEYMOTION_TOKEN=...` in the environment to require `Authorization: Bearer ...`.

### Without the app (headless)

```bash
vmotion mcp scene.json         # MCP over stdio, edits the file
vmotion serve scene.json 19790 # MCP over HTTP, edits the file
claude mcp add veymotion -- /path/to/vmotion mcp /path/to/scene.json
```

### MCP tools

| Tool | Purpose |
|---|---|
| `get_scene` / `set_scene` | read / replace the whole scene |
| `update_scene` | width, height, fps, duration, background |
| `add_layer` / `update_layer` / `remove_layer` / `reorder_layer` | layer edits (`update_layer` is a JSON merge patch) |
| `set_keyframes` | replace keyframes of one property (numbers or the colors `fill`/`stroke`/`color`) |
| `apply_preset` | 34 presets: entrances (fade, slide, pop, zoom, blur, bounce, drop, flip, rotate), exits, emphasis (spin, pulse, heartbeat, shake, wobble, jello), `drawOn` for shapes, per-letter/word/line text presets; `ids` + `stagger` cascades over several layers |
| `set_parent` | make a layer follow another one (keeps its on-screen position) |
| `render_frame` | PNG of one frame, so the agent can check its work |
| `list_assets` / `read_asset` | browse the asset library; image preview / text content |
| `import_asset` / `write_asset` | copy a file or download a URL / create a file from text or base64 |
| `search_stock` / `import_stock` / `get_credits` | find free photos, illustrations, icons, music, sound effects; import with license; credit lines |
| `rename_asset` / `delete_asset` | rename or move into a folder (repoints layers) / move to Trash (refused while in use unless `force`) |
| `create_folder` / `rename_folder` / `delete_folder` | organize the library in folders (renaming or moving a folder repoints layers) |
| `export_video` | `.mp4` (H.264) or `.mov` (ProRes 4444, keeps alpha) |

## CLI

Every MCP tool is also a command. With the app open it edits the app's scene; otherwise pass
`--scene file.json` (or set `VEYMOTION_SCENE`).

```bash
vmotion tools                                   # list commands + arguments
vmotion apply_preset '{"id":"title","preset":"popIn","start":0.5}'
vmotion render_frame '{"time":2}' --out f.png
vmotion get_scene --scene scene.json

vmotion sample scene.json
vmotion frame  scene.json 2.5 frame.png 0.5
vmotion render scene.json out.mp4
```

## Scene format

```json
{
  "width": 1920, "height": 1080, "fps": 30, "duration": 6, "background": "#0E0E12",
  "layers": [
    { "id": "title", "type": "text", "text": "Hello", "fontSize": 120, "fontWeight": "heavy",
      "x": 960, "y": 540, "color": "#FFFFFF",
      "opacity": { "keyframes": [ {"t": 0, "v": 0}, {"t": 0.6, "v": 1, "easing": "easeOut"} ] } }
  ]
}
```

- Scene pixels, origin top-left; `x`/`y` is the layer center. First layer = bottom.
- Animatable: `x`, `y`, `scale`, `scaleX`, `scaleY`, `rotation` (deg), `skewX`, `skewY`, `anchorX`, `anchorY`, `opacity`,
  `width`, `height`, `cornerRadius`, `strokeWidth`, `trim` (stroke draw-on), `reveal` (typewriter), `letterSpacing`,
  `blur`, `shadowX/Y/Blur/Opacity`, `pathProgress`, `z` (depth), and the colors `fill`, `stroke`, `color`.
  Each is a value or `{"keyframes": [...]}` (color keyframes use `"v": "#RRGGBB"`).
- Keyframe `t` is absolute seconds; `easing` shapes the segment *arriving* at that keyframe:
  `linear | easeIn | easeOut | easeInOut (default) | hold | spring | spring(damping,frequency) | steps(n) |
  cubicBezier(x1,y1,x2,y2)` and `ease<In|Out|InOut><Sine|Quad|Cubic|Quart|Quint|Expo|Circ|Back|Elastic|Bounce>`.
- Per layer: `loop` (`cycle`/`pingpong`/`offset` after the last key), `wiggle` (smooth noise), `parent`,
  `motionPath` (curve the layer follows, driven by `pathProgress`), `textAnimators` (staggered per char/word/line).
- Layer types: `rect` (width, height, cornerRadius, fill, stroke, strokeWidth), `ellipse`,
  `text` (text, fontSize, fontWeight, fontName, color, align, maxWidth), `image` (path, width, height),
  `video` (path to a .mov/.mp4 or a folder of numbered images, width, height, trimIn, speed,
  playback `once`/`hold`/`loop`, fps for image sequences).
- **3D**: render in Blender (or any 3D app) to a PNG sequence with a transparent background, or ProRes 4444 with
  alpha, and add the folder/file as a `video` layer. It composites like any other layer. The video's own sound is
  not played.
- **Camera (2.5D)**: give layers a depth `z` (positive = farther) and add a `camera` layer: `x`/`y` pan with
  parallax, `z` dollies in, `scale` zooms the lens, `rotation` rolls, `perspective` sets the depth strength, and
  `focus` + `aperture` add depth of field. Layers stay flat and face the camera (no X/Y rotation). Several cameras
  with start/end make cuts; without one, a default camera is used.

The full reference the agent sees is in `Sources/VeyMotionMCP/Docs.swift`.

## Architecture

```
Sources/
  VeyMotionCore/   Scene model (Codable), AnimValue/keyframes, Easing, SceneOps (all mutations),
                   FrameRenderer (CoreGraphics + CoreText), VideoExporter (AVAssetWriter)
  VeyMotionMCP/    MCPServer (JSON-RPC, tools), HTTP + stdio transports, control socket, FileSceneHost,
                   ClaudeCodeAgent (headless `claude` + stream-json parsing), AgentPrompt
  VeyMotionApp/    SwiftUI app: SceneStore (undo/redo, playback, SceneHost), canvas, inspector, timeline,
                   ChatStore + ChatPanel (embedded Claude chat)
  vmotion/         CLI
```

- **One mutation path.** UI and MCP both call `SceneOps` through `SceneStore.apply`, so every change is undoable.
- **One renderer.** Preview and export use the same `FrameRenderer`, so the export matches the preview.

## Roadmap

- Drag/resize on canvas, on-canvas motion-path editing, graph editor for values
- Masks, gradients
- Chart components (bar/line/counter), templates
- Audio track + markers, Metal renderer for effects/shaders
- "Code layer" (HTML/JS rendered offscreen) for things the schema can't express
