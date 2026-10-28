// Training Judge B, tuning thresholds for precision first, and personal
// calibration. Sessions are split whole: a session is used to train, to
// tune or to test, never more than one.

import Foundation

public enum Trainer {
    /// Roles for sessions that don't have one yet: three in four train, then alternate
    /// validation and test, per kind, so every kind of footage reaches every split.
    public static func assignRoles(_ recordings: [Recording]) -> [Recording] {
        var counters: [SessionInfo.Kind: Int] = [:]
        return recordings.map { rec in
            var rec = rec
            if rec.info.role == nil {
                let n = counters[rec.info.kind, default: 0]
                counters[rec.info.kind] = n + 1
                rec.info.role = [SessionInfo.Role.train, .validation, .train, .test][n % 4]
            }
            return rec
        }
    }

    public static func split(_ recordings: [Recording]) -> (train: [Recording], validation: [Recording], test: [Recording]) {
        let r = assignRoles(recordings).filter { $0.info.kind != .enrollment }
        return (r.filter { $0.info.role == .train }, r.filter { $0.info.role == .validation }, r.filter { $0.info.role == .test })
    }

    /// Which pose a frame inside a window of `label` shows, if it clearly shows it.
    static func poseLabel(for label: SegmentLabel) -> Pose? {
        guard let g = label.expected else { return nil }
        return g.pose
    }

    /// Labelled feature vectors for Judge B. Inside a gesture window, a frame is an example
    /// of the gesture's pose only where Judge A agrees it is that pose (the rest of the
    /// window is the hand arriving and leaving, which teaches nothing). Everything outside
    /// gesture windows, and all nothing and near-miss footage, is "nothing".
    public static func examples(from recordings: [Recording], model: NebulaModel, customs: [CustomGesture] = [],
                                weight: Float = 1) -> [(FeatureVector, Int, Float)] {
        let rules = CompiledRules(model.poseRules() + customs.map(\.rule))
        var out: [(FeatureVector, Int, Float)] = []
        let customIndex = Dictionary(uniqueKeysWithValues: customs.enumerated().map { ($1.id, $0) })
        for rec in recordings {
            let r = Recognizer(model: model, customs: customs)
            let windows = rec.labels.filter { !$0.isNegative }
            for frame in rec.frames {
                let o = r.observe(frame)
                guard o.valid && !o.partial else { continue }
                let w = windows.first { frame.time >= $0.start && frame.time <= $0.end }
                if let w {
                    var pose: Int?
                    if let p = poseLabel(for: w) { pose = p.rawValue }
                    if let ci = customIndex[w.gesture] { pose = customs[ci].label }
                    guard var p = pose else { continue }
                    var score = rules.score(p, o.features)
                    // A swipe or wave hand that isn't held flat is still an open hand.
                    if p == Pose.flat.rawValue || p == Pose.open.rawValue, w.expected?.kind == .movement {
                        let flat = rules.score(Pose.flat.rawValue, o.features), open = rules.score(Pose.open.rawValue, o.features)
                        p = flat >= open ? Pose.flat.rawValue : Pose.open.rawValue
                        score = max(flat, open)
                    }
                    if score >= 0.6 { out.append((o.features, p, weight)) }
                } else {
                    out.append((o.features, Pose.nothing.rawValue, weight))
                }
            }
        }
        return out
    }

    /// Trains Judge B on the training sessions; thresholds keep their defaults until `tune`.
    public enum JudgeBKind: String, Sendable { case mlp, knn }

    public static func trainClassifier(_ train: [Recording], base: NebulaModel, customs: [CustomGesture] = [],
                                       kind: JudgeBKind = .mlp, extra: [(FeatureVector, Int, Float)] = [],
                                       perClass: Int = 500, nothingCap: Int = 2500) -> ClassifierModel {
        let ex = examples(from: train, model: base, customs: customs) + extra
        let classCount = Pose.builtinCount + customs.count
        if kind == .mlp {
            let mlp = MLPModel.train(examples: ex, classCount: classCount)
            var model = Bootstrap.emptyModel().classifier
            model.classCount = classCount
            model.mlp = mlp
            return model
        }
        // "Nothing" is the most varied class, so it keeps more prototypes.
        let nothing = ex.filter { $0.1 == 0 }
        let rest = ex.filter { $0.1 != 0 }
        var thinned: [(FeatureVector, Int, Float)] = []
        let step = max(1, nothing.count / nothingCap)
        for i in stride(from: 0, to: nothing.count, by: step) { thinned.append(nothing[i]) }
        return ClassifierModel.train(examples: thinned + rest, classCount: classCount, perClass: max(perClass, nothingCap))
            .capped(perClass: perClass, nothingCap: nothingCap)
    }

    /// A fresh model: B trained on `train`, then every threshold tuned on `validation`.
    public static func train(_ train: [Recording], validation: [Recording], base: NebulaModel, source: String,
                             kind: JudgeBKind = .mlp, log: (String) -> Void = { _ in }) -> NebulaModel {
        var model = base
        model.source = source
        model.classifier = trainClassifier(train, base: base, kind: kind)
        if let mlp = model.classifier.mlp {
            log("Judge B: a \(mlp.inputs)→\(mlp.hidden)→\(mlp.classCount) network")
        } else {
            log("Judge B: \(model.classifier.count) nearest-neighbour prototypes over \(model.classifier.dims) features")
        }
        if !validation.isEmpty { model = tune(model, on: validation, log: log) }
        return model
    }

    // MARK: - Tuning

    struct Replay {
        var observations: [[Observation]]
        var times: [[Double]]
        var recordings: [Recording]
    }

    static func precompute(_ recordings: [Recording], model: NebulaModel) -> Replay {
        var obs: [[Observation]] = []
        var times: [[Double]] = []
        for rec in recordings {
            let r = Recognizer(model: model)
            obs.append(rec.frames.map { r.observe($0) })
            times.append(rec.frames.map(\.time))
        }
        return Replay(observations: obs, times: times, recordings: recordings)
    }

    static func evaluate(_ replay: Replay, model: NebulaModel) -> EvaluationResult {
        var result = EvaluationResult()
        var sums: [String: Double] = [:]
        for (i, rec) in replay.recordings.enumerated() {
            let fires = Evaluator.fires(replay.observations[i], times: replay.times[i], model: model, customs: [])
            Evaluator.score(rec, fires: fires, customs: [], into: &result, timeSums: &sums)
        }
        return result
    }

    /// Precision first, then recall: for each gesture, among the thresholds that cause no
    /// false fire and no wrong fire on the validation sessions, take the one that recognizes
    /// the most, and among those the shortest hold. A hold is lengthened only when no
    /// shorter one is clean.
    public static func tune(_ model: NebulaModel, on validation: [Recording], log: (String) -> Void = { _ in }) -> NebulaModel {
        var model = model
        let replay = precompute(validation, model: model)
        let confidences: [Float] = [0.5, 0.6, 0.7, 0.8]
        let margins: [Float] = [0.1, 0.25, 0.4]
        let holds: [Double] = [0.15, 0.2, 0.25, 0.3, 0.4, 0.5]
        for pass in 0..<2 {
            for g in Gesture.allCases where g != .swipeRight {
                var best: (key: (Int, Int, Int, Double, Float, Float), tuning: GestureTuning)?
                let current = model.tuning(for: g)
                let holdChoices = g.kind == .movement ? [current.hold] : holds
                for hold in holdChoices {
                    for c in confidences {
                        for mg in margins {
                            var trial = model
                            var t = current
                            t.hold = hold
                            t.confidence = g.kind == .movement ? c - 0.15 : c
                            t.cooldown = NebulaModel.defaultTuning(g).cooldown
                            t.margin = mg
                            trial.tuning[g.rawValue] = t
                            if g == .swipeLeft { trial.tuning[Gesture.swipeRight.rawValue] = t }
                            let e = evaluate(replay, model: trial)
                            let names = g == .swipeLeft ? ["swipeLeft", "swipeRight"] : [g.rawValue]
                            let bad = names.reduce(0) { $0 + (e.scores[$1]?.wrongFires ?? 0) }
                            let recognized = names.reduce(0) { $0 + (e.scores[$1]?.recognized ?? 0) }
                            // Fewest bad fires, then most recognized, then shortest hold, then strictest.
                            let key = (-bad, recognized, -Int(hold * 1000), 0.0, t.confidence, t.margin)
                            if best == nil || key > best!.key { best = (key, t) }
                        }
                    }
                }
                if let best {
                    model.tuning[g.rawValue] = best.tuning
                    if g == .swipeLeft { model.tuning[Gesture.swipeRight.rawValue] = best.tuning }
                    if pass == 1 {
                        log(g.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0)
                            + String(format: "hold %.2fs  B ≥ %.2f, margin ≥ %.2f  (validation: %d bad fires, %d recognized)",
                                     best.tuning.hold, best.tuning.confidence, best.tuning.margin, -best.key.0, best.key.1))
                    }
                }
            }
        }
        return model
    }

    // MARK: - Personal calibration

    /// Adapts a model to one person from about ten examples of each gesture: their examples
    /// join Judge B (counting three times as much as anyone else's), and Judge A's ranges
    /// widen to take in their hands, by no more than each condition's band.
    public static func personalize(_ model: NebulaModel, enrollment: [Recording], log: (String) -> Void = { _ in }) -> NebulaModel {
        var model = model
        // Does this camera report hands swapped? An open palm toward the camera must face it.
        var facing: [Float] = []
        for rec in enrollment {
            let r = Recognizer(model: model)
            for frame in rec.frames {
                guard let w = rec.labels.first(where: { frame.time >= $0.start && frame.time <= $0.end && $0.gesture == "openPalm" }) else { continue }
                _ = w
                let o = r.observe(frame)
                if o.valid && !o.partial { facing.append(o.features[Feature.palmFacing.rawValue]) }
            }
        }
        if facing.count >= 10 {
            let sorted = facing.sorted()
            if sorted[sorted.count / 2] < -0.2 {
                model.flipChirality.toggle()
                log("This camera reports left and right hands swapped; corrected.")
            }
        }

        let ex = examples(from: enrollment, model: model, weight: 3)
        let gestureExamples = ex.filter { $0.1 != 0 }
        model.classifier.add(gestureExamples.map { ($0.0, $0.1) }, weight: 3)
        log("Judge B: added \(gestureExamples.count) of your frames")

        var rules = model.poseRules()
        for p in 1..<rules.count {
            let mine = gestureExamples.filter { $0.1 == p }.map(\.0)
            guard mine.count >= 20 else { continue }
            var rule = rules[p]
            for (ci, c) in rule.conditions.enumerated() {
                guard let f = Feature.named(c.feature) else { continue }
                let values = mine.map { $0[f.rawValue] }.sorted()
                let lo = values[Int(Double(values.count) * 0.05)]
                let hi = values[min(values.count - 1, Int(Double(values.count) * 0.95))]
                if let m = c.min, lo < m {
                    rule.conditions[ci].min = max(lo, m - c.band * 0.75)
                }
                if let m = c.max, hi > m {
                    rule.conditions[ci].max = min(hi, m + c.band * 0.75)
                }
            }
            if rule != rules[p] {
                model.rules[rule.name] = rule
                log("Judge A: \(rule.name) widened to fit your hand")
            }
            rules[p] = rule
        }
        model.source += " + personal"
        return model
    }
}

extension ClassifierModel {
    /// Thins each class to at most `perClass` prototypes (nothing: `nothingCap`), evenly.
    func capped(perClass: Int, nothingCap: Int) -> ClassifierModel {
        var out = self
        out.points = []
        out.labels = []
        out.weights = []
        for c in 0..<classCount {
            let idx = labels.indices.filter { Int(labels[$0]) == c }
            let cap = c == 0 ? nothingCap : perClass
            let step = max(1.0, Double(idx.count) / Double(cap))
            var pos = 0.0
            while Int(pos) < idx.count {
                let i = idx[Int(pos)]
                out.points.append(contentsOf: points[(i * dims)..<((i + 1) * dims)])
                out.labels.append(labels[i])
                out.weights.append(weights[i])
                pos += step
            }
        }
        out.calibrateDistances()
        return out
    }
}
