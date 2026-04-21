import Metal
import MetalKit
import simd

/// Instanced quads sampling a shared atlas texture. State is carried across frames so
/// integrators like `tunnelRot` / `waveSpin` evolve smoothly regardless of audio pulses.
@MainActor
public final class InstancedAtlasRenderer<U, State>: VisualizerRenderer {
    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    private let atlas: MTLTexture
    private let instanceCount: Int
    private var state: State
    private let step: (inout State, AudioFrame, Float, SIMD2<Float>) -> U
    private var lastTime: Float = -1

    public init(context: MetalContext,
                pixelFormat: MTLPixelFormat,
                vertexFunction: String,
                fragmentFunction: String,
                atlas: MTLTexture,
                instanceCount: Int,
                label: String,
                initialState: State,
                step: @escaping (inout State, AudioFrame, Float, SIMD2<Float>) -> U) throws {
        self.context = context
        self.atlas = atlas
        self.instanceCount = instanceCount
        self.state = initialState
        self.step = step

        guard let vertex = context.library.makeFunction(name: vertexFunction),
              let fragment = context.library.makeFunction(name: fragmentFunction) else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = label
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
        let dt: Float = lastTime < 0
            ? 1.0 / 60.0
            : min(0.1, max(0.001, audio.time - lastTime))
        lastTime = audio.time

        let ds = view.drawableSize
        let res = SIMD2<Float>(Float(ds.width), Float(ds.height))
        var u = step(&state, audio, dt, res)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = context.commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        enc.label = pipeline.label
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(atlas, index: 0)

        withUnsafeBytes(of: &u) { bytes in
            if let base = bytes.baseAddress {
                enc.setVertexBytes(base, length: bytes.count, index: 0)
                enc.setFragmentBytes(base, length: bytes.count, index: 0)
            }
        }
        audio.bassHistory.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                enc.setVertexBytes(base, length: raw.count, index: 1)
                enc.setFragmentBytes(base, length: raw.count, index: 1)
            }
        }

        enc.drawPrimitives(type: .triangleStrip,
                           vertexStart: 0,
                           vertexCount: 4,
                           instanceCount: instanceCount)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }
}
