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

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let fft = FFTCore(fftSize: 1024, binCount: 32)
    private let bpm = OnsetBPMDetector()
    private let systemPlayer = MPMusicPlayerController.applicationMusicPlayer

    private var audioFile: AVAudioFile?
    private var activeTap: TapKind = .none
    private var exportedTempURL: URL?
    private var positionTimer: Timer?
    private var stateObserver: NSObjectProtocol?
    private var nowPlayingObserver: NSObjectProtocol?

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
        bpm.reset()
        cleanupTempFile()
        DispatchQueue.main.async {
            self.isPlaying = false
            self.positionSec = 0
        }
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
                if let nodeTime = self.player.lastRenderTime,
                   let p = self.player.playerTime(forNodeTime: nodeTime) {
                    pos = Double(p.sampleTime) / p.sampleRate
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
        guard var spec = fft.process(buffer) else { return }
        let hostSec = AVAudioTime.seconds(forHostTime: time.hostTime)
        let result = bpm.ingest(bass: spec.bands.bass, atHostTimeSec: hostSec)
        spec.bands.beatPulse = result.beatPulse

        DispatchQueue.main.async {
            self.spectrum = spec
            self.currentBPM = result.bpm
            self.isBeatDetected = result.isBeatNow
        }
    }
}
