import Metal
import simd

// MARK: - Matrix helpers (RH camera, Metal NDC depth [0, 1])
//
// Metal clips on z ∈ [0, 1]; we build a right-handed view (camera looks down
// its -Z) and a right-handed perspective that squashes view-space into that
// depth range. These are free functions rather than simd_float4x4 extensions
// so shader-side callers (WireTerrain only, for now) can use them without
// importing additional helpers. If a future viz lands a different convention,
// add a sibling helper — don't overload these.

@inlinable
public func perspectiveMatrix(fovyRadians fovy: Float,
                              aspect: Float,
                              near: Float, far: Float) -> simd_float4x4 {
    let ys = 1 / tanf(fovy * 0.5)
    let xs = ys / aspect
    let zs = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4<Float>(xs,  0,    0,         0),
        SIMD4<Float>( 0, ys,    0,         0),
        SIMD4<Float>( 0,  0,   zs,        -1),
        SIMD4<Float>( 0,  0, zs * near,    0)
    ))
}

@inlinable
public func lookAtMatrix(eye: SIMD3<Float>,
                         center: SIMD3<Float>,
                         up: SIMD3<Float>) -> simd_float4x4 {
    // Right-handed: forward runs from eye toward center; we store -f in the
    // third row so the camera's -Z maps to forward in view space.
    let f = simd_normalize(center - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(columns: (
        SIMD4<Float>( s.x,  u.x, -f.x, 0),
        SIMD4<Float>( s.y,  u.y, -f.y, 0),
        SIMD4<Float>( s.z,  u.z, -f.z, 0),
        SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
    ))
}

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

// Siri Waveform — 4 additive sin layers drawn in a single fragment pass.
// Layout (48 bytes total; MUST match Shaders/SiriWaveform.metal):
//   offset  0: time        (Float)     — seconds, monotonic
//   offset  4: beatPulse   (Float)     — 0..1
//   offset  8: _pad0       (Float)     — align bandEnergy to 16B
//   offset 12: _pad1       (Float)
//   offset 16: bandEnergy  (SIMD4<Float>) — magenta/cyan/blue/violet band mean
//   offset 32: resolution  (SIMD2<Float>) — drawable px
//   offset 40: _pad2       (Float)
//   offset 44: _pad3       (Float)
// SIMD4<Float> requires 16B alignment; two pad floats place it on the right
// boundary. The trailing pads round the struct up to a 16B multiple so Metal
// doesn't read past the buffer.
public struct SiriWaveformUniforms {
    public var time: Float
    public var beatPulse: Float
    public var _pad0: Float
    public var _pad1: Float
    public var bandEnergy: SIMD4<Float>
    public var resolution: SIMD2<Float>
    public var _pad2: Float
    public var _pad3: Float

    public init(time: Float = 0,
                beatPulse: Float = 0,
                _pad0: Float = 0,
                _pad1: Float = 0,
                bandEnergy: SIMD4<Float> = .zero,
                resolution: SIMD2<Float> = .zero,
                _pad2: Float = 0,
                _pad3: Float = 0) {
        self.time = time
        self.beatPulse = beatPulse
        self._pad0 = _pad0
        self._pad1 = _pad1
        self.bandEnergy = bandEnergy
        self.resolution = resolution
        self._pad2 = _pad2
        self._pad3 = _pad3
    }
}

// Wire Terrain — vertex-shader FBM displaces a 30×30 plane (128×128 subdivs)
// and the fragment maps height to a violet→blue→cyan palette. MeshRenderer
// binds this struct at vertex-index 1 and fragment-index 0 (see
// Shaders/WireTerrain.metal). Layout MUST match the Metal struct exactly:
//
//   offset   0 — projectionMatrix (float4x4, 64 B, 16-byte aligned)
//   offset  64 — viewMatrix       (float4x4, 64 B, 16-byte aligned)
//   offset 128 — time             (Float)
//   offset 132 — bass             (Float)
//   offset 136 — treble           (Float)
//   offset 140 — beatPulse        (Float)
//   offset 144 — resolution       (SIMD2<Float>, 8 B, 8-byte aligned)
//   offset 152 — fogDensity       (Float) — web FogExp2(0x000008, 0.035)
//   offset 156 — _pad0            (Float) — round total to 16-byte multiple
//   Total: 160 bytes.
public struct WireTerrainUniforms {
    public var projectionMatrix: simd_float4x4
    public var viewMatrix:       simd_float4x4
    public var time:             Float
    public var bass:             Float
    public var treble:           Float
    public var beatPulse:        Float
    public var resolution:       SIMD2<Float>
    public var fogDensity:       Float
    public var _pad0:            Float

    public init(projectionMatrix: simd_float4x4 = matrix_identity_float4x4,
                viewMatrix:       simd_float4x4 = matrix_identity_float4x4,
                time:             Float = 0,
                bass:             Float = 0,
                treble:           Float = 0,
                beatPulse:        Float = 0,
                resolution:       SIMD2<Float> = .zero,
                fogDensity:       Float = 0.035,
                _pad0:            Float = 0) {
        self.projectionMatrix = projectionMatrix
        self.viewMatrix = viewMatrix
        self.time = time
        self.bass = bass
        self.treble = treble
        self.beatPulse = beatPulse
        self.resolution = resolution
        self.fogDensity = fogDensity
        self._pad0 = _pad0
    }
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
public struct SiriWaveformState { public var clock: Float = 0 }

// Wire Terrain — `clock` is monotonic (drives FBM noise time; never resets
// mid-session). `orbit` is a separate accumulator for the camera angle so
// tuning the orbit speed doesn't drift the terrain noise phase. `hasInit`
// guards first-frame setup so Chunk C's factory closure can initialize the
// projection matrix exactly once.
public struct WireTerrainState {
    public var clock:   Float = 0
    public var orbit:   Float = 0
    public var hasInit: Bool  = false
}

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
        case .siriWaveform:
            return try makeSiriWaveform(context: context, pixelFormat: pixelFormat)
        case .wireTerrain:
            return try makeWireTerrain(context: context, pixelFormat: pixelFormat)
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

    private static func makeSiriWaveform(context: MetalContext,
                                         pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        // Web `react` slider default is 1.0; iOS has no slider yet, so use 1.0.
        // Parity rule: any tuning that touches these coefficients must land on
        // the web side too — see .claude/skills/studiojoe-viz/references/parity.md.
        return try FragmentRenderer<SiriWaveformUniforms, SiriWaveformState>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "siriwave_vs", fragmentFunction: "siriwave_fs",
            label: "SiriWaveform",
            initialState: SiriWaveformState()
        ) { state, a, dt, res in
            state.clock += dt

            // Per-band mel-bin means — one band per layer. Indices mirror the
            // web LAYERS[].bandLo/bandHi exactly (see viz/siri-waveform.js):
            //   magenta  0..4   (sub/bass)
            //   cyan     5..12  (low-mids)
            //   blue     13..20 (mids)
            //   violet   21..31 (treble)
            func bandMean(_ mags: [Float], _ lo: Int, _ hi: Int) -> Float {
                guard lo <= hi, lo >= 0, !mags.isEmpty else { return 0 }
                let hiClamp = min(hi, mags.count - 1)
                if lo > hiClamp { return 0 }
                var sum: Float = 0
                for i in lo...hiClamp { sum += mags[i] }
                return sum / Float(hiClamp - lo + 1)
            }
            let mags = a.magnitudes
            let e0 = bandMean(mags,  0,  4)
            let e1 = bandMean(mags,  5, 12)
            let e2 = bandMean(mags, 13, 20)
            let e3 = bandMean(mags, 21, 31)

            return SiriWaveformUniforms(
                time: state.clock,
                beatPulse: a.beatPulse,
                _pad0: 0,
                _pad1: 0,
                bandEnergy: SIMD4<Float>(e0, e1, e2, e3),
                resolution: res,
                _pad2: 0,
                _pad3: 0
            )
        }
    }

    // MARK: - Mesh visualizers

    private static func makeWireTerrain(context: MetalContext,
                                        pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        // Plane geometry — 30×30 world units on the XZ plane, 128×128 cells =
        // 129×129 verts laid out as a triangle list (2 tris × 128² cells × 3
        // verts = 98,304 vertices). Built once at factory time; MeshRenderer
        // uploads it to an .storageModeShared MTLBuffer and reads it every
        // frame. SIMD3<Float> stride is 16 B (includes trailing padding), so
        // the buffer is 98,304 × 16 ≈ 1.5 MB. Parity with web
        // THREE.PlaneGeometry(30, 30, 128, 128).rotateX(-π/2).
        let subdivs    = 128
        let planeSize: Float = 30.0
        let step:      Float = planeSize / Float(subdivs)
        let halfSize:  Float = planeSize / 2.0

        var verts: [SIMD3<Float>] = []
        verts.reserveCapacity(subdivs * subdivs * 6)
        for zi in 0..<subdivs {
            for xi in 0..<subdivs {
                let x0 = -halfSize + Float(xi)     * step
                let x1 = -halfSize + Float(xi + 1) * step
                let z0 = -halfSize + Float(zi)     * step
                let z1 = -halfSize + Float(zi + 1) * step
                // Two tris per cell, counter-clockwise wound when viewed from
                // +Y down. `.lines` triangleFillMode draws only the edges, so
                // winding only matters if we ever switch the fill mode back.
                verts.append(SIMD3<Float>(x0, 0, z0))
                verts.append(SIMD3<Float>(x1, 0, z0))
                verts.append(SIMD3<Float>(x1, 0, z1))
                verts.append(SIMD3<Float>(x0, 0, z0))
                verts.append(SIMD3<Float>(x1, 0, z1))
                verts.append(SIMD3<Float>(x0, 0, z1))
            }
        }

        let vertexCount  = verts.count
        let vertexStride = MemoryLayout<SIMD3<Float>>.stride
        let vertexData = verts.withUnsafeBufferPointer { buf -> Data in
            guard let base = buf.baseAddress else { return Data() }
            return Data(bytes: base, count: buf.count * vertexStride)
        }

        return try MeshRenderer<WireTerrainUniforms, WireTerrainState>(
            context: context,
            pixelFormat: pixelFormat,
            vertexFunction: "wireterrain_vs",
            fragmentFunction: "wireterrain_fs",
            label: "WireTerrain",
            vertexData: vertexData,
            vertexCount: vertexCount,
            vertexStride: vertexStride,
            triangleFillMode: .lines,
            initialState: WireTerrainState(),
            step: { state, audio, dt, res in
                // Monotonic clock drives both the vertex FBM phase and the
                // camera oscillator — parity with web `elapsed = t - startT`.
                state.clock += dt
                let clock = state.clock

                // Camera math — verbatim mirror of viz/wire-terrain.js:
                //   cAng = sin(elapsed*0.08)*0.9 + elapsed*0.05
                //   camY = 7.5 + sin(elapsed*0.3)*1.2
                //   camera.position = (cos(cAng)*14, camY, sin(cAng)*14)
                //   lookAt(0, 1.0 + bass*0.8, 0)
                // The web applies `react` to bass before passing it into
                // lookAt; iOS has no react slider yet, so `audio.bass` enters
                // raw (react == 1.0).
                let orbitAng = sinf(clock * 0.08) * 0.9 + clock * 0.05
                let camY     = 7.5 + sinf(clock * 0.3) * 1.2
                let eye      = SIMD3<Float>(cosf(orbitAng) * 14.0,
                                             camY,
                                             sinf(orbitAng) * 14.0)
                let center   = SIMD3<Float>(0.0, 1.0 + audio.bass * 0.8, 0.0)
                let up       = SIMD3<Float>(0.0, 1.0, 0.0)

                let aspect = max(0.0001, res.x / res.y)
                let proj   = perspectiveMatrix(
                    fovyRadians: 55.0 * .pi / 180.0,
                    aspect: aspect,
                    near: 0.1,
                    far: 200.0
                )
                let view   = lookAtMatrix(eye: eye, center: center, up: up)

                return WireTerrainUniforms(
                    projectionMatrix: proj,
                    viewMatrix:       view,
                    time:             clock,
                    bass:             audio.bass,
                    treble:           audio.treble,
                    beatPulse:        audio.beatPulse,
                    resolution:       res,
                    fogDensity:       0.035,
                    _pad0:            0
                )
            }
        )
    }
}
