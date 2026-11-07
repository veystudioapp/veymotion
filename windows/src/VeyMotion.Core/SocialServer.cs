using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace VeyMotion.Core;

/// <summary>OAuth through the VeyMotion server (<c>server/api/social/*</c>), which holds the client secrets.
/// Port of <c>SocialServer</c>.</summary>
public static class SocialServer
{
    public sealed record Provider(bool Configured, string? Scopes, string? AppId, string? GraphVersion);

    /// <summary>A connection in progress: open <see cref="Url"/> in the default browser, then
    /// <see cref="SocialAuth.FinishConnectAsync"/>.</summary>
    public sealed record Connection(SocialPlatform Platform, string Url, string State, string Secret);

    internal sealed record Tokens(string AccessToken, string? RefreshToken, double? ExpiresIn, string? Scope, string? UserId);

    public static string BaseUrl => ServerConfig.BaseUrl;

    static Dictionary<SocialPlatform, Provider>? _providerCache;
    static readonly Lock Gate = new();

    /// <summary>Which platforms the server has credentials for (cached until <paramref name="refresh"/>).</summary>
    public static async Task<IReadOnlyDictionary<SocialPlatform, Provider>> ProvidersAsync(bool refresh = false, CancellationToken ct = default)
    {
        lock (Gate) if (!refresh && _providerCache is { } cached) return cached;
        var obj = Json(await CallAsync(HttpMethod.Get, "/api/social/providers", null, ct));
        var output = new Dictionary<SocialPlatform, Provider>();
        if (obj["platforms"] is JsonObject platforms)
        {
            foreach (var (k, v) in platforms)
            {
                if (SocialPlatformExtensions.ParseSocialPlatform(k) is not { } p || v is not JsonObject o) continue;
                output[p] = new Provider(StockHttp.Bool(o, "configured") ?? false, StockHttp.Str(o, "scopes"),
                    StockHttp.Str(o, "appId"), StockHttp.Str(o, "graphVersion"));
            }
        }
        lock (Gate) _providerCache = output;
        return output;
    }

    /// <summary>Registers a connection with the server (<c>POST /api/social/&lt;platform&gt;/start</c>) and returns the
    /// consent page to open. Registering before the browser opens means polling never runs ahead of the server.</summary>
    public static async Task<Connection> BeginConnectAsync(SocialPlatform platform, CancellationToken ct = default)
    {
        var (state, secret, challenge) = Pkce.Create();
        var obj = Json(await CallAsync(HttpMethod.Post, $"/api/social/{platform.RawValue()}/start",
            new JsonObject { ["state"] = state, ["challenge"] = challenge }, ct));
        if (StockHttp.Str(obj, "url") is not { } s || !Uri.TryCreate(s, UriKind.Absolute, out _))
            throw new PublishException($"The VeyMotion server did not return a sign-in address for {platform.Name()}.");
        return new Connection(platform, s, state, secret);
    }

    /// <summary>Polls <c>/api/social/session</c> every 1.5 s until the user has consented in the browser (or declined).</summary>
    internal static async Task<Tokens> AwaitTokensAsync(Connection c, CancellationToken ct, TimeSpan? timeout = null)
    {
        var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.FromSeconds(600));
        while (true)
        {
            if (ct.IsCancellationRequested) throw new PublishCancelledException("Connection cancelled");
            var (data, status) = await RawCallAsync(HttpMethod.Post, "/api/social/session",
                new JsonObject { ["state"] = c.State, ["secret"] = c.Secret }, ct, "Connection cancelled");
            switch (status)
            {
                case 200:
                    return ParseTokens(Json(data)["tokens"]) ?? throw new PublishException("Unexpected response from the VeyMotion server");
                case 202:
                    break;
                default:
                    throw new PublishException(ServerMessage(data, status));
            }
            if (DateTime.UtcNow >= deadline) throw new PublishException($"Timed out waiting for {c.Platform.Name()} sign-in.");
            try { await Task.Delay(1500, ct); }
            catch (OperationCanceledException) { throw new PublishCancelledException("Connection cancelled"); }
        }
    }

    internal static async Task<Tokens> RefreshAsync(SocialPlatform platform, string refreshToken, CancellationToken ct)
    {
        var data = await CallAsync(HttpMethod.Post, $"/api/social/{platform.RawValue()}/refresh",
            new JsonObject { ["refreshToken"] = refreshToken }, ct);
        return ParseTokens(Json(data)["tokens"]) ?? throw new PublishException("Unexpected response from the VeyMotion server");
    }

    static Tokens? ParseTokens(JsonNode? n) =>
        StockHttp.Str(n, "accessToken") is { } token
            ? new Tokens(token, StockHttp.Str(n, "refreshToken"), StockHttp.Double(n, "expiresIn"), StockHttp.Str(n, "scope"),
                StockHttp.Str(n, "userId"))
            : null;

    // HTTP

    static async Task<byte[]> CallAsync(HttpMethod method, string path, JsonObject? json, CancellationToken ct)
    {
        var (data, status) = await RawCallAsync(method, path, json, ct, "Publishing cancelled");
        if (status is < 200 or >= 300) throw new PublishException(ServerMessage(data, status));
        return data;
    }

    static async Task<(byte[] Data, int Status)> RawCallAsync(HttpMethod method, string path, JsonObject? json,
        CancellationToken ct, string cancelMessage)
    {
        var baseUrl = BaseUrl;
        if (!Uri.TryCreate(baseUrl + path, UriKind.Absolute, out var url)) throw new PublishException($"Invalid BASE_API_URL: {baseUrl}");
        using var req = new HttpRequestMessage(method, url);
        if (json != null) req.Content = new StringContent(json.ToJsonString(), Encoding.UTF8, "application/json");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            using var resp = await StockHttp.Client.SendAsync(req, HttpCompletionOption.ResponseContentRead, timeout.Token);
            return (await resp.Content.ReadAsByteArrayAsync(timeout.Token), (int)resp.StatusCode);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw new PublishCancelledException(cancelMessage);
        }
        catch (Exception e) when (e is HttpRequestException or IOException or OperationCanceledException)
        {
            var why = e is OperationCanceledException ? "The request timed out." : e.Message;
            throw new PublishException($"Cannot reach the VeyMotion server at {baseUrl} "
                + $"(start it with `cd server && bun run dev`, or set BASE_API_URL). {why}");
        }
    }

    static JsonObject Json(byte[] data)
    {
        try { if (JsonNode.Parse(data) is JsonObject o) return o; }
        catch (JsonException) { }
        throw new PublishException("Unexpected response from the VeyMotion server");
    }

    static string ServerMessage(byte[] data, int status)
    {
        try
        {
            if (JsonNode.Parse(data) is JsonObject o && StockHttp.Str(o, "message") is { } m) return m;
        }
        catch (JsonException) { }
        return $"VeyMotion server error (HTTP {status})";
    }
}

/// <summary>The state / secret / challenge triple the server's connect flow expects: <c>state</c> and <c>secret</c> are
/// 32 random bytes in base64url (43 characters), <c>challenge</c> = base64url(sha256(utf8(secret))).</summary>
public static class Pkce
{
    public static (string State, string Secret, string Challenge) Create()
    {
        var secret = RandomToken();
        return (RandomToken(), secret, Challenge(secret));
    }

    public static string Challenge(string secret) => Base64Url(SHA256.HashData(Encoding.UTF8.GetBytes(secret)));

    public static string RandomToken() => Base64Url(RandomNumberGenerator.GetBytes(32));

    public static string Base64Url(byte[] data) => Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');
}

/// <summary>Connected accounts. Port of <c>SocialAuth</c>.</summary>
public static class SocialAuth
{
    /// <summary>Begins a connection, opens the consent page with <paramref name="openBrowser"/> (the app passes
    /// <c>url => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })</c>), then finishes it.</summary>
    public static async Task<SocialAccount> ConnectAsync(SocialPlatform platform, Func<string, bool> openBrowser, CancellationToken ct = default)
    {
        var connection = await SocialServer.BeginConnectAsync(platform, ct);
        if (ct.IsCancellationRequested) throw new PublishCancelledException("Connection cancelled");
        if (!openBrowser(connection.Url)) throw new PublishException($"Could not open the browser for {connection.Url}");
        return await FinishConnectAsync(connection, ct);
    }

    /// <summary>Waits for the browser sign-in started with <see cref="SocialServer.BeginConnectAsync"/>, loads the
    /// profile (and Facebook Pages), and saves the account in the Credential Manager.</summary>
    public static async Task<SocialAccount> FinishConnectAsync(SocialServer.Connection c, CancellationToken ct = default)
    {
        var t = await SocialServer.AwaitTokensAsync(c, ct);
        var account = new SocialAccount
        {
            Platform = c.Platform,
            AccessToken = t.AccessToken,
            RefreshToken = t.RefreshToken,
            ExpiresAt = t.ExpiresIn is { } e ? DateTimeOffset.UtcNow.AddSeconds(e) : null,
            Scope = t.Scope,
            UserId = t.UserId,
        };
        await SocialPublisher.LoadProfileAsync(account, ct);
        // Reconnecting an account that is already saved keeps its place in the list.
        if (SocialCredentials.Load(account.Key) is { } existing) account.ConnectedAt = existing.ConnectedAt;
        SocialCredentials.Save(account);
        return account;
    }

    /// <summary>The stored account with a fresh access token (refreshed through the server when it is about to expire).</summary>
    public static async Task<SocialAccount> ValidAccountAsync(string key, CancellationToken ct = default)
    {
        var account = SocialCredentials.Load(key) ?? throw new PublishException("This account is no longer connected. Connect it again.");
        var platform = account.Platform;
        if (!account.IsExpiring) return account;
        var refreshToken = account.RefreshToken
            ?? throw new PublishException($"The {platform.Name()} login has expired. Connect the account again.");
        var t = await SocialServer.RefreshAsync(platform, refreshToken, ct);
        account.AccessToken = t.AccessToken;
        account.RefreshToken = t.RefreshToken ?? refreshToken;
        account.ExpiresAt = t.ExpiresIn is { } e ? DateTimeOffset.UtcNow.AddSeconds(e) : null;
        if (t.Scope != null) account.Scope = t.Scope;
        SocialCredentials.Save(account);
        return account;
    }

    /// <summary>Every connected account of <paramref name="platform"/>, oldest first.</summary>
    public static List<SocialAccount> Accounts(SocialPlatform platform) => SocialCredentials.Accounts(platform);

    /// <summary>Forgets the account's tokens, and clears it as the platform's active account.</summary>
    public static void Disconnect(SocialAccount account)
    {
        SocialCredentials.Delete(account.Key);
        if (PublishSettings.ActiveAccount(account.Platform) == account.Key) PublishSettings.SetActiveAccount(account.Platform, null);
    }
}
