# New viz recipe

Step-by-step for adding a new music visualizer to both repos. Building a viz happens in 4 phases — don't move past a phase until its exit condition is met.

## Overview

| Phase | Output | Exit condition |
|---|---|---|
| 1. Prototype | `musicplayer-viz/prototypes/your-viz.html` | User sees it in browser, confirms the look |
| 2. Web integration | `musicplayer-viz/viz/your-viz.js` + `<script>` tag in `index.html` | Registers correctly, audio-reactive, appears in mode switcher |
| 3. iOS shader port | `Shaders/YourViz.metal` + factory entry in `VisualizerFactory.swift` | Metal fragment compiles, Swift uniforms layout-match |
| 4. Parity check | Numerical constants mirrored | GLSL coefficients = Metal coefficients; EMA taus match |

Skip Phase 1 only if the viz is a trivial variation of an existing one (e.g., Kaleidoscope with a different fold count).

## Phase 1 — Prototype (standalone HTML)

Why: integration touches registry, shared renderer state, DPR, audio wiring, control UI all at once. Prototype isolates aesthetic decisions — once the user signs off on the look, integration becomes a mechanical port.

Location: `musicplayer-viz/prototypes/your-viz.html`. Self-contained single file.

Template:

```html
<!doctype html>
<html>
<head><meta charset="utf-8"><title>your-viz prototype</title>
<style>
  html,body{margin:0;height:100%;background:#000;overflow:hidden}
  canvas{display:block;width:100vw;height:100vh}
</style></head>
<body>
<script src="https://cdn.jsdelivr.net/npm/three@0.128.0/build/three.min.js"></script>
<!-- postprocessing scripts here if you need UnrealBloomPass / EffectComposer -->
<script>
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.setSize(innerWidth, innerHeight);
document.body.appendChild(renderer.domElement);
const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(60, innerWidth/innerHeight, 0.1, 100);
camera.position.z = 5;

// ... your geometry + material here ...

// Fake audio frame — swap for real audio later.
function fakeFrame(t) {
  return {
    time: t,
    bass:   (Math.sin(t * 0.5)  + 1) * 0.5,
    mid:    (Math.sin(t * 0.9)  + 1) * 0.5,
    treble: (Math.sin(t * 1.6)  + 1) * 0.5,
    beatPulse: Math.max(0, Math.sin(t * 2.0)) ** 4,
    valence: 0.6, energy: 0.7, danceability: 0.6, tempoBPM: 120,
  };
}

function loop() {
  const t = performance.now() / 1000;
  const f = fakeFrame(t);
  // ... update uniforms from f ...
  renderer.render(scene, camera);
  requestAnimationFrame(loop);
}
addEventListener('resize', () => {
  renderer.setSize(innerWidth, innerHeight);
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
});
loop();
</script></body></html>
```

Serve it: `cd /Users/jdot/Documents/Development/musicplayer-viz && node serve.js`, then browse `http://127.0.0.1:3001/prototypes/your-viz.html`.

When the user signs off on the look, move to Phase 2.

## Phase 2 — Web integration

Location: `musicplayer-viz/viz/your-viz.js`. Add a `<script src="viz/your-viz.js"></script>` to `index.html` in the viz-scripts block.

Skeleton for a fragment-shader viz:

```js
// your-viz — one-line description.
//
// Render strategy: [single full-screen quad? scene with mesh? 2D canvas?]
// CPU: [what it accumulates per frame and passes as uniforms]
// GPU: [what the shader does]
//
// Depends on: window.Viz, window.AudioEngine, window.vizGL, THREE

(() => {
  if (typeof THREE === 'undefined' || !window.Viz) return;

  const VS = `
    varying vec2 vUv;
    void main() { vUv = uv; gl_Position = vec4(position, 1.0); }
  `;

  const FS = `
    precision highp float;
    varying vec2 vUv;
    uniform float u_time;
    uniform float u_bass;
    uniform float u_mid;
    uniform float u_treble;
    uniform float u_beatPulse;
    uniform vec2  u_resolution;
    uniform float u_valence;
    uniform float u_energy;
    uniform float u_danceability;

    void main() {
      float aspect = u_resolution.x / u_resolution.y;
      vec2 uv = (vUv - 0.5) * vec2(aspect, 1.0);
      // ... shader body ...
      gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
    }
  `;

  let scene = null, mat = null;

  function init() {
    if (!window.vizGL && typeof window.initThree === 'function') window.initThree();
    const gl = window.vizGL;
    if (!gl) { console.warn('[your-viz] window.vizGL not ready'); return; }
    scene = new THREE.Scene();
    mat = new THREE.ShaderMaterial({
      uniforms: {
        u_time:         { value: 0 },
        u_bass:         { value: 0 },
        u_mid:          { value: 0 },
        u_treble:       { value: 0 },
        u_beatPulse:    { value: 0 },
        u_resolution:   { value: new THREE.Vector2(innerWidth, innerHeight) },
        u_valence:      { value: 0.5 },
        u_energy:       { value: 0.5 },
        u_danceability: { value: 0.5 },
      },
      vertexShader: VS,
      fragmentShader: FS,
    });
    scene.add(new THREE.Mesh(new THREE.PlaneGeometry(2, 2), mat));
  }

  function render(t, frame) {
    if (!scene) init();
    if (!scene) return;
    const f = frame || {};
    const u = mat.uniforms;
    u.u_time.value         = t;
    u.u_bass.value         = f.bass      ?? 0;
    u.u_mid.value          = f.mid       ?? 0;
    u.u_treble.value       = f.treble    ?? 0;
    u.u_beatPulse.value    = f.beatPulse ?? 0;
    u.u_resolution.value.set(innerWidth, innerHeight);
    u.u_valence.value      = f.valence      ?? 0.5;
    u.u_energy.value       = f.energy       ?? 0.5;
    u.u_danceability.value = f.danceability ?? 0.5;
    window.vizGL.renderer.render(scene, window.vizGL.camera);
  }

  window.Viz.register({
    id:       'your-viz',
    label:    'Your Viz',
    kind:     'webgl',
    initFn:   init,
    renderFn: render,
    controls: [
      { id: 'intensity', label: 'Intensity', min: 0, max: 2.0, step: 0.05, default: 1.0 },
    ],
  });
})();
```

For 2D canvas viz use `kind: '2d'`, read `window.ctx` in render, and own your own clearRect.

CPU-side patterns to consider:
- EMA-smooth bass/mid/treble if the viz reads as "sustained shape" — see `patterns.md` §6.
- Accumulate rotation/phase state across frames — declare `let camZ = 0; let lastT = 0;` at module scope.
- Read controls every frame with `window.Viz.controlValue('your-viz', 'intensity')` so the UI feels instant.
- Apply dual-time drift (`patterns.md` §1) for organic fluid/ink motion.

Exit: new viz appears as a button in the mode switcher, switches in/out cleanly, reacts to mic + Spotify audio in the browser.

## Phase 3 — iOS shader port

Files touched:
- `Packages/Core/Sources/Core/Rendering/Shaders/YourViz.metal` (new)
- `Packages/Core/Sources/Core/Rendering/VisualizerFactory.swift` (add uniforms struct + state struct + factory method + switch case)
- `Packages/Core/Sources/Core/Rendering/VisualizerMode.swift` (append case + update title/symbol/isMetal/needsEmojiAtlas)

### 3a. Metal fragment shader

```metal
#include <metal_stdlib>
using namespace metal;

// Layout must match Swift YourVizUniforms exactly (N bytes total).
// Document padding reasoning here.
struct Uniforms {
    float time;
    float bass;
    float mid;
    float treble;
    float2 resolution;   // offset 16 — 8-byte aligned
    float beatPulse;
    float valence;
    float energy;
    float danceability;
    float tempoBPM;
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
    float aspect = u.resolution.x / u.resolution.y;
    float2 uv = (in.uv - 0.5) * float2(aspect, 1.0);
    // ... port the GLSL body here ...
    return float4(0.0, 0.0, 0.0, 1.0);
}
```

GLSL → Metal translation quick-ref:

| GLSL | Metal |
|---|---|
| `vec2` / `vec3` / `vec4` | `float2` / `float3` / `float4` |
| `mod(a,b)` | `fmod(a,b)` |
| `atan(y,x)` | `atan2(y,x)` |
| `mix(a,b,t)` | `mix(a,b,t)` (same) |
| `fract(x)` | `fract(x)` (same) |
| helper function | `static float fn(...)` |
| `M_PI` | `M_PI_F` |
| `gl_FragColor` | return value of fragment function |
| `gl_Position` | `[[position]]` on VSOut |

### 3b. Swift uniforms + state

In `VisualizerFactory.swift`, add alongside the other Uniforms structs:

```swift
public struct YourVizUniforms {
    public var time: Float
    public var bass: Float
    public var mid: Float
    public var treble: Float
    // 4 floats (16 bytes) before float2 — float2 on 8-byte boundary ✓
    public var resolution: SIMD2<Float>
    public var beatPulse: Float
    public var valence: Float
    public var energy: Float
    public var danceability: Float
    public var tempoBPM: Float

    public init(time: Float = 0, bass: Float = 0, mid: Float = 0, treble: Float = 0,
                resolution: SIMD2<Float> = .zero, beatPulse: Float = 0,
                valence: Float = 0.5, energy: Float = 0.5,
                danceability: Float = 0.5, tempoBPM: Float = 120) {
        self.time = time; self.bass = bass; self.mid = mid; self.treble = treble
        self.resolution = resolution; self.beatPulse = beatPulse
        self.valence = valence; self.energy = energy
        self.danceability = danceability; self.tempoBPM = tempoBPM
    }
}

public struct YourVizState {
    public var smBass: Float = 0
    public var smMid: Float = 0
    public var smTreble: Float = 0
    public var clock: Float = 0
}
```

### 3c. Factory case + private maker

In the `make` switch:

```swift
case .yourViz:
    return try makeYourViz(context: context, pixelFormat: pixelFormat)
```

And add the private function:

```swift
private static func makeYourViz(context: MetalContext,
                                pixelFormat: MTLPixelFormat) throws -> VisualizerRenderer {
    let tauBass:   Float = 0.5
    let tauMid:    Float = 0.8
    let tauTreble: Float = 0.3

    return try FragmentRenderer<YourVizUniforms, YourVizState>(
        context: context, pixelFormat: pixelFormat,
        vertexFunction: "yourviz_vs", fragmentFunction: "yourviz_fs",
        label: "YourViz",
        initialState: YourVizState()
    ) { state, a, dt, res in
        let dtF = Float(dt)
        let kB = 1.0 - expf(-dtF / tauBass)
        let kM = 1.0 - expf(-dtF / tauMid)
        let kT = 1.0 - expf(-dtF / tauTreble)
        state.smBass   += (a.bass   - state.smBass)   * kB
        state.smMid    += (a.mid    - state.smMid)    * kM
        state.smTreble += (a.treble - state.smTreble) * kT
        state.clock    += dtF

        return YourVizUniforms(
            time: state.clock,
            bass: state.smBass,
            mid: state.smMid,
            treble: state.smTreble,
            resolution: res,
            beatPulse: a.beatPulse,  // raw — see patterns.md §7
            valence: a.valence,
            energy: a.energy,
            danceability: a.danceability,
            tempoBPM: a.tempoBPM
        )
    }
}
```

### 3d. VisualizerMode enum

Append the case (don't reorder — raw values are persisted):

```swift
case yourViz
```

Add entries in `title`, `symbol`, `isMetal`, `needsEmojiAtlas` as appropriate.

### 3e. Dispatch

`VisualizerUI.swift` picks up new cases via `VisualizerMode.allCases` — no changes needed unless you want custom SwiftUI controls for this viz.

## Phase 4 — Parity check

Before calling the viz done, scan for drift between platforms. See `parity.md` for the full rule.

- [ ] Sin/cos frequencies in the shader (e.g., `sin(t * 0.30)`) identical GLSL ↔ Metal
- [ ] Reactivity coefficients (`bass * 0.55`, `treble * 0.035`, etc.) identical
- [ ] EMA time constants (tauBass, tauMid, tauTreble, tauBeat) match between the web JS driver and the Swift RenderState
- [ ] Breath rate + color palette mappings identical
- [ ] `normDt = dt * 60` applied on iOS if the web used per-frame integrators
- [ ] Raw vs smoothed beat matches: both platforms pass raw `beatPulse` for sharp punches, smoothed for sustained shape

Commit convention: make the tuning commit separately on each repo, and reference the other repo's commit hash in the message so the audit trail crosses the boundary.

## When to use Canvas 2D instead

Pick 2D when the viz is particle-heavy with simple primitives and no shader math — DVD Mode, Fireworks fit this. Skip Phase 3's Metal shader: iOS uses SwiftUI `Canvas` in `FireworksView.swift` / `DVDModeView.swift`. `VisualizerMode.isMetal` returns false for these; `VisualizerFactory.make` returns nil.
