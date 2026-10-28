// Judge A: each pose written out as explicit conditions on the features,
// with tolerance bands. Inside a condition's range it scores 1; outside, the
// score falls linearly to 0 over the band. A pose scores its weakest
// condition. Custom gestures from the Create screen use exactly this format.

public struct Condition: Codable, Sendable, Equatable {
    public var feature: String
    public var min: Float?
    public var max: Float?
    /// How far outside the range a value can drift before the condition scores 0.
    public var band: Float

    public init(_ feature: Feature, min: Float? = nil, max: Float? = nil, band: Float) {
        self.feature = feature.name
        self.min = min
        self.max = max
        self.band = band
    }

    public init(feature: String, min: Float?, max: Float?, band: Float) {
        self.feature = feature
        self.min = min
        self.max = max
        self.band = band
    }
}

public struct PoseRule: Codable, Sendable, Equatable {
    public var name: String
    public var conditions: [Condition]

    public init(name: String, conditions: [Condition]) {
        self.name = name
        self.conditions = conditions
    }

    /// Every feature name must exist and every range must make sense.
    public func validate() -> String? {
        if conditions.isEmpty { return "a pose needs at least one condition" }
        for c in conditions {
            guard let f = Feature.named(c.feature) else { return "no feature called \(c.feature)" }
            if [.velocityX, .velocityY, .speed, .roll, .posX, .posY, .handSize].contains(f) {
                return "\(c.feature) describes where or how fast the hand is, not its shape"
            }
            if c.min == nil && c.max == nil { return "\(c.feature) needs a min or a max" }
            if let lo = c.min, let hi = c.max, lo > hi { return "\(c.feature): min is above max" }
            if !(c.band > 0) || c.band > 1 { return "\(c.feature): band must be between 0 and 1" }
        }
        return nil
    }
}

/// The built-in poses. Ranges come from the plan's descriptions; the bands are
/// where personal calibration is allowed to move them.
public enum BuiltinRules {
    /// Bumped whenever these rules change, so personal calibration built on older ones is redone.
    public static let version = 4

    // Reach: about 1 for an extended finger, 0 or below for a curled one.
    static let extended: Float = 0.75
    static let curled: Float = 0.35

    private static func up(_ f: Feature) -> Condition { Condition(f, min: extended, band: 0.12) }
    private static func down(_ f: Feature) -> Condition { Condition(f, max: curled, band: 0.15) }

    public static let flat = PoseRule(name: "flat", conditions: [
        up(.reachIndex), up(.reachMiddle), up(.reachRing), Condition(.reachLittle, min: 0.65, band: 0.15),
        Condition(.straightThumb, min: 0.7, band: 0.12),
        Condition(.spreadIndexMiddle, max: 0.24, band: 0.07),
        Condition(.spreadMiddleRing, max: 0.24, band: 0.07),
        Condition(.spreadRingLittle, max: 0.3, band: 0.08),
        Condition(.palmFacing, min: 0.25, band: 0.15),
        Condition(.palmAxisY, min: 0.45, band: 0.2),
    ])

    /// An open hand in motion (swipes, waves): fingers out but not necessarily straight, and the
    /// palm free to turn a little. Recordings showed moving fingers reaching 0.6–0.75.
    public static let open = PoseRule(name: "open", conditions: [
        Condition(.reachIndex, min: 0.58, band: 0.15), Condition(.reachMiddle, min: 0.58, band: 0.15),
        Condition(.reachRing, min: 0.55, band: 0.15), Condition(.reachLittle, min: 0.45, band: 0.15),
        Condition(.palmFacing, min: -0.15, band: 0.2),
        Condition(.palmAxisY, min: 0.2, band: 0.2),
    ])

    /// Index and middle bent round, as in a fist. Reach alone can't tell a fist from two straight
    /// fingers pointed at the camera (both look short in the image); bend can: straight fingers
    /// stay straight however they point, so a scroll hand never reads as a thumb.
    private static let fistCurl: [Condition] = [Condition(.curlIndex, min: 0.55, band: 0.2), Condition(.curlMiddle, min: 0.55, band: 0.2)]

    public static let thumbsUp = PoseRule(name: "thumbsUp", conditions: [
        Condition(.straightThumb, min: 0.8, band: 0.1),
        Condition(.extThumb, min: 0.42, band: 0.15),
        Condition(.thumbDirY, min: 0.65, band: 0.15),
        down(.reachIndex), down(.reachMiddle), down(.reachRing), down(.reachLittle),
    ] + fistCurl)

    public static let thumbsDown = PoseRule(name: "thumbsDown", conditions: [
        Condition(.straightThumb, min: 0.8, band: 0.1),
        Condition(.extThumb, min: 0.42, band: 0.15),
        Condition(.thumbDirY, max: -0.65, band: 0.15),
        down(.reachIndex), down(.reachMiddle), down(.reachRing), down(.reachLittle),
    ] + fistCurl)

    public static let peace = PoseRule(name: "peace", conditions: [
        up(.reachIndex), up(.reachMiddle), down(.reachRing), down(.reachLittle),
        Condition(.spreadIndexMiddle, min: 0.29, max: 1.3, band: 0.05),
        Condition(.palmFacing, min: 0.15, band: 0.15),
        Condition(.indexDirY, min: 0.4, band: 0.2),
    ])

    /// Two fingers like on a trackpad. People point them anywhere from up to straight at the
    /// screen, which in the image makes them short, and hold them together or a little apart.
    /// So: both fingers straight (little bend, however foreshortened), the other two curled.
    /// Telling it from a peace sign is Judge B's job; it learns the difference from your hands.
    public static let scroll = PoseRule(name: "scroll", conditions: [
        Condition(.curlIndex, max: 0.42, band: 0.15), Condition(.curlMiddle, max: 0.42, band: 0.15),
        Condition(.reachIndex, min: 0.1, band: 0.15), Condition(.reachMiddle, min: 0.1, band: 0.15),
        down(.reachRing), down(.reachLittle),
        Condition(.spreadIndexMiddle, max: 0.55, band: 0.1),
        Condition(.palmFacing, min: -0.1, band: 0.2),
    ])

    public static let lips = PoseRule(name: "lips", conditions: [
        up(.reachIndex), down(.reachMiddle), down(.reachRing), down(.reachLittle),
        Condition(.indexDirY, min: 0.55, band: 0.2),
        Condition(.facePresent, min: 0.5, band: 0.01),
        Condition(.lipsDistance, max: 0.5, band: 0.12),
    ])

    public static let ear = PoseRule(name: "ear", conditions: [
        Condition(.facePresent, min: 0.5, band: 0.01),
        Condition(.earDistance, max: 0.9, band: 0.2),
        Condition(.faceDY, min: -0.8, max: 0.9, band: 0.2),
        // Cupped: curled anywhere from loosely to well round, but not flat.
        Condition(.openness, min: 0.05, max: 0.9, band: 0.1),
    ])

    public static let pinch = PoseRule(name: "pinch", conditions: [
        // Fingertips a small knob's width apart (2–3 cm), or touching.
        Condition(.thumbToIndex, max: 0.6, band: 0.15),
        Condition(.reachIndex, max: 0.85, band: 0.1),
        // Holding a knob, the other fingers curl too (unlike an OK sign).
        Condition(.reachMiddle, max: 0.65, band: 0.12),
    ])

    /// Indexed by `Pose.rawValue`. Index 0 (nothing) has no rule.
    public static let all: [PoseRule] = [
        PoseRule(name: "nothing", conditions: []),
        flat, open, thumbsUp, thumbsDown, peace, scroll, lips, ear, pinch,
    ]
}

/// The rules compiled into flat arrays, scored without allocating.
public struct CompiledRules: Sendable {
    public let poseCount: Int
    private var start: [Int32]   // poseCount + 1 offsets into the condition arrays
    private var feature: [Int32]
    private var lo: [Float]
    private var hi: [Float]
    private var invBand: [Float]

    public init(_ rules: [PoseRule]) {
        poseCount = rules.count
        start = [0]
        feature = []
        lo = []
        hi = []
        invBand = []
        for rule in rules {
            for c in rule.conditions {
                guard let f = Feature.named(c.feature) else { continue }
                feature.append(Int32(f.rawValue))
                lo.append(c.min ?? -.greatestFiniteMagnitude)
                hi.append(c.max ?? .greatestFiniteMagnitude)
                invBand.append(1 / max(c.band, 1e-4))
            }
            start.append(Int32(feature.count))
        }
    }

    /// One pose's score, 0...1. A pose with no conditions scores 0.
    @inline(__always)
    public func score(_ pose: Int, _ f: FeatureVector) -> Float {
        start.withUnsafeBufferPointer { s in
            let a = Int(s[pose]), b = Int(s[pose + 1])
            if a == b { return 0 }
            return feature.withUnsafeBufferPointer { fi in
                lo.withUnsafeBufferPointer { l in
                    hi.withUnsafeBufferPointer { h in
                        invBand.withUnsafeBufferPointer { ib in
                            var worst: Float = 1
                            for i in a..<b {
                                let v = f[Int(fi[i])]
                                var outside: Float = 0
                                if v < l[i] { outside = l[i] - v } else if v > h[i] { outside = v - h[i] }
                                let sc = 1 - outside * ib[i]
                                if sc < worst { worst = sc }
                                if worst <= 0 { return 0 }
                            }
                            return worst
                        }
                    }
                }
            }
        }
    }

    /// Scores every pose into `out` (which must have `poseCount` slots).
    @inline(__always)
    public func scoreAll(_ f: FeatureVector, into out: UnsafeMutableBufferPointer<Float>) {
        for p in 0..<poseCount { out[p] = score(p, f) }
    }
}
