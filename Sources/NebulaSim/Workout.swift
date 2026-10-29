// Galaxy Trainer's workouts: a simulated hand in front of Nebula.
//
// The trainer sends a workout (which gestures to drill, the real-world conditions to
// make them in, the everyday movements that must not fire, how few textbook gestures
// to allow). This turns it into simulated sessions (a person at a desk, sloppy the way
// real hands are) and runs them through Nebula's real recognizer, frame by frame, the
// same way a recording is scored. Round after round, each with new hands, until the
// time is up. Nothing touches the camera, and nothing here acts.

import Foundation
import NebulaCore

/// A workout as Galaxy Trainer writes it (see NovaAI galaxy/TRAINER_NEBULA.md).
public struct WorkoutSpec: Codable, Sendable {
    public struct Focus: Codable, Sendable {
        public var gesture: String
        public var weight: Double?
        public var why: String?
    }
    public struct Condition: Codable, Sendable {
        public var name: String
        public var amount: Double?
    }
    public struct Mix: Codable, Sendable {
        public var perfect: Double?
    }
    public var type: String?
    public var minutes: Double?
    public var sessionId: String?
    public var focus: [Focus]
    public var conditions: [Condition]?
    public var negatives: [String]?
    public var mix: Mix?
    public var difficulty: String?
}

/// What Nebula reports back: per gesture, how it did, and where it did worst.
public struct WorkoutResults: Codable, Sendable {
    public struct GestureResult: Codable, Sendable {
        public var name: String
        public var accuracy: Double
        public var samples: Int
        public var falseFires: Int
        public var missed: Int
        public var worstConditions: [String]
    }
    public struct Negative: Codable, Sendable {
        public var name: String
        public var falseFires: Int
        public var samples: Int
    }
    public struct ModelChange: Codable, Sendable {
        public var replaced: Bool
        public var before: Double
        public var after: Double
        public init(replaced: Bool, before: Double, after: Double) {
            self.replaced = replaced
            self.before = before
            self.after = after
        }
    }
    public var overall: Double
    public var rounds: Int
    public var gestures: [GestureResult]
    public var negatives: [Negative]
    public var model: ModelChange?
    public var notes: String
}

public enum Workout {
    /// The labels the simulator can perform, for each gesture name the trainer may use.
    static func labels(for gesture: String) -> [String] {
        switch gesture {
        case "volumeKnob": return ["volumeUp", "volumeDown"]
        case "volumeUp", "volumeDown": return [gesture]
        default: return SynthCorpus.gestureLabels.contains(gesture) ? [gesture] : []
        }
    }

    /// The hand a condition describes. Every hand is a little sloppy; the condition makes it worse in its own way.
    public static func options(for condition: WorkoutSpec.Condition?, sloppy: Bool) -> SynthOptions {
        var o = SynthOptions()
        o.fps = 30
        guard sloppy else { return o }
        // The baseline real hand: shakier, a bit lazy, sometimes quick.
        o.tremor = 1.8
        o.halfFormed = 0.12
        o.wristTurn = 4
        o.dropout = 0.02
        guard let c = condition else { return o }
        let a = Float(min(max(c.amount ?? 0.5, 0), 1))
        let name = c.name.lowercased()
        if name.contains("blur") || name.contains("fast") || name.contains("hurr") {
            o.speed = 1 + 1.2 * Double(a)
            o.tremor += 1.5 * a
        }
        if name.contains("slow") { o.speed = 1 - 0.45 * Double(a) }
        if name.contains("light") || name.contains("dark") || name.contains("dim") {
            o.jointNoise = 1 + 2.5 * a
            o.dropout += 0.1 * a
        }
        if name.contains("occlu") || name.contains("cut") || name.contains("hidden") {
            o.dropout += 0.25 * a
        }
        if name.contains("edge") || name.contains("frame") {
            o.edge = 0.4 + 0.5 * a
            o.dropout += 0.08 * a
        }
        if name.contains("angle") || name.contains("wrist") || name.contains("turn") || name.contains("tilt") {
            o.wristTurn += 22 * a
        }
        if name.contains("tremor") || name.contains("shak") {
            o.tremor += 4 * a
        }
        if name.contains("half") || name.contains("lazy") || name.contains("sloppy") || name.contains("partial") {
            o.halfFormed = min(0.12 + 0.4 * a, 0.6)
        }
        return o
    }

    static func distance(for condition: WorkoutSpec.Condition?, _ g: inout SplitMix) -> Int {
        let name = condition?.name.lowercased() ?? ""
        if name.contains("far") { return 105 }
        if name.contains("close") || name.contains("near") { return 35 }
        return [45, 60, 75, 90][Int.random(in: 0..<4, using: &g)]
    }

    /// One round of sessions for one condition: the focus gestures (weighted), every other
    /// gesture once (so nothing else gets worse unseen), near misses, and everyday movement.
    public static func sessions(_ spec: WorkoutSpec, condition: WorkoutSpec.Condition?, perfect: Bool, seed: UInt64) -> [Recording] {
        var g = SplitMix(seed: seed)
        let left = condition?.name.lowercased().contains("left") ?? false || g.chance(0.3)
        let opts = options(for: condition, sloppy: !perfect)
        let dist = distance(for: condition, &g)
        let tag = perfect ? "textbook" : (condition?.name ?? "everyday sloppy")

        var order: [String] = []
        let total = spec.focus.reduce(0) { $0 + max($1.weight ?? 1, 0.05) }
        for f in spec.focus {
            let reps = max(2, Int((Double(18) * max(f.weight ?? 1, 0.05) / max(total, 0.05)).rounded()))
            for _ in 0..<reps { order += labels(for: f.gesture).prefix(1) }
            if f.gesture == "volumeKnob" { for _ in 0..<reps / 2 { order.append("volumeDown") } }
        }
        order += SynthCorpus.gestureLabels
        var b = SessionBuilder(seed: seed &+ 1, options: opts, left: left, distanceCm: dist)
        b.rest(1)
        order.shuffle(using: &b.g)
        for label in order {
            b.perform(label)
            b.rest(Double(b.g.uniform(0.6, 1.4)))
        }
        let gestures = b.finish(SessionInfo(id: "workout-\(seed)-g", kind: .gestures, lighting: tag, distanceCm: dist,
                                            hands: left ? "left" : "right", notes: "workout", role: .test))

        var m = SessionBuilder(seed: seed &+ 2, options: opts, left: left, distanceCm: dist)
        for _ in 0..<10 { m.nearMiss(); m.rest(0.5) }
        let misses = m.finish(SessionInfo(id: "workout-\(seed)-m", kind: .nearMiss, lighting: tag, distanceCm: dist, notes: "workout", role: .test))

        var n = SessionBuilder(seed: seed &+ 3, options: opts, left: left, distanceCm: dist)
        while n.time < 45 { n.activity() }
        let everyday = n.finish(SessionInfo(id: "workout-\(seed)-n", kind: .nothing, lighting: tag, distanceCm: dist, notes: "workout", role: .test))
        return [gestures, misses, everyday]
    }

    /// Runs the workout until `deadline` (or `stop()` says to), round after round, with a new
    /// hand and new seed each time. Every condition gets its own sessions so the results can
    /// say which conditions each gesture does worst in.
    public static func run(_ spec: WorkoutSpec, model: NebulaModel, customs: [CustomGesture] = [], seed: UInt64,
                           deadline: Date, stop: () -> Bool = { false }) -> (results: WorkoutResults, corpus: [Recording]) {
        let conditions: [WorkoutSpec.Condition?] = (spec.conditions?.isEmpty ?? true) ? [nil] : spec.conditions!.map { $0 }
        let perfectShare = min(max(spec.mix?.perfect ?? 0.1, 0), 0.5)
        var perCondition: [String: [String: (hit: Int, n: Int)]] = [:]
        var totals: [String: (hit: Int, n: Int, wrong: Int)] = [:]
        var everydayFalse = 0, everydaySeconds = 0.0, missFalse = 0, missSamples = 0
        var corpus: [Recording] = []
        var rounds = 0
        var s = seed
        while Date() < deadline && !stop() && rounds < 400 {
            rounds += 1
            for (i, condition) in conditions.enumerated() {
                if Date() >= deadline || stop() { break }
                s = s &+ 7919
                // Textbook hands only now and then: most of a workout is the messy real thing.
                let perfect = Double((rounds * 31 + i * 17) % 100) / 100 < perfectShare
                let recs = sessions(spec, condition: condition, perfect: perfect, seed: s)
                let e = Evaluator.evaluate(recs, model: model, customs: customs)
                let key = perfect ? "textbook" : (condition?.name ?? "everyday sloppy")
                for (name, score) in e.scores {
                    var c = perCondition[key, default: [:]][name] ?? (0, 0)
                    c.hit += score.recognized
                    c.n += score.examples
                    perCondition[key, default: [:]][name] = c
                    var t = totals[name] ?? (0, 0, 0)
                    t.hit += score.recognized
                    t.n += score.examples
                    t.wrong += score.wrongFires
                    totals[name] = t
                }
                for f in e.falseFires {
                    if f.context.hasPrefix("nearMiss") { missFalse += 1 } else { everydayFalse += 1 }
                }
                missSamples += recs[1].labels.count
                everydaySeconds += recs[2].frames.last.map { $0.time } ?? 0
                // Keep a few rounds' sloppy sessions to learn from afterwards.
                if !perfect && corpus.count < 60 { corpus += recs }
            }
        }
        var gestures: [WorkoutResults.GestureResult] = []
        for (name, t) in totals.sorted(by: { $0.key < $1.key }) where t.n > 0 {
            let worst = perCondition
                .compactMap { (cond, scores) -> (String, Double)? in
                    guard let c = scores[name], c.n > 0 else { return nil }
                    return (cond, Double(c.hit) / Double(c.n))
                }
                .sorted { $0.1 < $1.1 }
                .prefix(2)
                .filter { $0.1 < Double(t.hit) / Double(t.n) }
                .map { $0.0 }
            gestures.append(WorkoutResults.GestureResult(name: name, accuracy: Double(t.hit) / Double(t.n), samples: t.n,
                                                         falseFires: t.wrong, missed: t.n - t.hit, worstConditions: Array(worst)))
        }
        let hits = totals.values.reduce(0) { $0 + $1.hit }
        let n = totals.values.reduce(0) { $0 + $1.n }
        let results = WorkoutResults(
            overall: n == 0 ? 0 : Double(hits) / Double(n),
            rounds: rounds,
            gestures: gestures,
            negatives: [
                WorkoutResults.Negative(name: "everyday movement (\(Int(everydaySeconds / 60)) min)", falseFires: everydayFalse, samples: Int(everydaySeconds)),
                WorkoutResults.Negative(name: "near misses", falseFires: missFalse, samples: missSamples),
            ],
            model: nil,
            notes: ""
        )
        return (results, corpus)
    }

    /// A fixed set of sloppy sessions, the same every time, to compare two models fairly.
    public static func benchmark(seed: UInt64 = 0x4E42_5452) -> [Recording] {
        let spec = WorkoutSpec(type: "benchmark", minutes: nil, sessionId: nil,
                               focus: SynthCorpus.gestureLabels.map { WorkoutSpec.Focus(gesture: $0, weight: 1, why: nil) },
                               conditions: nil, negatives: nil, mix: nil, difficulty: nil)
        let conditions: [WorkoutSpec.Condition?] = [
            nil,
            WorkoutSpec.Condition(name: "off-angle", amount: 0.6),
            WorkoutSpec.Condition(name: "motion blur", amount: 0.6),
            WorkoutSpec.Condition(name: "low light", amount: 0.6),
            WorkoutSpec.Condition(name: "frame edge", amount: 0.5),
            WorkoutSpec.Condition(name: "half-formed", amount: 0.6),
        ]
        var out: [Recording] = []
        for (i, c) in conditions.enumerated() { out += sessions(spec, condition: c, perfect: false, seed: seed &+ UInt64(i * 101)) }
        return out
    }
}
