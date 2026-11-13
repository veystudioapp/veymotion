import Foundation

enum Docs {
    static let instructions = #"""
    VeyMotion is a native macOS motion-graphics editor. You edit a scene; the user sees changes live and can undo them.

    SCENE FORMAT (JSON)
    { "width":1920, "height":1080, "fps":30, "duration":6, "background":"#0E0E12", "layers":[ ... ] }
    - Coordinates: scene pixels, origin top-left, y grows downward. A layer's x/y is its CENTER.
    - layers[0] is drawn first (bottom); the last layer is on top.
    - For social video, size the scene for the platform: TikTok / YouTube Shorts / Reels 1080×1920 (9:16, Shorts and
      Reels up to 3 min), YouTube 1920×1080, Facebook feed 1080×1350 (4:5), X 1920×1080 (up to 2:20), square 1080×1080.
      Keep text and faces out of the bottom ~20% and right edge of 9:16 videos (platform buttons and captions cover them).
      Publishing is done by the user from the app (Export → Publish); you cannot post.

    PLANS
    The user is on Free or VeyMotion Pro. Pro-only tools fail with a message saying so: VieNeu voices (generate_voice
    engine "vieneu"), stock video (search_stock/import_stock kind "video"), track_motion, auto_reframe, stabilize and
    add_template. 3D layers/models and removeBackground preview on Free, but such a scene exports only with Pro.
    Free exports are fitted into 1080p, carry a small "Made with Vey Motion" watermark, and cannot be ProRes (.mov).
    When a tool says Pro is needed, tell the user (Settings → Account) and offer a Free alternative (macOS voices,
    stock photos, manual keyframes, building the layers yourself) instead of retrying.

    LOOK & DESIGN (read this before building anything: it is what separates a finished video from a rough draft)
    A composition made of flat fills on a flat background looks like a draft. Professional motion graphics always
    have three layers of depth, and every new piece you build must have them unless the user asks for a flat style:
    1. A BACKGROUND WITH DEPTH: never a plain color. Call apply_look first (one call, see its description) or build it
       yourself: a full-frame rect with a radial gradient (lighter near the subject, dark edges), two big blurred
       ellipses (blur 150–300, blendMode screen or add on dark looks, opacity 0.4–0.6) in two related colors that
       drift slowly (wiggle x/y amount 40–80, frequency 0.08), a dust or bokeh particles layer at opacity 0.3–0.5, and
       on top a vignette (radial gradient from transparent to #000000AA) and a grain layer (mid-gray rect, blendMode
       overlay, grain 0.15–0.3). Light looks: white → light gray gradient, pastel blobs, no grain, dark text.
    2. A SUBJECT WITH LIGHT: text and shapes carry shadowOpacity 0.3–0.5 (shadowY 10–20, shadowBlur 30–50) on light
       looks, or glow 0.5–1.5 on dark looks; gradients instead of flat fills on big shapes, cards and hero titles
       (two neighboring hues, e.g. "#7C5CFF" → "#4FD1FF"); cards get cornerRadius 16–28, a 1 px stroke of white at
       8–15% alpha and a translucent fill (#FFFFFF14) on dark looks (glass), or white with a soft shadow on light.
    3. SECONDARY MOTION: something is always moving slowly — the look's blobs and particles, a camera zoom 1 → 1.04
       over the whole piece (or a 2–3% push per section), loop/wiggle on decorative shapes, and the subject's own
       entrance overshoot (easeOutBack / easeOutExpo / spring), so no frame is static.
    Typography: choose a font family for the mood (see FONTS; the system font is a last resort), 1–2 families per
       piece. Build a hierarchy: hero 120–180 px (heavy/black, letterSpacing -2 to -4), heading 64–96, body 32–44
       (medium, color at 70–80% of the text color, e.g. "#C8CAD6" on dark), label/eyebrow 22–28 (semibold, uppercase,
       letterSpacing 3–6, in the accent color). Lines of body text stay under ~45 characters (maxWidth).
    Color: pick ONE palette and stick to it: a background family (2 close dark or light tones), 1 accent (used on
       labels, rules, the key number, the main blob), 1 secondary hue related to the accent (second blob, gradients),
       and text in near-white (#F2F3F7) or near-black (#15171C), never pure #FFFFFF on pure #000000. Good pairs:
       indigo #6C5CE7 + cyan #4FD1FF; coral #FF6B6B + gold #FFD166; emerald #10B981 + mint #A7F3D0;
       magenta #FF2D95 + cyan #00D4FF (neon); orange #FF8C42 + plum #C34A8F (retro).
    Timing and rhythm: entrances 0.5–0.8 s staggered 0.08–0.15 s, exits shorter (0.3–0.5 s, easeIn), hold readable
       text ~1 s per 4 words, transitions between sections with a wipe, a shape morph or a camera move (not just a
       cut), and sound: a whoosh on moves, a soft hit on landings, music ducked under voice (see AUDIO).
    Illustrations: an object the viewer must recognize (a tree, a hand, a phone, a plane, a person, an animal) is never
       a triangle, a box or a stack of ellipses: that is a placeholder. Get a real drawing first: search_stock kind
       "icon" with palette=true in the query (e.g. "christmas tree palette=true": only multi-color illustration
       sets; without it the results are mostly one-color line icons) → import_stock → import_vector, which gives you one path
       layer per part to animate (pop the parts in, swing a limb with bones, trim the outlines on). Draw a shape
       yourself only when it is simple by nature (a card, a ring, a chart, an abstract pattern) or after the search
       found nothing, and then with curves (C/Q/A in d), a consistent stroke, and corners softened by a stroke in the
       fill color (strokeWidth 8–16; path joins are round). Keep one drawing style per piece (all flat-color, or all
       line art), parts that touch where they join, and the subject at about a third of the frame.
    Easing: overshoot (easeOutBack / spring / elastic) is an accent for one or two hero elements per section. The
       rest arrive with easeOutExpo / easeOutCubic and travel with easeInOutCubic; fast moves get motionBlur.
    Before you say you are done, run check_design (it finds the items below automatically; set_scene runs it too),
    then look at EVERY section at full size: check_design ends with the list of times; render_frame each one (one
    call per time, default scale) and Read it. A contact sheet (render_frames) is for pacing only: at that size a
    broken drawing, melted text or a detached limb is invisible. Fix everything listed and anything you see that
    fails this list, and render the fixed time again:
       - Does every object look like what it is, with parts that join? → a real illustration (see Illustrations).
       - Is every word readable: not inside a goo group, not over a busy photo without a dim layer, not overlapping
         other text? → move it out, dim the picture, separate the lines.
       - Does a long shadow stop in the middle of the frame? → longShadow long enough to leave the frame.
       - Is a section empty or its subject tiny? → a subject at about a third of the frame.
       - Does everything bounce? → overshoot only on the hero.
       - Is the background flat? → look layers (gradient, blobs, grain, vignette).
       - Does the subject sit on the background without a shadow or glow? → add one.
       - Is any text pure white on pure black, the system font, or all the same size? → palette, font, hierarchy.
       - Are there frames where nothing moves? → ambient motion, camera drift.
       - Do entrances just fade or slide linearly? → overshoot easings, stagger, motionBlur on fast moves.
       - Anything overlapping, clipped, or closer than 80 px to the edge? → fix layout.
       - Can every text be told from what is behind it (4.5:1; display type can go lower), with no photo detail
         crossing the letters? → change the color, add a plate or a dim layer.
       - Does everything arrive the same way, or five things at the same instant? → one entrance per role (hero,
         supporting, decoration), 0.06–0.12 s stagger in reading order.
       - More than two font families or more than two hues besides neutrals? → cut down to the palette.
       - Does each text stay about 1 s per 4 words? Do stacked texts share an edge exactly (not 5 px off)?
       - Vertical video: is text clear of the bottom 14% and the right 12% of the lower half (app buttons)?

    LAYER
    Common: id, name, type ("rect" | "ellipse" | "path" | "text" | "image" | "video" | "audio" | "particles" | "generator" | "group" | "model" | "drawing"), start, end (seconds, end optional = scene end),
            x, y, scale, rotation (degrees), opacity (0..1)
    rect/ellipse: width, height, cornerRadius (rect), fill "#RRGGBB[AA]", stroke, strokeWidth (see STROKES for trim)
    path: any vector shape. d = the shape in layer px around the layer's x/y (0,0 in d is at x/y and is the pivot for
          rotation/scale): SVG path data, e.g. "M-200 0 C -100 -150, 100 -150, 200 0" (M L H V C S Q T A Z; uppercase
          absolute, lowercase relative), or a shape centered on 0,0: star(points,outer,inner[,rotation]),
          polygon(sides,radius[,rotation]), circle(r), ellipse(rx,ry), rect(w,h[,cornerRadius]).
          fill, stroke, strokeWidth, fillRule ("nonzero" | "evenodd": inner shapes become holes). A path with a stroke
          and no fill is a line (fill defaults to transparent then). To draw in scene coordinates use x 0, y 0.
          Keyframes on d MORPH from shape to shape: {"d":{"keyframes":[{"t":0,"v":"star(5,200,80)"},
          {"t":1,"v":"circle(160)","easing":"easeInOutCubic"}]}} (or set_keyframes with property "d"). Any two shapes
          morph; closed shapes with similar point counts morph most cleanly. loop works on "d" too.
    text: text (may contain \n), fontSize, fontName (a font family, e.g. "Be Vietnam Pro"; see FONTS; default the
          system font), fontWeight (thin|light|regular|medium|semibold|bold|heavy|black or 100–900; add " italic", e.g.
          "bold italic"), color, align (left|center|right), maxWidth (wraps), reveal (0..1 typewriter),
          letterSpacing (px), textAnimators (see TEXT ANIMATORS)
    image: path (absolute file path), width/height (optional; keeps aspect if only one is set)
    video: path = a movie file (.mov/.mp4/.m4v) or a FOLDER of numbered images (image sequence, e.g. a Blender render;
          frames in natural name order), width/height (as image), trimIn (source seconds skipped), speed (1 = normal),
          playback ("once": the layer ends with the clip, default | "hold": last frame stays | "loop": starts over),
          fps (image sequences only: frames per second of the images; set to the render's rate, Blender's default is 24).
          The movie's own sound plays at speed 1 (silent at other speeds); volume (animatable, 1 = original, 0 = mute).
          timeRemap: keyframes of the SOURCE second shown over scene time, replacing speed/trimIn (silent):
          {"keyframes":[{"t":0,"v":0},{"t":1,"v":1},{"t":1.5,"v":4,"easing":"easeInOut"},{"t":3,"v":4,"easing":"hold"},
          {"t":4,"v":2}]} = normal speed, a fast ramp through 3 seconds of footage, a 1.5 s freeze frame, then
          reverse. Flat segments freeze, steep ones speed up, decreasing ones play backwards. Mark the layer's end
          yourself (once-playback no longer ends it).
          frameBlend: "off" (default) | "blend" (cross-fades the two nearest source frames: smoother slow motion) |
          "flow" (optical flow in-betweens, the smoothest; slow, needs the app). Use with speed < 1 or timeRemap.
    removeBackground (image and video): "person" or "subject" cuts out the person / main subject with Vision (no
          green screen needed). Text BEHIND a person: the full video, then the text, then a copy of the video with
          removeBackground "person" on top. Works in the app (sandboxed CLIs lack the Vision entitlement).
          sourceDuration / transcript / words are filled in by the app.
    particles: see PARTICLES.
    generator: see GENERATORS.
    group: children (an array of layers, see GROUPS).
    model: a lit 3D object (box, sphere, extruded/beveled text, turned profile, an OBJ/USDZ file…), see 3D.
    Optional on every visual layer (omit when unused):
      scaleX, scaleY (multiply scale; flip effects), skewX, skewY (degrees), anchorX, anchorY (pivot for rotation/scale/
      skew as an offset from the center in layer px, e.g. anchorX = -width/2 spins around the left edge; does not move the
      layer), blur (px), shadowOpacity (0..1, shadow off when 0), shadowX, shadowY (px, default 0/8), shadowBlur (default 16),
      shadowColor ("#000000"), parent, motionPath, spatial, pathProgress, loop, wiggle, audioReact (see below),
      blendMode ("normal" | "add" | "screen" | "multiply" | "overlay" | "lighten" | "darken"; "add"/"screen" make dark
      areas see-through, e.g. fire or smoke footage on black),
      gradient (rect/ellipse/path/text), matte, repeater, motionBlur, motionBlurPhase, glow, glowRadius, glowColor, brightness, contrast,
      saturation, hue, tint, tintColor, wipe, wipeStyle, keyColor, keyTolerance, keySoftness, waveWarp, ripple,
      waveLength, waveSpeed, twirl, bulge, distortRadius, turbulence, posterize, pixelate, rgbSplit, glitch, grain,
      scanlines, vignette, directionalBlur, blurAngle, zoomBlur, posterizeTime (see AFTER EFFECTS-STYLE TOOLS),
      depth, fixed (see CAMERA), links (see LINKS), rotationX, rotationY, perspective, hideBackface, cornerPin, pins
      (see 2.5D AND WARPS), threeD, z (see 3D), levelsBlack, levelsWhite, levelsGamma, curves, gradientMap, gradientMapAmount, lut,
      lutAmount (see GRADING), removeBackground

    ANIMATION
    Every number above (x, y, z, scale, scaleX, scaleY, scaleZ, rotation, rotationX, rotationY, skewX, skewY, anchorX,
    anchorY, opacity,
    width, height, cornerRadius, strokeWidth, trim, trimStart, trimOffset, reveal, letterSpacing, blur, shadowX, shadowY,
    shadowBlur, shadowOpacity, glow, glowRadius, pathProgress, volume, emission, particleSpeed, particleSize, brightness,
    contrast, saturation, hue, tint, wipe and the stylize/distort/keying numbers below), the colors
    fill, stroke and color, and a path's d (shapes) can be a plain value or
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
      (default: the music layer). Negative amount pushes the other way. Works on every number property;
      keep it subtle (scale 0.05–0.2, x/y 10–30 px, rotation 2–5°).
    - parent: id of another layer. The layer then moves, rotates and scales with it, and its x/y become relative to the
      parent's center. Use set_parent to link without the layer jumping. Opacity and timing are not inherited.
    - motionPath: {"points":[[200,800],[960,300],[1700,800]],"smooth":true,"closed":false,"orient":false} — the layer's
      center follows the path (x/y are then ignored); animate pathProgress 0→1 to move along it at even speed;
      orient = true turns the layer to face the direction of travel.
    - spatial: {"smooth":true,"orient":false} (or just true) — the x/y keys become ONE path, like After Effects position
      keys: an auto-Bezier curve through the key positions (smooth false = straight lines), traveled by distance with
      each key's easing, so arcs and multi-point moves flow without kinks or speed wobble. Put x and y keys at the same
      times (the easing comes from the x key). Bend a segment with custom tangents (scene px, relative to the key):
      "handles":[{"t":1,"out":[200,0]},{"t":2,"in":[0,-150]}]. orient = auto-orient along the path. Recommended for
      any layer that moves through 3+ positions or should travel in an arc.

    STROKES (rect, ellipse, path)
    - Trim paths: trimStart and trim (= end), 0..1 along the outline, draw only part of the stroke; trimOffset slides
      that part along (1 = one full lap; it wraps around). Draw on: trim 0→1. Draw on then off: trim 0→1 and trimStart
      0→1 starting a bit later. Chasing dash on a ring: trimStart 0, trim 0.25, trimOffset 0→1 (linear) + loop offset.
      A path made of several pieces trims each piece on its own, unless trimSequential: true (pieces one after
      another: handwriting). Text → handwriting: text_to_path, then preset writeOn.
    - lineCap: butt | round | square (paths default round); lineJoin: miter | round | bevel (paths default round).

    AFTER EFFECTS-STYLE TOOLS
    - gradient (rect, ellipse, path, text; replaces fill / color):
        {"type":"linear","colors":["#FF6B6B","#FFD93D"],"angle":90}
      colors spread evenly, or "stops":[{"offset":0,"color":"#..."},{"offset":0.7,"color":"#..."}]. linear: angle in
      degrees (0 = left→right, 90 = top→bottom). radial: cx, cy (center as a fraction of the layer box, default 0.5) and
      radius (fraction of half its diagonal, default 1). conic: the colors sweep around cx/cy (angle = where the first
      stop starts; make the last color equal the first for a seamless wheel; animate shift 0 → 1 to spin it: loaders,
      pie-like rings, iridescent discs). angle, radius and shift are animatable. shift slides the colors
      along (radial: outward): a metallic shine sweeping over a title = colors ["#C9A227","#FFF6C8","#C9A227"] with shift
      keyframes -1 → 1.
    - matte (track matte): {"source":"shape-id","mode":"alpha"} (or just "shape-id") shows the layer only where the
      source layer is (alpha), where it is not (alphaInverted), or where it is bright (luma, lumaInverted). The source
      layer is no longer drawn on its own; animate it (position, scale, trim, d morph, text animators…) for wipes and
      reveals: text revealed by a sliding bar, a photo inside big text, an image in a growing circle, a title wiped
      away by a shape. Keep the source next to the layer in the list.
    - repeater: {"count":12,"rotation":30,"pivotY":200,"opacityEnd":0.3,"delay":0.05} draws count copies; copy i is
      moved by i steps of x/y (px), rotation (°) and scale (×) around the pivot (pivotX/pivotY = offset from the layer's
      position, e.g. the center of a ring); steps compound, so rotation + x makes a spiral. opacityEnd = opacity of the
      last copy; delay = seconds each copy lags behind (its keyframes and start), for cascades and echo trails.
      x/y/rotation/scale are animatable (a fan opening: rotation 0 → 15). Recipes: ring of 12 dots = a dot at the ring's
      top, rotation 30, pivotY = radius; row of bars = x 60; echo trail of a moving layer = count 6, delay 0.04,
      opacityEnd 0.1; burst of rays = a thin rect above the center, rotation 360/count, pivotY = its distance to the
      center. Variation per copy: colors ["#FF5A5F","#2EC4B6","#FFBF47"] cycles the fill (text: color) over the copies;
      randomX/randomY (px), randomRotation (± degrees), randomScale (± fraction) scatter each copy a little, fixed by
      seed (change it for another arrangement): confetti rings, hand-placed dot patterns, uneven rays.
    - motionBlur: shutter angle (180 = natural film blur, 360 = strong, 0 = off); fast moves, spins and zooms smear like
      a real camera. It renders the layer several times per frame (more the faster it moves), so use it on the few
      fast-moving layers. motionBlurPhase (degrees, default -motionBlur/2 = centered on the frame; 0 = the exposure starts at
      the frame, so the smear runs ahead; -motionBlur = it trails behind).
    - glow (strength 0..4, animatable), glowRadius (px, default 24), glowColor (optional tint): light around the layer —
      neon lines and logos, glowing text, light streaks. Best on bright layers over dark backgrounds.
    - Light (every visual layer): shine (strength 0..2) is a soft bright band across the layer, placed by
      shinePosition (-0.5 before the left edge .. 1.5 past the right; animate 0 → 1 for a sweep, e.g. over a logo or
      metallic title), shineAngle (default 30), shineWidth (px, default 120), shineColor. rays (strength 0..3)
      streaks light out of the layer's bright parts (raysLength 0..0.95, default 0.6): god rays behind a logo or
      text. outline (px) + outlineColor draws a band around the layer's shape (sticker look on cut-out images and
      text). innerGlow (strength) + innerGlowRadius (px) + innerGlowColor lights the inside of the edges.
    - Path operators (rect, ellipse, path; all animatable, 0 = off): offsetPath (px, grows/shrinks the outline),
      zigzag (amplitude px; ridges every waveLength/2 — seals, badges), wigglePath (amplitude px; organic blobs,
      hand-drawn wobble; evolves with waveSpeed, size waveLength/2), pucker (-1 bloat .. 1 pucker: stars from
      polygons), dash [on, off, …] (px) + dashOffset (px, animate with loop offset for marching ants), taperStart /
      taperEnd (0..1 of the stroke thinning to a point: brush strokes, swooshes; works with trim for a drawn-on
      tapered line).
    - Color correction (every visual layer, all animatable, 0 = unchanged): brightness (-1..1, adds light), contrast
      (-1 flat gray .. 1 double), saturation (-1 black and white .. 1 double), hue (degrees around the color wheel),
      tint (0..1) with tintColor (white by default): maps the layer's brightness onto one color (duotone look, a
      photo in brand color, black and white = tint 1). Use it to match footage and images to the palette, flash a
      layer (brightness 0 → 0.6 → 0 on a beat), fade to black and white, or cycle hues (hue 0 → 360 + loop offset).
    - wipe (0..1, animatable): transition that hides the layer, 0 = all of it shows, 1 = wiped away. Animate 1 → 0 to
      reveal, 0 → 1 to hide. Its shape is wipeStyle (or just the type name, e.g. "wipeStyle":"iris"):
        {"type":"linear","angle":180,"feather":40}
      type: linear (straight edge) | radial (clock hand around the center) | iris (circle closing on the center) |
      blinds (stripes) | blocks (random squares dissolve). angle: linear/blinds = direction the edge travels as wipe
      goes 0 → 1 (0 = rightward, 90 = down), so reveal left → right = angle 180 with wipe 1 → 0; radial = where the
      hand starts (0 = 12 o'clock). feather = soft edge in px (0 sharp; 30–80 looks smooth). count = stripes (blinds)
      or blocks across (blocks), default 8. reverse: radial turns counter-clockwise; iris opens a hole from the center
      instead; blocks drop in the opposite order (the complement of the same seed). seed reshuffles blocks. Iris reveal = type iris with wipe 1 → 0. Presets wipeIn / wipeOut animate it
      (soft left → right edge unless a wipeStyle is set). Wipes work in the layer's own space, so they turn and
      scale with it; unlike a matte they need no extra layer.
    - Stylize (every visual layer, animatable, 0 = off): pixelate (block size px; 40 → 0 = "depixelate" reveal),
      posterize (number of color levels, 2–8 for a poster/comic look), rgbSplit (px: red right, blue left, negative
      swaps; chromatic aberration), glitch (0..1: random bands jump sideways with split colors, new pattern ~12 times
      a second; keyframe short bursts, or use preset glitchBurst), grain (0..1 film grain, changes every frame),
      scanlines (0..1 CRT lines), vignette (0..1, darkens the layer's edges — use it on a full-frame image/video).
    - Blurs: directionalBlur (length px) along blurAngle (degrees, 0 = horizontal) for speed lines and whip
      transitions; zoomBlur (0..0.9) smears toward the layer's center (punch-in/zoom transitions). The plain blur
      property is a gaussian.
    - Distort (around the layer's position, in layer px): waveWarp (amplitude, a horizontal wave bending the layer up
      and down) and ripple (amplitude, rings from the center) share waveLength (default 120) and waveSpeed (cycles per
      second, default 1; 0 = still); twirl (degrees at the center, fading to 0 at distortRadius, default 300); bulge
      (-1 pinch .. 1 magnify, within distortRadius); turbulence (px of smooth noisy displacement, its size is
      waveLength, it flows with waveSpeed) for heat haze, water and liquid logos. Keyframe twirl 0 → 720 → 0 or
      bulge 0 → 0.8 for transitions; keep amplitudes small (5–30) on text.
    - Keying: keyColor ("#00B140") removes that color from the layer (green/blue screen footage or images) and
      suppresses its spill on edges; keyTolerance (default 0.2) = how far from the key color is still removed,
      keySoftness (default 0.1) = the soft range above it. Raise tolerance if the screen still shows, lower it if
      the subject gets holes.
    - posterizeTime (fps, not animatable): the layer's animation only updates that many times a second (8–12 =
      stop-motion / hand-made look), the rest of the scene stays smooth.
    - These effects work on the layer's pixels in a bitmap, so they cost more than shapes: use them on the layers
      that need them, and prefer small areas over full-frame layers when you stack several.
    - 2D layers draw in list order. For real depth (z, a camera that orbits and flies through, objects that hide each
      other, lit 3D objects), see 3D; for a cheap sense of depth, combine scale, blur and parallax.

    FONTS
    - fontName is a font family; fontWeight picks the closest face it has. Without fontName, text uses the system font
      (clean but plain): choose fonts that fit the piece's mood.
    - list_fonts shows the fonts you can use right away (asset-library fonts first, then fonts on this Mac) with their
      weights; query filters by name, vietnamese true keeps fonts with Vietnamese letters.
    - More fonts: search_stock kind "font" searches ~1,900 free Google Fonts by name, category (serif, sans, display,
      handwriting, mono) or mood (elegant, modern, playful, retro, tech, cute…), most popular first; the image shows
      each font. When the text is Vietnamese, ALWAYS pass vietnamese true (otherwise accents fall back to another font).
      import_stock the ref (every upright weight by default; "weights":["400","700","400i"] to choose), then use the
      family name as fontName. Imported fonts are files in the asset library (fonts/ in a project), so they travel
      with the project and render the same in preview and export.
    - Use 1–2 families per piece: e.g. a display or serif font for titles and a clean sans for the rest.
    - Variable fonts (one file with axes, e.g. Inter, Roboto Flex, Fraunces, Anybody, most Google Fonts): fontWeightAxis
      (wght, 100–900) and fontWidth (wdth, e.g. 75–125) are animatable: keyframe a title from thin to black, or from
      condensed to extended ("the letters breathe"). Other axes go in fontVariations {"slnt": -10, "opsz": 24}. Text
      animators can do it per character: {"unit":"char","fontWeightAxis":900,"fontWidth":125,...} takes each letter from
      the text's own axes to those values and back (mode in/out). The font must have the axis (import a variable font
      with import_stock; static families ignore the axes).
    - A font warning in a tool result means the name was not found or the font lacks some letters: fix it.

    TEXT EXTRAS
    - Counter: put "{n}" in the text and animate counter: {"text":"+{n}%","counter":{"keyframes":[{"t":0,"v":0},
      {"t":2,"v":42,"easing":"easeOutExpo"}]}} counts up (counterDecimals 0–6, counterGrouping true → "1,234").
    - scramble (0..1, animatable): that share of the letters shows as random characters flickering ~15 times a
      second; keyframe 1 → 0 (or preset decode) for a hacker/decode reveal; 0 → 0.3 → 0 for a glitchy flicker.
    - Outline: stroke (color) + strokeWidth (px) draw an outline around the letters (fill stays `color`; use
      color "#00000000" for outline-only text).
    - textPath: {"points":[[-500,120],[0,-60],[500,120]],"smooth":true,"closed":false} lays the text along a curve
      (layer px from the layer's center, y down; the baseline sits on the path, letters turn with it). align picks
      where it starts; textOffset (px, animatable) slides it along — on a closed circle with loop offset it spins
      forever. Text animators still work per character on a path.

    TEXT ANIMATORS (per character / word / line, staggered)
    "textAnimators":[{"unit":"char","mode":"in","start":0.5,"duration":0.5,"stagger":0.04,"order":"forward",
                      "easing":"easeOutBack","opacity":0,"y":40,"x":0,"scale":1,"rotation":0,"blur":0,"color":null}]
    - unit: char | word | line. mode: in (units arrive from the away state) | out (units leave to it).
    - opacity/x/y/scale/rotation/blur (px)/color describe the AWAY state (x/y in px, y down); units animate between
      it and normal. Presets: textBlurIn (letters sharpen in), textFocus (words land from a big blur).
    - Unit i starts at start + rank·stagger; order: forward | reverse | center | edges | random (seed).
    - Use one "in" and optionally one "out" animator. The text*/typewriter presets create them for you.

    PARTICLES (fire, smoke, dust, sparks, snow, rain, confetti, bokeh, magic trails, explosions, text breaking apart)
    {"id":"fire","type":"particles","x":960,"y":900,"width":220,"height":0,"blur":3,"particles":{"preset":"fire"}}
    - preset: fire | smoke | dust | sparks | snow | rain | confetti | bokeh | magic | explosion. Its values are the
      starting point; any field you set overrides it, e.g. {"preset":"snow","rate":80,"size":14}. A preset also picks
      blendMode (add for fire, sparks, magic, explosion, bokeh, dust) unless you set it.
    - The layer is the emitter: x/y place it, width/height size it, rotation turns the emission direction. Particles
      are born there and keep their own life, so a moving emitter (keyframes, motionPath) leaves a trail.
    - Sizing per preset: fire/smoke: a line ~10–15% of the scene wide at the base (y ~85%); snow/confetti/rain: a line
      wider than the scene just above the top (y -40); dust/bokeh: width/height = the whole scene, centered.
    - Fields (angles in degrees, 0 = right, 90 = down, -90 = up; px and seconds):
      emission: rate (per second), bursts [{"t":1.2,"count":300}] (all at once, explosions), prewarm (seconds simulated
        before the layer starts, so snow/dust are already there), lifetime, lifetimeRandom (0..1),
        emitter (point|line|rect|ellipse, sized by width/height), edge (outline only), seed (another random layout)
      motion: speed, speedRandom (0..1), direction, spread (cone width; 360 = every way), inherit (0..1 of the emitter's
        own velocity), gravity (px/s², negative rises), wind (px/s²), drag (1/s), turbulence (swirl strength px/s),
        turbulenceScale (swirl size px), turbulenceSpeed (how fast swirls change), floor (scene y to bounce on), bounce,
        friction
      look: shape (soft | circle | square | spark | image | confetti: paper strips, squares and dots), size (diameter px), sizeRandom, grow (size at death ×; 0 shrinks
        away, 3 spreads like smoke), streak (spark length in seconds of travel), trail (seconds of past path drawn
        as a fading ribbon: comets, light painting, magic wands; 0.2–0.8), orient (face direction of travel),
        angleRandom, spin (deg/s), spinRandom, flutter (flips/s, confetti), colors ["#FFE9A050","#FF541048",...]
        (gradient over the life; #RRGGBBAA alpha matters with add), colorMode (life | random: one color each),
        fadeIn, fadeOut (fractions of the life)
      space: world (default, trail stays behind) | local (particles move with the layer)
    - shape "image": the layer's path is the sprite (PNG with alpha, e.g. a smoke puff from search_stock); tint true paints
      it with colors.
    - from: another layer's id: particles are born on that layer instead: inside a text's letters (or on their
      outline with edge true), inside a rect/ellipse, or an image's frame. Text turning to dust: fade the text out
      quickly at T and add {"type":"particles","blendMode":"add","particles":{"from":"title","rate":0,
      "bursts":[{"t":T,"count":3000}],"size":5,"speed":60,"spread":90,"direction":-20,"turbulence":80,
      "turbulenceScale":120,"lifetime":2.5,"fadeOut":0.5}}. Text forming from sparkles: rate on, emission keyframes.
    - Animatable multipliers (read at each particle's birth): emission (×rate; keyframe to 0 to stop the flow; works
      with audioReact for particles on the beat), particleSpeed, particleSize.
    - The layer's end cuts every particle: to let them die out, set emission to 0 a lifetime before the end.
    - Cost: keep live particles under ~5000 (rate × lifetime + bursts). Large soft particles with add saturate to
      white: lower the colors' alpha or the rate rather than the size. A small blur (2–4) softens fire and smoke.

    CAMERA (scene-level pan, zoom and rotation with parallax)
    "camera": {"x":{"keyframes":[{"t":0,"v":960},{"t":4,"v":1400,"easing":"easeInOut"}]},"y":540,
               "zoom":{"keyframes":[{"t":0,"v":1},{"t":4,"v":1.6}]},"rotation":0,"wiggle":{"x":{"amount":6,"frequency":1.2}}}
    - x/y = the scene point shown at the frame's center (default the scene center), zoom (1 = as is, 2 = twice as
      close), rotation (degrees). All animatable; wiggle on x/y/zoom/rotation gives a handheld feel. Set it with
      update_scene {"changes":{"camera":{...}}} (null removes it). Every layer is framed by it: push in on a title,
      pan across a long layout, slow drift over a photo, a whip to the next section (fast x move + directionalBlur).
    - depth on a layer (default 0): how far it is. The camera's movement is divided by 1 + depth, so background
      layers with depth 1–3 drift slowly, foreground ones with depth -0.3…-0.6 rush past: parallax from one camera
      move. fixed: true keeps a layer where it is (captions, logos, HUDs).
    - World-space particles follow the camera like everything else; group children see no camera of their own.
    - Depth of field: camera focus (the depth in focus, default 0) and aperture (px of blur per unit of depth away
      from it, default 0 = off; 4–10 is cinematic). Rack focus = keyframe focus from one layer's depth to another's.
    - 3D layers (see 3D) also follow orbitX, orbitY, distance, lens and z on the camera; 2D layers ignore those.

    2.5D AND WARPS (every visual layer except particles; the layer is drawn flat, then warped)
    - rotationX (degrees, + tips the top back), rotationY (+ turns the right side back), perspective (viewing distance
      px, default 1200; smaller = stronger). Each 2D layer has its own perspective: for layers that must share one
      space (a cube of faces, cards around a carousel, a floor) or a moving camera, use 3D layers instead. Animatable: card flips, panels swinging in, a group (whole UI card)
      turning in 3D. Text: perspective makes letters lean and shrink unevenly, which reads as crooked, so do not put
      rotationX/Y on text (or on a group holding text) unless the user asks for a 3D/tilt look. Even then, make it a
      short entrance/exit that ends at 0 so text that stays on screen is flat, keep any held tilt under ~10°, and
      prefer turning the card behind the text. hideBackface: true hides the layer while it faces away (past 90°): a
      two-sided card = two layers at the same place, back one starting at rotationY 180, both animating +180.
      Cube-like transitions: the outgoing group rotationY 0 → -90 while the incoming goes 90 → 0.
    - cornerPin: {"tl":[x,y],"tr":[x,y],"br":[x,y],"bl":[x,y]} (layer px around its center) pins the layer's box
      corners there — a picture on a phone/laptop screen, a sign, a billboard; keyframe it like any value
      ({"keyframes":[{"t":0,"v":{"tl":…}}, …]}), or match a moving screen with track_motion samples.
    - pins: [{"x":-200,"y":-100},{"x":200,"y":100,"dx":{"keyframes":[…]},"dy":40}] puppet pins: each (x, y) point
      (layer px at rest) moves by (dx, dy) and the picture bends around them (rigid-as-possible); pins that do not
      move hold their part. Waving flags, a character's arm, a logo that bends and springs back.
    - Every effect still applies after the warp (blur, shadow, glow, wipe…); the warp itself costs about a dozen
      image draws, so keep it to the layers that need it.

    GRADING (every visual layer; applied after brightness/contrast/saturation/hue/tint)
    - levelsBlack / levelsWhite (input points 0..1) and levelsGamma (default 1; >1 brighter mids).
    - curves: [[0,0],[0.25,0.18],[0.75,0.85],[1,1]] a smooth master tone curve (this one = S-curve contrast; lift
      [0,0.1] for a faded film look).
    - gradientMap: ["#1B0F3A","#E8436A","#FFE7A8"] maps brightness from shadows to highlights onto these colors
      (duotone, tritone, neon looks); gradientMapAmount (0..1, default 1) mixes it in.
    - lut: a .cube 3D LUT file (asset name or path; import it with import_asset), lutAmount (0..1, default 1).

    GROUPS (precomps)
    {"id":"card","type":"group","x":960,"y":540,"children":[{...layer...},{...layer...}]}
    - A group draws its children in a box (the scene size unless width/height are set) centered on x/y; children use
      coordinates inside that box like in a scene (a child at 960,540 sits at the group's center in a 1920x1080
      scene) and scene times. Children can parent and matte each other (ids are unique scene-wide); the group itself
      takes every layer property and effect at once: scale/rotate/move the whole card, opacity, blur, glow, wipe,
      color correction, repeater, matte, motionBlur. group_layers wraps existing layers; ungroup unwraps.
    - Tools address children by id as usual (update_layer, set_keyframes, apply_preset); add or remove children
      through update_layer on the group with a full "children" array.

    LINKS (one property follows another layer's, like After Effects expressions)
    "links":{"y":{"layer":"lead","property":"y","multiply":1,"add":80,"delay":0.1}}
    - value = source × multiply + add, read delay seconds later (follow-through, trails: a chain of layers each
      delayed a little more). The linked property's own keyframes are ignored; its wiggle/audioReact still add.
      Any number property can follow any other (rotation ← x × 0.2 for a rolling wheel, scale ← opacity, width of
      a bar ← audio-reacting value of another layer). One hop: a source that is itself linked gives its own
      keyframes, not its link.

    GENERATORS (music visualizers, audiograms, fractal noise, lightning, grids)
    {"id":"viz","type":"generator","generator":{"kind":"spectrum","shape":"bars","count":48},"x":960,"y":820,
     "width":1300,"height":260,"fill":"#4FD1C5","cornerRadius":4}
    - The layer draws in its width × height box (centered on x/y) with its fill color, or gradient (e.g. a gradient
      across a spectrum). Every layer property and effect applies: glow on a spectrum or lightning, blur on noise,
      matte, wipe, color correction.
    - kind spectrum: bars following the music's frequencies (low on the left). kind waveform: the loudness of the
      last `window` seconds (default 4), newest on the right — an audiogram for podcasts and voice clips. Both:
      source = audio layer id (default: the music layer, else the first audio layer); shape bars | line | circle (a
      ring of bars around the center, for logos in the middle); count (bars or points; spectrum 48, waveform 64);
      mirror (bars/line grow both ways from the middle; waveform default true); gain (× the values, default 1).
      Line thickness = strokeWidth (default 4); bar rounding = cornerRadius. They read 0 while the audio is silent.
    - kind noise: fractal noise filling the box. scale = feature size px (default 200), detail = octaves (1–8,
      default 4), speed = how fast it evolves (default 0.3; 0 = still), colors = low → high values (default black →
      white, e.g. ["#0B1026","#3B2C85","#F0A6CA"] for a nebula), seed. Use for smoke, clouds, textured or animated
      backgrounds, and as a luma matte for organic reveals (matte mode "luma" + animate brightness/contrast).
    - kind lightning: a bolt with `detail` branches (default 2) between from and to ({"x":..,"y":..} in layer px from
      x/y; default the left and right edges of the box), re-striking `speed` times a second (default 12; 0 = frozen).
      scale = how far it strays (default 15% of its length); strokeWidth = core width (default 4). Add glow 1–2 with
      a blue glowColor, and flicker opacity or the layer's timing for strikes.
    - kind grid: lines every `scale` px (default 80), strokeWidth wide (default 2), scrolling `speed` px/s (default 0).
      For a retro horizon, put it on a wide layer and skewX / scaleY it.
    - kind chart: {"kind":"chart","chart":"bar","values":[12,30,18,42],"labels":["Q1","Q2","Q3","Q4"],
      "colors":["#4FD1C5","#FFD93D","#FF6B6B","#A78BFA"]} — chart: bar | line | area | pie | donut. Animate the
      layer's reveal 0 → 1 to grow it in (bars one by one, line drawn on, pie swept). Colors cycle per bar/slice
      (line/area use the first); fill is used without colors. cornerRadius rounds bars, strokeWidth is the line
      width; labels use the layer's fontSize/fontWeight/fontName and color. Data videos: pair with a counter text.
    - kind flare: a lens flare. from = light position in layer px from the center (default the center),
      scale = size px (default a quarter of the box), gain = brightness, detail = number of ghost discs (default 5),
      colors = [core, ghosts]. Animate x/y (or from) to sweep it across; use blendMode add over footage.
    - seed (all kinds) gives another random pattern.

    3D (a shared 3D space with a real camera, and lit 3D objects)
    - threeD: true puts a layer (any visual type but particles) in the scene's 3D space. z (px, + = away from the
      viewer, - = closer; animatable) places it in depth; rotationX / rotationY / rotation turn it in 3D around its
      anchor (+X tips the top back, +Y turns the right side back), all seen through the scene camera with ONE shared
      perspective (`perspective` is ignored). With the default camera a 3D layer at z 0 looks exactly like its 2D
      self, so a scene can be made 3D step by step.
    - 3D layers are drawn far to near and hide each other per pixel (intersections, a floor under cards, walls), so
      their order in the list does not matter. A 2D layer between them splits them into separate groups that do
      not hide each other (it is drawn in list order, like in After Effects): keep backgrounds and HUD/captions 2D
      at the bottom/top of the list. Layers with blur or pixel effects are sorted but do not hide others per pixel.
    - Camera for 3D layers (with or without a "camera" object): the default camera looks at the frame's center from
      `distance` = the lens (the longer side of the frame in px). camera fields: orbitY (degrees; the camera circles
      to the right of the scene), orbitX (degrees; it rises and looks down), distance (px from the point it looks at:
      smaller = a dolly in), lens (focal length px: longer = flatter, shorter = wide angle), z (depth of the point it
      looks at: animate it to fly forward through layers spread along z), plus x, y, zoom, rotation as for 2D. All
      animatable and wiggle-able. A slow orbitY of 15–30° is the classic "3D parallax" move; orbit + z fly-throughs
      for title sequences. Depth of field uses real distances: focus 0 = the camera's distance, 1 = twice as far.
    - Groups: a group with threeD: true whose children have threeD: true keeps them in 3D: x/y are in the group's box,
      z is relative to the group, and they sort by depth with each other — build a cube, a room, a carousel, then
      turn it as one (rotationY on the group). The group's opacity and blend mode apply; its other effects do not.
      A 3D group without 3D children is one flat card turning in 3D. parent also chains 3D transforms (the parent
      must be threeD too; a rect with opacity 0 makes a rig).
      Cube of side W from rect faces in a threeD group with width = height = W, all children threeD, all W×W:
      front {"x":W/2,"y":W/2,"z":-W/2}, back z:+W/2, left {"x":0,"y":W/2,"rotationY":90}, right {"x":W,"y":W/2,
      "rotationY":90}, top {"x":W/2,"y":0,"rotationX":90}, bottom {"x":W/2,"y":W,"rotationX":90}.
    - hideBackface hides a 3D layer while its back faces the camera (two-sided cards). wipe works on the layer's
      plane; blur, shadow, glow, color correction and mattes still apply.
    - model layers are real, lit 3D objects (always 3D: z, rotationX/Y, rotation, scale, scaleZ, parent, presets
      and every effect work):
      {"id":"logo3d","type":"model","model":{"shape":"text","depth":60,"sideColor":"#B7791F","shininess":0.5},
       "text":"VEY","fontSize":220,"fontWeight":"black","fill":"#FFD54A","x":960,"y":540,"rotationY":-20}
      model.shape: box (width × height × model.depth, default depth = the smaller side) | sphere (width × height ×
      depth, default depth = width) | cylinder, cone (upright: width = diameter, height; cone model.radius = top
      radius 0..1, default 0) | torus (a ring facing the viewer; width = outer diameter, model.radius = tube 0..1,
      default 0.3) | plane | text (extruded letters: text, fontName, fontWeight, fontSize, align, maxWidth; depth
      default 0.3 × fontSize) | path (extrudes d like a path layer, fillRule respected; depth default 40) | lathe
      (turns the profile d around the vertical axis through the layer's center: x = distance from the axis, y =
      height, both in px around the center; open or closed subpaths; start/end a profile at x 0 to close it; vases,
      bottles, cups, chess pieces, lamps, rockets, bowls, columns, spinning tops) | file (path = a model file: .obj
      with its .mtl colors/textures, .stl, or .glb/.gltf with base colors/textures (not Draco-compressed);
      .usdz/.usd/.ply load only in the app; scaled so its largest side =
      width, default 400; import it with import_asset first). Animated .glb/.gltf (rigged characters, skinning and
      node animation) play a clip from the layer's start: model.animation = clip name or number (default the
      first clip; "none" = the rest pose), model.animationSpeed (default 1, negative = backwards),
      model.animationOffset (seconds into the clip at the layer's start), model.animationLoop (default true; false
      holds the last pose). add_layer/update_layer list the file's clips. Size and place come from the rest pose.
      Lathe vase, 300 px tall, open at the top: "model":{"shape":"lathe","segments":64},"d":"M0 150 L60 150
      C110 125 125 40 90 -20 C60 -70 35 -95 48 -150". A wine glass: foot + stem + bowl in one profile from x 0 at
      the bottom to the rim at the top. A closed subpath away from the axis makes a ring (a donut, a tire).
      model.bevel (text, path) = rounded edge size in px (logo/title look: 3–8% of fontSize; kept within half the
      depth and the thinnest stroke); model.bevelSteps 1 = a flat chamfer, default 3 = round. The bevel takes the
      fill color, the walls between take sideColor: gold text with bevel 8 and a dark sideColor reads as polished.
      fill = the color (animatable); model.sideColor = extrusion walls, box sides and cylinder/cone caps (default
      fill; a darker shade reads best); model.shininess 0..1 (default 0.3); model.metallic 0..1 (1 = metal: chrome
      with a light gray fill, gold with #E0B94F); model.segments = roundness (default 48; 6–10 = a low-poly gem);
      path on box/sphere/cylinder/plane/lathe = an image texture (a planet map on a sphere, a label around a can).
    - Designing objects: build them from parts in a threeD group (each part a model layer with its own color and
      material: a rocket = lathe body + extruded path fins + cylinder nozzle; a tree = cone + cylinder; a robot =
      boxes + spheres), then animate the group as one and the parts on their own (propellers spinning, a lid
      opening). For any shape these cannot make (terrain, crystals, low-poly animals, gears, stairs, twisted
      forms), compute the mesh yourself and write it as an OBJ with write_asset, then use it as a file model:
      write_asset {"name":"gem.obj","folder":"models","overwrite":true,"text":"mtllib gem.mtl\nv 0 1 0\n
      v 0.5 0 0.5\n...\nusemtl blue\nf 1 2 3\n..."} and {"name":"gem.mtl","folder":"models","overwrite":true,
      "text":"newmtl blue\nKd 0.2 0.5 1\n"}, then add_layer {"type":"model","model":{"shape":"file"},
      "path":"<the returned path of gem.obj>","width":400}. OBJ rules: y up, z toward the viewer (it is turned to
      the scene's axes and centered for you), any units (scaled so its largest side = width); faces are 1-based
      vertex indices, 3 or more per face (polygons are fanned); "vn" normals are optional (without them flat faces
      stay sharp and gentle bends under 40° shade smooth); "usemtl" switches the color for the faces after it
      (Kd r g b 0..1, d = opacity). Keep it under ~50k triangles (CPU renderer). Write the .obj and .mtl to the same
      folder with overwrite true so mtllib finds it; faces without a material take the fill color.
    - lights (scene level, for models): "lights":[{"type":"ambient","intensity":0.3},
      {"type":"directional","x":0.4,"y":0.6,"z":1,"intensity":0.8},
      {"type":"point","x":960,"y":200,"z":-600,"color":"#FFB86B","intensity":0.6}]
      directional x/y/z = the direction the light travels (y down, z away: 0.4, 0.6, 1 comes from the upper left, in
      front of the scene); point x/y/z = its position in scene px. intensity is animatable (flicker, light-up
      moments). Without lights a soft default rig is used. Set them with update_scene {"changes":{"lights":[...]}}.
    - Presets for 3D: turntable (one full turn on rotationY; add loop {"rotationY":"offset"} to keep spinning),
      swingIn, swingOut (90° turns with a fade).
    - Readability: text that must be read should face the camera at rest; make big 3D moves entrances/exits or keep
      orbits gentle. Always render_frame a few times of a 3D shot to check depth order and framing.
    - Footage rendered in Blender (or any 3D app) still works too: a PNG sequence with alpha or a ProRes 4444 .mov
      as a video layer.

    FLAT-DESIGN AND PRINT LOOKS
    - longShadow (px) + longShadowAngle (degrees, 45 = down-right) + longShadowColor: a hard-edged shadow cast across the
      scene from text, shapes, icons (flat design, posters). Use a darker tone of the background as the color.
    - textHighlights (text layers): [{"word":"key word","color":"#FFE600","start":1.2,"duration":0.4,"skew":-8,
      "padding":6,"radius":6,"all":false}] draws a marker band behind that word (first occurrence, or every one with
      all), swept in from the left from `start` (omit start = always on). The band sits behind the letters and follows
      line breaks.
    - halftone (dot cell px, 6–20): the layer as a grid of ink dots, bigger where it is darker (newspaper, comic,
      risograph). Combine with posterize, grain and a paper-colored background; rgbSplit 2–3 for misregistration.
    - goo (px, 20–60) on a group: its children are blurred and re-sharpened so overlapping shapes fuse like liquid
      (metaballs, drops splitting, blobs merging, gooey menus). Keep the group at the frame center (its box is the
      frame) and animate the children's x/y/scale; add particles with big soft shapes inside the group for drips.
    - transition types circle / shape: the new scene grows out of a point (x, y; default the center) as a circle or any
      path d ("star(5,1,0.5)", "M…") until it fills the frame — works through a copy of each layer with a matte, so
      the originals are untouched outside the transition. match: a match cut, the incoming layer starts where the
      outgoing one is (position, scale, rotation) and both glide to the incoming one's place.

    RIGS (bones + IK) AND FRAME-BY-FRAME DRAWING
    - A rig is a list of bones in the scene ("bones": [{"id":"arm","x":900,"y":500,"length":180,"angle":20},
      {"id":"forearm","parent":"arm","length":160,"angle":40,"minAngle":0,"maxAngle":150}]; set_bones adds them).
      A child bone starts at its parent's tip; its angle is relative to the parent. Layers hang on a bone with
      bind_bone (or "bone":"forearm" in their JSON: x/y/rotation are then in the bone's space, 0,0 = the bone's start,
      x along the bone). Animate with pose_bones (FK: angles at times) or solve_ik (the tip of a chain reaches a
      point). Workflow for a character: import_vector its SVG (parts as layers) → set_bones along the limbs → bind
      each part to its bone at time 0 → pose. Parts that should not bend (a head) just bind to the body bone.
    - "drawing" layers are hand-drawn, frame by frame: {"type":"drawing","x":960,"y":540,"drawing":{"fps":12,"loop":true,
      "frames":[{"hold":2,"strokes":[{"d":"M-80 40 Q 0 -80 80 40","stroke":"#111111","strokeWidth":8}]}, …]}}; draw_frame
      appends/replaces frames. Strokes are path data in layer px (round caps). Use 3–6 frames of slightly different
      lines for a boiling/wobbly outline, smear frames under a fast move, ink splashes, scribbled emphasis; hold 2
      for the classic look. Everything else (position keyframes, effects, bones) applies to the layer as a whole.
    - Groups with "localTime": true count their children's times from the group's start: keyframes at t 0 inside
      the group happen when the group starts, so a section built once can be moved by changing the group's start
      (and duplicated with timeOffset). audioReact and spectrum/waveform generators inside still follow the music at
      scene time, so they stay on the beat wherever the group starts.

    SECONDARY MOTION (automatic follow-through)
    - inertia (0…1): after a keyframed move, turn or scale stops (or changes speed abruptly), the layer overshoots and
      wobbles back for about a second (2.5 Hz, damped). 0.3 = subtle, 1 = cartoon. Works with any easing; the whole
      thing is deterministic, so every frame renders alone.
    - squash (0…1): while the layer moves, it stretches along its velocity and squeezes across it (squash & stretch);
      1 at 1000 px/s ≈ 1.5× long. Use with inertia on bouncing balls, jumping characters, logos that land.

    AUDIO
    audio layers: type "audio", path, start, end (optional; default = end of file), role ("voice"|"music"|"sfx"),
          volume (animatable, 1 = original), trimIn, fadeIn, fadeOut, duckTo (music: level while a voice speaks).
          Audio layers are not drawn. sourceDuration / transcript / words are filled in by the app.
    - Narrated video: write the script per section, then generate_voice once per section with start = section start.
      Use the returned duration to size each section (leave ~0.3–0.6s of air between sections) and the word times
      to make key text/visuals appear as they are spoken. Extend the scene duration if the narration is longer.
    - Vietnamese narration: use engine "vieneu" (list_voices engine "vieneu" for voice ids such as "Ngọc Lan"); it
      sounds far more natural than macOS voices. Its word times are estimated. If it fails because the TTS server is
      not running, tell the user and fall back to engine "macos".
    - Captions: add_captions on each voice layer when the user wants subtitles.
    - Subtitles for recorded speech (a video or audio layer, e.g. Vietnamese subtitles for a foreign video): call
      transcribe with the spoken language (e.g. "en-US", "ja-JP", "zh-CN"; Apple speech recognition, may take a minute
      or more for long media, so give the command a long timeout), then add_captions on the same layer; it lists the
      numbered captions with times. To translate, call set_caption_texts with the translated lines in the same order
      (batches with `from` for long lists; keep each line about as short as the original so it fits one line).
      Check the result with render_frame. Recognition makes mistakes: fix obvious ones while translating.
    - Music: add_audio with role "music", duckTo ≈ 0.25 and a fadeOut of 1–2s at the end.
    - Cut to the music: call analyze_audio once the music layer is in (it returns scene times). Start entrances and
      scene changes on downbeats, land keyframes and apply_preset starts on beats (e.g. a list item per beat), and
      put the biggest moment on the loudest part or a strong onset. For continuous motion with the music use
      audioReact (e.g. a logo pulsing on bass, a background breathing with level).

    SOUND EFFECTS
    A sound effect sells a motion only if it matches it in kind, length and timing. Add sound effects after the visuals
    are timed, and only where the user wants sound design (or the piece clearly calls for it).
    - Match the motion (motion → sound): slide/fly-in or camera move → whoosh (duration ≈ the move); quick flick, small
      element in, fast cut → swoosh; scale-in/appear → pop (blip for UI-like elements); button press, cursor, snap into
      place → click; counter steps, list items, checkboxes → tick (or click); success, check mark, key number → ding;
      reveal, achievement, happy ending → chime; shine sweep, magic, stars → sparkle; build-up before a reveal → riser
      ending exactly on the reveal; title slam, logo landing, beat drop → impact (subtle landing → thud); exit, error,
      things falling → drop; glitch transition → glitch; typewriter text → typing over the typing time.
    - Timing is where it goes wrong: the sound's peak must land on the frame where the motion peaks, not where the
      layer starts. Whoosh: peak at the middle/fastest point of the move, so it starts before the move. Impact, pop,
      click, thud: on the frame the thing lands or reaches full size (for a popIn preset, ~0.1–0.2 s after its start).
      Riser: ends on the reveal. Pass hitAt (scene time of that frame) to generate_sfx or add_audio and the tool does
      the math (skips leading silence, starts early). Never just put start = the visual's start.
    - Default to generate_sfx for every kind it has (whoosh, swoosh, pop, blip, click, tick, ding, chime, sparkle,
      riser, impact, thud, drop, glitch, typing), also when reworking a scene that already uses stock effects: it is
      made to measure (duration = the move, direction "left"/"right" pans a whoosh with the
      motion, pitch < 1 for bigger/heavier objects and > 1 for small/light ones, count for repeated ticks/clicks) and
      knows its exact hit. Vary `variant` (or pitch slightly) when the same sound repeats so it does not sound
      copy-pasted. Use search_stock kind "sound" for real-world sounds the synth cannot make (applause, camera shutter,
      door, crowd, nature, specific objects).
    - Picking a stock sound: search_stock lists each sound's shape (hit / whoosh / riser / sustained / multiple), peak,
      tags and a waveform image. Choose a single clear shape that fits the motion and a length close to it; avoid
      "sustained" (beds, loops) for one-shots and "multiple" files unless you pass hit to pick one of their sounds.
      Read the tags, not only the title. If nothing fits, try a different word (e.g. "swipe", "swish", "air pass" for
      whoosh; "bubble pop", "plop" for pop; "hit", "boom", "slam" for impact) before settling.
    - Mix: sound effects sit under the voice: volume ~0.4–0.7 (impact/riser ~0.6–0.8, ticks/clicks ~0.3–0.5); keep at
      most one effect per moment and leave quiet stretches; do not put a sound on every element of a stagger (one for
      the group, or soft ticks with count). With music, small effects can be dropped entirely.
    - Sustained sounds (shape "sustained": shimmers, ambiences, loops) have no accent: never place them with hitAt as
      a hit. Use them only as short beds under a moment (end + fadeIn/fadeOut), and check their level (quiet files
      need more volume).
    - Reporting: you cannot hear, but you do know each sound's shape, peak and placement, so do not open with a
      general "I can't hear audio" disclaimer. Say what you checked (kind matches the motion, peak lands on the frame)
      and name only the specific sounds the user should audition: stock sounds picked by title/tags, sustained ones,
      or any whose shape did not clearly match. Synthesized effects need no such note beyond a one-line "listen and
      tell me what to change".

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
    - Stock video (B-roll backgrounds, city/nature/people shots): search_stock kind "video" (Pexels + Pixabay, no credit
      needed; orientation "portrait" for 9:16), look at the numbered preview (first frames), import_stock the ref, then
      add_layer type "video" with the returned path, sized to cover the frame. Set maxDuration ≥ the time it must cover
      or use playback "loop"; mute it (volume 0) under music or a voice-over. Needs the VeyMotion server: if the search
      says it is unreachable or not configured, tell the user rather than retrying.
    - Photos: size them to cover the frame (set width = scene width, or height = scene height) when used as backgrounds,
      and dim them with a semi-transparent rect on top if text sits over them.
    - Background music: search_stock kind "music" with a mood/genre (e.g. "calm piano", "upbeat corporate", "cinematic").
      Prefer a track at least as long as the scene; import_stock it, then add_audio with role "music", start 0,
      end = scene duration, volume ~0.6, fadeIn 0.5, fadeOut 1.5, and duckTo ~0.25 if there is a voice-over.
    - Sound effects: see SOUND EFFECTS (generate_sfx first; search_stock kind "sound" for real-world sounds, then
      import_stock and add_audio with role "sfx" and hitAt).
    - Some licenses (CC BY, CC BY-SA) require credit. When you used such assets, call get_credits and tell the user,
      or add a small credits text at the end if they want it in the video.

    WORKFLOW TIPS
    - Start every new composition with the LOOK & DESIGN rules above: set_scene with the settings and content, then
      apply_look (or your own background/finish layers), then check the list at the end of that section.
    - For a short piece (up to ~15 layers), build it in one set_scene call, then refine with update_layer / set_keyframes.
    - For a longer piece, plan it as time sections (e.g. 0–8s intro, 8–20s concept 1, …). Call set_scene with the
      settings and the first section, then add_layers once per section. Give each section's layers start/end so the
      scene stays light. Keep every call's arguments under ~6 KB: very large calls are slow to write and may be rejected.
    - ALWAYS check visually before saying you are done: check_design, then render_frame at each time it lists (one per
      section, full size) and fix what looks wrong. After a small edit, the frames of the sections you touched are enough.
    - Stagger entrances by 0.1–0.2s, use easeOut for entrances and easeIn for exits, keep text inside a safe margin
      (~80px from edges), and give the viewer time to read (about 1s per 4 words).
    - duplicate_layer makes rows/rings/copies (with offsets and a time offset per copy) in one call; shift_time makes
      room in the timeline when a section gets longer (everything after `from` moves, later keyframes included);
      remove_layer / add_layer {group} / reorder_layer work on a group's children by id.
    - render_frames {times:[…]} shows up to 24 frames in one contact sheet: check pacing of a whole piece in one look
      (not detail: use render_frame for that).
    - import_vector turns an SVG (asset or file) into a group of path layers, one per shape: animate the parts of an
      illustration or character separately (set_parent them to a body part, or rig them with bones). It is the
      default way to put a recognizable object on screen (see Illustrations in LOOK & DESIGN).
    - apply_preset is a quick way to add common entrances/exits/emphasis; pass `ids` + `stagger` to cascade one preset
      over several layers (e.g. list items 0.12s apart). Combine with easings like easeOutBack / easeOutExpo for polish,
      and use loop/wiggle for ambient motion (floating shapes, subtle drift).
    - For motion-design polish, layer techniques: a logo outline drawn on with trim + glow, then filled; titles revealed
      through a matte; repeaters for bursts, rings and trails; shape morphs between scenes; motionBlur on fast moves;
      gradients instead of flat fills. Check fast moments with render_frame at several close times.
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
        "description": "Replace the entire scene. Use this to build a new composition in one step. See the server instructions for the format. When the scene's background is one flat color, a look is applied automatically (`look` auto): pass a look kind to choose it, or \"none\" to keep the scene exactly as given. The result includes a design check: fix what it lists before you finish.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "scene": { "type": "object", "description": "Full scene JSON: width, height, fps, duration, background, layers." },
            "look": { "type": "string", "enum": ["auto", "none", "cinematic", "clean", "neon", "retro", "sunset", "studio"], "default": "auto" }
          },
          "required": ["scene"]
        }
      },
      {
        "name": "check_design",
        "description": "Lints the scene for what makes a video look like a draft: flat background, pure white on pure black, system font, no type hierarchy, layers without shadow/glow/gradient, stretches where nothing moves or nothing but the background is on screen, text within 80 px of the edge or melted by a goo group, long shadows that stop inside the frame, illustrations made of bare polygons, overshoot easing on most layers, linear entrances, and (hint) only text and boxes; and for what makes it look machine-made: one entrance used on nearly every layer, five or more layers making the same move at the same instant, more than 3 font families, 6+ unrelated hues, text shown under 0.2 s per word, text with too little contrast against the pixels behind it or over a busy picture (measured in small renders), texts overlapping, stacked texts 3–8 px off each other's edge, and text under the app buttons of a vertical video. Returns findings with a fix for each, then one time per section: render_frame each of them at full size and look, because the lint cannot see whether a drawing looks right. Run it before you say you are done; fix errors and warnings (or tell the user why one is intended).",
        "inputSchema": { "type": "object", "properties": {} }
      },
      {
        "name": "update_scene",
        "description": "Change scene settings (width, height, fps, duration, background, camera, lights) without touching layers.",
        "inputSchema": {
          "type": "object",
          "properties": { "changes": { "type": "object", "description": "e.g. {\"duration\": 8, \"background\": \"#000000\"}" } },
          "required": ["changes"]
        }
      },
      {
        "name": "add_layer",
        "description": "Add one layer on top of the others (or at `index`, 0 = bottom), or inside a group (`group` = its id). Returns the final layer id.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "layer": { "type": "object", "description": "Layer JSON; `type` is required. Missing fields use defaults." },
            "index": { "type": "integer" },
            "group": { "type": "string", "description": "Id of a group layer to add the layer into (children use scene coordinates)." }
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
        "description": "Delete a layer (top-level or a group's child).",
        "inputSchema": { "type": "object", "properties": { "id": { "type": "string" } }, "required": ["id"] }
      },
      {
        "name": "reorder_layer",
        "description": "Move a layer to a draw-order index among its siblings (0 = bottom; inside its group for a child).",
        "inputSchema": {
          "type": "object",
          "properties": { "id": { "type": "string" }, "index": { "type": "integer" } },
          "required": ["id", "index"]
        }
      },
      {
        "name": "duplicate_layer",
        "description": "Copies a layer (with all its keyframes; a group with its children) `count` times right above it, each copy moved by offsetX/offsetY px and timeOffset seconds more than the previous one. Ids: `ids`, else <id>-2, <id>-3… Use it for rows of stars, speed lines, rings, repeated cards; then update_layer the copies that differ.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "count": { "type": "integer", "default": 1 },
            "offsetX": { "type": "number", "default": 0 },
            "offsetY": { "type": "number", "default": 0 },
            "timeOffset": { "type": "number", "default": 0, "description": "Seconds each copy starts later (start, end and every keyframe)." },
            "ids": { "type": "array", "items": { "type": "string" }, "description": "Ids for the copies, in order." }
          },
          "required": ["id"]
        }
      },
      {
        "name": "shift_time",
        "description": "Makes room in the timeline (or closes a gap): everything at or after `from` moves by `by` seconds. Layers starting at/after `from` move whole (start, end, keyframes, children, animators); layers spanning `from` keep their start, their later keyframes move and their end grows; the camera's later keyframes move; the scene duration changes by the same amount (extendDuration false keeps it). Use it to lengthen a section without re-keying every later scene.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "from": { "type": "number", "description": "Seconds." },
            "by": { "type": "number", "description": "Seconds, negative to pull later content earlier (never before `from`)." },
            "extendDuration": { "type": "boolean", "default": true }
          },
          "required": ["from", "by"]
        }
      },
      {
        "name": "set_keyframes",
        "description": "Replace all keyframes of one property (numbers, the colors fill/stroke/color, or a path layer's shape d, which morphs). An empty list makes the property constant.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "property": { "type": "string", "enum": ["counter", "scramble", "textOffset", "timeRemap", "rotationX", "rotationY", "perspective", "z", "scaleZ", "levelsBlack", "levelsWhite", "levelsGamma", "gradientMapAmount", "lutAmount", "fontWeightAxis", "fontWidth", "longShadow", "longShadowAngle", "goo", "halftone", "inertia", "squash", "x", "y", "scale", "scaleX", "scaleY", "rotation", "skewX", "skewY", "anchorX", "anchorY", "opacity", "width", "height", "cornerRadius", "strokeWidth", "trim", "trimStart", "trimOffset", "reveal", "letterSpacing", "blur", "shadowX", "shadowY", "shadowBlur", "shadowOpacity", "glow", "glowRadius", "pathProgress", "volume", "emission", "particleSpeed", "particleSize", "brightness", "contrast", "saturation", "hue", "tint", "wipe", "keyTolerance", "keySoftness", "waveWarp", "ripple", "waveLength", "waveSpeed", "twirl", "bulge", "distortRadius", "turbulence", "posterize", "pixelate", "rgbSplit", "glitch", "grain", "scanlines", "vignette", "directionalBlur", "blurAngle", "zoomBlur", "fill", "stroke", "color", "d"] },
            "keyframes": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": { "t": { "type": "number" }, "v": { "type": ["number", "string"], "description": "Number, \"#RRGGBB[AA]\" for fill/stroke/color, or a shape (SVG path data or e.g. \"star(5,200,80)\") for d." }, "easing": { "type": "string" } },
                "required": ["t", "v"]
              }
            }
          },
          "required": ["id", "property", "keyframes"]
        }
      },
      {
        "name": "apply_preset",
        "description": "Add a ready-made animation to one or more layers between start and start+duration. The layer's current values are the resting state. With several ids, each starts `stagger` seconds after the previous; layers the preset doesn't apply to are skipped. text* presets animate each letter/word/line; drawOn traces a shape's or path's outline.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "ids": { "type": "array", "items": { "type": "string" }, "description": "Several layers, in cascade order." },
            "preset": { "type": "string", "enum": ["fadeIn", "slideUp", "slideDown", "slideInLeft", "slideInRight", "popIn", "zoomIn", "blurIn", "bounceIn", "dropIn", "flipIn", "rotateIn", "wipeIn", "swingIn", "fadeOut", "slideOutUp", "slideOutDown", "slideOutLeft", "slideOutRight", "popOut", "zoomOut", "blurOut", "flipOut", "wipeOut", "swingOut", "spin", "pulse", "heartbeat", "shake", "wobble", "jello", "glitchBurst", "turntable", "drawOn", "writeOn", "typewriter", "textRise", "textPop", "textDrop", "textLines", "textOut", "decode", "textBlurIn", "textFocus"] },
            "start": { "type": "number" },
            "duration": { "type": "number", "default": 0.6 },
            "stagger": { "type": "number", "description": "Seconds between layers when several ids are given." }
          },
          "required": ["preset", "start"]
        }
      },
      {
        "name": "shatter_image",
        "description": "Break an image into irregular shards that fly apart, like broken glass or an exploding photo. Give either `layer` (an existing image layer: its file, position and size are reused, and it is replaced by the shards) or `path` (an asset name or absolute path to place a new shattered image). Before `at`, the shards sit together and look like the whole picture; from `at` to `at`+duration they fly apart.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "layer": { "type": "string", "description": "An existing image layer id to shatter in place (removed and replaced by the shards)." },
            "path": { "type": "string", "description": "Asset name or absolute path of an image, when not shattering an existing layer." },
            "x": { "type": "number", "description": "Center position (path mode only; default scene center)." },
            "y": { "type": "number" },
            "width": { "type": "number", "description": "Placed size (path mode only; default the image's natural size)." },
            "height": { "type": "number" },
            "at": { "type": "number", "description": "Scene time the explosion begins (default: the layer's start, or 0)." },
            "duration": { "type": "number", "default": 0.8, "description": "Seconds the pieces take to fly apart." },
            "pieces": { "type": "integer", "default": 40, "description": "Roughly how many shards (4–400)." },
            "direction": { "type": "string", "enum": ["out", "down", "up"], "description": "out (default): radial explosion. down/up: pieces mostly fall or burst upward." },
            "distance": { "type": "number", "default": 1, "description": "Multiplier on how far pieces fly." },
            "spin": { "type": "number", "default": 1, "description": "Multiplier on how much pieces rotate as they fly." },
            "fadeOut": { "type": "boolean", "default": true, "description": "Fade pieces out after they finish flying." },
            "seed": { "type": "integer", "description": "Random seed; same seed + pieces always shatters the same way." },
            "id": { "type": "string", "description": "Prefix for the shard layer ids (e.g. \"dog\" → dog-1, dog-2, …). Default: the source layer's id, or \"shatter\"." }
          }
        }
      },
      {
        "name": "sync_to_beats",
        "description": "Edits to the music in one step, on the beats of an audio layer (default the music): preset = apply a preset at each beat, cycling through `ids` (words popping one per beat, a logo pulsing); pulse = kick `property` of each layer up by `amount` at every beat and fall back over `release` s (scale 0.1, brightness 0.4, glow 1, y -20); cut = show `ids` one after another, one beat interval each (a slideshow cut to the music; their keyframes move with them); flash = white flash over the frame on each beat (`amount` = strength 0..1).",
        "inputSchema": {
          "type": "object",
          "properties": {
            "action": { "type": "string", "enum": ["preset", "pulse", "cut", "flash"] },
            "ids": { "type": "array", "items": { "type": "string" } },
            "every": { "type": "string", "enum": ["beat", "half", "bar", "onset"], "default": "beat", "description": "beat, every other beat, first beat of each bar, or strong hits." },
            "preset": { "type": "string", "description": "For action preset (e.g. pulse, popIn, textPop, glitchBurst, shake)." },
            "duration": { "type": "number", "description": "Preset length (default ~85% of a beat, at most 0.6 s)." },
            "property": { "type": "string", "description": "For action pulse." },
            "amount": { "type": "number" },
            "release": { "type": "number", "default": 0.25 },
            "source": { "type": "string", "description": "Audio layer id (default the music layer)." },
            "from": { "type": "number" },
            "to": { "type": "number" },
            "minStrength": { "type": "number", "default": 0.4, "description": "every=onset: weakest hit kept (0..1)." }
          },
          "required": ["action"]
        }
      },
      {
        "name": "add_template",
        "description": "Adds a ready-made animated piece as a group (its parts are normal layers you can edit by id): lowerThird (name + role bar, bottom left), callout (dot + line + label pointing at x/y), subscribe (button that gets clicked), endCard (title, two video placeholders, subscribe), titleCard (big title with shine, rule, subtitle), quote (quote marks, text popping by word, author). Entrances and exits are keyed inside start..start+duration.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "kind": { "type": "string", "enum": ["lowerThird", "callout", "subscribe", "endCard", "titleCard", "quote"] },
            "title": { "type": "string" },
            "subtitle": { "type": "string" },
            "accent": { "type": "string", "description": "Accent color #RRGGBB." },
            "start": { "type": "number", "default": 0 },
            "duration": { "type": "number", "default": 4 },
            "x": { "type": "number", "description": "Position (scene px): the point a callout points at, the left edge of a lower third, the center of the others." },
            "y": { "type": "number" },
            "fontName": { "type": "string" },
            "id": { "type": "string" }
          },
          "required": ["kind"]
        }
      },
      {
        "name": "apply_look",
        "description": "Gives the scene a finished look in one call: sets the background, adds a `look` group at the bottom (radial-gradient backdrop, two slow drifting blurred color blobs, ambient dust/bokeh particles) and a `look-finish` group on top (vignette, film grain), plus a slow camera push-in when the scene has no camera. Kinds: cinematic (deep navy/black, blue + teal, dust: titles, tech, trailers), clean (white/light gray, pastel blobs, no grain: product, corporate, explainer; use dark text), neon (black with magenta + cyan glow, bokeh: music, gaming), retro (warm brown/plum, orange + pink, heavy grain + scanlines: vintage), sunset (coral → violet, golden blobs: lifestyle, travel), studio (charcoal with a top spotlight, one accent blob: business, data). Applying again replaces the previous look's layers; the parts are normal layers you can edit by id (look-bg, look-light-1, look-light-2, look-particles, look-vignette, look-grain). Content layers keep their place between the two groups: call it after set_scene, or before add_layers.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "kind": { "type": "string", "enum": ["cinematic", "clean", "neon", "retro", "sunset", "studio"] },
            "accent": { "type": "string", "description": "Accent color #RRGGBB for the main blob (and a tint of the gradient); default per kind." },
            "intensity": { "type": "number", "default": 1, "description": "0.5 subtle … 1.5 strong: blob opacity, grain and vignette." },
            "particles": { "type": "boolean", "default": true },
            "grain": { "type": "boolean", "default": true },
            "vignette": { "type": "boolean", "default": true },
            "cameraDrift": { "type": "boolean", "default": true, "description": "Slow zoom 1 → 1.04 over the scene (only when it has no camera yet)." }
          },
          "required": ["kind"]
        }
      },
      {
        "name": "remove_look",
        "description": "Removes the layers added by apply_look (background color and camera stay).",
        "inputSchema": { "type": "object", "properties": {} }
      },
      {
        "name": "text_to_path",
        "description": "Turns a text layer into vector paths: one path layer (same id), or with letters=true a group (same id) of one path per letter, each centered on its letter so it can move, spin and scale alone. Then trim (handwriting: preset writeOn), morph keyframes on d, zigzag/wiggle/offset and combine_paths work on the letters. The font is baked in at that moment.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "letters": { "type": "boolean", "default": false },
            "time": { "type": "number", "description": "Scene time whose text (counter, scramble) is used (default the layer's start)." }
          },
          "required": ["id"]
        }
      },
      {
        "name": "combine_paths",
        "description": "Boolean operation on the outlines of rect/ellipse/path/text layers (as placed at `time`): union, subtract (the first minus the others), intersect or exclude. Creates one path layer with the first layer's fill/stroke/gradient where the result is; removes the sources unless keep=true. Logo building, cut-out text, ring shapes, Venn overlaps.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "ids": { "type": "array", "items": { "type": "string" } },
            "op": { "type": "string", "enum": ["union", "subtract", "intersect", "exclude"], "default": "union" },
            "id": { "type": "string", "description": "Id of the new path layer." },
            "keep": { "type": "boolean", "default": false },
            "time": { "type": "number", "default": 0 }
          },
          "required": ["ids"]
        }
      },
      {
        "name": "stabilize",
        "description": "Removes camera shake from a video layer (Vision frame registration, translation only): mode smooth (default) keeps intended pans and removes the jitter around them; lock cancels all camera motion (a locked-off shot). Keys the layer's x/y against the shake and scales it by `zoom` so the moving edges stay out of frame.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "layer": { "type": "string" },
            "mode": { "type": "string", "enum": ["smooth", "lock"], "default": "smooth" },
            "zoom": { "type": "number", "default": 1.08, "description": "Scale-up hiding the edges (1.05–1.15)." },
            "smoothing": { "type": "integer", "default": 15, "description": "smooth mode: frames averaged for the intended path." },
            "from": { "type": "number" },
            "to": { "type": "number" },
            "step": { "type": "number", "description": "Seconds between samples (default every frame)." }
          },
          "required": ["layer"]
        }
      },
      {
        "name": "track_motion",
        "description": "Follows an object through a video layer (Vision object tracking) and keyframes another layer to move with it (a label, sticker, arrow, blur box or highlight pinned to a face, product or car). Give the object's center and size at `from` in scene pixels. Without `target`, returns the tracked positions.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "layer": { "type": "string", "description": "The video layer id." },
            "x": { "type": "number", "description": "Object center at `from`, scene px." },
            "y": { "type": "number" },
            "width": { "type": "number", "default": 120, "description": "Object size at `from`, scene px." },
            "height": { "type": "number", "default": 120 },
            "from": { "type": "number", "description": "Scene time tracking starts (default: the layer's start)." },
            "to": { "type": "number", "description": "Scene time tracking ends (default: the layer's end)." },
            "step": { "type": "number", "description": "Seconds between samples (default every frame)." },
            "target": { "type": "string", "description": "Layer to attach: its x/y get a keyframe per sample." },
            "keepOffset": { "type": "boolean", "default": true, "description": "Keep the target's current offset from the object (false: center it on the object)." },
            "scale": { "type": "boolean", "default": false, "description": "Also scale the target as the object grows or shrinks." },
            "smoothing": { "type": "integer", "default": 3, "description": "Moving-average window in samples (1 = raw)." }
          },
          "required": ["layer", "x", "y"]
        }
      },
      {
        "name": "auto_reframe",
        "description": "Keeps the subject of a video layer in frame for another aspect ratio (16:9 → 9:16 for TikTok/Reels/Shorts): finds where attention goes in each sampled frame (Vision saliency) and keyframes the layer's position so that point stays in the center crop, never showing the video's edges. Then export_video with that width/height and fit \"crop\".",
        "inputSchema": {
          "type": "object",
          "properties": {
            "layer": { "type": "string", "description": "The video layer id." },
            "width": { "type": "number", "description": "Target format width, e.g. 1080." },
            "height": { "type": "number", "description": "Target format height, e.g. 1920." },
            "from": { "type": "number" },
            "to": { "type": "number" },
            "step": { "type": "number", "default": 0.5, "description": "Seconds between samples." },
            "smoothing": { "type": "integer", "default": 3 }
          },
          "required": ["layer", "width", "height"]
        }
      },
      {
        "name": "transition",
        "description": "Animates a transition between two layers (or groups): the outgoing one leaves and the incoming one arrives over [at, at+duration]. Sets the outgoing layer's end and the incoming layer's start. Types: fade, dissolve (block dissolve), push (both move), slide (new one slides over), zoom (through the old one), whip (fast pan with motion blur), wipe, iris, blinds, blocks, clock, glitch, flash (white flash, adds a 'flash' layer), blur, circle (the new layer grows out of x/y as a circle until it fills the frame; top-level layers only), shape (same with any path `shape`, e.g. star(5,1,0.5)), match (match cut: the new layer starts where the old one is and both settle into the new one's place).",
        "inputSchema": {
          "type": "object",
          "properties": {
            "type": { "type": "string", "enum": ["fade", "dissolve", "push", "slide", "zoom", "whip", "wipe", "iris", "blinds", "blocks", "clock", "glitch", "flash", "blur", "circle", "shape", "match"] },
            "shape": { "type": "string", "description": "shape only: path d centered on 0,0 (star(5,1,0.5), polygon(6,1), M… ); it is scaled from nothing to the frame." },
            "x": { "type": "number", "description": "circle/shape: where it grows from (default frame center)." },
            "y": { "type": "number" },
            "out": { "type": "string", "description": "Layer leaving (optional)." },
            "in": { "type": "string", "description": "Layer arriving (optional)." },
            "at": { "type": "number", "description": "Scene time the transition starts." },
            "duration": { "type": "number", "default": 0.6 },
            "direction": { "type": "string", "enum": ["left", "right", "up", "down"], "description": "Where the motion goes (push, slide, whip, wipe, blinds). Default left." }
          },
          "required": ["type", "at"]
        }
      },
      {
        "name": "group_layers",
        "description": "Moves top-level layers into a new group layer (a precomp): move, scale, fade, blur, wipe or effect them all at once. The group is centered on the scene, so the children keep their coordinates. Returns the group id.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "ids": { "type": "array", "items": { "type": "string" }, "description": "Layer ids to group (draw order is kept)." },
            "id": { "type": "string", "description": "Id for the group (default \"group\")." },
            "name": { "type": "string" }
          },
          "required": ["ids"]
        }
      },
      {
        "name": "ungroup",
        "description": "Puts a group's children back as top-level layers at the group's place (the group's own transform and effects are dropped).",
        "inputSchema": {
          "type": "object",
          "properties": { "id": { "type": "string", "description": "The group layer id." } },
          "required": ["id"]
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
        "description": "List text-to-speech voices. engine \"macos\" (default): voices installed on this Mac (id, name, language, quality), filtered by language prefix, e.g. \"vi\" or \"en\". engine \"vieneu\": natural Vietnamese cloud voices from VieNeu.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "engine": { "type": "string", "enum": ["macos", "vieneu"] },
            "language": { "type": "string", "description": "macos only." }
          }
        }
      },
      {
        "name": "generate_sfx",
        "description": "Synthesize a sound effect made to measure (no download, no license) and add it as an sfx audio layer whose hit lands at hitAt. Kinds: whoosh (slides, zooms, camera moves; peaks mid-way), swoosh (quick flicks/cuts), pop (scale-in, appear), blip (UI elements), click (buttons, snaps), tick (counters, list steps), ding (success, highlight), chime (reveal, achievement), sparkle (shine, magic), riser (build-up whose hit is its end), impact (title slam, logo landing), thud (soft landing), drop (exit, error), glitch (glitch transition), typing (typewriter text). Same settings give the same file.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "kind": { "type": "string", "enum": ["whoosh", "swoosh", "pop", "blip", "click", "tick", "ding", "chime", "sparkle", "riser", "impact", "thud", "drop", "glitch", "typing"] },
            "hitAt": { "type": "number", "description": "Scene time the hit should land: the frame the motion peaks/lands (whoosh: middle of the move; riser: the reveal; typing: first keystroke). Preferred over start." },
            "start": { "type": "number", "description": "Scene time the layer starts (when hitAt is not given)." },
            "duration": { "type": "number", "description": "Seconds. whoosh/swoosh: the move's length (0.2–2); riser: the build-up (1–6); typing: the typing time; drop/glitch/sparkle: length. With count: the span the repeats are spread over." },
            "pitch": { "type": "number", "description": "Frequency multiplier 0.5–2 (default 1): lower for big/heavy things, higher for small/light ones." },
            "direction": { "type": "string", "enum": ["left", "right"], "description": "whoosh/swoosh/riser: pan the sound in the direction the object moves." },
            "count": { "type": "integer", "description": "tick/click/pop/blip/thud/ding: repeat this many times evenly over duration (e.g. a counter); typing: number of keystrokes." },
            "variant": { "type": "integer", "description": "Different random detail (and chime root note). Change it when the same effect repeats." },
            "reverb": { "type": "number", "description": "0–1 room tail (defaults: ding/chime 0.3, impact 0.25, sparkle 0.2, others 0)." },
            "volume": { "type": "number", "description": "Layer volume (1 = full; effects usually sit at 0.4–0.7 under a voice)." },
            "add": { "type": "boolean", "description": "Add an audio layer (default true). false = only create the file." },
            "id": { "type": "string" },
            "folder": { "type": "string", "description": "Asset folder for the file (default sfx/ in projects)." }
          },
          "required": ["kind"]
        }
      },
      {
        "name": "generate_voice",
        "description": "Speak a script and add it as a voice audio layer starting at `start`. Returns the audio duration and the scene time of every word, so you can time visuals and captions to the narration. Generate one call per section.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "text": { "type": "string", "description": "What to say. Plain sentences; punctuation creates natural pauses." },
            "start": { "type": "number", "description": "Scene time (s) where the voice begins. Default 0." },
            "engine": { "type": "string", "enum": ["macos", "vieneu"], "description": "Default macos. vieneu = natural Vietnamese voices (word times are estimated)." },
            "language": { "type": "string", "description": "macos only: e.g. vi-VN, en-US. Used when `voice` is not given." },
            "voice": { "type": "string", "description": "Voice id from list_voices for the same engine." },
            "rate": { "type": "number", "description": "Speaking speed multiplier, 1 = normal (0.5–2)." },
            "id": { "type": "string", "description": "Layer id, e.g. vo-1." }
          },
          "required": ["text"]
        }
      },
      {
        "name": "add_audio",
        "description": "Add an audio file (music, sound effect or recorded voice) as an audio layer. For a sound effect, pass hitAt so its peak lands on the right frame; the reply describes the sound's shape.",
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
            "hitAt": { "type": "number", "description": "Sound effects: scene time where the sound's peak should land (the frame the motion hits). Sets start, trimIn (skips leading silence) and end (stops after that sound) for you; overrides start." },
            "hit": { "type": "integer", "description": "With hitAt, for a file holding several separate sounds: which one (1-based, as listed by import_stock / analyze_audio). Default: the loudest." },
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
        "description": "Find the rhythm of the music: tempo (bpm), beat times, downbeats (first beat of each bar), strong hits (onsets, [time, strength 0..1]) and loudness per second (0..1). Times are scene seconds for a layer. Use it to land entrances, cuts and accents on the beat and big moments on loud parts. For short files (sound effects, ≤ 30 s) it also returns `sound`: shape, peak and the separate sounds as [start, peak, end].",
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
        "description": "Create timed caption text layers (ids cap-<id>-<number>) from the word timings of a generated voice layer or a transcribed audio/video layer. Replaces earlier captions for that layer and lists the numbered captions with scene times.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string", "description": "Voice layer, or audio/video layer that was transcribed." },
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
        "name": "transcribe",
        "description": "Recognize the speech of an audio or video layer (the part it plays) with Apple speech recognition and store the text and word timings on the layer, for add_captions. Slow for long media (about a minute per few minutes of audio).",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string", "description": "Audio or video layer id." },
            "language": { "type": "string", "description": "Spoken language, e.g. en-US, ja-JP, zh-CN, ko-KR, vi-VN (a bare code like \"en\" picks a region). Default: the system language." }
          },
          "required": ["id"]
        }
      },
      {
        "name": "set_caption_texts",
        "description": "Replace the text of captions made by add_captions (e.g. with a translation), keeping their timing and style. texts[0] goes to caption number `from`, texts[1] to from+1, …",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string", "description": "The layer the captions belong to (as passed to add_captions)." },
            "texts": { "type": "array", "items": { "type": "string" } },
            "from": { "type": "integer", "description": "Number of the first caption to replace (default 1)." }
          },
          "required": ["id", "texts"]
        }
      },
      {
        "name": "list_captions",
        "description": "List a layer's captions: number, scene start–end and text.",
        "inputSchema": { "type": "object", "properties": { "id": { "type": "string" } }, "required": ["id"] }
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
        "description": "Search free assets online: photos and illustrations from Openverse (licenses allowing commercial use and changes), stock video clips from Pexels and Pixabay (free for commercial use, no credit needed; needs the VeyMotion server), icons from Iconify (200k+ open-source SVG icons), music from Jamendo and sound effects from Freesound (via Openverse), fonts from Google Fonts. Returns numbered results with refs, licenses, durations and a numbered preview image (thumbnails; for sounds, waveforms with each sound's shape, peak and tags). English keywords work best. For common motion sounds (whoosh, pop, click, ding, riser, impact…) generate_sfx is usually the better choice.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": { "type": "string", "description": "e.g. \"mountain sunset\", \"rocket\", \"upbeat corporate\", \"whoosh\"." },
            "kind": { "type": "string", "enum": ["photo", "illustration", "video", "icon", "music", "sound", "font"], "default": "photo" },
            "orientation": { "type": "string", "enum": ["landscape", "portrait", "square"], "description": "Videos only: frame shape (portrait for 9:16 TikTok/Reels/Shorts). Default: any." },
            "vietnamese": { "type": "boolean", "description": "Fonts only: keep fonts that have Vietnamese letters." },
            "maxDuration": { "type": "number", "description": "Music/sound/video: leave out results longer than this many seconds. Sounds default to 10 (one-shot effects); raise it for ambiences, 0 = no limit." },
            "page": { "type": "integer", "description": "1-based page (20 results per page, 48 for icons)." },
            "limit": { "type": "integer", "description": "Return at most this many results." },
            "preview": { "type": "boolean", "description": "Include the numbered preview image (thumbnails; for sounds, waveforms plus each sound's shape and peak, which downloads them). Default true." }
          },
          "required": ["query"]
        }
      },
      {
        "name": "import_stock",
        "description": "Download a search_stock result into the asset library (with its license and credit recorded). Returns the path to use in an image layer (a video layer for videos, downloaded as MP4 up to 1920 px on the long side). Icons are saved as SVG in `color`. Fonts are installed for the app and used by family name (fontName).",
        "inputSchema": {
          "type": "object",
          "properties": {
            "ref": { "type": "string", "description": "From search_stock, e.g. openverse:<id>, pexels:<id> or iconify:mdi:rocket." },
            "name": { "type": "string", "description": "File name in the library (optional)." },
            "folder": { "type": "string", "description": "Folder to put it in (created if missing). Default: top level." },
            "color": { "type": "string", "description": "Icons only: hex color, default #FFFFFF." },
            "weights": { "type": "array", "items": { "type": "string" }, "description": "Fonts only: styles to download, e.g. [\"400\", \"700\", \"400i\"] (i = italic). Default: every upright weight." },
            "size": { "type": "integer", "description": "Icons only: height in px of the SVG's natural size, default 512." }
          },
          "required": ["ref"]
        }
      },
      {
        "name": "list_fonts",
        "description": "List the font families text layers can use as fontName: fonts in the asset library (e.g. imported from Google Fonts) first, then fonts installed on this Mac, with their weights.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "query": { "type": "string", "description": "Part of a family name, e.g. \"serif\" or \"Avenir\"." },
            "vietnamese": { "type": "boolean", "description": "Only fonts with all Vietnamese letters." },
            "limit": { "type": "integer", "description": "Max families listed (default 80)." }
          }
        }
      },
      {
        "name": "get_credits",
        "description": "Credit lines for the downloaded assets used in the scene (needed for CC BY / CC BY-SA content). Put them in the video's end card or description.",
        "inputSchema": { "type": "object", "properties": {} }
      },
      {
        "name": "set_bones",
        "description": "Adds or replaces the scene's bones (a cut-out rig). A bone: {id, parent?, x, y (root only: where it starts, scene px), length (px), angle (degrees; root: absolute, 0 = right, 90 = down; child: relative to its parent), minAngle?, maxAngle? (IK limits)}. Child bones start at their parent's tip. Then bind_bone hangs layers (e.g. the parts of an import_vector character) on them, and pose_bones / solve_ik animate the angles (keyframes). Bones are not drawn.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "bones": { "type": "array", "items": { "type": "object" } },
            "replace": { "type": "boolean", "default": false, "description": "Drop bones not in the list." }
          },
          "required": ["bones"]
        }
      },
      {
        "name": "bind_bone",
        "description": "Hangs a layer on a bone: from then on it moves and turns with the bone (its x/y/rotation become relative to the bone's start and direction). The layer does not jump at `time`. bone \"\" detaches it. Typical rig: upperArm → forearm → hand bones, each part layer bound to its bone.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "bone": { "type": "string" },
            "time": { "type": "number", "default": 0, "description": "When the layer keeps its place." }
          },
          "required": ["id", "bone"]
        }
      },
      {
        "name": "pose_bones",
        "description": "Sets bone angles (degrees, in each bone's own frame). With `time`, each angle is a keyframe there (the previous pose is kept `hold` seconds before it when the bone had no keyframes yet); without it, constants. Call it at several times to animate a walk, a wave, a nod.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "angles": { "type": "object", "description": "{\"upperArm\": -40, \"forearm\": 70}" },
            "time": { "type": "number" },
            "hold": { "type": "number", "default": 0.4 }
          },
          "required": ["angles"]
        }
      },
      {
        "name": "solve_ik",
        "description": "Inverse kinematics: turns the chain ending at `bone` (that bone and `chain`-1 parents) so the bone's tip reaches x/y (scene px), within the bones' angle limits, and keys the angles at `time` (like pose_bones). Use it to put a hand on an object, a foot on the floor, a head toward a target: reach, grab, point, step.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "bone": { "type": "string", "description": "The last bone of the chain (its tip is the end effector)." },
            "x": { "type": "number" },
            "y": { "type": "number" },
            "chain": { "type": "integer", "default": 2 },
            "time": { "type": "number" },
            "hold": { "type": "number", "default": 0.4 }
          },
          "required": ["bone", "x", "y"]
        }
      },
      {
        "name": "draw_frame",
        "description": "Adds (or replaces, with `index`) one frame of a drawing layer (type \"drawing\"): a list of strokes, each {d: path data in layer px around the layer's x/y, stroke: color (null = none), strokeWidth (default 6), fill?}. hold = how many drawing frames it stays (2 = animate on 2s). The layer's drawing.fps (default 12) and drawing.loop are set with update_layer. Build hand-drawn animation frame by frame: smears, squiggly lines, a wobbling outline, an ink splash.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "id": { "type": "string" },
            "strokes": { "type": "array", "items": { "type": "object" } },
            "hold": { "type": "integer", "default": 1 },
            "index": { "type": "integer", "description": "Replace this frame (0-based) instead of appending." }
          },
          "required": ["id", "strokes"]
        }
      },
      {
        "name": "import_vector",
        "description": "Turns an SVG into editable layers: a group (`id`) whose children are one path layer per <path>/<rect>/<circle>/<ellipse>/<line>/<polyline>/<polygon> (d, fill, stroke, opacity, gradients, fill rule, caps, dashes kept; transforms baked in) and one group per <g> (flatten true puts every shape in the top group). Scaled to width/height (one keeps the aspect; none = SVG units as px) and centered on x/y (default: the frame center). The groups themselves sit at the frame center with anchorX/anchorY on the drawing, so rotation and scale pivot on it; move a group by offsetting its x/y from the frame center, not by writing the target position. Use it for illustrations, icons and characters whose parts must move separately (then set_parent / keyframes on the parts, or bones). `source` is an asset-library name (e.g. icons/hand.svg, after import_asset / import_stock) or an absolute path. Not imported: <text>, <image>, <use>, clip paths, masks, CSS <style>.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "source": { "type": "string" },
            "id": { "type": "string", "description": "Group id; part ids are <id>-<element id> or <id>-path3." },
            "x": { "type": "number" },
            "y": { "type": "number" },
            "width": { "type": "number" },
            "height": { "type": "number" },
            "flatten": { "type": "boolean", "default": false }
          },
          "required": ["source"]
        }
      },
      {
        "name": "render_frames",
        "description": "Renders up to 24 times into one contact-sheet PNG (labeled, `columns` per row). The fast way to check pacing and every section of a long piece in one look; then render_frame for detail.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "times": { "type": "array", "items": { "type": "number" }, "description": "Seconds, 1–24 of them." },
            "columns": { "type": "integer", "default": 4 },
            "scale": { "type": "number", "default": 0.25, "description": "Per-frame scale relative to the scene (0.1–0.5)." }
          },
          "required": ["times"]
        }
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
          "properties": {
            "path": { "type": "string", "description": "Absolute output path ending in .mp4 or .mov." },
            "preset": { "type": "string", "enum": ["tiktok", "shorts", "reels", "youtube", "facebook", "x", "square"], "description": "Export at a social platform's size: tiktok/shorts/reels 1080×1920, youtube 1920×1080, facebook 1080×1350, x 1920×1080, square 1080×1080. A scene of another aspect ratio is letterboxed or cropped (see fit); prefer making the scene that size with update_scene. The result warns about the platform's length/size limits." },
            "fit": { "type": "string", "enum": ["fit", "fill"], "default": "fit", "description": "With a preset of another aspect ratio: fit = whole scene with bars in the background color, fill = crop the edges." }
          },
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
