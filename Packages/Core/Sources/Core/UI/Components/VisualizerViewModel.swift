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

    /// User preference: when true, try to use Spotify's pre-computed analysis
    /// instead of the live file-mixer FFT. Apple Music tracks with an ISRC
    /// match route through the same path. Default on.
    @Published public var preferSyntheticAnalysis: Bool = true

    /// Current source driving the `magnitudes` / `bass` / `mid` / `treble`
    /// stream. Flipped to `.synthetic` automatically when a track with
    /// Spotify analysis (direct or via ISRC) loads; falls back to `.tap` when
    /// only a local mixer tap is available, or stays at zero when neither.
    @Published public private(set) var activeAnalysisSource: ActiveAnalysisSource = .tap

    public enum ActiveAnalysisSource: Equatable {
        case tap              // FFT from file mixer
        case synthetic        // Spotify /v1/audio-analysis → CADisplayLink
    }

    private let conductor: AudioConductor
    private var displayLink: CADisplayLink?
    private var metadataService: TrackMetadataService?
    private var analysisClient: SpotifyAnalysisClient?
    private var appleMusicKit: AppleMusicKitClient?
    private var metadataTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    /// Remembered source of the most recent track, so the Settings toggle can
    /// re-kick synthetic analysis mid-track without requiring a reload.
    private var lastTrackSource: TrackSource = .unknown

    public init(conductor: AudioConductor,
                binCount: Int = 32,
                metadataService: TrackMetadataService? = nil,
                analysisClient: SpotifyAnalysisClient? = nil,
                appleMusicKit: AppleMusicKitClient? = nil) {
        self.conductor = conductor
        self.binCount = binCount
        self.magnitudes = Array(repeating: 0, count: binCount)
        self.metadataService = metadataService
        self.analysisClient = analysisClient
        self.appleMusicKit = appleMusicKit
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
        analysisTask?.cancel()
    }

    public func play(item: MPMediaItem) async {
        let bpm: Double? = item.beatsPerMinute > 0 ? Double(item.beatsPerMinute) : nil
        // Try to enrich with ISRC via MusicKit so synthetic analysis can kick in
        // for DRM Apple Music tracks. If unavailable, fall back to BPM-only source.
        let isrc: String? = await appleMusicKit?.isrc(for: item.persistentID)
        let source: TrackSource
        if let isrc {
            source = .appleWithISRC(isrc: isrc, bpm: bpm)
        } else if let bpm {
            source = .appleWithBPM(bpm)
        } else {
            source = .appleUnknown
        }
        resetMetadata()
        do {
            try await conductor.load(item: item)
            conductor.play()
            errorMessage = nil
            fetchMetadata(for: source)
            activateAnalysisIfAvailable(source: source)
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
            activateAnalysisIfAvailable(source: source)
        } catch {
            errorMessage = Self.verboseMessage(for: error)
            print("[VisualizerViewModel] remote load error: \(error as NSError)")
        }
    }

    private func resetMetadata() {
        metadataTask?.cancel()
        metadataTask = nil
        metadataFeatures = TrackFeatures()
        analysisTask?.cancel()
        analysisTask = nil
        // Revert to tap until (and unless) synthetic re-activates.
        conductor.setAnalysisSource(.tap)
        activeAnalysisSource = .tap
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

    /// Fire-and-forget analysis fetch. On success, swaps AudioConductor to the
    /// synthetic source so the visualizer reads Spotify-computed bands instead
    /// of the file-mixer FFT. Silently no-ops on failure — the tap path
    /// remains active as the fallback (or stays silent if no tap is installed,
    /// e.g. DRM Apple Music tracks playing via MPMusicPlayerController).
    private func activateAnalysisIfAvailable(source: TrackSource) {
        guard preferSyntheticAnalysis,
              let client = analysisClient else { return }
        lastTrackSource = source

        analysisTask = Task { [weak self] in
            guard let self else { return }
            let trackID: String?
            switch source {
            case .spotify(let id):
                trackID = id
            case .appleWithISRC:
                // Resolve ISRC → Spotify track ID via the metadata service.
                trackID = await self.metadataService?.resolveSpotifyTrackID(for: source)
            case .appleWithBPM, .appleUnknown, .unknown:
                trackID = nil
            }
            guard let id = trackID else { return }
            if Task.isCancelled { return }

            do {
                let analysis = try await client.analysis(for: id)
                if Task.isCancelled { return }
                await MainActor.run {
                    let driver = SyntheticAnalysisDriver(analysis: analysis, binCount: self.binCount)
                    self.conductor.setAnalysisSource(.synthetic(driver))
                    self.activeAnalysisSource = .synthetic
                }
            } catch {
                // Analysis 404s on ~15% of tracks; stay on tap silently.
                print("[VisualizerViewModel] synthetic analysis unavailable for \(id): \(error.localizedDescription)")
            }
        }
    }

    /// User-facing toggle from Settings. Flips the active source immediately.
    public func setPreferSyntheticAnalysis(_ on: Bool) {
        preferSyntheticAnalysis = on
        if on {
            // Attempt to activate for whatever track is currently loaded. If
            // lastTrackSource is .unknown (nothing loaded) or it doesn't resolve
            // to a Spotify ID, this is a no-op and we stay on tap.
            activateAnalysisIfAvailable(source: lastTrackSource)
        } else {
            conductor.setAnalysisSource(.tap)
            activeAnalysisSource = .tap
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
