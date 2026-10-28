// A synthetic hand: a small 3D kinematic model posed, moved, projected and
// jittered the way Vision's 21 joints come out of a webcam.
//
// It exists so the recognizer, the report and the latency benchmark can be
// built and tested before any real recordings exist. Numbers measured on it
// say the pipeline works; they are never evidence that a gesture meets its
// target on your hands. Everything it writes is marked `synthetic`.

import Foundation
import NebulaCore

public struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension RandomNumberGenerator {
    mutating func uniform(_ lo: Float, _ hi: Float) -> Float { Float.random(in: lo...hi, using: &self) }
    mutating func gaussian() -> Float {
        let u1 = max(Float.random(in: 0..<1, using: &self), 1e-7)
        let u2 = Float.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    mutating func chance(_ p: Float) -> Bool { Float.random(in: 0..<1, using: &self) < p }
}

struct V3 {
    var x: Float, y: Float, z: Float
    static func + (a: V3, b: V3) -> V3 { V3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    static func * (a: V3, s: Float) -> V3 { V3(x: a.x * s, y: a.y * s, z: a.z * s) }
    var length: Float { (x * x + y * y + z * z).squareRoot() }
    var normalized: V3 { let l = max(length, 1e-6); return V3(x: x / l, y: y / l, z: z / l) }
}

/// Joint angles and orientation: everything that makes a hand shape. Degrees.
public struct HandShape {
    /// [MCP, PIP, DIP] flexion per finger, index...little.
    public var flex: [[Float]] = Array(repeating: [3, 3, 2], count: 4)
    /// Splay of each finger from straight up, index...little; positive toward the little finger.
    public var splay: [Float] = [-6, 0, 5, 11]
    /// Thumb: abduction from the index side, opposition toward the palm, and flexion [MP, IP].
    public var thumbAbduction: Float = 35
    public var thumbOpposition: Float = 15
    public var thumbFlex: [Float] = [5, 5]
    /// Orientation: roll in the image plane, yaw about the vertical, pitch about the horizontal.
    public var roll: Float = 0
    public var yaw: Float = 0
    public var pitch: Float = 0

    public init() {}

    public static func lerp(_ a: HandShape, _ b: HandShape, _ t: Float) -> HandShape {
        var o = a
        for i in 0..<4 { for j in 0..<3 { o.flex[i][j] = a.flex[i][j] + (b.flex[i][j] - a.flex[i][j]) * t } }
        for i in 0..<4 { o.splay[i] = a.splay[i] + (b.splay[i] - a.splay[i]) * t }
        o.thumbAbduction = a.thumbAbduction + (b.thumbAbduction - a.thumbAbduction) * t
        o.thumbOpposition = a.thumbOpposition + (b.thumbOpposition - a.thumbOpposition) * t
        for j in 0..<2 { o.thumbFlex[j] = a.thumbFlex[j] + (b.thumbFlex[j] - a.thumbFlex[j]) * t }
        o.roll = a.roll + (b.roll - a.roll) * t
        o.yaw = a.yaw + (b.yaw - a.yaw) * t
        o.pitch = a.pitch + (b.pitch - a.pitch) * t
        return o
    }
}

/// How a person's hand differs from the model: proportions and how they hold poses.
public struct Person {
    var scale: [Float]   // per finger length multiplier, thumb first
    var noise: Float     // joint jitter, palm lengths
    var flexBias: Float  // how tightly they curl

    public static func random<G: RandomNumberGenerator>(_ g: inout G) -> Person {
        Person(scale: (0..<5).map { _ in g.uniform(0.9, 1.1) }, noise: g.uniform(0.015, 0.03), flexBias: g.uniform(-8, 8))
    }
}

public enum Synth {
    static let knuckles: [V3] = [
        V3(x: -0.32, y: 0.93, z: 0), V3(x: 0, y: 1, z: 0), V3(x: 0.27, y: 0.95, z: 0), V3(x: 0.5, y: 0.84, z: 0),
    ]
    static let segments: [[Float]] = [[0.42, 0.25, 0.2], [0.47, 0.29, 0.21], [0.44, 0.28, 0.21], [0.35, 0.2, 0.18]]
    static let thumbBase = V3(x: -0.25, y: 0.22, z: 0.05)
    static let thumbSegments: [Float] = [0.45, 0.33, 0.28]

    /// The 21 joints in hand space: right hand, palm toward the camera (+z), fingers up (+y),
    /// x to your right in the mirror view, palm lengths.
    static func joints(_ s: HandShape, person p: Person) -> [V3] {
        var out = [V3](repeating: V3(x: 0, y: 0, z: 0), count: 21)
        let rad: Float = .pi / 180
        for f in 0..<4 {
            let phi = s.splay[f] * rad
            let d0 = V3(x: sin(phi), y: cos(phi), z: 0)
            var pos = knuckles[f]
            out[5 + f * 4] = pos
            var theta: Float = 0
            for k in 0..<3 {
                theta += max(s.flex[f][k] + (s.flex[f][k] > 20 ? p.flexBias : 0), -5) * rad
                let dir = d0 * cos(theta) + V3(x: 0, y: 0, z: 1) * sin(theta)
                pos = pos + dir * (segments[f][k] * p.scale[f + 1])
                out[6 + f * 4 + k] = pos
            }
        }
        let a = s.thumbAbduction * rad, b = s.thumbOpposition * rad
        let t0 = V3(x: -sin(a), y: cos(a), z: 0)
        let base = (t0 * cos(b) + V3(x: 0, y: 0, z: 1) * sin(b)).normalized
        let across = V3(x: 0.75, y: -0.1, z: 0.65).normalized
        var pos = thumbBase
        out[1] = pos
        var theta: Float = 0
        for k in 0..<3 {
            if k > 0 { theta += s.thumbFlex[k - 1] * rad }
            let dir = (base * cos(theta) + across * sin(theta)).normalized
            pos = pos + dir * (thumbSegments[k] * p.scale[0])
            out[2 + k] = pos
        }
        return out
    }

    /// Rotates hand-space joints by the shape's roll, yaw and pitch.
    static func orient(_ pts: [V3], _ s: HandShape) -> [V3] {
        let rad: Float = .pi / 180
        let (cr, sr) = (cos(s.roll * rad), sin(s.roll * rad))
        let (cy, sy) = (cos(s.yaw * rad), sin(s.yaw * rad))
        let (cp, sp) = (cos(s.pitch * rad), sin(s.pitch * rad))
        return pts.map { v in
            // yaw about y, then pitch about x, then roll about z (the camera axis).
            let x1 = v.x * cy + v.z * sy, z1 = -v.x * sy + v.z * cy
            let y2 = v.y * cp - z1 * sp, z2 = v.y * sp + z1 * cp
            return V3(x: x1 * cr - y2 * sr, y: x1 * sr + y2 * cr, z: z2)
        }
    }

    /// Projects one hand into a Vision-style observation.
    /// `center` is where the palm centre lands in user space (frame heights; y 0 bottom to 1 top).
    public static func render<G: RandomNumberGenerator>(_ shape: HandShape, center: (Float, Float), size: Float,
                                                        left: Bool, person: Person, aspect: Float,
                                                        reportedChirality: Chirality? = nil, g: inout G) -> Hand {
        var pts = orient(joints(shape, person: person), shape)
        if left { pts = pts.map { V3(x: -$0.x, y: $0.y, z: $0.z) } }
        // Palm centre in hand space, to place the hand.
        let idx = [0, 5, 9, 13, 17]
        var cx: Float = 0, cy: Float = 0
        for i in idx { cx += pts[i].x; cy += pts[i].y }
        cx /= 5
        cy /= 5
        var hand = Hand()
        hand.chirality = reportedChirality ?? (left ? .left : .right)
        let curled = shape.flex.map { $0.reduce(0, +) > 150 }
        for j in 0..<21 {
            // Mild perspective: nearer joints a little bigger.
            let persp = 1 + pts[j].z * size * 0.25
            var ux = center.0 + (pts[j].x - cx) * size * persp
            var uy = center.1 + (pts[j].y - cy) * size * persp
            ux += g.gaussian() * person.noise * size
            uy += g.gaussian() * person.noise * size
            if g.chance(0.0015) {
                ux += g.uniform(-0.25, 0.25) * size
                uy += g.uniform(-0.25, 0.25) * size
            }
            let finger = j >= 5 ? (j - 5) / 4 : -1
            let hidden = finger >= 0 && curled[finger] && (j - 5) % 4 >= 2
            let conf: Float = hidden ? g.uniform(0.15, 0.55) : g.uniform(0.55, 0.97)
            hand.set(Joint(rawValue: j)!, 1 - ux / aspect, uy, confidence: conf)
        }
        return hand
    }
}

// MARK: - Poses

public enum ShapeKind: String, CaseIterable {
    case flat, open, fist, thumbsUp, thumbsDown, peace, scroll, lips, ear, pinch
    // Near-misses and ordinary activity.
    case relaxed, typing, restingOpen, twoLoose, fistNoThumb, scratch, phone, pointing, ok, claw
}

extension HandShape {
    static let fistFlex: [Float] = [85, 100, 60]
    static let curlFlex: [Float] = [80, 100, 60]

    public static func make<G: RandomNumberGenerator>(_ kind: ShapeKind, _ g: inout G) -> HandShape {
        var s = HandShape()
        func j(_ v: Float, _ r: Float) -> Float { v + g.uniform(-r, r) }
        func fingers(_ f: [Float], _ r: Float) -> [Float] { f.map { j($0, r) } }
        s.yaw = j(0, 15)
        s.pitch = j(0, 12)
        s.roll = j(0, 12)
        switch kind {
        case .flat:
            s.flex = (0..<4).map { _ in fingers([3, 3, 2], 4) }
            s.splay = [j(-5, 3), j(0, 2), j(5, 3), j(10, 4)]
            s.thumbAbduction = j(30, 10)
            s.thumbOpposition = j(12, 8)
            s.thumbFlex = [j(5, 5), j(5, 5)]
        case .open:
            s.flex = (0..<4).map { _ in fingers([5, 5, 3], 5) }
            s.splay = [j(-16, 5), j(0, 3), j(13, 5), j(27, 6)]
            s.thumbAbduction = j(55, 10)
            s.thumbOpposition = j(10, 8)
            s.thumbFlex = [j(5, 5), j(5, 5)]
        case .fist, .fistNoThumb:
            s.flex = (0..<4).map { _ in fingers(fistFlex, 8) }
            s.splay = [j(-3, 3), j(0, 2), j(3, 3), j(6, 3)]
            s.thumbAbduction = j(15, 8)
            s.thumbOpposition = j(55, 10)
            s.thumbFlex = [j(45, 10), j(40, 10)]
        case .thumbsUp, .thumbsDown:
            s.flex = (0..<4).map { _ in fingers(fistFlex, 8) }
            s.splay = [j(-3, 3), j(0, 2), j(3, 3), j(6, 3)]
            s.thumbAbduction = j(82, 8)
            s.thumbOpposition = j(8, 8)
            s.thumbFlex = [j(5, 5), j(5, 5)]
            s.roll = kind == .thumbsUp ? j(-90, 20) : j(90, 20)
            s.yaw = j(-25, 40)
        case .peace:
            s.flex = [fingers([3, 3, 2], 4), fingers([3, 3, 2], 4), fingers(curlFlex, 8), fingers(curlFlex, 8)]
            s.splay = [j(-17, 4), j(14, 4), j(4, 3), j(8, 3)]
            s.thumbAbduction = j(10, 6)
            s.thumbOpposition = j(60, 10)
            s.thumbFlex = [j(50, 10), j(40, 10)]
        case .scroll:
            s.flex = [fingers([3, 3, 2], 4), fingers([3, 3, 2], 4), fingers(curlFlex, 8), fingers(curlFlex, 8)]
            s.splay = [j(-2, 1.5), j(1, 1.5), j(4, 3), j(8, 3)]
            s.thumbAbduction = j(10, 6)
            s.thumbOpposition = j(60, 10)
            s.thumbFlex = [j(50, 10), j(40, 10)]
        case .lips, .pointing:
            s.flex = [fingers([3, 3, 2], 5), fingers(curlFlex, 8), fingers(curlFlex, 8), fingers(curlFlex, 8)]
            s.splay = [j(0, 3), j(2, 2), j(4, 3), j(8, 3)]
            s.thumbAbduction = j(10, 6)
            s.thumbOpposition = j(60, 10)
            s.thumbFlex = [j(50, 10), j(40, 10)]
            s.yaw = j(45, 30)
        case .ear:
            s.flex = (0..<4).map { _ in fingers([25, 32, 18], 7) }
            s.splay = [j(-4, 3), j(0, 2), j(4, 3), j(8, 3)]
            s.thumbAbduction = j(30, 8)
            s.thumbOpposition = j(25, 8)
            s.thumbFlex = [j(15, 6), j(12, 6)]
            s.yaw = j(0, 25)
            s.roll = j(0, 20)
        case .pinch, .ok:
            s.flex = [fingers([40, 50, 30], 6),
                      kind == .ok ? fingers([3, 3, 2], 4) : fingers([50, 60, 40], 8),
                      kind == .ok ? fingers([4, 4, 2], 4) : fingers([60, 80, 50], 8),
                      kind == .ok ? fingers([5, 5, 3], 4) : fingers([60, 80, 50], 8)]
            s.splay = [j(-6, 3), j(0, 2), j(5, 3), j(10, 3)]
            s.thumbFlex = [j(20, 5), j(15, 5)]
            s.roll = j(0, 25)
        case .relaxed:
            s.flex = (0..<4).map { _ in [g.uniform(5, 50), g.uniform(10, 60), g.uniform(5, 40)] }
            s.splay = [j(-8, 6), j(0, 4), j(6, 5), j(12, 6)]
            s.thumbAbduction = j(30, 20)
            s.thumbOpposition = j(25, 20)
            s.thumbFlex = [j(20, 15), j(20, 15)]
            s.yaw = g.uniform(-160, 160)
            s.roll = j(0, 50)
        case .typing:
            s.flex = (0..<4).map { _ in [g.uniform(20, 45), g.uniform(30, 60), g.uniform(10, 30)] }
            s.splay = [j(-8, 4), j(0, 3), j(6, 4), j(12, 4)]
            s.pitch = j(-70, 12)
            s.yaw = j(180, 25)
            s.roll = j(0, 25)
        case .restingOpen:
            s.flex = (0..<4).map { _ in fingers([5, 5, 3], 5) }
            s.pitch = j(-75, 10)
            s.yaw = j(180, 20)
        case .twoLoose:
            s.flex = [fingers([28, 25, 15], 10), fingers([28, 25, 15], 10), fingers(curlFlex, 10), fingers(curlFlex, 10)]
            s.splay = [j(-6, 5), j(4, 5), j(4, 3), j(8, 3)]
            s.thumbAbduction = j(20, 10)
            s.thumbOpposition = j(50, 10)
            s.thumbFlex = [j(40, 10), j(30, 10)]
        case .scratch:
            s.flex = [fingers([35, 55, 35], 10), fingers(curlFlex, 10), fingers(curlFlex, 10), fingers(curlFlex, 10)]
            s.thumbOpposition = j(50, 10)
            s.thumbFlex = [j(40, 10), j(30, 10)]
            s.yaw = j(40, 30)
        case .phone:
            s.flex = (0..<4).map { _ in fingers([45, 60, 40], 10) }
            s.thumbAbduction = j(60, 10)
            s.thumbOpposition = j(40, 10)
            s.yaw = j(70, 25)
        case .claw:
            s.flex = (0..<4).map { _ in fingers([10, 70, 50], 10) }
            s.splay = [j(-12, 5), j(0, 3), j(10, 5), j(20, 6)]
        }
        if kind == .pinch || kind == .ok { s.fitPinch() }
        return s
    }

    /// Opposes the thumb so its tip lands on the index fingertip.
    mutating func fitPinch() {
        let p = Person(scale: [1, 1, 1, 1, 1], noise: 0, flexBias: 0)
        var best = (Float.greatestFiniteMagnitude, thumbAbduction, thumbOpposition)
        var a: Float = 0
        while a <= 90 {
            var b: Float = 0
            while b <= 90 {
                var trial = self
                trial.thumbAbduction = a
                trial.thumbOpposition = b
                let pts = Synth.joints(trial, person: p)
                let d = V3(x: pts[4].x - pts[8].x, y: pts[4].y - pts[8].y, z: pts[4].z - pts[8].z).length
                if d < best.0 { best = (d, a, b) }
                b += 5
            }
            a += 5
        }
        thumbAbduction = best.1
        thumbOpposition = best.2
    }
}
