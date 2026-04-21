import SwiftUI

public struct VisualizerUI: View {
    @ObservedObject public var viewModel: VisualizerViewModel
    @State private var showPicker = false
    @State private var showSpotify = false
    @State private var currentMode: VisualizerMode = .bars
    @State private var swipeOffset: CGFloat = 0

    public init(viewModel: VisualizerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            BlueHourBackground()
            renderer
                .offset(x: swipeOffset)
            pulsingCircleCanvas
                .allowsHitTesting(false)
            hudGlass
                .allowsHitTesting(false)
            transportGlass
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    // Follow the finger a bit for tactile feedback (rubber-band).
                    let damped = value.translation.width * 0.35
                    swipeOffset = max(-120, min(120, damped))
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let vx = value.predictedEndTranslation.width
                    let threshold: CGFloat = 60
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if dx < -threshold || vx < -threshold * 2 {
                            advanceMode(by: 1)
                        } else if dx > threshold || vx > threshold * 2 {
                            advanceMode(by: -1)
                        }
                        swipeOffset = 0
                    }
                }
        )
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
        .sheet(isPresented: $showSpotify) {
            SpotifyLibraryView(viewModel: viewModel) {
                showSpotify = false
            }
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
        if currentMode.isMetal {
            MetalVisualizerView(viewModel: viewModel, mode: currentMode)
                .ignoresSafeArea()
        } else {
            spectrumCanvas
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
    }

    private var hudGlass: some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(viewModel.effectiveBPM > 0
                             ? "\(Int(viewModel.effectiveBPM)) BPM"
                             : "— BPM")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(StudioJoeColors.label1)
                        Text(viewModel.bpmSourceLabel)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(StudioJoeColors.label3)
                    }
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
                    Text(currentMode.title)
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .foregroundStyle(StudioJoeColors.label3)
                        .textCase(.uppercase)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                if viewModel.mode == .system {
                    micBadge
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            modeIndicator
                .padding(.bottom, 100)
        }
    }

    private var modeIndicator: some View {
        HStack(spacing: 6) {
            ForEach(VisualizerMode.allCases) { mode in
                Capsule()
                    .fill(mode == currentMode
                          ? StudioJoeColors.accent
                          : StudioJoeColors.label3)
                    .frame(width: mode == currentMode ? 20 : 6, height: 5)
                    .animation(.spring(response: 0.3, dampingFraction: 0.85),
                               value: currentMode)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private var micBadge: some View {
        Label("Live mic", systemImage: "mic.fill")
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(StudioJoeColors.label1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(StudioJoeColors.accent.opacity(0.35)),
                         in: .capsule)
    }

    private var transportGlass: some View {
        VStack(spacing: 10) {
            Spacer()
            progressRow
                .padding(.horizontal, 18)
            sourceRow
            playbackRow
                .padding(.bottom, 28)
        }
    }

    private var progressRow: some View {
        VStack(spacing: 2) {
            ProgressScrubBar(
                position: viewModel.positionSec,
                duration: viewModel.durationSec,
                onSeek: { viewModel.seek(to: $0) }
            )
            HStack {
                Text(Self.formatTime(viewModel.positionSec))
                Spacer()
                Text(viewModel.durationSec > 0
                     ? Self.formatTime(viewModel.durationSec)
                     : "—")
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(StudioJoeColors.label3)
        }
        .opacity(viewModel.durationSec > 0 ? 1 : 0.35)
    }

    private var sourceRow: some View {
        HStack(spacing: 10) {
            Button { showPicker = true } label: {
                Label("Library", systemImage: "music.note.list")
                    .font(.system(.footnote, weight: .semibold))
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.glassProminent)

            Button { showSpotify = true } label: {
                Label("Spotify", systemImage: "music.note.house")
                    .font(.system(.footnote, weight: .semibold))
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.glass)
        }
    }

    private var playbackRow: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 16) {
                Button { viewModel.rewind() } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .disabled(viewModel.mode == .idle)

                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.glassProminent)
                .disabled(viewModel.mode == .idle)

                Button { viewModel.fastForward() } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .disabled(viewModel.mode == .idle)
            }
        }
    }

    // MARK: - Mode navigation

    private func advanceMode(by delta: Int) {
        let all = VisualizerMode.allCases
        guard let current = all.firstIndex(of: currentMode) else { return }
        let next = (current + delta + all.count) % all.count
        currentMode = all[next]
    }

    // MARK: - Helpers

    private static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

/// Scrubable progress bar — shows `position` relative to `duration`. Tap or drag
/// anywhere along the bar to seek. Invokes `onSeek(seconds)` on drag end.
private struct ProgressScrubBar: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0

    var body: some View {
        GeometryReader { geo in
            let progress = duration > 0
                ? (isScrubbing ? scrubFraction : min(1, max(0, position / duration)))
                : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(StudioJoeColors.label3.opacity(0.45))
                Capsule()
                    .fill(StudioJoeColors.accent)
                    .frame(width: max(0, geo.size.width * progress))
                Circle()
                    .fill(StudioJoeColors.accent)
                    .frame(width: isScrubbing ? 14 : 10,
                           height: isScrubbing ? 14 : 10)
                    .offset(x: max(0, geo.size.width * progress) - 6)
                    .animation(.spring(response: 0.2, dampingFraction: 0.8),
                               value: isScrubbing)
            }
            .frame(height: 4)
            .contentShape(Rectangle().inset(by: -10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        isScrubbing = true
                        scrubFraction = min(1, max(0, value.location.x / geo.size.width))
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let f = min(1, max(0, value.location.x / geo.size.width))
                        isScrubbing = false
                        onSeek(f * duration)
                    }
            )
        }
        .frame(height: 18)   // hit area
    }
}
