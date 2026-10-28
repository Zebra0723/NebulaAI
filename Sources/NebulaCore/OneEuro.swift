// The One Euro filter (Casiez, Roussel & Vogel, CHI 2012): smooths jitter
// when the hand is slow and gets out of the way when it's fast, so a moving
// hand isn't trailed by its own smoothing.

public struct OneEuroParameters: Codable, Sendable, Equatable {
    /// Cutoff at rest, Hz. Lower is smoother when still.
    public var minCutoff: Float
    /// How quickly the cutoff opens with speed. Higher is less lag when moving.
    public var beta: Float
    /// Cutoff for the derivative, Hz.
    public var derivativeCutoff: Float

    /// Tuned for low lag at speed: at 2 palm lengths per second the cutoff is
    /// already above 30 Hz, so the filter adds well under one frame of delay. The
    /// speed estimate itself is smoothed at 10 Hz (a 16 ms time constant): slower
    /// smoothing would let a swipe "complete" a tenth of a second after the hand stopped.
    public static let lowLag = OneEuroParameters(minCutoff: 1.7, beta: 0.35, derivativeCutoff: 10)

    public init(minCutoff: Float, beta: Float, derivativeCutoff: Float) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }
}

public struct OneEuroFilter: Sendable {
    public var parameters: OneEuroParameters
    private var lastTime: Double = -1
    private var x: Float = 0
    private(set) public var derivative: Float = 0

    public init(_ parameters: OneEuroParameters = .lowLag) {
        self.parameters = parameters
    }

    public var hasValue: Bool { lastTime >= 0 }
    public var value: Float { x }

    public mutating func reset() {
        lastTime = -1
        derivative = 0
    }

    @inline(__always)
    static func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    /// Filters `raw` at time `t` (seconds). `scale` normalizes the speed that opens
    /// the cutoff (pass the palm size so "fast" means the same near and far).
    @inline(__always)
    public mutating func filter(_ raw: Float, at t: Double, scale: Float = 1) -> Float {
        guard lastTime >= 0 else {
            lastTime = t
            x = raw
            derivative = 0
            return raw
        }
        let dt = Float(max(t - lastTime, 1e-4))
        lastTime = t
        let rawDerivative = (raw - x) / dt
        let ad = Self.alpha(cutoff: parameters.derivativeCutoff, dt: dt)
        derivative += ad * (rawDerivative - derivative)
        let speed = abs(derivative) / max(scale, 1e-4)
        let cutoff = parameters.minCutoff + parameters.beta * speed * 10
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        x += a * (raw - x)
        return x
    }

    /// Where the value will be `horizon` seconds from now, from the current trend:
    /// scroll and pointer track the hand instead of trailing it.
    @inline(__always)
    public func predicted(_ horizon: Float) -> Float { x + derivative * horizon }
}
