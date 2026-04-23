---
name: studiojoe-viz
description: Make sure to use this skill whenever working in the musicplayer-viz or StudioJoeMusic repos; whenever adding, editing, tuning, or porting any music visualizer; whenever writing or reviewing GLSL or Metal fragment shaders for audio-reactive graphics; whenever touching raymarching, SDFs, or metaball math for viz; whenever configuring PBR in Three.js r128 or Metal; whenever optimizing real-time GPU rendering for music viz; whenever porting a viz between web and iOS; and whenever referencing Apple MetalSampleCode or Three.js r128 specifics. This skill routes you to the right reference file for the sub-task.
---

# studiojoe-viz

Expert advisor for Joe's two parallel music-viz projects: the web app `musicplayer-viz` (vanilla JS + Three.js r128 UMD + Canvas 2D, self-registering viz via `window.Viz.register`) and the iOS app `StudioJoeMusic` (SwiftUI + Metal fragment shaders, enum-dispatched via `VisualizerFactory.swift`). Whenever viz work is happening, use the decision tree below to pick the right reference file; do not load them all.

## Decision tree — load only the file you need

| User intent / sub-task | Load this reference |
|---|---|
| Adding a new visualizer from scratch | `references/new-viz-recipe.md` |
| Need the registry API, AudioFrame schema, or iOS factory/enum contract | `references/stack-contracts.md` |
| Tuning an existing viz (sin freqs, reactivity, EMA taus, colors) | `references/parity.md` + `references/patterns.md` |
| Recognizing or applying a core pattern (drift, ACES/PCL, normDt, shared rot) | `references/patterns.md` |
| Propagating a tuning change between web and iOS | `references/parity.md` |
| Looking for an Apple Metal sample to borrow a technique from | `references/metal-samples-index.md` |
| Setting up PBR or matching Three.js r128 PBR to Metal | `references/pbr.md` |
| Frame rate drops, overdraw, raymarch cost, mobile GPU caps | `references/performance.md` |
| Looking up an external tutorial (IQ, Book of Shaders, SebLague, etc.) | `references/external-resources.md` |

If the intent spans multiple files, load them in the order listed above.

## Quick contracts (inline)

### Web viz registration

```js
window.Viz.register({
  id:       'your-id',
  label:    'Your Label',
  kind:     '2d' | 'webgl',
  initFn:   () => void,        // lazy — first activation
  renderFn: (t, frame) => void,
  teardownFn: () => void,      // optional
  controls: [{id, label, type, min, max, step, default}],  // optional
  layout:   'vertical',        // optional — stacks controls
});
```

### AudioFrame (from `window.AudioEngine.currentFrame()`)

```
{ time, bass, mid, treble, beatPulse, bpm, isBeatNow, bassHistory,
  magnitudes, valence, energy, danceability, tempoBPM, width, height }
```

### Shared globals

- `window.vizGL = { renderer, camera }` — Three.js r128 renderer + camera.
- `window.ctx` — shared Canvas 2D context.
- `window.vizSharedRotY` — rotation accumulator; sphere viz (Lunar, Chrome, etc.) share it so mode switches stay continuous.

### iOS dispatch

1. Add a new case to `VisualizerMode.swift` — enum case + title + symbol + `isMetal` flag.
2. Add the matching `case .yourMode: return try makeYourMode(...)` in the switch inside `VisualizerFactory.swift`.
3. Shader lives at `Rendering/Shaders/YourViz.metal`.
4. Swift uniforms struct must layout-match the Metal one — `float2` on 8-byte boundary. Document the padding and the struct's total size in comments.

## Core patterns (one line each — see `patterns.md` for detail)

- **Dual-time drift.** Monotonic `u_time` feeds noise; oscillating `u_nodeT = (sin(t*0.30)*6 + sin(t*0.19)*3) * drift` feeds node positions. Produces organic ink/fluid motion without runaway drift.
- **Prototype-first.** A new complex viz starts life as a standalone `prototypes/*.html` file before it earns a registry entry.
- **Shared rotation.** Sphere viz accumulate into `window.vizSharedRotY` so Lunar ↔ Chrome ↔ etc. mode switches stay continuous instead of snapping.
- **ACES + physicallyCorrectLights.** When a Three.js viz flips these, save the old values in `initFn` and restore in `teardownFn`. r128 defaults them OFF — leaking them into the next viz changes its look.
- **normDt = dt * 60.** iOS port idiom for web integrators that assume 60fps. Multiply dt by 60 in Swift/Metal, then reuse the web's per-frame coefficients verbatim.
- **EMA smoothing.** AudioFrame values jitter. Typical taus (sec): bass 0.5, mid 0.8, treble 0.3, beat 0.25. Keep raw `beatPulse` for sharp drops.

## The parity rule (one sentence)

Tuning changes — sin/cos frequencies, reactivity weights, EMA time constants, speed ceilings, color mappings — must propagate between web and iOS; see `references/parity.md`. Does **not** include UI chrome (the iPod overlay is web-only) or platform-specific perf caps (e.g., mobile-GPU step-count reductions).

## Before you code — checklist

- [ ] Identified whether this is new-viz, tuning-change, perf-fix, or technique-question
- [ ] If new viz, prototyped first (standalone HTML → registry → Metal port)
- [ ] If tuning change, will mirror to the other platform
- [ ] Uniform layout matches (float2 on 8-byte boundary, struct size documented)
- [ ] EMA smoothing applied where audio would otherwise jitter
- [ ] Raw `beatPulse` for sharp per-beat punches; smoothed for sustained shape

## Reference files

All in `references/`. Load only what the sub-task needs.

- `stack-contracts.md` — viz registry API, AudioFrame schema, iOS enum/factory pattern, uniform layout rules. Load when touching the registration seam on either platform.
- `patterns.md` — dual-time drift, prototype-first, shared rotation, ACES+PCL save/restore, EMA smoothing, `normDt = dt * 60` parity idiom. Load when applying or reviewing a pattern.
- `new-viz-recipe.md` — step-by-step for creating a new viz (prototype → web registry → iOS Metal port). Load at the start of any new-viz task.
- `parity.md` — web ↔ iOS tuning propagation rule and what counts as "tuning." Load on any tuning change.
- `metal-samples-index.md` — Apple MetalSampleCode catalog indexed by viz relevance. Load when scouting a Metal technique.
- `pbr.md` — Three.js r128 PBR ↔ Metal PBR parity cheat sheet. Load for any PBR setup or a lighting mismatch between platforms.
- `performance.md` — real-time GPU optimization for music viz. Load on any frame-rate, overdraw, or raymarch-cost investigation.
- `external-resources.md` — shader-tutorial.dev, SebLague, Inigo Quilez, Book of Shaders, threejs.org/examples, WebGLFundamentals. Load when hunting an external tutorial or reference.
