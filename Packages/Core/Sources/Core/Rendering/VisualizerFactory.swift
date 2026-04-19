import Metal
import simd

// MARK: - Per-visualizer uniform structs (must match layout in the .metal file)

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

// MARK: - Factory

@MainActor
public enum VisualizerFactory {
    public static func make(mode: VisualizerMode,
                            context: MetalContext,
                            pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer? {
        switch mode {
        case .bars: return nil  // not Metal-rendered
        case .blob: return try makeBlob(context: context, pixelFormat: pixelFormat)
        case .mandala: return try makeMandala(context: context, pixelFormat: pixelFormat)
        case .hypnoRings: return try makeHypno(context: context, pixelFormat: pixelFormat)
        case .spiral: return try makeSpiral(context: context, pixelFormat: pixelFormat)
        case .subwoofer: return try makeSubwoofer(context: context, pixelFormat: pixelFormat)
        }
    }

    private static func makeBlob(context: MetalContext, pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentVisualizerRenderer<BlobUniforms>(
            context: context,
            pixelFormat: pixelFormat,
            vertexFunction: "blob_vs",
            fragmentFunction: "blob_fs",
            label: "Blob"
        ) { a, res in
            let audio = min(1.0, a.bass * 0.75 + a.beatPulse * 0.45)
            return BlobUniforms(time: a.time, audio: audio, resolution: res)
        }
    }

    private static func makeMandala(context: MetalContext, pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentVisualizerRenderer<MandalaUniforms>(
            context: context,
            pixelFormat: pixelFormat,
            vertexFunction: "mandala_vs",
            fragmentFunction: "mandala_fs",
            label: "Mandala"
        ) { a, res in
            MandalaUniforms(time: a.time, bass: a.bass, treble: a.treble, resolution: res)
        }
    }

    private static func makeHypno(context: MetalContext, pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentVisualizerRenderer<HypnoUniforms>(
            context: context,
            pixelFormat: pixelFormat,
            vertexFunction: "hypno_vs",
            fragmentFunction: "hypno_fs",
            label: "Hypno"
        ) { a, res in
            HypnoUniforms(time: a.time, bass: a.bass, treble: a.treble, resolution: res)
        }
    }

    private static func makeSpiral(context: MetalContext, pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentVisualizerRenderer<SpiralUniforms>(
            context: context,
            pixelFormat: pixelFormat,
            vertexFunction: "spiral_vs",
            fragmentFunction: "spiral_fs",
            label: "Spiral"
        ) { a, res in
            SpiralUniforms(time: a.time, bass: a.bass, treble: a.treble, resolution: res)
        }
    }

    private static func makeSubwoofer(context: MetalContext, pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
        try FragmentVisualizerRenderer<SubwooferUniforms>(
            context: context,
            pixelFormat: pixelFormat,
            vertexFunction: "subwoofer_vs",
            fragmentFunction: "subwoofer_fs",
            label: "Subwoofer"
        ) { a, res in
            SubwooferUniforms(time: a.time, bass: a.bass, beatPulse: a.beatPulse, resolution: res)
        }
    }
}
