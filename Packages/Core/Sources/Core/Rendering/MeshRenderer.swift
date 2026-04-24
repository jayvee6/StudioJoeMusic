import Metal
import MetalKit
import simd

/// Generic vertex+fragment mesh renderer. Mirrors `FragmentRenderer<U, State>` but
/// for visualizers that need geometry (a vertex buffer) rather than a fullscreen-quad
/// 3-vertex triangle. First non-quad Metal viz template in the project — intended
/// for wire-frame terrains, 3D blob meshes, or any future mesh-displacement viz.
///
/// Differences from `FragmentRenderer`:
///   • Takes caller-supplied `vertexData` (populated once; immutable after construction).
///   • Creates an MTLBuffer for vertex storage and a depth texture for proper mesh
///     rendering with fog / occlusion.
///   • Issues `drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: N)` instead
///     of the 3-vertex fullscreen-quad trick.
///   • Binds the uniform struct `U` to BOTH the vertex stage (index 0) and the fragment
///     stage (index 0) so shaders at either stage can read camera matrices, audio, etc.
///
/// The caller packs projection matrix (float4x4) + view matrix (float4x4) into their
/// `U` struct alongside audio fields — we intentionally do not split into two uniform
/// structs because every caller would have to define two of them. Same rationale as
/// `FragmentRenderer`: one uniform struct per viz.
///
/// `State` is per-frame mutable state (orbit angle, clock accumulator, etc.) owned by
/// the renderer; `step` integrates that state with the current audio frame and produces
/// `U`, the shader uniforms.
@MainActor
public final class MeshRenderer<U, State>: VisualizerRenderer {
    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let depthFormat: MTLPixelFormat
    private let vertexBuffer: MTLBuffer
    private let vertexCount: Int
    private let triangleFillMode: MTLTriangleFillMode
    private var depthTexture: MTLTexture?
    private var state: State
    private let step: (inout State, AudioFrame, Float, SIMD2<Float>) -> U
    private var lastTime: Float = -1

    public init(context: MetalContext,
                pixelFormat: MTLPixelFormat,
                vertexFunction: String,
                fragmentFunction: String,
                label: String,
                vertexData: Data,
                vertexCount: Int,
                vertexStride: Int,
                depthFormat: MTLPixelFormat = .depth32Float,
                triangleFillMode: MTLTriangleFillMode = .fill,
                initialState: State,
                step: @escaping (inout State, AudioFrame, Float, SIMD2<Float>) -> U) throws {
        self.context = context
        self.state = initialState
        self.step = step
        self.vertexCount = vertexCount
        self.depthFormat = depthFormat
        self.triangleFillMode = triangleFillMode

        guard let vertex = context.library.makeFunction(name: vertexFunction),
              let fragment = context.library.makeFunction(name: fragmentFunction) else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }

        // Vertex buffer — populated once from caller-supplied Data, immutable after.
        // Storage mode shared: CPU-writable at creation, GPU-readable every frame
        // (unified memory on Apple Silicon — no copy cost).
        let bufferLength = vertexCount * vertexStride
        precondition(vertexData.count >= bufferLength,
                     "MeshRenderer: vertexData (\(vertexData.count) bytes) smaller than vertexCount * vertexStride (\(bufferLength) bytes)")
        guard let buf = vertexData.withUnsafeBytes({ raw -> MTLBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return context.device.makeBuffer(bytes: base,
                                              length: bufferLength,
                                              options: [.storageModeShared])
        }) else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }
        buf.label = "\(label).vertices"
        self.vertexBuffer = buf

        // Pipeline — color + depth attachments both declared so Metal validation
        // accepts the pass descriptor we'll build per-frame.
        let desc = MTLRenderPipelineDescriptor()
        desc.label = label
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = pixelFormat
        desc.depthAttachmentPixelFormat = depthFormat
        self.pipeline = try context.device.makeRenderPipelineState(descriptor: desc)

        // Standard less-equal depth test — nearer fragments win, writes enabled.
        let dDesc = MTLDepthStencilDescriptor()
        dDesc.depthCompareFunction = .less
        dDesc.isDepthWriteEnabled = true
        guard let ds = context.device.makeDepthStencilState(descriptor: dDesc) else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }
        self.depthState = ds
    }

    /// Ensure the depth texture matches the current drawable size. Recreates on
    /// resize; private / renderTarget usage — never sampled, just written.
    private func ensureDepthTexture(width: Int, height: Int) {
        if let tex = depthTexture, tex.width == width, tex.height == height {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget]
        desc.storageMode = .private
        depthTexture = context.device.makeTexture(descriptor: desc)
        depthTexture?.label = "\(pipeline.label ?? "MeshRenderer").depth"
    }

    public func draw(in view: MTKView, audio: AudioFrame) {
        let dt: Float = lastTime < 0
            ? 1.0 / 60.0
            : min(0.1, max(0.001, audio.time - lastTime))
        lastTime = audio.time

        let ds = view.drawableSize
        let width = Int(ds.width)
        let height = Int(ds.height)
        guard width > 0, height > 0 else { return }

        ensureDepthTexture(width: width, height: height)
        guard let depthTex = depthTexture else { return }

        let res = SIMD2<Float>(Float(width), Float(height))
        var u = step(&state, audio, dt, res)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = context.commandQueue.makeCommandBuffer()
        else { return }

        // MTKView ships no depth attachment (framebufferOnly=true, no
        // depthStencilPixelFormat configured on the view). We attach our own
        // depth texture here so this renderer stays plug-compatible with the
        // existing MetalVisualizerView without forcing a global view change.
        pass.depthAttachment.texture = depthTex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1.0

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        enc.label = pipeline.label
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        // `.lines` draws triangle edges only — lets a plane-subdivided mesh
        // render as a wireframe grid without a separate line-geometry buffer.
        // Default `.fill` preserves existing behavior for all prior callers.
        enc.setTriangleFillMode(triangleFillMode)

        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &u) { bytes in
            if let base = bytes.baseAddress {
                // Bind to both stages at index 0 — callers decide which stage reads
                // which fields. Struct is small (camera + audio) so cross-stage
                // duplication is cheap.
                enc.setVertexBytes(base, length: bytes.count, index: 1)
                enc.setFragmentBytes(base, length: bytes.count, index: 0)
            }
        }
        audio.bassHistory.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                enc.setFragmentBytes(base, length: raw.count, index: 1)
            }
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }
}
