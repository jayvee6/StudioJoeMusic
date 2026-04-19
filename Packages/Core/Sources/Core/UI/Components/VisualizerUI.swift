import SwiftUI

public struct VisualizerUI: View {
    @ObservedObject public var viewModel: VisualizerViewModel
    @State private var showPicker = false
    @State private var currentMode: VisualizerMode = .bars

    public init(viewModel: VisualizerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            BlueHourBackground()
            renderer
            pulsingCircleCanvas
            hudGlass
            transportGlass
        }
        .tint(StudioJoeColors.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showPicker) {
            MusicPickerView(
                onPick: { item in
                    showPicker = false
                    Task { await viewModel.play(item: item) }
                },
                onCancel: { showPicker = false }
            )
        }
        .alert("Playback error",
               isPresented: Binding(
                   get: { viewModel.errorMessage != nil },
                   set: { if !$0 { viewModel.errorMessage = nil } }
               ),
               actions: { Button("OK") {} },
               message: { Text(viewModel.errorMessage ?? "") })
    }

    @ViewBuilder
    private var renderer: some View {
        switch currentMode {
        case .bars:
            spectrumCanvas
        case .blob:
            MetalVisualizerView(viewModel: viewModel)
                .ignoresSafeArea()
        }
    }

    private var pulsingCircleCanvas: some View {
        Canvas { ctx, size in
            guard currentMode == .bars else { return }
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
            let margin: CGFloat = 24
            let totalSpacing = spacing * CGFloat(bins.count - 1)
            let barW = max(1, (size.width - margin * 2 - totalSpacing) / CGFloat(bins.count))
            let maxH = size.height * 0.30
            let baseY = size.height - 180

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

    private var hudGlass: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.currentBPM > 0
                         ? "\(Int(viewModel.currentBPM)) BPM"
                         : "— BPM")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(StudioJoeColors.label1)
                    Text(String(format: "bass %.2f · mid %.2f · treble %.2f",
                                viewModel.bass, viewModel.mid, viewModel.treble))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(StudioJoeColors.label2)
                    if let title = viewModel.currentTitle {
                        Text(viewModel.currentArtist?.isEmpty == false
                             ? "\(title) — \(viewModel.currentArtist!)"
                             : title)
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(StudioJoeColors.label2)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                Spacer()
                if viewModel.mode == .system {
                    micBadge
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Spacer()
        }
    }

    private var micBadge: some View {
        Label("Live mic", systemImage: "mic.fill")
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(StudioJoeColors.label1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular.tint(StudioJoeColors.accent.opacity(0.35)),
                         in: .capsule)
    }

    private var transportGlass: some View {
        VStack {
            Spacer()
            modeSwitcher
                .padding(.bottom, 14)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Pick Song", systemImage: "music.note.list")
                            .font(.system(.body, weight: .semibold))
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        viewModel.togglePlayPause()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glass)
                    .disabled(viewModel.mode == .idle)
                }
            }
            .padding(.bottom, 28)
        }
    }

    private var modeSwitcher: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(VisualizerMode.allCases) { mode in
                    modePill(for: mode)
                }
            }
        }
    }

    @ViewBuilder
    private func modePill(for mode: VisualizerMode) -> some View {
        let selected = (currentMode == mode)
        let label = Label(mode.title, systemImage: mode.symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(.footnote, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

        if selected {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { currentMode = mode }
            } label: { label }
            .buttonStyle(.glassProminent)
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { currentMode = mode }
            } label: { label }
            .buttonStyle(.glass)
        }
    }
}
