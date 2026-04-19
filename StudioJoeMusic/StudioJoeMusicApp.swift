import SwiftUI
import Core

@main
struct StudioJoeMusicApp: App {
    @StateObject private var viewModel = VisualizerViewModel(conductor: AudioConductor())

    init() {
        MediaLibraryPermission.request { _ in }
    }

    var body: some Scene {
        WindowGroup {
            VisualizerUI(viewModel: viewModel)
        }
    }
}
