# VeyMotion for Windows

Native Windows port of VeyMotion (C# / .NET 10, WinUI 3, Win2D). The scene JSON is the contract between the two apps:
a project made on macOS opens here and back. The Swift sources in `../Sources` stay the reference; each C# file names
the Swift file it ports.

## Build

With GNU make (`winget install ezwinports.make`), from this folder:

```bash
make build                   # debug build (copies vmotion into the app's cli\ folder for the chat)
make run [SCENE=file.json]   # the app
make test
make bundle                  # release: dist/VeyMotion/VeyMotion.exe + vmotion.exe
make clean
```

Or with dotnet directly:

```bash
dotnet build                 # from this folder
dotnet test
dotnet run --project src/VeyMotion.App                  # the app (demo scene)
dotnet run --project src/VeyMotion.App -- scene.json    # open a scene, or a project's scene.json
```

To check Core/MCP changes without the GUI, use the CLI against a scene file:

```bash
V=src/vmotion/bin/Debug/net10.0/vmotion.exe
$V sample s.json
$V apply_preset '{"id":"title","preset":"popIn","start":0.5}' --scene s.json
$V check s.json              # validate + print as VeyMotion writes it
$V tools                     # command list generated from the tool schemas
```

Without `--scene` (or `VEYMOTION_SCENE`), tool commands go to the running app over the named pipe
`\\.\pipe\veymotion-control-<user>` (`VEYMOTION_PIPE` overrides) and fail with exit code 3 if the app is not open.

## Layout

| Project | Role | Swift counterpart |
|---|---|---|
| `src/VeyMotion.Core` | Model, JSON, scene ops (platform-neutral `net10.0`) | `VeyMotionCore` (model part) |
| `src/VeyMotion.Mcp` | MCP tool layer, control pipe, Claude Code agent, agent prompt | `VeyMotionMCP` |
| `src/vmotion` | CLI | `vmotion` |
| `src/VeyMotion.App` | WinUI 3 app (unpackaged, self-contained): canvas, transport, Claude panel | `VeyMotionApp` |
| `tests/VeyMotion.Core.Tests` | JSON compatibility, scene ops and MCP tests | — |

**Tool schemas stay single-sourced.** `VeyMotion.Mcp` embeds `../Sources/VeyMotionMCP/Docs.swift` and reads
`instructions` and `toolsJSON` out of it (`Docs.cs`), listing only the tools in `Docs.PortedTools`. To port a tool:
add a case to `McpServer.CallTool` and its name to `PortedTools`; the CLI and the agent prompt pick it up.

**One mutation path.** Scene changes are `SceneOps` extension methods; the app runs them through
`SceneStore.Apply(label, …)` on a clone of the scene (undo stack of 300 snapshots). Agent edits arrive on pipe threads
and hop to the UI thread with an "Agent: …" label, so Ctrl+Z undoes them.

**Embedded chat** (`Chat/ChatStore.cs`, `Chat/ChatPanel.xaml`): a long-lived `claude -p` with stream-json in and out,
`--tools Bash,Read --allowedTools "Bash(vmotion:*)" …`, `--strict-mcp-config --setting-sources ""`. Differences from
macOS: the system prompt goes through `--append-system-prompt-file` (the Windows command line is limited to 32,767
characters), there is no sandbox socket setting (named pipes need none), and `MSYS_NO_PATHCONV=1` keeps Git Bash from
rewriting paths inside the JSON arguments. `render_frame` uses the app's Win2D renderer and saves PNGs under
`%LOCALAPPDATA%\VeyMotion\agent\frames`. Each project (a folder with `scene.json`) keeps its conversation in
`.chat.json` and the per-prompt versions in `.versions.json`, in the same format as macOS.

## Platform mapping

| macOS | Windows |
|---|---|
| SwiftUI + AppKit | WinUI 3 (Windows App SDK) |
| CoreGraphics | Direct2D via Win2D |
| CoreText | DirectWrite (Win2D `CanvasTextLayout`, `CanvasGeometry.CreateText`) |
| Accelerate / vImage | Win2D effects (GPU) |
| AVFoundation | Media Foundation; FFmpeg for ProRes 4444 with alpha |
| Vision | Windows ML / DirectML + ONNX models |
| SFSpeechRecognizer | `Windows.Media.SpeechRecognition` or Whisper |
| AVSpeechSynthesizer | `Windows.Media.SpeechSynthesis` (word boundaries) |
| Keychain | Credential Manager (`PasswordVault`) |
| FSEvents | `FileSystemWatcher` |
| Unix control socket | Named pipe |
| UserDefaults | `%LOCALAPPDATA%\VeyMotion\settings.json` |

## Status

Feature-by-feature comparison with macOS (in Vietnamese): [FEATURES.md](FEATURES.md).

- Model, scene JSON, tools and docs mirror the Swift sources (`Docs.swift` is embedded, so tool schemas and the agent
  reference stay in sync). Every layer type and effect is drawn by one Win2D renderer used by the canvas,
  `render_frame`, export and the CLI.
- Media: Media Foundation through COM interop (`Media/MediaFoundation.cs`) decodes video frames and sound and writes
  H.264/AAC MP4; the scene mix plays while previewing. No ProRes encoder exists on Windows (export `.mp4`).
- Speech: Windows voices (exact word times) and VieNeu for text-to-speech; System.Speech for transcription.
- Editor: layers/assets sidebar, inspector, timeline (keyframes, easing, waveforms, beats), canvas selection and
  dragging, annotation to chat, export/publish/voice-over/sound/stock sheets, RAM preview.
- CLI: tool commands, `frame`, `render`, `serve` (MCP over HTTP), `daemon`, `chat`, `mcp`. Commands that need the
  renderer run `VeyMotion.exe` without a window (`--frame`, `--render`, `--tool`, `--host`).
- Differences: `MotionLayer`/`MotionScene` are classes — `Clone()` before keeping a snapshot. Social tokens live in
  Windows Credential Manager (not shared with the macOS keychain). Background removal has no native segmentation
  model on Windows, so pictures are drawn whole (like macOS in a sandbox).
