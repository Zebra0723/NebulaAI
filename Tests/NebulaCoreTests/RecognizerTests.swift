import XCTest
@testable import NebulaCore
@testable import NebulaSim

/// The decision rules, frame by frame: holds, agreement, release, cooldown,
/// movements that must complete, and continuous controls.
final class RecognizerTests: XCTestCase {
    let thumbsUp = Gesture.thumbsUp.index

    func testAHeldPoseCuesOnTheFirstFrameAndFiresAfterTheHold() {
        let r = Recognizer(model: TestKit.model)
        let hold = TestKit.model.tuning(for: .thumbsUp).hold
        let events = TestKit.run(r, from: 10, seconds: 1) { _ in [TestKit.hand(.thumbsUp)] }
        guard case .cue(thumbsUp)? = events.first?.1 else { return XCTFail("expected a cue first, got \(events)") }
        XCTAssertEqual(events.first!.0, 10, accuracy: 1e-9, "the cue comes on the very first frame")
        let fires = TestKit.fires(events)
        XCTAssertEqual(fires.count, 1, "held for a second, fires once")
        XCTAssertEqual(fires[0].1, thumbsUp)
        XCTAssertEqual(fires[0].0 - 10, hold, accuracy: 1.0 / 60 + 1e-6, "fires as the hold completes")
    }

    func testItFiresAgainOnlyAfterTheHandLeavesThePose() {
        let r = Recognizer(model: TestKit.model)
        var events = TestKit.run(r, from: 0, seconds: 3) { _ in [TestKit.hand(.thumbsUp)] }
        XCTAssertEqual(TestKit.fires(events).count, 1, "three seconds of one pose is one fire")
        events = TestKit.run(r, from: 3, seconds: 0.3) { _ in [TestKit.hand(.fist)] }
        events += TestKit.run(r, from: 3.3, seconds: 1) { _ in [TestKit.hand(.thumbsUp)] }
        XCTAssertEqual(TestKit.fires(events).count, 1, "leaving and coming back fires again")
    }

    func testCooldownHoldsEvenAfterRelease() {
        let r = Recognizer(model: TestKit.model)
        _ = TestKit.run(r, from: 0, seconds: 0.4) { _ in [TestKit.hand(.thumbsUp)] }
        // Out of the pose for a moment, then straight back, inside the cooldown.
        var events = TestKit.run(r, from: 0.4, seconds: 0.1) { _ in [TestKit.hand(.fist)] }
        events += TestKit.run(r, from: 0.5, seconds: 0.25) { _ in [TestKit.hand(.thumbsUp)] }
        XCTAssertTrue(TestKit.fires(events).isEmpty)
    }

    func testABriefFlickerDoesNotFire() {
        let r = Recognizer(model: TestKit.model)
        // Shorter than the hold.
        var events = TestKit.run(r, from: 0, seconds: 0.08) { _ in [TestKit.hand(.thumbsUp)] }
        events += TestKit.run(r, from: 0.08, seconds: 1) { _ in [TestKit.hand(.relaxed)] }
        XCTAssertTrue(TestKit.fires(events).isEmpty)
        XCTAssertTrue(events.contains { if case .cancelled = $0.1 { return true } else { return false } })
    }

    func testAMovingHandNeverHolds() {
        let r = Recognizer(model: TestKit.model)
        // Talking with a thumbs-up-shaped hand that never stops moving.
        let events = TestKit.run(r, from: 0, seconds: 2) { t in
            [TestKit.hand(.thumbsUp, at: (0.67 + 0.12 * Float(sin(t * 9)), 0.5 + 0.1 * Float(cos(t * 7))))]
        }
        XCTAssertTrue(TestKit.fires(events).isEmpty)
    }

    func testAHandTouchingTheEdgeNeverFires() {
        let r = Recognizer(model: TestKit.model)
        let events = TestKit.run(r, from: 0, seconds: 1.5) { _ in [TestKit.hand(.thumbsUp, at: (0.03, 0.5))] }
        XCTAssertTrue(TestKit.fires(events).isEmpty)
        XCTAssertEqual(r.status.rejection, .touchingEdge)
    }

    func testTooFarOrLowConfidenceNeverFires() {
        let r = Recognizer(model: TestKit.model)
        var events = TestKit.run(r, from: 0, seconds: 1) { _ in [TestKit.hand(.thumbsUp, size: 0.03)] }
        var low = TestKit.hand(.thumbsUp)
        low.confidence[Joint.wrist.rawValue] = 0.05
        events += TestKit.run(r, from: 1, seconds: 1) { _ in [low] }
        XCTAssertTrue(TestKit.fires(events).isEmpty)
    }

    func testDisabledGesturesDontFire() {
        let r = Recognizer(model: TestKit.model)
        r.setEnabled(thumbsUp, false)
        let events = TestKit.run(r, from: 0, seconds: 1) { _ in [TestKit.hand(.thumbsUp)] }
        XCTAssertTrue(TestKit.fires(events).isEmpty)
    }

    func testWithTwoHandsItFollowsTheOneMakingAPose() {
        let r = Recognizer(model: TestKit.model)
        let events = TestKit.run(r, from: 0, seconds: 1) { _ in
            // A bigger (nearer) relaxed hand, and a smaller one giving a thumbs up.
            [TestKit.hand(.relaxed, at: (0.4, 0.4), size: 0.2), TestKit.hand(.thumbsUp, at: (0.95, 0.5), size: 0.13, left: true)]
        }
        print("two hands:", events, r.status)
        XCTAssertEqual(TestKit.fires(events).map(\.1), [thumbsUp])
    }

    func testThumbsUpAndDownAreNotConfused() {
        let r = Recognizer(model: TestKit.model)
        var events = TestKit.run(r, from: 0, seconds: 1) { _ in [TestKit.hand(.thumbsDown)] }
        events += TestKit.run(r, from: 1, seconds: 0.3) { _ in [] }
        events += TestKit.run(r, from: 1.3, seconds: 1) { _ in [TestKit.hand(.thumbsUp)] }
        XCTAssertEqual(TestKit.fires(events).map(\.1), [Gesture.thumbsDown.index, thumbsUp])
    }

    // MARK: Movements

    private func swipe(_ r: Recognizer, from t0: Double, direction: Float, distance: Float = 3.5, duration: Double = 0.3,
                       kind: ShapeKind = .flat) -> [(Double, RecognizerEvent)] {
        let size: Float = 0.14
        let x0 = 0.67 - direction * distance * size / 2
        var events = TestKit.run(r, from: t0, seconds: 0.05) { _ in [TestKit.hand(kind, at: (x0, 0.5), size: size)] }
        events += TestKit.run(r, from: t0 + 0.05, seconds: duration) { t in
            let u = Float(t / duration)
            let e = u * u * u * (10 - 15 * u + 6 * u * u)
            return [TestKit.hand(kind, at: (x0 + direction * distance * size * e, 0.5), size: size)]
        }
        events += TestKit.run(r, from: t0 + 0.05 + duration, seconds: 0.4) { _ in
            [TestKit.hand(kind, at: (x0 + direction * distance * size, 0.5), size: size)]
        }
        return events
    }

    func testASwipeFiresOnceWhenTheMovementCompletes() {
        let r = Recognizer(model: TestKit.model)
        let events = swipe(r, from: 0, direction: 1)
        let fires = TestKit.fires(events)
        XCTAssertEqual(fires.map(\.1), [Gesture.swipeRight.index])
        // Completion: after the stroke's peak and before the hand has fully stopped.
        XCTAssertGreaterThan(fires[0].0, 0.05 + 0.15)
        XCTAssertLessThan(fires[0].0, 0.05 + 0.3 + 0.05, "within a few frames of the hand stopping")
    }

    func testSwipeDirectionIsYourDirection() {
        let r = Recognizer(model: TestKit.model)
        XCTAssertEqual(TestKit.fires(swipe(r, from: 0, direction: -1)).map(\.1), [Gesture.swipeLeft.index])
    }

    func testHalfASwipeDoesNotFire() {
        let r = Recognizer(model: TestKit.model)
        XCTAssertTrue(TestKit.fires(swipe(r, from: 0, direction: 1, distance: 1.2)).isEmpty)
    }

    func testASwipeWithAFistDoesNotFire() {
        let r = Recognizer(model: TestKit.model)
        XCTAssertTrue(TestKit.fires(swipe(r, from: 0, direction: 1, kind: .fist)).isEmpty)
    }

    func testOpenPalmDoesNotFireAsASwipeEnds() {
        let r = Recognizer(model: TestKit.model)
        let fires = TestKit.fires(swipe(r, from: 0, direction: 1))
        XCTAssertFalse(fires.contains { $0.1 == Gesture.openPalm.index }, "the flat hand at the end of a swipe is not a pause")
    }

    func testAWaveFiresWaveAndNotSwipes() {
        let r = Recognizer(model: TestKit.model)
        let size: Float = 0.14
        var events = TestKit.run(r, from: 0, seconds: 0.1) { _ in [TestKit.hand(.open, size: size)] }
        events += TestKit.run(r, from: 0.1, seconds: 0.9) { t in
            [TestKit.hand(.open, at: (0.67 + 0.7 * size * Float(sin(2 * .pi * 2.5 * t)), 0.5), size: size)]
        }
        XCTAssertEqual(TestKit.fires(events).map(\.1), [Gesture.wave.index])
    }

    // MARK: Continuous

    func testScrollEngagesThenFollowsTheHandEveryFrame() {
        let r = Recognizer(model: TestKit.model)
        let size: Float = 0.15
        var events = TestKit.run(r, from: 0, seconds: 0.3) { _ in [TestKit.hand(.scroll, size: size)] }
        XCTAssertEqual(TestKit.fires(events).map(\.1), [Gesture.scroll.index])
        let moving = TestKit.run(r, from: 0.3, seconds: 0.5) { t in [TestKit.hand(.scroll, at: (0.67, 0.5 + Float(t) * 2 * size), size: size)] }
        let deltas = moving.compactMap { if case .scroll(let d) = $0.1 { return d } else { return nil } }
        XCTAssertGreaterThan(deltas.count, 25, "a scroll update nearly every frame (\(deltas.count) in 30)")
        XCTAssertGreaterThan(deltas.reduce(0, +), 0.6, "hand moved up about one palm; scroll followed")
        // Curling the fingers stops it.
        events = TestKit.run(r, from: 0.8, seconds: 0.3) { _ in [TestKit.hand(.fist, size: size)] }
        XCTAssertTrue(events.contains { $0.1 == .ended(Gesture.scroll.index) })
    }

    func testTheKnobTurnsVolumeUpClockwiseAndDownCounterClockwise() {
        for (turn, sign) in [(Float(-40), 1), (Float(40), -1)] {
            let r = Recognizer(model: TestKit.model)
            _ = TestKit.run(r, from: 0, seconds: 0.3) { _ in [TestKit.hand(.pinch, roll: 0)] }
            let events = TestKit.run(r, from: 0.3, seconds: 0.6) { t in [TestKit.hand(.pinch, roll: turn * Float(min(t / 0.5, 1)))] }
            let steps = events.compactMap { if case .volume(let s) = $0.1 { return s } else { return nil } }
            XCTAssertEqual(steps.count, 3, "40° is three 12° steps")
            XCTAssertTrue(steps.allSatisfy { $0 == sign })
        }
    }

    // MARK: Trial mode

    func testTrialModeLetsASureJudgeAActWhenJudgeBKnowsNothing() {
        let untrained = Bootstrap.emptyModel() // Judge B says "nothing" to everything
        let strict = Recognizer(model: untrained)
        XCTAssertTrue(TestKit.fires(TestKit.run(strict, from: 0, seconds: 1) { _ in [TestKit.hand(.thumbsUp)] }).isEmpty,
                      "strict: both judges must agree")
        let trial = Recognizer(model: untrained, lenient: true)
        XCTAssertEqual(TestKit.fires(TestKit.run(trial, from: 0, seconds: 1) { _ in [TestKit.hand(.thumbsUp)] }).map(\.1),
                       [Gesture.thumbsUp.index])
    }

    func testTrialModeStillIgnoresOrdinaryHands() {
        let trial = Recognizer(model: Bootstrap.emptyModel(), lenient: true)
        var events: [(Double, RecognizerEvent)] = []
        for (i, kind) in [ShapeKind.relaxed, .typing, .fist, .claw, .phone, .restingOpen].enumerated() {
            events += TestKit.run(trial, from: Double(i), seconds: 1) { _ in [TestKit.hand(kind, seed: UInt64(i + 3))] }
        }
        XCTAssertTrue(TestKit.fires(events).isEmpty, "\(TestKit.fires(events))")
    }

    func testScrollStartsEvenWhileTheHandDriftsSlowly() {
        let r = Recognizer(model: TestKit.model)
        let size: Float = 0.15
        // About 3 palm lengths a second: too fast for a held gesture, fine for scroll.
        let events = TestKit.run(r, from: 0, seconds: 0.5) { t in [TestKit.hand(.scroll, at: (0.67, 0.4 + Float(t) * 3 * size), size: size)] }
        XCTAssertEqual(TestKit.fires(events).map(\.1), [Gesture.scroll.index])
    }

    func testPeaceAndScrollAreToldApartWhenJudgeAAcceptsBoth() {
        let r = Recognizer(model: TestKit.model)
        var events = TestKit.run(r, from: 0, seconds: 0.6) { _ in [TestKit.hand(.peace)] }
        events += TestKit.run(r, from: 0.6, seconds: 0.4) { _ in [] }
        events += TestKit.run(r, from: 1.0, seconds: 0.6) { _ in [TestKit.hand(.scroll)] }
        XCTAssertEqual(TestKit.fires(events).map(\.1), [Gesture.peace.index, Gesture.scroll.index])
    }

    func testTrialModeStillWorksWithTheHandAtFaceHeight() {
        // Almost any hand beside the face also passes the ear rule; that must not block the others.
        let faceHeight: (Float, Float) = (0.67, 0.62)
        for (i, (kind, gesture)) in [(ShapeKind.thumbsUp, Gesture.thumbsUp), (.thumbsDown, .thumbsDown),
                                     (.scroll, .scroll), (.flat, .openPalm)].enumerated() {
            let trial = Recognizer(model: Bootstrap.emptyModel(), lenient: true)
            let events = TestKit.run(trial, from: 0, seconds: 1) { _ in [TestKit.hand(kind, at: faceHeight, seed: UInt64(i + 1))] }
            XCTAssertEqual(TestKit.fires(events).map(\.1), [gesture.index], "\(kind)")
        }
    }

    func testTrialModeIgnoresOrdinaryHandsByTheFace() {
        let trial = Recognizer(model: Bootstrap.emptyModel(), lenient: true)
        var events: [(Double, RecognizerEvent)] = []
        for (i, kind) in [ShapeKind.relaxed, .scratch, .fist, .claw, .phone].enumerated() {
            events += TestKit.run(trial, from: Double(i), seconds: 1) { _ in [TestKit.hand(kind, at: (0.67, 0.62), seed: UInt64(i + 3))] }
        }
        XCTAssertTrue(TestKit.fires(events).isEmpty, "\(TestKit.fires(events))")
    }
}
