import AVFoundation
import Foundation
import Observation
import VeyMotionCore

/// Plays the scene's mixed audio in sync with preview playback. Uses the same `AudioMixer` as export.
final class AudioPreview {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isSetUp = false
    private var cache: (signature: String, buffer: AVAudioPCMBuffer)?
    /// Starts are coalesced so fast scrubbing during playback doesn't queue many restarts.
    private var generation = 0

    func play(_ scene: MotionScene, from t: Double) {
        guard AudioMixer.hasAudio(scene) else { stop(); return }
        generation += 1
        let gen = generation
        let signature = Self.signature(scene)
        let cached = cache?.signature == signature ? cache?.buffer : nil
        let requested = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let buffer = cached ?? (try? AudioMixer.render(scene))
            DispatchQueue.main.async {
                guard gen == self.generation, let buffer else { return }
                self.cache = (signature, buffer)
                // The picture kept moving while we mixed; start the sound where the playhead is now.
                self.start(buffer, at: t + Date().timeIntervalSince(requested))
            }
        }
    }

    func stop() {
        generation += 1
        if isSetUp { player.stop() }
    }

    private func start(_ mix: AVAudioPCMBuffer, at t: Double) {
        do {
            if !isSetUp {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: AudioMixer.format)
                isSetUp = true
            }
            if !engine.isRunning { try engine.start() }
        } catch {
            return
        }
        player.stop()
        let frame = Int((t * AudioMixer.sampleRate).rounded())
        guard let slice = AudioMixer.slice(mix, fromFrame: frame) else { return }
        player.scheduleBuffer(slice, at: nil, options: [])
        player.play()
    }

    /// Everything that affects the mix: audio layers and duration.
    private static func signature(_ scene: MotionScene) -> String {
        SceneJSON.string(scene.audioLayers, pretty: false) + "|\(scene.duration)"
    }
}

/// Waveform peaks per file, computed in the background and cached.
@Observable
final class WaveformCache {
    static let shared = WaveformCache()
    private(set) var peaks: [String: [Float]] = [:]
    @ObservationIgnored private var pending = Set<String>()

    func peaks(for path: String) -> [Float]? {
        if let p = peaks[path] { return p }
        if !pending.contains(path) {
            pending.insert(path)
            DispatchQueue.global(qos: .utility).async {
                let result = (try? Waveform.peaks(path: path)) ?? []
                DispatchQueue.main.async {
                    self.peaks[path] = result
                    self.pending.remove(path)
                }
            }
        }
        return nil
    }
}
