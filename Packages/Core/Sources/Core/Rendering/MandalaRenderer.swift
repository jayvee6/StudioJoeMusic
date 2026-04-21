import Metal
import MetalKit
import simd

public struct MandalaFrameUniforms {
    public var rot: Float = 0
    public var hue: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var resolution: SIMD2<Float> = .zero
}

/// Mandala renderer with persistent offscreen accumulation + per-frame alpha fade.
/// Replicates the web prototype's Canvas 2D frame-persistence trick:
///   1. Fade pass  — multiplies the accumulation texture by 0.82 (matches web's
///                   `fillRect(…, rgba(0,0,0,0.18))` alpha wash).
///   2. Draw pass  — additively blends this frame's polygon lines onto the accumulation.
///   3. Blit pass  — copies the accumulation to the drawable.
///
/// The result is the "dancing laser shapes" trail effect: old polygon positions linger
/// as dimmer ghosts for several frames before fading out.
@MainActor
public final class MandalaRenderer: VisualizerRenderer {
    private let context: MetalContext
    private let pixelFormat: MTLPixelFormat
    private let fadePipeline: MTLRenderPipelineState
    private let drawPipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState

    private var accumTexture: MTLTexture?
    private var accumSize: MTLSize = MTLSize(width: 0, height: 0, depth: 1)
    private var needsInitialClear = true

    // CPU-integrated state (web's mandalaRot + mandalaHue, per-frame at 60fps).
    private var rot: Float = 0
    private var hue: Float = 0
    private var lastTime: Float = -1

    public init(context: MetalContext, pixelFormat: MTLPixelFormat) throws {
        self.context = context
        self.pixelFormat = pixelFormat

        guard let fadeVtx = context.library.makeFunction(name: "mandala_fs_trail_vs"),
              let fadeFrag = context.library.makeFunction(name: "mandala_fs_trail_fade_fs"),
              let drawVtx = context.library.makeFunction(name: "mandala_fs_trail_vs"),
              let drawFrag = context.library.makeFunction(name: "mandala_fs_trail_draw_fs"),
              let blitVtx = context.library.makeFunction(name: "mandala_fs_trail_vs"),
              let blitFrag = context.library.makeFunction(name: "mandala_fs_trail_blit_fs") else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }

        // Fade pass: multiplies destination by (1 - srcAlpha) using a zero-color
        // source. With srcAlpha = 0.18, destination retains 82%.
        let fadeDesc = MTLRenderPipelineDescriptor()
        fadeDesc.label = "Mandala fade"
        fadeDesc.vertexFunction = fadeVtx
        fadeDesc.fragmentFunction = fadeFrag
        let fadeAttach = fadeDesc.colorAttachments[0]!
        fadeAttach.pixelFormat = pixelFormat
        fadeAttach.isBlendingEnabled = true
        fadeAttach.sourceRGBBlendFactor = .sourceAlpha
        fadeAttach.destinationRGBBlendFactor = .oneMinusSourceAlpha
        fadeAttach.sourceAlphaBlendFactor = .sourceAlpha
        fadeAttach.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.fadePipeline = try context.device.makeRenderPipelineState(descriptor: fadeDesc)

        // Draw pass: additive blending so overlapping polygon edges brighten
        // (matches Canvas 2D's default stroke behavior + shadowBlur stacking).
        let drawDesc = MTLRenderPipelineDescriptor()
        drawDesc.label = "Mandala draw"
        drawDesc.vertexFunction = drawVtx
        drawDesc.fragmentFunction = drawFrag
        let drawAttach = drawDesc.colorAttachments[0]!
        drawAttach.pixelFormat = pixelFormat
        drawAttach.isBlendingEnabled = true
        drawAttach.sourceRGBBlendFactor = .one
        drawAttach.destinationRGBBlendFactor = .one
        drawAttach.sourceAlphaBlendFactor = .one
        drawAttach.destinationAlphaBlendFactor = .one
        self.drawPipeline = try context.device.makeRenderPipelineState(descriptor: drawDesc)

        // Blit pass: copy accumulation texture straight to drawable, no blending.
        let blitDesc = MTLRenderPipelineDescriptor()
        blitDesc.label = "Mandala blit"
        blitDesc.vertexFunction = blitVtx
        blitDesc.fragmentFunction = blitFrag
        blitDesc.colorAttachments[0].pixelFormat = pixelFormat
        self.blitPipeline = try context.device.makeRenderPipelineState(descriptor: blitDesc)
    }

    public func draw(in view: MTKView, audio: AudioFrame) {
        // Ensure accumulation texture matches drawable size.
        let ds = view.drawableSize
        let w = Int(ds.width), h = Int(ds.height)
        if w <= 0 || h <= 0 { return }
        if accumTexture == nil || w != accumSize.width || h != accumSize.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            accumTexture = context.device.makeTexture(descriptor: desc)
            accumSize = MTLSize(width: w, height: h, depth: 1)
            needsInitialClear = true
        }
        guard let accum = accumTexture,
              let drawable = view.currentDrawable else { return }

        // Integrate state — web rate at 60fps.
        let dt: Float = lastTime < 0 ? 1.0/60.0
            : min(0.1, max(0.001, audio.time - lastTime))
        lastTime = audio.time
        let normDt = dt * 60.0
        rot += (0.004 + audio.treble * 0.06) * normDt
        hue += (0.4 + audio.treble * 2.5) * normDt / 360.0
        hue -= floor(hue)

        var u = MandalaFrameUniforms(
            rot: rot, hue: hue,
            bass: audio.bass, treble: audio.treble,
            resolution: SIMD2<Float>(Float(w), Float(h))
        )

        guard let cmd = context.commandQueue.makeCommandBuffer() else { return }

        // Pass 1: fade the accumulation by 18%.
        // First frame after (re)allocation: clear to black so we don't load GPU garbage.
        let fadePass = MTLRenderPassDescriptor()
        fadePass.colorAttachments[0].texture = accum
        if needsInitialClear {
            fadePass.colorAttachments[0].loadAction = .clear
            fadePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            needsInitialClear = false
        } else {
            fadePass.colorAttachments[0].loadAction = .load
        }
        fadePass.colorAttachments[0].storeAction = .store
        if let fadeEnc = cmd.makeRenderCommandEncoder(descriptor: fadePass) {
            fadeEnc.label = "Mandala fade"
            fadeEnc.setRenderPipelineState(fadePipeline)
            fadeEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            fadeEnc.endEncoding()
        }

        // Pass 2: additively blend this frame's polygons onto the accumulation.
        let drawPass = MTLRenderPassDescriptor()
        drawPass.colorAttachments[0].texture = accum
        drawPass.colorAttachments[0].loadAction = .load
        drawPass.colorAttachments[0].storeAction = .store
        if let drawEnc = cmd.makeRenderCommandEncoder(descriptor: drawPass) {
            drawEnc.label = "Mandala draw"
            drawEnc.setRenderPipelineState(drawPipeline)
            withUnsafeBytes(of: &u) { bytes in
                if let base = bytes.baseAddress {
                    drawEnc.setFragmentBytes(base, length: bytes.count, index: 0)
                }
            }
            drawEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            drawEnc.endEncoding()
        }

        // Pass 3: blit accumulation to drawable.
        guard let finalPass = view.currentRenderPassDescriptor,
              let blitEnc = cmd.makeRenderCommandEncoder(descriptor: finalPass) else {
            cmd.present(drawable); cmd.commit(); return
        }
        blitEnc.label = "Mandala blit"
        blitEnc.setRenderPipelineState(blitPipeline)
        blitEnc.setFragmentTexture(accum, index: 0)
        blitEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        blitEnc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }
}
