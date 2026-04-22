import SwiftUI
import UIKit
import Combine
import MediaPlayer
import QuartzCore
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "VisualizerViewModel")

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
    @Published public private(set) var currentArtwork: UIImage?
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
        case tap                    // FFT from file mixer
        case synthetic              // Spotify /v1/audio-analysis → CADisplayLink
        case syntheticFromPreview   // Apple Music 30-sec preview, FFT'd offline and looped
    }

    /// Which system is owning audio playback right now. Transport controls,
    /// position/duration, and title/artist all dispatch through this.
    @Published public private(set) var playbackBackend: PlaybackBackend = .idle

    public enum PlaybackBackend: Equatable {
        case idle
        case conductor       // local audio via AudioConductor (file or system player)
        case spotifyApp      // full-track via SPTAppRemote (Spotify iOS SDK)
    }

    private let conductor: AudioConductor
    private var displayLink: CADisplayLink?
    private let deps: Dependencies
    private var metadataTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    /// Everything we remember about the most recently-loaded track so the
    /// Settings toggle can re-kick analysis mid-track, and the preview-FFT
    /// fallback has the metadata it needs without a second MPMediaItem
    /// round-trip. One assignment per track load means no risk of a partial
    /// update where e.g. the source moves forward but the duration lags.
    private struct LastTrackContext {
        let source: TrackSource
        let persistentID: UInt64?
        let duration: Double
        let bpmHint: Double?
        static let empty = LastTrackContext(source: .unknown,
                                            persistentID: nil,
                                            duration: 0,
                                            bpmHint: nil)
    }
    private var lastTrack: LastTrackContext = .empty

    /// Optional collaborators bundled into a struct so the init stays tight
    /// (one required param + Dependencies + binCount) and call sites can use
    /// a struct literal rather than threading 5+ args.
    public struct Dependencies: Sendable {
        public var metadataService: TrackMetadataService? = nil
        public var analysisClient: SpotifyAnalysisClient? = nil
        public var appleMusicKit: AppleMusicKitClient? = nil
        public var previewAnalysisService: PreviewAnalysisService? = nil
        /// Spotify iOS SDK playback wrapper. The Settings UI holds the same
        /// reference for the Connect/Disconnect controls; the VM uses it to
        /// route full-track playback through SPTAppRemote when connected.
        public var spotifyPlayback: SpotifyPlaybackSource? = nil
        public init() {}
    }

    public init(conductor: AudioConductor,
                binCount: Int = 32,
                deps: Dependencies = .init()) {
        self.conductor = conductor
        self.binCount = binCount
        self.magnitudes = Array(repeating: 0, count: binCount)
        self.deps = deps
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
        let isrc: String? = await deps.appleMusicKit?.isrc(for: item.persistentID)
        let source: TrackSource
        if let isrc {
            source = .appleWithISRC(isrc: isrc, bpm: bpm)
        } else if let bpm {
            source = .appleWithBPM(bpm)
        } else {
            source = .appleUnknown
        }
        // Single assignment — no chance of a partial update.
        lastTrack = LastTrackContext(
            source: source,
            persistentID: item.persistentID,
            duration: item.playbackDuration,
            bpmHint: bpm
        )

        resetMetadata()
        do {
            try await conductor.load(item: item)
            conductor.play()
            playbackBackend = .conductor
            currentArtwork = item.artwork?.image(at: CGSize(width: 512, height: 512))
            errorMessage = nil
            fetchMetadata(for: source)
            activateAnalysisIfAvailable()
        } catch {
            errorMessage = Self.verboseMessage(for: error)
            log.error("load error: \((error as NSError).domain, privacy: .public)(\((error as NSError).code, privacy: .public)) \(error.localizedDescription, privacy: .public)")
        }
    }

    public func play(remoteURL: URL,
                     title: String?,
                     artist: String?,
                     durationSec: TimeInterval = 0,
                     source: TrackSource = .unknown) async {
        // Remote URLs (Spotify previews, downloaded mp3s) run through the
        // file-mixer tap; the preview-clip fallback is Apple-Music-specific.
        currentArtwork = nil
        lastTrack = LastTrackContext(
            source: source,
            persistentID: nil,
            duration: durationSec,
            bpmHint: nil
        )

        resetMetadata()
        do {
            try await conductor.load(remoteURL: remoteURL,
                                     title: title,
                                     artist: artist,
                                     durationSec: durationSec)
            conductor.play()
            playbackBackend = .conductor
            errorMessage = nil
            fetchMetadata(for: source)
            activateAnalysisIfAvailable()
        } catch {
            errorMessage = Self.verboseMessage(for: error)
            log.error("remote load error: \((error as NSError).domain, privacy: .public)(\((error as NSError).code, privacy: .public)) \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Play a Spotify track. If the Spotify iOS SDK is connected (`Settings →
    /// Spotify Playback → Connect`), plays the FULL track via SPTAppRemote
    /// through the Spotify app (Premium required — audio comes out wherever
    /// Spotify is currently routing, e.g. AirPods). Otherwise falls back to
    /// the 30-second preview clip via the file mixer.
    ///
    /// Either way, `activateAnalysisIfAvailable(source:)` kicks off the
    /// `/v1/audio-analysis` fetch so the visualizer reacts to the real DSP.
    public func playSpotify(trackID: String,
                            name: String,
                            artist: String,
                            previewURL: URL?,
                            durationSec: TimeInterval) async {
        let source = TrackSource.spotify(id: trackID)
        currentArtwork = nil

        // SDK path: full-track via SPTAppRemote.
        if let sdk = deps.spotifyPlayback, sdk.isConnected {
            // Stop any local playback so the conductor isn't holding the route.
            conductor.stop()
            lastTrack = LastTrackContext(
                source: source,
                persistentID: nil,
                duration: durationSec,
                bpmHint: nil
            )

            resetMetadata()
            do {
                try await sdk.play(uri: "spotify:track:\(trackID)")
                playbackBackend = .spotifyApp
                errorMessage = nil
                fetchMetadata(for: source)
                activateAnalysisIfAvailable()
                return
            } catch {
                // SDK play failed (Spotify app closed, not Premium, etc.).
                // Fall back to preview if one is available; otherwise surface.
                let ns = error as NSError
                log.warning("SDK play failed: \(ns.domain, privacy: .public)(\(ns.code, privacy: .public)) — \(ns.localizedDescription, privacy: .public)")
                if previewURL == nil {
                    errorMessage = Self.verboseMessage(for: error)
                    return
                }
                // else fall through to preview path below
            }
        }

        // Preview fallback.
        guard let preview = previewURL else {
            errorMessage = "No preview available. Connect Spotify in Settings for full-track playback."
            return
        }
        await play(remoteURL: preview,
                   title: name,
                   artist: artist,
                   durationSec: durationSec,
                   source: source)
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
        guard let service = deps.metadataService, source != .unknown else { return }
        metadataTask = Task { [weak self] in
            guard let self else { return }
            let features = await service.features(for: source)
            if Task.isCancelled { return }
            await MainActor.run {
                self.metadataFeatures = features
            }
        }
    }

    /// Installs a synthetic driver on the conductor from a resolved analysis
    /// blob, and updates the source indicator on the MainActor. Extracted so
    /// the Tier-1 and Tier-2 success paths don't drift.
    private func installSynthetic(_ analysis: SpotifyAudioAnalysis,
                                  as label: ActiveAnalysisSource) async {
        await MainActor.run {
            let driver = SyntheticAnalysisDriver(analysis: analysis, binCount: self.binCount)
            self.conductor.setAnalysisSource(.synthetic(driver))
            self.activeAnalysisSource = label
            if label == .syntheticFromPreview {
                log.info("Analysis source → synthetic (preview tier)")
            } else {
                log.info("Analysis source → synthetic")
            }
        }
    }

    /// Fire-and-forget analysis fetch with a two-tier fallback:
    ///   Tier 1: Spotify `/v1/audio-analysis` (direct track ID, or via ISRC lookup)
    ///   Tier 2: offline FFT of the MusicKit 30-second preview clip, looped
    ///
    /// On success, swaps AudioConductor to the synthetic source so the
    /// visualizer reads pre-computed bands instead of the file-mixer FFT.
    /// Silently no-ops on total failure — the tap path remains active as the
    /// floor fallback (or stays silent for DRM Apple Music tracks with no
    /// tappable audio route).
    ///
    /// Reads all state from `lastTrack`; call sites update that struct before
    /// invoking this.
    private func activateAnalysisIfAvailable() {
        guard preferSyntheticAnalysis else { return }

        // Capture @MainActor-isolated state up front so the Task body uses
        // plain values and only needs cross-actor hops for explicit awaits.
        let source = lastTrack.source
        let pid = lastTrack.persistentID
        let duration = lastTrack.duration
        let bpmHint = lastTrack.bpmHint
        let client = deps.analysisClient
        let previewService = deps.previewAnalysisService
        let meta = deps.metadataService
        let appleMusicKit = deps.appleMusicKit

        analysisTask = Task { [weak self] in
            guard let self else { return }

            // Tier 1: Spotify analysis by track ID (direct or resolved from ISRC).
            // For .appleWithISRC, speculatively warm the AppleMusicKit SongInfo
            // cache in parallel — if Tier-1 wins, the extra fetch is free
            // (cached for next track); if Tier-1 misses, Tier-2's
            // previewURL(for:) call below hits a warm cache.
            if let client {
                let trackID: String?
                switch source {
                case .spotify(let id):
                    trackID = id
                case .appleWithISRC:
                    async let resolved = meta?.resolveSpotifyTrackID(for: source)
                    // Fire-and-forget preview-URL warming via an inherited
                    // child `Task` so it runs TRULY in parallel with the
                    // ISRC resolution above. (An `async let _` inside a
                    // block would be implicitly awaited at scope exit,
                    // serializing it — defeats the parallelism goal.) The
                    // outer Task's cancellation propagates down to this
                    // child, so we don't leak past the analysis lifetime.
                    if let pid, let akit = appleMusicKit {
                        Task { _ = await akit.previewURL(for: pid) }
                    }
                    trackID = await resolved
                case .appleWithBPM, .appleUnknown, .unknown:
                    trackID = nil
                }
                if let id = trackID {
                    if Task.isCancelled { return }
                    do {
                        let analysis = try await client.analysis(for: id)
                        if Task.isCancelled { return }
                        await self.installSynthetic(analysis, as: .synthetic)
                        return
                    } catch {
                        // Analysis 404s on ~15% of tracks. Don't stop here —
                        // fall through to the preview-clip tier.
                        log.warning("Tier-1 analysis unavailable for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            // Tier 2: preview-clip FFT fallback (Apple Music library only).
            if let previewService, let pid, duration > 0 {
                if Task.isCancelled { return }
                do {
                    let analysis = try await previewService.analysis(
                        for: pid,
                        trackDurationSec: duration,
                        bpmHint: bpmHint
                    )
                    if Task.isCancelled { return }
                    await self.installSynthetic(analysis, as: .syntheticFromPreview)
                } catch {
                    log.warning("Tier-2 preview fallback unavailable for pid=\(pid, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// User-facing toggle from Settings. Flips the active source immediately.
    public func setPreferSyntheticAnalysis(_ on: Bool) {
        preferSyntheticAnalysis = on
        if on {
            // Attempt to activate for whatever track is currently loaded. If
            // nothing is loaded, or the source doesn't resolve to a Spotify
            // ID, this is a no-op and we stay on tap.
            activateAnalysisIfAvailable()
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
        switch playbackBackend {
        case .conductor:
            conductor.isPlaying ? conductor.pause() : conductor.play()
        case .spotifyApp:
            guard let sdk = deps.spotifyPlayback else { return }
            let playing = sdk.isPlaying
            Task {
                do {
                    if playing { try await sdk.pause() } else { try await sdk.resume() }
                } catch {
                    print("[VisualizerViewModel] SDK toggle failed: \(error.localizedDescription)")
                }
            }
        case .idle:
            break
        }
    }

    public func stop() {
        switch playbackBackend {
        case .conductor: conductor.stop()
        case .spotifyApp:
            if let sdk = deps.spotifyPlayback {
                Task { try? await sdk.pause() }
            }
        case .idle: break
        }
        playbackBackend = .idle
    }

    public func seek(to seconds: Double) {
        switch playbackBackend {
        case .conductor: conductor.seek(to: seconds)
        case .spotifyApp:
            guard let sdk = deps.spotifyPlayback else { return }
            Task { try? await sdk.seek(to: seconds) }
        case .idle: break
        }
    }

    public func rewind(by seconds: Double = 10) {
        seek(to: max(0, positionSec - seconds))
    }

    public func fastForward(by seconds: Double = 10) {
        seek(to: min(durationSec, positionSec + seconds))
    }

    public var isPlaying: Bool {
        switch playbackBackend {
        case .conductor:  return conductor.isPlaying
        case .spotifyApp: return deps.spotifyPlayback?.isPlaying ?? false
        case .idle:       return false
        }
    }

    public var positionSec: Double {
        switch playbackBackend {
        case .conductor:  return conductor.positionSec
        case .spotifyApp: return deps.spotifyPlayback?.positionSec ?? 0
        case .idle:       return 0
        }
    }

    public var durationSec: Double {
        switch playbackBackend {
        case .conductor:  return conductor.durationSec
        case .spotifyApp: return deps.spotifyPlayback?.currentTrack?.durationSec ?? 0
        case .idle:       return 0
        }
    }

    public var mode: PlaybackMode { conductor.mode }

    public var currentTitle: String? {
        switch playbackBackend {
        case .conductor:  return conductor.currentTitle
        case .spotifyApp: return deps.spotifyPlayback?.currentTrack?.name
        case .idle:       return nil
        }
    }

    public var currentArtist: String? {
        switch playbackBackend {
        case .conductor:  return conductor.currentArtist
        case .spotifyApp: return deps.spotifyPlayback?.currentTrack?.artistName
        case .idle:       return nil
        }
    }

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
