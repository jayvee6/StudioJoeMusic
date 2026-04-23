import SwiftUI
import UIKit
import QuartzCore

// MARK: - Rocket + Particle

struct FireworkRocket: Identifiable {
    let id = UUID()
    var x, y: CGFloat
    var vx, vy: CGFloat
    var explosionY: CGFloat      // detonate when y <= this
    var emoji: String
    var debris: [String]
    var z: CGFloat               // [0,1] — depth layer
    var depthScale: CGFloat      // derived from z — cached
    var force: CGFloat           // 0..10 slider unit
    var count: Int               // particle count to spawn
}

struct FireworkParticle: Identifiable {
    let id = UUID()
    var x, y: CGFloat
    var vx, vy: CGFloat
    var age: CGFloat
    var life: CGFloat
    var emoji: String
    var size: CGFloat
    var z: CGFloat
    var depthScale: CGFloat
}

/// Physics controller for the emoji fireworks display. Mirrors the web
/// `viz/fireworks.js` on `musicplayer-viz`:
/// - random launch angle ±20° from vertical
/// - random emoji theme per launch (14 themes shipped)
/// - z-depth layer so some bursts read as nearer and some farther
/// - explosion band clamped to 15–50% of canvas height (upper-middle)
/// - auto-fires on each detected beat; idle fallback timer during silence
@MainActor
public final class FireworksPhysics: ObservableObject {
    @Published private(set) var rockets: [FireworkRocket] = []
    @Published private(set) var particles: [FireworkParticle] = []

    private var screenSize: CGSize = .zero
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var elapsed: CFTimeInterval = 0
    private var lastAutoFireT: CFTimeInterval = -999

    // Physics constants — 1:1 with viz/fireworks.js (px/s² for gravity,
    // px/s base for launch and explosion). Tuned for a screen-sized canvas.
    private let gravity: CGFloat = 520
    private let launchSpeedUnit: CGFloat = 180
    private let explosionUnit: CGFloat = 260
    private let angleRangeDeg: CGFloat = 20

    // Launch + apex zones (canvas y-fractions; 0 = top, 1 = bottom).
    private let horizonYFrac: CGFloat = 0.90
    private let horizonXSpread: CGFloat = 0.22
    private let apexMinFrac: CGFloat = 0.15
    private let apexMaxFrac: CGFloat = 0.50

    // Defaults (no UI sliders on iOS per the web parity).
    private let launchSpeedSlider: CGFloat = 7     // 0..10
    private let explosionForceSlider: CGFloat = 6  // 0..10
    private let particleCount: Int = 50
    private let yVariance: CGFloat = 0.3

    private let idleInterval: CFTimeInterval = 1.8

    private let themes: [(rocket: String, debris: [String])] = [
        ("🚀", ["✨","💥","🌟","🎉"]),
        ("💘", ["💖","💕","❤️","💗","💝"]),
        ("🪄", ["✨","🌟","💫","⭐","✴️"]),
        ("🎃", ["👻","🦇","🕸️","🕷️","🍬"]),
        ("🍾", ["🎉","🎊","🥂","🎈"]),
        ("🌈", ["🦄","💖","⭐","🌟","✨"]),
        ("🌸", ["🌼","🌺","🌷","🌻","🏵️"]),
        ("👽", ["🛸","⭐","🌙","🪐","💫"]),
        ("🐙", ["🐠","🐡","🐟","🐚","🌊"]),
        ("🎊", ["🎉","🎈","🥳","🪩","🍰"]),
        ("🎄", ["🎁","🎅","❄️","⛄","🎀"]),
        ("🍄", ["🌿","🍃","🌳","🌱","☘️"]),
        ("⚡", ["⭐","✨","💫","🌟","☄️"]),
        ("🐉", ["🔥","💥","✨","⚔️","🐲"]),
    ]

    public init() {}

    public func start(screenSize: CGSize) {
        self.screenSize = screenSize
        rockets.removeAll()
        particles.removeAll()
        elapsed = 0
        lastAutoFireT = -999
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
        rockets.removeAll()
        particles.removeAll()
    }

    public func updateSize(_ size: CGSize) {
        screenSize = size
    }

    /// Called from the view when a beat is detected. Triggers one launch.
    public func onBeat() {
        launch()
        lastAutoFireT = elapsed
    }

    // MARK: - Depth helpers (mirror web zToScale / zToAlpha)

    private func zToScale(_ z: CGFloat) -> CGFloat { 0.72 + z * 0.60 }
    public  func zToAlpha(_ z: CGFloat) -> Double  { Double(0.70 + z * 0.28) }

    // MARK: - Launch

    @discardableResult
    public func launch() -> Bool {
        guard screenSize.width > 0, screenSize.height > 0 else { return false }
        let W = screenSize.width, H = screenSize.height
        let theme = themes.randomElement()!

        // Random angle within ±angleRange from vertical (90°).
        let angleDeg = CGFloat.random(in: (90 - angleRangeDeg)...(90 + angleRangeDeg))
        let angleRad = angleDeg * .pi / 180

        let z = CGFloat.random(in: 0..<1)
        let depthScale = zToScale(z)
        let jitter = CGFloat.random(in: 0.85...1.15) * depthScale
        let speed = launchSpeedSlider * launchSpeedUnit * jitter

        let vx =  speed * cos(angleRad)
        let vy = -speed * sin(angleRad)   // up = negative y

        // Launch from the horizon band; slight parallax so back layer
        // starts higher/narrower on screen.
        let xSpread = horizonXSpread * (0.75 + z * 0.35)
        let startX = W * 0.5 + CGFloat.random(in: -W * xSpread...W * xSpread)
        let startY = H * (horizonYFrac - (1 - z) * 0.03)

        // Explosion Y: random within upper-middle band (15–50% Y-frac).
        let apexMinY = H * apexMinFrac
        let apexMaxY = H * apexMaxFrac
        let midY  = (apexMinY + apexMaxY) * 0.5
        let halfR = (apexMaxY - apexMinY) * 0.5
        let explosionY = midY + CGFloat.random(in: -1...1) * halfR * yVariance

        rockets.append(FireworkRocket(
            x: startX, y: startY, vx: vx, vy: vy,
            explosionY: explosionY,
            emoji: theme.rocket,
            debris: theme.debris,
            z: z, depthScale: depthScale,
            force: explosionForceSlider,
            count: particleCount
        ))
        return true
    }

    private func spawnBurst(at p: CGPoint, force: CGFloat, count: Int,
                             emojis: [String], z: CGFloat, depthScale: CGFloat) {
        let speed = force * explosionUnit * 0.1 * (0.80 + z * 0.35)
        for i in 0..<count {
            let theta = CGFloat(i) / CGFloat(count) * .pi * 2
                      + CGFloat.random(in: -0.12...0.12)
            let mag = speed * CGFloat.random(in: 0.6...1.3)
            let emoji = emojis.randomElement() ?? "✨"
            particles.append(FireworkParticle(
                x: p.x, y: p.y,
                vx: cos(theta) * mag,
                vy: sin(theta) * mag - CGFloat.random(in: 20...80),
                age: 0,
                life: CGFloat.random(in: 1.2...2.0),
                emoji: emoji,
                size: CGFloat.random(in: 26...38) * depthScale,
                z: z,
                depthScale: depthScale
            ))
        }
    }

    // MARK: - Tick

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt: CGFloat = lastTimestamp == 0 ? (1.0 / 60.0) : min(CGFloat(now - lastTimestamp), 0.05)
        lastTimestamp = now
        elapsed += Double(dt)

        // Idle fallback — if no beat has fired in a while, auto-launch
        // so the show keeps running during silence. Music-driven launches
        // come through onBeat() which updates lastAutoFireT.
        if elapsed - lastAutoFireT > idleInterval {
            launch()
            lastAutoFireT = elapsed
        }

        // Rocket physics — integrate + detonate on apex hit.
        if !rockets.isEmpty {
            var remaining: [FireworkRocket] = []
            remaining.reserveCapacity(rockets.count)
            for var r in rockets {
                r.vy += gravity * dt
                r.x  += r.vx * dt
                r.y  += r.vy * dt
                if r.y <= r.explosionY {
                    spawnBurst(
                        at: CGPoint(x: r.x, y: r.y),
                        force: r.force,
                        count: r.count,
                        emojis: r.debris,
                        z: r.z,
                        depthScale: r.depthScale
                    )
                } else {
                    remaining.append(r)
                }
            }
            rockets = remaining
        }

        // Particle physics — 65% gravity for softer arc, age out then cull.
        if !particles.isEmpty {
            var alive: [FireworkParticle] = []
            alive.reserveCapacity(particles.count)
            for var p in particles {
                p.age += dt
                if p.age < p.life {
                    p.vy += gravity * dt * 0.65
                    p.x  += p.vx * dt
                    p.y  += p.vy * dt
                    alive.append(p)
                }
            }
            particles = alive
        }
    }

    deinit {
        // Touch the main-actor property only if we can; otherwise let ARC
        // invalidate the link when this object is released.
        if let link = displayLink {
            link.invalidate()
        }
    }
}
