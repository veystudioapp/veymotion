import AppKit
import CoreText
import Foundation

/// Fonts for text layers: installed fonts plus font files in the asset libraries (registered for this process, so
/// preview, `vmotion` and export all draw them). `fontName` may be a family ("Be Vietnam Pro", picked by `fontWeight`),
/// a PostScript name ("BeVietnamPro-Bold") or a full name ("Be Vietnam Pro Bold").
public enum FontLibrary {
    public static let fileExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    public struct Face: Hashable, Sendable {
        public var postScriptName: String
        public var style: String
        /// CSS-style weight, 100 (thin) … 900 (black).
        public var weight: Int
        public var italic: Bool
    }

    private static let lock = NSLock()
    /// Registered font files by path, with the modification time they were registered at.
    private static var registered: [String: Double] = [:]
    /// Family names that come from library files.
    private static var libraryFamilyNames: Set<String> = []
    private static var lastScan = Date.distantPast
    private static var resolved: [String: String?] = [:]
    private static var faceCache: [String: [Face]] = [:]
    private static var familyIndex: [String: String]?

    // MARK: Registration

    /// Registers new or changed font files from the active and shared asset libraries. Without `force`, scans at
    /// most every 2 seconds. Returns true when something new was registered.
    @discardableResult
    public static func refresh(force: Bool = false) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard force || Date().timeIntervalSince(lastScan) > 2 else { return false }
        lastScan = Date()
        var changed = false
        for dir in Set([AssetStore.directory.standardizedFileURL, AssetStore.sharedDirectory.standardizedFileURL]) {
            for url in fontFiles(in: dir) {
                let mtime = modificationTime(url.path)
                if let known = registered[url.path] {
                    if known == mtime { continue }
                    CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
                }
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    for family in families(inFile: url) { libraryFamilyNames.insert(family) }
                    changed = true
                }
                registered[url.path] = mtime
            }
        }
        if changed {
            resolved.removeAll()
            faceCache.removeAll()
            familyIndex = nil
        }
        return changed
    }

    static func fontFiles(in dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { fileExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Family names of the fonts in a file (without registering it).
    public static func families(inFile url: URL) -> [String] {
        let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return Array(Set(descs.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String })).sorted()
    }

    /// Style names in a file, e.g. ["Bold"], for listing assets.
    public static func faces(inFile url: URL) -> [String] {
        let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        return descs.compactMap { d in
            let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String ?? ""
            let style = CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? ""
            return "\(family) \(style)".trimmingCharacters(in: .whitespaces)
        }
    }

    private static func modificationTime(_ path: String) -> Double {
        var info = stat()
        return stat(path, &info) == 0 ? Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9 : 0
    }

    // MARK: Lookup

    /// Every family that can be used (installed + library fonts), sorted.
    public static func allFamilies() -> [String] {
        refresh()
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Families to offer: like `allFamilies`, without the per-weight families of static font files
    /// ("Be Vietnam Pro Black" is a weight of "Be Vietnam Pro").
    public static func listedFamilies() -> [String] {
        let all = allFamilies()
        let set = Set(all)
        return all.filter { subfamily($0, in: set) == nil }
    }

    /// "Be Vietnam Pro Black" → ("Be Vietnam Pro", 900) when that base family exists. Static font files name
    /// weights other than regular and bold as families of their own.
    static func subfamily(_ name: String, in families: Set<String>) -> (base: String, weight: Int)? {
        let words = name.split(separator: " ").map(String.init)
        for n in [1, 2] where words.count > n {
            let base = words.dropLast(n).joined(separator: " ")
            let suffix = words.suffix(n).joined().lowercased()
            let weights = ["thin": 100, "hairline": 100, "extralight": 200, "ultralight": 200, "light": 300,
                           "book": 400, "medium": 500, "semibold": 600, "demibold": 600, "extrabold": 800,
                           "ultrabold": 800, "black": 900, "heavy": 900]
            if let w = weights[suffix], families.contains(base) { return (base, w) }
        }
        return nil
    }

    /// Families that come from font files in the asset libraries.
    public static var libraryFamilies: [String] {
        refresh()
        lock.lock()
        defer { lock.unlock() }
        return libraryFamilyNames.sorted()
    }

    /// The faces of a family, lightest first.
    public static func faces(of family: String) -> [Face] {
        lock.lock()
        if let cached = faceCache[family] { lock.unlock(); return cached }
        lock.unlock()
        func descriptors(_ name: String) -> [CTFontDescriptor] {
            let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
            return CTFontDescriptorCreateMatchingFontDescriptors(desc, Set([kCTFontFamilyNameAttribute as String]) as CFSet)
                as? [CTFontDescriptor] ?? []
        }
        var sources: [(CTFontDescriptor, Int?)] = descriptors(family).map { ($0, nil) }
        let all = Set(allFamilies())
        for other in all where other.hasPrefix(family + " ") {
            if let sub = subfamily(other, in: all), sub.base == family {
                sources += descriptors(other).map { ($0, sub.weight) }
            }
        }
        var seen = Set<String>()
        var out: [Face] = []
        for (d, forcedWeight) in sources {
            guard let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String, seen.insert(ps).inserted else { continue }
            let style = CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? ""
            let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
            let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let italic = symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
                || style.lowercased().contains("italic") || style.lowercased().contains("oblique")
            let trait = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            out.append(Face(postScriptName: ps, style: style,
                            weight: forcedWeight ?? weight(styleName: style) ?? weight(trait: trait), italic: italic))
        }
        out.sort { ($0.weight, $0.italic ? 1 : 0) < ($1.weight, $1.italic ? 1 : 0) }
        lock.lock()
        faceCache[family] = out
        lock.unlock()
        return out
    }

    /// PostScript name for `name` (family, PostScript or full name) at a `fontWeight` such as "bold", "light italic"
    /// or "600"; nil when no such font exists (the system font is used then).
    public static func resolve(_ name: String, weight fontWeight: String) -> String? {
        let key = name + "|" + fontWeight
        lock.lock()
        let hit = resolved[key]
        lock.unlock()
        if let hit {
            // A miss is rechecked (at most every 2 s) in case the font was added to the library since.
            if hit != nil || !refresh() { return hit }
        }
        var result = lookup(name, weight: fontWeight)
        if result == nil, refresh() { result = lookup(name, weight: fontWeight) }
        lock.lock()
        resolved[key] = result
        lock.unlock()
        return result
    }

    private static func lookup(_ raw: String, weight fontWeight: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let family = familyName(matching: name) {
            let want = parseWeight(fontWeight)
            let faces = faces(of: family)
            let best = faces.min { a, b in
                score(a, want) < score(b, want)
            }
            if let best { return best.postScriptName }
        }
        // PostScript or full name of one face.
        return NSFont(name: name, size: 12)?.fontName
    }

    private static func score(_ f: Face, _ want: (weight: Int, italic: Bool)) -> Int {
        abs(f.weight - want.weight) + (f.italic == want.italic ? 0 : 1000)
    }

    /// The installed family whose name matches, ignoring case and spaces.
    public static func familyName(matching name: String) -> String? {
        lock.lock()
        if familyIndex == nil {
            lock.unlock()
            let index = Dictionary(allFamilies().map { (squash($0), $0) }, uniquingKeysWith: { a, _ in a })
            lock.lock()
            familyIndex = index
        }
        let hit = familyIndex?[squash(name)]
        lock.unlock()
        return hit
    }

    private static func squash(_ s: String) -> String {
        s.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
    }

    /// Families with names close to `name`, best first.
    public static func suggestions(for name: String, limit: Int = 5) -> [String] {
        let q = squash(name)
        guard !q.isEmpty else { return [] }
        let all = listedFamilies()
        let contains = all.filter { squash($0).contains(q) || q.contains(squash($0)) }
        let ranked = all.map { ($0, distance(q, squash($0))) }.sorted { $0.1 < $1.1 }.map(\.0)
        var out: [String] = []
        for f in contains + ranked where !out.contains(f) {
            out.append(f)
            if out.count == limit { break }
        }
        return out
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// Characters of `text` the font has no glyph for (CoreText would borrow them from another font).
    public static func missingCharacters(_ text: String, postScriptName: String) -> [Character] {
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        var missing: [Character] = []
        for ch in Set(text) where !ch.isWhitespace && !ch.isNewline {
            let units = Array(String(ch).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            if !CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count) { missing.append(ch) }
        }
        return missing.sorted()
    }

    /// Letters a font needs for Vietnamese text.
    public static let vietnameseSample = "ĂăÂâĐđÊêÔôƠơƯưẠạẢảẤấẦầẨẩẪẫẬậẮắẰằẲẳẴẵẶặẸẹẺẻẼẽẾếỀềỂểỄễỆệỈỉỊịỌọỎỏỐốỒồỔổỖỗỘộỚớỜờỞởỠỡỢợỤụỦủỨứỪừỬửỮữỰựỲỳỴỵỶỷỸỹ"

    public static func supportsVietnamese(family: String) -> Bool {
        guard let face = faces(of: family).first(where: { !$0.italic }) ?? faces(of: family).first else { return false }
        return missingCharacters(vietnameseSample, postScriptName: face.postScriptName).isEmpty
    }

    // MARK: Weights

    /// "bold" → 700, "light italic" → (300, italic), "600" → 600. Unknown words mean regular.
    public static func parseWeight(_ s: String) -> (weight: Int, italic: Bool) {
        let lower = s.lowercased()
        let italic = lower.contains("italic") || lower.contains("oblique")
        if let n = Int(lower.filter(\.isNumber)), (1...1000).contains(n) { return (n, italic) }
        return (weight(styleName: lower) ?? 400, italic)
    }

    /// Weight named in a style ("Semibold Italic" → 600), or nil.
    static func weight(styleName s: String) -> Int? {
        let key = s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let table: [(String, Int)] = [
            ("extralight", 200), ("ultralight", 200), ("hairline", 100), ("thin", 100),
            ("semibold", 600), ("demibold", 600), ("extrabold", 800), ("ultrabold", 800),
            ("light", 300), ("medium", 500), ("bold", 700), ("black", 900), ("heavy", 900),
            ("regular", 400), ("normal", 400), ("book", 400), ("roman", 400),
        ]
        return table.first { key.contains($0.0) }?.1
    }

    /// CoreText weight trait (-1…1) to the nearest CSS weight.
    static func weight(trait: Double) -> Int {
        let table: [(Double, Int)] = [(-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500), (0.3, 600),
                                      (0.4, 700), (0.56, 800), (0.62, 900)]
        return table.min { abs($0.0 - trait) < abs($1.0 - trait) }!.1
    }

    /// The system font for a `fontWeight` ("bold", "light italic", "600").
    static func systemFont(_ fontWeight: String, size: CGFloat) -> NSFont {
        let lower = fontWeight.lowercased()
        let italic = lower.contains("italic") || lower.contains("oblique")
        let word = lower.replacingOccurrences(of: "italic", with: "").replacingOccurrences(of: "oblique", with: "")
            .trimmingCharacters(in: .whitespaces)
        let weight: NSFont.Weight
        switch word {
        case "ultralight": weight = .ultraLight
        case "thin": weight = .thin
        case "light": weight = .light
        case "regular", "normal": weight = .regular
        case "": weight = italic ? .regular : .bold
        case "medium": weight = .medium
        case "semibold": weight = .semibold
        case "heavy": weight = .heavy
        case "black": weight = .black
        default: weight = Int(word).map(systemWeight) ?? .bold
        }
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return font }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
    }

    /// NSFont weight for a CSS weight.
    static func systemWeight(_ w: Int) -> NSFont.Weight {
        switch w {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }
}
