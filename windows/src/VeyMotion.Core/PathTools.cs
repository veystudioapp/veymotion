using System.Numerics;

namespace VeyMotion.Core;

public enum PathCombine { Union, Subtract, Intersect, Exclude }

/// <summary>Outline work that needs the platform's text and geometry engine (the app's Win2D/DirectWrite).</summary>
public interface IPathGeometry
{
    /// <summary>A text layer's glyphs as outlines in layer px (around its center, y down), one per glyph with its
    /// center, in reading order.</summary>
    List<(List<Subpath> Path, PathPoint Center)> GlyphPaths(MotionLayer text, double t);

    /// <summary>The first outline combined with each of the others in turn.</summary>
    List<Subpath> Combine(IReadOnlyList<List<Subpath>> outlines, PathCombine op);
}

/// <summary>Text to paths and boolean combinations. Port of the <c>MotionScene</c> extension in <c>PathOps.swift</c>.</summary>
public static class PathTools
{
    public static List<Subpath> Transformed(IEnumerable<Subpath> subpaths, Matrix3x2 m)
    {
        PathPoint T(PathPoint p)
        {
            var v = Vector2.Transform(new Vector2((float)p.X, (float)p.Y), m);
            return new PathPoint(v.X, v.Y);
        }
        return subpaths.Select(s => new Subpath(T(s.Start), s.Segments.Select(g => new CubicSegment(T(g.C1), T(g.C2), T(g.P))).ToList(), s.Closed)).ToList();
    }

    /// <summary>Replaces a text layer by a path layer of its letters (or, with letters, a group with one path per
    /// letter, each centered on its letter so it can move and turn on its own). Fill keeps the text color.</summary>
    public static string TextToPath(this MotionScene scene, string id, bool letters, double t, IPathGeometry geometry)
    {
        var i = scene.LayerIndex(id);
        var text = scene.Layers[i];
        if (text.Type != LayerType.Text) throw new SceneException($"'{id}' is not a text layer");
        var glyphs = geometry.GlyphPaths(text, t);
        if (glyphs.Count == 0) throw new SceneException($"'{id}' has no visible letters");
        MotionLayer PathLayer(List<Subpath> path, string lid, string name)
        {
            var l = text.Clone();
            l.Type = LayerType.Path;
            l.Id = lid;
            l.Name = name;
            l.D = new PathShape(path);
            l.Fill = text.Color;
            l.Stroke = text.Stroke;
            if (text.Stroke == null) l.StrokeWidth = 0.0;
            l.FillRule = FillRule.Nonzero;
            l.TextAnimators = [];
            l.TextPath = null;
            return l;
        }
        if (!letters)
        {
            scene.Layers[i] = PathLayer(glyphs.SelectMany(g => g.Path).ToList(), text.Id, text.Name);
            return text.Id;
        }
        var group = text.Clone();
        group.Type = LayerType.Group;
        group.Width = null;
        group.Height = null;
        group.TextAnimators = [];
        double cx = scene.Width / 2.0, cy = scene.Height / 2.0;
        var children = new List<MotionLayer>();
        var seen = scene.AllLayers.Select(l => l.Id).ToHashSet();
        for (var k = 0; k < glyphs.Count; k++)
        {
            var (path, center) = glyphs[k];
            var c = new MotionLayer(LayerType.Path, "", null, cx + center.X, cy + center.Y)
            {
                D = new PathShape(Transformed(path, Matrix3x2.CreateTranslation((float)-center.X, (float)-center.Y))),
                Fill = text.Color, Stroke = text.Stroke,
                StrokeWidth = text.Stroke == null ? 0.0 : text.StrokeWidth,
                Gradient = text.Gradient, Start = text.Start, End = text.End,
            };
            var cid = $"{text.Id}-{k + 1}";
            for (var n = 2; seen.Contains(cid); n++) cid = $"{text.Id}-{k + 1}-{n}";
            seen.Add(cid);
            c.Id = cid;
            c.Name = $"Letter {k + 1}";
            children.Add(c);
        }
        group.Children = children;
        // Effects stay on the group; the letters only carry their shapes.
        group.Gradient = null;
        scene.Layers[i] = group;
        return text.Id;
    }

    /// <summary>Combines the outlines of shapes, paths and texts (union, the first minus the rest, intersection, or
    /// exclusion) into a new path layer placed where they are. The sources are removed unless keep.</summary>
    public static string CombinePaths(this MotionScene scene, IReadOnlyList<string> ids, PathCombine op, string? newId, bool keep,
        double t, IPathGeometry geometry)
    {
        if (ids.Count < 2) throw new SceneException("Give at least two layer ids");
        var outlines = new List<List<Subpath>>();
        foreach (var lid in ids)
        {
            var l = scene.Layer(lid);
            List<Subpath> local;
            switch (l.Type)
            {
                case LayerType.Rect:
                {
                    double w = Math.Max(0, l.Value(AnimProperty.Width, t)), h = Math.Max(0, l.Value(AnimProperty.Height, t));
                    var r = Math.Max(0, Math.Min(l.Value(AnimProperty.CornerRadius, t), Math.Min(w / 2, h / 2)));
                    local = [PathParser.RoundedRect(-w / 2, -h / 2, w, h, r)];
                    break;
                }
                case LayerType.Ellipse:
                    local = PathParser.Ellipse(Math.Max(0, l.Value(AnimProperty.Width, t)) / 2, Math.Max(0, l.Value(AnimProperty.Height, t)) / 2);
                    break;
                case LayerType.Path:
                    local = l.PathShapeAt(t).Subpaths.ToList();
                    break;
                case LayerType.Text:
                    local = geometry.GlyphPaths(l, t).SelectMany(g => g.Path).ToList();
                    break;
                default:
                    throw new SceneException($"'{lid}' is a {l.Type.Json()} layer: combine rect, ellipse, path or text layers");
            }
            outlines.Add(Transformed(local, scene.SceneTransform(l, t)));
        }
        var result = geometry.Combine(outlines, op);
        if (new PathShape(result).Bounds is not { } box || (box.MaxX - box.MinX <= 0 && box.MaxY - box.MinY <= 0))
            throw new SceneException("The result is empty");
        double midX = (box.MinX + box.MaxX) / 2, midY = (box.MinY + box.MaxY) / 2;
        var first = scene.Layer(ids[0]);
        var layer = new MotionLayer(LayerType.Path, newId ?? $"{ids[0]}-{op.Json()}", newId ?? "Combined", midX, midY)
        {
            D = new PathShape(Transformed(result, Matrix3x2.CreateTranslation((float)-midX, (float)-midY))),
            Fill = first.Type == LayerType.Text ? first.Color : first.Fill,
            Stroke = first.Stroke,
            StrokeWidth = first.Stroke == null ? 0.0 : first.StrokeWidth,
            Gradient = first.Gradient, Start = first.Start, End = first.End,
        };
        var index = scene.Layers.FindIndex(l => l.Id == ids[0]);
        if (!keep)
            foreach (var lid in ids)
                if (scene.Layers.Any(l => l.Id == lid)) scene.RemoveLayer(lid);
        return scene.AddLayer(layer, index >= 0 ? Math.Min(index, scene.Layers.Count) : null);
    }
}
