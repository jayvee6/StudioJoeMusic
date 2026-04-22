import AVFoundation
import Foundation
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "PreviewAnalyzer")

/// Offline analysis of a short audio clip (typically the 30-second Apple Music
/// preview) into a full-duration `SpotifyAudioAnalysis`, so the existing
/// `SyntheticAnalysisDriver` can drive visuals for DRM tracks that have no
/// live audio tap and no Spotify analysis match.
///
/// Preview segments are looped across `trackDurationSec`; beats are regenerated
/// at the detected BPM over the whole track (not looped — a constant beat grid
/// sounds better than stuttering every 30 s).
public enum PreviewAnalyzer {
    public static func analyze(previewURL: URL,
                               trackDurationSec: Double,
                               bpmHint: Double?,
                               binCount: Int = 32) throws -> SpotifyAudioAnalysis {
        // Phase 1: read + FFT the preview clip.
        let (frames, bpmDetector, previewDurationSec) = try readPreviewFrames(
            url: previewURL,
            fftFrames: 2048,
            binCount: binCount
        )

        // Phase 2: aggregate into per-segment summaries, then loop across
        // the full track duration.
        let previewSegments = aggregateSegments(frames: frames,
                                                targetSegDurSec: 0.2,
                                                binCount: binCount)
        let fullSegments = synthesizeFullDurationSegments(
            previewSegments: previewSegments,
            previewDurationSec: previewDurationSec,
            trackDurationSec: trackDurationSec
        )

        // Phase 3: resolve BPM (live detection → hint → default) and lay a
        // full-duration beat grid at that tempo.
        let detectedBPM = resolveBPM(
            detector: bpmDetector,
            previewDurationSec: previewDurationSec,
            hint: bpmHint
        )
        let beats = synthesizeBeats(bpm: detectedBPM, trackDurationSec: trackDurationSec)

        // Phase 4: assemble track + sections envelope.
        let meanLoudness: Double = previewSegments.isEmpty
            ? -20.0
            : previewSegments.reduce(0.0) { $0 + $1.loudness_max } / Double(previewSegments.count)

        let track = SpotifyAudioAnalysis.Track(
            tempo: detectedBPM,
            duration: trackDurationSec,
            time_signature: 4,
            loudness: meanLoudness
        )
        let sections = [
            SpotifyAudioAnalysis.Section(
                start: 0,
                duration: trackDurationSec,
                loudness: meanLoudness,
                tempo: detectedBPM
            )
        ]

        log.info("Analyzed preview (\(previewDurationSec, privacy: .public)s) → segments=\(fullSegments.count, privacy: .public) beats=\(beats.count, privacy: .public) BPM=\(detectedBPM, privacy: .public) across \(trackDurationSec, privacy: .public)s")

        return SpotifyAudioAnalysis(
            track: track,
            sections: sections,
            segments: fullSegments,
            beats: beats,
            tatums: [],
            bars: []
        )
    }

    // MARK: - Phase 1: preview read + FFT

    private struct FrameSnapshot {
        let t: Double
        let bass: Float
        let mags: [Float]
    }

    private static func readPreviewFrames(
        url: URL,
        fftFrames: AVAudioFrameCount,
        binCount: Int
    ) throws -> (frames: [FrameSnapshot], bpmDetector: OnsetBPMDetector, previewDurationSec: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        let previewDurationSec = max(0.01, Double(totalFrames) / sampleRate)

        let fft = FFTCore(fftSize: Int(fftFrames), binCount: binCount)
        let bpm = OnsetBPMDetector()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: fftFrames) else {
            throw NSError(domain: "PreviewAnalyzer", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate PCM buffer"])
        }

        let estFrames = Int(previewDurationSec * sampleRate / Double(fftFrames)) + 1
        var frames: [FrameSnapshot] = []
        frames.reserveCapacity(estFrames)

        var cursor: AVAudioFramePosition = 0
        while cursor < totalFrames {
            file.framePosition = cursor
            let remaining = min(AVAudioFrameCount(totalFrames - cursor), fftFrames)
            try file.read(into: buffer, frameCount: remaining)
            if buffer.frameLength == 0 { break }

            if let spec = fft.process(buffer) {
                let t = Double(cursor) / sampleRate
                frames.append(FrameSnapshot(t: t, bass: spec.bands.bass, mags: spec.magnitudes))
                _ = bpm.ingest(bass: spec.bands.bass, atHostTimeSec: t)
            }
            cursor += AVAudioFramePosition(buffer.frameLength)
        }

        return (frames, bpm, previewDurationSec)
    }

    // MARK: - Phase 2: segment aggregation + full-duration loop

    private static func aggregateSegments(frames: [FrameSnapshot],
                                          targetSegDurSec: Double,
                                          binCount: Int) -> [SpotifyAudioAnalysis.Segment] {
        guard !frames.isEmpty else { return [] }
        var segments: [SpotifyAudioAnalysis.Segment] = []
        segments.reserveCapacity(frames.count / 4 + 1)

        // Hoisted out of the segment loop — we zero these at the top of each
        // iteration instead of reallocating. ~150 throwaway heap allocs per
        // analysis become zero.
        var pitchSum: [Double] = Array(repeating: 0, count: 12)
        var pitchCount: [Int] = Array(repeating: 0, count: 12)

        var i = 0
        while i < frames.count {
            let segStartT = frames[i].t
            let segEndT = segStartT + targetSegDurSec
            var j = i + 1
            while j < frames.count && frames[j].t < segEndT { j += 1 }

            let startBass = dbFromLinear(frames[i].bass)
            var maxDb = startBass
            var maxRelTime: Double = 0
            for k in i..<j {
                let db = dbFromLinear(frames[k].bass)
                if db > maxDb {
                    maxDb = db
                    maxRelTime = frames[k].t - segStartT
                }
            }

            // Zero pitch accumulators for this segment.
            for k in 0..<12 {
                pitchSum[k] = 0
                pitchCount[k] = 0
            }
            // 12-chroma pitches: average bin energy per chroma slot.
            for k in i..<j {
                let m = frames[k].mags
                for b in 0..<m.count {
                    let p = min(11, (b * 12) / max(1, binCount))
                    pitchSum[p] += Double(m[b])
                    pitchCount[p] += 1
                }
            }
            var pitches: [Double] = Array(repeating: 0, count: 12)
            for p in 0..<12 where pitchCount[p] > 0 {
                let v = pitchSum[p] / Double(pitchCount[p])
                pitches[p] = min(1.0, max(0.0, v))
            }

            let segDur: Double = {
                if j < frames.count {
                    return frames[j].t - segStartT
                }
                return targetSegDurSec
            }()

            segments.append(SpotifyAudioAnalysis.Segment(
                start: segStartT,
                duration: max(0.01, segDur),
                loudness_start: startBass,
                loudness_max: maxDb,
                loudness_max_time: max(0, maxRelTime),
                pitches: pitches,
                timbre: []
            ))
            i = j
        }
        return segments
    }

    private static func synthesizeFullDurationSegments(
        previewSegments: [SpotifyAudioAnalysis.Segment],
        previewDurationSec: Double,
        trackDurationSec: Double
    ) -> [SpotifyAudioAnalysis.Segment] {
        guard !previewSegments.isEmpty else { return [] }
        var fullSegments: [SpotifyAudioAnalysis.Segment] = []
        var loopIdx = 0
        outer: while true {
            let shift = Double(loopIdx) * previewDurationSec
            if shift >= trackDurationSec { break }
            for seg in previewSegments {
                let shiftedStart = seg.start + shift
                if shiftedStart >= trackDurationSec { break outer }
                let remainingDur = trackDurationSec - shiftedStart
                let clampedDur = min(seg.duration, remainingDur)
                fullSegments.append(SpotifyAudioAnalysis.Segment(
                    start: shiftedStart,
                    duration: clampedDur,
                    loudness_start: seg.loudness_start,
                    loudness_max: seg.loudness_max,
                    loudness_max_time: min(seg.loudness_max_time, clampedDur),
                    pitches: seg.pitches,
                    timbre: seg.timbre
                ))
            }
            loopIdx += 1
            if loopIdx > 10_000 { break }
        }
        return fullSegments
    }

    // MARK: - Phase 3: BPM resolution + beat grid

    private static func resolveBPM(
        detector: OnsetBPMDetector,
        previewDurationSec: Double,
        hint: Double?
    ) -> Double {
        let probe = detector.ingest(bass: 0, atHostTimeSec: previewDurationSec)
        if probe.bpm > 40 && probe.bpm < 240 { return probe.bpm }
        if let h = hint, h > 40, h < 240 { return h }
        return 120
    }

    private static func synthesizeBeats(
        bpm: Double,
        trackDurationSec: Double
    ) -> [SpotifyAudioAnalysis.Beat] {
        let interval = 60.0 / bpm
        var beats: [SpotifyAudioAnalysis.Beat] = []
        beats.reserveCapacity(Int(trackDurationSec / interval) + 1)
        var t: Double = 0
        while t < trackDurationSec {
            beats.append(SpotifyAudioAnalysis.Beat(
                start: t,
                duration: interval,
                confidence: 0.75
            ))
            t += interval
        }
        return beats
    }

    // MARK: - Helpers

    /// FFTCore output is AGC-normalized linear [0, 1]. Map to a dB-ish range
    /// [-60, 0] that matches Spotify's loudness scale — `SyntheticAnalysisDriver`
    /// normalizes via `(loudness + 60) / 60`, so quiet → 0 env, loud → 1 env.
    private static func dbFromLinear(_ linear: Float) -> Double {
        let safe = max(0, min(1, linear))
        return -60.0 + Double(safe) * 60.0
    }
}
