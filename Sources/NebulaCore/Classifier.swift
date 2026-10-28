// Judge B: a small, fast classifier that knows what "nothing" looks like.
//
// k nearest neighbours over standardized shape features, with a "nothing"
// class trained on ordinary hand movement and near-misses. It is
// deliberately simple: it learns from your own examples instantly (personal
// calibration just adds prototypes), it is fully inspectable, and a frame
// costs tens of microseconds. A query far from everything it has seen
// is "nothing", however its neighbours vote.

public struct ClassifierModel: Codable, Sendable, Equatable {
    /// Feature indices used, in order.
    public var features: [Int]
    public var mean: [Float]
    public var invStd: [Float]
    /// Prototypes, row-major: count × features.count.
    public var points: [Float]
    public var labels: [UInt8]
    /// Per-prototype vote weight (personal examples count for more).
    public var weights: [Float]
    public var k: Int
    /// Kernel width in standardized units.
    public var bandwidth: Float
    /// Nearest-prototype distance beyond which the answer is "nothing".
    public var maxDistance: Float
    public var classCount: Int
    /// When set, Judge B is this small network instead of nearest neighbours.
    public var mlp: MLPModel?

    public var dims: Int { features.count }
    public var count: Int { labels.count }

    public init(features: [Int], mean: [Float], invStd: [Float], points: [Float], labels: [UInt8],
                weights: [Float], k: Int, bandwidth: Float, maxDistance: Float, classCount: Int, mlp: MLPModel? = nil) {
        self.features = features
        self.mean = mean
        self.invStd = invStd
        self.points = points
        self.labels = labels
        self.weights = weights
        self.k = k
        self.bandwidth = bandwidth
        self.maxDistance = maxDistance
        self.classCount = classCount
        self.mlp = mlp
    }

    /// Builds a model from labelled feature vectors: standardizes, then keeps up
    /// to `perClass` prototypes per class, spread evenly through the examples.
    public static func train(examples: [(FeatureVector, Int, Float)], classCount: Int, k: Int = 9,
                             perClass: Int = 600, features: [Int] = Feature.classifierSet.map(\.rawValue)) -> ClassifierModel {
        let d = features.count
        var mean = [Float](repeating: 0, count: d)
        var sq = [Float](repeating: 0, count: d)
        for (f, _, _) in examples {
            for (i, fi) in features.enumerated() {
                mean[i] += f[fi]
                sq[i] += f[fi] * f[fi]
            }
        }
        let n = Float(max(examples.count, 1))
        var invStd = [Float](repeating: 1, count: d)
        for i in 0..<d {
            mean[i] /= n
            let variance = max(sq[i] / n - mean[i] * mean[i], 0)
            // A floor, so a feature that barely varies in training can't dominate distances.
            invStd[i] = 1 / max(variance.squareRoot(), 0.05)
        }
        // Weight each feature by how well it separates the classes (Fisher's ratio of
        // between-class to within-class variance), so the one feature that tells a V from
        // two fingers together isn't drowned out by thirty that don't care.
        var classMean = [[Float]](repeating: [Float](repeating: 0, count: d), count: classCount)
        var classN = [Float](repeating: 0, count: classCount)
        for (f, c, _) in examples where c < classCount {
            classN[c] += 1
            for (i, fi) in features.enumerated() { classMean[c][i] += (f[fi] - mean[i]) * invStd[i] }
        }
        for c in 0..<classCount where classN[c] > 0 { for i in 0..<d { classMean[c][i] /= classN[c] } }
        var within = [Float](repeating: 0, count: d)
        var between = [Float](repeating: 0, count: d)
        for (f, c, _) in examples where c < classCount {
            for (i, fi) in features.enumerated() {
                let z = (f[fi] - mean[i]) * invStd[i] - classMean[c][i]
                within[i] += z * z
            }
        }
        for c in 0..<classCount where classN[c] > 0 {
            for i in 0..<d { between[i] += classN[c] * classMean[c][i] * classMean[c][i] }
        }
        var weight = (0..<d).map { i -> Float in (between[i] / max(within[i], 1e-6)).squareRoot() }
        let meanWeight = weight.reduce(0, +) / Float(max(d, 1))
        weight = weight.map { min(max($0 / max(meanWeight, 1e-6), 0.25), 4) }
        for i in 0..<d { invStd[i] *= weight[i] }

        var byClass = [[Int]](repeating: [], count: classCount)
        for (i, e) in examples.enumerated() where e.1 < classCount { byClass[e.1].append(i) }
        var points: [Float] = []
        var labels: [UInt8] = []
        var weights: [Float] = []
        for (c, idx) in byClass.enumerated() where !idx.isEmpty {
            let step = max(1, Double(idx.count) / Double(perClass))
            var pos = 0.0
            while Int(pos) < idx.count {
                let (f, _, w) = examples[idx[Int(pos)]]
                for (i, fi) in features.enumerated() { points.append((f[fi] - mean[i]) * invStd[i]) }
                labels.append(UInt8(c))
                weights.append(w)
                pos += step
            }
        }
        var model = ClassifierModel(features: features, mean: mean, invStd: invStd, points: points, labels: labels,
                                    weights: weights, k: k, bandwidth: 1, maxDistance: .greatestFiniteMagnitude,
                                    classCount: classCount)
        model.calibrateDistances()
        return model
    }

    /// Sets the kernel width from typical neighbour distances, and the "too far
    /// from anything" cut-off from the far tail of them.
    public mutating func calibrateDistances() {
        let n = count, d = dims
        guard n > 1 else { return }
        var nearest: [Float] = []
        let stride = max(1, n / 400)
        var i = 0
        while i < n {
            var best = Float.greatestFiniteMagnitude
            for j in 0..<n where j != i {
                var s: Float = 0
                for q in 0..<d {
                    let diff = points[i * d + q] - points[j * d + q]
                    s += diff * diff
                }
                if s < best { best = s }
            }
            nearest.append(best.squareRoot())
            i += stride
        }
        nearest.sort()
        let median = nearest[nearest.count / 2]
        bandwidth = max(median * 2, 0.3)
        maxDistance = max(nearest[min(nearest.count - 1, Int(Double(nearest.count) * 0.995))] * 3, 2.5)
    }

    /// Adds labelled examples (personal calibration) as prototypes, without retraining.
    public mutating func add(_ examples: [(FeatureVector, Int)], weight: Float) {
        for (f, c) in examples {
            for (i, fi) in features.enumerated() { points.append((f[fi] - mean[i]) * invStd[i]) }
            labels.append(UInt8(c))
            weights.append(weight)
            if c >= classCount { classCount = c + 1 }
        }
    }
}

public struct Classification: Sendable, Equatable {
    public var top: Int = 0
    public var confidence: Float = 0
    /// Top score minus second-best score.
    public var margin: Float = 0
    public var nearest: Float = .greatestFiniteMagnitude
    public init() {}
}

/// Runs a `ClassifierModel` with every buffer allocated up front.
public final class Classifier {
    public let model: ClassifierModel
    private let query: UnsafeMutablePointer<Float>
    private let scores: UnsafeMutablePointer<Float>
    private let bestD: UnsafeMutablePointer<Float>
    private let bestI: UnsafeMutablePointer<Int32>
    private let pts: UnsafeMutablePointer<Float>
    private let lab: UnsafeMutablePointer<UInt8>
    private let wts: UnsafeMutablePointer<Float>
    private let mean: UnsafeMutablePointer<Float>
    private let invStd: UnsafeMutablePointer<Float>
    private let feat: UnsafeMutablePointer<Int32>
    private let n: Int, d: Int, k: Int, classes: Int
    private let invBandwidth2: Float
    private let maxDistance2: Float
    private let mlp: MLPRunner?

    public init(_ model: ClassifierModel) {
        self.model = model
        mlp = model.mlp.map(MLPRunner.init)
        n = model.count
        d = model.dims
        k = max(1, min(model.k, 32, max(n, 1)))
        classes = max(model.classCount, model.mlp?.classCount ?? 0, 1)
        query = .allocate(capacity: max(d, 1))
        scores = .allocate(capacity: classes)
        bestD = .allocate(capacity: 32)
        bestI = .allocate(capacity: 32)
        pts = .allocate(capacity: max(n * d, 1))
        lab = .allocate(capacity: max(n, 1))
        wts = .allocate(capacity: max(n, 1))
        mean = .allocate(capacity: max(d, 1))
        invStd = .allocate(capacity: max(d, 1))
        feat = .allocate(capacity: max(d, 1))
        invBandwidth2 = 1 / max(model.bandwidth * model.bandwidth, 1e-6)
        maxDistance2 = model.maxDistance >= .greatestFiniteMagnitude ? .greatestFiniteMagnitude : model.maxDistance * model.maxDistance
        let (pts, lab, wts, n, d) = (self.pts, self.lab, self.wts, self.n, self.d)
        model.points.withUnsafeBufferPointer { if n * d > 0 { pts.initialize(from: $0.baseAddress!, count: n * d) } }
        model.labels.withUnsafeBufferPointer { if n > 0 { lab.initialize(from: $0.baseAddress!, count: n) } }
        model.weights.withUnsafeBufferPointer { if n > 0 { wts.initialize(from: $0.baseAddress!, count: n) } }
        for i in 0..<d {
            mean[i] = model.mean[i]
            invStd[i] = model.invStd[i]
            feat[i] = Int32(model.features[i])
        }
    }

    deinit {
        for p in [query, scores, bestD, pts, wts, mean, invStd] { p.deallocate() }
        bestI.deallocate()
        lab.deallocate()
        feat.deallocate()
    }

    /// The score `classify` gave class `c` (a fraction of the vote).
    @inline(__always) public func score(_ c: Int) -> Float { c < classes ? scores[c] : 0 }

    @inline(__always)
    public func classify(_ f: FeatureVector) -> Classification {
        var out = Classification()
        for c in 0..<classes { scores[c] = 0 }
        if let mlp {
            mlp.run(f)
            var top = 0, best: Float = -1, second: Float = 0
            for c in 0..<mlp.c {
                let p = mlp.out[c]
                scores[c] = p
                if p > best {
                    second = max(second, best)
                    best = p
                    top = c
                } else if p > second {
                    second = p
                }
            }
            out.top = top
            out.confidence = best
            out.margin = best - second
            return out
        }
        guard n > 0 else { out.confidence = 1; scores[0] = 1; return out }
        for i in 0..<d { query[i] = (f[Int(feat[i])] - mean[i]) * invStd[i] }
        var filled = 0
        var worst = Float.greatestFiniteMagnitude
        var row = pts
        for i in 0..<n {
            var s: Float = 0
            for q in 0..<d {
                let diff = row[q] - query[q]
                s += diff * diff
            }
            row += d
            if filled < k || s < worst {
                // Insertion into the small sorted list of the k best.
                var pos = filled < k ? filled : k - 1
                while pos > 0 && bestD[pos - 1] > s {
                    bestD[pos] = bestD[pos - 1]
                    bestI[pos] = bestI[pos - 1]
                    pos -= 1
                }
                bestD[pos] = s
                bestI[pos] = Int32(i)
                if filled < k { filled += 1 }
                worst = filled == k ? bestD[k - 1] : .greatestFiniteMagnitude
            }
        }
        out.nearest = bestD[0].squareRoot()
        if bestD[0] > maxDistance2 {
            // Unlike anything it was trained on: not a gesture.
            scores[0] = 1
            out.top = 0
            out.confidence = 1
            out.margin = 1
            return out
        }
        var total: Float = 0
        for j in 0..<filled {
            let i = Int(bestI[j])
            let w = wts[i] / (1 + bestD[j] * invBandwidth2)
            scores[Int(lab[i])] += w
            total += w
        }
        var top = 0, second: Float = 0, best: Float = -1
        for c in 0..<classes {
            scores[c] /= max(total, 1e-9)
            if scores[c] > best {
                second = max(second, best)
                best = scores[c]
                top = c
            } else if scores[c] > second {
                second = scores[c]
            }
        }
        out.top = top
        out.confidence = best
        out.margin = best - max(second, 0)
        return out
    }
}
