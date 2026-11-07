namespace VeyMotion.Core;

/// <summary>Puts stock downloads into the asset library (the <see cref="StockImporter"/> contract): routed by type in
/// projects, reused when already imported, checked playable for sound and video, credited. Port of
/// <c>importItem</c>'s library side (<c>StockSources.swift</c> / <c>Assets.swift</c>).</summary>
public static class StockImport
{
    /// <summary>Decides whether a downloaded file is playable sound / a video (the app's media stack); null = assume yes.</summary>
    public static Func<string, StockKind, bool>? Playable { get; set; }

    public static StockAsset Import(StockImportRequest r)
    {
        var folder = AssetStore.ValidFolder(AssetStore.Routed(r.Folder, r.TypeFolder));
        var name = AssetStore.Join(folder, AssetStore.ValidName(r.FileName));
        if (r.ReuseExisting && r.Credit.Ref.Length > 0 && AssetStore.Credit(name) is { } old && old.Ref == r.Credit.Ref
            && File.Exists(AssetStore.PathFor(name)) && AssetStore.Info(AssetStore.PathFor(name)) is { } existing)
            return new StockAsset(existing.Path, existing.Name, existing.Summary);
        var info = AssetStore.Write(r.Download(), r.FileName, folder, r.Overwrite);
        if ((r.Kind.IsAudio() || r.Kind == StockKind.Video) && Playable?.Invoke(info.Path, r.Kind) == false)
        {
            try { AssetStore.Trash(info.Path); } catch (Exception e) when (e is IOException or AssetException) { }
            throw new SceneException(r.NotPlayableMessage);
        }
        AssetStore.SetCredit(r.Credit, info.Name);
        var fresh = AssetStore.Info(info.Path) ?? info;
        return new StockAsset(fresh.Path, fresh.Name, fresh.Summary);
    }
}
