using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Windows.UI;

namespace VeyMotion.App.Editor;

/// <summary>One mark drawn over the canvas, in scene px: a scribble, a shape or a text note. Port of
/// <c>Annotation</c> (<c>Annotations.swift</c>).</summary>
public sealed class Annotation
{
    public enum ShapeKind { Rect, Ellipse, Arrow, Line }
    public List<Vector2>? Stroke;
    public ShapeKind? Shape;
    public Vector2 A, B;
    public string? Text;
    public Color Color = Color.FromArgb(255, 255, 59, 48);
    /// <summary>Line width (or text size) in scene px.</summary>
    public float Size = 6;

    public Annotation Moved(Vector2 d) => new()
    {
        Stroke = Stroke?.Select(p => p + d).ToList(), Shape = Shape, A = A + d, B = B + d, Text = Text, Color = Color, Size = Size,
    };

    public bool Hit(Vector2 p, float tolerance)
    {
        var reach = tolerance + Size / 2;
        if (Stroke != null) return Stroke.Zip(Stroke.Skip(1)).Any(s => Distance(p, s.First, s.Second) <= reach);
        if (Text != null) return p.X >= A.X - tolerance && p.X <= A.X + Text.Length * Size * 0.6f + tolerance && p.Y >= A.Y - tolerance && p.Y <= A.Y + Size * 1.3f + tolerance;
        return Shape switch
        {
            ShapeKind.Arrow or ShapeKind.Line => Distance(p, A, B) <= reach,
            _ => p.X >= Math.Min(A.X, B.X) - reach && p.X <= Math.Max(A.X, B.X) + reach && p.Y >= Math.Min(A.Y, B.Y) - reach && p.Y <= Math.Max(A.Y, B.Y) + reach,
        };
    }

    static float Distance(Vector2 p, Vector2 a, Vector2 b)
    {
        var ab = b - a;
        var t = ab.LengthSquared() > 0 ? Math.Clamp(Vector2.Dot(p - a, ab) / ab.LengthSquared(), 0, 1) : 0;
        return Vector2.Distance(p, a + ab * t);
    }

    /// <summary>Draws in scene px (the session's transform maps them to the target). Text and shapes get a thin dark
    /// outline so they read on any background.</summary>
    public void Draw(CanvasDrawingSession ds, bool selected = false)
    {
        using var round = new CanvasStrokeStyle { StartCap = CanvasCapStyle.Round, EndCap = CanvasCapStyle.Round, LineJoin = CanvasLineJoin.Round };
        var halo = Color.FromArgb(120, 0, 0, 0);
        if (Stroke is { Count: > 1 } pts)
        {
            using var b = new CanvasPathBuilder(ds);
            b.BeginFigure(pts[0]);
            foreach (var p in pts.Skip(1)) b.AddLine(p);
            b.EndFigure(CanvasFigureLoop.Open);
            using var g = CanvasGeometry.CreatePath(b);
            ds.DrawGeometry(g, halo, Size + 2, round);
            ds.DrawGeometry(g, Color, Size, round);
        }
        else if (Text != null)
        {
            using var format = new CanvasTextFormat { FontSize = Math.Max(1, Size), FontWeight = new Windows.UI.Text.FontWeight { Weight = 600 }, WordWrapping = CanvasWordWrapping.NoWrap };
            using var layout = new CanvasTextLayout(ds, Text, format, 10_000, 10_000);
            using var geo = CanvasGeometry.CreateText(layout);
            ds.DrawGeometry(geo, A, halo, Math.Max(1, Size / 8), round);
            ds.DrawTextLayout(layout, A, Color);
        }
        else if (Shape is { } k)
        {
            var r = new Windows.Foundation.Rect(Math.Min(A.X, B.X), Math.Min(A.Y, B.Y), Math.Abs(B.X - A.X), Math.Abs(B.Y - A.Y));
            void Lines(Color c, float w)
            {
                switch (k)
                {
                    case ShapeKind.Rect: ds.DrawRectangle(r, c, w, round); break;
                    case ShapeKind.Ellipse: ds.DrawEllipse((float)(r.X + r.Width / 2), (float)(r.Y + r.Height / 2), (float)r.Width / 2, (float)r.Height / 2, c, w, round); break;
                    case ShapeKind.Line: ds.DrawLine(A, B, c, w, round); break;
                    case ShapeKind.Arrow:
                        ds.DrawLine(A, B, c, w, round);
                        var dir = B - A;
                        if (dir.LengthSquared() > 1)
                        {
                            dir = Vector2.Normalize(dir);
                            var head = Math.Max(14, w * 4);
                            var side = new Vector2(-dir.Y, dir.X);
                            ds.DrawLine(B, B - dir * head + side * head * 0.6f, c, w, round);
                            ds.DrawLine(B, B - dir * head - side * head * 0.6f, c, w, round);
                        }
                        break;
                }
            }
            Lines(halo, Size + 2);
            Lines(Color, Size);
        }
        if (selected && Bounds() is { } box) ds.DrawRectangle(box, Color.FromArgb(200, 77, 150, 255), 1.5f);
    }

    public Windows.Foundation.Rect? Bounds()
    {
        IEnumerable<Vector2> pts = Stroke ?? (Text != null ? [A, A + new Vector2(Text.Length * Size * 0.6f, Size * 1.3f)] : [A, B]);
        var list = pts.ToList();
        if (list.Count == 0) return null;
        float x0 = list.Min(p => p.X), y0 = list.Min(p => p.Y), x1 = list.Max(p => p.X), y1 = list.Max(p => p.Y);
        var pad = Size / 2 + 4;
        return new Windows.Foundation.Rect(x0 - pad, y0 - pad, x1 - x0 + 2 * pad, y1 - y0 + 2 * pad);
    }
}

/// <summary>Annotation mode state: the marks, the tool, and their own undo history (nothing here touches the
/// scene). Port of <c>AnnotationStore</c>.</summary>
public sealed class AnnotationSession
{
    public enum Tool { Select, Pen, Rect, Ellipse, Arrow, Line, Text }
    public bool Active;
    public Tool Current = Tool.Pen;
    public Color Color = Color.FromArgb(255, 255, 59, 48);
    public float Width = 6;
    public readonly List<Annotation> Items = [];
    public Annotation? Draft;
    public Annotation? Selected;
    readonly List<List<Annotation>> _undo = [], _redo = [];

    public void Record()
    {
        _undo.Add([.. Items]);
        _redo.Clear();
    }

    public void Undo()
    {
        if (_undo.Count == 0) return;
        _redo.Add([.. Items]);
        Items.Clear();
        Items.AddRange(_undo[^1]);
        _undo.RemoveAt(_undo.Count - 1);
        Selected = null;
    }

    public void Redo()
    {
        if (_redo.Count == 0) return;
        _undo.Add([.. Items]);
        Items.Clear();
        Items.AddRange(_redo[^1]);
        _redo.RemoveAt(_redo.Count - 1);
        Selected = null;
    }

    public void Delete()
    {
        if (Selected == null) return;
        Record();
        Items.Remove(Selected);
        Selected = null;
    }

    public void Close()
    {
        Active = false;
        Items.Clear();
        Draft = null;
        Selected = null;
        _undo.Clear();
        _redo.Clear();
    }
}
