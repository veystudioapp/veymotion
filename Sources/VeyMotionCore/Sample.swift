import Foundation

extension MotionScene {
    /// Demo scene shown on first launch; also a reference for the JSON format.
    public static var sample: MotionScene {
        (try? SceneJSON.decode(MotionScene.self, from: Data(sampleJSON.utf8))) ?? MotionScene()
    }

    public static let sampleJSON = #"""
    {
      "width": 1920, "height": 1080, "fps": 30, "duration": 6,
      "background": "#0E0E12",
      "layers": [
        { "id": "glow", "type": "ellipse", "x": 1560, "y": 240, "width": 560, "height": 560,
          "fill": "#6C5CE733",
          "scale": { "keyframes": [ {"t": 0, "v": 0.6}, {"t": 6, "v": 1.15, "easing": "easeInOut"} ] } },

        { "id": "title", "type": "text", "text": "VeyMotion", "fontSize": 140, "fontWeight": "heavy",
          "x": 960, "color": "#FFFFFF",
          "opacity": { "keyframes": [ {"t": 0.2, "v": 0}, {"t": 0.9, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 0.2, "v": 330}, {"t": 0.9, "v": 270, "easing": "easeOut"} ] } },

        { "id": "subtitle", "type": "text", "text": "Native motion graphics, driven by AI over MCP",
          "fontSize": 44, "fontWeight": "medium", "x": 960, "y": 390, "color": "#A0A0B8",
          "reveal": { "keyframes": [ {"t": 1.0, "v": 0}, {"t": 2.4, "v": 1, "easing": "linear"} ] } },

        { "id": "bar-1", "type": "rect", "x": 690, "width": 120, "height": 160, "cornerRadius": 16, "fill": "#6C5CE7",
          "opacity": { "keyframes": [ {"t": 2.6, "v": 0}, {"t": 3.0, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 2.6, "v": 980}, {"t": 3.1, "v": 880, "easing": "spring"} ] } },
        { "id": "bar-2", "type": "rect", "x": 870, "width": 120, "height": 240, "cornerRadius": 16, "fill": "#00B894",
          "opacity": { "keyframes": [ {"t": 2.8, "v": 0}, {"t": 3.2, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 2.8, "v": 940}, {"t": 3.3, "v": 840, "easing": "spring"} ] } },
        { "id": "bar-3", "type": "rect", "x": 1050, "width": 120, "height": 320, "cornerRadius": 16, "fill": "#FDCB6E",
          "opacity": { "keyframes": [ {"t": 3.0, "v": 0}, {"t": 3.4, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 3.0, "v": 900}, {"t": 3.5, "v": 800, "easing": "spring"} ] } },
        { "id": "bar-4", "type": "rect", "x": 1230, "width": 120, "height": 400, "cornerRadius": 16, "fill": "#FF7675",
          "opacity": { "keyframes": [ {"t": 3.2, "v": 0}, {"t": 3.6, "v": 1, "easing": "easeOut"} ] },
          "y": { "keyframes": [ {"t": 3.2, "v": 860}, {"t": 3.7, "v": 760, "easing": "spring"} ] } },

        { "id": "badge", "type": "text", "text": "+42%", "fontSize": 64, "fontWeight": "black",
          "x": 1230, "y": 505, "color": "#FF7675",
          "scale": { "keyframes": [ {"t": 3.8, "v": 0}, {"t": 4.2, "v": 1.1, "easing": "easeOut"}, {"t": 4.4, "v": 1} ] } }
      ]
    }
    """#
}
