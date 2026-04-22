import Metal
import MetalKit
import simd

public struct CosmicWaveUniforms {
    public var time: Float = 0
    public var bass: Float = 0
    public var mid: Float = 0
    public var treble: Float = 0
    public var spinAngle: Float = 0     // CPU-accumulated colour-spectrum rotation
    // Explicit 4-byte pad — Metal aligns float2 to 8 bytes; after 5 floats (20 bytes)
    // the next 8-byte boundary is 24, so one float pad is required.
    public var _pad0: UInt32 = 0
    public var resolution: SIMD2<Float> = .zero
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120
}

@MainActor
public final class CosmicWaveRenderer: VisualizerRenderer {
    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    private var smoothedMags: [Float]
    private var spinAngle: Float = 0
    private var lastTime: Float = 0

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
        let dt     = min(0.1, max(0.001, audio.time - lastTime))
        lastTime   = audio.time
        let normDt = min(2.5, dt * 60.0)

        // Smooth the 32-bin FFT magnitudes to prevent jitter
        let alpha: Float = 0.35
        let src = audio.magnitudes
        for i in 0..<min(32, src.count) {
            smoothedMags[i] = smoothedMags[i] * (1.0 - alpha) + src[i] * alpha
        }

        // Slow spin, bass nudges speed
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
