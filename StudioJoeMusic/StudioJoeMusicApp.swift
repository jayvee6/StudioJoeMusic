import SwiftUI
import Core

@main
struct StudioJoeMusicApp: App {
    @StateObject private var viewModel: VisualizerViewModel
    @StateObject private var spotifyPlayback: SpotifyPlaybackSource

    init() {
        let spotifyAuth = SpotifyAuth()
        let catalog = SpotifyCatalog(auth: spotifyAuth)
        let appleMusicKit = AppleMusicKitClient()
        let playback = SpotifyPlaybackSource()
        let conductor = AudioConductor()

        var deps = VisualizerViewModel.Dependencies()
        deps.metadataService = TrackMetadataService(spotifyCatalog: catalog)
        deps.analysisClient = SpotifyAnalysisClient(auth: spotifyAuth)
        deps.appleMusicKit = appleMusicKit
        deps.previewAnalysisService = PreviewAnalysisService(appleMusicKit: appleMusicKit)
        deps.spotifyPlayback = playback

        let vm = VisualizerViewModel(
            conductor: conductor,
            deps: deps
        )
        _viewModel = StateObject(wrappedValue: vm)
        _spotifyPlayback = StateObject(wrappedValue: playback)
        MediaLibraryPermission.request { _ in }

        // Silently request mic access and enable ambient capture. The first
        // launch shows the system permission prompt; subsequent launches
        // restore from the granted status without UI. No "mic is live" badge
        // in the UI — per product direction, mic is infrastructure, not
        // user-facing state. All audio processing stays on-device.
        Task { _ = await conductor.enableMicCapture() }
    }

    var body: some Scene {
        WindowGroup {
            VisualizerUI(viewModel: viewModel, spotifyPlayback: spotifyPlayback)
                .onOpenURL { url in
                    // Try Spotify SDK app-switch callback first; if it wasn't that,
                    // ignore (the PKCE flow uses ASWebAuthenticationSession which
                    // handles its own callback internally).
                    _ = spotifyPlayback.handleCallback(url: url)
                }
        }
    }
}
