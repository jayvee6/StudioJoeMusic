import AVFoundation
import Accelerate

public final class FFTCore: @unchecked Sendable {
    public let fftSize: Int
    public let binCount: Int

    private let log2N: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]

    // Hoisted scratch buffers — allocated once in init(), reused every process() call.
    // Sizes: samples=fftSize, real/imag/mags=fftSize/2, binned=binCount.
    private var samples: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var binned: [Float]

    // Mel-scale bin boundaries, precomputed at init. Size = binCount + 1,
    // each entry is an index into the FFT magnitude array (0 ..< fftSize/2).
    private let melBoundaries: [Int]

    // Perceptual gain curve: boosts high-frequency bins to compensate for
    // mel-scale bass concentration and typical music's bass-heavy amplitude.
    // Computed once at init, applied per-frame in process() BEFORE AGC so
    // the boosted signal shapes the peakFloor envelope.
    // gain[b] = 1.0 + pow(normalized_position, 1.3) * 2.5
    // At b=0 -> 1.0x, at b=binCount/2 -> ~2.0x, at b=binCount-1 -> ~3.5x.
    private let binGain: [Float]

    // Exponential-decay peak tracker for AGC normalization. Persists across frames.
    // Decays at ~0.995/frame (≈3 s half-life at 86 fps) so the floor drops slowly
    // when input goes quiet; jumps instantly to new peaks.
    private var peakFloor: Float = 0.0001

    // Per-bin adaptive noise floor for spectral subtraction. Tracks the rolling
    // minimum of each bin over ~20-30 s: fast descent to capture quiet moments,
    // very slow relaxation up so the floor doesn't stick to a single past dip.
    // The gate is meaningful when the input is the microphone (room noise vs.
    // music); for clean file-mixer input the floor stays near zero and the
    // subtraction is a no-op.
    private var noiseFloor: [Float]

    public init(fftSize: Int = 2048, binCount: Int = 32) {
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

        let halfN = fftSize / 2
        self.samples = [Float](repeating: 0, count: fftSize)
        self.real = [Float](repeating: 0, count: halfN)
        self.imag = [Float](repeating: 0, count: halfN)
        self.mags = [Float](repeating: 0, count: halfN)
        self.binned = [Float](repeating: 0, count: binCount)

        self.melBoundaries = FFTCore.computeMelBoundaries(fftSize: fftSize,
                                                          binCount: binCount)
        self.binGain = FFTCore.computeBinGain(binCount: binCount)
        // Initialize high so the first few frames aren't gated — the gate
        // activates only after the tracker has seen some quiet bins.
        self.noiseFloor = [Float](repeating: 0.01, count: binCount)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    public func process(_ buffer: AVAudioPCMBuffer) -> Spectrum? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let n = min(frameCount, fftSize)
        guard n > 0 else { return nil }

        let halfN = fftSize / 2

        // Refill `samples` in place: memcpy n fresh frames, memset the tail to zero.
        samples.withUnsafeMutableBufferPointer { dest in
            let base = dest.baseAddress!
            _ = memcpy(base, channelData[0], n * MemoryLayout<Float>.size)
            if n < fftSize {
                memset(base + n, 0, (fftSize - n) * MemoryLayout<Float>.size)
            }
        }

        vDSP_vmul(samples, 1, window, 1, &samples, 1, vDSP_Length(fftSize))

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

        // Mel-scale bin mapping — replaces squared-linear.
        // Preserves existing sqrt ordering: sqrt the per-bin average, then AGC-normalize.
        mags.withUnsafeBufferPointer { mPtr in
            for b in 0..<binCount {
                let lo = melBoundaries[b]
                let hi = max(lo + 1, melBoundaries[b + 1])
                var avg: Float = 0
                vDSP_meanv(mPtr.baseAddress! + lo, 1, &avg, vDSP_Length(hi - lo))
                binned[b] = sqrtf(avg)
            }
        }

        // Apply perceptual gain curve — treble gets a progressive boost so high bins
        // carry visible amplitude in typical (bass-heavy) music. Must run BEFORE the
        // peakFloor / AGC normalization so the boosted signal shapes the envelope.
        binned.withUnsafeMutableBufferPointer { bPtr in
            binGain.withUnsafeBufferPointer { gPtr in
                vDSP_vmul(bPtr.baseAddress!, 1, gPtr.baseAddress!, 1,
                          bPtr.baseAddress!, 1, vDSP_Length(binCount))
            }
        }

        // Adaptive noise gate — spectral subtraction with per-bin minimum
        // tracking. Strong descent (v=binned[b] < floor → learn over ~5
        // frames) captures quiet moments; gentle relaxation (×1.00005/frame
        // ≈ 0.4%/sec at 86fps) keeps the floor from sticking. 1.8x
        // over-subtraction multiplier gives a clear margin so music clearly
        // above ambient stays intact while persistent noise gets zeroed.
        for b in 0..<binCount {
            let v = binned[b]
            if v < noiseFloor[b] {
                noiseFloor[b] = v * 0.2 + noiseFloor[b] * 0.8
            } else {
                noiseFloor[b] *= 1.00005
            }
            let gated = v - noiseFloor[b] * 1.8
            binned[b] = gated > 0 ? gated : 0
        }

        // Exponential peak AGC — replaces per-frame max normalization.
        // Instant rise to new peaks; slow decay (~3 s half-life at 86 fps) when quiet.
        var bufferMax: Float = 0
        vDSP_maxv(binned, 1, &bufferMax, vDSP_Length(binCount))
        peakFloor = max(bufferMax, peakFloor * 0.995)
        var inv: Float = 1.0 / max(peakFloor, 0.0001)
        vDSP_vsmul(binned, 1, &inv, &binned, 1, vDSP_Length(binCount))

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

    // MARK: - Mel-scale helpers

    private static func computeMelBoundaries(fftSize: Int,
                                             binCount: Int,
                                             sampleRate: Float = 44100) -> [Int] {
        let nyquistHz = sampleRate / 2
        let melMin = hzToMel(0)
        let melMax = hzToMel(nyquistHz)
        var bounds: [Int] = []
        bounds.reserveCapacity(binCount + 1)
        let halfN = fftSize / 2
        for i in 0...binCount {
            let mel = melMin + (melMax - melMin) * Float(i) / Float(binCount)
            let hz = melToHz(mel)
            let idx = min(halfN, max(0, Int(hz / sampleRate * Float(fftSize))))
            bounds.append(idx)
        }
        // Guarantee strictly increasing boundaries so each bin averages ≥1 FFT bin.
        for i in 1...binCount {
            if bounds[i] <= bounds[i - 1] {
                bounds[i] = min(halfN, bounds[i - 1] + 1)
            }
        }
        return bounds
    }

    private static func hzToMel(_ hz: Float) -> Float {
        2595.0 * log10f(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Float) -> Float {
        700.0 * (powf(10.0, mel / 2595.0) - 1.0)
    }

    // MARK: - Perceptual gain helpers

    private static func computeBinGain(binCount: Int) -> [Float] {
        var gains = [Float](repeating: 1.0, count: binCount)
        for b in 0..<binCount {
            let t = Float(b) / Float(max(1, binCount - 1))
            gains[b] = 1.0 + powf(t, 1.3) * 2.5
        }
        return gains
    }
}
