import SwiftUI

/// A subtle ambient field of slow-drifting dust motes, drawn with `Canvas` and
/// driven by `TimelineView`. Decorative only — never intercepts touches.
///
/// Particle parameters are derived deterministically from each index (no RNG),
/// so the field is stable across redraws.
struct ParticleField: View {
    var count: Int = 40
    var color: Color = .white

    private let motes: [Mote]

    init(count: Int = 40, color: Color = .white) {
        self.count = count
        self.color = color
        self.motes = (0..<count).map(Mote.init(index:))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for mote in motes {
                    // Drift downward and wrap; gentle horizontal sway.
                    let y = (mote.y0 + t * mote.speed).truncatingRemainder(dividingBy: 1.0)
                    let sway = sin(t * mote.driftRate + mote.phase) * 0.018
                    let x = (mote.x0 + sway).truncatingRemainder(dividingBy: 1.0)
                    let px = x * size.width
                    let py = y * size.height
                    let twinkle = 0.6 + 0.4 * sin(t * mote.twinkleRate + mote.phase)

                    let rect = CGRect(x: px, y: py, width: mote.size, height: mote.size)
                    context.opacity = mote.baseOpacity * twinkle
                    context.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// One particle, with parameters seeded from its index.
    private struct Mote {
        let x0, y0: Double
        let size: Double
        let speed: Double
        let baseOpacity: Double
        let phase: Double
        let driftRate: Double
        let twinkleRate: Double

        init(index i: Int) {
            func frac(_ x: Double) -> Double { x - floor(x) }
            let n = Double(i) + 1
            x0 = frac(n * 0.618033988749895)
            y0 = frac(n * 0.754877666246693)
            size = 1.4 + frac(n * 12.9898) * 2.6
            speed = 0.012 + frac(n * 78.233) * 0.03
            baseOpacity = 0.05 + frac(n * 43.1234) * 0.16
            phase = frac(n * 3.337) * (2 * .pi)
            driftRate = 0.25 + frac(n * 19.19) * 0.5
            twinkleRate = 0.4 + frac(n * 7.77) * 0.9
        }
    }
}
