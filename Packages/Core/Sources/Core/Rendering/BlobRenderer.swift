import Metal
import MetalKit
import simd

public struct BlobUniforms {
    public var time: Float = 0
    public var audio: Float = 0
    public var resolution: SIMD2<Float> = .zero
}

public final class BlobRenderer {
    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState

    public init(context: MetalContext, pixelFormat: MTLPixelFormat) throws {
        self.context = context

        guard let vertex = context.library.makeFunction(name: "blob_vs"),
              let fragment = context.library.makeFunction(name: "blob_fs") else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Blob"
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = pixelFormat
        self.pipeline = try context.device.makeRenderPipelineState(descriptor: desc)
    }

    public func draw(in view: MTKView, uniforms: BlobUniforms) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        encoder.label = "Blob pass"
        encoder.setRenderPipelineState(pipeline)

        var u = uniforms
        encoder.setFragmentBytes(&u,
                                 length: MemoryLayout<BlobUniforms>.stride,
                                 index: 0)

        // Fullscreen triangle (3 vertices; shader derives positions from vertex_id)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
