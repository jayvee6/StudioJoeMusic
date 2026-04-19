import XCTest
import AVFoundation
@testable import Core

final class FFTCoreTests: XCTestCase {
    func testProcessSineWaveProducesNonZeroBass() throws {
        let fft = FFTCore(fftSize: 1024, binCount: 32)
        let sr: Double = 44100
        let freq: Double = 80
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1024)!
        buf.frameLength = 1024
        let ptr = buf.floatChannelData![0]
        for i in 0..<1024 {
            ptr[i] = Float(sin(2.0 * .pi * freq * Double(i) / sr))
        }
        let spec = fft.process(buf)
        XCTAssertNotNil(spec)
        XCTAssertGreaterThan(spec!.bands.bass, 0.01)
    }

    func testOnsetDetectorEmitsBPMOnSteadyBeats() {
        let det = OnsetBPMDetector()
        var t: Double = 0
        let period: Double = 0.5  // 120 BPM
        var bass: Float = 0
        for step in 0..<256 {
            bass = (step % 22 == 0) ? 0.9 : 0.05
            _ = det.ingest(bass: bass, atHostTimeSec: t)
            t += 0.0232  // ~43 Hz — approximates buffer rate
        }
        let res = det.ingest(bass: 0.9, atHostTimeSec: t)
        XCTAssertGreaterThan(res.bpm, 80)
        XCTAssertLessThan(res.bpm, 160)
    }
}
