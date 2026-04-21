import Foundation
import QuartzCore
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "SyntheticAnalysisDriver")

/// Drives a `Spectrum` stream from a pre-fetched Spotify audio analysis
/// payload, sampled on a CADisplayLink against a caller-supplied playback
/// clock. This is the primary (non-microphone) visualizer signal path.
///
/// Ported from `musicplayer-viz/spotify-analysis.js` but with per-bin pitch
/// magnitudes so the spectrum array has real content instead of broadcasting
/// a scalar.
@MainActor
public final class SyntheticAnalysisDriver {
    public var onUpdate: ((Spectrum) -> Void)?

    private let analysis: SpotifyAudioAnalysis
    private let binCount: Int

    private var displayLink: CADisplayLink?
    private var positionProvider: (@MainActor () -> Double)?

    // Kept outside of `segments` / `beats` so that empty arrays read uniformly.
    private let segmentCount: Int
    private let beatCount: Int
    // Precomputed to avoid Double divisions inside the tick hot path.
    private let invBinCount: Double

    public init(analysis: SpotifyAudioAnalysis, binCount: Int = 32) {
        self.analysis = analysis
        // Clamp to a sane minimum so the bin loop isn't degenerate.
        self.binCount = max(1, binCount)
        self.segmentCount = analysis.segments.count
        self.beatCount = analysis.beats.count
        self.invBinCount = 1.0 / Double(self.binCount)
        log.info("init — segments=\(self.segmentCount) beats=\(self.beatCount) bins=\(self.binCount)")
    }

    deinit {
        // displayLink is @MainActor-isolated; deinit on a MainActor class runs
        // on the main actor so calling invalidate here is safe.
        displayLink?.invalidate()
    }

    public func start(positionProvider: @escaping @MainActor () -> Double) {
        // Idempotent: stop any existing link before creating a new one so
        // repeated starts don't leak CADisplayLinks.
        stop()
        self.positionProvider = positionProvider
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60,
                                                       maximum: 120,
                                                       preferred: 120)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
        log.info("started")
    }

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        positionProvider = nil
    }

    // MARK: - Tick

    @objc private func tick(_ link: CADisplayLink) {
        guard let provider = positionProvider else { return }
        let t = provider()
        var spec = Spectrum(binCount: binCount)
        spec.sampleHostTimeSec = link.timestamp

        // Handle empty segments — all zero spectrum is the correct output.
        guard segmentCount > 0 else {
            onUpdate?(spec)
            return
        }

        // Clamp t to segment range so positions outside the analyzed window
        // (e.g. negative clock, or after the last segment ends) never crash.
        let firstStart = analysis.segments[0].start
        let lastSeg = analysis.segments[segmentCount - 1]
        let lastEnd = lastSeg.start + lastSeg.duration
        let clampedT: Double
        if t < firstStart { clampedT = firstStart }
        else if t >= lastEnd { clampedT = max(firstStart, lastEnd - 0.0001) }
        else { clampedT = t }

        let idx = Self.segmentIndex(segments: analysis.segments, at: clampedT)
        let seg = analysis.segments[idx]
        let nextSeg: SpotifyAudioAnalysis.Segment? = (idx + 1 < segmentCount) ? analysis.segments[idx + 1] : nil

        // --- Envelope -------------------------------------------------------
        let loudnessDb = Self.segmentLoudness(seg: seg, atLocalT: clampedT - seg.start, next: nextSeg)
        // Spec: normalize dB to [0,1] as (loudness + 60) / 60, clamped.
        let envDouble = min(1.0, max(0.0, (loudnessDb + 60.0) / 60.0))
        let env = Float(envDouble)

        // --- Beat envelope (nearest past beat, linear scan) -----------------
        var beatEnvelope: Float = 0
        if beatCount > 0 {
            if let beat = Self.nearestPastBeat(beats: analysis.beats, at: clampedT) {
                let timeSinceBeat = clampedT - beat.start
                let denom = max(beat.duration, 0.2)
                let phase = timeSinceBeat / denom
                // exp(-4 * phase) * confidence
                let decay = Float(exp(-4.0 * phase))
                beatEnvelope = decay * Float(beat.confidence)
                if !beatEnvelope.isFinite { beatEnvelope = 0 }
            }
        }

        // --- Bands ----------------------------------------------------------
        let timbre1 = seg.timbre.count > 1 ? seg.timbre[1] : 0
        let timbre2 = seg.timbre.count > 2 ? seg.timbre[2] : 0

        let bass = Self.clamp01(env * 0.5 + beatEnvelope)
        let mid = Self.clamp01(env * 0.6 + Float(timbre1) * 0.002)
        let treble = Self.clamp01(env * 0.4 + Float(timbre2) * 0.002)
        let beatPulse = Self.clamp01(beatEnvelope)
        spec.bands = Bands(bass: bass, mid: mid, treble: treble, beatPulse: beatPulse)

        // --- Magnitudes (per-bin from 12 chroma pitches) --------------------
        if !seg.pitches.isEmpty {
            let pitchCount = seg.pitches.count
            let envScale = env * 0.8 + beatEnvelope * 0.2
            for b in 0..<binCount {
                // p = b * 12 / binCount, rounded down; clamp to pitches bounds.
                var p = (b * 12) / binCount
                if p >= pitchCount { p = pitchCount - 1 }
                let mag = Float(seg.pitches[p]) * envScale
                spec.magnitudes[b] = mag.isFinite ? mag : 0
            }
        }

        onUpdate?(spec)
    }

    // MARK: - Segment envelope

    /// Piecewise-linear loudness across the segment: rising from
    /// `loudness_start → loudness_max` over [0, loudness_max_time], then falling
    /// to the next segment's loudness_start (or this segment's loudness_start
    /// when no next segment exists) over [loudness_max_time, duration].
    private static func segmentLoudness(seg: SpotifyAudioAnalysis.Segment,
                                        atLocalT localT: Double,
                                        next: SpotifyAudioAnalysis.Segment?) -> Double {
        let maxT = seg.loudness_max_time
        if localT <= maxT {
            // Rising phase. Guard against maxT == 0 where the slope is
            // undefined — treat as already-at-max.
            if maxT <= 0 { return seg.loudness_max }
            let r = max(0.0, min(1.0, localT / maxT))
            return seg.loudness_start + (seg.loudness_max - seg.loudness_start) * r
        }
        // Falling phase.
        let tailDur = max(seg.duration - maxT, 0.0001)
        let endLoud = next?.loudness_start ?? seg.loudness_start
        let r = max(0.0, min(1.0, (localT - maxT) / tailDur))
        return seg.loudness_max + (endLoud - seg.loudness_max) * r
    }

    // MARK: - Lookups

    /// Binary search for the segment whose [start, start+duration) contains t.
    /// Caller must ensure segments array is non-empty.
    private static func segmentIndex(segments: [SpotifyAudioAnalysis.Segment], at t: Double) -> Int {
        var lo = 0
        var hi = segments.count - 1
        while lo <= hi {
            let m = (lo + hi) >> 1
            let s = segments[m]
            if t < s.start { hi = m - 1 }
            else if t >= s.start + s.duration { lo = m + 1 }
            else { return m }
        }
        // If t fell between segments (rare — continuous analysis should not
        // have gaps), snap to the nearest valid index.
        return max(0, min(segments.count - 1, lo))
    }

    /// Linear scan for the nearest beat whose `start <= t`. Beats arrays are
    /// small (<500 for most tracks) so a scan is acceptable per the spec.
    /// Returns nil only when every beat is still in the future.
    private static func nearestPastBeat(beats: [SpotifyAudioAnalysis.Beat], at t: Double) -> SpotifyAudioAnalysis.Beat? {
        var best: SpotifyAudioAnalysis.Beat?
        for b in beats {
            if b.start <= t {
                best = b
            } else {
                break
            }
        }
        return best
    }

    // MARK: - Misc

    @inline(__always)
    private static func clamp01(_ x: Float) -> Float {
        let safe = x.isFinite ? x : 0
        if safe < 0 { return 0 }
        if safe > 1 { return 1 }
        return safe
    }
}
