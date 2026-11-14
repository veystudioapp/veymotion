import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Free, keyless asset sources:
/// - Openverse (api.openverse.org): openly licensed photos and illustrations. Searches are limited to
///   licenses that allow commercial use and modification (CC0, Public Domain, CC BY, CC BY-SA).
/// - Iconify (api.iconify.design): 200k+ open-source SVG icons (Material, Tabler, Lucide, Phosphor, …).
/// - Openverse audio: music from Jamendo, music loops and sound effects from Freesound, with the same license filter.
/// - ccMixter (ccmixter.org/api/query): remixes under CC BY / CC0, many with a bpm (see `CCMixter`).
/// - Google Fonts: open-source font families (see `GoogleFonts`).
/// - Videos: Pexels and Pixabay through the VeyMotion server, which holds their API keys (see `StockVideoSearch`).
public enum StockKind: String, CaseIterable, Codable, Sendable {
    case photo, illustration, video, icon, music, sound, font

    public var title: String {
        switch self {
        case .photo: return "Photos"
        case .illustration: return "Illustrations"
        case .video: return "Videos"
        case .icon: return "Icons"
        case .music: return "Music"
        case .sound: return "Sound FX"
        case .font: return "Fonts"
        }
    }

    public var isAudio: Bool { self == .music || self == .sound }
}

/// How fast a piece of music feels. Jamendo tags its tracks with a speed; elsewhere it comes from the bpm.
public enum MusicTempo: String, CaseIterable, Codable, Sendable {
    case slow, medium, fast

    public init(bpm: Double) { self = bpm < 95 ? .slow : bpm < 125 ? .medium : .fast }

    /// Jamendo's speed tags (as indexed by Openverse) for this tempo.
    var jamendoTags: [String] {
        switch self {
        case .slow: return ["speed_low", "speed_verylow"]
        case .medium: return ["speed_medium"]
        case .fast: return ["speed_high", "speed_veryhigh"]
        }
    }
}

/// Where music searches look. All are keyless.
public enum MusicSource: String, CaseIterable, Codable, Sendable {
    case jamendo, freesound, ccmixter

    public var title: String {
        switch self {
        case .jamendo: return "Jamendo"
        case .freesound: return "Freesound"
        case .ccmixter: return "ccMixter"
        }
    }

    /// What to expect from it (for agents and tooltips).
    public var note: String {
        switch self {
        case .jamendo: return "full tracks, 2–5 min, tagged with genre, speed and vocal/instrumental"
        case .freesound: return "short music loops and beds, 30 s–2 min, mostly CC0 (no credit)"
        case .ccmixter: return "remixes and instrumentals with a bpm, CC BY"
        }
    }
}

/// Narrows a music search. The default changes nothing.
public struct MusicFilter: Hashable, Sendable {
    /// Leave out tracks known to have vocals (and ask Jamendo for instrumentals only).
    public var instrumental = false
    /// Keep tracks of this tempo; ones whose tempo is unknown are left out.
    public var tempo: MusicTempo?
    /// Leave out tracks shorter than this many seconds.
    public var minDuration: Double?
    /// Search one source instead of all of them.
    public var source: MusicSource?

    public init(instrumental: Bool = false, tempo: MusicTempo? = nil, minDuration: Double? = nil, source: MusicSource? = nil) {
        self.instrumental = instrumental
        self.tempo = tempo
        self.minDuration = minDuration
        self.source = source
    }

    public var isEmpty: Bool { self == MusicFilter() }
}

public struct StockItem: Identifiable, Hashable, Sendable {
    /// "openverse:<uuid>", "pexels:<id>", "ccmixter:<id>" or "iconify:<prefix>:<name>". Pass it to `StockSearch.importItem`.
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
    /// Full-size file for photos/illustrations/audio/video (icon files are built from the ref).
    public var downloadURL: URL?
    /// Videos: the smallest rendition, for hover previews.
    public var previewURL: URL?
    /// Audio and video length in seconds.
    public var duration: Double?
    /// Music genres; for fonts: category, weights and "Vietnamese ✓".
    public var genres: [String] = []
    /// Keywords from the source (Freesound tags describe a sound much better than its title).
    public var tags: [String] = []
    /// Fonts: available styles ("400", "700", "400i"…).
    public var fontStyles: [String] = []
    /// Audio: the catalog it comes from ("Jamendo", "Freesound", "ccMixter").
    public var source = ""
    /// Music: beats per minute, when the source says.
    public var bpm: Double?
    /// Music: from the bpm or the source's speed tag.
    public var tempo: MusicTempo?
    /// Music: true = tagged instrumental, false = has vocals, nil = the source does not say.
    public var instrumental: Bool?

    public var id: String { ref }

    /// One line for agents: "openverse:abc — Title — 1024×768 jpg — CC BY 4.0 (credit required) — by Someone".
    public var summary: String {
        var parts = [ref, title]
        if kind == .font {
            parts.append(genres.joined(separator: ", "))
        } else if kind == .video {
            var s = duration.map { Self.clock($0) + " " } ?? ""
            if let w = width, let h = height { s += "\(w)×\(h) " }
            parts.append(s + fileExtension)
            if !tags.isEmpty { parts.append("tags: " + tags.prefix(8).joined(separator: ", ")) }
        } else if let d = duration {
            parts.append(Self.clock(d) + " " + fileExtension + (genres.isEmpty ? "" : " — " + genres.prefix(3).joined(separator: ", ")))
            if kind == .sound, !tags.isEmpty { parts.append("tags: " + tags.prefix(8).joined(separator: ", ")) }
            if kind == .music, !musicTraits.isEmpty { parts.append(musicTraits.joined(separator: ", ")) }
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

    /// Music: "Jamendo", "instrumental", "fast" / "120 bpm" — whatever is known.
    public var musicTraits: [String] {
        var out: [String] = []
        if !source.isEmpty { out.append(source) }
        if let i = instrumental { out.append(i ? "instrumental" : "vocals") }
        if let bpm { out.append(String(format: "%.0f bpm", bpm)) } else if let tempo { out.append(tempo.rawValue) }
        return out
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
    /// `maxDuration`: audio and video, leave out longer results (sounds default to `defaultSoundMaxDuration`;
    /// 0 = no limit). `orientation`: videos only, landscape / portrait / square (nil = any). `music`: music only.
    public static func search(_ query: String, kind: StockKind, page: Int = 1, vietnamese: Bool = false,
                              maxDuration: Double? = nil, orientation: String? = nil,
                              music: MusicFilter = MusicFilter()) throws -> [StockItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        switch kind {
        case .font: return try GoogleFonts.search(q, page: page, vietnamese: vietnamese)
        case .icon: return try searchIcons(q, page: page)
        case .photo, .illustration: return try searchOpenverse(q, kind: kind, page: page)
        case .video: return try StockVideoSearch.search(q, page: page, orientation: orientation, maxDuration: maxDuration)
        case .music:
            return try searchMusic(q, page: page, maxDuration: maxDuration.flatMap { $0 > 0 ? $0 : nil }, filter: music)
        case .sound:
            let limit = maxDuration ?? defaultSoundMaxDuration
            return try searchSounds(q, page: page, maxDuration: limit > 0 ? limit : nil)
        }
    }

    // MARK: Music

    /// Every source at once (or `filter.source` alone), results taken in turn so no catalog fills the page.
    /// A source that fails is left out; the search fails only when all of them do.
    private static func searchMusic(_ q: String, page: Int, maxDuration: Double?, filter: MusicFilter) throws -> [StockItem] {
        let sources = filter.source.map { [$0] } ?? MusicSource.allCases
        let size = sources.count == 1 ? 20 : 10
        var lists = [[StockItem]](repeating: [], count: sources.count)
        var errors = [Error?](repeating: nil, count: sources.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: sources.count) { i in
            do {
                let found: [StockItem]
                switch sources[i] {
                case .jamendo: found = try searchJamendo(q, page: page, size: size, maxDuration: maxDuration, filter: filter)
                case .freesound: found = try searchFreesoundMusic(q, page: page, size: size, maxDuration: maxDuration, filter: filter)
                case .ccmixter: found = try CCMixter.search(q, page: page, size: size, filter: filter, force: sources.count == 1)
                }
                lock.lock(); lists[i] = found; lock.unlock()
            } catch {
                lock.lock(); errors[i] = error; lock.unlock()
            }
        }
        if !errors.contains(where: { $0 == nil }), let first = errors[0] { throw first }
        return interleave(lists).filter { passes($0, filter: filter, maxDuration: maxDuration) }
    }

    /// [[a1, a2, a3], [b1]] → [a1, b1, a2, a3], without repeats.
    static func interleave(_ lists: [[StockItem]]) -> [StockItem] {
        var out: [StockItem] = []
        var seen = Set<String>()
        for i in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where i < list.count && seen.insert(list[i].ref).inserted { out.append(list[i]) }
        }
        return out
    }

    static func passes(_ item: StockItem, filter: MusicFilter, maxDuration: Double?) -> Bool {
        let d = item.duration ?? 0
        if d < 1 { return false } // Jamendo lists some tracks with no length: their files do not play
        if let m = maxDuration, d > m + 0.05 { return false }
        if let m = filter.minDuration, d < m - 0.05 { return false }
        if filter.instrumental, item.instrumental == false { return false }
        if let t = filter.tempo, item.tempo != t { return false }
        return true
    }

    /// Openverse matches every word of `q` against titles and tags, and Jamendo's tags carry "instrumental" and a
    /// speed, so both filters go into the query (a tempo with two speed tags takes two requests).
    private static func searchJamendo(_ q: String, page: Int, size: Int, maxDuration: Double?, filter: MusicFilter) throws -> [StockItem] {
        var base = q
        if filter.instrumental, !q.lowercased().contains("instrumental") { base += " instrumental" }
        let queries = filter.tempo.map { $0.jamendoTags.map { base + " " + $0 } } ?? [base]
        let per = max(5, size / queries.count)
        return interleave(try queries.map {
            try openverseAudio($0, source: "jamendo", kind: .music, page: page, size: per,
                               minDuration: filter.minDuration, maxDuration: maxDuration)
        })
    }

    /// Words that mark a Freesound upload as music.
    static let musicWords: Set<String> = ["music", "loop", "song", "melody", "soundtrack", "beat", "instrumental", "jingle"]

    /// Freesound also holds music: short loops, beds and jingles, mostly CC0. Asked for by adding "music" to the
    /// query and leaving out clips under 30 s (one-shots) and over 10 min (concert and field recordings).
    private static func searchFreesoundMusic(_ q: String, page: Int, size: Int, maxDuration: Double?, filter: MusicFilter) throws -> [StockItem] {
        let words = Set(q.lowercased().split { !$0.isLetter }.map(String.init))
        let query = words.isDisjoint(with: musicWords) ? q + " music" : q
        return try openverseAudio(query, source: "freesound", kind: .music, page: page, size: size,
                                  minDuration: filter.minDuration ?? 30, maxDuration: maxDuration ?? 600)
    }

    /// A Freesound item looked up by ref: music when it is long enough and tagged as such, else a sound effect.
    static func isFreesoundMusic(_ item: StockItem) -> Bool {
        guard (item.duration ?? 0) >= 30 else { return false }
        let words = Set(item.title.lowercased().split { !$0.isLetter }.map(String.init)).union(item.tags)
        return !words.isDisjoint(with: musicWords)
    }

    /// Instrumental / tempo / bpm from a track's tags ("instrumental", "speed_high", "125bpm", "85-bpm", "male_vocals").
    static func applyMusicTags(_ tags: [String], to item: inout StockItem) {
        // "rap" and "hiphop" are genres here as often as they are voices, and "no-vocals" says the opposite.
        let vocal = tags.contains {
            ($0.contains("vocal") && !$0.hasPrefix("no")) || ["voice", "singing", "singer", "lyrics", "acappella", "spoken_word"].contains($0)
        }
        if tags.contains("instrumental") { item.instrumental = true } else if vocal { item.instrumental = false }
        for tag in tags {
            if tag.hasPrefix("speed_") {
                item.tempo = MusicTempo.allCases.first { $0.jamendoTags.contains(tag) } ?? item.tempo
            } else if item.bpm == nil, tag.contains("bpm") {
                // "bpm_120_125" is ccMixter's range tag: its exact bpm comes from the upload itself.
                let digits = tag.split { !$0.isNumber }
                if digits.count == 1, let v = Double(digits[0]), (40...220).contains(v) { item.bpm = v }
            }
        }
        if item.bpm == nil { item.bpm = bpm(inTitle: item.title) }
        if let bpm = item.bpm { item.tempo = MusicTempo(bpm: bpm) }
    }

    /// Loop makers put the tempo in the name: "Lofi Piano Loop 80 BPM(2).wav" → 80.
    static func bpm(inTitle title: String) -> Double? {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for (i, word) in words.enumerated() {
            var number: Substring?
            if word == "bpm" {
                if i > 0, words[i - 1].allSatisfy(\.isNumber) { number = words[i - 1][...] }
                else if i + 1 < words.count, words[i + 1].allSatisfy(\.isNumber) { number = words[i + 1][...] }
            } else if word.hasSuffix("bpm"), word.dropLast(3).allSatisfy(\.isNumber) {
                number = word.dropLast(3)
            }
            if let number, let v = Double(number), (40...220).contains(v) { return v }
        }
        return nil
    }

    /// Request headers a host insists on. ccMixter serves its audio files only to requests that name one of its
    /// pages as the referrer (the app's player needs this too).
    public static func headers(for url: URL) -> [String: String] {
        guard let host = url.host?.lowercased(), host == "ccmixter.org" || host.hasSuffix(".ccmixter.org") else { return [:] }
        return ["Referer": "https://ccmixter.org/"]
    }

    // MARK: Openverse audio

    /// Words that mark a Freesound result as a background bed rather than a one-shot effect.
    static let bedWords = ["loop", "ambience", "ambiance", "ambient", "atmosphere", "atmos", "soundscape", "field-recording",
                           "field recording", "drone", "music", "song", "melody", "background", "room tone"]

    /// Openverse length buckets (shortest < 30 s, short 30 s–2 min, medium 2–10 min, long > 10 min) that overlap
    /// min…max; nil when that is all of them.
    static func lengthBuckets(min: Double?, max: Double?) -> String? {
        let all: [(name: String, from: Double, to: Double)] = [("shortest", 0, 30), ("short", 30, 120), ("medium", 120, 600),
                                                               ("long", 600, .infinity)]
        let lo = min ?? 0, hi = max ?? .infinity
        let keep = all.filter { $0.to > lo && $0.from < hi }
        return keep.isEmpty || keep.count == all.count ? nil : keep.map(\.name).joined(separator: ",")
    }

    /// One page from one Openverse audio source (Jamendo is all music; Freesound items have no category).
    private static func openverseAudio(_ q: String, source: String, kind: StockKind, page: Int, size: Int = 20,
                                       minDuration: Double? = nil, maxDuration: Double?) throws -> [StockItem] {
        var c = URLComponents(string: "https://api.openverse.org/v1/audio/")!
        var items = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "page", value: String(max(1, page))),
            URLQueryItem(name: "page_size", value: String(size)),
            URLQueryItem(name: "license_type", value: "commercial,modification"),
            URLQueryItem(name: "source", value: source),
        ]
        if let buckets = lengthBuckets(min: minDuration, max: maxDuration) {
            items.append(URLQueryItem(name: "length", value: buckets))
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
        if let m = minDuration { found = found.filter { ($0.duration ?? 0) >= m - 0.05 } }
        return found
    }

    private static func searchSounds(_ q: String, page: Int, maxDuration: Double?) throws -> [StockItem] {
        let found = try openverseAudio(q, source: "freesound", kind: .sound, page: page, maxDuration: maxDuration)
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
        if kind.isAudio {
            switch r["source"] as? String {
            case "jamendo": item.source = MusicSource.jamendo.title
            case "freesound": item.source = MusicSource.freesound.title
            default: break
            }
        }
        if kind == .music { applyMusicTags(item.tags, to: &item) }
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
            guard (obj["source"] as? String) == "freesound" else {
                guard let item = openverseItem(obj, kind: .music) else { throw AssetError.failed("Openverse has no audio \(parts[1])") }
                return item
            }
            // Freesound holds both: a result of a music search comes back as music (and is filed under music/).
            guard let sound = openverseItem(obj, kind: .sound) else { throw AssetError.failed("Openverse has no audio \(parts[1])") }
            return isFreesoundMusic(sound) ? openverseItem(obj, kind: .music) ?? sound : sound
        case "ccmixter" where parts.count == 2:
            return try CCMixter.item(id: parts[1])
        case "googlefonts" where parts.count == 2:
            return GoogleFonts.item(try GoogleFonts.family(named: parts[1]))
        case let source? where StockVideoSearch.refPrefixes.contains(source) && parts.count == 2:
            return try StockVideoSearch.item(source: source, id: parts[1])
        case "iconify" where parts.count == 3:
            let info = try? HTTP.json(URL(string: "https://api.iconify.design/collections?prefixes=\(parts[1])")!)
            return iconItem(prefix: parts[1], name: parts[2], collection: info?[parts[1]] as? [String: Any])
        default:
            throw AssetError.failed("Unknown ref '\(ref)'. Use a ref from search_stock, e.g. openverse:<id>, pexels:<id>, ccmixter:<id> or iconify:mdi:rocket.")
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
        case .video: typeFolder = "video"
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
            asset = try AssetStore.download(url, name: fileName, folder: folder, timeout: item.kind == .video ? 600 : 120)
        }
        if item.kind.isAudio, asset.duration == nil || !AudioFileInfo.isDecodable(asset.path) {
            _ = try? AssetStore.trash(asset.path)
            throw AssetError.failed("The downloaded file for '\(item.title)' is not playable audio. Try another result.")
        }
        if item.kind == .video, asset.kind != .video {
            _ = try? AssetStore.trash(asset.path)
            throw AssetError.failed("The downloaded file for '\(item.title)' is not a video. Try another result.")
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
        guard item.kind != .video, let original = item.downloadURL, item.fileExtension == "svg" || pixels <= 1_500_000,
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

// MARK: - ccMixter

/// ccMixter (https://ccmixter.org): a remix community whose uploads are Creative Commons. Its query API needs no
/// key. Only CC BY and CC0 uploads are kept (most of the catalog is non-commercial), and a cappellas and
/// sample packs are skipped. The site answers 502 at times, so after a failure it is left alone for a few minutes.
enum CCMixter {
    static let refPrefix = "ccmixter:"
    private static let lock = NSLock()
    private static var failedAt: Date?
    private static let pause: TimeInterval = 300

    /// Blocking. `force` asks even right after a failure (when ccMixter is the only source searched).
    static func search(_ q: String, page: Int, size: Int, filter: MusicFilter, force: Bool = false) throws -> [StockItem] {
        // The tempo is checked here, from each upload's bpm: ask for more so a page is not left nearly empty
        // (an upload is 5–7 KB of JSON, hence the cap).
        let limit = filter.tempo == nil ? size : min(size * 2, 20)
        var query = [
            URLQueryItem(name: "search", value: q),
            URLQueryItem(name: "search_type", value: "all"),
            URLQueryItem(name: "lic", value: "by,zero"),
            URLQueryItem(name: "sort", value: "rank"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String((max(1, page) - 1) * limit)),
        ]
        if filter.instrumental { query.append(URLQueryItem(name: "tags", value: "instrumental")) }
        return try call(query, force: force).compactMap(item(from:))
    }

    /// Looks up "ccmixter:<id>". Blocking.
    static func item(id: String) throws -> StockItem {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { throw AssetError.failed("Bad ccMixter ref \(refPrefix)\(id)") }
        guard let found = try call([URLQueryItem(name: "ids", value: id)], force: true).compactMap(item(from:)).first else {
            throw AssetError.failed("ccMixter has no track \(id) under a license that allows commercial use")
        }
        return found
    }

    private static func call(_ query: [URLQueryItem], force: Bool) throws -> [[String: Any]] {
        lock.lock()
        let recent = failedAt.map { Date().timeIntervalSince($0) < pause } ?? false
        lock.unlock()
        if recent, !force { throw AssetError.failed("ccMixter did not answer a moment ago; it is skipped for a few minutes.") }
        var c = URLComponents(string: "https://ccmixter.org/api/query")!
        c.queryItems = [URLQueryItem(name: "f", value: "json")] + query
        do {
            let data = try HTTP.get(c.url!, timeout: 10)
            guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw AssetError.failed("Unexpected response from ccmixter.org")
            }
            lock.lock(); failedAt = nil; lock.unlock()
            return list
        } catch {
            lock.lock(); failedAt = Date(); lock.unlock()
            throw error
        }
    }

    /// One upload → StockItem; nil when its license rules it out or it has no MP3.
    static func item(from r: [String: Any]) -> StockItem? {
        guard let id = (r["upload_id"] as? NSNumber)?.stringValue ?? (r["upload_id"] as? String),
              let license = license(r["license_url"] as? String ?? "") else { return nil }
        let extra = r["upload_extra"] as? [String: Any] ?? [:]
        if extra["nsfw"] as? Bool == true { return nil }
        let uploadKind = Set((extra["ccud"] as? String ?? "").split(separator: ",").map(String.init))
        if uploadKind.contains("acappella") || uploadKind.contains("sample") { return nil }
        let files = r["files"] as? [[String: Any]] ?? []
        guard let file = files.first(where: { ($0["file_format_info"] as? [String: Any])?["default-ext"] as? String == "mp3" }),
              let download = (file["download_url"] as? String).flatMap(URL.init(string:)) else { return nil }

        let title = (r["upload_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
        let creator = (r["user_real_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? r["user_name"] as? String
        let page = r["file_page_url"] as? String
        let featuring = (extra["featuring"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let ref = refPrefix + id
        var attribution = "\"\(title)\"\(creator.map { " by \($0)" } ?? "")\(featuring.map { " (featuring \($0))" } ?? "")"
            + " is licensed under \(license.name)."
        if let page { attribution += " " + page }
        let credit = AssetCredit(title: title, creator: creator, license: license.name, licenseURL: r["license_url"] as? String,
                                 sourceURL: page, attribution: attribution, requiresAttribution: license.credit, ref: ref)
        var item = StockItem(ref: ref, kind: .music, title: title, thumbnailURL: nil, fileExtension: "mp3", credit: credit)
        item.downloadURL = download
        item.source = MusicSource.ccmixter.title
        item.duration = ((file["file_format_info"] as? [String: Any])?["ps"] as? String).flatMap(seconds)
        let tags = (extra["usertags"] as? String ?? "").lowercased().split(separator: ",").map(String.init)
        item.tags = tags
        // A number, or "" when the uploader gave none.
        item.bpm = ((extra["bpm"] as? NSNumber)?.doubleValue ?? (extra["bpm"] as? String).flatMap(Double.init))
            .flatMap { (40...220).contains($0) ? $0 : nil }
        StockSearch.applyMusicTags(tags, to: &item)
        item.genres = tags.filter { $0 != "instrumental" && !$0.contains("vocal") && !$0.contains("bpm") }
            .prefix(4).map { $0.replacingOccurrences(of: "_", with: " ") }
        return item
    }

    /// CC BY, CC BY-SA and CC0 allow commercial use and changes; everything else on ccMixter (NC, ND, Sampling) does not.
    static func license(_ url: String) -> (name: String, credit: Bool)? {
        let parts = url.lowercased().split(separator: "/").map(String.init)
        if parts.contains("zero") { return ("CC0 1.0 (public domain)", false) }
        guard let i = parts.firstIndex(where: { $0 == "by" || $0 == "by-sa" }) else { return nil }
        let version = i + 1 < parts.count && parts[i + 1].first?.isNumber == true ? " " + parts[i + 1] : ""
        return ("CC \(parts[i].uppercased())\(version)", true)
    }

    /// "3:26" → 206, "1:02:03" → 3723.
    static func seconds(_ clock: String) -> Double? {
        let parts = clock.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(nil) else { return nil }
        return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
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
        r.setValue("VeyMotion/\(AppVersion.marketing) (macOS motion graphics editor)", forHTTPHeaderField: "User-Agent")
        for (field, value) in StockSearch.headers(for: url) { r.setValue(value, forHTTPHeaderField: field) }
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
