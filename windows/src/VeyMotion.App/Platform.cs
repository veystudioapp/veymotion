using System.Text;
using Microsoft.Graphics.Canvas.Text;
using VeyMotion.App.Rendering;
using VeyMotion.Core;
using VeyMotion.Mcp;
using Windows.Storage;

namespace VeyMotion.App;


/// <summary>File lengths from the Windows property system (Media Foundation reads the headers).</summary>
sealed class MediaProbe : IMediaProbe
{
    public double? Duration(string path, bool video)
    {
        try
        {
            var file = StorageFile.GetFileFromPathAsync(Path.GetFullPath(path)).AsTask().GetAwaiter().GetResult();
            var duration = video
                ? file.Properties.GetVideoPropertiesAsync().AsTask().GetAwaiter().GetResult().Duration
                : file.Properties.GetMusicPropertiesAsync().AsTask().GetAwaiter().GetResult().Duration;
            return duration > TimeSpan.Zero ? duration.TotalSeconds : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or System.Runtime.InteropServices.COMException) { return null; }
    }
}
