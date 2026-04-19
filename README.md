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

## Creating the Xcode app target

The Swift package builds standalone via `swift build`, but to run the UI on a device or simulator you need an iOS app target hosting it. One-time setup:

1. Open Xcode.
2. **File → New → Project → iOS → App**.
3. Product Name: `StudioJoeMusic` · Interface: **SwiftUI** · Language: **Swift** · Testing: on.
4. Save location: `/Users/jdot/Documents/Development/StudioJoeMusic/` (creates `StudioJoeMusic.xcodeproj` next to `Packages/`).
5. **File → Add Package Dependencies… → Add Local…** → select `Packages/Core`.
6. In the app target's **Frameworks, Libraries, and Embedded Content**, add `Core`.
7. **Info.plist additions** — see `Info.plist.additions.md`.
8. Replace `StudioJoeMusicApp.swift` with:

   ```swift
   import SwiftUI
   import Core

   @main
   struct StudioJoeMusicApp: App {
       @StateObject private var vm = VisualizerViewModel(conductor: AudioConductor())

       init() {
           MediaLibraryPermission.request { _ in }
       }

       var body: some Scene {
           WindowGroup {
               VisualizerUI(viewModel: vm)
           }
       }
   }
   ```
9. Select your device, **⌘R**. Grant media library access when prompted. Tap **Pick Song**, select a track you own (not a cloud Apple Music download), watch the bars and BPM circle react.

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
