import SwiftUI

public struct VisualizerUI: View {
    @ObservedObject public var viewModel: VisualizerViewModel
    @ObservedObject public var spotifyPlayback: SpotifyPlaybackSource
    @State private var showPicker = false
    @State private var showSpotify = false
    @State private var showSettings = false
    @State private var currentMode: VisualizerMode = .bars
    @State private var swipeOffset: CGFloat = 0

    // Transient mode-name overlay state. Shown briefly on launch and on every
    // mode change, then fades out after a short dwell.
    @State private var showModeLabel = false
    @State private var modeLabelTask: Task<Void, Never>?

    public init(viewModel: VisualizerViewModel, spotifyPlayback: SpotifyPlaybackSource) {
        self.viewModel = viewModel
        self.spotifyPlayback = spotifyPlayback
    }

    public var body: some View {
        ZStack {
            BlueHourBackground()
            renderer
                .offset(x: swipeOffset)
            pulsingCircleCanvas
                .allowsHitTesting(false)
            modeLabelOverlay
                .allowsHitTesting(false)
            transportGlass
            settingsButton   // floats bottom-right, above everything
        }
        .onAppear { flashModeLabel() }
        .onChange(of: currentMode) { _, _ in flashModeLabel() }
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
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel, spotifyPlayback: spotifyPlayback) {
                showSettings = false
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
        } else if currentMode == .dvdMode {
            DVDModeView(viewModel: viewModel)
                .ignoresSafeArea()
        } else if currentMode == .fireworks {
            FireworksView(viewModel: viewModel)
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

    /// Transient mode-name overlay. Fades in briefly on mode change / first launch,
    /// then fades back out so it doesn't clutter the visualizer. Implements
    /// the "only show the label text when you change the visualizer" behavior.
    private var modeLabelOverlay: some View {
        VStack {
            if showModeLabel {
                Text(currentMode.title.uppercased())
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(StudioJoeColors.label1)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .padding(.top, 70)
            }
            Spacer()
        }
    }

    private func flashModeLabel() {
        modeLabelTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            showModeLabel = true
        }
        modeLabelTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled {
                await MainActor.run {
                    withAnimation(.easeOut(duration: 0.7)) {
                        showModeLabel = false
                    }
                }
            }
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

    /// Single glass card at the bottom of the screen containing every playback
    /// control — modeled on the web prototype's transport pill. Holds track info,
    /// progress + scrub bar, source buttons, transport buttons, and the mode
    /// indicator all in one container so everything reads as a cohesive surface.
    private var transportGlass: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                trackInfoRow
                progressRow
                transportRow
                modeIndicator
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .padding(.horizontal, 12)
            .padding(.bottom, 28)
        }
    }

    private var trackInfoRow: some View {
        HStack {
            if let title = viewModel.currentTitle {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(StudioJoeColors.label1)
                        .lineLimit(1)
                    if let artist = viewModel.currentArtist, !artist.isEmpty {
                        Text(artist)
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(StudioJoeColors.label2)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("No track loaded")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(StudioJoeColors.label3)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var progressRow: some View {
        VStack(spacing: 4) {
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

    /// Library / rewind / play / fast-forward / Spotify — all in one row.
    /// Sources on the edges, transport controls centered.
    private var transportRow: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button { showPicker = true } label: {
                    Image(systemName: "music.note.list")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)

                Spacer(minLength: 0)

                Button { viewModel.rewind() } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .disabled(viewModel.mode == .idle)

                Button { viewModel.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.glassProminent)
                .disabled(viewModel.mode == .idle)

                Button { viewModel.fastForward() } label: {
                    Image(systemName: "goforward.10")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .disabled(viewModel.mode == .idle)

                Spacer(minLength: 0)

                Button { showSpotify = true } label: {
                    Image(systemName: "music.note.house")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
            }
        }
    }

    /// Floating gear button — deliberately OUTSIDE the transport card since it's
    /// settings, not playback.
    private var settingsButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glass)
                .padding(.trailing, 18)
                .padding(.bottom, 34)
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
