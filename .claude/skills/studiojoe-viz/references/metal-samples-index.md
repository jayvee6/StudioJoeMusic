## How to use this index

Samples are grouped by tier:
- **HIGH** — techniques directly applicable to music viz; read these first when a relevant problem comes up.
- **MEDIUM** — applicable with adaptation; scan for ideas if the obvious approach isn't working.
- **LOW** — out of scope for music viz (game porting, OpenGL migration, specialized RT). Skip unless an exotic problem surfaces.

For each HIGH and MEDIUM sample, the "Viz relevance" column says WHY it matters. Open the sample's README.md first; drill into shaders only if the README suggests it.

Path base: `/Users/jdot/Documents/Development/MetalSampleCode/`

## HIGH tier — core viz techniques

| Sample | What it teaches | Viz relevance |
|---|---|---|
| AchievingSmoothFrameRatesWithMetalsDisplayLink | Display link for frame pacing and input latency reduction | Critical for synced audio-reactive frame rates; essential for smooth animation loops. Use when a viz feels microstuttery even though FPS is 60. |
| ImprovingEdgeRenderingQualityWithMultisampleAntialiasingMSAA | MSAA with custom resolve, tone-mapping, tile shaders | Antialiasing for crisp line art (Seismic mesh wireframe, Chrome facet edges). Tile shaders also apply to tone-mapping HDR renders. |
| RenderingASceneWithDeferredLightingInSwift | Deferred G-buffer, light volumes, stencil culling; single-pass on TBDR | Multi-light PBR viz patterns (future Chrome-style scenes with multiple stage lights). Raster order groups + memoryless storage for efficiency. |
| ApplyingTemporalAntialiasingAndUpscalingUsingMetalFX | MetalFX temporal antialiasing + upscaling | Run the heavy raymarch at 0.5x render scale + upscale with MetalFX on devices that support it. Smooths animated content too. |
| CustomizingShadersUsingFunctionPointersAndStitching | Function pointers for runtime shader variant selection | Runtime shader switching for mood-driven viz — e.g., swap the FBM octave count or color mapping without recompiling pipelines. |
| SynchronizingCPUAndGPUWork | Triple-buffering, semaphores, immutable buffers for CPU/GPU sync | Prevents stalls when CPU writes audio parameters while GPU renders. Essential whenever audio-reactive updates feel "laggy" relative to what you hear. |

## MEDIUM tier — applicable with adaptation

| Sample | What it teaches | Viz relevance |
|---|---|---|
| CombiningBlitAndComputeOperationsInASinglePass | Unified compute encoder: blit + dispatch in one pass | GPU-driven texture composition. Useful for procedural texture updates synchronized with audio (e.g., accumulating feedback buffers for trails). |
| ManagingGroupsOfResourcesWithArgumentBuffers | Argument buffer encoding + GPU resource handles (Metal 2 & 3) | Efficient multi-sampler/texture setups for complex shaders (e.g., Lunar's LROC albedo + LDEM displacement + normal map). Reduces CPU overhead. |
| EncodingArgumentBuffersOnTheGPU | GPU-side argument buffer encoding | For GPU-driven pipelines that adapt to audio analysis without CPU round-trip. Advanced; only if you hit a real bottleneck. |
| SelectingDeviceObjectsForComputeProcessing | Multi-GPU compute dispatch; N-body particle simulation | Compute kernels for particle effects driven by audio (e.g., FFT-based particle emission, Ferrofluid spring sim if it ever leaves CPU). |
| ProcessingHDRImagesWithMetal | HDR rendering pipeline + tone-mapping operators | Linear-space rendering + tone-mapping for vibrant wide-gamut viz. Pairs with the ACES tone mapping pattern in `patterns.md`. |
| UsingArgumentBuffersWithResourceHeaps | Resource heaps + argument buffers for batched rendering | Scales to many textures/samplers; useful for animated texture atlases (EmojiVortex, EmojiWaves already use an atlas). |
| EncodingIndirectCommandBuffersOnTheGPU | GPU-driven indirect draws | Compute shader can encode draw calls based on audio levels (e.g., spawn geometry per frequency bin). Advanced; only if per-frame CPU encoding is the bottleneck. |
| ImplementingAMultistageImageFilterUsingHeapsAndFences | Heaps, fences, multi-pass filters | GPU synchronization for chained post-processing (bloom → motion blur → color grade) tied to audio envelopes. |
| RenderingASceneWithForwardPlusLightingUsingTileShaders | Tile-based forward+ with light culling | Tile shaders can aggregate per-tile audio analysis. Efficient for light-reactive scenes with many small lights. |

## LOW tier — out of scope for music viz

These exist in the sample pack; the skill lists them so a search doesn't circle back to them.

| Sample | Why skipped |
|---|---|
| AcceleratingRayTracingUsingMetal | RT overkill for rasterization-based viz. |
| AcceleratingRayTracingAndMotionBlurUsingMetal | Motion blur better achieved via screen-space post. |
| RayQueryExample, RayTracingPipelinesExample, RaytracingWithIFB, RenderingReflectionsInRealTimeUsingRayTracing, RenderingACurvePrimitiveInARayTracingScene, ControlTheRayTracingProcessUsingIntersectionQueries | Game/film RT; not real-time music viz territory. |
| TessellationGeometryInstancing | Tessellation specialized for geometry-heavy scenes; viz typically use compute-driven mesh deformation or shader displacement. |
| StreamingLargeImagesWithMetalSparseTextures | Large-scale streaming; viz use preloaded or procedural textures. |
| FunctionConstantsAndFramebufferFetch | Framebuffer fetch covered in deferred lighting sample above. |
| LoadingTexturesAndModelsUsingMetalFastResourceLoading | Infrastructure; not viz-specific. |
| ReadingPixelDataFromADrawableTexture | CPU readback introduces latency; viz render to screen, not CPU. |
| CreatingACustomMetalView, SelectingDeviceObjectsForGraphicsRendering, CustomizingRenderPassSetup, CapturingMetalCommandsProgrammatically | Basic Metal setup; covered by `MetalContext.swift` + `MetalVisualizerView.swift` in the app. |
| MigratingOpenGLCodeToMetal, MixingMetalAndOpenGLRenderingInAView, StartingAGamePortWithMetal | OpenGL migration + game porting; irrelevant. |
| LearnMetalCPP, CreatingAMetalDynamicLibrary | C++ Metal API + dynamic libraries; viz is Swift-first. |
| SupportingSimulatorInAMetalApp | Simulator-specific scaffolding. |
| ModernRenderingWithMetal | Abstract overview; covered piecemeal by other HIGH samples. |
| RenderingReflectionsWithFewerRenderPasses | Environmental reflections less relevant than audio reactivity. |
| RenderingTerrainDynamicallyWithArgumentBuffers | Terrain rendering; viz don't render terrain. |
| EncodingIndirectCommandBuffersOnTheCPU | GPU-side (MEDIUM above) is preferred for real-time audio. |
| CullingOccludedGeometryUsingTheVisibilityResultBuffer | Occlusion culling for heavy scenes; viz don't have complex occlusion. |
| ImplementingOrderIndependentTransparencyWithImageBlocks | OIT for complex translucent scenes; usually overkill. |

## How to borrow from a sample

1. Read the sample's README.md first — it usually explains the setup and the key insight in one page.
2. Then read the main shader file (`*.metal`) to see the actual technique.
3. Isolate the technique (e.g., "how they set up MSAA with custom resolve") as a ~30-line snippet.
4. Graft it into the existing `MetalContext` + `FragmentRenderer` scaffolding in `StudioJoeMusic`. Don't wholesale-copy their app structure — the user's repo already has a renderer harness.
5. If the technique has a web analog (e.g., MSAA → `WebGLRenderer({antialias:true, samples:4})`), update both sides. Parity rule applies.
