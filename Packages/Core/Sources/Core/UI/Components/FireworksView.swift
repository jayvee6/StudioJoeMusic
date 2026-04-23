import SwiftUI

/// Emoji fireworks display — random themed rockets arc up from a horizon
/// band and detonate into matching debris. Auto-fires on each detected
/// beat; idle fallback keeps the show running during silence.
///
/// Mirrors `viz/fireworks.js` on the musicplayer-viz web app.
public struct FireworksView: View {
    @ObservedObject public var viewModel: VisualizerViewModel
    @StateObject private var physics = FireworksPhysics()

    public init(viewModel: VisualizerViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dark sky — not fully black so particle trails read clearly.
                Color(red: 0.016, green: 0.024, blue: 0.063)
                    .ignoresSafeArea()

                Canvas { ctx, size in
                    // Combine rockets + particles into one z-sorted draw
                    // list so the back layer renders first, giving proper
                    // parallax overlap between near and far bursts.
                    struct Drawable {
                        let x, y, size: CGFloat
                        let emoji: String
                        let alpha: Double
                        let z: CGFloat
                    }
                    var drawList: [Drawable] = []
                    drawList.reserveCapacity(physics.rockets.count + physics.particles.count)

                    for r in physics.rockets {
                        drawList.append(Drawable(
                            x: r.x, y: r.y,
                            size: 36 * r.depthScale,
                            emoji: r.emoji,
                            alpha: physics.zToAlpha(r.z),
                            z: r.z
                        ))
                    }
                    for p in physics.particles {
                        let remaining = max(0, 1 - p.age / p.life)
                        let fade = Double(remaining * remaining) * physics.zToAlpha(p.z)
                        drawList.append(Drawable(
                            x: p.x, y: p.y,
                            size: p.size,
                            emoji: p.emoji,
                            alpha: fade,
                            z: p.z
                        ))
                    }
                    drawList.sort { $0.z < $1.z }

                    for item in drawList {
                        let text = Text(item.emoji)
                            .font(.system(size: item.size))
                        let resolved = ctx.resolve(text)
                        var copy = ctx
                        copy.opacity = item.alpha
                        copy.draw(resolved, at: CGPoint(x: item.x, y: item.y), anchor: .center)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .onAppear {
                physics.start(screenSize: geo.size)
            }
            .onDisappear {
                physics.stop()
            }
            .onChange(of: geo.size) { _, newSize in
                physics.updateSize(newSize)
            }
            .onChange(of: viewModel.isBeatDetected) { _, isBeat in
                // Rising edge only — isBeatDetected mirrors per-frame onset
                // detection so it's true only on the exact frame a beat
                // fires, then flips false next frame.
                if isBeat { physics.onBeat() }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fireworks Mode: emoji fireworks display")
    }
}
