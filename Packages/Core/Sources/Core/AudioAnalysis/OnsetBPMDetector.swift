import Foundation

public final class OnsetBPMDetector: @unchecked Sendable {
    public struct Result {
        public let bpm: Double
        public let beatPulse: Float
        public let isBeatNow: Bool
    }

    private var bassHistory: [Float] = []
    private let historyLength = 32

    private var onsets: [Double] = []
    private let maxOnsets = 16

    private var lastBeatTimeSec: Double = 0
    private var lastBpm: Double = 0

    private let minOnsetIntervalSec: Double = 0.20
    private let kSigma: Float = 1.3
    private let silenceFloor: Float = 0.15

    public init() {}

    public func ingest(bass: Float, atHostTimeSec t: Double) -> Result {
        bassHistory.append(bass)
        if bassHistory.count > historyLength { bassHistory.removeFirst() }

        guard bassHistory.count >= historyLength / 2 else {
            return Result(bpm: lastBpm, beatPulse: decay(at: t), isBeatNow: false)
        }

        let window = bassHistory.dropLast()
        var mu: Float = 0
        for v in window { mu += v }
        mu /= Float(window.count)
        var varSum: Float = 0
        for v in window { let d = v - mu; varSum += d * d }
        let sigma = sqrtf(varSum / Float(window.count))

        let threshold = mu + kSigma * sigma
        let rising = bass > threshold
        let debounced = (t - lastBeatTimeSec) > minOnsetIntervalSec
        let detected = rising && debounced && bass > silenceFloor

        if detected {
            onsets.append(t)
            if onsets.count > maxOnsets { onsets.removeFirst() }
            lastBeatTimeSec = t
            lastBpm = estimateBPM()
        }

        return Result(bpm: lastBpm, beatPulse: decay(at: t), isBeatNow: detected)
    }

    public func reset() {
        bassHistory.removeAll(keepingCapacity: true)
        onsets.removeAll(keepingCapacity: true)
        lastBeatTimeSec = 0
        lastBpm = 0
    }

    private func decay(at t: Double) -> Float {
        guard lastBeatTimeSec > 0 else { return 0 }
        let dt = t - lastBeatTimeSec
        return Float(exp(-dt * 8.0))
    }

    private func estimateBPM() -> Double {
        guard onsets.count >= 4 else { return lastBpm }
        var intervals: [Double] = []
        for i in 1..<onsets.count {
            let d = onsets[i] - onsets[i - 1]
            if d > 0.2 && d < 2.0 { intervals.append(d) }
        }
        guard !intervals.isEmpty else { return lastBpm }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let bpm = 60.0 / median
        if lastBpm > 0 { return lastBpm * 0.7 + bpm * 0.3 }
        return bpm
    }
}
