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
        let file = try AVAudioFile(forReading: previewURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        let previewDurationSec = max(0.01, Double(totalFrames) / sampleRate)

        let fftFrames: AVAudioFrameCount = 2048
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

        let previewSegments = aggregateSegments(frames: frames,
                                                targetSegDurSec: 0.2,
                                                binCount: binCount)

        // Loop preview segments across full track duration.
        var fullSegments: [SpotifyAudioAnalysis.Segment] = []
        if !previewSegments.isEmpty {
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
        }

        // Beats: full-duration grid at detected BPM.
        let detectedBPM: Double = {
            let probe = bpm.ingest(bass: 0, atHostTimeSec: previewDurationSec)
            if probe.bpm > 40 && probe.bpm < 240 { return probe.bpm }
            if let hint = bpmHint, hint > 40, hint < 240 { return hint }
            return 120
        }()
        let interval = 60.0 / detectedBPM
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

        let meanLoudness: Double = {
            guard !previewSegments.isEmpty else { return -20.0 }
            let sum = previewSegments.reduce(0.0) { $0 + $1.loudness_max }
            return sum / Double(previewSegments.count)
        }()

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

    private struct FrameSnapshot {
        let t: Double
        let bass: Float
        let mags: [Float]
    }

    private static func aggregateSegments(frames: [FrameSnapshot],
                                          targetSegDurSec: Double,
                                          binCount: Int) -> [SpotifyAudioAnalysis.Segment] {
        guard !frames.isEmpty else { return [] }
        var segments: [SpotifyAudioAnalysis.Segment] = []
        segments.reserveCapacity(frames.count / 4 + 1)

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

            // 12-chroma pitches: average bin energy per chroma slot.
            var pitchSum: [Double] = Array(repeating: 0, count: 12)
            var pitchCount: [Int] = Array(repeating: 0, count: 12)
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

    // FFTCore output is AGC-normalized linear [0, 1]. Map to a dB-ish range
    // [-60, 0] that matches Spotify's loudness scale — `SyntheticAnalysisDriver`
    // normalizes via `(loudness + 60) / 60`, so quiet → 0 env, loud → 1 env.
    private static func dbFromLinear(_ linear: Float) -> Double {
        let safe = max(0, min(1, linear))
        return -60.0 + Double(safe) * 60.0
    }
}
