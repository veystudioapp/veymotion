import AppKit
import AVFoundation
import Observation
import SwiftUI
import VeyMotionCore

/// Search state for the free-asset browser. Network calls run off the main thread.
@Observable
final class StockBrowserModel {
    var kind: StockKind = .photo
    var query = ""
    var results: [StockItem] = []
    var page = 1
    var isSearching = false
    var canLoadMore = false
    var error: String?
    var importing: Set<String> = []
    var imported: [String: String] = [:]  // ref → library path
    var thumbs: [String: NSImage] = [:]
    /// Ref of the audio result being previewed.
    var playing: String?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var endObserver: Any?
    @ObservationIgnored private var searchToken = 0
    @ObservationIgnored private var loadingThumbs: Set<String> = []
    @ObservationIgnored private let thumbQueue = DispatchQueue(label: "veymotion.stock-thumbs", attributes: .concurrent)

    func search(more: Bool = false) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !(more && isSearching) else { return } // a new search replaces one in flight
        let kind = kind, page = more ? page + 1 : 1
        if !more { results = []; canLoadMore = false }
        searchToken += 1
        let token = searchToken
        isSearching = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try StockSearch.search(q, kind: kind, page: page) }
            DispatchQueue.main.async {
                guard token == self.searchToken else { return }
                self.isSearching = false
                switch outcome {
                case let .success(items):
                    let known = Set(self.results.map(\.ref))
                    self.results += items.filter { !known.contains($0.ref) }
                    self.page = page
                    self.canLoadMore = !items.isEmpty
                    if self.results.isEmpty { self.error = "No results for “\(q)”. Try simpler English keywords." }
                case let .failure(e):
                    self.error = e.localizedDescription
                }
            }
        }
    }

    func thumbnail(_ item: StockItem) -> NSImage? {
        if let t = thumbs[item.ref] { return t }
        if !loadingThumbs.contains(item.ref) {
            loadingThumbs.insert(item.ref)
            thumbQueue.async {
                let cg = StockSearch.loadThumbnail(item)
                DispatchQueue.main.async {
                    if let cg { self.thumbs[item.ref] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
                }
            }
        }
        return nil
    }

    /// Streams an audio result (no download) so it can be auditioned before importing.
    func togglePreview(_ item: StockItem) {
        if playing == item.ref { stopPreview(); return }
        stopPreview()
        guard let url = item.downloadURL else { return }
        let p = AVPlayer(url: url)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem,
                                                             queue: .main) { [weak self] _ in self?.stopPreview() }
        p.play()
        player = p
        playing = item.ref
    }

    func stopPreview() {
        player?.pause()
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playing = nil
    }

    /// Downloads into the asset library, then optionally adds it to the scene (as background music if `asMusic`).
    func importItem(_ item: StockItem, iconColor: String, store: SceneStore, addToScene: Bool, asMusic: Bool = false) {
        func place(_ path: String) {
            guard addToScene else { return }
            if asMusic { store.addMusicLayer(path) } else { store.addFileLayer(path) }
        }
        if let path = imported[item.ref] {
            place(path)
            return
        }
        guard !importing.contains(item.ref) else { return }
        importing.insert(item.ref)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try StockSearch.importItem(item, color: iconColor) }
            DispatchQueue.main.async {
                self.importing.remove(item.ref)
                switch outcome {
                case let .success(asset):
                    self.imported[item.ref] = asset.path
                    AssetLibrary.shared.refresh()
                    store.message = "Added \(asset.name) to Assets"
                        + (item.credit.requiresAttribution ? " — credit required (\(item.credit.license))" : "")
                    place(asset.path)
                case let .failure(e):
                    self.error = e.localizedDescription
                }
            }
        }
    }
}

struct StockBrowserSheet: View {
    @Environment(SceneStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model = StockBrowserModel()
    @State private var iconColor = Color.white
    @State private var hovered: StockItem?
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $model.kind) {
                    ForEach(StockKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(placeholder, text: $model.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { model.search() }
                    if model.isSearching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
                if model.kind == .icon {
                    ColorPicker("Color", selection: $iconColor, supportsOpacity: false)
                        .help("Icon color used when importing")
                }
            }
            .padding(12)
            Divider()

            ScrollView {
                if model.results.isEmpty {
                    emptyState.frame(maxWidth: .infinity).padding(.top, 80)
                } else if model.kind.isAudio {
                    LazyVStack(spacing: 2) {
                        ForEach(model.results) { item in
                            StockAudioRow(item: item, model: model)
                                .onHover { inside in
                                    if inside { hovered = item } else if hovered?.ref == item.ref { hovered = nil }
                                }
                        }
                    }
                    .padding(8)
                    if model.canLoadMore {
                        Button(model.isSearching ? "Loading…" : "Load More") { model.search(more: true) }
                            .disabled(model.isSearching)
                            .padding(.bottom, 14)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: model.kind == .icon ? 84 : 150), spacing: 10)], spacing: 10) {
                        ForEach(model.results) { item in
                            StockCell(item: item, model: model, iconColor: hex(iconColor))
                                .onHover { inside in
                                    if inside { hovered = item } else if hovered?.ref == item.ref { hovered = nil }
                                }
                        }
                    }
                    .padding(12)
                    if model.canLoadMore {
                        Button(model.isSearching ? "Loading…" : "Load More") { model.search(more: true) }
                            .disabled(model.isSearching)
                            .padding(.bottom, 14)
                    }
                }
            }
            .frame(minHeight: 380)

            Divider()
            HStack(spacing: 8) {
                if let e = model.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).lineLimit(2)
                } else if let h = hovered {
                    Text(h.credit.attribution).lineLimit(2).foregroundStyle(.secondary)
                    if h.credit.requiresAttribution {
                        Text("Credit required").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.2)))
                    }
                } else {
                    Text(model.kind.isAudio
                         ? "▶ previews · ⤓ adds to Assets. Music: Jamendo · Sound FX: Freesound (via Openverse, commercial use allowed)."
                         : "Click to add to Assets · ⊕ adds it to the scene. Photos & illustrations: Openverse (commercial use allowed). Icons: Iconify.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .font(.caption)
            .padding(12)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 640)
        .onAppear { searchFocused = true }
        .onDisappear { model.stopPreview() }
        .onChange(of: model.kind) { _, _ in model.stopPreview(); model.search() }
    }

    private var placeholder: String {
        switch model.kind {
        case .photo: return "Search free photos (e.g. city night, coffee, mountain)"
        case .illustration: return "Search illustrations (e.g. rocket, team, map)"
        case .icon: return "Search icons (e.g. rocket, check, chart)"
        case .music: return "Search music by mood or genre (e.g. calm piano, upbeat corporate)"
        case .sound: return "Search sound effects (e.g. whoosh, pop, click, applause)"
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: emptyIcon)
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("Free \(model.kind.title.lowercased()) for your videos").font(.headline)
            Text("Type a few words and press Return.").foregroundStyle(.secondary)
            HStack {
                ForEach(suggestions, id: \.self) { s in
                    Button(s) { model.query = s; model.search() }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private var suggestions: [String] {
        switch model.kind {
        case .photo: return ["city", "nature", "office", "technology", "food"]
        case .illustration: return ["rocket", "people", "map", "science", "animal"]
        case .icon: return ["arrow", "check", "chart", "user", "heart"]
        case .music: return ["upbeat", "calm piano", "cinematic", "lofi", "corporate"]
        case .sound: return ["whoosh", "pop", "click", "ding", "transition"]
        }
    }

    private var emptyIcon: String {
        switch model.kind {
        case .icon: return "star.square.on.square"
        case .music: return "music.note.list"
        case .sound: return "speaker.wave.2"
        default: return "photo.on.rectangle.angled"
        }
    }

    private func hex(_ c: Color) -> String { RGBA(c).hex }
}

private struct StockCell: View {
    @Environment(SceneStore.self) private var store
    let item: StockItem
    let model: StockBrowserModel
    let iconColor: String
    @State private var hovering = false

    var body: some View {
        let isIcon = item.kind == .icon
        let busy = model.importing.contains(item.ref)
        let done = model.imported[item.ref] != nil
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isIcon ? Color(white: 0.16) : Color.primary.opacity(0.06))
                if let img = model.thumbnail(item) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: isIcon ? .fit : .fill)
                        .padding(isIcon ? 18 : 0)
                } else {
                    ProgressView().controlSize(.small)
                }
                if busy {
                    Color.black.opacity(0.35)
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: isIcon ? 84 : 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(done ? Color.green : hovering ? Color.accentColor : .clear, lineWidth: 2))
            .overlay(alignment: .topTrailing) {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).padding(5)
                } else if item.credit.requiresAttribution, !isIcon {
                    Text("CC BY").font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .foregroundStyle(.white)
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering, !busy {
                    Button { model.importItem(item, iconColor: iconColor, store: store, addToScene: true) } label: {
                        Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(.white, Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Add to the scene")
                    .padding(5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.importItem(item, iconColor: iconColor, store: store, addToScene: false) }
            .onHover { hovering = $0 }
            .help("\(item.title)\n\(item.credit.license)\(item.credit.creator.map { " · \($0)" } ?? "")")

            if !isIcon {
                Text(item.title).font(.caption).lineLimit(1)
                Text(item.credit.license).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// One music / sound-effect result: preview, details, license and the ways to use it.
private struct StockAudioRow: View {
    @Environment(SceneStore.self) private var store
    let item: StockItem
    let model: StockBrowserModel
    @State private var hovering = false

    var body: some View {
        let busy = model.importing.contains(item.ref)
        let done = model.imported[item.ref] != nil
        let playing = model.playing == item.ref
        HStack(spacing: 10) {
            Button { model.togglePreview(item) } label: {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(playing ? "Stop preview" : "Preview")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let d = item.duration {
                Text(StockItem.clock(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(item.credit.requiresAttribution ? "CC BY" : "No credit needed")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(item.credit.requiresAttribution ? Color.orange.opacity(0.2) : Color.green.opacity(0.2)))
                .help(item.credit.attribution)
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("In Assets")
                } else {
                    Button { model.importItem(item, iconColor: "", store: store, addToScene: false) } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Add to Assets")
                }
            }
            .frame(width: 20)
            Button(item.kind == .music ? "Use as Background" : "Add at Playhead") {
                model.importItem(item, iconColor: "", store: store, addToScene: true, asMusic: item.kind == .music)
            }
            .controlSize(.small)
            .disabled(busy)
            .help(item.kind == .music
                  ? "Adds it from 0s to the end of the scene, faded in/out and ducked under voice-overs"
                  : "Adds it at the playhead")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(playing ? Color.accentColor.opacity(0.1) : hovering ? Color.primary.opacity(0.05) : .clear))
        .onHover { hovering = $0 }
    }

    private var details: String {
        var parts: [String] = []
        if let c = item.credit.creator, !c.isEmpty { parts.append(c) }
        if !item.genres.isEmpty { parts.append(item.genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
