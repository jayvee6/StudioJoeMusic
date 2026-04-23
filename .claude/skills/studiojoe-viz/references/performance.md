# Performance

Real-time GPU optimization playbook for music viz. Target: 60 fps on desktop Safari and an A15 iPhone; stay above 30 fps on an A12 iPhone / integrated-GPU laptop. If a viz drops below that, the music feels decoupled from the image.

## Before optimizing, measure

The cheapest optimization is the one you don't need. Check first:

- Is the viz actually dropping frames, or does it just feel laggy (latency ≠ throughput)?
- Which phase is slow — vertex, fragment, CPU updates, blit, or the composer pass chain?
- Browser DevTools → Performance → GPU track for web. Instruments → Metal System Trace for iOS.
- If you have no profiler data, don't guess. Add `performance.now()` timing around suspect phases first.

## Web — Three.js r128 / WebGL 1.0

### DPR clamp

Every viz should clamp renderer pixel ratio. Without this, a retina iPhone renders at 3x = 9x fragment cost:

```js
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
```

Set once on init. For ultra-heavy raymarched shaders, dropping to 1 on mobile is fine — the blur is hidden by the motion.

### Raymarch step cap by device

Raymarched fragment shaders (Rorschach's SDF, future raymarched scenes) should adapt iteration count to device capability. Feature-detect once at load:

```js
const isMobile = /Mobi|Android|iPhone|iPad/i.test(navigator.userAgent);
const MAX_STEPS = isMobile ? 32 : 64;
```

Pass as a `uniform int u_maxSteps` and use it with a constant bound + break (see `patterns.md` §11 for GLSL ES 1.0 loop constraints).

### Shader branching

GLSL ES 1.0 implementations often unroll every `for` loop. Conditional branches inside the shader are fine for modern GPUs but can double the cost on older integrated GPUs because both branches execute. When a viz has `if (u_flag) { expensive() }`, consider factoring into two shader variants selected at `ShaderMaterial` construction, not at runtime.

### Postprocessing passes

EffectComposer's UnrealBloomPass is NOT free — it adds ~3–5 ms on a typical mobile GPU. If a viz uses bloom:

- Set `UnrealBloomPass.resolution` to half the render size (e.g., `new Vector2(w/2, h/2)`).
- Skip bloom entirely on detected-weak GPUs.
- Lower `strength` before lowering `radius` — they're not equivalent.

### Avoid per-frame object allocation

```js
// BAD — allocates every frame
u.u_resolution.value = new THREE.Vector2(w, h);

// GOOD — reuses the existing Vector2
u.u_resolution.value.set(w, h);
```

GC pauses during a viz are very visible (frame drops every few seconds). The viz skeletons in `new-viz-recipe.md` follow the `.set()` pattern.

### Texture size

LROC albedo + LDEM displacement textures for Lunar are 4K. Downsample to 2K for the WebGL target; the retina display doesn't resolve the difference at typical viewing distance. Less VRAM → less bandwidth pressure per frame.

## Web — WebGL 1.0 / GLSL ES 1.0 spec constraints

Authoritative references:
- WebGL 1.0 spec: https://registry.khronos.org/webgl/specs/latest/1.0/
- OpenGL ES index (GLSL ES 1.0 lives under ES 2.0): https://registry.khronos.org/OpenGL/index_es.php#specs

Key constraints GLSL ES 1.0 enforces that catch ports from newer shader code:
- For-loops must have constant expression bounds (patterns.md §11).
- No `dynamic indexing` of arrays (some implementations — wrap in explicit-switch if portability matters).
- No texture lookups in vertex shaders on some mobile GPUs (check `gl.getParameter(gl.MAX_VERTEX_TEXTURE_IMAGE_UNITS)`).
- Precision qualifiers (`precision highp float;`) are required at the top of a fragment shader — some mobile GPUs default to `mediump`, which is 16-bit and breaks raymarched SDFs.

## iOS — Metal

### Triple-buffered uniforms

When CPU writes uniforms while GPU is reading the previous frame's uniforms, you get stalls or wrong values. Use a 3-slot buffer + semaphore:

```swift
private let inFlightSemaphore = DispatchSemaphore(value: 3)
// ...
inFlightSemaphore.wait()
commandBuffer.addCompletedHandler { [semaphore = inFlightSemaphore] _ in
    semaphore.signal()
}
```

See `metal-samples-index.md` → **SynchronizingCPUAndGPUWork** for the full pattern. The user's existing `FragmentRenderer` scaffold already handles this.

### Immutable small buffers

For uniforms structs under 4KB, use `setBytes(...)` instead of `makeBuffer` + writing. It's GPU-private and avoids the CPU-GPU sync cost entirely:

```swift
encoder.setFragmentBytes(&uniforms, length: MemoryLayout<YourVizUniforms>.stride, index: 0)
```

All the `FragmentRenderer<U, S>`-based viz in the factory do this.

### Drawable count

`MTKView.preferredFramesPerSecond = 60` is the default. If a viz is legitimately unable to hold 60, drop to 30 rather than shipping a stuttery 60 — `preferredFramesPerSecond = 30` locks vsync to every other refresh, which reads as smooth at half rate. See **AchievingSmoothFrameRatesWithMetalsDisplayLink** sample.

### MetalFX upscaling

For a raymarched viz pegging the fragment shader, run at half resolution + upscale with MetalFX temporal AA. See **ApplyingTemporalAntialiasingAndUpscalingUsingMetalFX** in the index. Requires iOS 16 + A13 or newer — feature-detect before enabling.

### Avoid large uniform structs

Metal buffer binding has a fast path for small structs. If a viz uniforms struct grows past ~200 bytes, consider splitting audio uniforms from mood/mode uniforms and binding them at two different indices.

## Both platforms

### Profile the shader, not the app

If frame time is dominated by fragment work (usual case for full-screen shader viz), app-level optimization is noise. Profile the shader:

- **Web**: Spector.js for WebGL frame capture. Look at fragment shader ALU ops + texture fetches.
- **iOS**: Instruments → Metal System Trace. Shader profiler shows per-instruction cost.

### Resolution is the biggest lever

Halving the render resolution is ~4x faster for fragment-bound viz. If a viz is 20% slow, dropping resolution 10% is usually enough. Keep the display size unchanged; just render smaller and let the hardware upscale.

### Culling dormant viz

When a viz is not active, its `teardownFn` should release GL/Metal resources — not just hide the canvas. Otherwise switching between 5 viz leaves 5 scenes' worth of GPU memory allocated. The user's registry does call teardown on mode switch; just make sure individual viz implement it if they allocated textures, scenes, or materials in init.

### Don't over-smooth the audio

Adding an EMA with tau > 1.0 on bass can hide perf problems temporarily — the viz stops reacting to frame drops because the shape barely changes. Verify your perf improvements by watching the viz react to a staccato kick drum; if beat response is visibly delayed, the tau is too long.
