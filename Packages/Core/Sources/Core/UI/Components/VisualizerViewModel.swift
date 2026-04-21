import SwiftUI
import Combine
import MediaPlayer
import QuartzCore

@MainActor
public final class VisualizerViewModel: NSObject, ObservableObject {
    @Published public private(set) var magnitudes: [Float]
    @Published public private(set) var bass: Float = 0
    @Published public private(set) var mid: Float = 0
    @Published public private(set) var treble: Float = 0
    @Published public private(set) var beatPulse: Float = 0
    @Published public private(set) var currentBPM: Double = 0
    @Published public private(set) var isBeatDetected: Bool = false
    @Published public private(set) var metadataFeatures: TrackFeatures = TrackFeatures()
    @Published public var errorMessage: String?

    public let binCount: Int
    public var fallOffPerTick: Float = 0.04
    public var attackFactor: Float = 0.65

    private let conductor: AudioConductor
    private var displayLink: CADisplayLink?
    private var metadataService: TrackMetadataService?
    private var metadataTask: Task<Void, Never>?

    public init(conductor: AudioConductor,
                binCount: Int = 32,
                metadataService: TrackMetadataService? = nil) {
        self.conductor = conductor
        self.binCount = binCount
        self.magnitudes = Array(repeating: 0, count: binCount)
        self.metadataService = metadataService
        super.init()
        startDisplayLoop()
    }

    /// Best-available BPM: real-time onset detection wins once it stabilizes; metadata fallback otherwise.
    public var effectiveBPM: Double {
        if currentBPM > 0 { return currentBPM }
        return metadataFeatures.tempoBPM ?? 0
    }

    public var bpmSourceLabel: String {
        if currentBPM > 0 { return "live" }
        if metadataFeatures.tempoBPM != nil { return "metadata" }
        return "—"
    }

    deinit {
        displayLink?.invalidate()
        metadataTask?.cancel()
    }

    public func play(item: MPMediaItem) async {
        let source: TrackSource = item.beatsPerMinute > 0
            ? .appleWithBPM(Double(item.beatsPerMinute))
            : .appleUnknown
        resetMetadata()

        do {
            try await conductor.load(item: item)
            conductor.play()
            errorMessage = nil
            fetchMetadata(for: source)
        } catch {
            errorMessage = Self.verboseMessage(for: error)
            print("[VisualizerViewModel] load error: \(error as NSError)\n"
                  + "userInfo: \((error as NSError).userInfo)")
        }
    }

    public func play(remoteURL: URL,
                     title: String?,
                     artist: String?,
                     durationSec: TimeInterval = 0,
                     source: TrackSource = .unknown) async {
        resetMetadata()
        do {
            try await conductor.load(remoteURL: remoteURL,
                                     title: title,
                                     artist: artist,
                                     durationSec: durationSec)
            conductor.play()
            errorMessage = nil
            fetchMetadata(for: source)
        } catch {
            errorMessage = Self.verboseMessage(for: error)
            print("[VisualizerViewModel] remote load error: \(error as NSError)")
        }
    }

    private func resetMetadata() {
        metadataTask?.cancel()
        metadataTask = nil
        metadataFeatures = TrackFeatures()
    }

    private func fetchMetadata(for source: TrackSource) {
        guard let service = metadataService, source != .unknown else { return }
        metadataTask = Task { [weak self] in
            guard let self else { return }
            let features = await service.features(for: source)
            if Task.isCancelled { return }
            await MainActor.run {
                self.metadataFeatures = features
            }
        }
    }

    private static func verboseMessage(for error: Error) -> String {
        let ns = error as NSError
        var parts: [String] = ["\(ns.domain) (\(ns.code))"]
        if let reason = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String {
            parts.append(reason)
        } else if !ns.localizedDescription.isEmpty {
            parts.append(ns.localizedDescription)
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("↳ \(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)")
        }
        return parts.joined(separator: "\n")
    }

    public func togglePlayPause() {
        conductor.isPlaying ? conductor.pause() : conductor.play()
    }

    public func stop() { conductor.stop() }

    public func seek(to seconds: Double) { conductor.seek(to: seconds) }
    public func rewind(by seconds: Double = 10) { conductor.rewind(by: seconds) }
    public func fastForward(by seconds: Double = 10) { conductor.fastForward(by: seconds) }

    public var isPlaying: Bool { conductor.isPlaying }
    public var positionSec: Double { conductor.positionSec }
    public var durationSec: Double { conductor.durationSec }
    public var mode: PlaybackMode { conductor.mode }
    public var currentTitle: String? { conductor.currentTitle }
    public var currentArtist: String? { conductor.currentArtist }

    private func startDisplayLoop() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                        maximum: 120,
                                                        preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let targetMags = conductor.spectrum.magnitudes
        let targetBands = conductor.spectrum.bands

        if magnitudes.count != targetMags.count {
            magnitudes = Array(repeating: 0, count: targetMags.count)
        }
        var next = magnitudes
        for i in 0..<next.count {
            let t = targetMags[i]
            if t > next[i] {
                next[i] += (t - next[i]) * attackFactor
            } else {
                next[i] = max(0, next[i] - fallOffPerTick)
            }
        }
        magnitudes = next

        bass      = smooth(bass,      toward: targetBands.bass)
        mid       = smooth(mid,       toward: targetBands.mid)
        treble    = smooth(treble,    toward: targetBands.treble)
        beatPulse = smooth(beatPulse, toward: targetBands.beatPulse,
                           fall: 0.08, attack: 0.9)

        currentBPM = conductor.currentBPM
        isBeatDetected = conductor.isBeatDetected
    }

    private func smooth(_ current: Float, toward target: Float,
                        fall: Float = 0.05, attack: Float = 0.65) -> Float {
        if target > current {
            return current + (target - current) * attack
        }
        return max(0, current - fall)
    }
}
