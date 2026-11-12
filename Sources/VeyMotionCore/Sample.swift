import Foundation

extension MotionScene {
    /// Demo scene shown on first launch; also a reference for the JSON format.
    public static var sample: MotionScene {
        (try? SceneJSON.decode(MotionScene.self, from: Data(sampleJSON.utf8))) ?? MotionScene()
    }

    // The scene shows the three layers of a finished look (see LOOK & DESIGN in the agent docs): a background with
    // depth (gradient, drifting blurred lights, dust), a lit subject (glow, gradients, shadows, a type hierarchy) and
    // a finish on top (vignette, grain) under a slow camera push. `apply_look` builds the same look/finish groups.
    public static let sampleJSON = #"""
    {
      "width": 1920, "height": 1080, "fps": 30, "duration": 6,
      "background": "#06070B",
      "camera": { "x": 960, "y": 540,
        "zoom": { "keyframes": [ {"t": 0, "v": 1}, {"t": 6, "v": 1.04, "easing": "easeInOutSine"} ] } },
      "layers": [
        { "id": "look", "type": "group", "name": "Look · Cinematic Dark", "x": 960, "y": 540, "children": [
          { "id": "look-bg", "type": "rect", "x": 960, "y": 540, "width": 1920, "height": 1080,
            "gradient": { "type": "radial", "colors": ["#1A2140", "#05060A"], "cx": 0.5, "cy": 0.3, "radius": 1.1 } },
          { "id": "look-light-1", "type": "ellipse", "x": 420, "y": 330, "width": 1050, "height": 900,
            "fill": "#6C5CE780", "blur": 320, "blendMode": "screen",
            "wiggle": { "x": {"amount": 70, "frequency": 0.08, "seed": 11}, "y": {"amount": 40, "frequency": 0.07, "seed": 12} },
            "scale": { "keyframes": [ {"t": 0, "v": 0.95}, {"t": 6, "v": 1.1, "easing": "easeInOutSine"} ] }, "loop": {"scale": "pingpong"} },
          { "id": "look-light-2", "type": "ellipse", "x": 1540, "y": 840, "width": 960, "height": 820,
            "fill": "#1C8C8C80", "blur": 290, "blendMode": "screen",
            "wiggle": { "x": {"amount": 60, "frequency": 0.08, "seed": 23}, "y": {"amount": 35, "frequency": 0.07, "seed": 24} } },
          { "id": "look-particles", "type": "particles", "x": 960, "y": 540, "width": 1920, "height": 1080, "opacity": 0.5,
            "blendMode": "add", "particles": { "preset": "dust", "rate": 18, "speed": 25, "prewarm": 6, "colors": ["#C8C4F0"] } }
        ] },

        { "id": "eyebrow", "type": "text", "text": "MOTION GRAPHICS FOR MACOS", "fontSize": 26, "fontWeight": "semibold",
          "letterSpacing": 6, "x": 960, "y": 190, "color": "#8F7BFF",
          "opacity": { "keyframes": [ {"t": 0.1, "v": 0}, {"t": 0.7, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 0.1, "v": 210}, {"t": 0.7, "v": 190, "easing": "easeOutCubic"} ] } },

        { "id": "title", "type": "text", "text": "VeyMotion", "fontSize": 150, "fontWeight": "black", "letterSpacing": -3,
          "x": 960, "color": "#F2F3F7", "glow": 0.6, "glowRadius": 60, "glowColor": "#8F7BFF",
          "gradient": { "type": "linear", "colors": ["#FFFFFF", "#C9C2FF"], "angle": 90 },
          "opacity": { "keyframes": [ {"t": 0.3, "v": 0}, {"t": 1.0, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 0.3, "v": 340}, {"t": 1.1, "v": 290, "easing": "easeOutExpo"} ] },
          "scale": { "keyframes": [ {"t": 0.3, "v": 0.92}, {"t": 1.1, "v": 1, "easing": "easeOutExpo"} ] } },

        { "id": "subtitle", "type": "text", "text": "Native motion graphics, driven by AI over MCP",
          "fontSize": 40, "fontWeight": "medium", "x": 960, "y": 405, "color": "#B9BCCF",
          "reveal": { "keyframes": [ {"t": 1.0, "v": 0}, {"t": 2.4, "v": 1, "easing": "linear"} ] } },

        { "id": "bar-1", "type": "rect", "x": 690, "width": 120, "height": 160, "cornerRadius": 18,
          "gradient": { "colors": ["#8F7BFF", "#5A47D6"], "angle": 90 }, "shadowOpacity": 0.45, "shadowY": 18, "shadowBlur": 40,
          "opacity": { "keyframes": [ {"t": 2.6, "v": 0}, {"t": 3.0, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 2.6, "v": 980}, {"t": 3.2, "v": 880, "easing": "easeOutBack"} ] } },
        { "id": "bar-2", "type": "rect", "x": 870, "width": 120, "height": 240, "cornerRadius": 18,
          "gradient": { "colors": ["#2EE6B8", "#00A884"], "angle": 90 }, "shadowOpacity": 0.45, "shadowY": 18, "shadowBlur": 40,
          "opacity": { "keyframes": [ {"t": 2.75, "v": 0}, {"t": 3.15, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 2.75, "v": 940}, {"t": 3.35, "v": 840, "easing": "easeOutBack"} ] } },
        { "id": "bar-3", "type": "rect", "x": 1050, "width": 120, "height": 320, "cornerRadius": 18,
          "gradient": { "colors": ["#FFE08A", "#F5B942"], "angle": 90 }, "shadowOpacity": 0.45, "shadowY": 18, "shadowBlur": 40,
          "opacity": { "keyframes": [ {"t": 2.9, "v": 0}, {"t": 3.3, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 2.9, "v": 900}, {"t": 3.5, "v": 800, "easing": "easeOutBack"} ] } },
        { "id": "bar-4", "type": "rect", "x": 1230, "width": 120, "height": 400, "cornerRadius": 18,
          "gradient": { "colors": ["#FF8A8A", "#F0506E"], "angle": 90 }, "shadowOpacity": 0.45, "shadowY": 18, "shadowBlur": 40,
          "opacity": { "keyframes": [ {"t": 3.05, "v": 0}, {"t": 3.45, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 3.05, "v": 860}, {"t": 3.65, "v": 760, "easing": "easeOutBack"} ] } },

        { "id": "badge", "type": "text", "text": "+42%", "fontSize": 64, "fontWeight": "black",
          "x": 1230, "y": 500, "color": "#FF8A8A", "glow": 0.8, "glowRadius": 40, "glowColor": "#FF6B6B",
          "scale": { "keyframes": [ {"t": 3.8, "v": 0}, {"t": 4.25, "v": 1, "easing": "easeOutBack"} ] },
          "opacity": { "keyframes": [ {"t": 3.8, "v": 0}, {"t": 4.0, "v": 1, "easing": "easeOut"} ] } },

        { "id": "look-finish", "type": "group", "name": "Finish", "x": 960, "y": 540, "children": [
          { "id": "look-vignette", "type": "rect", "x": 960, "y": 540, "width": 1920, "height": 1080,
            "gradient": { "type": "radial", "stops": [ {"offset": 0.45, "color": "#00000000"}, {"offset": 1, "color": "#0000008C"} ], "radius": 1.05 } },
          { "id": "look-grain", "type": "rect", "x": 960, "y": 540, "width": 1920, "height": 1080,
            "fill": "#808080", "blendMode": "overlay", "grain": 0.22 }
        ] }
      ]
    }
    """#
}
