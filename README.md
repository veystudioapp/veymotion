# VeyMotion

Native macOS motion-graphics editor (SwiftUI) with a built-in MCP server, so AI agents
(Claude Code, Cursor, …) can build and edit animations that you then tweak by hand.

**Status:** MVP. Shapes, text, images; keyframes with easing; presets; live preview; MP4/MOV export; MCP.

## Run

```bash
swift build && swift run VeyMotion   # dev run; `swift build` first so the vmotion CLI exists for the chat
bash scripts/bundle.sh               # build "dist/Vey Motion.app" (+ vmotion inside it)
open "dist/Vey Motion.app"
```

Requires macOS 14+. The Claude chat needs [Claude Code](https://claude.com/claude-code) installed and logged in.

### Versions and updates

The version is `AppVersion.marketing` in `Sources/VeyMotionCore/AppVersion.swift` (`bundle.sh` writes it into
Info.plist, with the commit count as the build number). It shows in About, Settings (⌘,) and
`vmotion --version`.

The app checks `GET /api/app/latest` on the server (`BASE_API_URL`) shortly after launch and every 6 hours. A newer
version is downloaded in the background, verified, and installed when the app quits (or right away with
**Restart to Update** in the toolbar). Both can be turned off in Settings → Updates; **Check for Updates…** is in the
app menu. Only a bundled app in a folder you can write to (e.g. `/Applications`) replaces itself; `swift run` builds and
copies running from a disk image just offer the download.

To publish a version: bump `AppVersion.marketing`, commit, then `bash scripts/release.sh [notes.md]` (needs `gh`). It
uploads `VeyMotion-<version>-mac.zip` (what the updater installs) and a DMG to the GitHub release `v<version>`. The
server reads releases from `NITRO_UPDATES_REPO=owner/name`; for a private repo also set `NITRO_UPDATES_GITHUB_TOKEN`
(read access), and downloads go through `/api/app/download/:id`.

### Plans: Free and Pro

Free has the whole editor; exports are fitted into 1080p with a small "Made with Vey Motion" watermark. Pro (a
license key sold through [Polar](https://polar.sh), entered in Settings → Account) adds 4K/ProRes exports without the
watermark, Vietnamese voices, stock video, 3D layers and models, background removal, motion tracking,
auto reframe, stabilize, templates and the graph editor. A key works on as many Macs as its Polar activation limit
allows (Deactivate This Mac frees one) and keeps working offline for 14 days.

Setup, once:
1. `cd server && bun run license:keygen`. Put `NITRO_LICENSE_PRIVATE_KEY` in the server's environment and the public
   key in `License.publicKeyBase64` (`Sources/VeyMotionCore/License.swift`). Keep the private key secret; changing it
   signs every user out of Pro until their app refreshes.
2. In Polar, create one **one-time** Pro product with a **License Key** benefit (no expiration, activation limit 3,
   customers may deactivate activations in the portal) and a checkout link for it. Set `NITRO_POLAR_ORGANIZATION_ID`,
   `NITRO_POLAR_PRO_BENEFIT_IDS`, `NITRO_LICENSE_CHECKOUT_URL` and `NITRO_LICENSE_PORTAL_URL` (see
   `server/.env.example`). Test against a Polar sandbox organization with `NITRO_POLAR_API_URL=https://sandbox-api.polar.sh`.

In debug builds, `VEYMOTION_PRO=1` turns Pro on without a key (for development).

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

Same agent in the terminal: `vmotion chat "make the title bounce in"`. A design review of a scene file (lint + an
art-director pass over rendered frames, scores 1–5): `vmotion review scene.json [more.json…] [--lint-only] [--json]`.

### Codex instead of Claude

Pick **Codex** in the chat's model menu (needs the [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) —
`curl -fsSL https://chatgpt.com/codex/install.sh | sh`, then `codex login`; the chat offers both when they are
missing. Set `VEYMOTION_CODEX` if it is not found). Each message runs one `codex exec --json` (the
thread continues with `codex exec resume`):

```
Chat panel ──► codex exec --json (your Codex login and ~/.codex/config.toml, e.g. a proxy base_url)
                 shell: read-only sandbox, no approvals
                 MCP server `veymotion` = vmotion mcp ──unix socket──► running app (live, undoable)
```

`vmotion mcp` without a scene file is a stdio MCP bridge to the running app, usable by any MCP client.
Claude and Codex keep separate sessions (and model/effort settings) in the same project conversation.

## Audio & voice-over

- **Audio layers** (`type: "audio"`): music, sound effects or recorded voice. Volume is animatable;
  `trimIn`, `fadeIn`/`fadeOut`, and `duckTo` (music dips while a voice speaks). Waveforms show in the timeline;
  dragging the left edge trims the file like a video editor.
- **Music sync**: the music's beats show on its clip (bars brighter); keyframes, layers and trims snap to them
  (toggle with **Beats** in the timeline header). `analyze_audio` gives agents the tempo, beat/downbeat times,
  strong hits and loudness, and `audioReact` makes any number property follow the music (loudness, bass/mid/treble,
  or a pulse on every beat/bar) — set it in the Inspector's Motion section.
- **Sound effects** (Add → Sound Effect…, or the `generate_sfx` tool): 35 synthesized effects made to measure, offline
  and license-free (whoosh, swoosh, pop, blip, click, tick, ding, chime, sparkle, riser, impact, thud, drop, glitch,
  typing; cinematic swell, braam, explosion, subdrop, laser; notification, error, beep, coin, powerup, tada; shutter,
  clap, droplet, boing, heartbeat, scribble; static, and the beds wind and drone) with length, pitch, direction,
  repeats and reverb. Each knows where its hit is, so it lands on the playhead
  (a whoosh peaks there, a riser ends there). For stock sounds, agents see each result's shape (hit / whoosh / riser /
  sustained / several sounds), peak and tags plus a waveform sheet, and `add_audio` with `hitAt` skips leading silence
  and starts the sound early so its peak lands on the right frame.
- **Voice-over** (Add Layer → Voice-over…, or the `generate_voice` tool): macOS text-to-speech, offline and free.
  Returns per-word timings, used for **captions** (`add_captions`) and so Claude can time visuals to the narration.
  Better voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.
- **Vietnamese voices with [VieNeu](https://vieneu.io)**: pick the VieNeu engine in the Voice-over sheet, or pass
  `"engine": "vieneu"` to `list_voices` / `generate_voice`. The app calls the server in `server/` (Nitro), which
  keeps the VieNeu API key: put `NITRO_VIENEU_API_KEY` in `server/.env`, run `cd server && bun run dev`, and point
  the app at it with `BASE_API_URL` (default `http://localhost:3000`; see `.env.example`). Word timings for
  captions are estimated.
- Preview plays the mix in sync with the playhead; export writes it into the file
  (`.mp4` AAC, `.mov` PCM, audio-only `.m4a` / `.wav`). Preview and export share one mixer (`AudioMixer`).
- Generated voice files live in `~/Library/Application Support/VeyMotion/assets/`.

## Social video: export sizes

- **Platform sizes**: the Export sheet's **Size** menu has TikTok, YouTube Shorts, Reels (1080×1920), YouTube
  (1920×1080), Facebook feed (1080×1350), X (1920×1080) and Square (1080×1080). A scene of another aspect
  ratio is **fit** (bars in the background color) or **fill** (cropped), and the sheet warns when the video is
  longer or (roughly) bigger than the platform accepts. Agents use `export_video` with `preset` / `fit`; the CLI
  takes `vmotion render scene.json out.mp4 --preset tiktok --fit fill`.

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
- Lottie animations from [LottieFiles](https://lottiefiles.com) (animated icons, loaders, stickers), free under the
  Lottie Simple License, played as vector video layers.
- Music from three catalogs searched together: [Jamendo](https://www.jamendo.com) (full tracks),
  [Freesound](https://freesound.org) (short loops, mostly CC0) and [ccMixter](https://ccmixter.org) (remixes with a
  bpm, CC BY / CC0 only), filtered by **Instrumental**, tempo and source (`instrumental`, `tempo`, `minDuration`,
  `source` in `search_stock`). Sound effects come from Freesound. Jamendo and Freesound go through Openverse with the
  same license filter. In-app preview for all of them. **Use as Background** adds a track from 0s to the scene end with
  fades, at 60% volume, ducked under voice-overs.
- License and credit are saved with each file (`.credits.json` in the library). CC BY / BY-SA items must be credited:
  right-click an asset → Copy Credit, or the quote button copies the credits for everything the scene uses
  (`get_credits` for agents). Logos and trademarks found in search results are not covered by those licenses.

## Connect an external agent over MCP

While the app is open it serves MCP at `http://127.0.0.1:19790/mcp` (localhost only).

```bash
claude mcp add --transport http veymotion http://127.0.0.1:19790/mcp
```

(Help → Copy Claude Code MCP Command copies this command.) Then ask, e.g.:
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
| `analyze_audio` | tempo, beats, downbeats, strong hits and loudness of the music, in scene seconds (short files: the sound's shape and peak) |
| `generate_sfx` | synthesized sound effect (whoosh, pop, click, ding, riser, impact…) placed so its hit lands at `hitAt` |
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
  `width`, `height`, `cornerRadius`, `strokeWidth`, `trim`/`trimStart`/`trimOffset` (trim paths), `reveal` (typewriter),
  `letterSpacing`, `blur`, `shadowX/Y/Blur/Opacity`, `glow`/`glowRadius`, `pathProgress`,
  `brightness`/`contrast`/`saturation`/`hue`/`tint` (color correction), `wipe` (transition, 0 shown → 1 wiped away),
  stylize `pixelate`/`posterize`/`rgbSplit`/`glitch`/`grain`/`scanlines`/`vignette`, `directionalBlur`/`blurAngle`/
  `zoomBlur`, distort `waveWarp`/`ripple`/`waveLength`/`waveSpeed`/`twirl`/`bulge`/`distortRadius`/`turbulence`,
  `keyTolerance`/`keySoftness`, light `shine`/`shinePosition`/`shineAngle`/`shineWidth`, `rays`/`raysLength`, `outline`,
  `innerGlow`/`innerGlowRadius`, path operators `offsetPath`/`zigzag`/`wigglePath`/`pucker`/`dashOffset`/`taperStart`/
  `taperEnd`, text `counter` (number shown for `{n}`)/`scramble`/`textOffset`, video `timeRemap`, 2.5D
  `rotationX`/`rotationY`/`perspective`, grading `levelsBlack`/`levelsWhite`/`levelsGamma`/`gradientMapAmount`/`lutAmount`,
  `emission`/`particleSpeed`/`particleSize` (particles), the colors `fill`, `stroke`, `color`, and a path's shape `d`
  (keyframes morph between shapes).
  Each is a value or `{"keyframes": [...]}` (color keyframes use `"v": "#RRGGBB"`).
- Keyframe `t` is absolute seconds; `easing` shapes the segment *arriving* at that keyframe:
  `linear | easeIn | easeOut | easeInOut (default) | hold | spring | spring(damping,frequency) | steps(n) |
  cubicBezier(x1,y1,x2,y2)` and `ease<In|Out|InOut><Sine|Quad|Cubic|Quart|Quint|Expo|Circ|Back|Elastic|Bounce>`.
- Per layer: `blendMode` (`normal`, `add`, `screen`, `multiply`, `overlay`, `lighten`, `darken`), `loop` (`cycle`/`pingpong`/`offset` after the last key), `wiggle` (smooth noise), `audioReact` (follows the music), `parent`,
  `motionPath` (curve the layer follows, driven by `pathProgress`), `textAnimators` (staggered per char/word/line),
  `gradient` (linear/radial fill for shapes, paths and text), `matte` (track matte: alpha/luma, inverted),
  `repeater` (stepped copies with compounding transform and delay), `motionBlur` (shutter angle), `glowColor`,
  `tintColor`, `wipeStyle` (`linear`, `radial` clock wipe, `iris`, `blinds`, `blocks` dissolve; angle, feather, count),
  `keyColor` (green/blue screen keying), `posterizeTime` (stop-motion frame rate for one layer), `shineColor`/
  `outlineColor`/`innerGlowColor`, `dash` (stroke dash pattern), text `stroke` (outline) and `textPath` (text on a
  curve), `links` (a property follows another layer's: multiply, add, delay), `depth`/`fixed` (camera parallax),
  `cornerPin` (pin the box corners, animatable), `pins` (puppet pins), `hideBackface`, `trimSequential`
  (handwriting trim), `curves`, `gradientMap`, `lut` (.cube), `removeBackground` (`person`/`subject`, Vision),
  `frameBlend` (`blend`/`flow` slow motion).
- Scene `camera`: animatable `x`, `y`, `zoom`, `rotation` (+ `wiggle` for a handheld shake) framing every layer;
  layers with `depth` move less (far) or more (close); `focus` + `aperture` blur layers away from the focus depth.
- Layer types: `rect` (width, height, cornerRadius, fill, stroke, strokeWidth), `ellipse`,
  `path` (`d` = SVG path data or `star(5,200,80)` / `polygon(6,150)` / `circle(r)` / `ellipse(rx,ry)` / `rect(w,h,r)`,
  fill, stroke, fillRule, lineCap, lineJoin),
  `text` (text, fontSize, fontWeight, fontName = any installed font, a font file in the asset library, or a Google
  font imported with `search_stock`/`import_stock` kind `font`; color, align, maxWidth), `image` (path, width, height),
  `video` (path to a .mov/.mp4, a folder of numbered images or a Lottie .json/.lottie, width, height, trimIn, speed,
  playback `once`/`hold`/`loop`, fps for image sequences, `timeRemap` for speed ramps/freezes/reverse), `particles`
  (see below), `generator` (audio `spectrum`/`waveform` visualizers in bars, line or circle; fractal `noise`;
  `lightning`; `grid`; `chart` bar/line/area/pie/donut from `values`; lens `flare`), `group` (`children` drawn as one
  layer, a precomp).
- Tools beyond editing: `transition` (fade, dissolve, push, slide, zoom, whip, wipe, iris, blinds, blocks, clock,
  glitch, flash, blur between two layers), `group_layers`/`ungroup`, `track_motion` (Vision object tracking that pins a
  layer to something in a video), `auto_reframe` (Vision saliency keeps the subject centered for 9:16 exports),
  `stabilize` (removes camera shake), `sync_to_beats` (presets, pulses, cuts or flashes on the music's beats),
  `add_template` (lower third, call-out, subscribe, end card, title card, quote), `apply_look` (cinematic, clean,
  neon, retro, sunset, studio: gradient backdrop, drifting lights, dust, vignette, grain and a slow camera push in one
  call; also Add → Look in the app; `set_scene` adds one by itself when the background is flat), `check_design`
  (lints for what makes a draft: flat background, system font, unlit layers, static stretches, text on the edge; and
  for what makes a piece look machine-made: one entrance on everything, no stagger, too many fonts or hues, text
  shown too briefly, weak contrast against the pixels behind it, overlapping or almost-aligned text, text under a
  phone app's buttons; the in-app chat runs it after every change and hands the findings back to the assistant, then
  a separate Claude Code review of rendered frames scores the piece and sends back what a viewer would notice;
  `vmotion review scene.json` does both from the terminal), `duplicate_layer`,
  `shift_time` (makes room in the timeline: everything after a point moves, later keyframes included),
  `render_frames` (a labeled contact sheet of up to 24 times), `import_vector` (an SVG as a group of editable path
  layers, one per shape, gradients and transforms kept), `set_bones` / `bind_bone` / `pose_bones` / `solve_ik` (a
  cut-out rig: bones with lengths, angles and limits, layers hung on them, FK poses and CCD inverse kinematics),
  `draw_frame` (frame-by-frame `drawing` layers: strokes held for n frames at their own fps), `text_to_path` (text → vector
  paths, whole or per letter), `combine_paths` (union / subtract / intersect / exclude outlines).
- **Particles**: `{"type": "particles", "x": 960, "y": 900, "width": 220, "height": 0, "particles": {"preset": "fire"}}`.
  Presets: `fire`, `smoke`, `dust`, `sparks`, `snow`, `rain`, `confetti`, `bokeh`, `magic`, `explosion`; any field
  overrides the preset (rate, bursts, lifetime, speed, direction, spread, gravity, wind, drag, turbulence, floor/bounce,
  shape `soft`/`circle`/`square`/`spark`/`image`, size, grow, colors over life…). The layer is the emitter (width/height
  size it); `from` emits from another layer instead, e.g. inside a text's letters to make it break into dust.
- **3D**: render in Blender (or any 3D app) to a PNG sequence with a transparent background, or ProRes 4444 with
  alpha, and add the folder/file as a `video` layer. It composites like any other layer. The video's own sound is
  not played.

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
