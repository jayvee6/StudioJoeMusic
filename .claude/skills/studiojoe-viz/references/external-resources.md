# External resources

Curated references. Load from the web when the model needs them — don't mirror content here, just annotate why each matters.

## Shader / GPU fundamentals

### shader-tutorial.dev — https://shader-tutorial.dev/

Structured multi-section guide (Basics → Intermediates → Advanced) covering the render pipeline, math, vertex + fragment shaders, image generation, color/normal/specular mapping, lighting, branching, transparency, shadow mapping. Written clearly; good for first-principles refreshes.

Load when:
- Porting unfamiliar effect (e.g., normal mapping, shadow mapping)
- Double-checking vector/matrix/trig identities
- Explaining shader concepts to the user mid-session

Most-useful chapters for viz:
- `/basics/mathematics/` — vectors, matrices, trig. The trig section is load-bearing for the dual-time drift pattern (`patterns.md` §1).
- `/intermediates/lighting/` + `/normal-mapping/` + `/specular-mapping/` — pairs with `pbr.md`.
- `/advanced/branching/` — for understanding shader branch cost (`performance.md`).

### The Book of Shaders — https://thebookofshaders.com/

Classic interactive GLSL intro by Patricio Gonzalez Vivo and Jen Lowe. Covers SDFs, noise, FBM, fractals. Live examples in every chapter.

Load when:
- Need a noise or FBM variant beyond what's in patterns.md §8
- Picking an SDF primitive for a new viz
- Refreshing on `smoothstep`, `step`, `mix` idioms

### Inigo Quilez articles — https://iquilezles.org/articles/

Authoritative source on SDFs, distance functions, raymarching, noise, palette generation. The `smin` helper in patterns.md §10 is his. Any SDF-based viz (Rorschach, future raymarched scenes) should start here.

Most relevant articles:
- "distfunctions" — library of 2D/3D SDF primitives with formulas
- "smin" — the polynomial smooth-min derivation
- "raymarchingdf" — signed-distance raymarching
- "fbm" / "warp" — noise functions and domain warping
- "palettes" — procedural color palettes with cosine

## WebGL / OpenGL specs (authoritative)

### WebGL 1.0 spec — https://registry.khronos.org/webgl/specs/latest/1.0/

The canonical spec for the platform `musicplayer-viz` targets. Use when:
- A viz crashes on mobile Safari and you need to know what WebGL 1.0 guarantees vs optional extensions
- Debugging `getContext('webgl')` failures
- Checking what `gl.getParameter(...)` queries are available
- Confirming behavior of a specific WebGL API call

Note: WebGL 1.0 maps to OpenGL ES 2.0. If a feature is listed as ES 2.0, it's available in WebGL 1.0.

### OpenGL ES spec index — https://registry.khronos.org/OpenGL/index_es.php#specs

Landing page for all OpenGL ES spec PDFs. For WebGL 1.0, the relevant ones are:
- OpenGL ES 2.0 (the API WebGL 1.0 is based on)
- OpenGL ES Shading Language 1.00 (GLSL ES 1.0 — what Three.js r128 shaders are written in)

Use the GLSL ES 1.0 spec as the authority on:
- What built-in functions are available (`mix`, `smoothstep`, `step`, `mod`, `fract`, trig, etc.)
- Constant expression rules (see patterns.md §11)
- Precision qualifier semantics (`highp`, `mediump`, `lowp`)
- Uniform / varying / attribute qualifier rules

If you're ever unsure whether a GLSL construct is legal in WebGL, this is the source of truth.

## Three.js

### threejs.org/examples — https://threejs.org/examples

Enormous collection of live Three.js examples. Many assume r160+ ESM, but most patterns translate cleanly to r128 UMD with small syntax changes.

Load when:
- Evaluating whether to adopt a postprocessing pass (bloom, film, DOF, glitch — all have example sources)
- Seeing a canonical setup for `PMREMGenerator`, `EffectComposer`, shadow map, etc.
- Checking material usage patterns (MeshPhysicalMaterial, ShaderMaterial with `onBeforeCompile`)

Warning: r128 is old. Check the first few lines of any example for Three version assumptions before copying.

### WebGLFundamentals — https://webglfundamentals.org/

Non-Three.js, raw-WebGL fundamentals. Use when a bug is below the Three abstraction (e.g., texture binding, attribute setup, precision qualifiers). Detailed, no-magic explanations.

### WebGL2Fundamentals — https://webgl2fundamentals.org/

Same author, WebGL 2.0 (≈ ES 3.0). Mostly not relevant for r128 work, but useful if the user ever migrates to a WebGL 2 target.

## Algorithmic / procedural

### Sebastian Lague — https://github.com/SebLague + https://www.youtube.com/@SebastianLague

Unity C# source, but the ALGORITHMS are directly translatable to GLSL/Metal. His "Coding Adventures" YouTube series is the pedagogical anchor — watch the video, study the C# for the algorithm, translate to shader code yourself.

Relevant projects / videos:
- **Slime-Simulation** — Physarum-style agent-based patterns. Good source for procedural organic-growth textures.
- **Fluid-Sim** — particle-based SPH fluid. Directly relevant to Ferrofluid (iOS spring-damper currently; could be generalized).
- **Geographical-Adventures** / procedural terrain — useful for future terrain-style viz.
- **Solar-System** / atmospheric scattering / planet shader — directly relevant to Lunar. Atmosphere, orbit mechanics, surface shading.
- **Ray Tracing series** — pedagogical ray tracing; applicable if a future viz wants RT reflections.
- **Marching Cubes** — volumetric iso-surface extraction; relevant for volumetric/cloud viz.

Load a video for the explanation; load the repo for the algorithm code.

### ShaderToy — https://www.shadertoy.com/

Live shader playground. Massive library of user-contributed GLSL. Use for:
- Searching for a specific effect ("metaball ink", "kaleidoscope tunnel")
- Cross-checking an SDF or noise formulation
- Finding a starting point for a new viz's prototype phase

Warning: ShaderToy uses its own uniform conventions (`iResolution`, `iTime`, `iMouse`). Translate to the skill's uniform names (`u_resolution`, `u_time`, etc.) during port.

## How to add a new resource

If the user points you at a new resource during a session:
1. Fetch the landing page to confirm it's alive and understand scope.
2. Add a short entry here with one-line description, URL, and "load when" guidance.
3. If the resource is specifically load-bearing for a pattern in `patterns.md` or a technique in `pbr.md` / `performance.md`, cross-link both ways.
4. Don't mirror content — just link + annotate.
