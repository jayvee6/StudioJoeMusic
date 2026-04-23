# Patterns

Proven techniques used across the web + iOS music-visualizer apps. Each pattern lists when to apply and when NOT to.

## 1. Dual-time oscillating drift

For viz where motion should feel like ink sloshing, fluid breathing, or slow organic drift (NOT mechanical rotation), decouple two time values:

- `u_time` — monotonic real-time seconds. Drives noise animation, splatter FBM — anything that should "keep going forward" so the texture never reverses.
- `u_nodeT` — oscillating drift time. Feeds node-position sin/cos drivers (metaball centers, spring rest positions, orbit angles). Sweeps forward and back so the shape traces its trajectory in both directions → reads as organic, not looping.

Canonical oscillator:

```js
// CPU driver (web) — drift is a user slider 0.1..2.0
const drift = window.Viz.controlValue(vizId, 'drift');
const nodeT = (Math.sin(t * 0.30) * 6.0 + Math.sin(t * 0.19) * 3.0) * drift;
```

```swift
// CPU driver (iOS) — inside FragmentRenderer's per-frame closure
state.clock += dtF
let nodeT = sinf(state.clock * 0.30) * 6.0 + sinf(state.clock * 0.19) * 3.0
```

Why the numbers:
- Two incommensurate frequencies (0.30 and 0.19 Hz, ratio ≈ 1.58) so the sum never exactly repeats.
- Amplitudes 6.0 + 3.0 give combined peak ~9. Fed into `sin(nodeT * 0.3)` style expressions in the shader, each node traces about half a circle back and forth per cycle.
- `drift` slider scales amplitude; 0.1× reads as "almost still", 2× as "lively but still organic".

Why two time vars, not one: if you sub an oscillating time into edge-noise coordinates (FBM displacement, splatter FBM), the noise animates backward on each cycle — reads as videotape-rewind, not organic. Keep noise time monotonic.

Where to apply: Rorschach (already does), Ferrofluid spike targets, Lunar sun orbit + cloud drift. Do NOT apply to rigid rotations (Kaleidoscope tunnel depth, Chrome disco ball spin), deterministic physics (DVD bounce), or anything where the user expects forward motion only.

## 2. Prototype-first for complex viz

New viz combining multiple techniques (postprocessing, custom camera, unusual geometry) should be built as a standalone single-file HTML in `musicplayer-viz/prototypes/` BEFORE registry integration.

Why: integration touches registry, shared renderer state, DPR, audio wiring, control UI — all at once. Prototype isolates aesthetic decisions. Once the user signs off on the look, integration is a mechanical port.

Template: one `<script>` block, Three.js via jsdelivr UMD, no audio — just `performance.now() / 1000` as a clock. Fake the AudioFrame with sin-based pulses: `{ bass: (Math.sin(t*0.5)+1)/2, ..., beatPulse: Math.max(0, Math.sin(t*2.0))**4 }`. See `new-viz-recipe.md` Phase 1 for the full template.

Example: `prototypes/disco-chrome.html` → validated with user → became `viz/disco-chrome.js`.

## 3. Shared rotation — `window.vizSharedRotY`

Sphere viz (Lunar, Chrome, any future sphere-centric viz) all read and write `window.vizSharedRotY` every frame. This way, switching between them preserves rotation continuity — no jump on mode-change.

```js
window.vizSharedRotY = (window.vizSharedRotY ?? 0) + dt * (0.08 + bass * 0.30);
mySphereMesh.rotation.y = window.vizSharedRotY;
```

Different sphere viz may use slightly different coefficients (Chrome uses `0.25 + bass * 0.35`). That's fine — what matters is they all mutate the same accumulator.

iOS analog: a shared accumulator in the `RenderingState` singleton, read by any sphere renderer that wants rotation continuity across mode switches. Not yet wired as of this writing; parity TBD.

## 4. ACES tone mapping + physicallyCorrectLights (Three.js r128)

r128 defaults `physicallyCorrectLights = false` and `toneMapping = NoToneMapping`. r160 (and most tutorial code) defaults the other way. If a viz relies on PBR + realistic light falloff + tone-mapped output (Chrome, future HDR viz), it MUST save + restore those flags:

```js
let _savedPCL, _savedTone, _savedExposure, _savedEncoding;

function init() {
  const r = window.vizGL.renderer;
  _savedPCL      = r.physicallyCorrectLights;
  _savedTone     = r.toneMapping;
  _savedExposure = r.toneMappingExposure;
  _savedEncoding = r.outputEncoding;
  r.physicallyCorrectLights = true;
  r.toneMapping             = THREE.ACESFilmicToneMapping;
  r.toneMappingExposure     = 1.0;
  r.outputEncoding          = THREE.sRGBEncoding;
}

function teardown() {
  const r = window.vizGL.renderer;
  r.physicallyCorrectLights = _savedPCL;
  r.toneMapping             = _savedTone;
  r.toneMappingExposure     = _savedExposure;
  r.outputEncoding          = _savedEncoding;
}
```

Otherwise subsequent viz that assume default state (Rorschach with flat shader materials, etc.) look wrong and debugging is miserable.

## 5. normDt = dt * 60 — parity idiom for integrators

The web viz were originally written assuming 60 fps — integrators like `rot += 0.004 + treble * 0.06` run once per frame. When porting to iOS (real vsync-aware dt), multiply by 60 first:

```swift
let normDt = dt * 60.0
state.rot += (0.004 + a.treble * 0.06) * normDt
```

Now the per-frame coefficients carry over verbatim — no re-tuning. Future tuning changes then propagate both ways cleanly.

Exceptions:
- Accumulators already per-second (e.g., `hue += dt * 0.05` in seconds) do NOT use normDt.
- Physics integration (Ferrofluid springs) uses real dt — normDt is only for the web's 60fps-implicit coefficients.

## 6. EMA smoothing for audio channels

Raw AudioFrame values jitter frame-to-frame. For viz where the shape reads as "ink formation" or sustained breathing (Rorschach, Lunar, Ferrofluid), apply a single-pole EMA on the CPU before passing to the shader.

Canonical time constants (seconds to reach ~63% of the new value):

| Channel | tau (sec) | Reason |
|---|---|---|
| bass | 0.5 | slow enough for sustained rumble, fast enough to track drops |
| mid | 0.8 | longest — mid frequencies are naturally noisiest |
| treble | 0.3 | fastest — treble drives fine edge detail; needs responsiveness |
| beatPulse (smoothed) | 0.25 | retains onset punch, filters frame-level jitter |

Formula (identical on both platforms):

```js
// Web
function ema(cur, target, dt, tau) {
  const k = 1 - Math.exp(-dt / tau);
  return cur + (target - cur) * k;
}
```

```swift
// iOS
let k = 1.0 - expf(-dtF / tau)
state.smBass += (a.bass - state.smBass) * k
```

## 7. Raw beatPulse vs smoothed — pick per effect

- **Smoothed beat** (`smBeat`, tau ≈ 0.25) → sustained "breath" on a scale/size driver. Shape grows and shrinks over ~250 ms, not per-frame.
- **Raw `a.beatPulse`** → sharp per-beat punches (Rorschach's outlier splatter droplets, subwoofer cone pop, fireworks launch). Let the detector's built-in `exp(-8*dt)` decay envelope handle fade — don't re-smooth or you lose the attack.

Rule of thumb: if the element is the PRIMARY motion of the viz, smooth it. If it's an accent that should feel like a drum hit, keep it raw.

## 8. Center-subtract noise

When using FBM/value noise to perturb an SDF boundary, write the loop to be centered at 0:

```glsl
float fbm3(vec2 p) {
  float v = 0.0, a = 0.5;
  for (int i = 0; i < 3; i++) {
    v += a * (vnoise(p) - 0.5);   // <-- the -0.5 is load-bearing
    p = p * 2.1 + vec2(2.71, 1.83);
    a *= 0.5;
  }
  return v;   // range ≈ [-0.44, 0.44], net-zero mean
}
```

If FBM has nonzero mean, the SDF edge drifts on average and the shape looks like it's always outgassing. Centered noise perturbs symmetrically — crisp jagged edges, no drift.

## 9. Two-layer edge displacement

Jagged ink/splatter reads wrong with one noise octave — too uniform. Use two coordinate scales and kick both up on beats:

```glsl
float splashKick = 1.0 + u_beatSharp * 0.6;
vec2 nCoord1 = p * 8.0  + vec2(t * 0.20, t * 0.15);
vec2 nCoord2 = p * 28.0 + vec2(t * 0.13, -t * 0.09);
float coarse = fbm3(nCoord1) * (0.050 + treble * 0.035) * splashKick;
float fine   = fbm3(nCoord2) * (0.018 + treble * 0.018) * splashKick;
d += coarse + fine;
```

Coarse layer reads as "drift" of the overall edge; fine layer as "splatter". Both benefit from a beat kick — gives a per-beat "splash" feel.

## 10. Polynomial smooth-min for metaballs (Inigo Quilez)

Verbatim helper — gives narrow bridges between distinct blobs rather than one monolithic lump:

```glsl
float smin(float a, float b, float k) {
  float h = max(k - abs(a - b), 0.0) / k;
  return min(a, b) - h * h * k * 0.25;
}
```

`k` is blend radius. Small k (0.02–0.045) → distinct blobs with narrow ink bridges. Large k (0.1+) → blobs merge into a lump. Rorschach uses k ≈ 0.028–0.045.

## 11. Constant loop bounds for GLSL ES 1.0

Web viz target GLSL ES 1.0 (the default for WebGL 1.0 / Three.js r128 on low-end devices). For-loops must have constant bounds:

```glsl
// OK
for (int i = 0; i < 3; i++) { ... }

// NOT OK
for (int i = 0; i < u_iters; i++) { ... }

// OK — constant bound + conditional break
const int MAX_ITERS = 16;
for (int i = 0; i < MAX_ITERS; i++) {
  if (i >= u_iters) break;
  ...
}
```

Breaks within constant-bounded loops are fine. The compiler unrolls the loop up to MAX_ITERS; the break handles the dynamic cutoff.

## 12. Lazy vizGL bootstrap

A WebGL viz may be the first WebGL mode activated — in which case `window.vizGL` is null because nothing has called `initThree()`. Defensive pattern at the top of `renderFn` (NOT `initFn`, since init runs too early):

```js
function render(t, frame) {
  if (!window.vizGL && typeof window.initThree === 'function') window.initThree();
  if (!scene) init();
  if (!scene) return;
  // ... actual render ...
}
```

This mirrors how `viz/kaleidoscope.js` handles being picked as the first WebGL mode.
