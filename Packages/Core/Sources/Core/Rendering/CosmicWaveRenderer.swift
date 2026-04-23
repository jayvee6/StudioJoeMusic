import Metal
import MetalKit
import simd

// Uniforms (48 bytes — layout-compatible with Metal CosmicWaveUniforms):
//   [0..3]   time         float
//   [4..7]   bass         float
//   [8..11]  mid          float
//   [12..15] treble       float
//   [16..19] spinAngle    float
//   [20..23] _pad0        UInt32  ← explicit pad; aligns float2 to 8-byte boundary at 24
//   [24..31] resolution   SIMD2<Float>
//   [32..35] valence      float
//   [36..39] energy       float
//   [40..43] danceability float
//   [44..47] tempoBPM     float
public struct CosmicWaveUniforms {
    public var time: Float = 0
    public var bass: Float = 0
    public var mid: Float = 0
    public var treble: Float = 0
    public var spinAngle: Float = 0
    public var _pad0: UInt32 = 0
    public var resolution: SIMD2<Float> = .zero
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120

    public init(time: Float, bass: Float, mid: Float, treble: Float,
                spinAngle: Float, resolution: SIMD2<Float>,
                valence: Float, energy: Float, danceability: Float, tempoBPM: Float) {
        self.time = time; self.bass = bass; self.mid = mid; self.treble = treble
        self.spinAngle = spinAngle; self._pad0 = 0; self.resolution = resolution
        self.valence = valence; self.energy = energy
        self.danceability = danceability; self.tempoBPM = tempoBPM
    }
}

@MainActor
public final class CosmicWaveRenderer: VisualizerRenderer {
    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    private var smoothedMags: [Float]       // EMA-smoothed 32-bin FFT
    private var spinAngle: Float = 0
    private var lastTime: Float = -1

    private let binCount: Int = 32
    private let magAlpha: Float = 0.35      // EMA factor — balances reactivity vs. jitter

    public init(context: MetalContext, pixelFormat: MTLPixelFormat) throws {
        self.context = context
        self.smoothedMags = Array(repeating: 0, count: 32)

        guard let vertex   = context.library.makeFunction(name: "cosmicwave_vs"),
              let fragment = context.library.makeFunction(name: "cosmicwave_fs") else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "CosmicWave"
        desc.vertexFunction   = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = pixelFormat
        self.pipeline = try context.device.makeRenderPipelineState(descriptor: desc)
    }

    public func draw(in view: MTKView, audio: AudioFrame) {
        let dt     = lastTime < 0 ? 1.0 / 60.0 : min(0.1, max(0.001, audio.time - lastTime))
        lastTime   = audio.time
        let normDt = min(2.5, dt * 60.0)

        // EMA-smooth FFT magnitudes to suppress per-frame jitter
        let src = audio.magnitudes
        for i in 0..<binCount {
            let raw = i < src.count ? src[i] : 0.0
            smoothedMags[i] = smoothedMags[i] * (1.0 - magAlpha) + raw * magAlpha
        }

        // Slow global ring spin; bass nudges speed
        spinAngle += (0.006 + audio.bass * 0.018) * normDt

        let ds  = view.drawableSize
        let res = SIMD2<Float>(Float(ds.width), Float(ds.height))
        var u   = CosmicWaveUniforms(
            time:         audio.time,
            bass:         audio.bass,
            mid:          audio.mid,
            treble:       audio.treble,
            spinAngle:    spinAngle,
            resolution:   res,
            valence:      audio.valence,
            energy:       audio.energy,
            danceability: audio.danceability,
            tempoBPM:     audio.tempoBPM
        )

        guard let drawable = view.currentDrawable,
              let pass     = view.currentRenderPassDescriptor,
              let cmd      = context.commandQueue.makeCommandBuffer(),
              let enc      = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        enc.label = pipeline.label
        enc.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &u) { bytes in
            if let base = bytes.baseAddress {
                enc.setFragmentBytes(base, length: bytes.count, index: 0)
            }
        }
        smoothedMags.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                enc.setFragmentBytes(base, length: raw.count, index: 1)
            }
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
