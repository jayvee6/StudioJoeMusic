import SwiftUI
import Core

@main
struct StudioJoeMusicApp: App {
    @StateObject private var viewModel: VisualizerViewModel

    init() {
        let spotifyAuth = SpotifyAuth()
        let catalog = SpotifyCatalog(auth: spotifyAuth)
        let metadata = TrackMetadataService(spotifyCatalog: catalog)
        let analysis = SpotifyAnalysisClient(auth: spotifyAuth)
        let appleMusicKit = AppleMusicKitClient()
        let vm = VisualizerViewModel(
            conductor: AudioConductor(),
            metadataService: metadata,
            analysisClient: analysis,
            appleMusicKit: appleMusicKit
        )
        _viewModel = StateObject(wrappedValue: vm)
        MediaLibraryPermission.request { _ in }
    }

    var body: some Scene {
        WindowGroup {
            VisualizerUI(viewModel: viewModel)
        }
    }
}
