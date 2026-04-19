import AVFoundation
import Observation
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "AudioConductor")

@Observable
public final class AudioConductor: @unchecked Sendable {
    public private(set) var spectrum = Spectrum(binCount: 32)
    public private(set) var currentBPM: Double = 0
    public private(set) var isBeatDetected: Bool = false
    public private(set) var isPlaying: Bool = false
    public private(set) var positionSec: Double = 0
    public private(set) var durationSec: Double = 0
    public private(set) var lastErrorMessage: String?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let fft = FFTCore(fftSize: 1024, binCount: 32)
    private let bpm = OnsetBPMDetector()
    private var audioFile: AVAudioFile?
    private var tapInstalled = false
    private var exportedTempURL: URL?

    public init() {
        engine.attach(player)
    }

    public func load(url: URL) async throws {
        let localURL = try await ensureLocalFile(url: url)

        let file = try AVAudioFile(forReading: localURL)
        audioFile = file
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / sampleRate
        log.info("Loaded \(localURL.lastPathComponent, privacy: .public) — \(Int(sampleRate))Hz, \(Int(duration))s")

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback,
                                mode: .default,
                                options: [.allowBluetoothA2DP, .allowAirPlay])
        try session.setActive(true)

        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)

        if !tapInstalled {
            let mixer = engine.mainMixerNode
            mixer.installTap(onBus: 0,
                             bufferSize: 1024,
                             format: mixer.outputFormat(forBus: 0)) { [weak self] buf, time in
                self?.handle(buffer: buf, time: time)
            }
            tapInstalled = true
        }

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
            self.durationSec = duration
            self.positionSec = 0
            self.lastErrorMessage = nil
        }
    }

    public func play() {
        guard audioFile != nil else {
            log.warning("play() called with no audio file loaded")
            return
        }
        player.play()
        DispatchQueue.main.async { self.isPlaying = true }
        log.info("play() — engine running: \(self.engine.isRunning), player playing: \(self.player.isPlaying)")
    }

    public func pause() {
        player.pause()
        DispatchQueue.main.async { self.isPlaying = false }
    }

    public func stop() {
        player.stop()
        bpm.reset()
        DispatchQueue.main.async {
            self.isPlaying = false
            self.positionSec = 0
        }
    }

    private func ensureLocalFile(url: URL) async throws -> URL {
        if url.isFileURL {
            return url
        }
        log.info("Non-file URL scheme '\(url.scheme ?? "nil", privacy: .public)' — exporting to temp file")

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

        if let previous = exportedTempURL {
            try? FileManager.default.removeItem(at: previous)
        }
        exportedTempURL = tmp
        log.info("Exported to \(tmp.lastPathComponent, privacy: .public)")
        return tmp
    }

    private func handle(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard var spec = fft.process(buffer) else { return }
        let hostSec = AVAudioTime.seconds(forHostTime: time.hostTime)
        let result = bpm.ingest(bass: spec.bands.bass, atHostTimeSec: hostSec)
        spec.bands.beatPulse = result.beatPulse

        var pos: Double = 0
        if let nodeTime = player.lastRenderTime,
           let pTime = player.playerTime(forNodeTime: nodeTime) {
            pos = max(0, Double(pTime.sampleTime) / pTime.sampleRate)
        }

        DispatchQueue.main.async {
            self.spectrum = spec
            self.currentBPM = result.bpm
            self.isBeatDetected = result.isBeatNow
            self.positionSec = pos
        }
    }
}
