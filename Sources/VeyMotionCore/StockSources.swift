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
/// - Google Fonts: open-source font families (see `GoogleFonts`).
public enum StockKind: String, CaseIterable, Codable, Sendable {
    case photo, illustration, icon, music, sound, font

    public var title: String {
        switch self {
        case .photo: return "Photos"
        case .illustration: return "Illustrations"
        case .icon: return "Icons"
        case .music: return "Music"
        case .sound: return "Sound FX"
        case .font: return "Fonts"
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
    /// Music genres; for fonts: category, weights and "Vietnamese ✓".
    public var genres: [String] = []
    /// Keywords from the source (Freesound tags describe a sound much better than its title).
    public var tags: [String] = []
    /// Fonts: available styles ("400", "700", "400i"…).
    public var fontStyles: [String] = []

    public var id: String { ref }

    /// One line for agents: "openverse:abc — Title — 1024×768 jpg — CC BY 4.0 (credit required) — by Someone".
    public var summary: String {
        var parts = [ref, title]
        if kind == .font {
            parts.append(genres.joined(separator: ", "))
        } else if let d = duration {
            parts.append(Self.clock(d) + " " + fileExtension + (genres.isEmpty ? "" : " — " + genres.prefix(3).joined(separator: ", ")))
            if kind == .sound, !tags.isEmpty { parts.append("tags: " + tags.prefix(8).joined(separator: ", ")) }
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

    /// Sound effects longer than this are left out unless a search asks for longer ones.
    public static let defaultSoundMaxDuration = 10.0

    /// Blocking; call off the main thread. `page` starts at 1.
    /// `vietnamese`: fonts only, keep families with Vietnamese letters.
    /// `maxDuration`: audio only, leave out longer results (sounds default to `defaultSoundMaxDuration`; 0 = no limit).
    public static func search(_ query: String, kind: StockKind, page: Int = 1, vietnamese: Bool = false,
                              maxDuration: Double? = nil) throws -> [StockItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        switch kind {
        case .font: return try GoogleFonts.search(q, page: page, vietnamese: vietnamese)
        case .icon: return try searchIcons(q, page: page)
        case .photo, .illustration: return try searchOpenverse(q, kind: kind, page: page)
        case .music, .sound:
            let limit = maxDuration ?? (kind == .sound ? defaultSoundMaxDuration : 0)
            return try searchOpenverseAudio(q, kind: kind, page: page, maxDuration: limit > 0 ? limit : nil)
        }
    }

    /// Words that mark a Freesound result as a background bed rather than a one-shot effect.
    static let bedWords = ["loop", "ambience", "ambiance", "ambient", "atmosphere", "atmos", "soundscape", "field-recording",
                           "field recording", "drone", "music", "song", "melody", "background", "room tone"]

    private static func searchOpenverseAudio(_ q: String, kind: StockKind, page: Int, maxDuration: Double?) throws -> [StockItem] {
        var c = URLComponents(string: "https://api.openverse.org/v1/audio/")!
        var items = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "page_size", value: "20"),
            URLQueryItem(name: "license_type", value: "commercial,modification"),
            // Jamendo is all music; Freesound is sound effects (its items have no category).
            URLQueryItem(name: "source", value: kind == .music ? "jamendo" : "freesound"),
        ]
        // Openverse length buckets: shortest < 30 s, short 30 s–2 min, medium 2–10 min, long > 10 min.
        if let m = maxDuration {
            let buckets = m <= 30 ? "shortest" : m <= 120 ? "shortest,short" : m <= 600 ? "shortest,short,medium" : nil
            if let buckets { items.append(URLQueryItem(name: "length", value: buckets)) }
        }
        c.queryItems = items
        let obj: [String: Any]
        do {
            obj = try HTTP.json(c.url!)
        } catch where items.contains(where: { $0.name == "length" }) {
            // Older API versions reject `length`: retry without it and filter by duration here.
            c.queryItems = items.filter { $0.name != "length" }
            obj = try HTTP.json(c.url!)
        }
        let results = obj["results"] as? [[String: Any]] ?? []
        var found = results.compactMap { openverseItem($0, kind: kind) }
        if let m = maxDuration { found = found.filter { ($0.duration ?? 0) <= m + 0.05 } }
        guard kind == .sound else { return found }
        // One-shot effects first: beds (loops, ambiences, music) go last unless the query asks for one.
        let lowered = q.lowercased()
        let wanted = bedWords.filter { lowered.contains($0) }
        func isBed(_ item: StockItem) -> Bool {
            guard wanted.isEmpty else { return false }
            let text = (item.title + " " + item.tags.joined(separator: " ")).lowercased()
            return bedWords.contains { text.contains($0) }
        }
        return found.filter { !isBed($0) } + found.filter(isBed)
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
        if let tags = r["tags"] as? [[String: Any]] {
            var seen = Set<String>()
            item.tags = tags.compactMap { ($0["name"] as? String)?.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
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
        case "googlefonts" where parts.count == 2:
            return GoogleFonts.item(try GoogleFonts.family(named: parts[1]))
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
        if item.kind == .font {
            guard let first = try importFont(item, folder: folder).first else { throw AssetError.failed("No font files") }
            return first
        }
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
        var asset: AssetInfo
        if item.kind.isAudio, let cached = cachedAudio(item) {
            asset = try AssetStore.write(try Data(contentsOf: cached), name: fileName, folder: folder)
        } else {
            asset = try AssetStore.download(url, name: fileName, folder: folder)
        }
        if item.kind.isAudio, asset.duration == nil || !AudioFileInfo.isDecodable(asset.path) {
            _ = try? AssetStore.trash(asset.path)
            throw AssetError.failed("The downloaded file for '\(item.title)' is not playable audio. Try another result.")
        }
        AssetStore.setCredit(item.credit, for: asset.name)
        asset.credit = item.credit
        return asset
    }

    /// Downloads a font family's styles ("400", "700i"…; default every upright weight) into the library and
    /// registers them, so a text layer can use the family as its fontName right away. Blocking.
    @discardableResult
    public static func importFont(_ item: StockItem, styles: [String]? = nil, folder: String? = nil) throws -> [AssetInfo] {
        guard item.ref.hasPrefix(GoogleFonts.refPrefix) else { throw AssetError.failed("\(item.ref) is not a font") }
        let family = try GoogleFonts.family(named: String(item.ref.dropFirst(GoogleFonts.refPrefix.count)))
        return try GoogleFonts.importFamily(family, styles: styles, folder: folder)
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

    // MARK: Sound previews

    private static var audioCacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VeyMotion/cache/sounds", isDirectory: true)
    }

    private static func audioCacheURL(_ item: StockItem) -> URL {
        let id = item.ref.split(separator: ":").last.map(String.init) ?? slug(item.title)
        return audioCacheDir.appendingPathComponent("\(id).\(item.fileExtension)")
    }

    /// The file of an audio result if a search already downloaded it.
    static func cachedAudio(_ item: StockItem) -> URL? {
        let url = audioCacheURL(item)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloads short audio results (into a cache that `importItem` reuses) and profiles them, keyed by item index,
    /// so an agent can tell a one-shot whoosh from a loop without listening. Results over `maxDuration` are skipped.
    /// Blocking.
    public static func soundProfiles(_ items: [StockItem], maxDuration: Double = 30, timeout: TimeInterval = 20) -> [Int: SoundProfile] {
        let fm = FileManager.default
        try? fm.createDirectory(at: audioCacheDir, withIntermediateDirectories: true)
        pruneAudioCache()
        var out: [Int: SoundProfile] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { i in
            let item = items[i]
            guard item.kind.isAudio, (item.duration ?? 0) <= maxDuration, let remote = item.downloadURL else { return }
            let url = audioCacheURL(item)
            if !fm.fileExists(atPath: url.path) {
                guard let data = try? HTTP.get(remote, timeout: timeout), !data.isEmpty, data.count < 20_000_000 else { return }
                let part = url.appendingPathExtension("part\(i)")
                guard (try? data.write(to: part)) != nil else { return }
                if (try? fm.moveItem(at: part, to: url)) == nil { try? fm.removeItem(at: part) }
            }
            guard AudioFileInfo.isDecodable(url.path) else { try? fm.removeItem(at: url); return }
            guard let p = SoundProfile.cached(path: url.path) else { return }
            lock.lock(); out[i] = p; lock.unlock()
        }
        return out
    }

    /// Keeps the preview cache to the 400 most recent files.
    private static func pruneAudioCache() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: audioCacheDir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > 400 else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(400) { try? fm.removeItem(at: url) }
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
        if item.kind == .font { return GoogleFonts.preview(item, timeout: timeout) }
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
        // Font samples are wide.
        let fonts = items.allSatisfy { $0.kind == .font }
        let cellW = fonts ? 400 : cell, cellH = fonts ? 112 : cell
        let cols = min(fonts ? 3 : columns, items.count)
        let rows = (items.count + cols - 1) / cols
        let w = cols * cellW, h = rows * cellH
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: FrameRenderer.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Icons default to white, so show them on a dark background; photos on mid-grey.
        let iconsOnly = items.allSatisfy { $0.kind == .icon || $0.kind == .font }
        ctx.setFillColor(iconsOnly ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for i in items.indices {
            let col = i % cols, row = i / cols
            let cellRect = CGRect(x: col * cellW, y: h - (row + 1) * cellH, width: cellW, height: cellH).insetBy(dx: 4, dy: 4)
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
        let result = try perform(request(url, timeout: timeout))
        if let http = result.response {
            if http.statusCode == 429 {
                throw AssetError.failed("\(url.host ?? "The server") is rate-limiting requests. Wait a minute and try again.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw AssetError.failed("\(url.host ?? "Server") returned HTTP \(http.statusCode)")
            }
        }
        return result
    }

    /// Blocking request of any method. Throws only when the server cannot be reached; the caller checks the status.
    static func perform(_ req: URLRequest) throws -> (data: Data, response: HTTPURLResponse?) {
        let url = req.url
        let timeout = req.timeoutInterval
        let done = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let task = session.dataTask(with: req) { d, r, e in
            result = (d, r, e)
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw AssetError.failed("Request timed out: \(url?.host ?? url?.absoluteString ?? "")")
        }
        if let e = result.2 { throw AssetError.failed("Cannot reach \(url?.host ?? "the server"): \(e.localizedDescription)") }
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
