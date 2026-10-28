// What the camera stage hands the recognizer: hands as 21 joints each,
// exactly as Vision reports them, plus the face rectangle when there is one.
//
// Everything here is a fixed-size value. A frame never allocates, so the
// per-frame path can copy frames around freely.

/// The 21 joints of VNHumanHandPoseObservation, in a fixed order.
public enum Joint: Int, CaseIterable, Sendable {
    case wrist = 0
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    public static let count = 21

    /// The four joints of each finger, base to tip. Thumb first.
    public static let fingers: [[Joint]] = [
        [.thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.littleMCP, .littlePIP, .littleDIP, .littleTip],
    ]
}

public enum Chirality: UInt8, Codable, Sendable {
    case unknown = 0, left, right
}

/// One hand in one frame. Points are Vision's: normalized to the image,
/// origin bottom-left, x to the right as the camera sees it (not mirrored).
/// Lanes 21...31 of each vector are unused and stay zero.
public struct Hand: Sendable, Equatable {
    public var x = SIMD32<Float>()
    public var y = SIMD32<Float>()
    public var confidence = SIMD32<Float>()
    public var chirality: Chirality = .unknown

    public init() {}

    @inline(__always) public subscript(_ j: Joint) -> (x: Float, y: Float) {
        (x[j.rawValue], y[j.rawValue])
    }

    /// Fills in finger joints the camera lost (near-zero confidence, often a fingertip behind
    /// the hand or in front of the face) by continuing the finger's last segment, so a hand
    /// with one hidden fingertip is still a hand. Knuckles and the wrist are never invented.
    @inline(__always) public mutating func fillMissingJoints(below threshold: Float = 0.05) {
        var base = 1
        while base <= 17 { // thumb CMC, then each knuckle
            var j = base + 1
            while j <= base + 3 {
                if confidence[j] < threshold {
                    let parent = j - 1
                    let grand = parent == base ? 0 : parent - 1
                    x[j] = x[parent] + (x[parent] - x[grand]) * 0.7
                    y[j] = y[parent] + (y[parent] - y[grand]) * 0.7
                    confidence[j] = threshold
                }
                j += 1
            }
            base += 4
        }
    }

    @inline(__always) public mutating func set(_ j: Joint, _ px: Float, _ py: Float, confidence c: Float = 1) {
        x[j.rawValue] = px
        y[j.rawValue] = py
        confidence[j.rawValue] = c
    }
}

/// A face rectangle in Vision's normalized image coordinates. Only the
/// rectangle: never landmarks, never identity.
public struct FaceBox: Sendable, Equatable, Codable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Up to two hands and the latest face rectangle, at one camera timestamp.
public struct Frame: Sendable {
    /// Seconds on a monotonic clock: the camera's presentation time.
    public var time: Double
    /// Image width / height, so x and y can be put in the same units.
    public var aspect: Float
    public var handCount: Int
    public var hand0 = Hand()
    public var hand1 = Hand()
    public var hasFace = false
    public var face = FaceBox(x: 0, y: 0, width: 0, height: 0)

    public init(time: Double, aspect: Float = 4.0 / 3.0, handCount: Int = 0) {
        self.time = time
        self.aspect = aspect
        self.handCount = handCount
    }

    @inline(__always) public func hand(_ i: Int) -> Hand { i == 0 ? hand0 : hand1 }

    public mutating func setFace(_ box: FaceBox?) {
        if let box {
            hasFace = true
            face = box
        } else {
            hasFace = false
        }
    }
}

// MARK: - Small math

@inline(__always) func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }

@inline(__always) func hypot2(_ x: Float, _ y: Float) -> Float { (x * x + y * y).squareRoot() }

/// The unsigned angle between two 2D vectors, 0...π. 0 for a zero vector.
@inline(__always) func angleBetween(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) -> Float {
    let la = hypot2(ax, ay), lb = hypot2(bx, by)
    if la < 1e-6 || lb < 1e-6 { return 0 }
    let c = clamp((ax * bx + ay * by) / (la * lb), -1, 1)
    return acosApprox(c)
}

/// acos to about 1e-4 rad, without libm's slow path. Good enough for joint angles.
@inline(__always) func acosApprox(_ x: Float) -> Float {
    // Abramowitz & Stegun 4.4.45, refined.
    let a = abs(x)
    var r: Float = -0.0187293
    r = r * a + 0.0742610
    r = r * a - 0.2121144
    r = r * a + 1.5707288
    r *= (1 - a).squareRoot()
    return x < 0 ? Float.pi - r : r
}

@inline(__always) func atan2Approx(_ y: Float, _ x: Float) -> Float {
    // Max error about 0.0015 rad; plenty for orientation features.
    let ax = abs(x), ay = abs(y)
    if ax < 1e-12 && ay < 1e-12 { return 0 }
    let a = min(ax, ay) / max(ax, ay)
    let s = a * a
    var r = ((-0.0464964749 * s + 0.15931422) * s - 0.327622764) * s * a + a
    if ay > ax { r = 1.57079637 - r }
    if x < 0 { r = 3.14159274 - r }
    if y < 0 { r = -r }
    return r
}

@inline(__always) func wrapAngle(_ a: Float) -> Float {
    var v = a
    while v > .pi { v -= 2 * .pi }
    while v < -.pi { v += 2 * .pi }
    return v
}
