import AppKit
import Foundation
import Observation
import SwiftUI
import VeyMotionCore

/// RAM preview, After Effects style: canvas frames at the playback resolution, kept for one scene revision.
/// Frames the canvas renders are kept, and while the scene is unchanged for a moment background workers render
/// the rest (from the playhead to the end, then from the start; while playing, ahead of the playhead as it
/// moves: `follow`), so playback runs from memory instead of
/// rendering each frame in 1/fps. A scene edit drops only the frames it can have changed
/// (`MotionScene.change(since:)`); a canvas resize or an input change (asset file, audio analysis) drops them all,
/// and memory pressure purges them.
@Observable
final class FrameCache {
    static let shared = FrameCache()

    /// What cached frames were rendered from: a scene revision at one pixel width (= the playback scale).
    /// `generation` changes when something outside the scene changes (an asset file, an audio analysis).
    struct Key: Equatable {
        var revision: Int
        var pixelWidth: Int
        var generation: Int
    }

    /// Cached frame numbers, for the green strip over the timeline (refreshed a few times a second).
    private(set) var cachedFrames = IndexSet()
    /// Frame rate of the cached scene, to place `cachedFrames` on a time axis.
    private(set) var fps = 30

    /// Render the remaining frames in the background while the scene is idle (Playback menu).
    var fillsWhenIdle = UserDefaults.standard.object(forKey: "cacheFramesWhenIdle") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(fillsWhenIdle, forKey: "cacheFramesWhenIdle")
            restartFill()
        }
    }
    /// Set while exporting, so background caching doesn't slow the export down.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { restartFill() } }
    }

    // Guarded by `lock` (workers and the preview queue read and insert frames).
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var _key: Key?
    @ObservationIgnored private var frames: [Int: CGImage] = [:]
    @ObservationIgnored private var bytes = 0
    @ObservationIgnored private var job: FillJob?
    @ObservationIgnored private var renderers: [FrameRenderer] = []
    @ObservationIgnored private var rendererGeneration = 0
    @ObservationIgnored private var publishPending = false
    /// How long a worker takes per frame (moving average), to aim ahead of the playhead.
    @ObservationIgnored private var renderSeconds = 0.05

    // Main thread only.
    @ObservationIgnored private var scene: MotionScene?
    @ObservationIgnored private var playhead: Double = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var idleWork: DispatchWorkItem?
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?

    /// A quarter of the machine's memory, at most 4 GB.
    @ObservationIgnored private let budget = Int(min(ProcessInfo.processInfo.physicalMemory / 4, 4 << 30))
    private static let idleDelay = 0.5
    private static var workerCount: Int { min(max(ProcessInfo.processInfo.activeProcessorCount - 2, 1), 6) }

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in self?.purge() }
        source.resume()
        pressureSource = source
    }

    /// The key frames are currently cached under; nil after a purge until the canvas sets a source again.
    var key: Key? { lock.withLock { _key } }

    // MARK: - Frames

    /// The frame number of time `t`, or nil when `t` is not on the frame grid (only whole frames are cached).
    static func frame(at t: Double, fps: Int) -> Int? {
        let f = t * Double(max(fps, 1))
        let rounded = f.rounded()
        return abs(f - rounded) < 1e-6 ? Int(rounded) : nil
    }

    /// Number of frames playback shows (times 0, 1/fps, … before the end).
    static func frameCount(_ scene: MotionScene) -> Int {
        max(Int((scene.duration * Double(max(scene.fps, 1)) - 1e-6).rounded(.up)), 0)
    }

    /// Pixel width of a frame rendered at `scale` (as `FrameRenderer.makeImage` computes it).
    static func pixelWidth(_ scene: MotionScene, scale: Double) -> Int {
        max(1, Int((Double(scene.width) * scale).rounded()))
    }

    /// The cached frame at `t`, if it was rendered under `key`. Any thread.
    func image(at t: Double, fps: Int, key: Key) -> CGImage? {
        guard let f = Self.frame(at: t, fps: fps) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return _key == key ? frames[f] : nil
    }

    /// Keeps a frame rendered at `t` under `key`. Ignored when the key is stale, the image is another size or the
    /// cache is full. Any thread.
    func insert(_ image: CGImage, at t: Double, fps: Int, key: Key) {
        guard let f = Self.frame(at: t, fps: fps) else { return }
        insert(image, frame: f, key: key)
    }

    private func insert(_ image: CGImage, frame f: Int, key: Key) {
        guard image.width == key.pixelWidth else { return }
        let size = image.bytesPerRow * image.height
        lock.lock()
        guard _key == key, frames[f] == nil, bytes + size <= budget else { lock.unlock(); return }
        frames[f] = image
        bytes += size
        let schedule = !publishPending
        publishPending = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.publish() }
        }
    }

    private func publish() {
        lock.lock()
        publishPending = false
        let set = IndexSet(frames.keys)
        lock.unlock()
        if set != cachedFrames { cachedFrames = set }
    }

    // MARK: - Source

    /// Main thread. Called by the canvas whenever the scene or the playback size changes: a new key drops the
    /// cached frames the edit can have changed (all of them for another size) and, after a short idle delay,
    /// starts filling from `playhead`.
    func setSource(_ scene: MotionScene, revision: Int, pixelWidth: Int, playhead: Double) {
        let newKey = Key(revision: revision, pixelWidth: pixelWidth, generation: generation)
        let previous = self.scene
        self.scene = scene
        guard newKey != key else { return }
        self.playhead = playhead
        if fps != scene.fps { fps = scene.fps }
        // An edit keeps the frames it cannot have changed (most agent edits touch a layer or two).
        if let previous, let old = key, old.pixelWidth == pixelWidth, old.generation == generation {
            reset(to: newKey, dropping: scene.change(since: previous), fps: scene.fps)
        } else {
            reset(to: newKey)
        }
    }

    /// Main thread. Something the frames depend on changed outside the scene (an asset file, an audio analysis).
    func invalidate() {
        generation += 1
        guard var k = key else { return }
        k.generation = generation
        reset(to: k)
    }

    /// Main thread. Frees every frame (Playback menu, memory pressure). Playing caches frames again, but the
    /// background fill waits for the next scene change. With `dropRenderers` (another document) the workers'
    /// image and video caches go too.
    func purge(dropRenderers: Bool = false) {
        reset(to: key, fill: false)
        if dropRenderers {
            lock.withLock {
                renderers.removeAll()
                rendererGeneration += 1
            }
        }
    }

    /// Re-keys the cache, keeping the frames outside `change` (frame numbers at `fps`).
    private func reset(to newKey: Key?, dropping change: SceneChange = .all, fps: Int = 1, fill: Bool = true) {
        idleWork?.cancel()
        idleWork = nil
        lock.lock()
        job?.cancelled = true
        job = nil
        _key = newKey
        if change == .all {
            frames.removeAll()
            bytes = 0
        } else {
            let rate = Double(max(fps, 1))
            for (f, img) in frames where change.contains(Double(f) / rate) {
                frames[f] = nil
                bytes -= img.bytesPerRow * img.height
            }
        }
        let kept = IndexSet(frames.keys)
        lock.unlock()
        if cachedFrames != kept { cachedFrames = kept }
        if fill, newKey != nil { scheduleFill() }
    }

    // MARK: - Background fill

    /// Workers take the first missing frame from `aim` on (wrapping to the start), so moving `aim` redirects them.
    private final class FillJob {
        let count: Int
        var aim: Int              // guarded by FrameCache.lock
        /// Frames a worker took (rendering or done): never taken twice, so one that fails to render is not retried.
        var taken = Set<Int>()    // guarded by FrameCache.lock
        var cancelled = false     // guarded by FrameCache.lock
        init(count: Int, aim: Int) { self.count = count; self.aim = aim }
    }

    private func restartFill() {
        idleWork?.cancel()
        idleWork = nil
        lock.withLock {
            job?.cancelled = true
            job = nil
        }
        scheduleFill()
    }

    private func scheduleFill() {
        guard fillsWhenIdle, !isSuspended else { return }
        let work = DispatchWorkItem { [weak self] in self?.startFill() }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: work)
    }

    private func startFill() {
        idleWork = nil
        guard fillsWhenIdle, !isSuspended, let scene, let key else { return }
        let count = Self.frameCount(scene)
        guard count > 0, scene.width > 0 else { return }
        let start = min(max(Self.frame(at: playhead, fps: scene.fps) ?? Int(playhead * Double(scene.fps)), 0), count - 1)
        let job = FillJob(count: count, aim: start)
        lock.withLock {
            self.job?.cancelled = true
            self.job = job
        }
        let scale = Double(key.pixelWidth) / Double(scene.width)
        let frameBytes = key.pixelWidth * max(1, Int((Double(scene.height) * scale).rounded())) * 4
        let fps = Double(max(scene.fps, 1))
        for _ in 0..<Self.workerCount {
            DispatchQueue.global(qos: .utility).async { [self] in
                let (renderer, gen) = takeRenderer()
                defer { returnRenderer(renderer, generation: gen) }
                while let f = nextFrame(of: job, frameBytes: frameBytes) {
                    let began = Date()
                    autoreleasepool {
                        // Off the main thread and outside `withoutWaiting`, so audio reactions wait for their
                        // analysis: cached frames are final.
                        if let img = renderer.makeImage(scene, at: Double(f) / fps, scale: scale) {
                            insert(img, frame: f, key: key)
                        }
                    }
                    let took = Date().timeIntervalSince(began)
                    lock.withLock { renderSeconds += (took - renderSeconds) * 0.2 }
                }
            }
        }
    }

    private func nextFrame(of job: FillJob, frameBytes: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !job.cancelled, bytes + frameBytes <= budget else { return nil }
        for i in 0..<job.count {
            let f = (job.aim + i) % job.count
            if frames[f] == nil, job.taken.insert(f).inserted {
                job.aim = (f + 1) % job.count
                return f
            }
        }
        return nil
    }

    /// Main thread, whenever the canvas shows another time. Playing, a frame missing at the playhead means the
    /// workers are behind it: they are sent ahead by as many frames as one of them takes to render one, so what
    /// they render next is ready when playback gets there (and a fill still waiting for the scene to settle starts
    /// now). Paused, they start from the frame looked at.
    func follow(_ t: Double, playing: Bool) {
        guard let scene else { return }
        let count = Self.frameCount(scene)
        guard count > 0 else { return }
        let p = min(max(Self.frame(at: t, fps: scene.fps) ?? Int(t * Double(max(scene.fps, 1))), 0), count - 1)
        playhead = t
        if playing, idleWork != nil {
            idleWork?.cancel()
            startFill()
        }
        lock.lock(); defer { lock.unlock() }
        guard let job, !job.cancelled, frames[p] == nil else { return }
        let lead = playing ? Int((renderSeconds * Double(max(scene.fps, 1))).rounded(.up)) + 1 : 0
        job.aim = (p + lead) % count
    }

    /// Workers reuse renderers so decoded images and open video decoders survive edits.
    private func takeRenderer() -> (FrameRenderer, Int) {
        lock.lock(); defer { lock.unlock() }
        let r = renderers.popLast() ?? FrameRenderer()
        r.motionBlurSamples = 8
        r.motionBlurMaxSamples = 32
        r.modelSupersampling = 2 // frames at playback size
        return (r, rendererGeneration)
    }

    private func returnRenderer(_ r: FrameRenderer, generation gen: Int) {
        lock.withLock {
            if gen == rendererGeneration { renderers.append(r) }
        }
    }
}

/// Green marks over the frames held in the RAM preview cache. Time `t` is drawn at `t * pointsPerSecond - offset`.
struct CachedFramesStrip: View {
    let pointsPerSecond: Double
    var offset: Double = 0
    private let cache = FrameCache.shared

    var body: some View {
        let frames = cache.cachedFrames
        let fps = Double(max(cache.fps, 1))
        let pps = pointsPerSecond, offset = offset
        Canvas { ctx, size in
            for r in frames.rangeView {
                let x0 = Double(r.lowerBound) / fps * pps - offset
                let x1 = Double(r.upperBound) / fps * pps - offset
                guard x1 > 0, x0 < Double(size.width) else { continue }
                ctx.fill(Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)),
                         with: .color(.green.opacity(0.75)))
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
