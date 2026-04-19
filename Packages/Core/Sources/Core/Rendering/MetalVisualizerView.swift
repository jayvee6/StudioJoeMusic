import SwiftUI
import MetalKit
import simd

public struct MetalVisualizerView: UIViewRepresentable {
    @ObservedObject public var viewModel: VisualizerViewModel

    public init(viewModel: VisualizerViewModel) {
        self.viewModel = viewModel
    }

    public func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.metalContext.device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        view.delegate = context.coordinator
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        context.coordinator.attach(to: view)
        return view
    }

    public func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.viewModel = viewModel
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    @MainActor
    public final class Coordinator: NSObject, MTKViewDelegate {
        let metalContext: MetalContext
        var viewModel: VisualizerViewModel
        private var blob: BlobRenderer?
        private let startTime = CACurrentMediaTime()
        private var loadError: String?

        init(viewModel: VisualizerViewModel) {
            self.viewModel = viewModel
            do {
                self.metalContext = try MetalContext()
            } catch {
                fatalError("Metal unavailable: \(error)")
            }
            super.init()
        }

        func attach(to view: MTKView) {
            guard blob == nil else { return }
            do {
                blob = try BlobRenderer(context: metalContext,
                                        pixelFormat: view.colorPixelFormat)
            } catch {
                loadError = "Blob pipeline: \(error.localizedDescription)"
                print("[MetalVisualizerView] \(loadError!)")
            }
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        public func draw(in view: MTKView) {
            guard let blob else { return }
            let t = Float(CACurrentMediaTime() - startTime)
            let audio = min(1.0, viewModel.bass * 0.75 + viewModel.beatPulse * 0.45)
            let size = view.drawableSize
            let u = BlobUniforms(
                time: t,
                audio: audio,
                resolution: SIMD2<Float>(Float(size.width), Float(size.height))
            )
            blob.draw(in: view, uniforms: u)
        }
    }
}
