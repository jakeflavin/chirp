import SwiftUI

/// What the bird is doing. Drives its pose everywhere it appears.
enum BirdMood: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case reading
    case asleep
}

/// Chirp's mascot: a small round bird drawn from shapes, so it scales and animates.
struct Bird: View {
    var mood: BirdMood = .idle
    /// Live audio level, 0…1. Opens the beak and lifts the body while listening or speaking.
    var level: Double = 0
    /// Width and height in points. The bird is drawn on a 100 × 100 grid scaled to this.
    var size: CGFloat = 64
    /// Where an idle bird looks, in its own units (about -2…2 each way): toward the pointer when it
    /// comes near, down at an empty page. Zero looks straight ahead.
    var gaze: CGPoint = .zero

    /// When the idle bird last woke to blink. An idle bird is drawn once and left alone between blinks,
    /// so a bird that is always on screen costs nothing while nothing is happening.
    @State private var wokeAt: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || mood == .asleep || (mood == .idle && wokeAt == nil))) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvasSize in
                draw(&ctx, size: canvasSize, time: t)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(label)
        .task(id: mood) {
            wokeAt = nil
            guard mood == .idle, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3.5...6)))
                wokeAt = Date().timeIntervalSinceReferenceDate
                try? await Task.sleep(for: .milliseconds(450))
                wokeAt = nil
            }
        }
    }

    /// What VoiceOver says for the bird: its mood in words.
    private var label: String {
        switch mood {
        case .idle: "Chirp is ready"
        case .listening: "Chirp is listening"
        case .thinking: "Chirp is working"
        case .speaking: "Chirp is reading aloud"
        case .reading: "Chirp is reading"
        case .asleep: "Chirp is resting"
        }
    }

    /// Draws one frame. The mood, the sound level and the time set the pose (bob, tilt, beak, eye),
    /// then the parts are painted back to front. The feet stay still so the bird stays on its wire.
    private func draw(_ ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        let u = min(size.width, size.height) / 100  // design grid is 100 × 100
        let lvl = max(0, min(1, level))
        let motion = reduceMotion ? 0.0 : 1.0

        // Pose
        var bob = 0.0, tilt = 0.0, beakOpen = 0.0, pupil = CGPoint.zero
        var eyeClosed = false
        switch mood {
        case .idle:
            // Still, apart from a blink and a small settle each time it wakes. It looks where it is asked to.
            pupil = gaze
            if let wokeAt {
                let since = t - wokeAt
                eyeClosed = since > 0.06 && since < 0.2
                bob = sin(min(max(since, 0), 0.45) / 0.45 * .pi) * 0.9 * motion
            }
        case .listening:
            bob = -lvl * 5
            tilt = -8 + sin(t * 2) * 2 * motion
            beakOpen = 0.15
            pupil = CGPoint(x: 1.2, y: -0.6)
        case .thinking:
            tilt = sin(t * 1.2) * 5 * motion
            pupil = CGPoint(x: cos(t * 2.4) * 1.6 * motion, y: -1.4)
        case .speaking:
            beakOpen = reduceMotion ? 0.5 : max(lvl, 0.25 + 0.25 * abs(sin(t * 9)))
            bob = -lvl * 2
        case .reading:
            pupil = CGPoint(x: (t.truncatingRemainder(dividingBy: 2.0) - 1.0) * 1.8 * motion, y: 1.0)
            tilt = 6
        case .asleep:
            eyeClosed = true
            tilt = 10
        }

        let body = Color("BirdBody")
        let belly = Color("BirdBelly")
        let beak = Color("BirdBeak")

        // Short legs and small feet stay on the wire while the body moves.
        var legs = Path()
        for x in [45.0, 55.0] {
            legs.move(to: CGPoint(x: x * u, y: 80 * u + bob * u))
            legs.addLine(to: CGPoint(x: x * u, y: 88 * u))
            legs.move(to: CGPoint(x: (x - 3) * u, y: 89 * u))
            legs.addLine(to: CGPoint(x: (x + 3) * u, y: 89 * u))
        }
        ctx.stroke(legs, with: .color(beak), style: StrokeStyle(lineWidth: 2.4 * u, lineCap: .round))

        ctx.translateBy(x: 50 * u, y: 56 * u + bob * u)
        ctx.rotate(by: .degrees(tilt))
        ctx.translateBy(x: -50 * u, y: -56 * u)

        // A shade of the body colour for the tail and wing.
        let shade = Color.birdWing

        // Tail: short and rounded
        var tail = Path()
        tail.move(to: CGPoint(x: 26 * u, y: 58 * u))
        tail.addQuadCurve(to: CGPoint(x: 9 * u, y: 50 * u), control: CGPoint(x: 14 * u, y: 58 * u))
        tail.addQuadCurve(to: CGPoint(x: 30 * u, y: 70 * u), control: CGPoint(x: 13 * u, y: 68 * u))
        tail.closeSubpath()
        ctx.fill(tail, with: .color(shade))

        // Body and belly
        let bodyRect = CGRect(x: 20 * u, y: 24 * u, width: 60 * u, height: 58 * u)
        ctx.fill(Path(ellipseIn: bodyRect), with: .color(body))
        ctx.fill(
            Path(ellipseIn: CGRect(x: 38 * u, y: 46 * u, width: 38 * u, height: 34 * u)), with: .color(belly))

        // Wing, in the bird's own colour
        var wing = Path()
        wing.move(to: CGPoint(x: 27 * u, y: 50 * u))
        wing.addQuadCurve(to: CGPoint(x: 50 * u, y: 66 * u), control: CGPoint(x: 29 * u, y: 71 * u))
        wing.addQuadCurve(to: CGPoint(x: 27 * u, y: 50 * u), control: CGPoint(x: 49 * u, y: 50 * u))
        ctx.fill(wing, with: .color(shade))

        // Beak: short and rounded, in two halves that open
        let open = beakOpen * 6 * u
        var lower = Path()
        lower.move(to: CGPoint(x: 77 * u, y: 49 * u))
        lower.addQuadCurve(to: CGPoint(x: 86 * u, y: 50 * u + open), control: CGPoint(x: 83 * u, y: 49 * u + open * 0.6))
        lower.addQuadCurve(to: CGPoint(x: 77 * u, y: 53 * u), control: CGPoint(x: 83 * u, y: 53.5 * u + open))
        lower.closeSubpath()
        var upper = Path()
        upper.move(to: CGPoint(x: 77 * u, y: 45 * u))
        upper.addQuadCurve(to: CGPoint(x: 88 * u, y: 49 * u - open * 0.3), control: CGPoint(x: 86 * u, y: 45.5 * u - open * 0.3))
        upper.addQuadCurve(to: CGPoint(x: 77 * u, y: 50.5 * u), control: CGPoint(x: 84 * u, y: 51 * u))
        upper.closeSubpath()
        ctx.fill(lower, with: .color(beak.opacity(0.8)))
        ctx.fill(upper, with: .color(beak))

        // Cheek
        ctx.fill(
            Path(ellipseIn: CGRect(x: 65 * u, y: 48 * u, width: 8 * u, height: 8 * u)),
            with: .color(Color.birdCheek.opacity(0.45)))

        // Eye: a dark bead with one glint, never a white eyeball. It shifts a little to look around.
        let eyeCenter = CGPoint(x: (63 + pupil.x * 0.7) * u, y: (43 + pupil.y * 0.7) * u)
        if eyeClosed {
            var lid = Path()
            lid.move(to: CGPoint(x: eyeCenter.x - 4 * u, y: eyeCenter.y))
            lid.addQuadCurve(
                to: CGPoint(x: eyeCenter.x + 4 * u, y: eyeCenter.y),
                control: CGPoint(x: eyeCenter.x, y: eyeCenter.y + 3.5 * u))
            ctx.stroke(lid, with: .color(Color.birdEye), style: StrokeStyle(lineWidth: 2 * u, lineCap: .round))
        } else {
            ctx.fill(
                Path(ellipseIn: CGRect(x: eyeCenter.x - 4.6 * u, y: eyeCenter.y - 4.6 * u, width: 9.2 * u, height: 9.2 * u)),
                with: .color(Color.birdEye))
            ctx.fill(
                Path(ellipseIn: CGRect(x: eyeCenter.x + 0.1 * u, y: eyeCenter.y - 3.1 * u, width: 3 * u, height: 3 * u)),
                with: .color(.white))
        }
    }
}

/// The wire the bird sits on. It is flat when quiet and becomes the live waveform when there is sound.
struct Wire: View {
    /// Recent audio levels, oldest first, each 0…1.
    var levels: [Double]
    var color: Color = Color("Ink")
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            let mid = size.height / 2
            guard levels.count > 1 else {
                path.move(to: CGPoint(x: 0, y: mid))
                path.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                return
            }
            let step = size.width / CGFloat(levels.count - 1)
            for (i, level) in levels.enumerated() {
                // Alternate above and below the line so it reads as a wave.
                let sign: CGFloat = i.isMultiple(of: 2) ? -1 : 1
                let y = mid + sign * CGFloat(max(0, min(1, level))) * (size.height / 2 - lineWidth)
                let p = CGPoint(x: CGFloat(i) * step, y: y)
                if i == 0 {
                    path.move(to: p)
                } else {
                    let prev = CGPoint(x: CGFloat(i - 1) * step, y: path.currentPoint?.y ?? mid)
                    path.addCurve(
                        to: p, control1: CGPoint(x: prev.x + step / 2, y: prev.y),
                        control2: CGPoint(x: p.x - step / 2, y: p.y))
                }
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
