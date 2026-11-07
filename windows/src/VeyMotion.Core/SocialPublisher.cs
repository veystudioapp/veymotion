using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

/// <summary>Uploads to YouTube, TikTok, Facebook Pages and X. Port of <c>SocialPublisher</c>.</summary>
public static class SocialPublisher
{
    /// <summary>Uploads and publishes <c>req.File</c> with the stored account <paramref name="accountKey"/>.
    /// <paramref name="progress"/> gets 0…1 and a short status line (on a background thread).</summary>
    public static async Task<PublishResult> PublishAsync(SocialPlatform platform, string accountKey, PublishRequest req,
        Action<double, string> progress, CancellationToken ct = default)
    {
        if (!platform.Accepts(req.File))
            throw new PublishException($"{platform.Name()} needs an MP4 file{(platform == SocialPlatform.X ? "" : " or MOV")} (export as MP4 — H.264).");
        var size = FileSize(req.File);
        if (size <= 0) throw new PublishException("The video file is empty.");
        if (size > platform.MaxBytes())
            throw new PublishException($"{platform.Name()} accepts files up to {AssetFormat.ByteCount(platform.MaxBytes())}.");
        var account = await SocialAuth.ValidAccountAsync(accountKey, ct);
        var up = new Uploader(req.File, size, ct, progress);
        return platform switch
        {
            SocialPlatform.Youtube => await YoutubeAsync(req, account, up),
            SocialPlatform.Tiktok => await TiktokAsync(req, account, up),
            SocialPlatform.Facebook => await FacebookAsync(req, account, up),
            _ => await XAsync(req, account, up),
        };
    }

    // Profiles

    internal static async Task LoadProfileAsync(SocialAccount a, CancellationToken ct)
    {
        var token = a.AccessToken;
        switch (a.Platform)
        {
            case SocialPlatform.Youtube:
            {
                var obj = (await PublishHttp.CallAsync("GET", "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true", ct,
                    bearer: token)).Json;
                var first = (obj["items"] as JsonArray)?.FirstOrDefault() as JsonObject;
                a.DisplayName = StockHttp.Str(first?["snippet"], "title");
                a.UserId = StockHttp.Str(first, "id");
                if (a.UserId == null) throw new PublishException("This Google account has no YouTube channel. Create one at youtube.com first.");
                break;
            }
            case SocialPlatform.Tiktok:
            {
                var obj = (await PublishHttp.CallAsync("GET", "https://open.tiktokapis.com/v2/user/info/?fields=open_id,display_name", ct,
                    bearer: token)).Json;
                TiktokCheck(obj);
                var user = obj["data"]?["user"];
                a.DisplayName = StockHttp.Str(user, "display_name");
                a.UserId = StockHttp.Str(user, "open_id") ?? a.UserId;
                break;
            }
            case SocialPlatform.Facebook:
            {
                var v = await GraphVersionAsync(ct);
                var me = (await PublishHttp.CallAsync("GET", $"https://graph.facebook.com/{v}/me?fields=id,name&access_token={Enc(token)}", ct)).Json;
                a.DisplayName = StockHttp.Str(me, "name");
                a.UserId = StockHttp.Str(me, "id");
                var list = (await PublishHttp.CallAsync("GET",
                    $"https://graph.facebook.com/{v}/me/accounts?fields=id,name,access_token&limit=100&access_token={Enc(token)}", ct)).Json;
                a.Pages = (list["data"] as JsonArray ?? []).Select(p =>
                    StockHttp.Str(p, "id") is { } id && StockHttp.Str(p, "access_token") is { } t
                        ? new FacebookPage(id, StockHttp.Str(p, "name") ?? id, t) : null).OfType<FacebookPage>().ToList();
                if (a.Pages.Count == 0)
                    throw new PublishException("No Facebook Pages found. VeyMotion posts to Pages you manage (Facebook does not allow posting to personal profiles through its API).");
                break;
            }
            case SocialPlatform.X:
            {
                var obj = (await PublishHttp.CallAsync("GET", "https://api.x.com/2/users/me", ct, bearer: token)).Json;
                var data = obj["data"];
                a.Username = StockHttp.Str(data, "username");
                a.DisplayName = a.Username != null ? $"@{a.Username}" : StockHttp.Str(data, "name");
                a.UserId = StockHttp.Str(data, "id");
                break;
            }
        }
    }

    // YouTube (resumable upload)

    static async Task<PublishResult> YoutubeAsync(PublishRequest req, SocialAccount a, Uploader up)
    {
        up.Status(0, "Starting upload…");
        var title = Prefix(req.Title.Length == 0 ? Path.GetFileNameWithoutExtension(req.File) : req.Title, SocialPlatform.Youtube.TitleLimit());
        var snippet = new JsonObject { ["title"] = title, ["description"] = req.Description, ["categoryId"] = "22" };
        if (req.Tags.Count > 0) snippet["tags"] = new JsonArray(req.Tags.Select(t => (JsonNode)t).ToArray());
        var meta = new JsonObject
        {
            ["snippet"] = snippet,
            ["status"] = new JsonObject { ["privacyStatus"] = req.YoutubePrivacy, ["selfDeclaredMadeForKids"] = false },
        };
        var start = await PublishHttp.CallAsync("POST",
            "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status", up.Token,
            bearer: a.AccessToken, json: meta,
            headers: new Dictionary<string, string> { ["X-Upload-Content-Length"] = $"{up.Size}", ["X-Upload-Content-Type"] = up.MimeType });
        if (!start.Headers.TryGetValue("Location", out var location) || !Uri.TryCreate(location, UriKind.Absolute, out var uploadUrl))
            throw new PublishException("YouTube did not return an upload address.");

        const int chunk = 64 * 256 * 1024; // 16 MB, a multiple of 256 KB as YouTube requires
        long offset = 0;
        JsonObject? final = null;
        while (final == null)
        {
            up.CheckCancelled();
            var length = Math.Min(chunk, up.Size - offset);
            var r = new HttpRequestMessage(HttpMethod.Put, uploadUrl) { Content = new ProgressContent(up.File, offset, length, up.MimeType) };
            r.Headers.TryAddWithoutValidation("Authorization", $"Bearer {a.AccessToken}");
            r.Content.SetRange(offset, length, up.Size);
            var sentBefore = offset;
            var res = await PublishHttp.SendAsync(r, up.Token, timeout: 600,
                onProgress: sent => up.Status((double)(sentBefore + sent) / up.Size, "Uploading to YouTube…"));
            switch (res.Status)
            {
                case 308:
                    // "Resume Incomplete": Range says what YouTube has, e.g. "bytes=0-16777215".
                    offset = res.Headers.TryGetValue("Range", out var range) && long.TryParse(range.Split('-')[^1], out var last) ? last + 1 : 0;
                    break;
                case 200 or 201:
                    final = res.Json;
                    break;
                default:
                    throw new PublishException(PlatformMessage(SocialPlatform.Youtube, res));
            }
        }
        var id = StockHttp.Str(final, "id") ?? throw new PublishException("YouTube did not return a video id.");
        var note = "YouTube is processing the video; it may take a few minutes before it plays in full quality.";
        if (req.Thumbnail is { } thumb)
        {
            up.Status(0.99, "Setting the thumbnail…");
            try
            {
                await PublishHttp.CallAsync("POST", $"https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId={id}&uploadType=media",
                    up.Token, bearer: a.AccessToken, body: thumb, contentType: "image/jpeg");
            }
            catch (PublishException e) when (e is not PublishCancelledException)
            {
                note += $" The thumbnail was not set ({e.Message}). Custom thumbnails need a verified channel: youtube.com/verify.";
            }
        }
        up.Status(1, "Uploaded");
        return new PublishResult(SocialPlatform.Youtube, id, $"https://youtu.be/{id}", note);
    }

    // TikTok (Content Posting API)

    /// <summary>What TikTok allows the creator to post; show it before a direct post, as TikTok requires.</summary>
    public static async Task<TikTokCreatorInfo> TiktokCreatorInfoAsync(string accountKey, CancellationToken ct = default)
    {
        var a = await SocialAuth.ValidAccountAsync(accountKey, ct);
        var obj = (await PublishHttp.CallAsync("POST", "https://open.tiktokapis.com/v2/post/publish/creator_info/query/", ct,
            bearer: a.AccessToken, json: [])).Json;
        TiktokCheck(obj);
        var d = obj["data"] as JsonObject ?? [];
        return new TikTokCreatorInfo(
            StockHttp.Str(d, "creator_nickname") ?? a.DisplayName ?? "TikTok",
            StockHttp.Str(d, "creator_username"),
            StockHttp.Strings(d, "privacy_level_options") ?? [],
            StockHttp.Bool(d, "comment_disabled") ?? false,
            StockHttp.Bool(d, "duet_disabled") ?? false,
            StockHttp.Bool(d, "stitch_disabled") ?? false,
            StockHttp.Double(d, "max_video_post_duration_sec"));
    }

    static async Task<PublishResult> TiktokAsync(PublishRequest req, SocialAccount a, Uploader up)
    {
        up.Status(0, "Starting upload…");
        // Files up to 64 MB go in one chunk; bigger ones in 10 MB chunks (TikTok allows 5–64 MB), the count
        // rounded down so the last chunk takes the remainder.
        var chunk = up.Size <= 64L << 20 ? up.Size : 10L << 20;
        var count = Math.Max(1, up.Size / chunk);
        var source = new JsonObject
        {
            ["source"] = "FILE_UPLOAD", ["video_size"] = up.Size, ["chunk_size"] = chunk, ["total_chunk_count"] = count,
        };
        var direct = req.TiktokMode == TikTokMode.Direct;
        var body = new JsonObject { ["source_info"] = source };
        if (direct)
        {
            var privacy = req.TiktokPrivacy ?? throw new PublishException("Choose who can see the TikTok post.");
            body["post_info"] = new JsonObject
            {
                ["title"] = Prefix(req.Title, SocialPlatform.Tiktok.TitleLimit()),
                ["privacy_level"] = privacy,
                ["disable_comment"] = req.DisableComments,
                ["disable_duet"] = req.DisableDuet,
                ["disable_stitch"] = req.DisableStitch,
                ["video_cover_timestamp_ms"] = (int)Math.Round((req.CoverTime ?? 0) * 1000, MidpointRounding.AwayFromZero),
            };
        }
        var initUrl = direct ? "https://open.tiktokapis.com/v2/post/publish/video/init/"
                             : "https://open.tiktokapis.com/v2/post/publish/inbox/video/init/";
        var initRes = (await PublishHttp.CallAsync("POST", initUrl, up.Token, bearer: a.AccessToken, json: body)).Json;
        TiktokCheck(initRes);
        var data = initRes["data"];
        if (StockHttp.Str(data, "publish_id") is not { } publishId
            || StockHttp.Str(data, "upload_url") is not { } u || !Uri.TryCreate(u, UriKind.Absolute, out var uploadUrl))
            throw new PublishException("TikTok did not return an upload address.");

        for (long i = 0; i < count; i++)
        {
            up.CheckCancelled();
            var first = i * chunk;
            var length = i == count - 1 ? up.Size - first : chunk;
            var r = new HttpRequestMessage(HttpMethod.Put, uploadUrl) { Content = new ProgressContent(up.File, first, length, up.MimeType) };
            r.Content.SetRange(first, length, up.Size);
            var res = await PublishHttp.SendAsync(r, up.Token, timeout: 600,
                onProgress: sent => up.Status(0.95 * (first + sent) / up.Size, "Uploading to TikTok…"));
            if (res.Status is not (201 or 206 or 200)) throw new PublishException(PlatformMessage(SocialPlatform.Tiktok, res));
        }

        // TikTok processes the upload asynchronously; wait a while for the final state.
        up.Status(0.95, "TikTok is processing the video…");
        var deadline = DateTime.UtcNow.AddSeconds(180);
        while (DateTime.UtcNow < deadline)
        {
            up.CheckCancelled();
            var s = (await PublishHttp.CallAsync("POST", "https://open.tiktokapis.com/v2/post/publish/status/fetch/", up.Token,
                bearer: a.AccessToken, json: new JsonObject { ["publish_id"] = publishId })).Json;
            TiktokCheck(s);
            var d = s["data"] as JsonObject ?? [];
            switch (StockHttp.Str(d, "status"))
            {
                case "SEND_TO_USER_INBOX":
                    up.Status(1, "Sent to TikTok");
                    return new PublishResult(SocialPlatform.Tiktok, publishId, null,
                        "Open the TikTok app: the video is in your inbox notifications, ready to edit and post.");
                case "PUBLISH_COMPLETE":
                {
                    up.Status(1, "Posted");
                    var postId = (d["publicaly_available_post_id"] as JsonArray)?.FirstOrDefault() is JsonValue pv
                        ? (pv.GetValueKind() == JsonValueKind.String ? pv.GetValue<string>() : pv.ToJsonString()) : null;
                    string? user = null;
                    try { user = (await TiktokCreatorInfoAsync(a.Key, up.Token)).Username; }
                    catch (PublishException e) when (e is not PublishCancelledException) { }
                    var url = postId != null && user != null ? $"https://www.tiktok.com/@{user}/video/{postId}" : null;
                    return new PublishResult(SocialPlatform.Tiktok, postId ?? publishId, url,
                        postId == null ? "Posted. Unaudited TikTok apps can only post privately (Only me)." : null);
                }
                case "FAILED":
                    throw new PublishException($"TikTok could not post the video: {StockHttp.Str(d, "fail_reason") ?? "unknown reason"}.");
                default:
                    await up.DelayAsync(3);
                    break;
            }
        }
        return new PublishResult(SocialPlatform.Tiktok, publishId, null,
            "Uploaded. TikTok is still processing the video; check the TikTok app in a few minutes.");
    }

    static void TiktokCheck(JsonObject obj)
    {
        if (obj["error"] is not JsonObject err || StockHttp.Str(err, "code") is not { } code || code == "ok") return;
        throw new PublishException($"TikTok: {StockHttp.Str(err, "message") ?? code} ({code})");
    }

    // Facebook Pages (resumable upload API)

    static async Task<PublishResult> FacebookAsync(PublishRequest req, SocialAccount a, Uploader up)
    {
        if (a.Pages is not { Count: > 0 } pages) throw new PublishException("Connect a Facebook account that manages a Page.");
        var page = pages.FirstOrDefault(p => p.Id == req.FacebookPageId) ?? (pages.Count == 1 ? pages[0] : null)
            ?? throw new PublishException("Choose the Facebook Page to post to.");
        var v = await GraphVersionAsync(up.Token);
        var appId = (await SocialServer.ProvidersAsync(ct: up.Token)).GetValueOrDefault(SocialPlatform.Facebook)?.AppId
            ?? throw new PublishException("The server did not return the Facebook app id.");
        up.Status(0, "Starting upload…");
        var session = (await PublishHttp.CallAsync("POST",
            $"https://graph.facebook.com/{v}/{appId}/uploads?file_name={Enc(Path.GetFileName(req.File))}"
            + $"&file_length={up.Size}&file_type={Enc(up.MimeType)}&access_token={Enc(a.AccessToken)}", up.Token)).Json;
        var sessionId = StockHttp.Str(session, "id") ?? throw new PublishException("Facebook did not start an upload session.");

        var r = new HttpRequestMessage(HttpMethod.Post, $"https://graph.facebook.com/{v}/{sessionId}")
        {
            Content = new ProgressContent(up.File, 0, up.Size),
        };
        r.Headers.TryAddWithoutValidation("Authorization", $"OAuth {a.AccessToken}");
        r.Headers.TryAddWithoutValidation("file_offset", "0");
        var uploaded = await PublishHttp.SendAsync(r, up.Token, timeout: 3600,
            onProgress: sent => up.Status(0.95 * sent / up.Size, "Uploading to Facebook…"));
        if (uploaded.Status is < 200 or >= 300 || StockHttp.Str(uploaded.Json, "h") is not { } handle)
            throw new PublishException(PlatformMessage(SocialPlatform.Facebook, uploaded));

        up.Status(0.97, $"Publishing on {page.Name}…");
        var fields = new Dictionary<string, string>
        {
            ["access_token"] = page.AccessToken,
            ["fbuploader_video_file_chunk"] = handle,
            ["description"] = req.Description.Length == 0 ? req.Title : req.Description,
        };
        if (req.Title.Length > 0) fields["title"] = Prefix(req.Title, SocialPlatform.Facebook.TitleLimit());
        var post = (await PublishHttp.CallAsync("POST", $"https://graph-video.facebook.com/{v}/{page.Id}/videos", up.Token, form: fields)).Json;
        var id = StockHttp.Str(post, "id") ?? throw new PublishException("Facebook did not return a video id.");
        var note = $"Facebook is processing the video; it appears on {page.Name} when it is ready.";
        if (req.Thumbnail is { } thumb)
        {
            up.Status(0.99, "Setting the thumbnail…");
            try
            {
                var (body, type) = PublishHttp.Multipart(
                    new Dictionary<string, string> { ["access_token"] = page.AccessToken, ["is_preferred"] = "true" },
                    ("source", "thumbnail.jpg", "image/jpeg", thumb));
                await PublishHttp.CallAsync("POST", $"https://graph.facebook.com/{v}/{id}/thumbnails", up.Token, body: body, contentType: type);
            }
            catch (PublishException e) when (e is not PublishCancelledException)
            {
                note += $" The thumbnail was not set ({e.Message}); you can change it on the video's page.";
            }
        }
        up.Status(1, "Posted");
        return new PublishResult(SocialPlatform.Facebook, id, $"https://www.facebook.com/{page.Id}/videos/{id}", note);
    }

    static async Task<string> GraphVersionAsync(CancellationToken ct) =>
        (await SocialServer.ProvidersAsync(ct: ct)).GetValueOrDefault(SocialPlatform.Facebook)?.GraphVersion ?? "v27.0";

    // X (media upload v2 + post)

    static async Task<PublishResult> XAsync(PublishRequest req, SocialAccount a, Uploader up)
    {
        up.Status(0, "Starting upload…");
        var start = (await PublishHttp.CallAsync("POST", "https://api.x.com/2/media/upload/initialize", up.Token, bearer: a.AccessToken,
            json: new JsonObject { ["media_type"] = "video/mp4", ["total_bytes"] = up.Size, ["media_category"] = "tweet_video" })).Json;
        var mediaId = XMediaId(start) ?? throw new PublishException("X did not return a media id.");

        const int chunk = 4 << 20;
        var index = 0;
        long offset = 0;
        while (offset < up.Size)
        {
            var bytes = await up.ReadAsync(offset, chunk);
            if (bytes.Length == 0) throw new PublishException("The video file ended early.");
            var boundary = $"veymotion-{Guid.NewGuid().ToString().ToUpperInvariant()}";
            using var ms = new MemoryStream();
            void Append(string s) => ms.Write(Encoding.UTF8.GetBytes(s));
            Append($"--{boundary}\r\nContent-Disposition: form-data; name=\"segment_index\"\r\n\r\n{index}\r\n");
            Append($"--{boundary}\r\nContent-Disposition: form-data; name=\"media\"; filename=\"chunk\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n");
            ms.Write(bytes);
            Append($"\r\n--{boundary}--\r\n");
            var r = new HttpRequestMessage(HttpMethod.Post, $"https://api.x.com/2/media/upload/{mediaId}/append")
            {
                Content = new ProgressContent(ms.ToArray(), $"multipart/form-data; boundary={boundary}"),
            };
            r.Headers.TryAddWithoutValidation("Authorization", $"Bearer {a.AccessToken}");
            var sentBefore = offset;
            var res = await PublishHttp.SendAsync(r, up.Token, timeout: 600,
                onProgress: sent => up.Status(0.9 * (sentBefore + Math.Min(sent, bytes.Length)) / up.Size, "Uploading to X…"));
            if (res.Status is < 200 or >= 300) throw new PublishException(PlatformMessage(SocialPlatform.X, res));
            offset += bytes.Length;
            index += 1;
        }

        var fin = (await PublishHttp.CallAsync("POST", $"https://api.x.com/2/media/upload/{mediaId}/finalize", up.Token,
            bearer: a.AccessToken)).Json;
        var info = fin["data"]?["processing_info"] as JsonObject;
        var deadline = DateTime.UtcNow.AddSeconds(300);
        while (StockHttp.Str(info, "state") is { } state && state != "succeeded")
        {
            if (state == "failed")
                throw new PublishException($"X could not process the video: {StockHttp.Str(info?["error"], "message") ?? "processing failed"}");
            if (DateTime.UtcNow >= deadline) throw new PublishException("X is taking too long to process the video. Try again later.");
            up.CheckCancelled();
            up.Status(0.92, "X is processing the video…");
            await up.DelayAsync(Math.Min(Math.Max(StockHttp.Double(info, "check_after_secs") ?? 2, 1), 10));
            var s = (await PublishHttp.CallAsync("GET", $"https://api.x.com/2/media/upload?command=STATUS&media_id={mediaId}", up.Token,
                bearer: a.AccessToken)).Json;
            info = ((s["data"] as JsonObject) ?? s)["processing_info"] as JsonObject;
        }

        up.Status(0.97, "Posting…");
        var post = (await PublishHttp.CallAsync("POST", "https://api.x.com/2/tweets", up.Token, bearer: a.AccessToken,
            json: new JsonObject
            {
                ["text"] = Prefix(req.Title, SocialPlatform.X.TitleLimit()),
                ["media"] = new JsonObject { ["media_ids"] = new JsonArray(mediaId) },
            })).Json;
        var id = StockHttp.Str(post["data"], "id") ?? throw new PublishException("X did not return a post id.");
        up.Status(1, "Posted");
        return new PublishResult(SocialPlatform.X, id, $"https://x.com/{a.Username ?? "i"}/status/{id}", null);
    }

    static string? XMediaId(JsonObject obj)
    {
        var d = obj["data"] as JsonObject ?? obj;
        if ((StockHttp.Str(d, "id") ?? StockHttp.Str(d, "media_id_string")) is { } s) return s;
        return d["media_id"] is JsonValue v && v.GetValueKind() == JsonValueKind.Number ? v.ToJsonString() : null;
    }

    // Helpers

    static long FileSize(string path)
    {
        try { return new FileInfo(path).Length; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new PublishException(e.Message); }
    }

    /// <summary>Percent-encodes everything except letters, digits and <c>-._~</c>.</summary>
    static string Enc(string s) => Uri.EscapeDataString(s);

    /// <summary>The first <paramref name="n"/> characters, without splitting a surrogate pair (Swift counts graphemes).</summary>
    static string Prefix(string s, int n)
    {
        if (s.Length <= n) return s;
        var cut = char.IsHighSurrogate(s[n - 1]) ? n - 1 : n;
        return s[..cut];
    }

    static string PlatformMessage(SocialPlatform platform, PublishHttp.Result res) =>
        $"{platform.Name()} (HTTP {res.Status}): {PublishHttp.ErrorText(res.Data)}";

    /// <summary>Reads the file in chunks and reports progress for one upload.</summary>
    sealed class Uploader(string file, long size, CancellationToken token, Action<double, string> progress)
    {
        public string File { get; } = file;
        public long Size { get; } = size;
        public CancellationToken Token { get; } = token;

        public string MimeType => Path.GetExtension(File).Equals(".mov", StringComparison.OrdinalIgnoreCase) ? "video/quicktime" : "video/mp4";

        public void Status(double p, string text) => progress(Math.Clamp(p, 0, 1), text);

        public void CheckCancelled()
        {
            if (Token.IsCancellationRequested) throw new PublishCancelledException("Publishing cancelled");
        }

        public async Task DelayAsync(double seconds)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(seconds), Token); }
            catch (OperationCanceledException) { throw new PublishCancelledException("Publishing cancelled"); }
        }

        public async Task<byte[]> ReadAsync(long offset, int count)
        {
            CheckCancelled();
            try
            {
                await using var fs = new FileStream(File, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, useAsync: true);
                fs.Seek(offset, SeekOrigin.Begin);
                var buffer = new byte[(int)Math.Min(count, Math.Max(0, Size - offset))];
                var read = 0;
                while (read < buffer.Length)
                {
                    var n = await fs.ReadAsync(buffer.AsMemory(read), Token);
                    if (n == 0) break;
                    read += n;
                }
                return read == buffer.Length ? buffer : buffer[..read];
            }
            catch (OperationCanceledException) { throw new PublishCancelledException("Publishing cancelled"); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new PublishException(e.Message); }
        }
    }
}
