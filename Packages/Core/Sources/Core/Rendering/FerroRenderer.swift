import Metal
import MetalKit
import simd

public struct FerroUniforms {
    public var time: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var spikeCount: Int32 = 32
    public var resolution: SIMD2<Float> = .zero
}

@MainActor
public final class FerroRenderer: VisualizerRenderer {
    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    public let spikeCount: Int

    private var heights: [Float]
    private var velocities: [Float]
    private var lastTime: Float = 0

    // Tunables
    public var stiffness: Float = 38.0
    public var damping: Float = 0.86
    public var maxDt: Float = 1.0 / 30.0

    public init(context: MetalContext,
                pixelFormat: MTLPixelFormat,
                spikeCount: Int = 32) throws {
        self.context = context
        self.spikeCount = spikeCount
        self.heights = Array(repeating: 0, count: spikeCount)
        self.velocities = Array(repeating: 0, count: spikeCount)

        guard let vertex = context.library.makeFunction(name: "ferrofluid_vs"),
              let fragment = context.library.makeFunction(name: "ferrofluid_fs") else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Ferrofluid"
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try context.device.makeRenderPipelineState(descriptor: desc)
    }

    public func draw(in view: MTKView, audio: AudioFrame) {
        // Integrate spring dynamics — targets come from FFT magnitudes
        let dt = min(maxDt, max(0.001, audio.time - lastTime))
        lastTime = audio.time

        let bassBoost: Float = 1.0 + audio.bass * 0.6
        let k: Float = stiffness * bassBoost
        let d: Float = damping

        let targets = audio.magnitudes
        for i in 0..<spikeCount {
            let t = i < targets.count ? targets[i] : 0
            let force = (t - heights[i]) * k
            velocities[i] = velocities[i] * d + force * dt
            heights[i] = max(0.0, heights[i] + velocities[i] * dt)
        }

        let ds = view.drawableSize
        let res = SIMD2<Float>(Float(ds.width), Float(ds.height))
        var u = FerroUniforms(
            time: audio.time,
            bass: audio.bass,
            treble: audio.treble,
            spikeCount: Int32(spikeCount),
            resolution: res
        )

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = context.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        enc.label = pipeline.label
        enc.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &u) { bytes in
            if let base = bytes.baseAddress {
                enc.setFragmentBytes(base, length: bytes.count, index: 0)
            }
        }
        heights.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                enc.setFragmentBytes(base,
                                     length: raw.count,
                                     index: 1)
            }
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }
}
