import Foundation

/// Free stock video (Pexels and Pixabay) through the VeyMotion server (`/api/stock/videos`), which holds the API
/// keys. The server is the one at `VieNeu.baseURL` (`BASE_API_URL`). The video files themselves come straight from
/// the sources' CDNs.
enum StockVideoSearch {
    static let refPrefixes = ["pexels", "pixabay"]

    /// Downloads are capped at this many pixels on the long side (1080p): 4K files are hundreds of MB and the
    /// canvas never shows more than the scene size.
    static let maxImportSide = 1920

    /// Blocking. `orientation`: landscape, portrait or square. `maxDuration` > 0 leaves out longer clips.
    static func search(_ q: String, page: Int, orientation: String?, maxDuration: Double?) throws -> [StockItem] {
        var c = URLComponents()
        c.path = "/api/stock/videos"
        var items = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "page", value: String(max(1, page))),
                     URLQueryItem(name: "perPage", value: "20")]
        if let o = orientation?.lowercased(), !o.isEmpty, o != "any" { items.append(URLQueryItem(name: "orientation", value: o)) }
        c.queryItems = items
        let obj = try call(c.string ?? "/api/stock/videos")
        var found = (obj["results"] as? [[String: Any]] ?? []).compactMap(item(from:))
        if let m = maxDuration, m > 0 { found = found.filter { ($0.duration ?? 0) <= m + 0.5 } }
        return found
    }

    /// Looks up "pexels:<id>" / "pixabay:<id>". Blocking.
    static func item(source: String, id: String) throws -> StockItem {
        guard id.allSatisfy(\.isNumber), !id.isEmpty else { throw AssetError.failed("Bad video ref \(source):\(id)") }
        guard let item = item(from: try call("/api/stock/videos/\(source)/\(id)")) else {
            throw AssetError.failed("\(source) video \(id) has no MP4 file")
        }
        return item
    }

    /// A server result → StockItem, downloading the largest MP4 up to `maxImportSide` (else the smallest).
    static func item(from r: [String: Any]) -> StockItem? {
        guard let ref = r["ref"] as? String, let pageURL = r["pageUrl"] as? String else { return nil }
        let files: [(url: URL, w: Int, h: Int)] = (r["files"] as? [[String: Any]] ?? []).compactMap { f in
            guard let s = f["url"] as? String, let u = URL(string: s), let w = f["width"] as? Int, let h = f["height"] as? Int
            else { return nil }
            return (u, w, h)
        }.sorted { $0.w * $0.h < $1.w * $1.h }
        guard let smallest = files.first else { return nil }
        let chosen = files.last { max($0.w, $0.h) <= maxImportSide } ?? smallest

        let source = r["source"] as? String ?? ""
        let sourceName = source == "pixabay" ? "Pixabay" : "Pexels"
        let title = (r["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(sourceName) video"
        let creator = r["creator"] as? String
        let credit = AssetCredit(title: title, creator: creator,
                                 license: r["license"] as? String ?? "\(sourceName) License",
                                 licenseURL: r["licenseUrl"] as? String, sourceURL: pageURL,
                                 attribution: "Video\(creator.map { " by \($0)" } ?? "") on \(sourceName)",
                                 requiresAttribution: false, ref: ref)
        var item = StockItem(ref: ref, kind: .video, title: title,
                             thumbnailURL: (r["thumbnail"] as? String).flatMap(URL.init(string:)),
                             fileExtension: "mp4", width: chosen.w, height: chosen.h, credit: credit)
        item.downloadURL = chosen.url
        item.previewURL = smallest.url
        item.duration = (r["duration"] as? Double) ?? (r["duration"] as? Int).map(Double.init)
        item.tags = (r["tags"] as? [String] ?? []).map { $0.lowercased() }
        return item
    }

    // MARK: HTTP

    private static func call(_ pathAndQuery: String) throws -> [String: Any] {
        let base = VieNeu.baseURL
        guard let url = URL(string: base.absoluteString + pathAndQuery) else {
            throw AssetError.failed("Invalid BASE_API_URL: \(base)")
        }
        try License.require(.stockVideo)
        var req = HTTP.request(url, timeout: 30)
        License.authorize(&req)
        let result: (data: Data, response: HTTPURLResponse?)
        do {
            result = try HTTP.perform(req)
        } catch {
            throw AssetError.failed("Stock video needs the VeyMotion server, which is not reachable at \(base.absoluteString) "
                + "(start it with `cd server && bun run dev`, or set BASE_API_URL).")
        }
        let status = result.response?.statusCode ?? 0
        let obj = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        guard (200..<300).contains(status) else {
            if status == 404, (obj?["message"] as? String)?.contains("has no video") != true {
                throw AssetError.failed("The VeyMotion server at \(base.absoluteString) has no stock video route. Update and restart it.")
            }
            let msg = obj?["message"] as? String ?? String(data: result.data.prefix(300), encoding: .utf8) ?? "no details"
            throw AssetError.failed(status == 429 ? "Stock video is rate-limited: \(msg). Wait a minute and try again." : msg)
        }
        guard let obj else { throw AssetError.failed("Unexpected response from the VeyMotion server") }
        return obj
    }
}
