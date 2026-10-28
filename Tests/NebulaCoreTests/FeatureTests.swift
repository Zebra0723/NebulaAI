import XCTest
@testable import NebulaCore
@testable import NebulaSim

final class FeatureTests: XCTestCase {
    private func features(_ h: Hand, face: Bool = false) -> FeatureVector {
        var f = FeatureVector()
        FeatureExtractor.extract(h, frame: TestKit.frame(0, [h], face: face), into: &f)
        return f
    }

    private let shapeFeatures: [Feature] = Feature.allCases.filter {
        $0.rawValue <= Feature.indexDirY.rawValue || $0 == .openness
    }

    func testShapeFeaturesDontCareAboutDistanceOrPosition() {
        let near = features(TestKit.hand(.peace, at: (0.6, 0.5), size: 0.24))
        let far = features(TestKit.hand(.peace, at: (0.9, 0.35), size: 0.09))
        for f in shapeFeatures {
            // Perspective foreshortens a near hand's curled fingers a little, as a real lens does.
            let tolerance: Float = f.rawValue <= Feature.curlLittle.rawValue ? 0.06 : 0.02
            XCTAssertEqual(near[f.rawValue], far[f.rawValue], accuracy: tolerance, "\(f.name)")
        }
    }

    func testLeftHandsAreMirroredIntoRightHandSpace() {
        let right = features(TestKit.hand(.thumbsUp, left: false))
        let left = features(TestKit.hand(.thumbsUp, left: true))
        for f in shapeFeatures {
            XCTAssertEqual(right[f.rawValue], left[f.rawValue], accuracy: 0.02, "\(f.name)")
        }
    }

    func testPalmFacingTheCameraIsPositiveAndTheBackIsNegative() {
        var g = SplitMix(seed: 3)
        var shape = HandShape.make(.flat, &g)
        shape.yaw = 0
        let front = Synth.render(shape, center: (0.6, 0.5), size: 0.15, left: false, person: TestKit.steady, aspect: TestKit.aspect, g: &g)
        shape.yaw = 180
        let back = Synth.render(shape, center: (0.6, 0.5), size: 0.15, left: false, person: TestKit.steady, aspect: TestKit.aspect, g: &g)
        XCTAssertGreaterThan(features(front)[Feature.palmFacing.rawValue], 0.4)
        XCTAssertLessThan(features(back)[Feature.palmFacing.rawValue], -0.4)
        // The same holds for a left hand.
        shape.yaw = 0
        let leftFront = Synth.render(shape, center: (0.6, 0.5), size: 0.15, left: true, person: TestKit.steady, aspect: TestKit.aspect, g: &g)
        XCTAssertGreaterThan(features(leftFront)[Feature.palmFacing.rawValue], 0.4)
    }

    func testReachSeparatesExtendedFromCurledFingers() {
        let flat = features(TestKit.hand(.flat))
        let fist = features(TestKit.hand(.fist))
        for f in [Feature.reachIndex, .reachMiddle, .reachRing, .reachLittle] {
            XCTAssertGreaterThan(flat[f.rawValue], 0.85, f.name)
            XCTAssertLessThan(fist[f.rawValue], 0.3, f.name)
        }
    }

    func testThumbDirectionTellsUpFromDown() {
        XCTAssertGreaterThan(features(TestKit.hand(.thumbsUp))[Feature.thumbDirY.rawValue], 0.7)
        XCTAssertLessThan(features(TestKit.hand(.thumbsDown))[Feature.thumbDirY.rawValue], -0.7)
    }

    func testSpreadTellsAVFromTwoFingersTogether() {
        XCTAssertGreaterThan(features(TestKit.hand(.peace))[Feature.spreadIndexMiddle.rawValue], 0.4)
        XCTAssertLessThan(features(TestKit.hand(.scroll))[Feature.spreadIndexMiddle.rawValue], 0.12)
    }

    func testFaceFeaturesNeedAFace() {
        let f = features(TestKit.hand(.flat), face: false)
        XCTAssertEqual(f[Feature.facePresent.rawValue], 0)
        XCTAssertEqual(f[Feature.lipsDistance.rawValue], 3)
        let withFace = features(TestKit.hand(.flat), face: true)
        XCTAssertEqual(withFace[Feature.facePresent.rawValue], 1)
        XCTAssertLessThan(withFace[Feature.lipsDistance.rawValue], 3)
    }

    func testQualityRejectsEdgesAndFarOrNearHands() {
        let q = FeatureExtractor.Quality()
        XCTAssertEqual(FeatureExtractor.check(TestKit.hand(.flat), aspect: TestKit.aspect, quality: q), .none)
        XCTAssertEqual(FeatureExtractor.check(TestKit.hand(.flat, at: (0.02, 0.5)), aspect: TestKit.aspect, quality: q), .touchingEdge)
        XCTAssertEqual(FeatureExtractor.check(TestKit.hand(.flat, size: 0.03), aspect: TestKit.aspect, quality: q), .tooFar)
        var low = TestKit.hand(.flat)
        low.confidence[Joint.indexMCP.rawValue] = 0.05
        XCTAssertEqual(FeatureExtractor.check(low, aspect: TestKit.aspect, quality: q), .lowConfidence)
    }

    func testFastMathIsCloseToLibm() {
        for i in -100...100 {
            let x = Float(i) / 100
            XCTAssertEqual(acosApprox(x), acos(x), accuracy: 2e-4)
        }
        for i in 0..<64 {
            let a = Float(i) / 64 * 2 * .pi - .pi
            XCTAssertEqual(atan2Approx(sin(a), cos(a)), atan2(sin(a), cos(a)), accuracy: 2e-3)
        }
    }
}

final class RuleTests: XCTestCase {
    private func score(_ pose: Pose, _ h: Hand, face: Bool = true) -> Float {
        var f = FeatureVector()
        FeatureExtractor.extract(h, frame: TestKit.frame(0, [h], face: face), into: &f)
        return CompiledRules(BuiltinRules.all).score(pose.rawValue, f)
    }

    func testEachPoseMatchesItsOwnRule() {
        let cases: [(ShapeKind, Pose)] = [(.flat, .flat), (.open, .open), (.thumbsUp, .thumbsUp), (.thumbsDown, .thumbsDown),
                                          (.peace, .peace), (.scroll, .scroll), (.pinch, .pinch)]
        for (kind, pose) in cases {
            for seed in 1...5 {
                XCTAssertGreaterThanOrEqual(score(pose, TestKit.hand(kind, seed: UInt64(seed))), 0.75, "\(kind) seed \(seed)")
            }
        }
    }

    func testRiskyPairsAreSeparatedByJudgeA() {
        for seed in 1...5 {
            let s = UInt64(seed)
            // A peace sign may also satisfy the scroll rule (fingers pointing at the screen look
            // like a narrow V); Judge B tells them apart, see RecognizerTests. A fist never does.
            XCTAssertLessThan(score(.scroll, TestKit.hand(.fist, seed: s)), 0.1, "a fist is not scroll")
            XCTAssertLessThan(score(.scroll, TestKit.hand(.fistNoThumb, seed: s)), 0.1)
            XCTAssertLessThan(score(.peace, TestKit.hand(.scroll, seed: s)), 0.3, "scroll is not peace")
            XCTAssertLessThan(score(.thumbsDown, TestKit.hand(.thumbsUp, seed: s)), 0.3)
            XCTAssertLessThan(score(.thumbsUp, TestKit.hand(.thumbsDown, seed: s)), 0.3)
            XCTAssertLessThan(score(.flat, TestKit.hand(.fist, seed: s)), 0.1)
            XCTAssertLessThan(score(.pinch, TestKit.hand(.ok, seed: s)), 0.5, "an OK sign is not a knob grip")
        }
    }

    func testFingerToLipsNeedsTheLips() {
        // Index up, but nowhere near the face.
        XCTAssertLessThan(score(.lips, TestKit.hand(.pointing, at: (0.4, 0.3))), 0.1)
        XCTAssertEqual(score(.lips, TestKit.hand(.pointing), face: false), 0)
    }

    func testCustomRulesValidate() {
        XCTAssertNil(PoseRule(name: "ok", conditions: [Condition(.reachIndex, min: 0.8, band: 0.1)]).validate())
        XCTAssertNotNil(PoseRule(name: "x", conditions: []).validate())
        XCTAssertNotNil(PoseRule(name: "x", conditions: [Condition(feature: "noSuchThing", min: 0, max: 1, band: 0.1)]).validate())
        XCTAssertNotNil(PoseRule(name: "x", conditions: [Condition(.speed, max: 1, band: 0.1)]).validate(), "motion isn't shape")
        XCTAssertNotNil(PoseRule(name: "x", conditions: [Condition(.reachIndex, min: 0.9, max: 0.1, band: 0.1)]).validate())
    }
}

final class RecordingTests: XCTestCase {
    func testRoundTripKeepsJointsToAFractionOfAPixel() throws {
        var g = SplitMix(seed: 5)
        var b = SessionBuilder(seed: 5, options: SynthOptions(), left: true, distanceCm: 60)
        b.perform("peace")
        let rec = b.finish(SessionInfo(id: "t", kind: .gestures, role: .test))
        let back = try Recording.decode(try rec.encoded())
        XCTAssertEqual(back.info, rec.info)
        XCTAssertEqual(back.labels, rec.labels)
        XCTAssertEqual(back.frames.count, rec.frames.count)
        for (a, b) in zip(rec.frames, back.frames) {
            XCTAssertEqual(a.time, b.time, accuracy: 1e-5)
            XCTAssertEqual(a.handCount, b.handCount)
            XCTAssertEqual(a.hasFace, b.hasFace)
            if a.handCount > 0 {
                XCTAssertEqual(a.hand0.chirality, b.hand0.chirality)
                for j in 0..<21 {
                    XCTAssertEqual(a.hand0.x[j], b.hand0.x[j], accuracy: 1e-4)
                    XCTAssertEqual(a.hand0.y[j], b.hand0.y[j], accuracy: 1e-4)
                }
            }
        }
        _ = g.next()
    }

    func testSessionsAreSplitWholeNeverByFrame() {
        let recs = (0..<8).map { i in Recording(info: SessionInfo(id: "s\(i)", kind: i % 2 == 0 ? .gestures : .nothing, startedAt: Double(i))) }
        let (train, validation, test) = Trainer.split(recs)
        XCTAssertEqual(train.count + validation.count + test.count, 8)
        XCTAssertFalse(test.isEmpty)
        XCTAssertFalse(validation.isEmpty)
        let ids = (train + validation + test).map(\.info.id)
        XCTAssertEqual(Set(ids).count, 8, "each session in exactly one split")
        // Both kinds of footage reach the test split.
        XCTAssertEqual(Set(test.map(\.info.kind)), [.gestures, .nothing])
    }
}
