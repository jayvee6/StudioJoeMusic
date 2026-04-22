import SwiftUI
import Core

@main
struct StudioJoeMusicApp: App {
    @StateObject private var viewModel: VisualizerViewModel
    @StateObject private var spotifyPlayback: SpotifyPlaybackSource

    init() {
        let spotifyAuth = SpotifyAuth()
        let catalog = SpotifyCatalog(auth: spotifyAuth)
        let metadata = TrackMetadataService(spotifyCatalog: catalog)
        let analysis = SpotifyAnalysisClient(auth: spotifyAuth)
        let appleMusicKit = AppleMusicKitClient()
        let previewAnalysis = PreviewAnalysisService(appleMusicKit: appleMusicKit)
        let playback = SpotifyPlaybackSource()
        let vm = VisualizerViewModel(
            conductor: AudioConductor(),
            metadataService: metadata,
            analysisClient: analysis,
            appleMusicKit: appleMusicKit,
            previewAnalysisService: previewAnalysis,
            spotifyPlayback: playback
        )
        _viewModel = StateObject(wrappedValue: vm)
        _spotifyPlayback = StateObject(wrappedValue: playback)
        MediaLibraryPermission.request { _ in }
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
