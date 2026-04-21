import AVFoundation
import MediaPlayer
import Observation
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "AudioConductor")

public enum PlaybackMode: Sendable, Equatable {
    case idle
    case file     // AVAudioPlayerNode → mainMixerNode tap (owned tracks)
    case system   // MPMusicPlayerController + inputNode (mic) tap (DRM tracks)
}

/// Selects which signal drives the `spectrum` stream. Playback mode
/// (.file / .system) is chosen by the source of the audio itself — it is
/// independent of this choice. For DRM tracks we can prefer synthetic over
/// the mic; for owned file playback we can still flip to synthetic to match
/// the Spotify-anchored visuals.
public enum AnalysisSource {
    case tap                            // FFT from active AVAudioEngine tap
    case synthetic(SyntheticAnalysisDriver)
}

@Observable
public final class AudioConductor: @unchecked Sendable {
    public private(set) var spectrum = Spectrum(binCount: 32)
    public private(set) var currentBPM: Double = 0
    public private(set) var isBeatDetected: Bool = false
    public private(set) var isPlaying: Bool = false
    public private(set) var positionSec: Double = 0
    public private(set) var durationSec: Double = 0
    public private(set) var mode: PlaybackMode = .idle
    public private(set) var currentTitle: String?
    public private(set) var currentArtist: String?
    public private(set) var analysisSource: AnalysisSource = .tap

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    // 2048 at 44.1kHz → 21.5 Hz bin resolution (vs 43 Hz at 1024), better bass.
    private let fft = FFTCore(fftSize: 2048, binCount: 32)
    private let bpm = OnsetBPMDetector()
    private let systemPlayer = MPMusicPlayerController.applicationMusicPlayer

    private var audioFile: AVAudioFile?
    private var activeTap: TapKind = .none
    private var exportedTempURL: URL?
    private var positionTimer: Timer?
    private var stateObserver: NSObjectProtocol?
    private var nowPlayingObserver: NSObjectProtocol?
    // Running offset (in audio frames) of the currently-scheduled segment's start.
    // 0 when the whole file was just scheduled via scheduleFile; non-zero after seek()
    // re-queues with scheduleSegment from a different startFrame. Used to convert the
    // player node's local sampleTime back to absolute playback position.
    private var seekBaseFrames: AVAudioFramePosition = 0

    private enum TapKind { case none, mixer, mic }

    public init() {
        engine.attach(player)

        stateObserver = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: systemPlayer,
            queue: .main
        ) { [weak self] _ in self?.systemPlaybackStateChanged() }

        nowPlayingObserver = NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: systemPlayer,
            queue: .main
        ) { [weak self] _ in self?.systemNowPlayingChanged() }

        systemPlayer.beginGeneratingPlaybackNotifications()
    }

    deinit {
        if let s = stateObserver { NotificationCenter.default.removeObserver(s) }
        if let n = nowPlayingObserver { NotificationCenter.default.removeObserver(n) }
        systemPlayer.endGeneratingPlaybackNotifications()
        positionTimer?.invalidate()
    }

    // MARK: - Public API

    /// Swap the analysis signal source. Playback mode is NOT changed — this
    /// only controls whether the `spectrum` stream comes from the real-time
    /// FFT tap or from a synthetic driver (e.g. Spotify audio analysis).
    ///
    /// MainActor because `SyntheticAnalysisDriver` is MainActor-isolated, and
    /// because we assign the `onUpdate` closure which then writes `spectrum`
    /// via `DispatchQueue.main.async` to match the rest of this class.
    @MainActor
    public func setAnalysisSource(_ source: AnalysisSource) {
        // Stop any existing synthetic driver before replacing.
        if case .synthetic(let old) = analysisSource { old.stop() }

        analysisSource = source

        if case .synthetic(let driver) = source {
            driver.onUpdate = { [weak self] spec in
                guard let self else { return }
                DispatchQueue.main.async { self.spectrum = spec }
            }
            driver.start { [weak self] in self?.positionSec ?? 0 }
            log.info("Analysis source → synthetic")
        } else {
            log.info("Analysis source → tap")
        }
    }

    public func load(item: MPMediaItem) async throws {
        let title = item.title ?? "unknown"
        log.info("load(item:) — title='\(title, privacy: .private)' hasAssetURL=\(item.assetURL != nil)")

        await MainActor.run {
            self.currentTitle = item.title
            self.currentArtist = item.artist
        }

        if let url = item.assetURL {
            do {
                try await loadFile(url: url, duration: item.playbackDuration)
                return
            } catch {
                // Some library assets (DRM-wrapped Apple Music downloads, protected iTunes
                // purchases, etc.) return a non-nil assetURL but refuse to export / be
                // read by AVAudioFile. Fall back to the system player + mic-tap path.
                let ns = error as NSError
                log.warning("loadFile failed (\(ns.domain)\(ns.code) — \(ns.localizedDescription, privacy: .public)); falling back to system player")
            }
        }
        try await loadSystemPlayer(item: item)
    }

    /// Load a remote / local audio URL directly — used for Spotify preview mp3 etc.
    public func load(remoteURL: URL,
                     title: String?,
                     artist: String?,
                     durationSec: TimeInterval = 0) async throws {
        log.info("load(remoteURL:) — \(remoteURL.absoluteString, privacy: .private)")
        await MainActor.run {
            self.currentTitle = title
            self.currentArtist = artist
        }
        try await loadFile(url: remoteURL, duration: durationSec)
    }

    public func play() {
        switch mode {
        case .file:
            guard audioFile != nil else {
                log.warning("play() on .file mode with no audio file")
                return
            }
            player.play()
        case .system:
            systemPlayer.play()
        case .idle:
            log.warning("play() in .idle mode")
            return
        }
        DispatchQueue.main.async { self.isPlaying = true }
        startPositionTimer()
    }

    public func pause() {
        switch mode {
        case .file: player.pause()
        case .system: systemPlayer.pause()
        case .idle: break
        }
        DispatchQueue.main.async { self.isPlaying = false }
    }

    public func stop() {
        switch mode {
        case .file: player.stop()
        case .system: systemPlayer.stop()
        case .idle: break
        }
        positionTimer?.invalidate()
        positionTimer = nil
        seekBaseFrames = 0
        bpm.reset()
        cleanupTempFile()

        // Tear down any synthetic analysis driver and reset to tap. Driver
        // lives on MainActor, so hop there to call stop() and mutate state.
        let currentSource = analysisSource
        Task { @MainActor in
            if case .synthetic(let driver) = currentSource { driver.stop() }
            self.analysisSource = .tap
        }

        DispatchQueue.main.async {
            self.isPlaying = false
            self.positionSec = 0
        }
    }

    /// Seek to an absolute position. Clamped to [0, durationSec].
    /// - file mode: stops the player, re-schedules a segment starting at the target
    ///   frame, and restarts playback if it was already playing.
    /// - system mode: sets `MPMusicPlayerController.currentPlaybackTime`.
    public func seek(to seconds: Double) {
        let target = max(0, min(seconds, max(0.01, durationSec)))
        switch mode {
        case .file:
            guard let file = audioFile else { return }
            let sr = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(target * sr)
            let remaining = AVAudioFrameCount(max(0, file.length - startFrame))
            if remaining == 0 { return }
            let wasPlaying = isPlaying
            player.stop()
            seekBaseFrames = startFrame
            player.scheduleSegment(file,
                                   startingFrame: startFrame,
                                   frameCount: remaining,
                                   at: nil) { [weak self] in
                DispatchQueue.main.async { self?.isPlaying = false }
            }
            bpm.reset()
            if wasPlaying {
                player.play()
            }
        case .system:
            systemPlayer.currentPlaybackTime = target
        case .idle:
            return
        }
        DispatchQueue.main.async { self.positionSec = target }
    }

    public func rewind(by seconds: Double = 10) {
        seek(to: positionSec - seconds)
    }

    public func fastForward(by seconds: Double = 10) {
        seek(to: positionSec + seconds)
    }

    // MARK: - File mode (owned tracks)

    private func loadFile(url: URL, duration: TimeInterval) async throws {
        // Teardown any system playback
        systemPlayer.stop()

        let localURL = try await ensureLocalFile(url: url)
        let file = try AVAudioFile(forReading: localURL)
        audioFile = file
        let sampleRate = file.processingFormat.sampleRate
        let actualDuration = max(duration, Double(file.length) / sampleRate)
        log.info("Loaded file \(localURL.lastPathComponent, privacy: .public) — \(Int(sampleRate))Hz, \(Int(actualDuration))s")

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback,
                                mode: .default,
                                options: [.allowBluetoothA2DP, .allowAirPlay])
        try session.setActive(true)

        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)

        try switchTap(to: .mixer)

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
            log.info("Engine started, output format: \(self.engine.mainMixerNode.outputFormat(forBus: 0))")
        }

        player.stop()
        seekBaseFrames = 0
        player.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async { self?.isPlaying = false }
        }
        bpm.reset()

        await MainActor.run {
            self.mode = .file
            self.durationSec = actualDuration
            self.positionSec = 0
        }
    }

    // MARK: - System mode (DRM tracks: MPMusicPlayerController + mic)

    private func loadSystemPlayer(item: MPMediaItem) async throws {
        // Stop file playback if any
        player.stop()

        let granted = await requestMicAccess()
        guard granted else {
            throw NSError(
                domain: "AudioConductor", code: -20,
                userInfo: [
                    NSLocalizedDescriptionKey: "Microphone access denied",
                    NSLocalizedFailureReasonErrorKey:
                        "DRM-protected tracks (Apple Music subscription downloads) need the microphone to react to what's playing on the speaker. Grant mic access in Settings → StudioJoe Music and try again."
                ]
            )
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .default,
                                options: [.defaultToSpeaker,
                                          .allowBluetoothA2DP,
                                          .mixWithOthers])
        try session.setActive(true)

        engine.disconnectNodeOutput(player)
        try switchTap(to: .mic)

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
            log.info("Engine started for mic tap, format: \(self.engine.inputNode.outputFormat(forBus: 0))")
        }

        systemPlayer.setQueue(with: MPMediaItemCollection(items: [item]))
        bpm.reset()

        await MainActor.run {
            self.mode = .system
            self.durationSec = item.playbackDuration
            self.positionSec = 0
        }
        log.info("System queue set, mic tap active — play speakers to drive visualization")
    }

    private func requestMicAccess() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    @objc private func systemPlaybackStateChanged() {
        let state = systemPlayer.playbackState
        let playing = (state == .playing)
        Task { @MainActor in self.isPlaying = playing }
    }

    @objc private func systemNowPlayingChanged() {
        let item = systemPlayer.nowPlayingItem
        Task { @MainActor in
            self.currentTitle = item?.title
            self.currentArtist = item?.artist
            if let dur = item?.playbackDuration { self.durationSec = dur }
        }
    }

    private func startPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let pos: Double
            switch self.mode {
            case .system:
                pos = self.systemPlayer.currentPlaybackTime
            case .file:
                // Add seekBaseFrames-derived offset so the position is absolute:
                // after a seek(), scheduleSegment resets the node's sampleTime to 0,
                // so we need to add the segment's starting frame back in.
                if let nodeTime = self.player.lastRenderTime,
                   let p = self.player.playerTime(forNodeTime: nodeTime) {
                    let baseSec = Double(self.seekBaseFrames) / p.sampleRate
                    pos = baseSec + Double(p.sampleTime) / p.sampleRate
                } else {
                    pos = self.positionSec
                }
            case .idle:
                pos = 0
            }
            Task { @MainActor in self.positionSec = max(0, pos) }
        }
    }

    // MARK: - Tap management

    private func switchTap(to kind: TapKind) throws {
        if activeTap == kind { return }
        switch activeTap {
        case .mixer: engine.mainMixerNode.removeTap(onBus: 0)
        case .mic:   engine.inputNode.removeTap(onBus: 0)
        case .none:  break
        }
        switch kind {
        case .mixer:
            let mixer = engine.mainMixerNode
            mixer.installTap(onBus: 0, bufferSize: 1024,
                             format: mixer.outputFormat(forBus: 0)) { [weak self] buf, time in
                self?.handle(buffer: buf, time: time)
            }
        case .mic:
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, time in
                self?.handle(buffer: buf, time: time)
            }
        case .none: break
        }
        activeTap = kind
    }

    // MARK: - Export helper (owned tracks whose URL is ipod-library://)

    private func ensureLocalFile(url: URL) async throws -> URL {
        if url.isFileURL { return url }
        let scheme = url.scheme?.lowercased() ?? ""
        log.info("Non-file URL scheme '\(scheme, privacy: .public)' — normalizing to temp file")

        if scheme == "https" || scheme == "http" {
            // Preview mp3 from Spotify / Apple Music — direct download
            let (tmpSrc, _) = try await URLSession.shared.download(from: url)
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension.isEmpty ? "mp3" : url.pathExtension)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmpSrc, to: dst)
            cleanupTempFile()
            exportedTempURL = dst
            log.info("Downloaded \(dst.lastPathComponent, privacy: .public)")
            return dst
        }

        // iPod library asset — transcode via AVAssetExportSession
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            throw NSError(domain: "AudioConductor", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Source has no audio tracks"])
        }
        guard let exporter = AVAssetExportSession(asset: asset,
                                                  presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "AudioConductor", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create export session"])
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try await exporter.export(to: tmp, as: .m4a)

        cleanupTempFile()
        exportedTempURL = tmp
        log.info("Exported to \(tmp.lastPathComponent, privacy: .public)")
        return tmp
    }

    private func cleanupTempFile() {
        if let previous = exportedTempURL {
            try? FileManager.default.removeItem(at: previous)
            exportedTempURL = nil
        }
    }

    // MARK: - Tap callback

    private func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // Always run FFT + BPM: the onset detector stays useful (currentBPM /
        // isBeatDetected) regardless of which signal drives `spectrum`.
        guard var spec = fft.process(buffer) else { return }
        let hostSec = AVAudioTime.seconds(forHostTime: time.hostTime)
        let result = bpm.ingest(bass: spec.bands.bass, atHostTimeSec: hostSec)
        spec.bands.beatPulse = result.beatPulse

        // Snapshot once — avoids racing with setAnalysisSource between reads.
        let shouldPublishSpectrum: Bool
        switch analysisSource {
        case .tap: shouldPublishSpectrum = true
        case .synthetic: shouldPublishSpectrum = false
        }

        DispatchQueue.main.async {
            if shouldPublishSpectrum {
                self.spectrum = spec
            }
            self.currentBPM = result.bpm
            self.isBeatDetected = result.isBeatNow
        }
    }
}
