import SwiftUI
import Combine
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

    public let binCount: Int
    public var fallOffPerTick: Float = 0.04
    public var attackFactor: Float = 0.65

    private let conductor: AudioConductor
    private var displayLink: CADisplayLink?

    public init(conductor: AudioConductor, binCount: Int = 32) {
        self.conductor = conductor
        self.binCount = binCount
        self.magnitudes = Array(repeating: 0, count: binCount)
        super.init()
        startDisplayLoop()
    }

    deinit {
        displayLink?.invalidate()
    }

    public func play(url: URL) throws {
        try conductor.load(url: url)
        conductor.play()
    }

    public func togglePlayPause() {
        conductor.isPlaying ? conductor.pause() : conductor.play()
    }

    public func stop() { conductor.stop() }

    public var isPlaying: Bool { conductor.isPlaying }
    public var positionSec: Double { conductor.positionSec }
    public var durationSec: Double { conductor.durationSec }

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
