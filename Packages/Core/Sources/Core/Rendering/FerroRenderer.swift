import Metal
import MetalKit
import simd

public struct FerroUniforms {
    public var time: Float = 0
    public var hue: Float = 0          // CPU-accumulated fluidHue, 0..1
    public var bass: Float = 0
    public var treble: Float = 0
    public var spikeCount: Int32 = 48
    public var resolution: SIMD2<Float> = .zero
}

@MainActor
public final class FerroRenderer: VisualizerRenderer {
    public let spikeCount: Int = 48

    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    private var heights: [Float]
    private var velocities: [Float]
    private var lastTime: Float = 0
    private var fluidHue: Float = 0    // 0..1; web: += 0.06 + bass*1.8 per frame (degrees)

    // Matches web spec: k = stiffness * (0.12 + bass * 2.8); damp = 0.60 - bass * 0.46.
    public var stiffness: Float = 0.95
    public var damping: Float = 0.60
    public var maxDt: Float = 1.0 / 24.0

    public init(context: MetalContext,
                pixelFormat: MTLPixelFormat) throws {
        self.context = context
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
        let dt = min(maxDt, max(0.001, audio.time - lastTime))
        lastTime = audio.time
        let normDt = min(2.5, dt * 60.0)   // normalize spring step to 60fps equivalent

        // Map our 32-bin FFT magnitudes onto 48 spike targets (linear interpolation).
        // Our magnitudes are already log-weighted at FFT time (quadratic bin mapping),
        // so linear oversampling here is enough to spread them across 48 spikes.
        var targets = [Float](repeating: 0, count: spikeCount)
        let src = audio.magnitudes
        if src.count >= 2 {
            let srcMax = src.count - 1
            for i in 0..<spikeCount {
                let f = Float(i) / Float(spikeCount - 1) * Float(srcMax)
                let lo = min(srcMax, Int(f))
                let hi = min(srcMax, lo + 1)
                let t = f - Float(lo)
                targets[i] = src[lo] * (1 - t) + src[hi] * t
            }
        }

        // Idle shimmer so the pool isn't frozen between tracks.
        let now = audio.time
        for i in 0..<spikeCount {
            let idle: Float = 0.04 * (0.4 + 0.6 * sin(now * 0.7 + Float(i) * 0.52))
            targets[i] = max(targets[i], idle)
        }

        // Spring / damper per web spec. Velocity integration dt-scaled.
        let k = stiffness * (0.12 + audio.bass * 2.8)
        let damp = max(0.04, damping - audio.bass * 0.46)
        for i in 0..<spikeCount {
            let force = (targets[i] - heights[i]) * k
            velocities[i] = velocities[i] * (1.0 - damp * normDt) + force * normDt
            heights[i] = max(0.0, heights[i] + velocities[i] * normDt)
        }

        // Hue drift + bass kick snap — matches web's fluidHue += 0.06 + bass*1.8 deg/frame.
        fluidHue += (0.06 + audio.bass * 1.8) * normDt / 360.0
        fluidHue -= floor(fluidHue)

        let ds = view.drawableSize
        let res = SIMD2<Float>(Float(ds.width), Float(ds.height))
        var u = FerroUniforms(
            time: audio.time,
            hue: fluidHue,
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
                enc.setFragmentBytes(base, length: raw.count, index: 1)
            }
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }
}
