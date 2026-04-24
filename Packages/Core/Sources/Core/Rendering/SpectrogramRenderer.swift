import Metal
import MetalKit
import simd

// Spectrogram — scrolling mel-over-time heatmap. Mirrors the web driver at
// musicplayer-viz/viz/spectrogram.js. The generic `FragmentRenderer<U,S>`
// doesn't support texture bindings; this renderer owns its own encoder setup
// so it can bind the ring-buffer texture alongside the uniforms.
//
// Algorithm (matches web exactly):
//   1. Maintain a row-major Uint8 ring buffer: TIME_COLS × FREQ_ROWS. Each
//      row y stores the last TIME_COLS samples of mel bin y. Row 0 = bass
//      (the shader flips Y so row 0 paints at the bottom).
//   2. Per frame, shift each row left by 1 and write the current mel mags
//      into the rightmost column (oldest sample drops off).
//   3. Upload the buffer to an r8Unorm MTLTexture and sample it in the
//      fragment shader.
//
// Layout constants match web constants verbatim (TIME_COLS = 256, FREQ_ROWS = 32).

public struct SpectrogramUniforms {
    public var bass: Float = 0        // EMA-smoothed bass × react
    public var gamma: Float = 0.65    // amplitude gamma; matches web default
    // 2 floats (8 bytes) before resolution — keeps float2 at an 8-byte boundary.
    public var resolution: SIMD2<Float> = .zero
    // Total: 16 bytes.
}

@MainActor
public final class SpectrogramRenderer: VisualizerRenderer {
    // Ring-buffer geometry. Do not diverge from the web's TIME_COLS / FREQ_ROWS
    // without mirroring the change — the "how much history is visible" contract
    // must match.
    public static let timeCols: Int = 256
    public static let freqRows: Int = 32

    // Public tuning knobs. `gamma` is a future-slider hook — web default 0.65.
    // `react` mirrors the web `react` slider; default 1.0.
    public var gamma: Float = 0.65
    public var react: Float = 1.0

    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    private let histTexture: MTLTexture
    private let sampler: MTLSamplerState
    private var hist: [UInt8]           // row-major: hist[y * timeCols + x]

    public init(context: MetalContext,
                pixelFormat: MTLPixelFormat) throws {
        self.context = context
        self.hist = Array(repeating: 0, count: Self.timeCols * Self.freqRows)

        guard let vertex = context.library.makeFunction(name: "spectrogram_vs"),
              let fragment = context.library.makeFunction(name: "spectrogram_fs") else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Spectrogram"
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = pixelFormat
        self.pipeline = try context.device.makeRenderPipelineState(descriptor: desc)

        // r8Unorm matches the web's LuminanceFormat Uint8 DataTexture.
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Self.timeCols,
            height: Self.freqRows,
            mipmapped: false
        )
        texDesc.usage = [.shaderRead]
        texDesc.storageMode = .shared
        guard let tex = context.device.makeTexture(descriptor: texDesc) else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }
        tex.label = "SpectrogramHistory"
        self.histTexture = tex

        // Linear filter + clamp-to-edge — matches web DataTexture setup in
        // viz/spectrogram.js (minFilter/magFilter = LinearFilter, wrapS/wrapT
        // = ClampToEdgeWrapping).
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let samp = context.device.makeSamplerState(descriptor: samplerDesc) else {
            throw MetalContext.Error.libraryLoadFailed(nil)
        }
        self.sampler = samp
    }

    /// Shift every row left by 1 column; write current magnitudes into the
    /// rightmost column. Port of `pushFrame(mags)` in viz/spectrogram.js — same
    /// row-major layout, same bin-index clamp, same 0..1 → 0..255 quantization.
    private func pushFrame(_ mags: [Float]) {
        let cols = Self.timeCols
        let rows = Self.freqRows

        // No data — shift and seed zeros so the image decays cleanly.
        if mags.isEmpty {
            hist.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                for y in 0..<rows {
                    let rowOff = y * cols
                    // copyWithin(rowOff, rowOff+1, rowOff+cols) — shift left 1.
                    memmove(base + rowOff, base + rowOff + 1, cols - 1)
                    base[rowOff + cols - 1] = 0
                }
            }
            return
        }

        let n = min(rows, mags.count)
        hist.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for y in 0..<rows {
                let rowOff = y * cols
                memmove(base + rowOff, base + rowOff + 1, cols - 1)
                // Map row y to mag bin — row 0 is bass, row rows-1 is treble.
                // Shader flips Y so bass ends up at the bottom.
                let magIdx = y < n ? y : n - 1
                let v = mags[magIdx]
                let q: UInt8
                if v <= 0 { q = 0 }
                else if v >= 1 { q = 255 }
                else { q = UInt8((v * 255.0).rounded()) }
                base[rowOff + cols - 1] = q
            }
        }
    }

    public func draw(in view: MTKView, audio: AudioFrame) {
        // Push the smoothed magnitudes — iOS VisualizerViewModel already
        // applies per-bin attack/decay smoothing, so `audio.magnitudes` is the
        // equivalent of the web's `frame.magnitudesSmooth`.
        pushFrame(audio.magnitudes)

        // Upload ring buffer to GPU. 256 × 32 = 8KB; negligible per frame.
        let bytesPerRow = Self.timeCols
        let region = MTLRegionMake2D(0, 0, Self.timeCols, Self.freqRows)
        hist.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            histTexture.replace(region: region,
                                mipmapLevel: 0,
                                withBytes: base,
                                bytesPerRow: bytesPerRow)
        }

        let ds = view.drawableSize
        let res = SIMD2<Float>(Float(ds.width), Float(ds.height))
        var u = SpectrogramUniforms(
            bass: audio.bass * react,
            gamma: gamma,
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
        enc.setFragmentTexture(histTexture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }
}
