// Judge B as a tiny neural network: standardized shape features → one
// hidden layer → a softmax over the poses, "nothing" included. About 3,000
// multiply-adds a frame, every buffer allocated once.
//
// Trained here in plain Swift (Adam, class-balanced cross-entropy, a little
// input noise), so training runs the same on the Mac and in CI.

public struct MLPModel: Codable, Sendable, Equatable {
    public var features: [Int]
    public var mean: [Float]
    public var invStd: [Float]
    public var hidden: Int
    public var classCount: Int
    /// hidden × inputs, row-major.
    public var w1: [Float]
    public var b1: [Float]
    /// classCount × hidden, row-major.
    public var w2: [Float]
    public var b2: [Float]

    public var inputs: Int { features.count }
}

public struct MLPTrainingOptions: Sendable {
    public var hidden = 64
    public var epochs = 24
    public var batch = 128
    public var learningRate: Float = 0.003
    public var l2: Float = 1e-4
    public var inputNoise: Float = 0.08
    public var labelSmoothing: Float = 0.05
    public var seed: UInt64 = 1
    public init() {}
}

extension MLPModel {
    /// Trains on labelled feature vectors. Classes are balanced, so "nothing" (always the
    /// biggest class) doesn't drown out the gestures, nor they it.
    public static func train(examples: [(FeatureVector, Int, Float)], classCount: Int,
                             features: [Int] = Feature.classifierSet.map(\.rawValue),
                             options o: MLPTrainingOptions = MLPTrainingOptions()) -> MLPModel {
        let d = features.count, h = o.hidden, c = classCount
        let n = examples.count
        // Standardize.
        var mean = [Float](repeating: 0, count: d), sq = [Float](repeating: 0, count: d)
        for (f, _, _) in examples { for (i, fi) in features.enumerated() { mean[i] += f[fi]; sq[i] += f[fi] * f[fi] } }
        let nf = Float(max(n, 1))
        var invStd = [Float](repeating: 1, count: d)
        for i in 0..<d {
            mean[i] /= nf
            invStd[i] = 1 / max((max(sq[i] / nf - mean[i] * mean[i], 0)).squareRoot(), 0.05)
        }
        var x = [Float](repeating: 0, count: n * d)
        var y = [Int](repeating: 0, count: n)
        var sw = [Float](repeating: 1, count: n)
        var counts = [Float](repeating: 0, count: c)
        for (k, (f, label, w)) in examples.enumerated() {
            for (i, fi) in features.enumerated() { x[k * d + i] = (f[fi] - mean[i]) * invStd[i] }
            y[k] = min(label, c - 1)
            sw[k] = w
            counts[y[k]] += 1
        }
        let present = Float(counts.filter { $0 > 0 }.count)
        let classWeight = counts.map { $0 > 0 ? nf / (present * $0) : 0 }

        var rng = MLPRandom(seed: o.seed)
        var m = MLPModel(features: features, mean: mean, invStd: invStd, hidden: h, classCount: c,
                         w1: (0..<(h * d)).map { _ in rng.normal() * (2 / Float(d)).squareRoot() },
                         b1: [Float](repeating: 0, count: h),
                         w2: (0..<(c * h)).map { _ in rng.normal() * (1 / Float(h)).squareRoot() },
                         b2: [Float](repeating: 0, count: c))

        // Adam state.
        var m1 = [Float](repeating: 0, count: h * d), v1 = m1
        var mb1 = [Float](repeating: 0, count: h), vb1 = mb1
        var m2 = [Float](repeating: 0, count: c * h), v2 = m2
        var mb2 = [Float](repeating: 0, count: c), vb2 = mb2
        var g1 = [Float](repeating: 0, count: h * d), gb1 = [Float](repeating: 0, count: h)
        var g2 = [Float](repeating: 0, count: c * h), gb2 = [Float](repeating: 0, count: c)
        var input = [Float](repeating: 0, count: d)
        var hid = [Float](repeating: 0, count: h)
        var out = [Float](repeating: 0, count: c)
        var dh = [Float](repeating: 0, count: h)
        let beta1: Float = 0.9, beta2: Float = 0.999, eps: Float = 1e-8
        var step: Float = 0
        var order = Array(0..<n)

        for epoch in 0..<o.epochs {
            // Shuffle.
            for i in stride(from: n - 1, to: 0, by: -1) { order.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
            let lr = o.learningRate * (epoch < o.epochs * 2 / 3 ? 1 : 0.3)
            var start = 0
            while start < n {
                let end = min(start + o.batch, n)
                for i in 0..<g1.count { g1[i] = 0 }
                for i in 0..<h { gb1[i] = 0 }
                for i in 0..<g2.count { g2[i] = 0 }
                for i in 0..<c { gb2[i] = 0 }
                var batchWeight: Float = 0
                for bi in start..<end {
                    let k = order[bi]
                    for i in 0..<d { input[i] = x[k * d + i] + o.inputNoise * rng.normal() }
                    for j in 0..<h {
                        var s = m.b1[j]
                        for i in 0..<d { s += m.w1[j * d + i] * input[i] }
                        hid[j] = max(s, 0)
                    }
                    var top: Float = -.greatestFiniteMagnitude
                    for q in 0..<c {
                        var s = m.b2[q]
                        for j in 0..<h { s += m.w2[q * h + j] * hid[j] }
                        out[q] = s
                        top = max(top, s)
                    }
                    var z: Float = 0
                    for q in 0..<c { out[q] = expf(out[q] - top); z += out[q] }
                    let weight = classWeight[y[k]] * sw[k]
                    batchWeight += weight
                    // dLoss/dlogit = p - target (smoothed), times the example's weight.
                    for q in 0..<c {
                        let target: Float = (q == y[k] ? 1 - o.labelSmoothing : 0) + o.labelSmoothing / Float(c)
                        out[q] = (out[q] / z - target) * weight
                    }
                    for j in 0..<h { dh[j] = 0 }
                    for q in 0..<c {
                        gb2[q] += out[q]
                        for j in 0..<h {
                            g2[q * h + j] += out[q] * hid[j]
                            dh[j] += out[q] * m.w2[q * h + j]
                        }
                    }
                    for j in 0..<h where hid[j] > 0 {
                        gb1[j] += dh[j]
                        for i in 0..<d { g1[j * d + i] += dh[j] * input[i] }
                    }
                }
                step += 1
                let scale = 1 / max(batchWeight, 1e-6)
                let c1 = 1 - powf(beta1, step), c2 = 1 - powf(beta2, step)
                func adam(_ w: inout [Float], _ g: [Float], _ mm: inout [Float], _ vv: inout [Float], decay: Bool) {
                    for i in 0..<w.count {
                        let gi = g[i] * scale + (decay ? o.l2 * w[i] : 0)
                        mm[i] = beta1 * mm[i] + (1 - beta1) * gi
                        vv[i] = beta2 * vv[i] + (1 - beta2) * gi * gi
                        w[i] -= lr * (mm[i] / c1) / ((vv[i] / c2).squareRoot() + eps)
                    }
                }
                adam(&m.w1, g1, &m1, &v1, decay: true)
                adam(&m.b1, gb1, &mb1, &vb1, decay: false)
                adam(&m.w2, g2, &m2, &v2, decay: true)
                adam(&m.b2, gb2, &mb2, &vb2, decay: false)
                start = end
            }
        }
        return m
    }
}

struct MLPRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func normal() -> Float {
        let u1 = max(uniform(), 1e-7), u2 = uniform()
        return (-2 * logf(u1)).squareRoot() * cosf(2 * .pi * u2)
    }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs an `MLPModel` with every buffer allocated up front.
final class MLPRunner {
    let d: Int, h: Int, c: Int
    private let w1, b1, w2, b2, mean, invStd, input, hid: UnsafeMutablePointer<Float>
    let out: UnsafeMutablePointer<Float>
    private let feat: UnsafeMutablePointer<Int32>

    init(_ m: MLPModel) {
        d = m.inputs
        h = m.hidden
        c = m.classCount
        func copy(_ a: [Float]) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(a.count, 1))
            for (i, v) in a.enumerated() { p[i] = v }
            return p
        }
        w1 = copy(m.w1)
        b1 = copy(m.b1)
        w2 = copy(m.w2)
        b2 = copy(m.b2)
        mean = copy(m.mean)
        invStd = copy(m.invStd)
        input = .allocate(capacity: max(d, 1))
        hid = .allocate(capacity: max(h, 1))
        out = .allocate(capacity: max(c, 1))
        feat = .allocate(capacity: max(d, 1))
        for i in 0..<d { feat[i] = Int32(m.features[i]) }
    }

    deinit {
        for p in [w1, b1, w2, b2, mean, invStd, input, hid, out] { p.deallocate() }
        feat.deallocate()
    }

    /// Fills `out` with class probabilities.
    @inline(__always)
    func run(_ f: FeatureVector) {
        for i in 0..<d { input[i] = (f[Int(feat[i])] - mean[i]) * invStd[i] }
        var row = w1
        for j in 0..<h {
            var s = b1[j]
            for i in 0..<d { s += row[i] * input[i] }
            hid[j] = s > 0 ? s : 0
            row += d
        }
        var top: Float = -.greatestFiniteMagnitude
        row = w2
        for q in 0..<c {
            var s = b2[q]
            for j in 0..<h { s += row[j] * hid[j] }
            out[q] = s
            if s > top { top = s }
            row += h
        }
        var z: Float = 0
        for q in 0..<c {
            out[q] = expf(out[q] - top)
            z += out[q]
        }
        let inv = 1 / z
        for q in 0..<c { out[q] *= inv }
    }
}
