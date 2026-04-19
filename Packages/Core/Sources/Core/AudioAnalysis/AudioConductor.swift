import AVFoundation
import Observation

@Observable
public final class AudioConductor: @unchecked Sendable {
    public private(set) var spectrum = Spectrum(binCount: 32)
    public private(set) var currentBPM: Double = 0
    public private(set) var isBeatDetected: Bool = false
    public private(set) var isPlaying: Bool = false
    public private(set) var positionSec: Double = 0
    public private(set) var durationSec: Double = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let fft = FFTCore(fftSize: 1024, binCount: 32)
    private let bpm = OnsetBPMDetector()
    private var audioFile: AVAudioFile?
    private var tapInstalled = false

    public init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
    }

    public func load(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        audioFile = file
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / sampleRate

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback,
                                mode: .default,
                                options: [.allowBluetoothA2DP, .allowAirPlay])
        try session.setActive(true)

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
        }

        player.stop()
        player.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async { self?.isPlaying = false }
        }
        bpm.reset()

        DispatchQueue.main.async {
            self.durationSec = duration
            self.positionSec = 0
        }
    }

    public func play() {
        guard audioFile != nil else { return }
        player.play()
        DispatchQueue.main.async { self.isPlaying = true }
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
