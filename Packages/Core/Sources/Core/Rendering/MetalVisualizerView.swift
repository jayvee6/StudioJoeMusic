import SwiftUI
import MetalKit
import simd

public struct MetalVisualizerView: UIViewRepresentable {
    @ObservedObject public var viewModel: VisualizerViewModel
    public let mode: VisualizerMode

    public init(viewModel: VisualizerViewModel, mode: VisualizerMode) {
        self.viewModel = viewModel
        self.mode = mode
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
        context.coordinator.pixelFormat = view.colorPixelFormat
        return view
    }

    public func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.currentMode = mode
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, initialMode: mode)
    }

    @MainActor
    public final class Coordinator: NSObject, MTKViewDelegate {
        let metalContext: MetalContext
        var viewModel: VisualizerViewModel
        var currentMode: VisualizerMode
        var pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb

        private var renderers: [VisualizerMode: VisualizerRenderer] = [:]
        private let startTime = CACurrentMediaTime()
        private var emojiAtlas: EmojiAtlas?

        // Rolling bass history — newest at [0], oldest at [15]. Matches web prototype's
        // `bassHistory.unshift(newBass); bassHistory.pop()` convention so shaders can
        // index-by-delay for outward-traveling wave effects.
        private var bassRing: [Float] = Array(repeating: 0, count: 16)
        private var bassHead: Int = 0

        init(viewModel: VisualizerViewModel, initialMode: VisualizerMode) {
            self.viewModel = viewModel
            self.currentMode = initialMode
            do {
                self.metalContext = try MetalContext()
            } catch {
                fatalError("Metal unavailable: \(error)")
            }
            super.init()
            self.emojiAtlas = try? EmojiAtlas(device: metalContext.device)
            if emojiAtlas == nil {
                print("[MetalVisualizerView] EmojiAtlas failed to build; emoji modes disabled")
            }
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        public func draw(in view: MTKView) {
            guard let renderer = renderer(for: currentMode) else { return }

            // Advance the bass history ring (newest goes to head, then read back in order).
            bassRing[bassHead] = viewModel.bass
            bassHead = (bassHead + 1) % bassRing.count
            var history = [Float](repeating: 0, count: bassRing.count)
            for i in 0..<bassRing.count {
                history[i] = bassRing[(bassHead + bassRing.count - 1 - i) % bassRing.count]
            }

            let audio = AudioFrame(
                time: Float(CACurrentMediaTime() - startTime),
                bass: viewModel.bass,
                mid: viewModel.mid,
                treble: viewModel.treble,
                beatPulse: viewModel.beatPulse,
                bpm: Float(viewModel.currentBPM),
                magnitudes: viewModel.magnitudes,
                bassHistory: history
            )
            renderer.draw(in: view, audio: audio)
        }

        private func renderer(for mode: VisualizerMode) -> VisualizerRenderer? {
            if let cached = renderers[mode] { return cached }
            do {
                guard let r = try VisualizerFactory.make(mode: mode,
                                                          context: metalContext,
                                                          pixelFormat: pixelFormat,
                                                          atlas: emojiAtlas) else {
                    return nil
                }
                renderers[mode] = r
                return r
            } catch {
                print("[MetalVisualizerView] Failed to build renderer for \(mode): \(error)")
                return nil
            }
        }
    }
}
