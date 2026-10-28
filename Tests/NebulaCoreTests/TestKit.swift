import Foundation
@testable import NebulaCore
@testable import NebulaSim

/// Builders for clean, controllable test input: synthetic hands with no jitter,
/// and a small model trained on them, so recognizer logic can be tested exactly.
enum TestKit {
    static let aspect: Float = 4.0 / 3.0
    static var steady: Person { Person(scale: [1, 1, 1, 1, 1], noise: 0, flexBias: 0) }

    static func hand(_ kind: ShapeKind, at center: (Float, Float) = (0.67, 0.5), size: Float = 0.16,
                     left: Bool = false, seed: UInt64 = 1, roll: Float? = nil) -> Hand {
        var g = SplitMix(seed: seed)
        var shape = HandShape.make(kind, &g)
        if let roll { shape.roll = roll }
        return Synth.render(shape, center: center, size: size, left: left, person: steady, aspect: aspect, g: &g)
    }

    static func frame(_ t: Double, _ hands: [Hand], face: Bool = true) -> Frame {
        var f = Frame(time: t, aspect: aspect, handCount: hands.count)
        if hands.count > 0 { f.hand0 = hands[0] }
        if hands.count > 1 { f.hand1 = hands[1] }
        if face { f.setFace(faceBox) }
        return f
    }

    static let faceCenter: (Float, Float) = (0.67, 0.68)
    static let faceWidth: Float = 0.22
    static var faceBox: FaceBox {
        FaceBox(x: 1 - (faceCenter.0 + faceWidth / 2) / aspect, y: faceCenter.1 - faceWidth * 0.625,
                width: faceWidth / aspect, height: faceWidth * 1.25)
    }

    /// A model whose Judge B knows clean examples of every pose, and "nothing" from
    /// ordinary activity shapes.
    static let model: NebulaModel = {
        var examples: [(FeatureVector, Int, Float)] = []
        var g = SplitMix(seed: 99)
        let classes: [(ShapeKind, Pose)] = [(.flat, .flat), (.open, .open), (.thumbsUp, .thumbsUp), (.thumbsDown, .thumbsDown),
                                            (.peace, .peace), (.scroll, .scroll), (.pinch, .pinch)]
        for (kind, pose) in classes {
            for i in 0..<60 {
                let h = hand(kind, at: (g.uniform(0.4, 0.9), g.uniform(0.3, 0.6)), size: g.uniform(0.1, 0.22), left: i % 2 == 0, seed: UInt64(i + 7 * pose.rawValue))
                var f = FeatureVector()
                FeatureExtractor.extract(h, frame: frame(0, [h]), into: &f)
                examples.append((f, pose.rawValue, 1))
            }
        }
        for i in 0..<300 {
            let kind: ShapeKind = [.relaxed, .typing, .fist, .claw, .phone, .twoLoose, .restingOpen][i % 7]
            let h = hand(kind, at: (g.uniform(0.4, 0.9), g.uniform(0.2, 0.6)), size: g.uniform(0.1, 0.22), left: i % 2 == 0, seed: UInt64(1000 + i))
            var f = FeatureVector()
            FeatureExtractor.extract(h, frame: frame(0, [h]), into: &f)
            examples.append((f, 0, 1))
        }
        var m = Bootstrap.emptyModel()
        m.source = "test"
        m.classifier = ClassifierModel.train(examples: examples, classCount: Pose.builtinCount, k: 5)
        return m
    }()

    /// Runs `seconds` of frames at `fps` through a recognizer, collecting (time, event).
    static func run(_ r: Recognizer, from t0: Double, seconds: Double, fps: Double = 60,
                    _ makeHands: (Double) -> [Hand]) -> [(Double, RecognizerEvent)] {
        var out: [(Double, RecognizerEvent)] = []
        var t = t0
        while t < t0 + seconds - 1e-9 {
            for e in r.run(frame(t, makeHands(t - t0))) { out.append((t, e)) }
            t += 1 / fps
        }
        return out
    }

    static func fires(_ events: [(Double, RecognizerEvent)]) -> [(Double, Int)] {
        events.compactMap { if case .fired(let g) = $0.1 { return ($0.0, g) } else { return nil } }
    }
}
