// Everything the recognizer runs on, in one file the app loads and the
// report writes: the classifier, the per-gesture thresholds the tuning
// chose, and the timing rules.

import Foundation

/// When a gesture may fire, per gesture. Tuned on validation sessions.
public struct GestureTuning: Codable, Sendable, Equatable {
    /// Seconds the pose must be held (held gestures) or before engaging (continuous ones).
    public var hold: Double
    /// Judge B's minimum share of the vote.
    public var confidence: Float
    /// Judge B's minimum lead over its second choice.
    public var margin: Float
    /// Judge A's score to start: entering needs more than staying.
    public var enter: Float
    /// Judge A's score to stay in the pose once in it.
    public var stay: Float
    /// Seconds after firing before the same gesture can fire again.
    public var cooldown: Double

    public init(hold: Double = 0.15, confidence: Float = 0.6, margin: Float = 0.25, enter: Float = 0.75,
                stay: Float = 0.45, cooldown: Double = 0.8) {
        self.hold = hold
        self.confidence = confidence
        self.margin = margin
        self.enter = enter
        self.stay = stay
        self.cooldown = cooldown
    }
}

/// The timing and movement rules shared by every gesture.
public struct MotionTuning: Codable, Sendable, Equatable {
    /// A held pose must be agreed on in at least this share of its frames.
    public var agreement: Float = 0.8
    /// Palm lengths per second below which a hand counts as held still.
    public var stillSpeed: Float = 1.6
    /// Frames out of a pose before the same gesture can fire again.
    public var releaseFrames: Int = 3
    /// Frames without a usable hand before a hold or an engagement ends.
    public var lostFrames: Int = 3
    /// After a swipe or wave stroke ends, open palm waits this long (so a swipe's end isn't a pause).
    public var palmSettle: Double = 0.35

    // Swipe: one fast, wide, level stroke.
    public var strokeStartSpeed: Float = 3.0
    public var strokeEndSpeed: Float = 1.5
    public var swipeMinDistance: Float = 2.6
    public var swipeMinPeakSpeed: Float = 6
    public var swipeMaxDuration: Double = 0.6
    public var swipeMaxDrift: Float = 0.6
    /// Share of a stroke's frames where both judges agree the hand is open and flat.
    public var strokePoseShare: Float = 0.6
    /// A stroke that starts this soon after an opposite one is part of a wave, not a swipe.
    public var swipeReversalGuard: Double = 0.4

    // Wave: smaller strokes that alternate.
    public var waveMinDistance: Float = 0.35
    public var waveMaxDistance: Float = 2.2
    public var waveStrokes: Int = 3
    public var waveMaxGap: Double = 0.3
    public var waveMaxStroke: Double = 0.6

    // Continuous controls.
    /// How far ahead scroll extrapolates the hand, seconds: about one frame plus display latency.
    public var predictionHorizon: Float = 0.03
    /// Degrees of wrist twist per volume step.
    public var knobStepDegrees: Float = 12

    public init() {}
}

public struct NebulaModel: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version = NebulaModel.currentVersion
    /// Where the classifier's examples came from: "synthetic" until your recordings replace it.
    public var source: String
    public var classifier: ClassifierModel
    /// Keyed by `Gesture.rawValue` (and custom gesture ids).
    public var tuning: [String: GestureTuning]
    public var motion = MotionTuning()
    public var quality = FeatureExtractor.Quality()
    public var filter = OneEuroParameters.lowLag
    /// Set by enrollment if this camera reports left and right hands swapped.
    public var flipChirality = false
    /// Personal calibration's adjusted pose rules, keyed by pose name. Missing = built-in.
    public var rules: [String: PoseRule] = [:]
    /// The `BuiltinRules.version` those personal rules were derived from.
    public var rulesVersion: Int?

    public init(source: String, classifier: ClassifierModel, tuning: [String: GestureTuning] = [:]) {
        self.source = source
        self.classifier = classifier
        self.tuning = tuning
    }

    public func tuning(for gesture: Gesture) -> GestureTuning {
        tuning[gesture.rawValue] ?? NebulaModel.defaultTuning(gesture)
    }

    public static func defaultTuning(_ gesture: Gesture) -> GestureTuning {
        switch gesture {
        case .swipeLeft, .swipeRight:
            // Motion blurs the hand, so B is allowed less certainty mid-stroke; the stroke rules carry it.
            return GestureTuning(hold: 0, confidence: 0.45, margin: 0.1, enter: 0.6, stay: 0.4, cooldown: 0.5)
        case .wave:
            // A wave disarms Nebula, so a hand still waving afterwards must not count twice.
            return GestureTuning(hold: 0, confidence: 0.45, margin: 0.1, enter: 0.6, stay: 0.4, cooldown: 2.5)
        case .scroll, .volumeKnob:
            return GestureTuning(hold: 0.15, confidence: 0.6, margin: 0.25, enter: 0.75, stay: 0.4, cooldown: 0.4)
        default:
            return GestureTuning()
        }
    }

    /// The pose rules in force: built-in, with any personal adjustments.
    public func poseRules() -> [PoseRule] {
        BuiltinRules.all.map { rules[$0.name] ?? $0 }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// A short fingerprint of the model, so a report can say which model it measured.
    public var fingerprint: String {
        let data = (try? encoded()) ?? Data()
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in data { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    public static func decode(_ data: Data) throws -> NebulaModel {
        try JSONDecoder().decode(NebulaModel.self, from: data)
    }
}

public enum Bootstrap {
    /// A model whose Judge B has seen nothing yet: it agrees with no pose, so nothing can fire.
    /// Training replaces the classifier; everything else starts at its defaults.
    public static func emptyModel() -> NebulaModel {
        let features = Feature.classifierSet.map(\.rawValue)
        let classifier = ClassifierModel(features: features, mean: features.map { _ in 0 }, invStd: features.map { _ in 1 },
                                         points: [], labels: [], weights: [], k: 9, bandwidth: 1,
                                         maxDistance: .greatestFiniteMagnitude, classCount: Pose.builtinCount)
        return NebulaModel(source: "untrained", classifier: classifier)
    }
}
