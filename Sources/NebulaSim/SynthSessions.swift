// Whole synthetic sessions: a person at a desk making gestures between
// rests, or just using the Mac (typing, mousing, drinking, talking with
// their hands), sampled at the camera's frame rate and labelled the way the
// Practice-screen recorder labels real ones.

import Foundation
import NebulaCore

public struct SynthOptions {
    public var fps: Double = 60
    public var aspect: Float = 4.0 / 3.0
    public var repetitions = 20
    public var nothingMinutes: Double = 5

    // How sloppy the hand is, for Galaxy Trainer's workouts. The defaults are the tidy hand
    // the corpus has always used, so nothing that was there before changes.
    /// Multiplies the hand's tremor.
    public var tremor: Float = 1
    /// Movements play this many times faster (motion blur, a hurried hand) or slower.
    public var speed: Double = 1
    /// Extra wrist turn, in degrees of random roll.
    public var wristTurn: Float = 0
    /// How far every pose slumps toward a relaxed hand: a lazy, half-made gesture. 0 to 0.6.
    public var halfFormed: Float = 0
    /// The chance a frame loses the hand (bad light, a finger out of view, the frame edge).
    public var dropout: Float = 0
    /// The chance the hand works near the edge of the frame.
    public var edge: Float = 0
    /// Multiplies the joints' jitter (low or uneven light).
    public var jointNoise: Float = 1

    public init() {}
}

/// One stretch of movement: shape and palm centre eased from `from` to `to`.
struct Segment {
    var duration: Double
    var fromShape: HandShape, toShape: HandShape
    var from: (Float, Float), to: (Float, Float)
    var size: Float
    var visible = true
    var ease: (Float) -> Float = { t in t * t * (3 - 2 * t) }
    /// Extra positional movement over the segment, in palm lengths (for waves).
    var wobble: ((Float) -> (Float, Float))? = nil
}

public struct SessionBuilder {
    public var g: SplitMix
    let options: SynthOptions
    var time: Double = 0
    var frames: [Frame] = []
    var labels: [SegmentLabel] = []
    var person: Person
    var left: Bool
    var face: FaceBox
    var faceCenter: (Float, Float) // user space
    var faceWidth: Float, faceHeight: Float
    var size: Float
    var reportUnknownChirality = false

    public init(seed: UInt64, options: SynthOptions, left: Bool, distanceCm: Int) {
        var g = SplitMix(seed: seed)
        self.options = options
        self.left = left
        person = Person.random(&g)
        person.noise *= max(options.jointNoise, 0.1)
        // Palm length ≈ 9.5 cm; vertical field of view ≈ 55°.
        let viewHeight = 2 * Float(distanceCm) * tan(27.5 * .pi / 180)
        size = 9.5 / viewHeight * g.uniform(0.92, 1.08)
        faceWidth = 15 / viewHeight * options.aspect / options.aspect
        faceHeight = faceWidth * 1.25
        faceCenter = (options.aspect * 0.5 + g.uniform(-0.08, 0.08), g.uniform(0.6, 0.7))
        let raw = SessionBuilder.rawFace(center: faceCenter, width: faceWidth, height: faceHeight, aspect: options.aspect)
        face = raw
        self.g = g
    }

    static func rawFace(center: (Float, Float), width: Float, height: Float, aspect: Float) -> FaceBox {
        FaceBox(x: 1 - (center.0 + width / 2) / aspect, y: center.1 - height / 2, width: width / aspect, height: height)
    }

    var lips: (Float, Float) { (faceCenter.0, faceCenter.1 - faceHeight / 2 + faceHeight * 0.22) }
    func ear(_ right: Bool) -> (Float, Float) { (faceCenter.0 + (right ? 1 : -1) * faceWidth * 0.5, faceCenter.1) }

    // MARK: Sampling

    mutating func play(_ seg: Segment) {
        let dt = 1 / options.fps
        let duration = seg.duration / max(options.speed, 0.2)
        // A lazy hand: every pose slumps part of the way toward relaxed.
        let slump: HandShape? = options.halfFormed > 0 ? HandShape.make(.relaxed, &g) : nil
        var t = 0.0
        while t < duration {
            let u = Float(t / max(duration, 1e-6))
            let e = seg.ease(u)
            var shape = HandShape.lerp(seg.fromShape, seg.toShape, e)
            if let slump { shape = HandShape.lerp(shape, slump, min(options.halfFormed, 0.6)) }
            var cx = seg.from.0 + (seg.to.0 - seg.from.0) * e
            var cy = seg.from.1 + (seg.to.1 - seg.from.1) * e
            if let w = seg.wobble {
                let (wx, wy) = w(u)
                cx += wx * seg.size
                cy += wy * seg.size
            }
            // Tremor.
            cx += g.gaussian() * 0.012 * seg.size * options.tremor
            cy += g.gaussian() * 0.012 * seg.size * options.tremor
            shape.roll += g.gaussian() * (0.6 + options.wristTurn)
            var frame = Frame(time: time, aspect: options.aspect)
            frame.setFace(g.chance(0.97) ? jitteredFace() : nil)
            if seg.visible && !(options.dropout > 0 && g.chance(options.dropout)) {
                frame.handCount = 1
                frame.hand0 = Synth.render(shape, center: (cx, cy), size: seg.size, left: left, person: person,
                                           aspect: options.aspect,
                                           reportedChirality: reportUnknownChirality ? .unknown : nil, g: &g)
            }
            frames.append(frame)
            time += dt * Double(g.uniform(0.97, 1.03))
            t += dt
        }
    }

    mutating func jitteredFace() -> FaceBox {
        var f = face
        f.x += g.gaussian() * 0.002
        f.y += g.gaussian() * 0.002
        return f
    }

    mutating func rest(_ seconds: Double) {
        // Hand down out of view, or resting low at the bottom edge.
        if g.chance(0.6) {
            play(Segment(duration: seconds, fromShape: HandShape(), toShape: HandShape(), from: (0, 0), to: (0, 0),
                         size: size, visible: false))
        } else {
            let s = HandShape.make(.typing, &g)
            let p = (options.aspect * g.uniform(0.3, 0.7), g.uniform(0.02, 0.12))
            play(Segment(duration: seconds, fromShape: s, toShape: s, from: p, to: (p.0 + g.uniform(-0.05, 0.05), p.1), size: size))
        }
    }

    mutating func center() -> (Float, Float) {
        if options.edge > 0 && g.chance(options.edge) {
            // Working near the edge of the frame, where hands get cut off.
            let x = g.chance(0.5) ? g.uniform(0.1, 0.2) : g.uniform(0.8, 0.9)
            return (options.aspect * x, g.uniform(0.25, 0.75))
        }
        return (options.aspect * g.uniform(0.3, 0.7) + (left ? -0.1 : 0.1), g.uniform(0.35, 0.6))
    }

    /// Where the palm centre must be for the index fingertip to land on `target`.
    mutating func placeIndexTip(_ shape: HandShape, at target: (Float, Float)) -> (Float, Float) {
        let probe = Synth.render(shape, center: (0.5, 0.5), size: size, left: left,
                                 person: Person(scale: person.scale, noise: 0, flexBias: person.flexBias),
                                 aspect: options.aspect, g: &g)
        let tipX = (1 - probe.x[8]) * options.aspect, tipY = probe.y[8]
        return (target.0 - (tipX - 0.5), target.1 - (tipY - 0.5))
    }

    // MARK: Gestures

    public mutating func perform(_ label: String) {
        let start = time
        let low = (options.aspect * g.uniform(0.35, 0.65), Float(0.05))
        let relaxed = HandShape.make(.relaxed, &g)
        let approach = Double(g.uniform(0.25, 0.4))
        switch label {
        case "openPalm", "thumbsUp", "thumbsDown", "peace", "fingerToLips", "handToEar":
            let kind: ShapeKind = ["openPalm": .flat, "thumbsUp": .thumbsUp, "thumbsDown": .thumbsDown, "peace": .peace,
                                   "fingerToLips": .lips, "handToEar": .ear][label]!
            let shape = HandShape.make(kind, &g)
            var at = center()
            if label == "fingerToLips" { at = placeIndexTip(shape, at: lips) }
            if label == "handToEar" {
                let e = ear(!left)
                at = (e.0 + (left ? -1 : 1) * faceWidth * g.uniform(0.0, 0.25), e.1 + g.uniform(-0.05, 0.05))
            }
            play(Segment(duration: approach, fromShape: relaxed, toShape: shape, from: low, to: at, size: size))
            let hold = Double(g.uniform(0.45, 0.9))
            play(Segment(duration: hold, fromShape: shape, toShape: shape, from: at, to: at, size: size))
            play(Segment(duration: 0.3, fromShape: shape, toShape: relaxed, from: at, to: low, size: size))
        case "swipeLeft", "swipeRight":
            let dir: Float = label == "swipeRight" ? 1 : -1
            let shape = HandShape.make(.flat, &g)
            let distance = g.uniform(3.0, 4.4) * size
            let y = g.uniform(0.4, 0.6)
            let x0 = options.aspect * 0.5 - dir * distance / 2
            let x1 = x0 + dir * distance
            play(Segment(duration: approach, fromShape: relaxed, toShape: shape, from: low, to: (x0, y), size: size))
            let pause = Double(g.uniform(0, 0.1))
            if pause > 0.02 { play(Segment(duration: pause, fromShape: shape, toShape: shape, from: (x0, y), to: (x0, y), size: size)) }
            let duration = Double(g.uniform(0.25, 0.42))
            var stroke = Segment(duration: duration, fromShape: shape, toShape: shape, from: (x0, y), to: (x1, y + g.uniform(-0.3, 0.3) * size), size: size)
            stroke.ease = { t in t * t * t * (10 - 15 * t + 6 * t * t) } // minimum jerk
            play(stroke)
            play(Segment(duration: 0.3, fromShape: shape, toShape: relaxed, from: (x1, y), to: (x1, 0.05), size: size))
        case "wave":
            let shape = HandShape.make(.open, &g)
            let at = center()
            play(Segment(duration: approach, fromShape: relaxed, toShape: shape, from: low, to: at, size: size))
            let freq = g.uniform(2.0, 3.0), amp = g.uniform(0.55, 0.8)
            let cycles = g.uniform(1.6, 2.6)
            let duration = Double(cycles / freq)
            var wave = Segment(duration: duration, fromShape: shape, toShape: shape, from: at, to: at, size: size)
            wave.ease = { $0 }
            let phase = g.chance(0.5) ? Float.pi : 0
            wave.wobble = { u in (amp * sin(2 * .pi * cycles * u + phase), 0) }
            play(wave)
            play(Segment(duration: 0.3, fromShape: shape, toShape: relaxed, from: at, to: low, size: size))
        case "scroll":
            let shape = HandShape.make(.scroll, &g)
            let at = center()
            let dir: Float = g.chance(0.5) ? 1 : -1
            let end = (at.0, at.1 + dir * g.uniform(1.0, 2.2) * size)
            play(Segment(duration: approach, fromShape: relaxed, toShape: shape, from: low, to: at, size: size))
            play(Segment(duration: Double(g.uniform(0.25, 0.4)), fromShape: shape, toShape: shape, from: at, to: at, size: size))
            play(Segment(duration: Double(g.uniform(0.6, 1.1)), fromShape: shape, toShape: shape, from: at, to: end, size: size))
            play(Segment(duration: 0.25, fromShape: shape, toShape: HandShape.make(.fist, &g), from: end, to: end, size: size))
            play(Segment(duration: 0.25, fromShape: HandShape.make(.fist, &g), toShape: relaxed, from: end, to: low, size: size))
        case "volumeUp", "volumeDown":
            var shape = HandShape.make(.pinch, &g)
            let at = center()
            play(Segment(duration: approach, fromShape: relaxed, toShape: shape, from: low, to: at, size: size))
            play(Segment(duration: Double(g.uniform(0.25, 0.4)), fromShape: shape, toShape: shape, from: at, to: at, size: size))
            // Clockwise (volume up) as you see it is a negative roll; mirrored for a left hand.
            var twist = g.uniform(35, 70) * (label == "volumeUp" ? -1 : 1)
            if left { twist = -twist }
            var turned = shape
            turned.roll += twist
            play(Segment(duration: Double(g.uniform(0.45, 0.8)), fromShape: shape, toShape: turned, from: at, to: at, size: size))
            shape = turned
            play(Segment(duration: 0.3, fromShape: shape, toShape: relaxed, from: at, to: low, size: size))
        default:
            fatalError("no synthetic recipe for \(label)")
        }
        labels.append(SegmentLabel(gesture: label, start: start, end: time))
    }

    // MARK: Ordinary activity

    public mutating func activity() {
        let kinds = ["typing", "mouse", "drink", "faceTouch", "hair", "talking", "stretch", "phone", "reach", "rest"]
        let k = kinds[Int.random(in: 0..<kinds.count, using: &g)]
        let low = (options.aspect * g.uniform(0.3, 0.7), g.uniform(0.03, 0.14))
        switch k {
        case "typing", "mouse":
            let s = HandShape.make(k == "typing" ? .typing : .claw, &g)
            for _ in 0..<Int(g.uniform(3, 8)) {
                let p = (low.0 + g.uniform(-0.1, 0.1), low.1 + g.uniform(-0.02, 0.06))
                play(Segment(duration: Double(g.uniform(0.3, 1)), fromShape: s, toShape: HandShape.make(k == "typing" ? .typing : .claw, &g), from: low, to: p, size: size))
            }
        case "drink", "faceTouch":
            let s = HandShape.make(k == "drink" ? .phone : [.relaxed, .scratch, .ok, .fist][Int.random(in: 0..<4, using: &g)], &g)
            let target = (lips.0 + g.uniform(-0.6, 0.6) * faceWidth, lips.1 + g.uniform(-0.25, 0.3) * faceHeight)
            play(Segment(duration: Double(g.uniform(0.4, 0.8)), fromShape: HandShape.make(.relaxed, &g), toShape: s, from: low, to: target, size: size))
            play(Segment(duration: Double(g.uniform(0.6, 2.5)), fromShape: s, toShape: HandShape.make(.relaxed, &g), from: target, to: (target.0 + g.uniform(-0.03, 0.03), target.1), size: size))
            play(Segment(duration: 0.5, fromShape: s, toShape: HandShape.make(.relaxed, &g), from: target, to: low, size: size))
        case "hair":
            // Fingers in the hair, above and around the ear, rubbing.
            let s = HandShape.make([.open, .claw, .relaxed, .scratch][Int.random(in: 0..<4, using: &g)], &g)
            let e = ear(g.chance(0.5))
            let target = (e.0 + g.uniform(-0.1, 0.1), e.1 + faceHeight * g.uniform(0.25, 0.6))
            play(Segment(duration: 0.5, fromShape: HandShape.make(.relaxed, &g), toShape: s, from: low, to: target, size: size))
            var rub = Segment(duration: Double(g.uniform(0.6, 2)), fromShape: s, toShape: s, from: target, to: target, size: size)
            let f = g.uniform(1.5, 4)
            rub.wobble = { u in (0.25 * sin(2 * .pi * f * u), 0.15 * cos(2 * .pi * f * u)) }
            play(rub)
            play(Segment(duration: 0.5, fromShape: s, toShape: HandShape.make(.relaxed, &g), from: target, to: low, size: size))
        case "talking":
            var shape = HandShape.make([.open, .relaxed, .flat, .twoLoose, .pointing][Int.random(in: 0..<5, using: &g)], &g)
            var p = center()
            for _ in 0..<Int(g.uniform(4, 10)) {
                let next = HandShape.make([.open, .relaxed, .flat, .twoLoose, .claw, .pointing][Int.random(in: 0..<6, using: &g)], &g)
                let q = (min(max(p.0 + g.uniform(-1.5, 1.5) * size, 0.3), options.aspect - 0.3), min(max(p.1 + g.uniform(-1, 1) * size, 0.25), 0.75))
                play(Segment(duration: Double(g.uniform(0.15, 0.5)), fromShape: shape, toShape: next, from: p, to: q, size: size))
                shape = next
                p = q
            }
        case "stretch":
            let s = HandShape.make(.open, &g)
            let p = center()
            play(Segment(duration: 0.6, fromShape: HandShape.make(.relaxed, &g), toShape: s, from: low, to: (p.0, 0.97), size: size))
            play(Segment(duration: 0.6, fromShape: s, toShape: HandShape.make(.relaxed, &g), from: (p.0, 0.97), to: low, size: size))
        case "phone":
            let s = HandShape.make(.phone, &g)
            let p = center()
            play(Segment(duration: Double(g.uniform(2, 5)), fromShape: s, toShape: HandShape.make(.phone, &g), from: p, to: (p.0 + 0.02, p.1 - 0.02), size: size))
        case "reach":
            let s = HandShape.make(g.chance(0.5) ? .restingOpen : .relaxed, &g)
            let y = g.uniform(0.2, 0.45)
            var seg = Segment(duration: Double(g.uniform(0.35, 0.7)), fromShape: s, toShape: s,
                              from: (options.aspect * 0.15, y), to: (options.aspect * 0.85, y + g.uniform(-0.1, 0.1)), size: size)
            if g.chance(0.5) { swap(&seg.from, &seg.to) }
            play(seg)
        default:
            rest(Double(g.uniform(1, 3)))
        }
    }

    /// The poses most like each gesture without being it, held and moved a little.
    public mutating func nearMiss() {
        let kinds: [ShapeKind] = [.restingOpen, .twoLoose, .fistNoThumb, .scratch, .relaxed, .ok, .pointing, .claw, .fist, .phone]
        let k = kinds[Int.random(in: 0..<kinds.count, using: &g)]
        let s = HandShape.make(k, &g)
        var at = center()
        if k == .scratch { at = (lips.0 + g.uniform(-0.1, 0.1) * faceWidth, lips.1 - faceHeight * 0.15) }
        if k == .relaxed && g.chance(0.5) { at = (lips.0, lips.1 - faceHeight * 0.05) }
        // Pointing up anywhere but at the lips (at the lips it *is* the gesture).
        if k == .pointing { at = (at.0 + (g.chance(0.5) ? 1 : -1) * faceWidth * g.uniform(0.9, 1.5), g.uniform(0.25, 0.42)) }
        if k == .restingOpen { at.1 = g.uniform(0.1, 0.25) }
        let start = time
        let low = (options.aspect * 0.5, Float(0.05))
        play(Segment(duration: 0.4, fromShape: HandShape.make(.relaxed, &g), toShape: s, from: low, to: at, size: size))
        play(Segment(duration: Double(g.uniform(0.8, 2.5)), fromShape: s, toShape: s, from: at, to: (at.0 + g.uniform(-0.03, 0.03), at.1), size: size))
        play(Segment(duration: 0.4, fromShape: s, toShape: HandShape.make(.relaxed, &g), from: at, to: low, size: size))
        labels.append(SegmentLabel(gesture: "nearMiss:\(k.rawValue)", start: start, end: time))
    }

    public mutating func finish(_ info: SessionInfo) -> Recording {
        var info = info
        info.fps = options.fps
        info.synthetic = true
        return Recording(info: info, frames: frames, labels: labels)
    }
}

public enum SynthCorpus {
    public static let gestureLabels = ["openPalm", "thumbsUp", "thumbsDown", "peace", "fingerToLips", "handToEar",
                                       "swipeLeft", "swipeRight", "scroll", "volumeUp", "volumeDown", "wave"]

    /// A corpus shaped like the recording plan: gesture sessions at three distances
    /// with both hands, nothing sessions and near-miss sessions, each given a role.
    public static func make(seed: UInt64, sessions: Int = 8, options: SynthOptions = SynthOptions()) -> [Recording] {
        var out: [Recording] = []
        let roles: [SessionInfo.Role] = [.train, .train, .validation, .test]
        let distances = [40, 70, 100, 55, 85]
        for s in 0..<sessions {
            let role = roles[s % roles.count]
            let distance = distances[s % distances.count]
            for (k, left) in [false, true].enumerated() {
                var opts = options
                opts.fps = (s + k) % 2 == 0 ? options.fps : 30
                var b = SessionBuilder(seed: seed &+ UInt64(s * 31 + k * 7 + 1), options: opts, left: left, distanceCm: distance)
                b.reportUnknownChirality = false
                b.rest(1)
                var order: [String] = []
                for _ in 0..<max(1, options.repetitions / 2) { order += gestureLabels }
                order.shuffle(using: &b.g)
                for label in order {
                    b.perform(label)
                    b.rest(Double(b.g.uniform(0.8, 1.6)))
                }
                out.append(b.finish(SessionInfo(id: "synth-g\(s)-\(left ? "L" : "R")", kind: .gestures, startedAt: Double(s * 10 + k),
                                                lighting: "synthetic", distanceCm: distance, hands: left ? "left" : "right", role: role)))
            }
            var n = SessionBuilder(seed: seed &+ UInt64(1000 + s), options: options, left: s % 2 == 1, distanceCm: distance)
            while n.time < options.nothingMinutes * 60 { n.activity() }
            out.append(n.finish(SessionInfo(id: "synth-n\(s)", kind: .nothing, startedAt: Double(s * 10 + 5), lighting: "synthetic",
                                            distanceCm: distance, role: role)))
            var m = SessionBuilder(seed: seed &+ UInt64(2000 + s), options: options, left: s % 2 == 0, distanceCm: distance)
            for _ in 0..<30 { m.nearMiss(); m.rest(0.6) }
            out.append(m.finish(SessionInfo(id: "synth-m\(s)", kind: .nearMiss, startedAt: Double(s * 10 + 6), lighting: "synthetic",
                                            distanceCm: distance, role: role)))
        }
        return out
    }
}
