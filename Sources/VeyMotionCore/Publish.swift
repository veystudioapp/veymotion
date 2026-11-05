import CryptoKit
import Foundation
import Security

// Publishing exported videos to YouTube, TikTok, Facebook Pages and X.
//
// OAuth goes through the VeyMotion server (`server/api/social/*`, at `BASE_API_URL`), which holds the
// client secrets: the app opens `/connect` in the browser, polls `/session` for the tokens, and refreshes
// them through `/refresh`. Tokens are kept in the login keychain. Uploads go straight to each platform.

public struct PublishError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct FacebookPage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Page access token (does not expire when obtained with a long-lived user token).
    public var accessToken: String
}

/// A connected account, stored in the keychain (one per platform).
public struct SocialAccount: Codable, Sendable {
    public var platform: SocialPlatform
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?
    public var userId: String?
    /// Channel title, display name or @username.
    public var displayName: String?
    /// X: @username, used to build post links.
    public var username: String?
    /// Facebook: Pages the user can post to.
    public var pages: [FacebookPage]?
    public var connectedAt = Date()

    var isExpiring: Bool { expiresAt.map { $0 < Date().addingTimeInterval(120) } ?? false }

    /// Whether the user granted `scope` (TikTok scopes are comma-separated, the others space-separated).
    public func hasScope(_ s: String) -> Bool {
        (scope ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).contains { $0 == s }
    }
}

// MARK: - Keychain

public enum SocialKeychain {
    static let service = "dev.veymotion.social"

    private static func query(_ platform: SocialPlatform) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: platform.rawValue]
    }

    public static func load(_ platform: SocialPlatform) -> SocialAccount? {
        var q = query(platform)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(SocialAccount.self, from: data)
    }

    public static func save(_ account: SocialAccount) throws {
        let data = try JSONEncoder().encode(account)
        let q = query(account.platform)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "VeyMotion — \(account.platform.name)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            let why = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            throw PublishError("Could not save the \(account.platform.name) login in the keychain: \(why)")
        }
    }

    public static func delete(_ platform: SocialPlatform) {
        SecItemDelete(query(platform) as CFDictionary)
    }
}

// MARK: - OAuth through the VeyMotion server

public enum SocialServer {
    public struct Provider: Sendable {
        public var configured: Bool
        public var scopes: String?
        /// Facebook app id (public) and Graph API version, needed for uploads.
        public var appId: String?
        public var graphVersion: String?
    }

    /// A connection in progress: open `url` in the browser, then `awaitTokens`.
    public struct Connection: Sendable {
        public var platform: SocialPlatform
        public var url: URL
        var state: String
        var secret: String
    }

    struct Tokens: Decodable {
        var accessToken: String
        var refreshToken: String?
        var expiresIn: Double?
        var scope: String?
        var userId: String?
    }

    public static var baseURL: URL { VieNeu.baseURL }

    nonisolated(unsafe) private static var providerCache: [SocialPlatform: Provider]?
    private static let lock = NSLock()

    /// Which platforms the server has credentials for. Blocking.
    public static func providers(refresh: Bool = false) throws -> [SocialPlatform: Provider] {
        lock.lock()
        if !refresh, let p = providerCache { lock.unlock(); return p }
        lock.unlock()
        let obj = try PublishHTTP.json(call("GET", "/api/social/providers"))
        var out: [SocialPlatform: Provider] = [:]
        for (k, v) in obj["platforms"] as? [String: [String: Any]] ?? [:] {
            guard let p = SocialPlatform(rawValue: k) else { continue }
            out[p] = Provider(configured: v["configured"] as? Bool ?? false, scopes: v["scopes"] as? String,
                              appId: v["appId"] as? String, graphVersion: v["graphVersion"] as? String)
        }
        lock.lock(); providerCache = out; lock.unlock()
        return out
    }

    /// Registers a connection with the server and returns the consent page to open. Registering before the
    /// browser opens means `awaitTokens` never polls for a connection the server does not know yet. Blocking.
    public static func beginConnect(_ platform: SocialPlatform) throws -> Connection {
        let state = randomToken(), secret = randomToken()
        let challenge = Data(SHA256.hash(data: Data(secret.utf8))).base64URL
        let obj = try PublishHTTP.json(call("POST", "/api/social/\(platform.rawValue)/start",
                                            json: ["state": state, "challenge": challenge]))
        guard let s = obj["url"] as? String, let url = URL(string: s) else {
            throw PublishError("The VeyMotion server did not return a sign-in address for \(platform.name).")
        }
        return Connection(platform: platform, url: url, state: state, secret: secret)
    }

    /// Polls the server until the user has consented in the browser (or declined). Blocking.
    static func awaitTokens(_ c: Connection, timeout: TimeInterval = 600,
                            isCancelled: @Sendable () -> Bool) throws -> Tokens {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isCancelled() { throw PublishError("Connection cancelled") }
            let (data, status) = try rawCall("POST", "/api/social/session", json: ["state": c.state, "secret": c.secret])
            switch status {
            case 200:
                struct Session: Decodable { var tokens: Tokens }
                return try JSONDecoder().decode(Session.self, from: data).tokens
            case 202:
                break
            default:
                throw PublishError(serverMessage(data, status: status))
            }
            guard Date() < deadline else { throw PublishError("Timed out waiting for \(c.platform.name) sign-in.") }
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    static func refresh(_ platform: SocialPlatform, refreshToken: String) throws -> Tokens {
        struct R: Decodable { var tokens: Tokens }
        let data = try call("POST", "/api/social/\(platform.rawValue)/refresh", json: ["refreshToken": refreshToken])
        return try JSONDecoder().decode(R.self, from: data).tokens
    }

    // MARK: HTTP

    private static func call(_ method: String, _ path: String, json: [String: Any]? = nil) throws -> Data {
        let (data, status) = try rawCall(method, path, json: json)
        guard (200..<300).contains(status) else { throw PublishError(serverMessage(data, status: status)) }
        return data
    }

    private static func rawCall(_ method: String, _ path: String, json: [String: Any]?) throws -> (Data, Int) {
        let base = baseURL
        guard let url = URL(string: base.absoluteString + path) else { throw PublishError("Invalid BASE_API_URL: \(base)") }
        var req = HTTP.request(url, timeout: 30)
        req.httpMethod = method
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        do {
            let r = try HTTP.perform(req)
            return (r.data, r.response?.statusCode ?? 0)
        } catch {
            throw PublishError("Cannot reach the VeyMotion server at \(base.absoluteString) "
                + "(start it with `cd server && bun run dev`, or set BASE_API_URL). \(error.localizedDescription)")
        }
    }

    private static func serverMessage(_ data: Data, status: Int) -> String {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["message"] as? String ?? "VeyMotion server error (HTTP \(status))"
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Accounts

public enum SocialAuth {
    /// Waits for the browser sign-in started with `SocialServer.beginConnect`, loads the profile
    /// (and Facebook Pages), and saves the account in the keychain. Blocking.
    public static func finishConnect(_ c: SocialServer.Connection,
                                     isCancelled: @escaping @Sendable () -> Bool) throws -> SocialAccount {
        let t = try SocialServer.awaitTokens(c, isCancelled: isCancelled)
        var account = SocialAccount(platform: c.platform, accessToken: t.accessToken, refreshToken: t.refreshToken,
                                    expiresAt: t.expiresIn.map { Date().addingTimeInterval($0) },
                                    scope: t.scope, userId: t.userId)
        try SocialPublisher.loadProfile(&account)
        try SocialKeychain.save(account)
        return account
    }

    /// The stored account with a fresh access token (refreshed through the server when it is about to expire).
    public static func validAccount(_ platform: SocialPlatform) throws -> SocialAccount {
        guard var account = SocialKeychain.load(platform) else {
            throw PublishError("Connect your \(platform.name) account first.")
        }
        guard account.isExpiring else { return account }
        guard let refreshToken = account.refreshToken else {
            throw PublishError("The \(platform.name) login has expired. Connect the account again.")
        }
        let t = try SocialServer.refresh(platform, refreshToken: refreshToken)
        account.accessToken = t.accessToken
        account.refreshToken = t.refreshToken ?? refreshToken
        account.expiresAt = t.expiresIn.map { Date().addingTimeInterval($0) }
        if let s = t.scope { account.scope = s }
        try SocialKeychain.save(account)
        return account
    }

    public static func disconnect(_ platform: SocialPlatform) {
        SocialKeychain.delete(platform)
    }
}

// MARK: - Publishing

public struct PublishRequest: Sendable {
    public enum TikTokMode: String, Sendable, CaseIterable {
        /// Upload to the creator's TikTok inbox; they finish and post it in the TikTok app.
        case draft
        /// Post directly (needs the `video.publish` scope; unaudited apps can only post privately).
        case direct
    }

    public var file: URL
    /// YouTube / Facebook title; TikTok and X caption.
    public var title: String
    /// YouTube / Facebook description.
    public var description = ""
    public var tags: [String] = []
    /// YouTube: private, unlisted or public.
    public var youtubePrivacy = "private"
    public var tiktokMode = TikTokMode.draft
    /// One of `TikTokCreatorInfo.privacyOptions` (direct posts).
    public var tiktokPrivacy: String?
    public var disableComments = false
    public var disableDuet = false
    public var disableStitch = false
    public var facebookPageId: String?

    public init(file: URL, title: String) {
        self.file = file
        self.title = title
    }
}

public struct PublishResult: Sendable {
    public var platform: SocialPlatform
    public var id: String
    /// Link to the post, when the platform gives enough to build one.
    public var url: URL?
    /// e.g. "Open TikTok to finish the post" or "YouTube is still processing the video".
    public var note: String?
}

/// What TikTok allows this creator to post (shown before a direct post, as TikTok requires).
public struct TikTokCreatorInfo: Sendable {
    public var nickname: String
    public var username: String?
    public var privacyOptions: [String]
    public var commentDisabled: Bool
    public var duetDisabled: Bool
    public var stitchDisabled: Bool
    public var maxDuration: Double?
}

public enum SocialPublisher {
    /// Uploads and publishes `req.file`. `progress` gets 0…1 and a short status line. Blocking.
    public static func publish(_ platform: SocialPlatform, _ req: PublishRequest,
                               isCancelled: @escaping @Sendable () -> Bool = { false },
                               progress: @escaping (Double, String) -> Void) throws -> PublishResult {
        guard platform.accepts(req.file) else {
            throw PublishError("\(platform.name) needs an MP4 file\(platform == .x ? "" : " or MOV") (export as MP4 — H.264).")
        }
        let size = try fileSize(req.file)
        guard size > 0 else { throw PublishError("The video file is empty.") }
        guard size <= platform.maxBytes else {
            throw PublishError("\(platform.name) accepts files up to \(ByteCountFormatter().string(fromByteCount: platform.maxBytes)).")
        }
        let account = try SocialAuth.validAccount(platform)
        let up = Uploader(file: req.file, size: size, isCancelled: isCancelled, progress: progress)
        switch platform {
        case .youtube: return try youtube(req, account, up)
        case .tiktok: return try tiktok(req, account, up)
        case .facebook: return try facebook(req, account, up)
        case .x: return try x(req, account, up)
        }
    }

    // MARK: Profiles

    static func loadProfile(_ a: inout SocialAccount) throws {
        let token = a.accessToken
        switch a.platform {
        case .youtube:
            let obj = try PublishHTTP.call("GET", "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true",
                                           bearer: token).json
            let snippet = ((obj["items"] as? [[String: Any]])?.first?["snippet"]) as? [String: Any]
            a.displayName = snippet?["title"] as? String
            a.userId = ((obj["items"] as? [[String: Any]])?.first?["id"]) as? String
            if a.userId == nil { throw PublishError("This Google account has no YouTube channel. Create one at youtube.com first.") }
        case .tiktok:
            let obj = try PublishHTTP.call("GET", "https://open.tiktokapis.com/v2/user/info/?fields=open_id,display_name",
                                           bearer: token).json
            try tiktokCheck(obj)
            let user = (obj["data"] as? [String: Any])?["user"] as? [String: Any]
            a.displayName = user?["display_name"] as? String
            a.userId = user?["open_id"] as? String ?? a.userId
        case .facebook:
            let v = try graphVersion()
            let me = try PublishHTTP.call("GET", "https://graph.facebook.com/\(v)/me?fields=id,name&access_token=\(enc(token))").json
            a.displayName = me["name"] as? String
            a.userId = me["id"] as? String
            let list = try PublishHTTP.call(
                "GET", "https://graph.facebook.com/\(v)/me/accounts?fields=id,name,access_token&limit=100&access_token=\(enc(token))").json
            a.pages = (list["data"] as? [[String: Any]] ?? []).compactMap { p in
                guard let id = p["id"] as? String, let t = p["access_token"] as? String else { return nil }
                return FacebookPage(id: id, name: p["name"] as? String ?? id, accessToken: t)
            }
            if a.pages?.isEmpty ?? true {
                throw PublishError("No Facebook Pages found. VeyMotion posts to Pages you manage (Facebook does not allow posting to personal profiles through its API).")
            }
        case .x:
            let obj = try PublishHTTP.call("GET", "https://api.x.com/2/users/me", bearer: token).json
            let data = obj["data"] as? [String: Any]
            a.username = data?["username"] as? String
            a.displayName = a.username.map { "@\($0)" } ?? data?["name"] as? String
            a.userId = data?["id"] as? String
        }
    }

    // MARK: YouTube (resumable upload)

    private static func youtube(_ req: PublishRequest, _ a: SocialAccount, _ up: Uploader) throws -> PublishResult {
        up.status(0, "Starting upload…")
        let title = String((req.title.isEmpty ? req.file.deletingPathExtension().lastPathComponent : req.title)
            .prefix(SocialPlatform.youtube.titleLimit))
        var snippet: [String: Any] = ["title": title, "description": req.description, "categoryId": "22"]
        if !req.tags.isEmpty { snippet["tags"] = req.tags }
        let meta: [String: Any] = ["snippet": snippet,
                                   "status": ["privacyStatus": req.youtubePrivacy, "selfDeclaredMadeForKids": false]]
        let start = try PublishHTTP.call(
            "POST", "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status",
            bearer: a.accessToken, json: meta,
            headers: ["X-Upload-Content-Length": "\(up.size)", "X-Upload-Content-Type": up.mimeType])
        guard let location = start.response.value(forHTTPHeaderField: "Location"), let uploadURL = URL(string: location) else {
            throw PublishError("YouTube did not return an upload address.")
        }

        let chunk = 64 * 256 * 1024 // 16 MB, a multiple of 256 KB as YouTube requires
        var offset: Int64 = 0
        var final: [String: Any]?
        while final == nil {
            let data = try up.read(offset, count: chunk)
            var r = URLRequest(url: uploadURL, timeoutInterval: 600)
            r.httpMethod = "PUT"
            r.setValue("Bearer \(a.accessToken)", forHTTPHeaderField: "Authorization")
            r.setValue(up.mimeType, forHTTPHeaderField: "Content-Type")
            r.setValue("bytes \(offset)-\(offset + Int64(data.count) - 1)/\(up.size)", forHTTPHeaderField: "Content-Range")
            r.httpBody = data
            let res = try PublishHTTP.send(r, isCancelled: up.isCancelled) { sent in
                up.status(Double(offset + sent) / Double(up.size), "Uploading to YouTube…")
            }
            switch res.status {
            case 308:
                // "Resume Incomplete": Range says what YouTube has, e.g. "bytes=0-16777215".
                if let range = res.response.value(forHTTPHeaderField: "Range"),
                   let last = range.split(separator: "-").last.flatMap({ Int64($0) }) {
                    offset = last + 1
                } else {
                    offset = 0
                }
            case 200, 201:
                final = res.json
            default:
                throw PublishError(platformMessage(.youtube, res))
            }
        }
        guard let id = final?["id"] as? String else { throw PublishError("YouTube did not return a video id.") }
        up.status(1, "Uploaded")
        return PublishResult(platform: .youtube, id: id, url: URL(string: "https://youtu.be/\(id)"),
                             note: "YouTube is processing the video; it may take a few minutes before it plays in full quality.")
    }

    // MARK: TikTok (Content Posting API)

    public static func tiktokCreatorInfo() throws -> TikTokCreatorInfo {
        let a = try SocialAuth.validAccount(.tiktok)
        let obj = try PublishHTTP.call("POST", "https://open.tiktokapis.com/v2/post/publish/creator_info/query/",
                                       bearer: a.accessToken, json: [:]).json
        try tiktokCheck(obj)
        let d = obj["data"] as? [String: Any] ?? [:]
        return TikTokCreatorInfo(
            nickname: d["creator_nickname"] as? String ?? a.displayName ?? "TikTok",
            username: d["creator_username"] as? String,
            privacyOptions: d["privacy_level_options"] as? [String] ?? [],
            commentDisabled: d["comment_disabled"] as? Bool ?? false,
            duetDisabled: d["duet_disabled"] as? Bool ?? false,
            stitchDisabled: d["stitch_disabled"] as? Bool ?? false,
            maxDuration: (d["max_video_post_duration_sec"] as? NSNumber)?.doubleValue)
    }

    private static func tiktok(_ req: PublishRequest, _ a: SocialAccount, _ up: Uploader) throws -> PublishResult {
        up.status(0, "Starting upload…")
        // Files up to 64 MB go in one chunk; bigger ones in 10 MB chunks (TikTok allows 5–64 MB), the count
        // rounded down so the last chunk takes the remainder.
        let chunk: Int64 = up.size <= 64 << 20 ? up.size : 10 << 20
        let count = max(1, up.size / chunk)
        let source: [String: Any] = ["source": "FILE_UPLOAD", "video_size": up.size, "chunk_size": chunk,
                                     "total_chunk_count": count]
        let direct = req.tiktokMode == .direct
        var body: [String: Any] = ["source_info": source]
        if direct {
            guard let privacy = req.tiktokPrivacy else { throw PublishError("Choose who can see the TikTok post.") }
            body["post_info"] = ["title": String(req.title.prefix(SocialPlatform.tiktok.titleLimit)),
                                 "privacy_level": privacy, "disable_comment": req.disableComments,
                                 "disable_duet": req.disableDuet, "disable_stitch": req.disableStitch]
        }
        let initURL = direct ? "https://open.tiktokapis.com/v2/post/publish/video/init/"
                             : "https://open.tiktokapis.com/v2/post/publish/inbox/video/init/"
        let initRes = try PublishHTTP.call("POST", initURL, bearer: a.accessToken, json: body).json
        try tiktokCheck(initRes)
        let data = initRes["data"] as? [String: Any] ?? [:]
        guard let publishId = data["publish_id"] as? String,
              let uploadURL = (data["upload_url"] as? String).flatMap(URL.init(string:)) else {
            throw PublishError("TikTok did not return an upload address.")
        }

        for i in 0..<count {
            let first = Int64(i) * chunk
            let length = i == count - 1 ? up.size - first : chunk
            let bytes = try up.read(first, count: Int(length))
            var r = URLRequest(url: uploadURL, timeoutInterval: 600)
            r.httpMethod = "PUT"
            r.setValue(up.mimeType, forHTTPHeaderField: "Content-Type")
            r.setValue("bytes \(first)-\(first + length - 1)/\(up.size)", forHTTPHeaderField: "Content-Range")
            r.httpBody = bytes
            let res = try PublishHTTP.send(r, isCancelled: up.isCancelled) { sent in
                up.status(0.95 * Double(first + sent) / Double(up.size), "Uploading to TikTok…")
            }
            guard res.status == 201 || res.status == 206 || res.status == 200 else {
                throw PublishError(platformMessage(.tiktok, res))
            }
        }

        // TikTok processes the upload asynchronously; wait a while for the final state.
        up.status(0.95, "TikTok is processing the video…")
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try up.checkCancelled()
            let s = try PublishHTTP.call("POST", "https://open.tiktokapis.com/v2/post/publish/status/fetch/",
                                         bearer: a.accessToken, json: ["publish_id": publishId]).json
            try tiktokCheck(s)
            let d = s["data"] as? [String: Any] ?? [:]
            switch d["status"] as? String {
            case "SEND_TO_USER_INBOX":
                up.status(1, "Sent to TikTok")
                return PublishResult(platform: .tiktok, id: publishId, url: nil,
                                     note: "Open the TikTok app: the video is in your inbox notifications, ready to edit and post.")
            case "PUBLISH_COMPLETE":
                up.status(1, "Posted")
                let postId = (d["publicaly_available_post_id"] as? [Any])?.first.map { "\($0)" }
                let user = (try? tiktokCreatorInfo())?.username
                let url = postId.flatMap { id in user.flatMap { URL(string: "https://www.tiktok.com/@\($0)/video/\(id)") } }
                return PublishResult(platform: .tiktok, id: postId ?? publishId, url: url,
                                     note: postId == nil ? "Posted. Unaudited TikTok apps can only post privately (Only me)." : nil)
            case "FAILED":
                throw PublishError("TikTok could not post the video: \(d["fail_reason"] as? String ?? "unknown reason").")
            default:
                Thread.sleep(forTimeInterval: 3)
            }
        }
        return PublishResult(platform: .tiktok, id: publishId, url: nil,
                             note: "Uploaded. TikTok is still processing the video; check the TikTok app in a few minutes.")
    }

    private static func tiktokCheck(_ obj: [String: Any]) throws {
        guard let err = obj["error"] as? [String: Any], let code = err["code"] as? String, code != "ok" else { return }
        throw PublishError("TikTok: \(err["message"] as? String ?? code) (\(code))")
    }

    // MARK: Facebook Pages (resumable upload API)

    private static func facebook(_ req: PublishRequest, _ a: SocialAccount, _ up: Uploader) throws -> PublishResult {
        guard let pages = a.pages, !pages.isEmpty else { throw PublishError("Connect a Facebook account that manages a Page.") }
        guard let page = pages.first(where: { $0.id == req.facebookPageId }) ?? (pages.count == 1 ? pages[0] : nil) else {
            throw PublishError("Choose the Facebook Page to post to.")
        }
        let v = try graphVersion()
        guard let appId = try SocialServer.providers()[.facebook]?.appId else {
            throw PublishError("The server did not return the Facebook app id.")
        }
        up.status(0, "Starting upload…")
        let session = try PublishHTTP.call(
            "POST", "https://graph.facebook.com/\(v)/\(appId)/uploads?file_name=\(enc(req.file.lastPathComponent))"
                + "&file_length=\(up.size)&file_type=\(enc(up.mimeType))&access_token=\(enc(a.accessToken))").json
        guard let sessionId = session["id"] as? String else { throw PublishError("Facebook did not start an upload session.") }

        var r = URLRequest(url: URL(string: "https://graph.facebook.com/\(v)/\(sessionId)")!, timeoutInterval: 3600)
        r.httpMethod = "POST"
        r.setValue("OAuth \(a.accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue("0", forHTTPHeaderField: "file_offset")
        r.httpBody = try Data(contentsOf: req.file, options: .alwaysMapped)
        let uploaded = try PublishHTTP.send(r, isCancelled: up.isCancelled) { sent in
            up.status(0.95 * Double(sent) / Double(up.size), "Uploading to Facebook…")
        }
        guard (200..<300).contains(uploaded.status), let handle = uploaded.json["h"] as? String else {
            throw PublishError(platformMessage(.facebook, uploaded))
        }

        up.status(0.97, "Publishing on \(page.name)…")
        var fields = ["access_token": page.accessToken, "fbuploader_video_file_chunk": handle,
                      "description": req.description.isEmpty ? req.title : req.description]
        if !req.title.isEmpty { fields["title"] = String(req.title.prefix(SocialPlatform.facebook.titleLimit)) }
        let post = try PublishHTTP.call("POST", "https://graph-video.facebook.com/\(v)/\(page.id)/videos", form: fields).json
        guard let id = post["id"] as? String else { throw PublishError("Facebook did not return a video id.") }
        up.status(1, "Posted")
        return PublishResult(platform: .facebook, id: id, url: URL(string: "https://www.facebook.com/\(page.id)/videos/\(id)"),
                             note: "Facebook is processing the video; it appears on \(page.name) when it is ready.")
    }

    private static func graphVersion() throws -> String {
        try SocialServer.providers()[.facebook]?.graphVersion ?? "v27.0"
    }

    // MARK: X (media upload v2 + post)

    private static func x(_ req: PublishRequest, _ a: SocialAccount, _ up: Uploader) throws -> PublishResult {
        up.status(0, "Starting upload…")
        let start = try PublishHTTP.call("POST", "https://api.x.com/2/media/upload/initialize", bearer: a.accessToken,
                                         json: ["media_type": "video/mp4", "total_bytes": up.size,
                                                "media_category": "tweet_video"]).json
        guard let mediaId = xMediaId(start) else { throw PublishError("X did not return a media id.") }

        let chunk = 4 << 20
        var index = 0
        var offset: Int64 = 0
        while offset < up.size {
            let bytes = try up.read(offset, count: chunk)
            let boundary = "veymotion-\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"segment_index\"\r\n\r\n\(index)\r\n")
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"media\"; filename=\"chunk\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n")
            body.append(bytes)
            body.append("\r\n--\(boundary)--\r\n")
            var r = URLRequest(url: URL(string: "https://api.x.com/2/media/upload/\(mediaId)/append")!, timeoutInterval: 600)
            r.httpMethod = "POST"
            r.setValue("Bearer \(a.accessToken)", forHTTPHeaderField: "Authorization")
            r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            let sentBefore = offset
            let res = try PublishHTTP.send(r, isCancelled: up.isCancelled) { sent in
                up.status(0.9 * Double(sentBefore + min(sent, Int64(bytes.count))) / Double(up.size), "Uploading to X…")
            }
            guard (200..<300).contains(res.status) else { throw PublishError(platformMessage(.x, res)) }
            offset += Int64(bytes.count)
            index += 1
        }

        var info = (try PublishHTTP.call("POST", "https://api.x.com/2/media/upload/\(mediaId)/finalize",
                                         bearer: a.accessToken).json["data"] as? [String: Any])?["processing_info"] as? [String: Any]
        let deadline = Date().addingTimeInterval(300)
        while let state = info?["state"] as? String, state != "succeeded" {
            if state == "failed" {
                let msg = (info?["error"] as? [String: Any])?["message"] as? String ?? "processing failed"
                throw PublishError("X could not process the video: \(msg)")
            }
            guard Date() < deadline else { throw PublishError("X is taking too long to process the video. Try again later.") }
            try up.checkCancelled()
            up.status(0.92, "X is processing the video…")
            Thread.sleep(forTimeInterval: min(max((info?["check_after_secs"] as? NSNumber)?.doubleValue ?? 2, 1), 10))
            let s = try PublishHTTP.call("GET", "https://api.x.com/2/media/upload?command=STATUS&media_id=\(mediaId)",
                                         bearer: a.accessToken).json
            info = ((s["data"] as? [String: Any]) ?? s)["processing_info"] as? [String: Any]
        }

        up.status(0.97, "Posting…")
        let post = try PublishHTTP.call("POST", "https://api.x.com/2/tweets", bearer: a.accessToken,
                                        json: ["text": String(req.title.prefix(SocialPlatform.x.titleLimit)),
                                               "media": ["media_ids": [mediaId]]]).json
        guard let id = (post["data"] as? [String: Any])?["id"] as? String else { throw PublishError("X did not return a post id.") }
        up.status(1, "Posted")
        let user = a.username ?? "i"
        return PublishResult(platform: .x, id: id, url: URL(string: "https://x.com/\(user)/status/\(id)"), note: nil)
    }

    private static func xMediaId(_ obj: [String: Any]) -> String? {
        let d = obj["data"] as? [String: Any] ?? obj
        return d["id"] as? String ?? d["media_id_string"] as? String ?? (d["media_id"] as? NSNumber)?.stringValue
    }

    // MARK: Helpers

    private static func fileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    static func platformMessage(_ platform: SocialPlatform, _ res: PublishHTTP.Result) -> String {
        "\(platform.name) (HTTP \(res.status)): \(PublishHTTP.errorText(res.data))"
    }
}

/// Reads the file in chunks and reports progress for one upload.
private final class Uploader {
    let file: URL
    let size: Int64
    let isCancelled: @Sendable () -> Bool
    let progress: (Double, String) -> Void

    init(file: URL, size: Int64, isCancelled: @escaping @Sendable () -> Bool, progress: @escaping (Double, String) -> Void) {
        self.file = file
        self.size = size
        self.isCancelled = isCancelled
        self.progress = progress
    }

    var mimeType: String { file.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4" }

    func status(_ p: Double, _ text: String) { progress(min(max(p, 0), 1), text) }

    func checkCancelled() throws { if isCancelled() { throw PublishError("Publishing cancelled") } }

    func read(_ offset: Int64, count: Int) throws -> Data {
        try checkCancelled()
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        return try h.read(upToCount: count) ?? Data()
    }
}

private extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}

// MARK: - HTTP for platform APIs

enum PublishHTTP {
    struct Result {
        var data: Data
        var response: HTTPURLResponse
        var status: Int { response.statusCode }
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
    }

    /// JSON / form API call; non-2xx statuses throw with the platform's error message.
    static func call(_ method: String, _ url: String, bearer: String? = nil, json: [String: Any]? = nil,
                     form: [String: String]? = nil, headers: [String: String] = [:]) throws -> Result {
        guard let u = URL(string: url) else { throw PublishError("Invalid URL \(url)") }
        var r = HTTP.request(u, timeout: 60)
        r.httpMethod = method
        if let bearer { r.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: json)
        } else if let form {
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var c = URLComponents()
            c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves "+" alone, which form decoding reads as a space.
            r.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let res = try send(r)
        guard (200..<300).contains(res.status) else {
            throw PublishError("\(u.host ?? "Server") (HTTP \(res.status)): \(errorText(res.data))")
        }
        return res
    }

    /// Sends one request, reporting bytes sent while it uploads. Throws only on network errors / cancel.
    static func send(_ req: URLRequest, isCancelled: (@Sendable () -> Bool)? = nil,
                     onProgress: ((Int64) -> Void)? = nil) throws -> Result {
        let done = DispatchSemaphore(value: 0)
        var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let task = HTTP.session.dataTask(with: req) { d, r, e in
            out = (d, r, e)
            done.signal()
        }
        task.resume()
        let deadline = Date().addingTimeInterval(req.timeoutInterval + 10)
        while done.wait(timeout: .now() + 0.25) == .timedOut {
            if isCancelled?() == true { task.cancel(); done.wait(); throw PublishError("Publishing cancelled") }
            if Date() > deadline { task.cancel(); done.wait(); throw PublishError("Request timed out: \(req.url?.host ?? "")") }
            onProgress?(task.countOfBytesSent)
        }
        onProgress?(task.countOfBytesSent)
        if let e = out.2 { throw PublishError("Cannot reach \(req.url?.host ?? "the server"): \(e.localizedDescription)") }
        guard let http = out.1 as? HTTPURLResponse else { throw PublishError("No response from \(req.url?.host ?? "the server")") }
        return Result(data: out.0 ?? Data(), response: http)
    }

    static func json(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PublishError("Unexpected response from the VeyMotion server")
        }
        return obj
    }

    /// The readable part of an API error body (Google, TikTok, Meta, X all differ).
    static func errorText(_ data: Data) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return String(data: data.prefix(300), encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? "no details"
        }
        if let e = obj["error"] as? [String: Any] {
            return (e["message"] as? String ?? e["code"] as? String ?? "error")
                + ((e["error_user_msg"] as? String).map { " — \($0)" } ?? "")
        }
        if let e = obj["error"] as? String { return obj["error_description"] as? String ?? e }
        if let errors = obj["errors"] as? [[String: Any]], let first = errors.first {
            return first["message"] as? String ?? first["detail"] as? String ?? "error"
        }
        return obj["detail"] as? String ?? obj["title"] as? String ?? obj["message"] as? String ?? "no details"
    }
}
