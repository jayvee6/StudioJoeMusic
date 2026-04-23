# Stack contracts

API contracts and data shapes shared across the web app (`musicplayer-viz`) and the iOS app (`StudioJoeMusic`). Treat these as the non-negotiable surface a new viz plugs into.

## Web — viz registry

`window.Viz.register(def)` registers a visualizer. The registry lives in `viz-registry.js` and is loaded before any `viz/*.js` file.

```js
window.Viz.register({
  id:         'unique-id',        // stable string id
  label:      'Button Text',
  kind:       '2d' | 'webgl',     // picks which shared canvas is shown
  initFn:     () => void,         // optional; lazy — runs on first activation
  renderFn:   (t, frame) => void, // required; runs every frame while active
  teardownFn: () => void,         // optional; runs when switching away
  controls:   ControlDef[],       // optional
  layout:     'vertical'          // optional; default is horizontal inline
});
```

Control types (`controls[]`):

| Type | Fields | Returns from `controlValue` |
|---|---|---|
| `slider` (default) | `id`, `label`, `min`, `max`, `step?`, `default?`, `showValue?` | number |
| `number` | `id`, `label`, `min`, `max`, `step?`, `default?`, `width?` | number |
| `text` | `id`, `label`, `default?`, `placeholder?`, `width?`, `showValue?` | string |
| `toggle` | `id`, `label`, `default?` | boolean |
| `button` | `id`, `label`, `onClick` | `null` (buttons use onClick) |

Read live values at render time:

```js
const drift = window.Viz.controlValue('my-viz', 'drift');
```

Other registry helpers:
- `window.Viz.setMode(index | id)` — switch active viz
- `window.Viz.activeId` — current id (getter)
- `window.Viz.currentIndex` — current index (getter)
- `window.Viz.entries` — defensive copy of registered entries
- `window.Viz.syncButtons()` — force mode-button row rebuild (rarely needed)

Lifecycle:

1. `register` → button + control row appended immediately.
2. First `setMode` on this id → `initFn` runs once.
3. Every frame while active → `renderFn(t, frame)`.
4. `setMode` away → `teardownFn` runs (if present).
5. `setMode` back → `renderFn` only; `initFn` never re-runs.

## Web — AudioFrame

Returned by `window.AudioEngine.currentFrame()` and passed as the second arg to `renderFn`:

```js
{
  time:         number,        // seconds elapsed, monotonic
  bass:         number,        // 0..1, EMA-smoothed by engine
  mid:          number,        // 0..1
  treble:       number,        // 0..1
  beatPulse:    number,        // 0..1, decays with exp(-8*dt) after an onset
  bpm:          number,        // live-detected BPM
  isBeatNow:    boolean,       // true only on the frame an onset fires
  bassHistory:  Float32Array,  // recent bass samples, for trails/echoes
  magnitudes:   Float32Array,  // 32 mel bins, 0..1
  valence:      number,        // 0..1 (Spotify audio-features; 0.5 default)
  energy:       number,        // 0..1
  danceability: number,        // 0..1
  tempoBPM:     number,        // Spotify-reported tempo (may differ from bpm)
  width:        number,        // canvas pixels
  height:       number
}
```

Note: `beatPulse` is ALREADY the detector's `exp(-8*dt)` envelope output. For sharp per-beat punches, pass it through raw. For sustained shape, apply an additional EMA on top (see `patterns.md`).

## Web — shared render surfaces

- `window.ctx` — 2D canvas context, DPR-scaled. Used by `kind: '2d'` viz.
- `window.canvas2d` — the underlying `<canvas>` element.
- `window.vizGL` — `{ renderer, camera }`. Shared Three.js r128 renderer + orthographic camera (for full-screen shader viz). A viz can bring its own perspective camera and pass it to `renderer.render(scene, myCam)` instead.
- `window.initThree()` — lazy bootstrap. Call defensively in `renderFn` if `window.vizGL` is null on first activation:

  ```js
  if (!window.vizGL && typeof window.initThree === 'function') window.initThree();
  ```

- `window.vizSharedRotY` — float accumulator shared by sphere viz (Lunar, Disco, Chrome). Read and write both:

  ```js
  window.vizSharedRotY = (window.vizSharedRotY ?? 0) + dt * (0.08 + bass * 0.30);
  mesh.rotation.y = window.vizSharedRotY;
  ```

## Web — Three.js r128 specifics

- Loaded via CDN UMD as a global `THREE`. Postprocessing scripts from `three@0.128.0/examples/js/*` on jsdelivr. NOT ESM r160.
- Defaults differ from r160:
  - `physicallyCorrectLights = false`
  - `toneMapping = THREE.NoToneMapping`
  - `outputEncoding = THREE.LinearEncoding`
- If a viz flips any of these, save the previous value in `initFn` and restore in `teardownFn`. See `patterns.md` → "ACES + physicallyCorrectLights".
- `EffectComposer`, `RenderPass`, `ShaderPass`, `UnrealBloomPass` all available via the jsdelivr examples path.

## iOS — VisualizerMode enum

`Packages/Core/Sources/Core/Rendering/VisualizerMode.swift`

```swift
public enum VisualizerMode: Int, CaseIterable, Identifiable, Sendable {
    case bars = 0, blob, mandala, hypnoRings, spiral, subwoofer,
         emojiVortex, emojiWaves, ferrofluid, rorschach, lunar,
         kaleidoScope, dvdMode, fireworks

    public var id: Int { rawValue }
    public var title: String { ... }         // short UI label
    public var symbol: String { ... }        // SF Symbols name
    public var isMetal: Bool { ... }         // false for Canvas-2D (bars, dvdMode, fireworks)
    public var needsEmojiAtlas: Bool { ... } // only emojiVortex, emojiWaves
}
```

When adding a new viz: APPEND the case (raw values are stable and persisted — don't reorder). Add entries to `title`, `symbol`, `isMetal`, `needsEmojiAtlas`.

## iOS — VisualizerFactory

`Packages/Core/Sources/Core/Rendering/VisualizerFactory.swift`

Entry point:

```swift
@MainActor
public enum VisualizerFactory {
    public static func make(mode: VisualizerMode,
                            context: MetalContext,
                            pixelFormat: MTLPixelFormat,
                            atlas: EmojiAtlas?) throws -> VisualizerRenderer?
}
```

Switches on mode, returns a `VisualizerRenderer?`. Returns `nil` for Canvas-2D viz (those are rendered by SwiftUI `Canvas` views, not Metal).

Generic templates:

- `FragmentRenderer<U, S>` — full-screen quad, fragment-only shader. `U` = uniforms struct, `S` = CPU state struct (`Void` if no state). The per-frame closure receives `(state, audio, dt, res)` and returns `U`.
- `InstancedAtlasRenderer<U, S>` — adds `atlas: MTLTexture` and `instanceCount`. Used by EmojiVortex, EmojiWaves.
- For pipelines that need custom render passes (e.g., `FerroRenderer` for ferrofluid's CPU spring-damper + tent-interpolated fragment), implement a dedicated class conforming to `VisualizerRenderer`.

## iOS — uniform struct layout rules

Swift `YourVizUniforms` MUST layout-match the Metal `struct Uniforms` exactly. Rules:

- Keep `SIMD2<Float>` / `float2` on an 8-byte boundary. Pad with floats before it if needed.
- Document the total byte size in a comment on the struct. Example from `RorschachUniforms`:

  ```swift
  // 48 bytes total. 4 floats (16 bytes) before float2 resolution keeps it 8-byte aligned.
  ```

- Don't reorder fields between Swift and Metal.
- When growing, prefer appending floats after the last float2 — floats fit 4-byte-safely into the 16-byte slot following a float2.
- Don't rely on Swift's implicit tail padding. Add explicit named fields (even `var _pad: Float = 0`, later repurposed).

## iOS — fragment shader skeleton

```metal
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time;
    // ... audio + mood fields ...
    float2 resolution;   // on 8-byte boundary — document offset
    // ... more fields ...
};

struct VSOut { float4 position [[position]]; float2 uv; };

vertex VSOut yourviz_vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

fragment float4 yourviz_fs(VSOut in [[stage_in]],
                            constant Uniforms& u [[buffer(0)]]) {
    // ... full-screen shader body ...
}
```

Vertex shader emits a full-screen triangle via `vid`; no vertex buffer. Fragment receives UVs ∈ [0,1].

## Parity note

Sin/cos frequencies, reactivity coefficients, EMA time constants, breath rates, speed ceilings, and color mappings must stay synced web ↔ iOS. See `parity.md` for the full rule and what does NOT count as tuning.
