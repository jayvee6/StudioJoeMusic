# Info.plist additions

Add these keys to your Xcode app target's **Info** tab (or paste into `Info.plist` source). Phase 1 only needs the Media Library key; the Spotify URL scheme lands in Phase 3.

## Required for Phase 1

| Key | Value | Why |
|---|---|---|
| `NSAppleMusicUsageDescription` | `Pick a song from your library to play through the visualizer.` | `MPMediaPickerController` requires it |

## Required in Phase 3 (Spotify auth)

| Key | Value | Why |
|---|---|---|
| `CFBundleURLTypes` → item → `CFBundleURLSchemes` → `studiojoe-musicplayer` | — | PKCE callback URL scheme |
| `LSApplicationQueriesSchemes` → `spotify` | — | `SPTAppRemote` connection check |

## Required in Phase 4 (Apple Music full-track)

Phase 1's `.playback` audio session + `MPMediaPickerController` assets do NOT require subscription. Phase 4's `ApplicationMusicPlayer` does — and asks the user at runtime via `MusicAuthorization.request()`. No extra Info.plist key for that flow.

## NOT needed

- `NSMicrophoneUsageDescription` — Phase 1 taps the mixer node, not the mic. Add later only if/when `Conductor.swift` (mic-tap path) is wired up for the ambient analysis mode.
