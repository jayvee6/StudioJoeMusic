import Metal
import simd

// MARK: - Uniform structs (layout-compatible with corresponding Metal structs)

public struct BlobUniforms {
    public var time: Float = 0
    public var audio: Float = 0
    public var resolution: SIMD2<Float> = .zero
    // Track-mood tail — added AFTER the trailing float2 so Swift/Metal alignment
    // stays 4-byte-safe (4 floats slot into the 16-byte region after `resolution`).
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120
}

public struct MandalaUniforms {
    public var rot: Float = 0
    public var hue: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var resolution: SIMD2<Float> = .zero
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120
}

public struct HypnoUniforms {
    public var offset: Float = 0
    public var colorShift: Float = 0
    public var hue: Float = 0
    public var bass: Float = 0
    public var resolution: SIMD2<Float> = .zero
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120
}

public struct SpiralUniforms {
    public var offset: Float = 0
    public var hue: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var resolution: SIMD2<Float> = .zero
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120
}

public struct SubwooferUniforms {
    public var time: Float = 0
    public var bass: Float = 0
    public var beatPulse: Float = 0
    public var resolution: SIMD2<Float> = .zero
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120
}

public struct VortexUniforms {
    public var tunnelRot: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var twist: Float = 2.0
    public var scale: Float = 1.0
    public var rippleAmp: Float = 0.06
    public var resolution: SIMD2<Float> = .zero
    public var atlasGrid: SIMD2<Float> = .init(4, 3)
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120
}

public struct WavesUniforms {
    public var waveSpin: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var ringScale: Float = 0.13
    public var resolution: SIMD2<Float> = .zero
    public var atlasGrid: SIMD2<Float> = .init(4, 3)
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120
}

public struct RorschachUniforms {
    public var time: Float       // monotonic — drives edge noise
    public var bass: Float
    public var mid: Float
    public var treble: Float
    // 4 floats (16 bytes) before resolution — keeps float2 at an 8-byte boundary.
    public var resolution: SIMD2<Float>
    public var beatPulse: Float
    public var valence: Float
    public var energy: Float
    public var danceability: Float
    public var tempoBPM: Float
    // Oscillating drift time — drives metaball node positions + breath. See
    // RorschachState for the CPU-side oscillator.
    public var nodeT: Float
    // Size multiplier (mirrors the web `size` slider). iOS has no slider for
    // this yet; default 1.0. Appended after `nodeT`, preserving the float
    // sequence. Total struct: 52 bytes.
    public var sizeMul: Float

    public init(time: Float = 0, bass: Float = 0, mid: Float = 0, treble: Float = 0,
                resolution: SIMD2<Float> = .zero, beatPulse: Float = 0,
                valence: Float = 0.5, energy: Float = 0.5,
                danceability: Float = 0.5, tempoBPM: Float = 120,
                nodeT: Float = 0, sizeMul: Float = 1.0) {
        self.time = time; self.bass = bass; self.mid = mid; self.treble = treble
        self.resolution = resolution; self.beatPulse = beatPulse
        self.valence = valence; self.energy = energy
        self.danceability = danceability; self.tempoBPM = tempoBPM
        self.nodeT = nodeT; self.sizeMul = sizeMul
    }
}

public struct LunarUniforms {
    public var time: Float = 0
    public var rotY: Float = 0          // CPU-accumulated y-axis rotation
    public var bass: Float = 0
    public var treble: Float = 0
    public var resolution: SIMD2<Float> = .zero
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120
}

public struct KaleidoUniforms {
    public var camZ: Float = 0          // CPU-accumulated tunnel depth
    public var hue: Float = 0           // 0..1, CPU-accumulated hue rotation
    public var bass: Float = 0
    public var mid: Float = 0
    public var treble: Float = 0
    public var twist: Float = 0         // CPU-accumulated mid-freq twist
    public var resolution: SIMD2<Float> = .zero
    public var valence: Float = 0.5
    public var energy: Float = 0.5
    public var danceability: Float = 0.5
    public var tempoBPM: Float = 120
}

// MARK: - State structs

public struct MandalaState { public var rot: Float = 0; public var hue: Float = 0 }
public struct HypnoState   { public var offset: Float = 0; public var colorShift: Float = 0; public var hue: Float = 0 }
public struct SpiralState  { public var offset: Float = 0; public var hue: Float = 0 }
public struct VortexState  {
    public var tunnelRot: Float = 0
    public var smoothTwist: Float = 1.8
    public var smoothScale: Float = 1.0
    public var smoothTreble: Float = 0
    public var smoothBass: Float = 0
}
// Rorschach wants EMA-smoothed audio (so shape reads as ink formation, not
// per-frame twitch) plus an independent oscillating "node time" (so the blob
// sloshes forward and back like tilting ink, not robotically). Both mirror
// the web viz/rorschach.js — any tuning change must land in both places.
public struct RorschachState {
    public var smBass: Float   = 0
    public var smMid: Float    = 0
    public var smTreble: Float = 0
    public var smBeat: Float   = 0
    public var clock: Float    = 0   // monotonic accumulated dt; drives the oscillator
}
public struct WavesState   { public var waveSpin: Float = 0 }
public struct LunarState   { public var rotY: Float = 0 }
public struct KaleidoState { public var camZ: Float = 0; public var hue: Float = 0; public var twist: Float = 0 }

// MARK: - Factory

@MainActor
public enum VisualizerFactory {
    public static func make(mode: VisualizerMode,
                            context: MetalContext,
                            pixelFormat: MTLPixelFormat,
                            atlas: EmojiAtlas?) throws -> VisualizerRenderer? {
        switch mode {
        case .bars: return nil
        case .blob: return try makeBlob(context: context, pixelFormat: pixelFormat)
        case .mandala: return try makeMandala(context: context, pixelFormat: pixelFormat)
        case .hypnoRings: return try makeHypno(context: context, pixelFormat: pixelFormat)
        case .spiral: return try makeSpiral(context: context, pixelFormat: pixelFormat)
        case .subwoofer: return try makeSubwoofer(context: context, pixelFormat: pixelFormat)
        case .emojiVortex:
            guard let atlas else { return nil }
            return try makeVortex(context: context, pixelFormat: pixelFormat, atlas: atlas)
        case .emojiWaves:
            guard let atlas else { return nil }
            return try makeWaves(context: context, pixelFormat: pixelFormat, atlas: atlas)
        case .ferrofluid:
            return try FerroRenderer(context: context, pixelFormat: pixelFormat)
        case .rorschach:
            return try makeRorschach(context: context, pixelFormat: pixelFormat)
        case .lunar:
            return try makeLunar(context: context, pixelFormat: pixelFormat)
        case .kaleidoScope:
            return try makeKaleido(context: context, pixelFormat: pixelFormat)
        case .dvdMode:
            return nil
        case .fireworks:
            return nil   // rendered by FireworksView (SwiftUI Canvas), not Metal
        case .spectrogram:
            return try SpectrogramRenderer(context: context, pixelFormat: pixelFormat)
        }
    }

    // MARK: - Fragment-only visualizers

    private static func makeBlob(context: MetalContext,
                                 pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentRenderer<BlobUniforms, Void>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "blob_vs", fragmentFunction: "blob_fs",
            label: "Blob",
            initialState: ()
        ) { _, a, _, res in
            let audio = min(1.0, a.bass * 0.75 + a.beatPulse * 0.45)
            return BlobUniforms(
                time: a.time,
                audio: audio,
                resolution: res,
                valence: a.valence,
                energy: a.energy,
                danceability: a.danceability,
                tempoBPM: a.tempoBPM
            )
        }
    }

    private static func makeMandala(context: MetalContext,
                                    pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentRenderer<MandalaUniforms, MandalaState>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "mandala_vs", fragmentFunction: "mandala_fs",
            label: "Mandala",
            initialState: MandalaState()
        ) { state, a, dt, res in
            // Web's per-frame integrators at 60 fps: rot += 0.004 + treble*0.06;
            //                                        hue += 0.4 + treble*2.5.
            let normDt = dt * 60.0
            state.rot += (0.004 + a.treble * 0.06) * normDt
            var newHue = state.hue + (0.4 + a.treble * 2.5) * normDt / 360.0
            newHue -= floor(newHue)
            state.hue = newHue
            return MandalaUniforms(
                rot: state.rot,
                hue: state.hue,
                bass: a.bass,
                treble: a.treble,
                resolution: res,
                valence: a.valence,
                energy: a.energy,
                danceability: a.danceability,
                tempoBPM: a.tempoBPM
            )
        }
    }

    private static func makeHypno(context: MetalContext,
                                  pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentRenderer<HypnoUniforms, HypnoState>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "hypno_vs", fragmentFunction: "hypno_fs",
            label: "Hypno",
            initialState: HypnoState()
        ) { state, a, dt, res in
            // Web: ringOffset += 0.45 + bass*7 pixels/frame; SPACING = 46 px.
            // We store offset in "ring spacings" so the shader can treat it as dimensionless.
            let normDt = dt * 60.0
            state.offset += (0.45 + a.bass * 7.0) / 46.0 * normDt
            // Wrap + bump colorShift (web's parity trick — keeps bands continuous on wrap).
            while state.offset >= 1.0 {
                state.offset -= 1.0
                state.colorShift += 1
            }
            state.hue += (0.3 + a.treble * 2.0) * normDt / 360.0
            state.hue -= floor(state.hue)
            return HypnoUniforms(
                offset: state.offset,
                colorShift: state.colorShift,
                hue: state.hue,
                bass: a.bass,
                resolution: res,
                valence: a.valence,
                energy: a.energy,
                danceability: a.danceability,
                tempoBPM: a.tempoBPM
            )
        }
    }

    private static func makeSpiral(context: MetalContext,
                                   pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentRenderer<SpiralUniforms, SpiralState>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "spiral_vs", fragmentFunction: "spiral_fs",
            label: "Spiral",
            initialState: SpiralState()
        ) { state, a, dt, res in
            // Web: spiralOffset += 0.45 + bass*7 px/frame; pitch = 50 px. Offset stored in "pitches".
            let normDt = dt * 60.0
            state.offset += (0.45 + a.bass * 7.0) / 50.0 * normDt
            state.hue += (0.3 + a.treble * 2.0) * normDt / 360.0
            state.hue -= floor(state.hue)
            return SpiralUniforms(
                offset: state.offset,
                hue: state.hue,
                bass: a.bass,
                treble: a.treble,
                resolution: res,
                valence: a.valence,
                energy: a.energy,
                danceability: a.danceability,
                tempoBPM: a.tempoBPM
            )
        }
    }

    private static func makeSubwoofer(context: MetalContext,
                                      pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentRenderer<SubwooferUniforms, Void>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "subwoofer_vs", fragmentFunction: "subwoofer_fs",
            label: "Subwoofer",
            initialState: ()
        ) { _, a, _, res in
            SubwooferUniforms(
                time: a.time,
                bass: a.bass,
                beatPulse: a.beatPulse,
                resolution: res,
                valence: a.valence,
                energy: a.energy,
                danceability: a.danceability,
                tempoBPM: a.tempoBPM
            )
        }
    }

    // MARK: - Instanced atlas visualizers

    private static func makeVortex(context: MetalContext,
                                   pixelFormat: MTLPixelFormat,
                                   atlas: EmojiAtlas) throws -> VisualizerRenderer {
        let grid = SIMD2<Float>(Float(atlas.columns), Float(atlas.rows))
        return try InstancedAtlasRenderer<VortexUniforms, VortexState>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "vortex_vs", fragmentFunction: "vortex_fs",
            atlas: atlas.texture,
            instanceCount: 12 * 13,
            label: "EmojiVortex",
            initialState: VortexState()
        ) { state, a, dt, res in
            // Web: tunnelRot += 0.004 + mid * 0.008 per frame at 60fps.
            let normDt = dt * 60.0
            state.tunnelRot += (0.004 + a.mid * 0.008) * normDt

            // Smooth the bass/treble feeds so twist/scale/size don't jitter per-frame.
            // Single-pole lowpass with dt-aware coefficient.
            let alphaTwist: Float  = min(1.0, 0.10 * normDt)
            let alphaScale: Float  = min(1.0, 0.10 * normDt)
            let alphaTreble: Float = min(1.0, 0.18 * normDt)
            let alphaBass: Float   = min(1.0, 0.22 * normDt)
            state.smoothTwist  += (1.8 + a.bass * 1.8 - state.smoothTwist)  * alphaTwist
            state.smoothScale  += (1.0 + a.bass * 0.06 - state.smoothScale) * alphaScale
            state.smoothTreble += (a.treble - state.smoothTreble) * alphaTreble
            state.smoothBass   += (a.bass   - state.smoothBass)   * alphaBass

            return VortexUniforms(
                tunnelRot: state.tunnelRot,
                bass: state.smoothBass,
                treble: state.smoothTreble,
                twist: state.smoothTwist,
                scale: state.smoothScale,
                rippleAmp: 0.060,
                resolution: res,
                atlasGrid: grid,
                valence: a.valence,
                energy: a.energy,
                danceability: a.danceability,
                tempoBPM: a.tempoBPM
            )
        }
    }

    private static func makeRorschach(context: MetalContext,
                                      pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        // EMA smoothing time constants (seconds) — match web viz/rorschach.js.
        // Bass/treble snap fast, mid paces, beat is smoothed only for legacy
        // state (the shader consumes raw beat for sharp punches — see below).
        let tauBass:   Float = 0.25
        let tauMid:    Float = 0.40
        let tauTreble: Float = 0.30
        let tauBeat:   Float = 0.25

        // iOS has no `drift` / `size` / `react` sliders yet; use web defaults.
        // Mirroring the web `size` slider default (1.0) as a uniform so the
        // fragment scales identically.
        let driftMul: Float   = 1.0
        let sizeMul:  Float   = 1.0
        let reactMul: Float   = 1.0

        return try FragmentRenderer<RorschachUniforms, RorschachState>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "rorschach_vs", fragmentFunction: "rorschach_fs",
            label: "Rorschach",
            initialState: RorschachState()
        ) { state, a, dt, res in
            let dtF = Float(dt)
            let kBass   = 1.0 - expf(-dtF / tauBass)
            let kMid    = 1.0 - expf(-dtF / tauMid)
            let kTreble = 1.0 - expf(-dtF / tauTreble)
            let kBeat   = 1.0 - expf(-dtF / tauBeat)
            state.smBass   += (a.bass      - state.smBass)   * kBass
            state.smMid    += (a.mid       - state.smMid)    * kMid
            state.smTreble += (a.treble    - state.smTreble) * kTreble
            state.smBeat   += (a.beatPulse - state.smBeat)   * kBeat
            state.clock    += dtF

            // Dual-time driver — monotonic `time` for FBM edge noise (never
            // plays backwards), oscillating `nodeT` for metaball positions +
            // breath (sweeps forward and back). Matches web viz/rorschach.js:
            //   nodeT = (sin(t*0.30)*6 + sin(t*0.19)*3) * drift
            let clock = state.clock
            let nodeT = (sinf(clock * 0.30) * 6.0 + sinf(clock * 0.19) * 3.0) * driftMul

            // Raw beatPulse (× react) passes through for sharp per-beat punches
            // on the splatter droplets + edge-glow flare — mirror of
            // `u_beatSharp = (f.beatPulse || 0) * react` in viz/rorschach.js.
            return RorschachUniforms(
                time: clock,
                bass: state.smBass * reactMul,
                mid: state.smMid,
                treble: state.smTreble * reactMul,
                resolution: res,
                beatPulse: a.beatPulse * reactMul,
                valence: a.valence,
                energy: a.energy,
                danceability: a.danceability,
                tempoBPM: a.tempoBPM,
                nodeT: nodeT,
                sizeMul: sizeMul
            )
        }
    }

    private static func makeWaves(context: MetalContext,
                                  pixelFormat: MTLPixelFormat,
                                  atlas: EmojiAtlas) throws -> VisualizerRenderer {
        let grid = SIMD2<Float>(Float(atlas.columns), Float(atlas.rows))
        return try InstancedAtlasRenderer<WavesUniforms, WavesState>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "waves_vs", fragmentFunction: "waves_fs",
            atlas: atlas.texture,
            instanceCount: 91,
            label: "EmojiWaves",
            initialState: WavesState()
        ) { state, a, dt, res in
            // Web: waveSpin += 0.008 * waveSpinSpeed (we fix waveSpinSpeed at 1.0).
            let normDt = dt * 60.0
            state.waveSpin += 0.008 * normDt
            return WavesUniforms(
                waveSpin: state.waveSpin,
                bass: a.bass,
                treble: a.treble,
                ringScale: 0.13,
                resolution: res,
                atlasGrid: grid,
                valence: a.valence,
                energy: a.energy,
                danceability: a.danceability,
                tempoBPM: a.tempoBPM
            )
        }
    }

    private static func makeLunar(context: MetalContext,
                                  pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentRenderer<LunarUniforms, LunarState>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "lunar_vs", fragmentFunction: "lunar_fs",
            label: "Lunar",
            initialState: LunarState()
        ) { state, a, dt, res in
            let normDt = dt * 60.0
            // Slow y-axis spin; danceability nudges speed slightly
            state.rotY += (0.003 + a.danceability * 0.002) * normDt
            return LunarUniforms(
                time: a.time,
                rotY: state.rotY,
                bass: a.bass,
                treble: a.treble,
                resolution: res,
                valence: a.valence,
                energy: a.energy,
                danceability: a.danceability,
                tempoBPM: a.tempoBPM
            )
        }
    }

    private static func makeKaleido(context: MetalContext,
                                    pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentRenderer<KaleidoUniforms, KaleidoState>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "kaleido_vs", fragmentFunction: "kaleido_fs",
            label: "KaleidoScope",
            initialState: KaleidoState()
        ) { state, a, dt, res in
            let normDt = dt * 60.0
            // Fly forward — base speed + danceability + beat pulse burst
            state.camZ  += (0.008 + a.danceability * 0.012 + a.beatPulse * 0.025) * normDt
            // Hue cycles with treble-driven speed
            state.hue   += (0.4 + a.treble * 2.0) * normDt / 360.0
            state.hue   -= floor(state.hue)
            // Twist accumulates from mid frequencies, giving the tunnel a growing spiral
            state.twist += a.mid * 0.018 * normDt
            return KaleidoUniforms(
                camZ: state.camZ,
                hue: state.hue,
                bass: a.bass,
                mid: a.mid,
                treble: a.treble,
                twist: state.twist,
                resolution: res,
                valence: a.valence,
                energy: a.energy,
                danceability: a.danceability,
                tempoBPM: a.tempoBPM
            )
        }
    }
}
