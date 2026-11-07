namespace VeyMotion.Core;

/// <summary>Splits an image into irregular shards for a "shatter" effect: shards are cut from a jittered grid
/// (interior points nudged at random, corners shared between neighbors so they still tile the whole picture with no
/// gaps), deterministic from the seed. Port of the geometry of <c>ImageShatter</c> (<c>Shatter.swift</c>); the
/// platform cuts the pixels.</summary>
public static class ImageShatter
{
    /// <summary>One shard: its quad and bounding box in source image pixels (origin top-left, y down) and its centroid.</summary>
    public sealed record Cell(PathPoint[] Quad, double X, double Y, double W, double H, PathPoint Centroid);

    /// <summary>count is a target: the actual number of shards is rows × cols, chosen close to it from the aspect.</summary>
    public static List<Cell> Cells(double w, double h, int count, long seed)
    {
        if (w < 2 || h < 2) throw new SceneException("Image is too small to shatter");
        double target = Math.Max(count, 1);
        var cols = Math.Max(1, (int)PixelBuffer.Round(Math.Sqrt(target * w / h)));
        var rows = Math.Max(1, (int)PixelBuffer.Round(Math.Sqrt(target * h / w)));
        double cellW = w / cols, cellH = h / rows;
        var salt = Noise.Mix(Noise.Hash("shatter") ^ unchecked((ulong)seed));
        // (rows+1) × (cols+1) grid; only interior points are jittered, so adjoining cells still share an edge.
        var points = new PathPoint[rows + 1, cols + 1];
        for (var r = 0; r <= rows; r++)
            for (var c = 0; c <= cols; c++)
            {
                double x = c * cellW, y = r * cellH;
                if (r > 0 && r < rows && c > 0 && c < cols)
                {
                    var key = Noise.Mix(salt ^ unchecked((ulong)(r * (cols + 1) + c)));
                    x += (Noise.Unit(0, key) - 0.5) * cellW * 0.7;
                    y += (Noise.Unit(1, key) - 0.5) * cellH * 0.7;
                }
                points[r, c] = new PathPoint(x, y);
            }
        var output = new List<Cell>();
        for (var r = 0; r < rows; r++)
            for (var c = 0; c < cols; c++)
            {
                PathPoint[] quad = [points[r, c], points[r, c + 1], points[r + 1, c + 1], points[r + 1, c]];
                double minX = quad.Min(p => p.X), maxX = quad.Max(p => p.X), minY = quad.Min(p => p.Y), maxY = quad.Max(p => p.Y);
                if (maxX - minX <= 0.5 || maxY - minY <= 0.5) continue;
                output.Add(new Cell(quad, minX, minY, maxX - minX, maxY - minY, new PathPoint(quad.Average(p => p.X), quad.Average(p => p.Y))));
            }
        return output;
    }
}
