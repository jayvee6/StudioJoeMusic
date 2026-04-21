import Metal
import MetalKit
import simd

public struct AudioFrame {
    public var time: Float
    public var bass: Float
    public var mid: Float
    public var treble: Float
    public var beatPulse: Float
    public var bpm: Float
    public var magnitudes: [Float]     // per-bin, 0..1; length equals VM.binCount
    public var bassHistory: [Float]    // length 16; [0] = newest, [15] = oldest
    // Track-level mood metadata (Spotify audio-features or equivalent). Defaults are
    // chosen so that absent metadata yields visuals identical to the pre-metadata baseline:
    // all four multipliers/offsets evaluate to 1.0 × base at these values.
    public var valence: Float          // 0..1; mood. 0 = cool/sad, 1 = warm/happy
    public var energy: Float           // 0..1; amplitude/saturation multiplier
    public var danceability: Float     // 0..1; speed/wobble multiplier
    public var tempoBPM: Float         // beat rate fallback when live BPM is absent

    public init(time: Float,
                bass: Float,
                mid: Float,
                treble: Float,
                beatPulse: Float,
                bpm: Float,
                magnitudes: [Float],
                bassHistory: [Float],
                valence: Float = 0.5,
                energy: Float = 0.5,
                danceability: Float = 0.5,
                tempoBPM: Float = 120) {
        self.time = time
        self.bass = bass
        self.mid = mid
        self.treble = treble
        self.beatPulse = beatPulse
        self.bpm = bpm
        self.magnitudes = magnitudes
        self.bassHistory = bassHistory
        self.valence = valence
        self.energy = energy
        self.danceability = danceability
        self.tempoBPM = tempoBPM
    }
}

public let bassHistoryLength: Int = 16

@MainActor
public protocol VisualizerRenderer: AnyObject {
    func draw(in view: MTKView, audio: AudioFrame)
}

/// Generic fragment-only renderer. `State` is per-frame mutable state (rotation
/// accumulators, hue drift, etc.) owned by the renderer; `step` integrates that
/// state with the current audio frame and produces `U`, the shader uniforms.
///
/// For stateless visualizers, pass `State` = `Void` and provide a step that ignores
/// the state parameter.
@MainActor
public final class FragmentRenderer<U, State>: VisualizerRenderer {
    private let context: MetalContext
    private let pipeline: MTLRenderPipelineState
    private var state: State
    private let step: (inout State, AudioFrame, Float, SIMD2<Float>) -> U
    private var lastTime: Float = -1

    public init(context: MetalContext,
                pixelFormat: MTLPixelFormat,
                vertexFunction: String,
                fragmentFunction: String,
                label: String,
                initialState: State,
                step: @escaping (inout State, AudioFrame, Float, SIMD2<Float>) -> U) throws {
        self.context = context
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

        enc.label = pipeline.label
        enc.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &u) { bytes in
            if let base = bytes.baseAddress {
                enc.setFragmentBytes(base, length: bytes.count, index: 0)
            }
        }
        audio.bassHistory.withUnsafeBytes { raw in
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

// Keep old stateless alias for any remaining consumers during transition.
public typealias FragmentVisualizerRenderer<U> = FragmentRenderer<U, Void>
