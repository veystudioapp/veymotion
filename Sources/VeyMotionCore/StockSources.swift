import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Free, keyless asset sources:
/// - Openverse (api.openverse.org): openly licensed photos and illustrations. Searches are limited to
///   licenses that allow commercial use and modification (CC0, Public Domain, CC BY, CC BY-SA).
/// - Iconify (api.iconify.design): 200k+ open-source SVG icons (Material, Tabler, Lucide, Phosphor, …).
/// - Openverse audio: music from Jamendo and sound effects from Freesound, with the same license filter.
public enum StockKind: String, CaseIterable, Codable, Sendable {
    case photo, illustration, icon, music, sound

    public var title: String {
        switch self {
        case .photo: return "Photos"
        case .illustration: return "Illustrations"
        case .icon: return "Icons"
        case .music: return "Music"
        case .sound: return "Sound FX"
        }
    }

    public var isAudio: Bool { self == .music || self == .sound }
}

public struct StockItem: Identifiable, Hashable, Sendable {
    /// "openverse:<uuid>" or "iconify:<prefix>:<name>". Pass it to `StockSearch.importItem`.
    public var ref: String
    public var kind: StockKind
    public var title: String
    public var thumbnailURL: URL?
    public var fileExtension: String
    public var width: Int?
    public var height: Int?
    /// Multi-color icon (its colors are fixed; `color` does not apply).
    public var isMulticolor = false
    public var credit: AssetCredit
    /// Full-size file for photos/illustrations/audio (icon files are built from the ref).
    public var downloadURL: URL?
    /// Audio length in seconds.
    public var duration: Double?
    public var genres: [String] = []

    public var id: String { ref }

    /// One line for agents: "openverse:abc — Title — 1024×768 jpg — CC BY 4.0 (credit required) — by Someone".
    public var summary: String {
        var parts = [ref, title]
        if let d = duration {
            parts.append(Self.clock(d) + " " + fileExtension + (genres.isEmpty ? "" : " — " + genres.prefix(3).joined(separator: ", ")))
        } else if let w = width, let h = height {
            parts.append("\(w)×\(h) \(fileExtension)")
        } else {
            parts.append(fileExtension)
        }
        parts.append(credit.license + (credit.requiresAttribution ? " (credit required)" : ""))
        if let c = credit.creator, !c.isEmpty { parts.append("by \(c)") }
        if isMulticolor { parts.append("multicolor") }
        return parts.joined(separator: " — ")
    }

    /// 95.2 → "1:35"; short sounds keep tenths: 0.45 → "0.5s".
    public static func clock(_ seconds: Double) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

public enum StockSearch {
    static let iconPageSize = 48

    // MARK: Search

    /// Blocking; call off the main thread. `page` starts at 1.
    public static func search(_ query: String, kind: StockKind, page: Int = 1) throws -> [StockItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        switch kind {
        case .icon: return try searchIcons(q, page: page)
        case .photo, .illustration: return try searchOpenverse(q, kind: kind, page: page)
        case .music, .sound: return try searchOpenverseAudio(q, kind: kind, page: page)
        }
    }

    private static func searchOpenverseAudio(_ q: String, kind: StockKind, page: Int) throws -> [StockItem] {
        var c = URLComponents(string: "https://api.openverse.org/v1/audio/")!
        c.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "license_type", value: "commercial,modification"),
            // Jamendo is all music; Freesound is sound effects (its items have no category).
            URLQueryItem(name: "source", value: kind == .music ? "jamendo" : "freesound"),
        ]
        let obj = try HTTP.json(c.url!)
        let results = obj["results"] as? [[String: Any]] ?? []
        return results.compactMap { openverseItem($0, kind: kind) }
    }

    private static func searchOpenverse(_ q: String, kind: StockKind, page: Int) throws -> [StockItem] {
        var c = URLComponents(string: "https://api.openverse.org/v1/images/")!
        c.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "license_type", value: "commercial,modification"),
            URLQueryItem(name: "category", value: kind == .photo ? "photograph" : "illustration"),
        ]
        let obj = try HTTP.json(c.url!)
        let results = obj["results"] as? [[String: Any]] ?? []
        return results.compactMap { openverseItem($0, kind: kind) }
    }

    private static func openverseItem(_ r: [String: Any], kind: StockKind) -> StockItem? {
        guard let id = r["id"] as? String, let urlString = r["url"] as? String, URL(string: urlString) != nil else { return nil }
        let title = (r["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let code = (r["license"] as? String ?? "").lowercased()
        let version = r["license_version"] as? String
        let license = licenseName(code, version: version)
        let requires = !(code == "cc0" || code == "pdm")
        let creator = r["creator"] as? String
        var ext = (r["filetype"] as? String ?? "").lowercased()
        if ext.isEmpty { ext = (URL(string: urlString)?.pathExtension.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "jpg" }
        if ext == "jpeg" { ext = "jpg" }
        // Jamendo reports "mp32" (its 320k mp3 format); keep only formats AVAudioFile can read.
        if kind.isAudio, !["mp3", "wav", "aiff", "aif", "m4a", "aac", "caf", "flac"].contains(ext) { ext = "mp3" }
        let attribution = (r["attribution"] as? String)
            ?? "\"\(title)\"\(creator.map { " by \($0)" } ?? "") is licensed under \(license)."
        let credit = AssetCredit(title: title, creator: creator, license: license,
                                 licenseURL: r["license_url"] as? String,
                                 sourceURL: r["foreign_landing_url"] as? String,
                                 attribution: attribution, requiresAttribution: requires,
                                 ref: (kind.isAudio ? "openverse-audio:" : "openverse:") + id)
        let ref = (kind.isAudio ? "openverse-audio:" : "openverse:") + id
        var item = StockItem(ref: ref, kind: kind, title: title,
                             thumbnailURL: (r["thumbnail"] as? String).flatMap(URL.init(string:)),
                             fileExtension: ext, width: r["width"] as? Int, height: r["height"] as? Int, credit: credit)
        item.downloadURL = URL(string: urlString)
        if let ms = r["duration"] as? Double { item.duration = ms / 1000 }
        if let g = r["genres"] as? [String] { item.genres = g }
        return item
    }

    private static func licenseName(_ code: String, version: String?) -> String {
        switch code {
        case "cc0": return "CC0 1.0 (public domain)"
        case "pdm": return "Public Domain Mark"
        case "": return "Unknown license"
        default:
            return "CC \(code.uppercased())" + (version.map { " \($0)" } ?? "")
        }
    }

    private static func searchIcons(_ q: String, page: Int) throws -> [StockItem] {
        var c = URLComponents(string: "https://api.iconify.design/search")!
        c.queryItems = [
            URLQueryItem(name: "query", value: q),
            URLQueryItem(name: "limit", value: String(iconPageSize)),
            URLQueryItem(name: "start", value: String((max(1, page) - 1) * iconPageSize)),
        ]
        let obj = try HTTP.json(c.url!)
        let collections = obj["collections"] as? [String: [String: Any]] ?? [:]
        return (obj["icons"] as? [String] ?? []).compactMap { full in
            let parts = full.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return iconItem(prefix: parts[0], name: parts[1], collection: collections[parts[0]])
        }
    }

    private static func iconItem(prefix: String, name: String, collection: [String: Any]?) -> StockItem {
        let setName = collection?["name"] as? String ?? prefix
        let lic = collection?["license"] as? [String: Any]
        let license = (lic?["title"] as? String) ?? "Open source (see iconify.design)"
        let spdx = (lic?["spdx"] as? String ?? "").uppercased()
        let author = (collection?["author"] as? [String: Any])?["name"] as? String
        let requires = spdx.hasPrefix("CC-BY")
        let credit = AssetCredit(title: "\(name) (\(setName))", creator: author, license: license,
                                 licenseURL: lic?["url"] as? String,
                                 sourceURL: "https://icon-sets.iconify.design/\(prefix)/?icon-filter=\(name)",
                                 attribution: "Icon \"\(name)\" from \(setName)\(author.map { " by \($0)" } ?? ""), \(license).",
                                 requiresAttribution: requires, ref: "iconify:\(prefix):\(name)")
        var item = StockItem(ref: "iconify:\(prefix):\(name)", kind: .icon, title: "\(prefix):\(name)",
                             thumbnailURL: iconURL(prefix: prefix, name: name, color: "#FFFFFF", height: 64), // shown on dark tiles
                             fileExtension: "svg", credit: credit)
        item.isMulticolor = collection?["palette"] as? Bool ?? false
        return item
    }

    static func iconURL(prefix: String, name: String, color: String?, height: Int) -> URL? {
        var c = URLComponents(string: "https://api.iconify.design/\(prefix)/\(name).svg")!
        var q = [URLQueryItem(name: "height", value: String(height))]
        if let color { q.append(URLQueryItem(name: "color", value: color)) }
        c.queryItems = q
        return c.url
    }

    // MARK: Import

    /// Looks up a ref returned by `search` (works across app launches).
    public static func item(ref: String) throws -> StockItem {
        let parts = ref.split(separator: ":").map(String.init)
        switch parts.first {
        case "openverse" where parts.count == 2:
            let obj = try HTTP.json(URL(string: "https://api.openverse.org/v1/images/\(parts[1])/")!)
            let kind: StockKind = (obj["category"] as? String) == "photograph" ? .photo : .illustration
            guard let item = openverseItem(obj, kind: kind) else { throw AssetError.failed("Openverse has no image \(parts[1])") }
            return item
        case "openverse-audio" where parts.count == 2:
            let obj = try HTTP.json(URL(string: "https://api.openverse.org/v1/audio/\(parts[1])/")!)
            let kind: StockKind = (obj["source"] as? String) == "freesound" ? .sound : .music
            guard let item = openverseItem(obj, kind: kind) else { throw AssetError.failed("Openverse has no audio \(parts[1])") }
            return item
        case "iconify" where parts.count == 3:
            let info = try? HTTP.json(URL(string: "https://api.iconify.design/collections?prefixes=\(parts[1])")!)
            return iconItem(prefix: parts[1], name: parts[2], collection: info?[parts[1]] as? [String: Any])
        default:
            throw AssetError.failed("Unknown ref '\(ref)'. Use a ref from search_stock, e.g. openverse:<id> or iconify:mdi:rocket.")
        }
    }

    /// Downloads an item into the asset library and records its credit. Icons are saved as SVG in `color`
    /// (hex, default white) at `size` px tall. Blocking; call off the main thread.
    @discardableResult
    public static func importItem(_ item: StockItem, name: String? = nil, folder: String? = nil, color: String? = nil,
                                  size: Int = 512) throws -> AssetInfo {
        let typeFolder: String
        switch item.kind {
        case .icon: typeFolder = "icons"
        case .music: typeFolder = "music"
        case .sound: typeFolder = "sfx"
        default: typeFolder = "images"
        }
        // Projects file stock items by type unless a folder is given.
        let folder = try AssetStore.validFolder(AssetStore.routed(folder, default: typeFolder))
        let url: URL
        var fileName: String
        if item.kind == .icon {
            let parts = item.ref.split(separator: ":").map(String.init)
            guard parts.count == 3 else { throw AssetError.failed("Bad icon ref \(item.ref)") }
            let hex = item.isMulticolor ? nil : normalizedHex(color ?? "#FFFFFF")
            guard let u = iconURL(prefix: parts[1], name: parts[2], color: hex, height: min(max(size, 16), 2048)) else {
                throw AssetError.failed("Bad icon name \(item.ref)")
            }
            url = u
            fileName = "\(parts[1])-\(parts[2])" + (hex.map { "-" + $0.dropFirst().lowercased() } ?? "") + ".svg"
        } else {
            guard let u = item.downloadURL else { throw AssetError.failed("No download URL for \(item.ref)") }
            url = u
            fileName = slug(item.title) + "." + item.fileExtension
        }
        if let name, !name.isEmpty {
            fileName = (name as NSString).pathExtension.isEmpty ? "\(name).\(item.fileExtension)" : name
        } else if AssetStore.credit(for: AssetStore.join(folder, fileName))?.ref == item.ref,
                  let existing = try? AssetStore.existing(AssetStore.join(folder, fileName)),
                  let info = AssetStore.info(existing) {
            return info // already imported (same item, same color)
        }
        var asset = try AssetStore.download(url, name: fileName, folder: folder)
        if item.kind.isAudio, asset.duration == nil || !AudioFileInfo.isDecodable(asset.path) {
            try? AssetStore.trash(asset.path)
            throw AssetError.failed("The downloaded file for '\(item.title)' is not playable audio. Try another result.")
        }
        AssetStore.setCredit(item.credit, for: asset.name)
        asset.credit = item.credit
        return asset
    }

    static func normalizedHex(_ s: String) -> String {
        let h = s.trimmingCharacters(in: .whitespaces)
        return h.hasPrefix("#") ? h : "#" + h
    }

    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var out = ""
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII { out.unicodeScalars.append(ch) }
            else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "image" : trimmed
    }

    // MARK: Previews

    /// Downloads thumbnails (in parallel) and decodes them, keyed by item index. Blocking.
    public static func thumbnails(_ items: [StockItem], timeout: TimeInterval = 20) -> [Int: CGImage] {
        var images: [Int: CGImage] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            guard let img = loadThumbnail(items[i], timeout: timeout) else { return }
            lock.lock(); images[i] = img; lock.unlock()
        }
        return images
    }

    /// One result's thumbnail. Openverse cannot thumbnail SVGs (HTTP 424), so for those, and for other small
    /// originals, it falls back to the original file. Blocking; call off the main thread.
    public static func loadThumbnail(_ item: StockItem, timeout: TimeInterval = 20) -> CGImage? {
        if let u = item.thumbnailURL, let data = try? HTTP.get(u, timeout: timeout), let img = decodeImage(data) {
            return img
        }
        let pixels = (item.width ?? .max / 2) * (item.height ?? 2)
        guard let original = item.downloadURL, item.fileExtension == "svg" || pixels <= 1_500_000,
              let data = try? HTTP.get(original, timeout: timeout) else { return nil }
        return decodeImage(data)
    }

    /// Bitmap or SVG data → CGImage.
    public static func decodeImage(_ data: Data, maxPixels: Int = 256) -> CGImage? {
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixels,
           ] as CFDictionary) {
            return img
        }
        guard let ns = NSImage(data: data), ns.size.width > 0 else { return nil }
        var rect = CGRect(x: 0, y: 0, width: maxPixels, height: Int(Double(maxPixels) * ns.size.height / ns.size.width))
        return ns.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// A numbered grid of result thumbnails (PNG), so an agent can pick visually. Numbers match list order (1-based).
    public static func contactSheet(_ items: [StockItem], columns: Int = 5, cell: Int = 160) -> Data? {
        guard !items.isEmpty else { return nil }
        let thumbs = thumbnails(items)
        let cols = min(columns, items.count)
        let rows = (items.count + cols - 1) / cols
        let w = cols * cell, h = rows * cell
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: FrameRenderer.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Icons default to white, so show them on a dark background; photos on mid-grey.
        let iconsOnly = items.allSatisfy { $0.kind == .icon }
        ctx.setFillColor(iconsOnly ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for i in items.indices {
            let col = i % cols, row = i / cols
            let cellRect = CGRect(x: col * cell, y: h - (row + 1) * cell, width: cell, height: cell).insetBy(dx: 4, dy: 4)
            ctx.setFillColor(iconsOnly ? CGColor(gray: 0.2, alpha: 1) : CGColor(gray: 0.95, alpha: 1))
            ctx.fill(cellRect)
            if let img = thumbs[i] {
                let pad: CGFloat = items[i].kind == .icon ? 30 : 2
                let box = cellRect.insetBy(dx: pad, dy: pad)
                let s = min(box.width / CGFloat(img.width), box.height / CGFloat(img.height))
                let iw = CGFloat(img.width) * s, ih = CGFloat(img.height) * s
                ctx.draw(img, in: CGRect(x: box.midX - iw / 2, y: box.midY - ih / 2, width: iw, height: ih))
            }
            // Number badge (top-left).
            let label = "\(i + 1)" as CFString
            let attrs = [kCTFontAttributeName: CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil),
                         kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, label, attrs))
            let tw = CTLineGetTypographicBounds(line, nil, nil, nil)
            let badge = CGRect(x: cellRect.minX + 4, y: cellRect.maxY - 26, width: tw + 12, height: 22)
            ctx.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.85))
            ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            ctx.textPosition = CGPoint(x: badge.minX + 6, y: badge.minY + 6)
            CTLineDraw(line, ctx)
        }
        guard let img = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

// MARK: - HTTP

enum HTTP {
    /// Shared by searches, thumbnails and asset downloads. A `var` so tests can swap in their own session.
    static var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    static func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.setValue("VeyMotion/0.1 (macOS motion graphics editor)", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// Blocking GET. Do not call on the main thread.
    static func get(_ url: URL, timeout: TimeInterval = 30) throws -> Data {
        try fetch(url, timeout: timeout).data
    }

    /// Blocking GET that also returns the response (for file names / MIME types).
    static func fetch(_ url: URL, timeout: TimeInterval = 30) throws -> (data: Data, response: HTTPURLResponse?) {
        let done = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let task = session.dataTask(with: request(url, timeout: timeout)) { d, r, e in
            result = (d, r, e)
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw AssetError.failed("Request timed out: \(url.host ?? url.absoluteString)")
        }
        if let e = result.2 { throw AssetError.failed("Cannot reach \(url.host ?? "the server"): \(e.localizedDescription)") }
        if let http = result.1 as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw AssetError.failed("\(url.host ?? "The server") is rate-limiting requests. Wait a minute and try again.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw AssetError.failed("\(url.host ?? "Server") returned HTTP \(http.statusCode)")
            }
        }
        return (result.0 ?? Data(), result.1 as? HTTPURLResponse)
    }

    static func json(_ url: URL) throws -> [String: Any] {
        let data = try get(url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssetError.failed("Unexpected response from \(url.host ?? "server")")
        }
        return obj
    }
}
