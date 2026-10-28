// Features → gesture events. The decision: both judges must agree, held
// poses must be held, movements must be complete, and nothing fires twice
// without the hand leaving the pose in between.
//
// Everything is allocated in init. `process` touches only preallocated
// memory and value types, so a frame costs microseconds and never waits on
// the allocator.

/// What happened this frame. Gesture ids: built-in gestures use `Gesture.index`;
/// custom gestures use `Recognizer.customBase + i`.
public enum RecognizerEvent: Sendable, Equatable {
    /// The first frame of a hold: the HUD starts filling its ring now, so it feels instant.
    case cue(Int)
    /// A hold that didn't make it.
    case cancelled(Int)
    /// A gesture fired (for scroll and the knob: engaged).
    case fired(Int)
    /// Scroll engaged: the hand's predicted movement this frame, palm lengths, up positive.
    case scroll(Float)
    /// Volume knob engaged: +1 one step up (clockwise), -1 one step down.
    case volume(Int)
    /// A continuous control let go.
    case ended(Int)
}

/// What the recognizer sees right now, for the Practice screen and the HUD.
public struct RecognizerStatus: Sendable, Equatable {
    public var handVisible = false
    public var rejection = FeatureExtractor.Rejection.none
    /// Which hand slot of the frame is being followed, or -1.
    public var hand = -1
    public var judgeA = 0
    public var judgeAScore: Float = 0
    public var judgeB = Classification()
    /// The pose both judges agree on this frame, or 0.
    public var agreed = 0
    public var holdGesture = -1
    public var holdProgress: Float = 0
    public var engaged = -1
    public var speed: Float = 0
    public init() {}
}

/// The seeing stage's output for one frame: everything the deciding stage needs.
public struct Observation: Sendable {
    public var valid = false
    public var rejection = FeatureExtractor.Rejection.none
    public var chosen = -1
    public var jumped = false
    /// The hand touches the frame edge: good enough to follow its movement, never to judge its pose.
    public var partial = false
    public var features = FeatureVector()
    /// Judge A's score per pose (built-in poses and up to six custom ones).
    public var a = SIMD16<Float>()
    public var b = Classification()
    public var smoothX: Float = 0
    public var smoothY: Float = 0
    public var predictedY: Float = 0
    public var size: Float = 0
    public init() {}
}

/// A custom gesture: a held pose with its own rule and its own classifier label.
public struct CustomGesture: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var rule: PoseRule
    /// The classifier label its recorded examples were added under.
    public var label: Int
    public var tuning: GestureTuning
    public var enabled: Bool

    public init(id: String, name: String, rule: PoseRule, label: Int, tuning: GestureTuning = GestureTuning(), enabled: Bool = true) {
        self.id = id
        self.name = name
        self.rule = rule
        self.label = label
        self.tuning = tuning
        self.enabled = enabled
    }
}

public final class Recognizer {
    /// Poses whose rules say little about the hand's shape: Judge A alone can't name them.
    @inline(__always) static func isVague(_ pose: Int) -> Bool {
        pose == Pose.pinch.rawValue || pose == Pose.ear.rawValue
    }

    public static let customBase = 100
    public static let maxEvents = 8

    public let model: NebulaModel
    public let customs: [CustomGesture]
    private let rules: CompiledRules
    private let classifier: Classifier
    private let poseCount: Int

    // Held and continuous gestures: one per pose.
    private struct Held {
        var id: Int
        var pose: Int
        var tuning: GestureTuning
        var continuous: Bool
        var settleAfterStrokes: Bool
    }
    private let held: UnsafeMutablePointer<Held>
    private let heldCount: Int
    private let poseToHeld: UnsafeMutablePointer<Int>
    private let cooldownUntil: UnsafeMutablePointer<Double>
    private let needsRelease: UnsafeMutablePointer<Bool>
    private let releaseCount: UnsafeMutablePointer<Int>
    private let enabledFlags: UnsafeMutablePointer<Bool> // by gesture id slot
    private let aScores: UnsafeMutablePointer<Float>

    private let swipeTuning: GestureTuning
    private let waveTuning: GestureTuning
    private let m: MotionTuning

    // Output
    private let eventBuffer: UnsafeMutablePointer<RecognizerEvent>
    public private(set) var eventCount = 0
    public private(set) var status = RecognizerStatus()
    public private(set) var features = FeatureVector()

    // Tracking
    private var trackedX: Float = -1, trackedY: Float = -1
    private var lostFrames = 0      // seeing stage
    private var missingFrames = 0   // deciding stage
    private var lastTime: Double = -1
    private var fx: OneEuroFilter, fy: OneEuroFilter
    private var smoothedSize: Float = 0
    private var rollUnwrapped: Float = 0, lastRawRoll: Float = 0, hasRoll = false
    private var lastPredY: Float = 0

    // Hold
    private var holdIndex = -1
    private var holdStart: Double = 0
    private var holdTotal = 0, holdAgreed = 0, holdChange = 0, holdMoving = 0

    // Continuous
    private var engagedIndex = -1
    private var engagedMisses = 0
    private var knobAnchor: Float = 0

    // Strokes
    private var inStroke = false
    private var strokeDir: Float = 0
    private var strokeStartT: Double = 0, strokeStartX: Float = 0, strokeStartY: Float = 0
    private var strokeLastT: Double = 0, strokeLastX: Float = 0, strokeLastY: Float = 0
    private var strokePeak: Float = 0, strokeFrames = 0, strokePoseFrames = 0, strokeSizeSum: Float = 0
    private var anchorT: Double = 0, anchorX: Float = 0, anchorY: Float = 0
    private var lastStrokeEnd: Double = -10, lastStrokeDir: Float = 0
    private var waveCount = 0, waveLastDir: Float = 0, waveLastEnd: Double = -10
    private var swipeCooldownUntil: Double = 0, waveCooldownUntil: Double = 0

    /// Custom gestures share the pose table with the ten built-in poses, sixteen at most.
    public static let maxCustoms = 6

    /// Trial mode: Judge A may decide on its own when it's sure and Judge B has no opinion
    /// (an untrained or thinly trained B mostly says "nothing"), and B needs less certainty.
    /// More gestures get through; so do more mistakes. Off unless you choose trial mode.
    public let lenient: Bool

    public init(model: NebulaModel, customs: [CustomGesture] = [], lenient: Bool = false) {
        self.lenient = lenient
        self.model = model
        self.customs = Array(customs.prefix(Recognizer.maxCustoms))
        let customs = self.customs
        let builtinRules = model.poseRules()
        rules = CompiledRules(builtinRules + customs.map(\.rule))
        poseCount = builtinRules.count + customs.count
        classifier = Classifier(model.classifier)
        m = model.motion
        swipeTuning = model.tuning(for: .swipeRight)
        waveTuning = model.tuning(for: .wave)
        fx = OneEuroFilter(model.filter)
        fy = OneEuroFilter(model.filter)

        var list: [Held] = []
        for g in [Gesture.openPalm, .thumbsUp, .thumbsDown, .peace, .fingerToLips, .handToEar, .scroll, .volumeKnob] {
            list.append(Held(id: g.index, pose: g.pose.rawValue, tuning: model.tuning(for: g),
                             continuous: g.kind == .continuous, settleAfterStrokes: g == .openPalm))
        }
        for (i, c) in customs.enumerated() {
            list.append(Held(id: Recognizer.customBase + i, pose: Pose.builtinCount + i, tuning: c.tuning,
                             continuous: false, settleAfterStrokes: false))
        }
        heldCount = list.count
        held = .allocate(capacity: heldCount)
        held.initialize(from: list, count: heldCount)
        poseToHeld = .allocate(capacity: poseCount)
        poseToHeld.initialize(repeating: -1, count: poseCount)
        for (i, h) in list.enumerated() { poseToHeld[h.pose] = i }
        cooldownUntil = .allocate(capacity: heldCount)
        cooldownUntil.initialize(repeating: 0, count: heldCount)
        needsRelease = .allocate(capacity: heldCount)
        needsRelease.initialize(repeating: false, count: heldCount)
        releaseCount = .allocate(capacity: heldCount)
        releaseCount.initialize(repeating: 0, count: heldCount)
        enabledFlags = .allocate(capacity: Recognizer.customBase + customs.count)
        enabledFlags.initialize(repeating: true, count: Recognizer.customBase + customs.count)
        for (i, c) in customs.enumerated() { enabledFlags[Recognizer.customBase + i] = c.enabled }
        aScores = .allocate(capacity: poseCount)
        aScores.initialize(repeating: 0, count: poseCount)
        eventBuffer = .allocate(capacity: Recognizer.maxEvents)
        eventBuffer.initialize(repeating: .ended(-1), count: Recognizer.maxEvents)
    }

    deinit {
        held.deallocate()
        poseToHeld.deallocate()
        cooldownUntil.deallocate()
        needsRelease.deallocate()
        releaseCount.deallocate()
        enabledFlags.deallocate()
        aScores.deallocate()
        eventBuffer.deallocate()
    }

    // MARK: - Public

    /// Turns a gesture on or off. Call on the queue that calls `process`.
    public func setEnabled(_ id: Int, _ on: Bool) {
        guard id >= 0 && id < Recognizer.customBase + customs.count else { return }
        enabledFlags[id] = on
    }

    public func isEnabled(_ id: Int) -> Bool {
        id >= 0 && id < Recognizer.customBase + customs.count && enabledFlags[id]
    }

    /// The events from the last `process` call. Valid until the next call.
    @inline(__always) public func event(_ i: Int) -> RecognizerEvent { eventBuffer[i] }

    /// Judge A's score for a pose on the last processed frame.
    @inline(__always) public func judgeAScore(_ pose: Int) -> Float { pose < poseCount ? aScores[pose] : 0 }

    /// Judge B's share of the vote for a class on the last processed frame.
    @inline(__always) public func judgeBScore(_ label: Int) -> Float { classifier.score(label) }

    /// Forgets everything in flight: holds, strokes, engagements. Cooldowns survive.
    public func reset() {
        holdIndex = -1
        engagedIndex = -1
        inStroke = false
        waveCount = 0
        trackedX = -1
        lostFrames = 0
        lastTime = -1
        fx.reset()
        fy.reset()
        hasRoll = false
        smoothedSize = 0
        status = RecognizerStatus()
    }

    /// Convenience for tests and tools: processes a frame and copies its events out.
    public func run(_ frame: Frame) -> [RecognizerEvent] {
        process(frame)
        return (0..<eventCount).map { eventBuffer[$0] }
    }

    // MARK: - The per-frame path

    /// Runs one camera frame through both stages: seeing (hand, features, both judges)
    /// and deciding (holds, strokes, engagement).
    public func process(_ frame: Frame) {
        let o = observe(frame)
        decide(o, at: frame.time)
    }

    /// The deciding stage alone, from a frame already seen. Threshold tuning replays the
    /// same observations under different thresholds this way.
    public func replay(_ o: Observation, at t: Double) {
        if o.valid {
            features = o.features
            for p in 0..<min(poseCount, 16) { aScores[p] = o.a[p] }
        }
        decide(o, at: t)
    }

    /// The seeing stage: picks the hand, extracts features, smooths motion and asks both judges.
    public func observe(_ input: Frame) -> Observation {
        var frame = input
        frame.hand0.fillMissingJoints()
        frame.hand1.fillMissingJoints()
        var o = Observation()
        let t = frame.time
        lastTime = t

        // Pick the hand: the one being followed, else the nearer (or the one making a pose).
        let busy = holdIndex >= 0 || engagedIndex >= 0 || inStroke
        var chosen = -1
        var partialChoice = -1
        var rejection = FeatureExtractor.Rejection.none
        var bestSize: Float = -1
        for i in 0..<min(frame.handCount, 2) {
            let hand = frame.hand(i)
            let r = FeatureExtractor.check(hand, aspect: frame.aspect, quality: model.quality)
            let c = FeatureExtractor.palmCenter(hand, aspect: frame.aspect)
            let near = trackedX >= 0 && hypot2(c.x - trackedX, c.y - trackedY) < 0.2
            if busy && trackedX >= 0 && !near { continue }
            if r != .none {
                if near || chosen < 0 { rejection = r }
                if r == .touchingEdge && (near || trackedX < 0) { partialChoice = i }
                continue
            }
            let size = FeatureExtractor.palmSize(hand, aspect: frame.aspect)
            let score = size + (near ? 10 : 0)
            if score > bestSize {
                bestSize = score
                chosen = i
            }
        }
        if chosen >= 0 && frame.handCount == 2 && !busy {
            chosen = choosePosingHand(frame, fallback: chosen)
        }
        if chosen < 0 && partialChoice >= 0 {
            chosen = partialChoice
            o.partial = true
            o.rejection = rejection
        }
        guard chosen >= 0 else {
            o.rejection = rejection
            lostTracking()
            return o
        }
        lostFrames = 0
        let hand = frame.hand(chosen)
        FeatureExtractor.extract(hand, frame: frame, flipChirality: model.flipChirality, into: &features)

        // Motion from the smoothed palm path.
        let size = features[Feature.handSize.rawValue]
        smoothedSize = smoothedSize == 0 ? size : smoothedSize + 0.3 * (size - smoothedSize)
        let cx = features[Feature.posX.rawValue], cy = features[Feature.posY.rawValue]
        if trackedX >= 0 && hypot2(cx - trackedX, cy - trackedY) > 0.2 {
            // A different hand, or a glitch: don't let the filters see a teleport as speed.
            fx.reset()
            fy.reset()
            o.jumped = true
        }
        o.smoothX = fx.filter(cx, at: t, scale: smoothedSize)
        o.smoothY = fy.filter(cy, at: t, scale: smoothedSize)
        trackedX = cx
        trackedY = cy
        let inv = 1 / max(smoothedSize, 1e-3)
        let vx = fx.derivative * inv, vy = fy.derivative * inv
        features[Feature.velocityX.rawValue] = vx
        features[Feature.velocityY.rawValue] = vy
        features[Feature.speed.rawValue] = hypot2(vx, vy)
        let rawRoll = features[Feature.roll.rawValue]
        if hasRoll {
            rollUnwrapped += wrapAngle(rawRoll - lastRawRoll)
        } else {
            rollUnwrapped = rawRoll
            hasRoll = true
        }
        lastRawRoll = rawRoll
        features[Feature.roll.rawValue] = rollUnwrapped
        o.predictedY = fy.predicted(m.predictionHorizon)
        o.size = smoothedSize

        o.valid = true
        o.chosen = chosen
        o.features = features
        if o.partial {
            for p in 0..<poseCount { aScores[p] = 0 }
            return o
        }

        // Both judges.
        for p in 1..<poseCount {
            let sc = rules.score(p, features)
            aScores[p] = sc
            if p < 16 { o.a[p] = sc }
        }
        o.b = classifier.classify(features)
        return o
    }

    private func lostTracking() {
        lostFrames += 1
        if lostFrames >= m.lostFrames {
            fx.reset()
            fy.reset()
            hasRoll = false
            trackedX = -1
            smoothedSize = 0
        }
    }

    private func decide(_ o: Observation, at t: Double) {
        eventCount = 0
        guard o.valid else {
            handLost(t, rejection: o.rejection)
            return
        }
        if o.jumped { endStroke(t, evaluate: false) }
        if o.partial {
            // Half a hand: follow the movement (a wide swipe can graze the edge), judge nothing.
            trackStrokes(t, vx: features[Feature.velocityX.rawValue], vy: features[Feature.velocityY.rawValue],
                         x: o.smoothX, y: o.smoothY, b: Classification(), partial: true)
            handLost(t, rejection: o.rejection, keepStroke: true)
            return
        }
        missingFrames = 0
        let b = o.b
        let vx = features[Feature.velocityX.rawValue]
        let speed = features[Feature.speed.rawValue]
        rollUnwrapped = features[Feature.roll.rawValue]
        smoothedSize = o.size
        var aBest = 0
        var aBestScore: Float = 0
        for p in 1..<poseCount where aScores[p] > aBestScore {
            aBestScore = aScores[p]
            aBest = p
        }

        status.handVisible = true
        status.rejection = .none
        status.hand = o.chosen
        status.judgeA = aBest
        status.judgeAScore = aBestScore
        status.judgeB = b
        status.speed = speed

        // Which pose do both judges agree on? B names at most one, so at most one pose.
        var agreed = 0
        if b.top > 0 && b.top < poseCount {
            let h = poseToHeld[b.top]
            let tuning = h >= 0 ? held[h].tuning : swipeTuning
            let inPose = (h >= 0 && (h == holdIndex || h == engagedIndex))
            let threshold = inPose ? tuning.stay : tuning.enter
            let needConfidence = lenient ? min(tuning.confidence, 0.45) : tuning.confidence
            let needMargin = lenient ? min(tuning.margin, 0.08) : tuning.margin
            if aScores[b.top] >= threshold && b.confidence >= needConfidence && b.margin >= needMargin {
                agreed = b.top
            }
        }
        // Not the knob or the ear: their rules say little about the hand's shape (a plain fist passes
        // pinch, and almost any hand at face height passes ear), so they always need both judges.
        if lenient && agreed == 0 && aBest > 0 && !Recognizer.isVague(aBest) && poseToHeld[aBest] >= 0
            && (b.top == 0 || b.top == aBest) {
            // Judge A alone, only when it is all but certain and B doesn't name another pose.
            let h = poseToHeld[aBest]
            let inPose = h == holdIndex || h == engagedIndex
            // If another shape rule matches too (peace and scroll can), that's a question for Judge B,
            // unless B already leans this way. The vague rules match alongside everything, so they
            // don't count.
            var rival: Float = 0
            for p in 1..<poseCount where p != aBest && poseToHeld[p] >= 0 && !Recognizer.isVague(p) && aScores[p] > rival {
                rival = aScores[p]
            }
            if aBestScore >= (inPose ? held[h].tuning.stay : 0.95) && (inPose || b.top == aBest || rival < 0.75) {
                agreed = aBest
            }
        }
        status.agreed = agreed

        trackReleases(aScores)

        // A continuous control in progress owns the hand.
        if engagedIndex >= 0 {
            continueEngagement(t, b: b, predictedY: o.predictedY, speed: speed)
            finishStatus()
            return
        }

        trackStrokes(t, vx: vx, vy: features[Feature.velocityY.rawValue], x: o.smoothX, y: o.smoothY, b: b, partial: false)

        // Holds.
        let still = speed <= m.stillSpeed
        // Scroll and the knob are about moving: they may start while the hand still drifts.
        let steadyEnough = speed <= m.stillSpeed * 4
        if holdIndex >= 0 {
            let h = held[holdIndex]
            holdTotal += 1
            if agreed == h.pose && (still || (h.continuous && steadyEnough)) { holdAgreed += 1 }
            // The shape changed: the held pose has gone and another one is clearly there.
            if aScores[h.pose] < h.tuning.stay && aBest != h.pose && aBestScore >= h.tuning.enter { holdChange += 1 } else { holdChange = 0 }
            if speed > m.stillSpeed * (h.continuous ? 6 : 2) { holdMoving += 1 } else { holdMoving = 0 }
            if holdChange >= 2 || holdMoving >= 2 || (h.settleAfterStrokes && inStroke) {
                cancelHold()
            } else {
                let elapsed = t - holdStart
                status.holdProgress = Float(min(elapsed / max(h.tuning.hold, 1e-3), 1))
                if elapsed >= h.tuning.hold - 0.004 {
                    if Float(holdAgreed) >= m.agreement * Float(holdTotal) {
                        fire(holdIndex, t, predictedY: o.predictedY)
                    } else {
                        cancelHold()
                    }
                }
            }
        }
        if holdIndex < 0 && engagedIndex < 0 && agreed > 0 && steadyEnough {
            let h = poseToHeld[agreed]
            if h >= 0 && (still || held[h].continuous) && enabledFlags[held[h].id] && !needsRelease[h] && t >= cooldownUntil[h]
                && !(held[h].settleAfterStrokes && (inStroke || t - lastStrokeEnd < m.palmSettle)) {
                holdIndex = h
                holdStart = t
                holdTotal = 1
                holdAgreed = 1
                holdChange = 0
                holdMoving = 0
                emit(.cue(held[h].id))
                if held[h].tuning.hold <= 0 { fire(h, t, predictedY: o.predictedY) }
            }
        }
        finishStatus()
    }

    // MARK: - Pieces

    @inline(__always) private func emit(_ e: RecognizerEvent) {
        guard eventCount < Recognizer.maxEvents else { return }
        eventBuffer[eventCount] = e
        eventCount += 1
    }

    private func finishStatus() {
        status.holdGesture = holdIndex >= 0 ? held[holdIndex].id : -1
        if holdIndex < 0 { status.holdProgress = 0 }
        status.engaged = engagedIndex >= 0 ? held[engagedIndex].id : -1
    }

    /// With two usable hands and nothing in flight, follow the one making a deliberate
    /// pose (both judges agree on it); failing that, the nearer one.
    private func choosePosingHand(_ frame: Frame, fallback: Int) -> Int {
        var best = fallback
        var bestScore: Float = 0
        var f = FeatureVector()
        for i in 0..<2 {
            let hand = frame.hand(i)
            guard FeatureExtractor.check(hand, aspect: frame.aspect, quality: model.quality) == .none else { continue }
            FeatureExtractor.extract(hand, frame: frame, flipChirality: model.flipChirality, into: &f)
            let b = classifier.classify(f)
            guard b.top > 0 && b.top < poseCount else { continue }
            let agreement = min(rules.score(b.top, f), b.confidence)
            if agreement >= 0.6 && agreement > bestScore + 0.05 {
                bestScore = agreement
                best = i
            }
        }
        return best
    }

    private func handLost(_ t: Double, rejection: FeatureExtractor.Rejection, keepStroke: Bool = false) {
        missingFrames += 1
        status.handVisible = false
        status.rejection = rejection
        status.hand = -1
        status.agreed = 0
        status.judgeA = 0
        status.judgeAScore = 0
        status.judgeB = Classification()
        // A stroke that leaves the frame completes on its last good frame.
        // A fast hand can vanish from Vision for a frame or two mid-swipe; only a longer gap
        // ends the stroke (on its last good frame).
        if inStroke && !keepStroke && missingFrames >= m.lostFrames { endStroke(t, evaluate: true) }
        for h in 0..<heldCount where needsRelease[h] {
            releaseCount[h] += 1
            if releaseCount[h] >= m.releaseFrames { needsRelease[h] = false }
        }
        if missingFrames >= m.lostFrames {
            if holdIndex >= 0 { cancelHold() }
            if engagedIndex >= 0 { endEngagement() }
        } else if engagedIndex >= 0 {
            engagedMisses += 1
        }
        finishStatus()
    }

    private func trackReleases(_ a: UnsafeMutablePointer<Float>) {
        for h in 0..<heldCount where needsRelease[h] && h != engagedIndex {
            if a[held[h].pose] < held[h].tuning.stay {
                releaseCount[h] += 1
                if releaseCount[h] >= m.releaseFrames { needsRelease[h] = false }
            } else {
                releaseCount[h] = 0
            }
        }
    }

    private func cancelHold() {
        guard holdIndex >= 0 else { return }
        emit(.cancelled(held[holdIndex].id))
        holdIndex = -1
    }

    private func fire(_ h: Int, _ t: Double, predictedY: Float) {
        let g = held[h]
        holdIndex = -1
        cooldownUntil[h] = t + g.tuning.cooldown
        needsRelease[h] = true
        releaseCount[h] = 0
        emit(.fired(g.id))
        if g.continuous {
            engagedIndex = h
            engagedMisses = 0
            knobAnchor = rollUnwrapped
            lastPredY = predictedY
        }
    }

    private func continueEngagement(_ t: Double, b: Classification, predictedY: Float, speed: Float) {
        let g = held[engagedIndex]
        // Leave when A drops below the lower "stay" score, or B is sure it's something else.
        let otherPose = b.top != g.pose && b.top != 0 && b.confidence >= 0.75
        // Dropping the hand is a way to stop: a sudden fast movement ends scrolling instead of flinging.
        let dropped = speed > 9
        if aScores[g.pose] >= g.tuning.stay && !otherPose && !dropped {
            engagedMisses = 0
            if g.id == Gesture.scroll.index {
                let delta = (predictedY - lastPredY) / max(smoothedSize, 1e-3)
                if delta != 0 { emit(.scroll(delta)) }
            } else if g.id == Gesture.volumeKnob.index && speed <= 3 {
                // Turning is done in place; a hand on the move is letting go, not turning.
                let step = m.knobStepDegrees * .pi / 180
                // Clockwise, as you see your own hand, turns the dial's angle down: volume up.
                var guardCount = 0
                while rollUnwrapped - knobAnchor <= -step && guardCount < 4 {
                    knobAnchor -= step
                    emit(.volume(1))
                    guardCount += 1
                }
                while rollUnwrapped - knobAnchor >= step && guardCount < 4 {
                    knobAnchor += step
                    emit(.volume(-1))
                    guardCount += 1
                }
            }
        } else {
            engagedMisses += 1
            if engagedMisses >= m.lostFrames + 2 || dropped { endEngagement() }
        }
        lastPredY = predictedY
    }

    private func endEngagement() {
        guard engagedIndex >= 0 else { return }
        emit(.ended(held[engagedIndex].id))
        engagedIndex = -1
    }

    // MARK: - Swipes and waves

    private func trackStrokes(_ t: Double, vx: Float, vy: Float, x: Float, y: Float, b: Classification, partial: Bool) {
        let aOpen = max(aScores[Pose.flat.rawValue], aScores[Pose.open.rawValue])
        let bOpen = (b.top == Pose.flat.rawValue || b.top == Pose.open.rawValue) && b.confidence >= swipeTuning.confidence
        let openish = !partial && aOpen >= swipeTuning.enter && (bOpen || (lenient && b.top == 0 && aOpen >= 0.9))
        // Sideways movement only: raising or dropping the hand isn't a stroke.
        let fast = abs(vx) >= m.strokeStartSpeed && abs(vx) >= 1.5 * abs(vy)
        let sign: Float = vx >= 0 ? 1 : -1
        if !inStroke {
            if fast {
                inStroke = true
                strokeDir = sign
                strokeStartT = anchorT
                strokeStartX = anchorX
                strokeStartY = anchorY
                strokePeak = abs(vx)
                strokeFrames = 1
                strokePoseFrames = openish ? 1 : 0
                strokeSizeSum = smoothedSize
                strokeLastT = t
                strokeLastX = x
                strokeLastY = y
            } else {
                anchorT = t
                anchorX = x
                anchorY = y
            }
            return
        }
        if sign == strokeDir && abs(vx) >= m.strokeEndSpeed && abs(vx) >= abs(vy) {
            strokePeak = max(strokePeak, abs(vx))
            strokeFrames += 1
            if openish { strokePoseFrames += 1 }
            strokeSizeSum += smoothedSize
            strokeLastT = t
            strokeLastX = x
            strokeLastY = y
            return
        }
        // The movement just completed on this frame.
        strokeLastT = t
        strokeLastX = x
        strokeLastY = y
        endStroke(t, evaluate: true)
        anchorT = t
        anchorX = x
        anchorY = y
        // A reversal starts the next stroke straight away (a wave).
        if fast && sign != strokeDir {
            inStroke = true
            strokeDir = sign
            strokeStartT = t
            strokeStartX = x
            strokeStartY = y
            strokePeak = abs(vx)
            strokeFrames = 1
            strokePoseFrames = openish ? 1 : 0
            strokeSizeSum = smoothedSize
        }
    }

    private func endStroke(_ t: Double, evaluate: Bool) {
        guard inStroke else { return }
        inStroke = false
        guard evaluate, strokeFrames >= 2 else { return }
        let size = strokeSizeSum / Float(max(strokeFrames, 1))
        let dx = (strokeLastX - strokeStartX) / max(size, 1e-3)
        let dy = (strokeLastY - strokeStartY) / max(size, 1e-3)
        let distance = abs(dx)
        let duration = strokeLastT - strokeStartT
        let poseShare = Float(strokePoseFrames) / Float(strokeFrames)
        let dir = strokeDir
        let reversedRecently = strokeStartT - lastStrokeEnd < m.swipeReversalGuard && lastStrokeDir == -dir
        let level = abs(dy) <= 0.6 * distance
        defer {
            // Only level strokes count as strokes for what follows (a wave, a swipe's settle).
            if level {
                lastStrokeEnd = strokeLastT
                lastStrokeDir = dir
            }
        }

        // Swipe: wide, fast, level, open and flat, and not the middle of a wave.
        if distance >= m.swipeMinDistance && strokePeak >= m.swipeMinPeakSpeed && duration <= m.swipeMaxDuration
            && abs(dy) <= m.swipeMaxDrift * distance && poseShare >= m.strokePoseShare && !reversedRecently
            && t >= swipeCooldownUntil {
            let g: Gesture = dir > 0 ? .swipeRight : .swipeLeft
            if enabledFlags[g.index] {
                swipeCooldownUntil = t + swipeTuning.cooldown
                waveCount = 0
                emit(.fired(g.index))
            }
            return
        }

        // Wave stroke: smaller, alternating.
        if distance >= m.waveMinDistance && distance <= m.waveMaxDistance && duration <= m.waveMaxStroke
            && poseShare >= m.strokePoseShare && level {
            if waveCount > 0 && dir == -waveLastDir && strokeStartT - waveLastEnd <= m.waveMaxGap {
                waveCount += 1
            } else {
                waveCount = 1
            }
            waveLastDir = dir
            waveLastEnd = strokeLastT
            if waveCount >= m.waveStrokes && t >= waveCooldownUntil {
                waveCount = 0
                if enabledFlags[Gesture.wave.index] {
                    waveCooldownUntil = t + waveTuning.cooldown
                    emit(.fired(Gesture.wave.index))
                }
            }
        } else {
            waveCount = 0
        }
    }
}
