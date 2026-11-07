using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using VeyMotion.Core;

namespace VeyMotion.App.Rendering;

/// <summary>Glyph outlines and boolean path operations with Direct2D geometries, for text_to_path and combine_paths
/// (macOS uses CoreText glyph paths and CGPath boolean ops).</summary>
public sealed class Win2DPathGeometry : IPathGeometry
{
    static CanvasDevice Device => CanvasDevice.GetSharedDevice();

    public List<(List<Subpath> Path, PathPoint Center)> GlyphPaths(MotionLayer text, double t)
    {
        var glyphs = GlyphPainter.GlyphOutlines(Device, text, t);
        try
        {
            return glyphs.Select(g =>
            {
                var b = g.ComputeBounds();
                return (Subpaths(g), new PathPoint(b.X + b.Width / 2, b.Y + b.Height / 2));
            }).ToList();
        }
        finally
        {
            foreach (var g in glyphs) g.Dispose();
        }
    }

    public List<Subpath> Combine(IReadOnlyList<List<Subpath>> outlines, PathCombine op)
    {
        if (outlines.Count == 0) return [];
        var mode = op switch
        {
            PathCombine.Subtract => CanvasGeometryCombine.Exclude,
            PathCombine.Intersect => CanvasGeometryCombine.Intersect,
            PathCombine.Exclude => CanvasGeometryCombine.Xor,
            _ => CanvasGeometryCombine.Union,
        };
        var result = ContentPainter.Geometry(Device, outlines[0]);
        foreach (var other in outlines.Skip(1))
        {
            using var g = ContentPainter.Geometry(Device, other);
            var next = result.CombineWith(g, Matrix3x2.Identity, mode);
            result.Dispose();
            result = next;
        }
        using (result) return Subpaths(result);
    }

    /// <summary>A geometry's outline as cubic subpaths.</summary>
    static List<Subpath> Subpaths(CanvasGeometry geometry)
    {
        using var simple = geometry.Simplify(CanvasGeometrySimplification.CubicsAndLines);
        var receiver = new Receiver();
        simple.SendPathTo(receiver);
        return receiver.Output;
    }

    sealed class Receiver : ICanvasPathReceiver
    {
        public readonly List<Subpath> Output = [];
        PathPoint _start, _current;
        List<CubicSegment> _segments = [];

        static PathPoint P(Vector2 v) => new(v.X, v.Y);

        public void BeginFigure(Vector2 startPoint, CanvasFigureFill figureFill)
        {
            _start = _current = P(startPoint);
            _segments = [];
        }

        public void AddLine(Vector2 endPoint)
        {
            var p = P(endPoint);
            _segments.Add(CubicSegment.Line(_current, p));
            _current = p;
        }

        public void AddCubicBezier(Vector2 controlPoint1, Vector2 controlPoint2, Vector2 endPoint)
        {
            _segments.Add(new CubicSegment(P(controlPoint1), P(controlPoint2), P(endPoint)));
            _current = P(endPoint);
        }

        public void AddQuadraticBezier(Vector2 controlPoint, Vector2 endPoint)
        {
            PathPoint c = P(controlPoint), e = P(endPoint);
            _segments.Add(new CubicSegment(
                new PathPoint(_current.X + 2.0 / 3 * (c.X - _current.X), _current.Y + 2.0 / 3 * (c.Y - _current.Y)),
                new PathPoint(e.X + 2.0 / 3 * (c.X - e.X), e.Y + 2.0 / 3 * (c.Y - e.Y)), e));
            _current = e;
        }

        // Simplify(CubicsAndLines) leaves no arcs; a straight line keeps the outline closed if one slips through.
        public void AddArc(Vector2 endPoint, float radiusX, float radiusY, float rotationAngle, CanvasSweepDirection sweepDirection,
            CanvasArcSize arcSize) => AddLine(endPoint);

        public void EndFigure(CanvasFigureLoop figureLoop)
        {
            var closed = figureLoop == CanvasFigureLoop.Closed;
            if (closed && (_current.X != _start.X || _current.Y != _start.Y)) _segments.Add(CubicSegment.Line(_current, _start));
            if (_segments.Count > 0) Output.Add(new Subpath(_start, _segments, closed));
        }

        public void SetFilledRegionDetermination(CanvasFilledRegionDetermination filledRegionDetermination) { }
        public void SetSegmentOptions(CanvasFigureSegmentOptions figureSegmentOptions) { }
    }
}
