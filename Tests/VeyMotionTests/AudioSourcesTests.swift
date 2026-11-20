import Foundation
import Testing
@testable import VeyMotionCore
@testable import VeyMotionMCP

@Suite struct AudioSourcesTests {
    /// One upload as ccmixter.org/api/query returns it (trimmed).
    private func upload(license: String = "http://creativecommons.org/licenses/by/3.0/", ccud: String = "media,remix,bpm_080_085",
                        usertags: String = "instrumental,piano,music_for_film", bpm: Any = 80) -> [String: Any] {
        [
            "upload_id": 71077, "upload_name": "Lost Roamin'", "user_name": "speck", "user_real_name": "Speck",
            "file_page_url": "https://ccmixter.org/files/speck/71077", "license_url": license,
            "upload_extra": ["usertags": usertags, "ccud": ccud, "bpm": bpm, "featuring": "mwic, airtone", "nsfw": false],
            "files": [
                ["file_format_info": ["default-ext": "zip"], "download_url": "https://ccmixter.org/content/speck/stems.zip"],
                ["file_format_info": ["default-ext": "mp3", "ps": "3:26"],
                 "download_url": "https://ccmixter.org/content/speck/speck_-_Lost_Roamin_1.mp3"],
            ],
        ]
    }

    @Test func ccMixterUploadBecomesAMusicItem() throws {
        let item = try #require(CCMixter.item(from: upload()))
        #expect(item.ref == "ccmixter:71077")
        #expect(item.kind == .music)
        #expect(item.duration == 206)
        #expect(item.bpm == 80)
        #expect(item.tempo == .slow)
        #expect(item.instrumental == true)
        #expect(item.downloadURL?.pathExtension == "mp3")
        #expect(item.genres == ["piano", "music for film"])
        #expect(item.credit.license == "CC BY 3.0")
        #expect(item.credit.requiresAttribution)
        #expect(item.credit.attribution.contains("featuring mwic, airtone"))
        #expect(item.summary.contains("ccMixter, instrumental, 80 bpm"))
    }

    @Test func ccMixterKeepsOnlyLicensesThatAllowCommercialUse() {
        #expect(CCMixter.item(from: upload(license: "http://creativecommons.org/licenses/by-nc/3.0/")) == nil)
        #expect(CCMixter.item(from: upload(license: "http://creativecommons.org/licenses/sampling+/1.0/")) == nil)
        let zero = CCMixter.item(from: upload(license: "http://creativecommons.org/publicdomain/zero/1.0/"))
        #expect(zero?.credit.requiresAttribution == false)
        // A cappellas and sample packs are not background music.
        #expect(CCMixter.item(from: upload(ccud: "acappella,media")) == nil)
        #expect(CCMixter.item(from: upload(ccud: "sample,media")) == nil)
        // The site sends an empty string where a bpm is unknown.
        let unknown = CCMixter.item(from: upload(usertags: "female_vocals,pop", bpm: ""))
        #expect(unknown?.bpm == nil)
        #expect(unknown?.tempo == nil)
        #expect(unknown?.instrumental == false)
    }

    @Test func tagsGiveTempoAndVocals() {
        func traits(_ tags: [String]) -> StockItem {
            var item = StockItem(ref: "x", kind: .music, title: "x", thumbnailURL: nil, fileExtension: "mp3",
                                 credit: AssetCredit(title: "x", creator: nil, license: "CC0", licenseURL: nil, sourceURL: nil,
                                                     attribution: "", requiresAttribution: false, ref: "x"))
            StockSearch.applyMusicTags(tags, to: &item)
            return item
        }
        #expect(traits(["instrumental", "speed_high"]).tempo == .fast)
        #expect(traits(["instrumental", "speed_high"]).instrumental == true)
        #expect(traits(["vocal", "male", "speed_verylow"]).tempo == .slow)
        #expect(traits(["vocal", "male"]).instrumental == false)
        #expect(traits(["loop", "125bpm"]).bpm == 125)
        #expect(traits(["loop", "125bpm"]).tempo == .fast)
        #expect(traits(["85-bpm"]).tempo == .slow)
        #expect(StockSearch.bpm(inTitle: "Lofi Piano Loop 80 BPM(2).wav") == 80)
        #expect(StockSearch.bpm(inTitle: "Upbeat loop 125bpm") == 125)
        #expect(StockSearch.bpm(inTitle: "BPM 2000 remix") == nil)
        #expect(StockSearch.headers(for: URL(string: "https://ccmixter.org/content/a/b.mp3")!)["Referer"] != nil)
        #expect(StockSearch.headers(for: URL(string: "https://cdn.freesound.org/previews/1.mp3")!).isEmpty)
        // A bpm range, a genre and "no vocals" say nothing certain.
        #expect(traits(["bpm_120_125", "rap", "no-vocals"]).bpm == nil)
        #expect(traits(["bpm_120_125", "rap", "no-vocals"]).instrumental == nil)
    }

    @Test func musicFiltersDropWhatDoesNotFit() {
        var item = StockItem(ref: "x", kind: .music, title: "x", thumbnailURL: nil, fileExtension: "mp3",
                             credit: AssetCredit(title: "x", creator: nil, license: "CC0", licenseURL: nil, sourceURL: nil,
                                                 attribution: "", requiresAttribution: false, ref: "x"))
        item.duration = 90
        #expect(StockSearch.passes(item, filter: MusicFilter(), maxDuration: nil))
        #expect(!StockSearch.passes(item, filter: MusicFilter(minDuration: 120), maxDuration: nil))
        #expect(!StockSearch.passes(item, filter: MusicFilter(), maxDuration: 60))
        // Unknown vocals pass an instrumental search; an unknown tempo does not pass a tempo search.
        #expect(StockSearch.passes(item, filter: MusicFilter(instrumental: true), maxDuration: nil))
        #expect(!StockSearch.passes(item, filter: MusicFilter(tempo: .fast), maxDuration: nil))
        item.instrumental = false
        #expect(!StockSearch.passes(item, filter: MusicFilter(instrumental: true), maxDuration: nil))
        item.duration = 0
        #expect(!StockSearch.passes(item, filter: MusicFilter(), maxDuration: nil))
    }

    @Test func lengthBucketsCoverTheAskedRange() {
        #expect(StockSearch.lengthBuckets(min: nil, max: nil) == nil)
        #expect(StockSearch.lengthBuckets(min: nil, max: 10) == "shortest")
        #expect(StockSearch.lengthBuckets(min: nil, max: 120) == "shortest,short")
        #expect(StockSearch.lengthBuckets(min: 30, max: 600) == "short,medium")
        #expect(StockSearch.lengthBuckets(min: 60, max: nil) == "short,medium,long")
    }

    @Test func everySynthKindRendersASoundWithItsHitInside() {
        for kind in SynthKind.allCases {
            let out = SoundSynth.render(SynthSettings(kind: kind))
            let length = Double(out.left.count) / SoundSynth.sampleRate
            let peak = max(out.left.map(abs).max() ?? 0, out.right.map(abs).max() ?? 0)
            #expect(out.left.count == out.right.count, "\(kind)")
            #expect(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite), "\(kind)")
            #expect(peak > 0.4 && peak <= 0.9, "\(kind) peaks at \(peak)")
            #expect(length > 0.03 && length < kind.defaultDuration + 2.5, "\(kind) lasts \(length)")
            let hit = out.hits.first ?? -1
            #expect(hit >= 0 && hit <= length, "\(kind) hit \(hit) outside 0…\(length)")
            #expect(SoundSynth.render(SynthSettings(kind: kind)).left == out.left, "\(kind) is not deterministic")
            #expect(!kind.use.isEmpty)
        }
    }

    @Test func buildUpsEndOnTheirHitAndRepeatsSpreadOut() {
        let swell = SoundSynth.render(SynthSettings(kind: .swell, duration: 2))
        #expect(swell.hits == [2])
        // Loudest just before the hit, quiet at the start.
        let rate = SoundSynth.sampleRate
        func level(_ from: Double, _ to: Double) -> Float { swell.left[Int(from * rate)..<Int(to * rate)].map(abs).max() ?? 0 }
        #expect(level(1.8, 2) > 8 * level(0, 0.4))

        let beats = SoundSynth.render(SynthSettings(kind: .heartbeat, count: 4))
        #expect(beats.hits.count == 4)
        #expect(abs((beats.hits[1] - beats.hits[0]) - 0.85) < 0.001)
        let countdown = SoundSynth.render(SynthSettings(kind: .beep, duration: 3, count: 3))
        #expect(countdown.hits.map { ($0 * 10).rounded() / 10 } == [0, 1, 2])
    }

    @Test func theToolSchemaListsEverySynthKindAndMusicFilter() throws {
        let tools = try #require(try JSONSerialization.jsonObject(with: Data(Docs.toolsJSON.utf8)) as? [[String: Any]])
        func properties(_ name: String) throws -> [String: [String: Any]] {
            let tool = try #require(tools.first { $0["name"] as? String == name })
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            return try #require(schema["properties"] as? [String: [String: Any]])
        }
        let kinds = try #require(try properties("generate_sfx")["kind"]?["enum"] as? [String])
        #expect(kinds == SynthKind.allCases.map(\.rawValue))
        let search = try properties("search_stock")
        #expect(search["tempo"]?["enum"] as? [String] == MusicTempo.allCases.map(\.rawValue))
        #expect(search["source"]?["enum"] as? [String] == MusicSource.allCases.map(\.rawValue))
        #expect(search["instrumental"] != nil && search["minDuration"] != nil)
        #expect(try properties("generate_music")["style"]?["enum"] as? [String] == MusicStyle.allCases.map(\.rawValue))
    }

    @Test func musicSitsOnItsGrid() {
        let s = MusicSettings(style: .driving, bpm: 120, duration: 10, key: "F#m", accents: [4.04], variant: 1)
        let a = MusicSynth.render(s)
        #expect(a.left == MusicSynth.render(s).left)                  // same settings, same file
        #expect(a.result.bars == [0, 2, 4, 6, 8])
        #expect(a.result.accents == [4])                              // moved to the nearest 8th
        #expect(a.result.ending == 8)
        #expect(abs(a.result.duration - 10) < 0.001)
        let rate = SoundSynth.sampleRate
        func level(_ from: Double, _ to: Double) -> Float {
            let part = a.left[Int(from * rate)..<Int(to * rate)]
            return part.map(abs).reduce(0, +) / Float(part.count)
        }
        print("music levels: gap \(level(3.55, 3.98)) hit \(level(4, 4.4)) groove \(level(2.5, 2.9))")
        #expect(level(4, 4.4) > level(3.55, 3.98))                    // the drums drop out before the hit

        // A loop keeps whole bars: 8 s at ~100 bpm becomes 3 bars at 90 bpm, with no ending.
        let loop = MusicSynth.render(MusicSettings(bpm: 100, duration: 8, loop: true)).result
        #expect(abs(loop.bpm - 90) < 1e-9)
        #expect(loop.ending == nil && loop.bars.count == 3)
        #expect(MusicSynth.parseKey("Bb minor") == (10, true) && MusicSynth.parseKey("C") == (0, false))
    }
}
