import AVFoundation
import Accelerate

public final class FFTCore: @unchecked Sendable {
    public let fftSize: Int
    public let binCount: Int

    private let log2N: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]

    public init(fftSize: Int = 1024, binCount: Int = 32) {
        precondition(fftSize > 0 && (fftSize & (fftSize - 1)) == 0,
                     "fftSize must be a power of 2")
        self.fftSize = fftSize
        self.binCount = binCount
        self.log2N = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        self.fftSetup = setup
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = w
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    public func process(_ buffer: AVAudioPCMBuffer) -> Spectrum? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let n = min(frameCount, fftSize)
        guard n > 0 else { return nil }

        var samples = [Float](repeating: 0, count: fftSize)
        samples.withUnsafeMutableBufferPointer { dest in
            _ = memcpy(dest.baseAddress!, channelData[0], n * MemoryLayout<Float>.size)
        }

        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

        let halfN = fftSize / 2
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        var mags = [Float](repeating: 0, count: halfN)

        real.withUnsafeMutableBufferPointer { rPtr in
            imag.withUnsafeMutableBufferPointer { iPtr in
                var split = DSPSplitComplex(realp: rPtr.baseAddress!,
                                            imagp: iPtr.baseAddress!)
                samples.withUnsafeBufferPointer { sPtr in
                    sPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                        capacity: halfN) { cPtr in
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2N, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))
            }
        }

        var scale: Float = 1.0 / Float(fftSize)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(halfN))

        var binned = [Float](repeating: 0, count: binCount)
        mags.withUnsafeBufferPointer { mPtr in
            for b in 0..<binCount {
                let t0 = Float(b) / Float(binCount)
                let t1 = Float(b + 1) / Float(binCount)
                let lo = min(halfN - 1, Int(Float(halfN) * t0 * t0))
                let hi = min(halfN, max(lo + 1, Int(Float(halfN) * t1 * t1)))
                var avg: Float = 0
                vDSP_meanv(mPtr.baseAddress! + lo, 1, &avg, vDSP_Length(hi - lo))
                binned[b] = sqrtf(avg)
            }
        }

        var maxV: Float = 0
        vDSP_maxv(binned, 1, &maxV, vDSP_Length(binCount))
        if maxV > 0.0001 {
            var inv = 1.0 / maxV
            vDSP_vsmul(binned, 1, &inv, &binned, 1, vDSP_Length(binCount))
        }

        let bassEnd = max(1, binCount / 10)
        let midEnd  = max(bassEnd + 1, (binCount * 45) / 100)
        let bass   = mean(binned, lo: 0,       hi: bassEnd)
        let mid    = mean(binned, lo: bassEnd, hi: midEnd)
        let treble = mean(binned, lo: midEnd,  hi: binCount)

        var spec = Spectrum(binCount: binCount)
        spec.magnitudes = binned
        spec.bands = Bands(bass: bass, mid: mid, treble: treble, beatPulse: 0)
        spec.sampleHostTimeSec = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        return spec
    }

    private func mean(_ a: [Float], lo: Int, hi: Int) -> Float {
        guard hi > lo else { return 0 }
        var m: Float = 0
        a.withUnsafeBufferPointer {
            vDSP_meanv($0.baseAddress! + lo, 1, &m, vDSP_Length(hi - lo))
        }
        return m
    }
}
