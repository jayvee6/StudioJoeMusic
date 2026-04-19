import Metal
import simd

// MARK: - Uniform structs (layout-compatible with corresponding Metal structs)

public struct BlobUniforms {
    public var time: Float = 0
    public var audio: Float = 0
    public var resolution: SIMD2<Float> = .zero
}

public struct MandalaUniforms {
    public var time: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var resolution: SIMD2<Float> = .zero
}

public struct HypnoUniforms {
    public var time: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var resolution: SIMD2<Float> = .zero
}

public struct SpiralUniforms {
    public var time: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var resolution: SIMD2<Float> = .zero
}

public struct SubwooferUniforms {
    public var time: Float = 0
    public var bass: Float = 0
    public var beatPulse: Float = 0
    public var resolution: SIMD2<Float> = .zero
}

public struct VortexUniforms {
    public var time: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var twist: Float = 2.0
    public var scale: Float = 1.0
    public var rippleAmp: Float = 0.08
    public var resolution: SIMD2<Float> = .zero
    public var atlasGrid: SIMD2<Float> = .init(4, 3)
}

public struct WavesUniforms {
    public var time: Float = 0
    public var bass: Float = 0
    public var treble: Float = 0
    public var ringScale: Float = 0.13
    public var spin: Float = 0.5
    public var resolution: SIMD2<Float> = .zero
    public var atlasGrid: SIMD2<Float> = .init(4, 3)
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
            return try FerroRenderer(context: context, pixelFormat: pixelFormat, spikeCount: 32)
        }
    }

    // MARK: - Fragment-only visualizers

    private static func makeBlob(context: MetalContext,
                                 pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentVisualizerRenderer<BlobUniforms>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "blob_vs", fragmentFunction: "blob_fs",
            label: "Blob"
        ) { a, res in
            let audio = min(1.0, a.bass * 0.75 + a.beatPulse * 0.45)
            return BlobUniforms(time: a.time, audio: audio, resolution: res)
        }
    }

    private static func makeMandala(context: MetalContext,
                                    pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentVisualizerRenderer<MandalaUniforms>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "mandala_vs", fragmentFunction: "mandala_fs",
            label: "Mandala"
        ) { a, res in
            MandalaUniforms(time: a.time, bass: a.bass, treble: a.treble, resolution: res)
        }
    }

    private static func makeHypno(context: MetalContext,
                                  pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentVisualizerRenderer<HypnoUniforms>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "hypno_vs", fragmentFunction: "hypno_fs",
            label: "Hypno"
        ) { a, res in
            HypnoUniforms(time: a.time, bass: a.bass, treble: a.treble, resolution: res)
        }
    }

    private static func makeSpiral(context: MetalContext,
                                   pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentVisualizerRenderer<SpiralUniforms>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "spiral_vs", fragmentFunction: "spiral_fs",
            label: "Spiral"
        ) { a, res in
            SpiralUniforms(time: a.time, bass: a.bass, treble: a.treble, resolution: res)
        }
    }

    private static func makeSubwoofer(context: MetalContext,
                                      pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentVisualizerRenderer<SubwooferUniforms>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "subwoofer_vs", fragmentFunction: "subwoofer_fs",
            label: "Subwoofer"
        ) { a, res in
            SubwooferUniforms(time: a.time, bass: a.bass, beatPulse: a.beatPulse, resolution: res)
        }
    }

    // MARK: - Instanced atlas visualizers

    private static func makeVortex(context: MetalContext,
                                   pixelFormat: MTLPixelFormat,
                                   atlas: EmojiAtlas) throws -> VisualizerRenderer {
        let grid = SIMD2<Float>(Float(atlas.columns), Float(atlas.rows))
        return try InstancedAtlasRenderer<VortexUniforms>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "vortex_vs", fragmentFunction: "vortex_fs",
            atlas: atlas.texture,
            instanceCount: 12 * 13,  // matches ARMS * STEPS in EmojiVortex.metal
            label: "EmojiVortex"
        ) { a, res in
            VortexUniforms(
                time: a.time,
                bass: a.bass,
                treble: a.treble,
                twist: 1.8 + a.bass * 2.0,
                scale: 1.0 + a.bass * 0.08,
                rippleAmp: 0.065,
                resolution: res,
                atlasGrid: grid
            )
        }
    }

    private static func makeWaves(context: MetalContext,
                                  pixelFormat: MTLPixelFormat,
                                  atlas: EmojiAtlas) throws -> VisualizerRenderer {
        let grid = SIMD2<Float>(Float(atlas.columns), Float(atlas.rows))
        return try InstancedAtlasRenderer<WavesUniforms>(
            context: context, pixelFormat: pixelFormat,
            vertexFunction: "waves_vs", fragmentFunction: "waves_fs",
            atlas: atlas.texture,
            instanceCount: 6 * 12,
            label: "EmojiWaves"
        ) { a, res in
            WavesUniforms(
                time: a.time,
                bass: a.bass,
                treble: a.treble,
                ringScale: 0.13,
                spin: 0.4 + a.treble * 0.3,
                resolution: res,
                atlasGrid: grid
            )
        }
    }
}
