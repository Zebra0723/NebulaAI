// Joints → features: a pure function of one hand (and the face rectangle).
//
// The features don't care how far away the hand is, how big it is or which
// hand it is: joints are moved so the wrist is the origin, scaled by the
// palm (wrist to middle-finger knuckle), and left hands are mirrored into
// right-hand space. Orientation features are kept in "user space", the
// mirror view you see of yourself, so "up" and "left" mean what you mean.

/// A fixed-size feature vector. 64 lanes, `Feature.count` used.
public typealias FeatureVector = SIMD64<Float>

/// Every feature by index, with a stable name a custom gesture spec can refer to.
public enum Feature: Int, CaseIterable, Sendable {
    // Per finger, thumb first: bend summed over the finger's joints, in units of π (0 straight).
    case curlThumb = 0, curlIndex, curlMiddle, curlRing, curlLittle
    /// Thumb: base-to-tip distance over its length (1 straight, low folded).
    case straightThumb
    // Fingers: how far the tip reaches past its knuckle along the palm's axis, in finger
    // lengths. About 1 extended, 0 or below curled. Unlike 2D straightness, a finger folded
    // toward the camera can't pass for a straight one.
    case reachIndex, reachMiddle, reachRing, reachLittle
    // Fingertip distance from the wrist in palm lengths (thumb: from the index knuckle).
    case extThumb, extIndex, extMiddle, extRing, extLittle
    // Angle between neighbouring fingers' directions, radians.
    case spreadThumbIndex, spreadIndexMiddle, spreadMiddleRing, spreadRingLittle
    // Thumb tip to each fingertip, palm lengths.
    case thumbToIndex, thumbToMiddle, thumbToRing, thumbToLittle
    /// Positive when the palm faces the camera, negative for the back of the hand.
    case palmFacing
    // Unit vectors in user space (+y up, +x to your right, left hands mirrored).
    case palmAxisX, palmAxisY
    case thumbDirX, thumbDirY
    case indexDirX, indexDirY
    /// Palm length as a fraction of the frame height: how near the hand is.
    case handSize
    /// Palm centre in user space: x in frame heights from the left, y 0 (bottom) to 1.
    case posX, posY
    case facePresent
    /// Index fingertip to the lips, in face widths (3 when there's no face).
    case lipsDistance
    /// Palm centre to the nearer ear, in face widths (3 when there's no face).
    case earDistance
    /// Palm centre height relative to the face centre, in face heights.
    case faceDY
    /// Mean reach of the four fingers.
    case openness
    // Motion, filled by the recognizer from the smoothed palm path: palm lengths per second.
    case velocityX, velocityY, speed
    /// Palm axis angle in radians, unwrapped across frames (the volume knob's dial).
    case roll

    public static let count = 42

    /// Features the classifier (Judge B) sees: hand shape and where it is relative
    /// to the face, never absolute position, size or motion.
    public static let classifierSet: [Feature] =
        Feature.allCases.filter { $0.rawValue <= Feature.indexDirY.rawValue || ($0.rawValue >= Feature.facePresent.rawValue && $0.rawValue <= Feature.openness.rawValue) }

    public var name: String { "\(self)" }

    public static func named(_ name: String) -> Feature? { allCases.first { $0.name == name } }
}

/// Where a face is, in user space, for "finger to lips" and "hand to ear".
struct FacePoints {
    var lipsX: Float, lipsY: Float
    var leftEarX: Float, rightEarX: Float, earY: Float
    var centerY: Float
    var width: Float, height: Float
}

public enum FeatureExtractor {
    /// Minimum confidences for a usable hand: the joints that carry the shape must be seen.
    public struct Quality: Sendable, Codable, Equatable {
        public var structural: Float = 0.2   // wrist, knuckles, thumb base
        public var tips: Float = 0.02        // a curled fingertip is often half-hidden (and filled in)
        public var edgeMargin: Float = 0.015 // a hand touching the frame edge is half a hand
        public var minHandSize: Float = 0.055
        public var maxHandSize: Float = 0.45
        public init() {}
    }

    public enum Rejection: UInt8, Sendable { case none, lowConfidence, touchingEdge, tooFar, tooNear }

    /// Whether a hand can be trusted at all this frame.
    @inline(__always)
    public static func check(_ hand: Hand, aspect: Float, quality q: Quality) -> Rejection {
        // Unrolled on purpose: no arrays on the per-frame path.
        let c = hand.confidence
        if c[0] < q.structural || c[1] < q.structural || c[2] < q.structural || c[5] < q.structural
            || c[9] < q.structural || c[13] < q.structural || c[17] < q.structural { return .lowConfidence }
        for j in 0..<21 where c[j] < q.tips { return .lowConfidence }
        let m = q.edgeMargin
        for j in 0..<21 {
            let px = hand.x[j], py = hand.y[j]
            if px < m || px > 1 - m || py < m || py > 1 - m { return .touchingEdge }
        }
        let size = hypot2((hand.x[9] - hand.x[0]) * aspect, hand.y[9] - hand.y[0])
        if size < q.minHandSize { return .tooFar }
        if size > q.maxHandSize { return .tooNear }
        return .none
    }

    /// Palm length in frame heights.
    @inline(__always)
    public static func palmSize(_ hand: Hand, aspect: Float) -> Float {
        hypot2((hand.x[9] - hand.x[0]) * aspect, hand.y[9] - hand.y[0])
    }

    /// Palm centre in user space (mirror view, frame-height units).
    @inline(__always)
    public static func palmCenter(_ hand: Hand, aspect: Float) -> (x: Float, y: Float) {
        let mx = (hand.x[0] + hand.x[5] + hand.x[9] + hand.x[13] + hand.x[17]) * 0.2
        let my = (hand.y[0] + hand.y[5] + hand.y[9] + hand.y[13] + hand.y[17]) * 0.2
        return ((1 - mx) * aspect, my)
    }

    /// Fills the pose features (everything but motion) for one hand.
    /// `flipChirality` corrects for a camera whose left/right comes out swapped (set by enrollment).
    @inline(__always)
    public static func extract(_ hand: Hand, frame: Frame, flipChirality: Bool = false, into f: inout FeatureVector) {
        let aspect = frame.aspect
        // User space: mirror the camera image so it reads like a mirror, and use frame heights for both axes.
        var ux = SIMD32<Float>(repeating: 1) - hand.x
        ux *= aspect
        let uy = hand.y

        var isLeft = hand.chirality == .left
        if flipChirality && hand.chirality != .unknown { isLeft.toggle() }
        let sx: Float = isLeft ? -1 : 1 // mirror left hands into right-hand space for shape features

        // Wrist at the origin, scaled by palm length.
        let wx = ux[0], wy = uy[0]
        let ax = ux[9] - wx, ay = uy[9] - wy
        let size = hypot2(ax, ay)
        let inv: Float = size > 1e-6 ? 1 / size : 0
        var px = (ux - SIMD32<Float>(repeating: wx)) * inv
        let py = (uy - SIMD32<Float>(repeating: wy)) * inv
        px *= sx

        // Curl: bend summed along the chain, in units of π.
        let invPi: Float = 1 / .pi
        f[Feature.curlThumb.rawValue] = (bend(px, py, 0, 1, 2) + bend(px, py, 1, 2, 3) + bend(px, py, 2, 3, 4)) * invPi
        f[Feature.curlIndex.rawValue] = (bend(px, py, 0, 5, 6) + bend(px, py, 5, 6, 7) + bend(px, py, 6, 7, 8)) * invPi
        f[Feature.curlMiddle.rawValue] = (bend(px, py, 0, 9, 10) + bend(px, py, 9, 10, 11) + bend(px, py, 10, 11, 12)) * invPi
        f[Feature.curlRing.rawValue] = (bend(px, py, 0, 13, 14) + bend(px, py, 13, 14, 15) + bend(px, py, 14, 15, 16)) * invPi
        f[Feature.curlLittle.rawValue] = (bend(px, py, 0, 17, 18) + bend(px, py, 17, 18, 19) + bend(px, py, 18, 19, 20)) * invPi

        // The thumb's two phalanges: tip distance over their length.
        let thumbChain = dist(px, py, 2, 3) + dist(px, py, 3, 4)
        f[Feature.straightThumb.rawValue] = thumbChain > 1e-6 ? dist(px, py, 2, 4) / thumbChain : 0
        // In canonical space the palm axis is +y, so reach is the tip's rise over its knuckle.
        f[Feature.reachIndex.rawValue] = (py[8] - py[5]) * (1 / 0.88)
        f[Feature.reachMiddle.rawValue] = (py[12] - py[9]) * (1 / 0.95)
        f[Feature.reachRing.rawValue] = (py[16] - py[13]) * (1 / 0.9)
        f[Feature.reachLittle.rawValue] = (py[20] - py[17]) * (1 / 0.72)

        f[Feature.extThumb.rawValue] = dist(px, py, 4, 5)
        f[Feature.extIndex.rawValue] = hypot2(px[8], py[8])
        f[Feature.extMiddle.rawValue] = hypot2(px[12], py[12])
        f[Feature.extRing.rawValue] = hypot2(px[16], py[16])
        f[Feature.extLittle.rawValue] = hypot2(px[20], py[20])

        f[Feature.spreadThumbIndex.rawValue] = spread(px, py, 2, 4, 5, 8)
        f[Feature.spreadIndexMiddle.rawValue] = spread(px, py, 5, 8, 9, 12)
        f[Feature.spreadMiddleRing.rawValue] = spread(px, py, 9, 12, 13, 16)
        f[Feature.spreadRingLittle.rawValue] = spread(px, py, 13, 16, 17, 20)

        f[Feature.thumbToIndex.rawValue] = dist(px, py, 4, 8)
        f[Feature.thumbToMiddle.rawValue] = dist(px, py, 4, 12)
        f[Feature.thumbToRing.rawValue] = dist(px, py, 4, 16)
        f[Feature.thumbToLittle.rawValue] = dist(px, py, 4, 20)

        // Palm facing: the sign of index-knuckle × little-knuckle, in mirrored right-hand space.
        // A right palm facing the camera has its index knuckle to the left of its little knuckle.
        let cross = px[5] * py[17] - py[5] * px[17]
        f[Feature.palmFacing.rawValue] = clamp(-cross * 2.5, -1.5, 1.5)

        unit(ax * sx, ay, Feature.palmAxisX.rawValue, Feature.palmAxisY.rawValue, &f)
        unit((ux[4] - ux[2]) * sx, uy[4] - uy[2], Feature.thumbDirX.rawValue, Feature.thumbDirY.rawValue, &f)
        unit((ux[8] - ux[5]) * sx, uy[8] - uy[5], Feature.indexDirX.rawValue, Feature.indexDirY.rawValue, &f)

        // The dial for the volume knob: the palm's angle as you see it, not mirrored, so
        // clockwise is clockwise for either hand. The recognizer unwraps it across frames.
        f[Feature.roll.rawValue] = atan2Approx(ay, ax)
        f[Feature.handSize.rawValue] = size
        let cx = (ux[0] + ux[5] + ux[9] + ux[13] + ux[17]) * 0.2
        let cy = (uy[0] + uy[5] + uy[9] + uy[13] + uy[17]) * 0.2
        f[Feature.posX.rawValue] = cx
        f[Feature.posY.rawValue] = cy

        if frame.hasFace, frame.face.width > 0.01 {
            let fp = facePoints(frame.face, aspect: aspect)
            f[Feature.facePresent.rawValue] = 1
            f[Feature.lipsDistance.rawValue] = min(hypot2(ux[8] - fp.lipsX, uy[8] - fp.lipsY) / fp.width, 3)
            let dl = hypot2(cx - fp.leftEarX, cy - fp.earY)
            let dr = hypot2(cx - fp.rightEarX, cy - fp.earY)
            f[Feature.earDistance.rawValue] = min(min(dl, dr) / fp.width, 3)
            f[Feature.faceDY.rawValue] = clamp((cy - fp.centerY) / fp.height, -3, 3)
        } else {
            f[Feature.facePresent.rawValue] = 0
            f[Feature.lipsDistance.rawValue] = 3
            f[Feature.earDistance.rawValue] = 3
            f[Feature.faceDY.rawValue] = 3
        }
        f[Feature.openness.rawValue] = (f[Feature.reachIndex.rawValue] + f[Feature.reachMiddle.rawValue]
            + f[Feature.reachRing.rawValue] + f[Feature.reachLittle.rawValue]) * 0.25
    }

    // Plain functions rather than nested closures: a closure capturing the frame's
    // values can cost a heap box in a debug build, and the per-frame path never allocates.
    @inline(__always)
    static func dist(_ px: SIMD32<Float>, _ py: SIMD32<Float>, _ a: Int, _ b: Int) -> Float {
        hypot2(px[a] - px[b], py[a] - py[b])
    }

    @inline(__always)
    static func bend(_ px: SIMD32<Float>, _ py: SIMD32<Float>, _ a: Int, _ b: Int, _ c: Int) -> Float {
        angleBetween(px[b] - px[a], py[b] - py[a], px[c] - px[b], py[c] - py[b])
    }

    @inline(__always)
    static func spread(_ px: SIMD32<Float>, _ py: SIMD32<Float>, _ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Float {
        angleBetween(px[a1] - px[a0], py[a1] - py[a0], px[b1] - px[b0], py[b1] - py[b0])
    }

    @inline(__always)
    static func unit(_ dx: Float, _ dy: Float, _ ix: Int, _ iy: Int, _ f: inout FeatureVector) {
        let l = hypot2(dx, dy)
        if l > 1e-6 {
            f[ix] = dx / l
            f[iy] = dy / l
        } else {
            f[ix] = 0
            f[iy] = 0
        }
    }

    /// Lips and ears from the face rectangle alone: lips a fifth of the way up from the
    /// chin, ears at the sides halfway up.
    @inline(__always)
    static func facePoints(_ box: FaceBox, aspect: Float) -> FacePoints {
        let cx = (1 - (box.x + box.width * 0.5)) * aspect
        let w = box.width * aspect
        return FacePoints(
            lipsX: cx, lipsY: box.y + box.height * 0.22,
            leftEarX: cx - w * 0.5, rightEarX: cx + w * 0.5, earY: box.y + box.height * 0.5,
            centerY: box.y + box.height * 0.5,
            width: max(w, 1e-3), height: max(box.height, 1e-3)
        )
    }
}
