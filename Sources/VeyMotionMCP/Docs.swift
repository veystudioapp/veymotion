import Foundation

enum Docs {
    static let instructions = #"""
    VeyMotion is a native macOS motion-graphics editor. You edit a scene; the user sees changes live and can undo them.

    SCENE FORMAT (JSON)
    { "width":1920, "height":1080, "fps":30, "duration":6, "background":"#0E0E12", "layers":[ ... ] }
    - Coordinates: scene pixels, origin top-left, y grows downward. A layer's x/y is its CENTER.
    - layers[0] is drawn first (bottom); the last layer is on top.

    LAYER
    Common: id, name, type ("rect" | "ellipse" | "text" | "image" | "video" | "audio" | "camera"), start, end (seconds, end optional = scene end),
            x, y, scale, rotation (degrees), opacity (0..1)
    rect/ellipse: width, height, cornerRadius (rect), fill "#RRGGBB[AA]", stroke, strokeWidth, trim (0..1: part of the
          stroke drawn, for "draw on" line animations)
    text: text (may contain \n), fontSize, fontWeight (thin|light|regular|medium|semibold|bold|heavy|black),
          fontName (optional PostScript name), color, align (left|center|right), maxWidth (wraps), reveal (0..1 typewriter),
          letterSpacing (px), textAnimators (see TEXT ANIMATORS)
    image: path (absolute file path), width/height (optional; keeps aspect if only one is set)
    video: path = a movie file (.mov/.mp4/.m4v) or a FOLDER of numbered images (image sequence, e.g. a Blender render;
          frames in natural name order), width/height (as image), trimIn (source seconds skipped), speed (1 = normal),
          playback ("once": the layer ends with the clip, default | "hold": last frame stays | "loop": starts over),
          fps (image sequences only: frames per second of the images; set to the render's rate, Blender's default is 24).
          The video's own sound is not played. sourceDuration is filled in by the app.
    Optional on every visual layer (omit when unused):
      z (depth in px, default 0; positive = farther from the camera, see CAMERA), scaleX, scaleY (multiply scale; flip effects), skewX, skewY (degrees), anchorX, anchorY (pivot for rotation/scale/
      skew as an offset from the center in layer px, e.g. anchorX = -width/2 spins around the left edge; does not move the
      layer), blur (px), shadowOpacity (0..1, shadow off when 0), shadowX, shadowY (px, default 0/8), shadowBlur (default 16),
      shadowColor ("#000000"), parent, motionPath, pathProgress, loop, wiggle, audioReact (see below)

    ANIMATION
    Every number above and in CAMERA (x, y, z, scale, scaleX, scaleY, rotation, skewX, skewY, anchorX, anchorY, opacity,
    width, height, cornerRadius, strokeWidth, trim, reveal, letterSpacing, blur, shadowX, shadowY, shadowBlur,
    shadowOpacity, pathProgress, volume, perspective, focus, aperture) and the colors fill, stroke and color can be a
    plain value or
      {"keyframes":[{"t":0.5,"v":0},{"t":1.2,"v":1,"easing":"easeOut"}]}     (colors: "v":"#FF5500")
    - Never write the same key twice in one object (e.g. "y": 500 and "y": {"keyframes": ...}); only one would be used.
    - t is ABSOLUTE scene time in seconds. Before the first keyframe the first value holds; after the last, the last holds
      (unless the property loops).
    - easing on a keyframe shapes the segment ARRIVING at it:
        linear, easeIn, easeOut, easeInOut (default), hold (jump at the key),
        ease<In|Out|InOut><Sine|Quad|Cubic|Quart|Quint|Expo|Circ|Back|Elastic|Bounce> e.g. easeOutBack (overshoot),
          easeOutElastic (springy wobble), easeOutBounce (lands and bounces), easeInOutExpo (snappy),
        spring (slight overshoot), spring(damping,frequency) e.g. spring(4,14) bouncy, spring(10,8) soft,
        steps(n) (n jumps, stop-motion look), cubicBezier(x1,y1,x2,y2).
    - loop: {"rotation":"offset","y":"pingpong","fill":"cycle"} repeats a property's keyframes after the last one:
      cycle = start over, pingpong = back and forth, offset = keep adding the change (endless spin: rotation 0→360 + offset).
    - wiggle: {"x":{"amount":12,"frequency":2},"rotation":{"amount":4,"frequency":1.5,"seed":2}} adds smooth random
      motion (amount in the property's unit, frequency = wobbles/second). Works on constant or animated properties.
    - audioReact: {"scale":{"amount":0.12,"band":"bass"},"opacity":{"amount":-0.4,"band":"beat","release":0.3}} makes a
      property follow the music: it adds amount × the sound's level (0..1) on top of the property's value/keyframes.
      band: level (overall loudness) | bass | mid | treble | beat (pulse on every beat) | downbeat (pulse on every bar).
      release = seconds to fall back after a peak (default 0.2; 0.1 punchy, 0.5 smooth). source = audio layer id
      (default: the music layer). Negative amount pushes the other way. Works on every number property and on
      cameras; keep it subtle (scale 0.05–0.2, x/y 10–30 px, rotation 2–5°).
    - parent: id of another layer. The layer then moves, rotates and scales with it, and its x/y become relative to the
      parent's center. Use set_parent to link without the layer jumping. Opacity and timing are not inherited.
    - motionPath: {"points":[[200,800],[960,300],[1700,800]],"smooth":true,"closed":false,"orient":false} — the layer's
      center follows the path (x/y are then ignored); animate pathProgress 0→1 to move along it at even speed;
      orient = true turns the layer to face the direction of travel.

    CAMERA (2.5D: layers stay flat and face the camera, placed at different depths)
    - Give visual layers a depth z (px): 0 = normal size, positive = farther (smaller, moves less), negative = closer.
      A child's depth adds its parent's z. Layers are drawn farthest first (list order only breaks ties), and a layer
      at z = 1000 with the default perspective looks 2/3 its size, so scale far backgrounds up to still fill the frame.
    - Camera layer: {"id":"cam","type":"camera","x":960,"y":540,"z":0,"scale":1,"rotation":0,
                     "perspective":2000,"focus":0,"aperture":0}
      x, y = the scene point the camera looks at (shown at the frame center; set it to the scene center when the scene
      is not 1920x1080); animate x/y to pan with parallax. z = dolly (positive moves toward the layers: push-in).
      scale = lens zoom (magnifies everything, no parallax). rotation = roll (degrees). perspective = distance from
      the camera to the z = 0 plane (default 2000; smaller = stronger depth effect; animate it against z for a dolly
      zoom). focus = depth z that is sharp; aperture = blur in px for layers 1000 px of depth from focus (0 = off,
      try 20–60); animate focus for a rack focus.
    - Camera layers are not drawn, cannot have a parent, and support motionPath/pathProgress, loop and wiggle
      (wiggle x/y/rotation = handheld shake). The topmost camera layer visible at time t is used, so cameras with
      start/end make cuts. Without a camera, a default one is used (z still works).
    - Layers that end up behind the camera (z − camera z < −perspective) are not drawn.

    TEXT ANIMATORS (per character / word / line, staggered)
    "textAnimators":[{"unit":"char","mode":"in","start":0.5,"duration":0.5,"stagger":0.04,"order":"forward",
                      "easing":"easeOutBack","opacity":0,"y":40,"x":0,"scale":1,"rotation":0}]
    - unit: char | word | line. mode: in (units arrive from the away state) | out (units leave to it).
    - opacity/x/y/scale/rotation describe the AWAY state (x/y in px, y down); units animate between it and normal.
    - Unit i starts at start + rank·stagger; order: forward | reverse | center | edges | random (seed).
    - Use one "in" and optionally one "out" animator. The text*/typewriter presets create them for you.

    3D MODELS / RENDERS
    3D content comes in as rendered video: render in Blender (or any 3D app) to a PNG sequence with a transparent
    background (Film → Transparent, output PNG RGBA) or ProRes 4444 .mov with alpha, then add a video layer pointing at
    the folder or file. It composites like any layer (position, scale, z, blur, shadow, presets).

    AUDIO
    audio layers: type "audio", path, start, end (optional; default = end of file), role ("voice"|"music"|"sfx"),
          volume (animatable, 1 = original), trimIn, fadeIn, fadeOut, duckTo (music: level while a voice speaks).
          Audio layers are not drawn. sourceDuration / transcript / words are filled in by the app.
    - Narrated video: write the script per section, then generate_voice once per section with start = section start.
      Use the returned duration to size each section (leave ~0.3–0.6s of air between sections) and the word times
      to make key text/visuals appear as they are spoken. Extend the scene duration if the narration is longer.
    - Captions: add_captions on each voice layer when the user wants subtitles.
    - Music: add_audio with role "music", duckTo ≈ 0.25 and a fadeOut of 1–2s at the end.
    - Cut to the music: call analyze_audio once the music layer is in (it returns scene times). Start entrances and
      scene changes on downbeats, land keyframes and apply_preset starts on beats (e.g. a list item per beat), and
      put the biggest moment on the loudest part or a strong onset. For continuous motion with the music use
      audioReact (e.g. a logo pulsing on bass, a background breathing with level, a camera kick on every beat).

    ASSETS
    The asset library is one shared folder of files (images, audio, …); generated voice-overs are stored there too.
    - Files can be organized in folders. An asset's name is its path inside the library, e.g. logo.png or
      icons/social/x.svg; every tool that takes a name accepts such paths.
    - list_assets shows folders, names, sizes and the full path (`folder` limits it to one folder). Use the full path
      as an image/audio layer's `path`.
    - import_asset copies a local file or downloads a URL into the library; write_asset creates a file from text or
      base64; read_asset shows an image preview or a text file; rename_asset also repoints layers; delete_asset moves
      the file to the Trash (refused while a layer uses it unless force is true).
    - import_asset, write_asset and import_stock take an optional `folder` (created if missing). rename_asset moves a
      file when newName has another folder (newName is the full name, e.g. icons/logo.png; a bare name moves it to
      the top level). create_folder, rename_folder (also moves; repoints layers) and delete_folder manage folders.
      Only make folders when the user asks for them or the library is getting large.
    - Prefer files in the library over paths elsewhere on disk, so the user can find them in the Assets panel.

    PROJECTS
    - The user may have a project open (see list_assets: "Project library"). A project is a folder with scene.json and
      its own assets/ library, so asset tools work inside the project. Paths are absolute in tools; the app stores them
      relative to the project so the folder can be moved.
    - In a project, files without a `folder` are filed by type automatically: images/, icons/ (stock icons), music/
      and sfx/ (audio longer / shorter than 20 s), voice/ (generate_voice), video/. Pass `folder` only when the user
      wants another place (e.g. images/backgrounds), and reuse existing folders rather than making similar new ones.
    - Files the user keeps for every video (logos, brand music…) live in the shared library: list_assets with
      library "shared", then import_asset that file's path to copy it into the project before using it in a layer.
      Never point a layer at a file outside the project.

    FREE ASSETS
    - search_stock finds photos/illustrations (Openverse) and icons (Iconify); look at the numbered preview, then
      import_stock the ref you want and use the returned path in an image layer.
    - Icons are SVG and stay sharp at any size: pick a color that contrasts with the background (color param).
    - Photos: size them to cover the frame (set width = scene width, or height = scene height) when used as backgrounds,
      and dim them with a semi-transparent rect on top if text sits over them.
    - Background music: search_stock kind "music" with a mood/genre (e.g. "calm piano", "upbeat corporate", "cinematic").
      Prefer a track at least as long as the scene; import_stock it, then add_audio with role "music", start 0,
      end = scene duration, volume ~0.6, fadeIn 0.5, fadeOut 1.5, and duckTo ~0.25 if there is a voice-over.
    - Sound effects: kind "sound" (e.g. "whoosh", "pop", "click", "ding"); add_audio with role "sfx" at the moment a
      visual enters. Keep them sparse and short.
    - Some licenses (CC BY, CC BY-SA) require credit. When you used such assets, call get_credits and tell the user,
      or add a small credits text at the end if they want it in the video.

    WORKFLOW TIPS
    - For a short piece (up to ~15 layers), build it in one set_scene call, then refine with update_layer / set_keyframes.
    - For a longer piece, plan it as time sections (e.g. 0–8s intro, 8–20s concept 1, …). Call set_scene with the
      settings and the first section, then add_layers once per section. Give each section's layers start/end so the
      scene stays light. Keep every call's arguments under ~6 KB: very large calls are slow to write and may be rejected.
    - ALWAYS call render_frame at a few key times to check layout and timing visually before saying you are done.
    - Stagger entrances by 0.1–0.2s, use easeOut for entrances and easeIn for exits, keep text inside a safe margin
      (~80px from edges), and give the viewer time to read (about 1s per 4 words).
    - apply_preset is a quick way to add common entrances/exits/emphasis; pass `ids` + `stagger` to cascade one preset
      over several layers (e.g. list items 0.12s apart). Combine with easings like easeOutBack / easeOutExpo for polish,
      and use loop/wiggle for ambient motion (floating shapes, subtle camera-like drift).
    - For depth, spread layers over z (e.g. background 1500, mid 600, title 0, foreground particles −300) and add a
      camera that slowly pans or pushes in; a little aperture with focus on the title adds a cinematic look.
    """#

    static let toolsJSON = #"""
    [
      {
        "name": "get_scene",
        "description": "Return the full current scene as JSON (settings and all layers with their animations).",
        "inputSchema": { "type": "object", "properties": {} }
      },
      {
        "name": "set_scene",
        "description": "Replace the entire scene. Use this to build a new composition in one step. See the server instructions for the format.",
        "inputSchema": {
          "type": "object",
          "properties": { "scene": { "type": "object", "description": "Full scene JSON: width, height, fps, duration, background, layers." } },
          "required": ["scene"]
        }
      },
      {
        "name": "update_scene",
        "description": "Change scene settings (width, height, fps, duration, background) without touching layers.",
        "inputSchema": {
          "type": "object",
          "properties": { "changes": { "type": "object", "description": "e.g. {\"duration\": 8, \"background\": \"#000000\"}" } },
          "required": ["changes"]
        }
      },
      {
        "name": "add_layer",
        "description": "Add one layer on top of the others (or at `index`, 0 = bottom). Returns the final layer id.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "layer": { "type": "object", "description": "Layer JSON; `type` is required. Missing fields use defaults." },
            "index": { "type": "integer" }
          },
          "required": ["layer"]
        }
      },
      {
        "name": "add_layers",
        "description": "Add several layers on top, in order. Use this to build a long piece section by section.",
        "inputSchema": {
          "type": "object",
          "properties": { "layers": { "type": "array", "items": { "type": "object" }, "description": "Layer JSON objects, bottom to top." } },
          "required": ["layers"]
        }
      },
      {
        "name": "update_layer",
        "description": "Merge-patch a layer: only the given fields change; set a field to null to reset it. An animated property given as a number becomes constant.",
        "inputSchema": {
          "type": "object",
          "properties": { "id": { "type": "string" }, "changes": { "type": "object" } },
          "required": ["id", "changes"]
        }
      },
      {
        "name": "remove_layer",
        "description": "Delete a layer.",
        "inputSchema": { "type": "object", "properties": { "id": { "type": "string" } }, "required": ["id"] }
      },
      {
        "name": "reorder_layer",
        "description": "Move a layer to a draw-order index (0 = bottom).",
        "inputSchema": {
          "type": "object",
          "properties": { "id": { "type": "string" }, "index": { "type": "integer" } },
          "required": ["id", "index"]
        }
      },
      {
        "name": "set_keyframes",
        "description": "Replace all keyframes of one property (numbers or the colors fill/stroke/color). An empty list makes the property constant.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "property": { "type": "string", "enum": ["x", "y", "z", "scale", "scaleX", "scaleY", "rotation", "skewX", "skewY", "anchorX", "anchorY", "opacity", "width", "height", "cornerRadius", "strokeWidth", "trim", "reveal", "letterSpacing", "blur", "shadowX", "shadowY", "shadowBlur", "shadowOpacity", "pathProgress", "volume", "perspective", "focus", "aperture", "fill", "stroke", "color"] },
            "keyframes": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": { "t": { "type": "number" }, "v": { "type": ["number", "string"], "description": "Number, or \"#RRGGBB[AA]\" for fill/stroke/color." }, "easing": { "type": "string" } },
                "required": ["t", "v"]
              }
            }
          },
          "required": ["id", "property", "keyframes"]
        }
      },
      {
        "name": "apply_preset",
        "description": "Add a ready-made animation to one or more layers between start and start+duration. The layer's current values are the resting state. With several ids, each starts `stagger` seconds after the previous; layers the preset doesn't apply to are skipped. text* presets animate each letter/word/line; drawOn traces a shape's outline.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "ids": { "type": "array", "items": { "type": "string" }, "description": "Several layers, in cascade order." },
            "preset": { "type": "string", "enum": ["fadeIn", "slideUp", "slideDown", "slideInLeft", "slideInRight", "popIn", "zoomIn", "blurIn", "bounceIn", "dropIn", "flipIn", "rotateIn", "fadeOut", "slideOutUp", "slideOutDown", "slideOutLeft", "slideOutRight", "popOut", "zoomOut", "blurOut", "flipOut", "spin", "pulse", "heartbeat", "shake", "wobble", "jello", "drawOn", "typewriter", "textRise", "textPop", "textDrop", "textLines", "textOut"] },
            "start": { "type": "number" },
            "duration": { "type": "number", "default": 0.6 },
            "stagger": { "type": "number", "description": "Seconds between layers when several ids are given." }
          },
          "required": ["preset", "start"]
        }
      },
      {
        "name": "set_parent",
        "description": "Make a layer follow another layer's position, rotation and scale (or unlink it with parent null). By default the layer's x/y are converted so it does not jump at `time`.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "parent": { "type": ["string", "null"], "description": "Parent layer id, or null to unlink." },
            "time": { "type": "number", "description": "Scene time where the layer must stay in place (default 0)." },
            "keepPosition": { "type": "boolean", "description": "Default true. false = keep the raw x/y numbers." }
          },
          "required": ["id"]
        }
      },
      {
        "name": "list_voices",
        "description": "List the text-to-speech voices installed on this Mac (id, name, language, quality). Filter by language prefix, e.g. \"vi\" or \"en\".",
        "inputSchema": { "type": "object", "properties": { "language": { "type": "string" } } }
      },
      {
        "name": "generate_voice",
        "description": "Speak a script with a macOS voice and add it as a voice audio layer starting at `start`. Returns the audio duration and the scene time of every word, so you can time visuals and captions to the narration. Generate one call per section.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "text": { "type": "string", "description": "What to say. Plain sentences; punctuation creates natural pauses." },
            "start": { "type": "number", "description": "Scene time (s) where the voice begins. Default 0." },
            "language": { "type": "string", "description": "e.g. vi-VN, en-US. Used when `voice` is not given." },
            "voice": { "type": "string", "description": "Voice id from list_voices." },
            "rate": { "type": "number", "description": "Speaking speed multiplier, 1 = normal (0.5–2)." },
            "id": { "type": "string", "description": "Layer id, e.g. vo-1." }
          },
          "required": ["text"]
        }
      },
      {
        "name": "add_audio",
        "description": "Add an audio file (music, sound effect or recorded voice) as an audio layer.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Absolute path to wav/aiff/caf/m4a/mp3." },
            "start": { "type": "number" },
            "role": { "type": "string", "enum": ["music", "sfx", "voice"] },
            "volume": { "type": "number", "description": "1 = original level." },
            "trimIn": { "type": "number", "description": "Seconds to skip at the start of the file." },
            "end": { "type": "number", "description": "Scene time to stop (default: end of file)." },
            "fadeIn": { "type": "number" },
            "fadeOut": { "type": "number" },
            "duckTo": { "type": "number", "description": "Music only: volume while a voice speaks, e.g. 0.25." },
            "id": { "type": "string" }
          },
          "required": ["path"]
        }
      },
      {
        "name": "get_audio_info",
        "description": "Duration of an audio file in seconds.",
        "inputSchema": { "type": "object", "properties": { "path": { "type": "string" } }, "required": ["path"] }
      },
      {
        "name": "analyze_audio",
        "description": "Find the rhythm of the music: tempo (bpm), beat times, downbeats (first beat of each bar), strong hits (onsets, [time, strength 0..1]) and loudness per second (0..1). Times are scene seconds for a layer. Use it to land entrances, cuts and accents on the beat and big moments on loud parts.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string", "description": "Audio layer id. Default: the music layer (else the first audio layer)." },
            "path": { "type": "string", "description": "Analyze an audio file instead of a layer (times are then file seconds)." },
            "from": { "type": "number", "description": "Only report times from here (scene seconds)." },
            "to": { "type": "number", "description": "Only report times up to here (scene seconds)." },
            "minStrength": { "type": "number", "description": "Leave out onsets weaker than this (0..1, default 0.4)." }
          }
        }
      },
      {
        "name": "add_captions",
        "description": "Create timed caption text layers from a generated voice layer's word timings (replaces earlier captions for that voice).",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string", "description": "Voice layer id." },
            "fontSize": { "type": "number" },
            "y": { "type": "number", "description": "Vertical center of captions (default: near the bottom)." },
            "color": { "type": "string" },
            "maxChars": { "type": "integer", "description": "Max characters per caption line (default 42)." },
            "background": { "type": "boolean", "description": "Dark rounded bar behind captions (default true)." }
          },
          "required": ["id"]
        }
      },
      {
        "name": "list_assets",
        "description": "List the folders and files in the asset library (images, audio, …) with size/duration, full path and which layers use each.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "kind": { "type": "string", "enum": ["image", "audio", "video", "text", "other"] },
            "folder": { "type": "string", "description": "Only list this folder (and its subfolders), e.g. icons." },
            "library": { "type": "string", "enum": ["active", "shared"], "description": "shared = the shared library while a project is open (read-only; import_asset a path from it to copy it into the project). Default: active." }
          }
        }
      },
      {
        "name": "import_asset",
        "description": "Copy a local file or download an http(s) URL into the asset library. Returns the asset's path to use as a layer `path`. An existing name gets a -2, -3… suffix unless overwrite is true.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "source": { "type": "string", "description": "Absolute file path or http(s) URL." },
            "name": { "type": "string", "description": "File name in the library, with extension (default: from the source)." },
            "folder": { "type": "string", "description": "Folder to put it in, e.g. icons or brand/logos (created if missing). Default: top level." },
            "overwrite": { "type": "boolean", "description": "Replace an asset with the same name. Default false." }
          },
          "required": ["source"]
        }
      },
      {
        "name": "write_asset",
        "description": "Create or replace a library file from text (SVG, JSON, notes…) or base64 bytes. Returns its path.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "name": { "type": "string", "description": "File name with extension, e.g. badge.svg (may include folders: icons/badge.svg)." },
            "folder": { "type": "string", "description": "Folder to put it in (created if missing). Default: top level." },
            "text": { "type": "string" },
            "base64": { "type": "string" },
            "overwrite": { "type": "boolean", "description": "Replace an asset with the same name. Default false." }
          },
          "required": ["name"]
        }
      },
      {
        "name": "read_asset",
        "description": "Look at an asset: images come back as a PNG preview, text files as text, audio as its duration.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "name": { "type": "string", "description": "Asset name, e.g. logo.png or icons/logo.png (or its full path)." },
            "maxPixels": { "type": "integer", "description": "Image preview size, longer side (64–2048, default 1024)." }
          },
          "required": ["name"]
        }
      },
      {
        "name": "rename_asset",
        "description": "Rename or move an asset. newName is the full name in the library, so icons/logo.png moves it into icons (created if missing) and a bare name puts it at the top level. Layers that use it are updated to the new path.",
        "inputSchema": {
          "type": "object",
          "properties": { "name": { "type": "string" }, "newName": { "type": "string" } },
          "required": ["name", "newName"]
        }
      },
      {
        "name": "delete_asset",
        "description": "Move an asset to the Trash. Refused while layers use it unless force is true.",
        "inputSchema": {
          "type": "object",
          "properties": { "name": { "type": "string" }, "force": { "type": "boolean" } },
          "required": ["name"]
        }
      },
      {
        "name": "create_folder",
        "description": "Create a folder in the asset library (parents too), e.g. icons or brand/logos. Fine if it exists.",
        "inputSchema": {
          "type": "object",
          "properties": { "name": { "type": "string" } },
          "required": ["name"]
        }
      },
      {
        "name": "rename_folder",
        "description": "Rename or move a folder with everything in it. newName is the full name in the library (brand/icons moves icons into brand). Layers that use files inside are updated.",
        "inputSchema": {
          "type": "object",
          "properties": { "name": { "type": "string" }, "newName": { "type": "string" } },
          "required": ["name", "newName"]
        }
      },
      {
        "name": "delete_folder",
        "description": "Move a folder and everything in it to the Trash. Refused while layers use files inside unless force is true.",
        "inputSchema": {
          "type": "object",
          "properties": { "name": { "type": "string" }, "force": { "type": "boolean" } },
          "required": ["name"]
        }
      },
      {
        "name": "search_stock",
        "description": "Search free assets online: photos and illustrations from Openverse (licenses allowing commercial use and changes), icons from Iconify (200k+ open-source SVG icons), music from Jamendo and sound effects from Freesound (via Openverse). Returns numbered results with refs, licenses, durations and (for images/icons) a numbered preview image. English keywords work best.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": { "type": "string", "description": "e.g. \"mountain sunset\", \"rocket\", \"upbeat corporate\", \"whoosh\"." },
            "kind": { "type": "string", "enum": ["photo", "illustration", "icon", "music", "sound"], "default": "photo" },
            "page": { "type": "integer", "description": "1-based page (20 results per page, 48 for icons)." },
            "limit": { "type": "integer", "description": "Return at most this many results." },
            "preview": { "type": "boolean", "description": "Include the numbered thumbnail sheet. Default true." }
          },
          "required": ["query"]
        }
      },
      {
        "name": "import_stock",
        "description": "Download a search_stock result into the asset library (with its license and credit recorded). Returns the path to use in an image layer. Icons are saved as SVG in `color`.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "ref": { "type": "string", "description": "From search_stock, e.g. openverse:<id> or iconify:mdi:rocket." },
            "name": { "type": "string", "description": "File name in the library (optional)." },
            "folder": { "type": "string", "description": "Folder to put it in (created if missing). Default: top level." },
            "color": { "type": "string", "description": "Icons only: hex color, default #FFFFFF." },
            "size": { "type": "integer", "description": "Icons only: height in px of the SVG's natural size, default 512." }
          },
          "required": ["ref"]
        }
      },
      {
        "name": "get_credits",
        "description": "Credit lines for the downloaded assets used in the scene (needed for CC BY / CC BY-SA content). Put them in the video's end card or description.",
        "inputSchema": { "type": "object", "properties": {} }
      },
      {
        "name": "render_frame",
        "description": "Render the scene at a time and return a PNG so you can check the result visually.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "time": { "type": "number", "description": "Seconds." },
            "scale": { "type": "number", "default": 0.5, "description": "Output scale relative to scene size (0.1–1)." }
          },
          "required": ["time"]
        }
      },
      {
        "name": "export_video",
        "description": "Render the whole scene (picture + mixed audio) to a file. .mp4 = H.264/AAC, .mov = ProRes 4444 (keeps alpha with a transparent background such as #00000000), .m4a = audio only.",
        "inputSchema": {
          "type": "object",
          "properties": { "path": { "type": "string", "description": "Absolute output path ending in .mp4 or .mov." } },
          "required": ["path"]
        }
      }
    ]
    """#

    static let tools: [[String: Any]] = {
        let data = Data(toolsJSON.utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }()
}
