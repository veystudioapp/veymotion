using Microsoft.UI.Xaml;

namespace VeyMotion.App;

public partial class App : Application
{
    Window? _window;

    public App() => InitializeComponent();

    /// <summary>The faces in a font file ("Be Vietnam Pro Bold"), for the asset list.</summary>
    static List<string>? FontFaces(string path)
    {
        try
        {
            using var set = new Microsoft.Graphics.Canvas.Text.CanvasFontSet(new Uri(path));
            return set.Fonts.Select(f => f.GetInformationalStrings(Microsoft.Graphics.Canvas.Text.CanvasFontInformation.FullName) is var names && names.TryGetValue("en-us", out var n) ? n : names.Values.FirstOrDefault() ?? "").Where(n => n.Length > 0).ToList();
        }
        catch (Exception e) when (e is ArgumentException or System.Runtime.InteropServices.COMException or UriFormatException) { return null; }
    }

    static bool IsMovie(string path)
    {
        using var movie = Media.MovieReader.Open(path);
        return movie != null;
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Core.AudioAnalysisCache.Source = Media.AudioDecoder.Shared;
        Core.AssetStore.MediaProbe = new MediaProbe();
        Core.AssetStore.PreviewPng = Rendering.ImageTools.PreviewPng;
        Core.AssetStore.FontFacesReader = FontFaces;
        Core.StockImport.Playable = (path, kind) => kind == Core.StockKind.Video
            ? IsMovie(path)
            : Media.AudioDecoder.Shared.Stereo48k(path) != null;
        var cli = Environment.GetCommandLineArgs().Skip(1).ToArray();
        if (Headless.IsHeadless(cli))
        {
            // The `vmotion` CLI's renderer: no window.
            if (Headless.Run(cli) is { } code) Environment.Exit(code);
            return;
        }
        // `VeyMotion.exe scene.json` opens that scene; otherwise the demo.
        var path = cli.FirstOrDefault(a => !a.StartsWith('-'));
        _window = new MainWindow(path);
        _window.Activate();
    }
}
