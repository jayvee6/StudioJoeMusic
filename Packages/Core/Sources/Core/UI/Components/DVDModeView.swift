import SwiftUI
import UIKit

public struct DVDModeView: View {
    @ObservedObject public var viewModel: VisualizerViewModel
    @StateObject private var physics = DVDPhysics()

    public init(viewModel: VisualizerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                    .ignoresSafeArea()

                warmFlash

                particleCanvas

                artGlow
                artworkImage

                if physics.showCornerLabel {
                    cornerLabel
                }

                hitCounter
            }
            .onAppear {
                physics.start(screenSize: geo.size, artwork: viewModel.currentArtwork)
            }
            .onDisappear {
                physics.stop()
            }
            .onChange(of: viewModel.bass) { _, bass in
                physics.updateBass(bass)
            }
            .onChange(of: viewModel.currentArtwork) { _, art in
                physics.updateArtwork(art)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DVD Mode: bouncing album art visualizer")
    }

    // MARK: - Sub-views

    private var warmFlash: some View {
        Color(red: 1.0, green: 0.85, blue: 0.4)
            .opacity(physics.screenFlash)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    private var particleCanvas: some View {
        Canvas { ctx, _ in
            for p in physics.particles {
                let frac = p.age / p.lifetime
                let opacity = Double(max(0, 1 - frac))
                let size = p.size * (1 - frac * 0.4)
                let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                ctx.fill(
                    Circle().path(in: rect),
                    with: .color(physics.accentColor.opacity(opacity))
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var artGlow: some View {
        let beatGlow = CGFloat(viewModel.beatPulse)
        return RoundedRectangle(cornerRadius: 28)
            .fill(physics.accentColor.opacity(0.25 + physics.glowPulse * 0.4 + beatGlow * 0.15))
            .frame(width: physics.artSize.width + 44, height: physics.artSize.height + 44)
            .blur(radius: 20 + physics.glowPulse * 18 + beatGlow * 10)
            .position(
                x: physics.position.x + physics.artSize.width / 2,
                y: physics.position.y + physics.artSize.height / 2
            )
            .allowsHitTesting(false)
    }

    private var artworkImage: some View {
        let beatGlow = CGFloat(viewModel.beatPulse)
        return artImageContents
            .frame(width: physics.artSize.width, height: physics.artSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(
                color: physics.accentColor.opacity(0.5 + beatGlow * 0.4 + physics.glowPulse * 0.3),
                radius: 12 + beatGlow * 18 + physics.glowPulse * 20
            )
            .position(
                x: physics.position.x + physics.artSize.width / 2,
                y: physics.position.y + physics.artSize.height / 2
            )
    }

    @ViewBuilder
    private var artImageContents: some View {
        if let artwork = viewModel.currentArtwork {
            Image(uiImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color(.systemFill)
                Image(systemName: "music.note")
                    .font(.system(size: 60, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var cornerLabel: some View {
        Text("CORNER! 🎯")
            .font(.system(.title2, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: physics.accentColor, radius: 10)
            .transition(.scale(scale: 1.25).combined(with: .opacity))
            .frame(maxWidth: .infinity)
            .padding(.top, 90)
    }

    private var hitCounter: some View {
        HStack {
            if physics.cornerHits > 0 {
                Label("\(physics.cornerHits)", systemImage: "target")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.leading, 16)
                    .padding(.top, 60)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            Spacer()
        }
    }
}
