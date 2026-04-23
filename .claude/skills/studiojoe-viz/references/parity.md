# Parity — web ↔ iOS tuning propagation

The iOS app and the web app share the same visualizer algorithms. When the user tunes a viz on one platform, the change must propagate to the other. This is a hard rule; tuning drifts between platforms are considered bugs.

## The rule

When a viz's feel is tuned on one platform — timing, smoothing, reactivity weights, color behavior — the same numerical change must land on the other platform before calling the tuning done.

Both sides of the change apply:
- Shader edits (Metal ↔ GLSL) — same numeric constants
- CPU-side driver edits (EMA time constants, rate accumulators, oscillator amplitudes) — same logic

Commit convention: split commits cleanly, one on each repo's branch describing the shared tuning change. Reference the other repo's commit hash in both messages so the audit trail crosses the boundary.

## What counts as "tuning"

These numbers must stay synced:

| Category | Examples |
|---|---|
| Sin/cos frequencies | `sin(t * 0.30)` — identical constant on both platforms |
| Reactivity coefficients | `bass * 0.55`, `treble * 0.035`, `beat * 1.65` |
| EMA time constants | `tauBass = 0.5`, `tauMid = 0.8`, `tauTreble = 0.3`, `tauBeat = 0.25` |
| Breath rates | `sin(nt * 0.19) * 0.035 + cos(nt * 0.13) * 0.020` |
| Speed ceilings | `speed = 0.55 + mid * 1.30` |
| Color palette mappings | HSL base + valence nudge + energy scale |
| Metaball smin radii | `smin(d, dist, 0.045)` |
| Drift oscillator amplitudes | `(sin(t*0.30)*6 + sin(t*0.19)*3)` |

## What does NOT count

These stay per-platform and do NOT propagate:

| Category | Examples |
|---|---|
| UI chrome | iPod overlay (web-only), SwiftUI controls (iOS-only) |
| Platform-specific perf caps | Web's mobile raymarch step-count feature-detect, iOS's MTKView drawable count |
| File structure | Web has one `.js` per viz, iOS has a `.metal` + factory entry |
| Audio source wiring | Spotify Web Playback SDK vs SPTAppRemote, MusicKit JS vs MusicKit (iOS) |
| Build-system details | `node serve.js` vs xcodegen + Xcode |

## Scope of the rule

Applies to: Rorschach, Kaleidoscope, Lunar, Ferrofluid, DVD Mode, and any future shared viz.

Does NOT apply to viz that exist on only one platform (if any emerge — currently everything shared is shared on both).

## Porting direction

- **iOS → web** was the primary direction for Wave 2/3 ports (B1, A1, A2, A5, A6, A4). The Metal shader + Swift driver were the reference; GLSL + JS mirrored them.
- **web → iOS** was the direction for later tuning changes the user discovered while prototyping in the browser (2026-04-22 Rorschach tuning). The web Rorschach was refined; iOS Rorschach then had to mirror the same EMA constants and drift oscillator.
- Either direction is fine. The rule is parity, not precedence.

## How to apply during a tuning session

1. The user describes a tuning intent ("too twitchy", "drops need to be snappier", "ink looks stagnant").
2. Implement on the currently-open platform (usually whichever is in front of the user — web is usually fastest to validate since it reloads instantly).
3. Identify every changed numeric constant. Checklist: shader uniforms, shader constants, CPU smoothing taus, CPU accumulator rates, control slider defaults/ranges.
4. Mirror each change to the other platform. File locations:
   - Web driver: `musicplayer-viz/viz/*.js`
   - Web shader (inline): same `.js` file, inside the `FS` string
   - iOS driver: `StudioJoeMusic/Packages/Core/Sources/Core/Rendering/VisualizerFactory.swift` (the relevant `makeX` closure)
   - iOS shader: `StudioJoeMusic/Packages/Core/Sources/Core/Rendering/Shaders/X.metal`
5. Verify both platforms visually before committing.
6. Commit on each repo, cross-reference the other commit hash.

## Related memories

- `feedback_viz_tuning_propagates` — the user's original statement of this rule.
- `project_viz_oscillating_drift_pattern` — the dual-time drift technique that emerged from a Rorschach tuning and must stay synced.
