using System.Buffers.Binary;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace VeyMotion.Core;

/// <summary>File kinds by extension, byte counts and Finder-like name order for the asset library (what macOS gets
/// from UTType, ByteCountFormatter and <c>localizedStandardCompare</c>).</summary>
public static class AssetFormat
{
    static readonly HashSet<string> Fonts = ["ttf", "otf", "ttc", "otc"];
    static readonly HashSet<string> Images =
        ["png", "jpg", "jpeg", "jpe", "gif", "bmp", "tif", "tiff", "webp", "heic", "heif", "avif", "svg", "svgz", "ico", "icns",
         "tga", "exr", "psd", "jxl", "jp2", "dds", "hdr"];
    static readonly HashSet<string> Audio =
        ["wav", "wave", "mp3", "m4a", "aac", "aif", "aiff", "aifc", "caf", "flac", "ogg", "oga", "opus", "wma", "mid", "midi", "amr", "m4r"];
    static readonly HashSet<string> Video =
        ["mp4", "m4v", "mov", "qt", "avi", "mkv", "webm", "wmv", "mpg", "mpeg", "m2ts", "mts", "3gp", "3g2", "flv", "ogv"];
    static readonly HashSet<string> Text =
        ["txt", "text", "md", "markdown", "json", "csv", "tsv", "xml", "html", "htm", "css", "js", "ts", "yaml", "yml",
         "srt", "vtt", "rtf", "log", "ini", "toml", "swift", "py", "sh", "cs", "c", "h", "cpp"];

    /// <summary>Lowercase extension without the dot ("" if none).</summary>
    public static string Extension(string path) => Path.GetExtension(path).TrimStart('.').ToLowerInvariant();

    public static AssetKind Kind(string path)
    {
        var ext = Extension(path);
        if (Fonts.Contains(ext)) return AssetKind.Font;
        if (Images.Contains(ext)) return AssetKind.Image;
        if (Audio.Contains(ext)) return AssetKind.Audio;
        if (Video.Contains(ext)) return AssetKind.Video;
        if (Text.Contains(ext)) return AssetKind.Text;
        return AssetKind.Other;
    }

    static readonly Dictionary<string, string> MimeToExtension = new(StringComparer.OrdinalIgnoreCase)
    {
        ["image/png"] = "png", ["image/jpeg"] = "jpeg", ["image/jpg"] = "jpeg", ["image/gif"] = "gif", ["image/webp"] = "webp",
        ["image/svg+xml"] = "svg", ["image/bmp"] = "bmp", ["image/tiff"] = "tiff", ["image/heic"] = "heic", ["image/avif"] = "avif",
        ["image/x-icon"] = "ico", ["image/vnd.microsoft.icon"] = "ico",
        ["audio/mpeg"] = "mp3", ["audio/mp3"] = "mp3", ["audio/wav"] = "wav", ["audio/x-wav"] = "wav", ["audio/wave"] = "wav",
        ["audio/vnd.wave"] = "wav", ["audio/ogg"] = "ogg", ["audio/opus"] = "opus", ["audio/flac"] = "flac", ["audio/x-flac"] = "flac",
        ["audio/mp4"] = "m4a", ["audio/x-m4a"] = "m4a", ["audio/aac"] = "aac", ["audio/aiff"] = "aiff", ["audio/x-aiff"] = "aiff",
        ["video/mp4"] = "mp4", ["video/quicktime"] = "mov", ["video/webm"] = "webm", ["video/x-msvideo"] = "avi",
        ["video/x-matroska"] = "mkv", ["video/mpeg"] = "mpg",
        ["application/json"] = "json", ["text/plain"] = "txt", ["text/csv"] = "csv", ["text/html"] = "html", ["text/xml"] = "xml",
        ["application/xml"] = "xml", ["text/markdown"] = "md",
        ["font/ttf"] = "ttf", ["font/otf"] = "otf", ["font/collection"] = "ttc", ["application/x-font-ttf"] = "ttf",
        ["application/font-sfnt"] = "ttf",
    };

    /// <summary>The usual extension for a MIME type ("image/png" → "png"), or null.</summary>
    public static string? ExtensionForMime(string? mime) =>
        mime == null ? null : MimeToExtension.GetValueOrDefault(mime.Split(';')[0].Trim());

    /// <summary>MIME type of an image file the MCP clients can show (png, jpeg, gif, webp), or null.</summary>
    public static string? ImageMime(string path) => Extension(path) switch
    {
        "png" => "image/png",
        "jpg" or "jpeg" or "jpe" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        _ => null,
    };

    /// <summary>Like <c>ByteCountFormatter</c> with the file style: decimal units, "245 KB", "1.2 MB", "12 bytes".</summary>
    public static string ByteCount(long bytes)
    {
        var inv = CultureInfo.InvariantCulture;
        if (bytes == 0) return "Zero KB";
        if (bytes == 1) return "1 byte";
        if (bytes < 1000) return $"{bytes} bytes";
        string Num(double v, int decimals) => Math.Round(v, decimals, MidpointRounding.AwayFromZero)
            .ToString(decimals == 0 ? "0" : "0." + new string('#', decimals), inv);
        if (bytes < 999_500) return Num(bytes / 1e3, 0) + " KB";
        if (bytes < 999_950_000) return Num(bytes / 1e6, 1) + " MB";
        if (bytes < 999_995_000_000) return Num(bytes / 1e9, 2) + " GB";
        return Num(bytes / 1e12, 2) + " TB";
    }

    /// <summary>Finder-like order: digit runs compare as numbers, letters without case.</summary>
    public static readonly IComparer<string> NaturalOrder = Comparer<string>.Create(NaturalCompare);

    public static int NaturalCompare(string? a, string? b)
    {
        a ??= ""; b ??= "";
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsAsciiDigit(a[i]) && char.IsAsciiDigit(b[j]))
            {
                int si = i, sj = j;
                while (i < a.Length && char.IsAsciiDigit(a[i])) i++;
                while (j < b.Length && char.IsAsciiDigit(b[j])) j++;
                var da = a[si..i].TrimStart('0');
                var db = b[sj..j].TrimStart('0');
                if (da.Length != db.Length) return da.Length.CompareTo(db.Length);
                var c = string.CompareOrdinal(da, db);
                if (c != 0) return c;
            }
            else
            {
                var c = string.Compare(a, i, b, j, 1, CultureInfo.InvariantCulture, CompareOptions.IgnoreCase);
                if (c != 0) return c;
                i++; j++;
            }
        }
        var rest = (a.Length - i).CompareTo(b.Length - j);
        return rest != 0 ? rest : string.CompareOrdinal(a, b);
    }
}

/// <summary>Pixel size from an image file's header (PNG, JPEG, GIF, BMP, WebP, SVG) without decoding it.</summary>
public static class ImageHeader
{
    public static (int Width, int Height)? Size(string path)
    {
        try
        {
            using var f = File.OpenRead(path);
            var head = new byte[32];
            var n = f.ReadAtLeast(head, head.Length, throwOnEndOfStream: false);
            if (n >= 24 && head[0] == 0x89 && head[1] == 'P' && head[2] == 'N' && head[3] == 'G')
                return (BinaryPrimitives.ReadInt32BigEndian(head.AsSpan(16)), BinaryPrimitives.ReadInt32BigEndian(head.AsSpan(20)));
            if (n >= 10 && head[0] == 'G' && head[1] == 'I' && head[2] == 'F')
                return (BinaryPrimitives.ReadUInt16LittleEndian(head.AsSpan(6)), BinaryPrimitives.ReadUInt16LittleEndian(head.AsSpan(8)));
            if (n >= 26 && head[0] == 'B' && head[1] == 'M')
                return (Math.Abs(BinaryPrimitives.ReadInt32LittleEndian(head.AsSpan(18))), Math.Abs(BinaryPrimitives.ReadInt32LittleEndian(head.AsSpan(22))));
            if (n >= 30 && Encoding.ASCII.GetString(head, 0, 4) == "RIFF" && Encoding.ASCII.GetString(head, 8, 4) == "WEBP")
                return WebP(head);
            if (n >= 4 && head[0] == 0xFF && head[1] == 0xD8)
            {
                f.Position = 2;
                return Jpeg(f);
            }
            if (AssetFormat.Extension(path) == "svg")
            {
                f.Position = 0;
                var buf = new byte[65536];
                var len = f.ReadAtLeast(buf, buf.Length, throwOnEndOfStream: false);
                return Svg(Encoding.UTF8.GetString(buf, 0, len));
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { }
        return null;
    }

    static (int, int)? WebP(byte[] h)
    {
        var chunk = Encoding.ASCII.GetString(h, 12, 4);
        switch (chunk)
        {
            case "VP8 ":
                return (BinaryPrimitives.ReadUInt16LittleEndian(h.AsSpan(26)) & 0x3FFF, BinaryPrimitives.ReadUInt16LittleEndian(h.AsSpan(28)) & 0x3FFF);
            case "VP8L":
                int b0 = h[21], b1 = h[22], b2 = h[23], b3 = h[24];
                return (1 + (((b1 & 0x3F) << 8) | b0), 1 + (((b3 & 0xF) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6)));
            case "VP8X":
                return (1 + (h[24] | (h[25] << 8) | (h[26] << 16)), 1 + (h[27] | (h[28] << 8) | (h[29] << 16)));
            default:
                return null;
        }
    }

    static (int, int)? Jpeg(Stream f)
    {
        var two = new byte[2];
        while (true)
        {
            int b;
            do { b = f.ReadByte(); } while (b != -1 && b != 0xFF);
            do { b = f.ReadByte(); } while (b == 0xFF);
            if (b == -1) return null;
            if (b is 0xD8 or 0x01 or (>= 0xD0 and <= 0xD7)) continue; // markers without a length
            if (b == 0xD9 || b == 0xDA) return null; // end of image / start of scan before any frame header
            if (f.ReadAtLeast(two, 2, false) < 2) return null;
            var len = BinaryPrimitives.ReadUInt16BigEndian(two);
            if (b is >= 0xC0 and <= 0xCF and not 0xC4 and not 0xC8 and not 0xCC)
            {
                var sof = new byte[5];
                if (f.ReadAtLeast(sof, 5, false) < 5) return null;
                return (BinaryPrimitives.ReadUInt16BigEndian(sof.AsSpan(3)), BinaryPrimitives.ReadUInt16BigEndian(sof.AsSpan(1)));
            }
            if (len < 2) return null;
            f.Seek(len - 2, SeekOrigin.Current);
        }
    }

    static readonly Regex SvgTag = new(@"<svg\b[^>]*>", RegexOptions.IgnoreCase | RegexOptions.Singleline);

    static (int, int)? Svg(string text)
    {
        if (SvgTag.Match(text) is not { Success: true } tag) return null;
        string? Attr(string name) =>
            Regex.Match(tag.Value, $@"\s{name}\s*=\s*[""']([^""']*)[""']", RegexOptions.IgnoreCase) is { Success: true } m ? m.Groups[1].Value : null;
        static double? Length(string? s)
        {
            if (s == null || s.Contains('%')) return null;
            var m = Regex.Match(s.Trim(), @"^([0-9]*\.?[0-9]+(?:e[-+]?\d+)?)\s*(px|pt|in|cm|mm|pc)?$", RegexOptions.IgnoreCase);
            if (!m.Success || !double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var v)) return null;
            return v * (m.Groups[2].Value.ToLowerInvariant() switch
            {
                "pt" => 4.0 / 3, "in" => 96, "cm" => 96 / 2.54, "mm" => 96 / 25.4, "pc" => 16, _ => 1,
            });
        }
        var w = Length(Attr("width"));
        var h = Length(Attr("height"));
        if (Attr("viewBox") is { } vb)
        {
            var nums = vb.Split([' ', ',', '\t', '\n', '\r'], StringSplitOptions.RemoveEmptyEntries)
                .Select(s => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : double.NaN).ToArray();
            if (nums.Length == 4 && nums[2] > 0 && nums[3] > 0)
            {
                if (w == null && h == null) { w = nums[2]; h = nums[3]; }
                else if (w == null) w = h * nums[2] / nums[3];
                else if (h == null) h = w * nums[3] / nums[2];
            }
        }
        if (w is not > 0 || h is not > 0) return null;
        return ((int)Math.Round(w.Value), (int)Math.Round(h.Value));
    }
}

/// <summary>Moves files and folders to the Windows Recycle Bin (macOS <c>FileManager.trashItem</c>).</summary>
public static class RecycleBin
{
    public static void Send(string path)
    {
        if (!OperatingSystem.IsWindows())
            throw AssetException.Failed("Moving files to the Recycle Bin is only supported on Windows");
        var full = Path.GetFullPath(path);
        var op = new ShFileOpStruct
        {
            wFunc = FO_DELETE,
            pFrom = full + '\0', // double-null terminated list
            fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI,
        };
        var code = SHFileOperationW(ref op);
        if (code != 0 || op.fAnyOperationsAborted)
            throw AssetException.Failed($"Cannot move {full} to the Recycle Bin (error 0x{code:X})");
    }

    const uint FO_DELETE = 3;
    const ushort FOF_SILENT = 0x4, FOF_NOCONFIRMATION = 0x10, FOF_ALLOWUNDO = 0x40, FOF_NOERRORUI = 0x400;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct ShFileOpStruct
    {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string? pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    static extern int SHFileOperationW(ref ShFileOpStruct op);
}
