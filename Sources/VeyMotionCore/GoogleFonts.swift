import AppKit
import CoreText
import Foundation

/// Google Fonts (keyless): the family list comes from fonts.google.com/metadata/fonts (cached for a week) and the
/// font files from the CSS API, which serves static TrueType files per weight to clients that are not browsers.
enum GoogleFonts {
    struct Family: Sendable {
        var name: String
        var category: String
        /// "400", "700", "400i"…
        var styles: [String]
        var subsets: [String]
        /// Rank (1 = most used).
        var popularity: Int
        var designers: [String]

        var vietnamese: Bool { subsets.contains("vietnamese") }
        var upright: [Int] { styles.filter { !$0.hasSuffix("i") }.compactMap { Int($0) }.sorted() }
        var hasItalic: Bool { styles.contains { $0.hasSuffix("i") } }
    }

    static let refPrefix = "googlefonts:"
    private static let lock = NSLock()
    private static var memory: [Family]?
    private static let maxAge: TimeInterval = 7 * 24 * 3600

    private static var cacheFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VeyMotion/cache/google-fonts.json")
    }

    /// Every family, from memory, the disk cache or the network. Blocking.
    static func families() throws -> [Family] {
        lock.lock()
        if let m = memory { lock.unlock(); return m }
        lock.unlock()
        let fm = FileManager.default
        var data: Data?
        if let attrs = try? fm.attributesOfItem(atPath: cacheFile.path), let date = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < maxAge {
            data = try? Data(contentsOf: cacheFile)
        }
        var list = data.flatMap { try? parse($0) }
        if list == nil || list?.isEmpty == true {
            let fresh = try HTTP.get(URL(string: "https://fonts.google.com/metadata/fonts")!, timeout: 60)
            list = try parse(fresh)
            try? fm.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? SceneJSON.write(fresh, to: cacheFile)
        }
        let result = list ?? []
        lock.lock()
        memory = result
        lock.unlock()
        return result
    }

    static func parse(_ data: Data) throws -> [Family] {
        // The response may start with an anti-JSON-hijacking prefix.
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let obj = try JSONSerialization.jsonObject(with: data[start...]) as? [String: Any],
              let list = obj["familyMetadataList"] as? [[String: Any]] else {
            throw AssetError.failed("Unexpected font list from Google Fonts")
        }
        return list.compactMap { f in
            guard let name = f["family"] as? String, f["isOpenSource"] as? Bool ?? true else { return nil }
            let styles = (f["fonts"] as? [String: Any]).map { Array($0.keys) } ?? ["400"]
            return Family(name: name, category: f["category"] as? String ?? "",
                          styles: styles.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                          subsets: f["subsets"] as? [String] ?? [], popularity: f["popularity"] as? Int ?? 99_999,
                          designers: f["designers"] as? [String] ?? [])
        }
    }

    static func family(named name: String) throws -> Family {
        let key = name.lowercased().filter { !$0.isWhitespace }
        guard let f = try families().first(where: { $0.name.lowercased().filter { !$0.isWhitespace } == key }) else {
            throw AssetError.failed("Google Fonts has no family '\(name)'. Use search_stock kind \"font\".")
        }
        return f
    }

    // MARK: Search

    private static let categoryWords: [String: String] = [
        "serif": "Serif", "sans": "Sans Serif", "sansserif": "Sans Serif", "sans-serif": "Sans Serif",
        "display": "Display", "decorative": "Display", "handwriting": "Handwriting", "handwritten": "Handwriting",
        "script": "Handwriting", "cursive": "Handwriting", "calligraphy": "Handwriting", "brush": "Handwriting",
        "mono": "Monospace", "monospace": "Monospace", "code": "Monospace", "terminal": "Monospace",
        // Moods
        "elegant": "Serif", "luxury": "Serif", "classic": "Serif", "editorial": "Serif", "wedding": "Handwriting",
        "modern": "Sans Serif", "clean": "Sans Serif", "minimal": "Sans Serif", "tech": "Sans Serif",
        "corporate": "Sans Serif", "geometric": "Sans Serif", "playful": "Display", "fun": "Display",
        "poster": "Display", "headline": "Display", "retro": "Display", "cute": "Handwriting", "signature": "Handwriting",
    ]
    private static let vietnameseWords: Set<String> = ["vietnamese", "vietnam", "việt", "viet", "tiếng"]
    private static let anyWords: Set<String> = ["*", "any", "all", "popular", "font", "fonts", "typeface"]

    /// Matches family names, categories ("serif", "handwriting"…) and moods ("elegant", "playful"…), most used first.
    static func search(_ query: String, page: Int, vietnamese: Bool, pageSize: Int = 20) throws -> [StockItem] {
        let found = matching(query, in: try families(), vietnamese: vietnamese)
        return found.dropFirst((max(1, page) - 1) * pageSize).prefix(pageSize).map(item)
    }

    static func matching(_ query: String, in all: [Family], vietnamese: Bool) -> [Family] {
        var words = query.lowercased().split { $0 == " " || $0 == "," }.map(String.init)
        var vi = vietnamese
        var categories = Set<String>()
        words.removeAll { w in
            if vietnameseWords.contains(w) { vi = true; return true }
            if let c = categoryWords[w] { categories.insert(c); return true }
            return anyWords.contains(w)
        }
        var list = all.filter { !vi || $0.vietnamese }
        if !words.isEmpty {
            let phrase = words.joined(separator: " ")
            let byName = list.filter { f in
                let n = f.name.lowercased()
                return n.contains(phrase) || words.allSatisfy { n.contains($0) }
            }
            // Unknown words with a category: just the category.
            list = byName.isEmpty && !categories.isEmpty ? list : byName
        }
        let inCategory = list.filter { categories.contains($0.category) }
        if !inCategory.isEmpty { list = inCategory }
        // Names that start with (or contain) the whole query come first, then the most used.
        let full = query.lowercased().trimmingCharacters(in: .whitespaces)
        func rank(_ f: Family) -> Int {
            let n = f.name.lowercased()
            return n.hasPrefix(full) ? 0 : n.contains(full) ? 1 : 2
        }
        return list.sorted { (rank($0), $0.popularity) < (rank($1), $1.popularity) }
    }

    static func item(_ f: Family) -> StockItem {
        let up = f.upright
        var weights = up.isEmpty ? "italic only" : up.count == 1 ? "weight \(up[0])" : "weights \(up.first!)–\(up.last!)"
        if f.hasItalic, !up.isEmpty { weights += " + italic" }
        let by = f.designers.prefix(3).joined(separator: ", ")
        let credit = AssetCredit(title: "\(f.name) font", creator: by.isEmpty ? nil : by,
                                 license: "Open font license (OFL / Apache, via Google Fonts)",
                                 licenseURL: "https://fonts.google.com/attribution",
                                 sourceURL: "https://fonts.google.com/specimen/" + f.name.replacingOccurrences(of: " ", with: "+"),
                                 attribution: "Font \"\(f.name)\"\(by.isEmpty ? "" : " by \(by)"), from Google Fonts.",
                                 requiresAttribution: false, ref: refPrefix + f.name)
        var item = StockItem(ref: refPrefix + f.name, kind: .font, title: f.name, thumbnailURL: nil,
                             fileExtension: "ttf", credit: credit)
        item.genres = [f.category, weights] + (f.vietnamese ? ["Vietnamese ✓"] : [])
        item.fontStyles = f.styles
        return item
    }

    // MARK: Files

    /// CSS API URL for some styles ("400", "700i"…), optionally only for the glyphs of `text` (a tiny preview font).
    static func cssURL(_ family: String, styles: [String], text: String? = nil) -> URL? {
        let parsed = styles.compactMap { s -> (Int, Int)? in
            let italic = s.hasSuffix("i")
            return Int(italic ? String(s.dropLast()) : s).map { (italic ? 1 : 0, $0) }
        }.sorted { $0 < $1 }
        var spec = family
        if parsed.contains(where: { $0.0 == 1 }) {
            spec += ":ital,wght@" + parsed.map { "\($0.0),\($0.1)" }.joined(separator: ";")
        } else if parsed.map(\.1) != [400] {
            spec += ":wght@" + parsed.map { String($0.1) }.joined(separator: ";")
        }
        var c = URLComponents(string: "https://fonts.googleapis.com/css2")!
        c.queryItems = [URLQueryItem(name: "family", value: spec)]
        if let text { c.queryItems?.append(URLQueryItem(name: "text", value: text)) }
        return c.url
    }

    /// The @font-face rules of a CSS API response.
    static func parseCSS(_ css: String) -> [(weight: Int, italic: Bool, url: URL)] {
        css.components(separatedBy: "@font-face").dropFirst().compactMap { block in
            func value(_ key: String) -> String? {
                guard let r = block.range(of: key + ":") else { return nil }
                let rest = block[r.upperBound...]
                return rest.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
            }
            guard let src = value("src"), let open = src.range(of: "url("),
                  let close = src[open.upperBound...].firstIndex(of: ")"),
                  let url = URL(string: String(src[open.upperBound..<close])) else { return nil }
            return (Int(value("font-weight") ?? "400") ?? 400, value("font-style") == "italic", url)
        }
    }

    private static let styleNames = [100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium",
                                     600: "SemiBold", 700: "Bold", 800: "ExtraBold", 900: "Black"]

    /// Downloads a family's styles (default: every upright weight) into the library. Blocking.
    static func importFamily(_ f: Family, styles requested: [String]?, folder: String?) throws -> [AssetInfo] {
        var wanted = (requested?.isEmpty == false ? requested! : f.styles.filter { !$0.hasSuffix("i") })
            .map { $0.lowercased().replacingOccurrences(of: "italic", with: "i").replacingOccurrences(of: " ", with: "") }
        if wanted.isEmpty { wanted = f.styles }
        let missing = wanted.filter { !f.styles.contains($0) }
        guard missing.isEmpty else {
            throw AssetError.failed("\(f.name) has no style \(missing.joined(separator: ", ")). Available: \(f.styles.joined(separator: ", ")) (i = italic).")
        }
        guard let css = cssURL(f.name, styles: wanted) else { throw AssetError.failed("Bad font name \(f.name)") }
        let faces = parseCSS(String(decoding: try HTTP.get(css), as: UTF8.self))
        guard !faces.isEmpty else { throw AssetError.failed("Google Fonts returned no files for \(f.name)") }
        let dir = try AssetStore.validFolder(AssetStore.routed(folder, default: "fonts"))
        let base = f.name.filter { $0.isLetter || $0.isNumber }
        let credit = item(f).credit
        var out: [AssetInfo] = []
        for face in faces {
            let style = (styleNames[face.weight] ?? String(face.weight))
            let fileName = "\(base)-\(face.italic ? (face.weight == 400 ? "Italic" : style + "Italic") : style).ttf"
            let name = AssetStore.join(dir, fileName)
            if AssetStore.credit(for: name)?.ref == credit.ref, let url = try? AssetStore.existing(name),
               let info = AssetStore.info(url) {
                out.append(info) // already imported
                continue
            }
            var info = try AssetStore.write(try HTTP.get(face.url, timeout: 60), name: fileName, folder: dir, overwrite: true)
            AssetStore.setCredit(credit, for: info.name)
            info.credit = credit
            out.append(info)
        }
        FontLibrary.refresh(force: true)
        return out
    }

    // MARK: Preview

    /// The family's name and a sample line drawn in the font itself (a tiny subset download), white on dark.
    static func preview(_ item: StockItem, timeout: TimeInterval = 20) -> CGImage? {
        guard item.ref.hasPrefix(refPrefix) else { return nil }
        let name = String(item.ref.dropFirst(refPrefix.count))
        let vi = item.genres.contains("Vietnamese ✓")
        let sample = vi ? "Chữ Việt đẹp quá" : "The quick brown fox"
        let upright = item.fontStyles.filter { !$0.hasSuffix("i") }
        let style = upright.contains("400") ? "400" : upright.first ?? item.fontStyles.first ?? "400"
        guard let css = cssURL(name, styles: [style], text: name + sample),
              let cssData = try? HTTP.get(css, timeout: timeout),
              let fontURL = parseCSS(String(decoding: cssData, as: UTF8.self)).first?.url,
              let fontData = try? HTTP.get(fontURL, timeout: timeout),
              let desc = CTFontManagerCreateFontDescriptorFromData(fontData as CFData) else { return nil }
        let w = 640, h = 170
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: FrameRenderer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func line(_ text: String, size: CGFloat, gray: CGFloat) -> (CTLine, CGFloat) {
            var s = size
            while true {
                let font = CTFontCreateWithFontDescriptor(desc, s, nil)
                let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1)] as CFDictionary
                let l = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs))
                let width = CTLineGetTypographicBounds(l, nil, nil, nil)
                if width <= Double(w - 40) || s < 12 { return (l, CGFloat(width)) }
                s *= 0.9
            }
        }
        let (title, tw) = line(name, size: 64, gray: 1)
        ctx.textPosition = CGPoint(x: (CGFloat(w) - tw) / 2, y: 82)
        CTLineDraw(title, ctx)
        let (sub, sw) = line(sample, size: 34, gray: 0.7)
        ctx.textPosition = CGPoint(x: (CGFloat(w) - sw) / 2, y: 24)
        CTLineDraw(sub, ctx)
        return ctx.makeImage()
    }
}
