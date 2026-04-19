import SwiftUI
import MediaPlayer

public struct MusicPickerView: UIViewControllerRepresentable {
    public let onPick: (URL) -> Void
    public let onCancel: () -> Void
    public let onDRMTrack: () -> Void

    public init(onPick: @escaping (URL) -> Void,
                onCancel: @escaping () -> Void,
                onDRMTrack: @escaping () -> Void = {}) {
        self.onPick = onPick
        self.onCancel = onCancel
        self.onDRMTrack = onDRMTrack
    }

    public func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = false
        picker.prompt = "Only tracks you own (not DRM Apple Music downloads) will play through the visualizer."
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ vc: MPMediaPickerController, context: Context) {}

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let parent: MusicPickerView
        init(_ parent: MusicPickerView) { self.parent = parent }

        public func mediaPicker(_ picker: MPMediaPickerController,
                                didPickMediaItems collection: MPMediaItemCollection) {
            picker.dismiss(animated: true)
            guard let item = collection.items.first else {
                parent.onCancel(); return
            }
            guard let url = item.assetURL else {
                parent.onDRMTrack(); return
            }
            parent.onPick(url)
        }

        public func mediaPickerDidCancel(_ picker: MPMediaPickerController) {
            picker.dismiss(animated: true)
            parent.onCancel()
        }
    }
}

public enum MediaLibraryPermission {
    public static func request(_ completion: @escaping (Bool) -> Void) {
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }
}
