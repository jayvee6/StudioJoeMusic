# StudioJoe Music

Native iOS port of the `musicplayer-viz` browser prototype. Beautiful Metal visualizers + full-track Apple Music and Spotify playback.

Plan: `/Users/jdot/.claude/plans/i-want-to-make-deep-feigenbaum.md`.

## Phase 1 Status

Phase 1 scaffolds the **audio analysis pipeline** that survives the DRM gate: `AudioConductor` plays a local audio file through `AVAudioPlayerNode`, taps `mainMixerNode` (not the mic), runs a vDSP FFT, and feeds an onset-based BPM detector. A `VisualizerViewModel` smooths the output; `VisualizerUI` draws SwiftUI Canvas bars and a BPM-pulsing core circle.

### What's shipped

- `Packages/Core/Package.swift` — iOS 17+ Swift package
- `Sources/Core/AudioAnalysis/`
  - `Bands.swift` — shared `Bands` + `Spectrum` types
  - `FFTCore.swift` — vDSP-based FFT, log-downsampled to 32 bins
  - `OnsetBPMDetector.swift` — mean+σ onset detection, median of inter-onset intervals → BPM
  - `AudioConductor.swift` — `@Observable` audio engine + player + tap pipeline
- `Sources/Core/UI/Components/`
  - `VisualizerViewModel.swift` — `ObservableObject` with `@Published` smoothed magnitudes + BPM state
  - `MusicPickerView.swift` — `MPMediaPickerController` SwiftUI wrapper (picks iTunes-owned tracks only)
  - `VisualizerUI.swift` — Canvas bars + pulsing beat circle, picker sheet, DRM alert
- `Sources/Core/Rendering/Shaders/Blob.metal` — Mode 3 raymarching shader, GLSL → MSL port
- `Tests/CoreTests/FFTCoreTests.swift` — sine-wave FFT sanity test + steady-beat BPM test

### What's NOT shipped yet

- The Xcode app target itself (manual step below).
- Apple Music auth, Spotify auth, library browsers, full-track playback, analysis-source picker, iPod overlay, Metal renderer. These are Phases 2–6 of the plan.

## Generating the Xcode project

`project.yml` is the source of truth for the Xcode project. Regenerate it with:

```sh
cd ~/Documents/Development/StudioJoeMusic
xcodegen generate
```

That produces `StudioJoeMusic.xcodeproj` with:

- App target `StudioJoeMusic` (bundle id `dev.studiojoe.StudioJoeMusic`, iOS 26 deployment)
- Local SPM dependency on `Packages/Core`
- Info.plist generated from `project.yml` (Media Library usage, dark scheme, portrait + landscape, light status bar)
- `Assets.xcassets` with `AppIcon` and `AccentColor` (#0A84FF)
- `StudioJoeMusicApp.swift` entry wires `VisualizerUI(viewModel:)` as the root scene and requests media library permission at launch

The `.xcodeproj` is git-ignored; regenerate any time `project.yml` changes.

## Running on device

1. `xcodegen generate` (if you haven't already).
2. `open StudioJoeMusic.xcodeproj`.
3. In **Signing & Capabilities**, pick your development team once — Xcode remembers it.
4. Select your iPhone, **⌘R**. Grant media library access when prompted.
5. Tap **Pick Song** → choose a track you own (not a cloud Apple Music download) → bars and BPM circle react.

## Headless build (for CI or sanity)

```sh
# Core package only (fast):
cd Packages/Core
xcodebuild -scheme Core -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator build

# Full app (after xcodegen):
cd ~/Documents/Development/StudioJoeMusic
xcodebuild -project StudioJoeMusic.xcodeproj -scheme StudioJoeMusic \
  -destination 'generic/platform=iOS Simulator' -sdk iphonesimulator \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

## Smoke-test checklist

- [ ] App launches on device, shows black screen with "— BPM" label.
- [ ] Tap **Pick Song** → system picker appears.
- [ ] Pick an owned track → playback starts.
- [ ] Spectrum bars animate across the bottom, with smooth fall-off.
- [ ] Core circle pulses on the beat; BPM reading stabilizes within 8–12 seconds.
- [ ] Pause → bars freeze, BPM holds.
- [ ] Pick a cloud-only Apple Music track → DRM alert shows, no crash.

## Next

Phase 2 begins once Phase 1 smoke tests pass on device. See the plan for the full sequence — all 8 Metal visualizers, Spotify PKCE, then full-track, then iPod overlay, then TestFlight.
