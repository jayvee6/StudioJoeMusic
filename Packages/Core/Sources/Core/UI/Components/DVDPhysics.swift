import SwiftUI
import UIKit
import QuartzCore

// MARK: - Particle

struct DVDParticle {
    var x, y: CGFloat
    var vx, vy: CGFloat
    var age, lifetime: CGFloat
    var size: CGFloat
}

// MARK: - Physics Controller

@MainActor
final class DVDPhysics: ObservableObject {
    @Published var position: CGPoint = CGPoint(x: 100, y: 120)
    @Published var accentColor: Color = .white
    @Published var cornerHits: Int = 0
    @Published var showCornerLabel: Bool = false
    @Published var screenFlash: CGFloat = 0
    @Published var particles: [DVDParticle] = []
    @Published var glowPulse: CGFloat = 0

    let artSize = CGSize(width: 180, height: 180)

    private var velocity = CGVector(dx: 72, dy: 58)
    private var screenSize: CGSize = .zero
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var speedBoost: CGFloat = 0
    private var cornerLabelTask: Task<Void, Never>?

    // Rainbow cycle — party-mode hue that loops every ~5 s, speeds up on bass.
    private var hue: CGFloat = 0
    private let baseHueRate: CGFloat = 0.20   // cycles per second at rest

    func start(screenSize: CGSize, artwork: UIImage?) {
        self.screenSize = screenSize
        position = CGPoint(
            x: screenSize.width * 0.30,
            y: screenSize.height * 0.25
        )
        // Seed the rainbow at a random hue so re-entering the mode doesn't
        // always start on red.
        hue = CGFloat.random(in: 0..<1)
        accentColor = Self.rainbowColor(at: hue)
        if UIAccessibility.isReduceMotionEnabled {
            velocity = CGVector(dx: 18, dy: 14)
        }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
        cornerLabelTask?.cancel()
    }

    func updateBass(_ bass: Float) {
        guard !UIAccessibility.isReduceMotionEnabled, bass > 0.55 else { return }
        speedBoost = min(speedBoost + CGFloat(bass) * 0.5, 2.5)
    }

    func updateArtwork(_ art: UIImage?) {
        // Artwork-driven tint is intentionally disabled in party mode; the
        // rainbow cycle in `tick` owns `accentColor` from here on.
        _ = art
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt: CGFloat = lastTimestamp == 0 ? (1.0 / 60.0) : min(CGFloat(now - lastTimestamp), 0.05)
        lastTimestamp = now

        speedBoost = max(0, speedBoost - dt * 1.8)
        let baseSpeed: CGFloat = UIAccessibility.isReduceMotionEnabled ? 18 : 80
        let currentSpeed = baseSpeed + speedBoost * 45

        let len = sqrt(velocity.dx * velocity.dx + velocity.dy * velocity.dy)
        if len > 0 {
            velocity = CGVector(dx: velocity.dx / len * currentSpeed,
                                dy: velocity.dy / len * currentSpeed)
        }

        var newX = position.x + velocity.dx * dt
        var newY = position.y + velocity.dy * dt
        var bounceX = false, bounceY = false

        let maxX = screenSize.width - artSize.width
        let maxY = screenSize.height - artSize.height

        if newX < 0 {
            newX = 0
            velocity = CGVector(dx: abs(velocity.dx), dy: velocity.dy)
            bounceX = true
        } else if newX > maxX {
            newX = maxX
            velocity = CGVector(dx: -abs(velocity.dx), dy: velocity.dy)
            bounceX = true
        }

        if newY < 0 {
            newY = 0
            velocity = CGVector(dx: velocity.dx, dy: abs(velocity.dy))
            bounceY = true
        } else if newY > maxY {
            newY = maxY
            velocity = CGVector(dx: velocity.dx, dy: -abs(velocity.dy))
            bounceY = true
        }

        position = CGPoint(x: newX, y: newY)

        if bounceX && bounceY {
            triggerCornerHit()
        }

        glowPulse = max(0, glowPulse - dt * 2.5)
        screenFlash = max(0, screenFlash - dt * 3.0)

        // Party-mode rainbow cycle. speedBoost (set from bass hits) briefly
        // accelerates the cycle so the color pops on beats.
        let hueRate = baseHueRate + speedBoost * 0.35
        hue += hueRate * dt
        if hue >= 1 { hue -= floor(hue) }
        accentColor = Self.rainbowColor(at: hue)

        if !particles.isEmpty {
            let gravity: CGFloat = 200
            particles = particles.compactMap { p in
                var p2 = p
                p2.x += p2.vx * dt
                p2.y += p2.vy * dt
                p2.vy += gravity * dt
                p2.age += dt
                return p2.age < p2.lifetime ? p2 : nil
            }
        }
    }

    private func triggerCornerHit() {
        cornerHits += 1
        glowPulse = 1.0
        screenFlash = 0.35

        let originX = position.x < 1 ? CGFloat(0) : position.x + artSize.width
        let originY = position.y < 1 ? CGFloat(0) : position.y + artSize.height

        particles = (0..<50).map { _ in
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let speed = CGFloat.random(in: 100...260)
            return DVDParticle(
                x: originX,
                y: originY,
                vx: cos(angle) * speed,
                vy: sin(angle) * speed - 60,
                age: 0,
                lifetime: CGFloat.random(in: 0.7...1.6),
                size: CGFloat.random(in: 5...13)
            )
        }

        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

        withAnimation(.easeOut(duration: 0.15)) { showCornerLabel = true }
        cornerLabelTask?.cancel()
        cornerLabelTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.6)) { showCornerLabel = false }
            }
        }
    }

    private static func rainbowColor(at hue: CGFloat) -> Color {
        Color(hue: Double(hue), saturation: 0.95, brightness: 1.0)
    }

    deinit {
        displayLink?.invalidate()
        cornerLabelTask?.cancel()
    }
}
