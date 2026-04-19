import SwiftUI
import MediaPlayer

public struct MusicPickerView: UIViewControllerRepresentable {
    public let onPick: (MPMediaItem) -> Void
    public let onCancel: () -> Void

    public init(onPick: @escaping (MPMediaItem) -> Void,
                onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = false
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
            parent.onPick(item)
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
