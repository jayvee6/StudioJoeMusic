import SwiftUI

public struct VisualizerUI: View {
    @ObservedObject public var viewModel: VisualizerViewModel
    @State private var showPicker = false
    @State private var drmWarning = false

    public init(viewModel: VisualizerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            backgroundCanvas
            pulsingCircleCanvas
            spectrumCanvas
            hud
            transport
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showPicker) {
            MusicPickerView(
                onPick: { url in
                    showPicker = false
                    try? viewModel.play(url: url)
                },
                onCancel: { showPicker = false },
                onDRMTrack: {
                    showPicker = false
                    drmWarning = true
                }
            )
        }
        .alert("Can't play this track",
               isPresented: $drmWarning,
               actions: { Button("OK") {} },
               message: {
                   Text("Apple Music subscription downloads are DRM-protected and have no file URL. Pick a track you own (iTunes purchase, imported, or iTunes Match).")
               })
    }

    private var backgroundCanvas: some View {
        Canvas { ctx, size in
            let pulse = CGFloat(viewModel.beatPulse)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = max(size.width, size.height) * (0.55 + pulse * 0.15)
            let gradient = Gradient(colors: [
                Color(hue: 0.62, saturation: 0.55, brightness: 0.32)
                    .opacity(0.4 + Double(pulse) * 0.25),
                Color.black
            ])
            let rect = CGRect(x: center.x - maxR, y: center.y - maxR,
                              width: maxR * 2, height: maxR * 2)
            ctx.fill(Circle().path(in: rect),
                     with: .radialGradient(gradient,
                                           center: center,
                                           startRadius: 0,
                                           endRadius: maxR))
        }
        .ignoresSafeArea()
    }

    private var pulsingCircleCanvas: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseR: CGFloat = min(size.width, size.height) * 0.18
            let pulseR = baseR * (1 + CGFloat(viewModel.beatPulse) * 0.35)
            let hue = 0.55 + Double(viewModel.treble) * 0.3
            let core = Color(hue: hue, saturation: 0.85, brightness: 1.0)

            let glowRect = CGRect(
                x: center.x - pulseR * 1.3, y: center.y - pulseR * 1.3,
                width: pulseR * 2.6, height: pulseR * 2.6
            )
            let glowGradient = Gradient(colors: [
                core.opacity(0.55 * Double(viewModel.beatPulse) + 0.2),
                .clear
            ])
            ctx.fill(
                Circle().path(in: glowRect),
                with: .radialGradient(glowGradient,
                                      center: center,
                                      startRadius: pulseR * 0.6,
                                      endRadius: pulseR * 1.3)
            )

            let coreRect = CGRect(
                x: center.x - pulseR, y: center.y - pulseR,
                width: pulseR * 2, height: pulseR * 2
            )
            ctx.fill(Circle().path(in: coreRect), with: .color(core.opacity(0.92)))
        }
        .allowsHitTesting(false)
    }

    private var spectrumCanvas: some View {
        Canvas { ctx, size in
            let bins = viewModel.magnitudes
            guard !bins.isEmpty else { return }
            let spacing: CGFloat = 3
            let margin: CGFloat = 16
            let totalSpacing = spacing * CGFloat(bins.count - 1)
            let barW = max(1, (size.width - margin * 2 - totalSpacing) / CGFloat(bins.count))
            let maxH = size.height * 0.32
            let baseY = size.height - 120

            for (i, m) in bins.enumerated() {
                let h = max(2, CGFloat(m) * maxH)
                let x = margin + CGFloat(i) * (barW + spacing)
                let y = baseY - h
                let rect = CGRect(x: x, y: y, width: barW, height: h)
                let hue = Double(i) / Double(bins.count)
                let gradient = Gradient(colors: [
                    Color(hue: hue, saturation: 0.85, brightness: 1.0),
                    Color(hue: hue, saturation: 0.85, brightness: 0.4)
                ])
                ctx.fill(
                    RoundedRectangle(cornerRadius: barW * 0.4).path(in: rect),
                    with: .linearGradient(gradient,
                                          startPoint: CGPoint(x: x, y: y),
                                          endPoint: CGPoint(x: x, y: y + h))
                )
            }
        }
        .allowsHitTesting(false)
    }

    private var hud: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.currentBPM > 0
                         ? "\(Int(viewModel.currentBPM)) BPM"
                         : "— BPM")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(String(format: "bass %.2f   mid %.2f   treble %.2f",
                                viewModel.bass, viewModel.mid, viewModel.treble))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            Spacer()
        }
    }

    private var transport: some View {
        VStack {
            Spacer()
            HStack(spacing: 20) {
                Button { showPicker = true } label: {
                    Label("Pick Song", systemImage: "music.note.list")
                        .font(.system(.body, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)

                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.durationSec == 0)
            }
            .padding(.bottom, 32)
        }
    }
}
