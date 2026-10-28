// Runs the recognizer over recorded sessions exactly as the app would, and
// scores what fired against what was labelled.
//
// An example counts as recognized only if its own gesture fires inside its
// window (a little slack after the end) and nothing else does. Every fire
// outside a gesture window, and every second fire inside one, is a false
// fire. "Armed time" is all recorded time outside gesture windows.

import Foundation

public struct Targets: Codable, Sendable {
    public var recall: Double = 0.99
    public var wrongGestureRate: Double = 0.005
    /// False fires per hour of armed "nothing" footage: 1 per 4 hours.
    public var falseFiresPerHour: Double = 0.25
    public var recognizerP95Ms: Double = 2
    public var pipelineP95Ms: Double = 10
    public var pipelineP99Ms: Double = 15
    public init() {}
}

public struct GestureScore: Codable, Sendable {
    public var gesture: String
    public var examples = 0
    public var recognized = 0
    /// Fires of this gesture that were right.
    public var correctFires = 0
    /// Fires of this gesture anywhere it wasn't wanted (other windows, armed time, double fires).
    public var wrongFires = 0
    public var recall: Double { examples == 0 ? 0 : Double(recognized) / Double(examples) }
    public var precision: Double {
        let total = correctFires + wrongFires
        return total == 0 ? 1 : Double(correctFires) / Double(total)
    }
    /// Seconds from the start of the window to the fire, for recognized examples.
    public var meanTimeToFire: Double = 0
}

public struct FalseFire: Codable, Sendable {
    public var session: String
    public var time: Double
    public var gesture: String
    /// The window it fell in, or "armed" for unlabelled time.
    public var context: String
}

public struct EvaluationResult: Codable, Sendable {
    public var sessions: [String] = []
    public var scores: [String: GestureScore] = [:]
    /// expected → (what fired first, or "none") → count.
    public var confusion: [String: [String: Int]] = [:]
    public var examples = 0
    public var wrongGesture = 0
    public var falseFires: [FalseFire] = []
    public var armedSeconds: Double = 0
    public var frames = 0
    /// Per-frame recognizer time, milliseconds.
    public var recognizer = Percentiles([])

    public var wrongGestureRate: Double { examples == 0 ? 0 : Double(wrongGesture) / Double(examples) }
    public var falseFiresPerHour: Double { armedSeconds <= 0 ? 0 : Double(falseFires.count) / (armedSeconds / 3600) }
}

public enum Evaluator {
    /// Slack after a window's end: a fire on the frame the movement completes can land just after the label.
    public static let slack = 0.25

    public static func gestureName(_ id: Int, customs: [CustomGesture]) -> String {
        if id >= Recognizer.customBase {
            let i = id - Recognizer.customBase
            return i < customs.count ? customs[i].id : "custom\(i)"
        }
        return Gesture.at(id).rawValue
    }

    struct Fire {
        var time: Double
        var id: Int
        var volume: Int
    }

    /// Runs one session through a fresh recognizer, returning fires and per-frame timings.
    static func fires(_ rec: Recording, model: NebulaModel, customs: [CustomGesture], timings: inout [Float]) -> [Fire] {
        let r = Recognizer(model: model, customs: customs)
        var out: [Fire] = []
        var engagedFire = -1
        for frame in rec.frames {
            let t0 = Monotonic.nanoseconds()
            r.process(frame)
            let t1 = Monotonic.nanoseconds()
            timings.append(Float(Double(t1 - t0) / 1e6))
            collect(r, time: frame.time, into: &out, engaged: &engagedFire)
        }
        return out
    }

    /// Replays precomputed observations (threshold tuning): no timings.
    static func fires(_ obs: [Observation], times: [Double], model: NebulaModel, customs: [CustomGesture]) -> [Fire] {
        let r = Recognizer(model: model, customs: customs)
        var out: [Fire] = []
        var engagedFire = -1
        for (i, o) in obs.enumerated() {
            r.replay(o, at: times[i])
            collect(r, time: times[i], into: &out, engaged: &engagedFire)
        }
        return out
    }

    @inline(__always)
    private static func collect(_ r: Recognizer, time: Double, into out: inout [Fire], engaged: inout Int) {
        for e in 0..<r.eventCount {
            switch r.event(e) {
            case .fired(let id):
                out.append(Fire(time: time, id: id, volume: 0))
                engaged = Gesture.at(min(id, Gesture.count - 1)).kind == .continuous && id < Recognizer.customBase ? out.count - 1 : -1
            case .volume(let step):
                if engaged >= 0 { out[engaged].volume += step }
            case .ended:
                engaged = -1
            default:
                break
            }
        }
    }

    public static func evaluate(_ recordings: [Recording], model: NebulaModel, customs: [CustomGesture] = []) -> EvaluationResult {
        var result = EvaluationResult()
        var timings: [Float] = []
        var timeSums: [String: Double] = [:]
        for rec in recordings {
            let fires = Self.fires(rec, model: model, customs: customs, timings: &timings)
            score(rec, fires: fires, customs: customs, into: &result, timeSums: &timeSums)
        }
        for (k, v) in timeSums where (result.scores[k]?.recognized ?? 0) > 0 {
            result.scores[k]!.meanTimeToFire = v / Double(result.scores[k]!.recognized)
        }
        result.recognizer = Percentiles(timings)
        return result
    }

    static func score(_ rec: Recording, fires: [Fire], customs: [CustomGesture], into result: inout EvaluationResult,
                      timeSums: inout [String: Double]) {
        result.sessions.append(rec.info.id)
        result.frames += rec.frames.count
        let windows = rec.labels.filter { !$0.isNegative }
        var used = [Bool](repeating: false, count: fires.count)
        for w in windows {
            let expected = w.expected.map(\.rawValue) ?? w.gesture
            result.examples += 1
            result.scores[expected, default: GestureScore(gesture: expected)].examples += 1
            let inWindow = fires.indices.filter { fires[$0].time >= w.start && fires[$0].time <= w.end + slack && !used[$0] }
            var hit = false
            var first = "none"
            for i in inWindow {
                used[i] = true
                let name = gestureName(fires[i].id, customs: customs)
                if first == "none" { first = name }
                var right = name == expected
                if right && !hit && (w.gesture == "volumeUp" || w.gesture == "volumeDown") {
                    right = w.gesture == "volumeUp" ? fires[i].volume > 0 : fires[i].volume < 0
                    if !right {
                        // The knob engaged but turned the volume the wrong way, or not at all: a wrong action.
                        if first == name { first = "volumeKnob (wrong way or no step)" }
                        result.scores[expected]!.wrongFires += 1
                        result.wrongGesture += 1
                        continue
                    }
                }
                if right && !hit {
                    hit = true
                    result.scores[expected]!.recognized += 1
                    result.scores[expected]!.correctFires += 1
                    timeSums[expected, default: 0] += fires[i].time - w.start
                } else {
                    result.scores[name, default: GestureScore(gesture: name)].wrongFires += 1
                    if name != expected { result.wrongGesture += 1 }
                    else { result.falseFires.append(FalseFire(session: rec.info.id, time: fires[i].time, gesture: name, context: "second fire in \(w.gesture)")) }
                }
            }
            let outcome = hit ? expected : first
            result.confusion[expected, default: [:]][outcome, default: 0] += 1
        }
        // Everything else is armed time.
        let windowTime = windows.reduce(0) { $0 + ($1.end + slack - $1.start) }
        result.armedSeconds += max(rec.duration - windowTime, 0)
        for (i, f) in fires.enumerated() where !used[i] {
            let name = gestureName(f.id, customs: customs)
            let negative = rec.labels.first { $0.isNegative && f.time >= $0.start && f.time <= $0.end }
            result.falseFires.append(FalseFire(session: rec.info.id, time: f.time, gesture: name, context: negative?.gesture ?? "armed"))
            result.scores[name, default: GestureScore(gesture: name)].wrongFires += 1
        }
    }
}

// MARK: - The report

public struct GateCheck: Codable, Sendable {
    public var name: String
    public var value: Double
    public var target: Double
    public var pass: Bool
    public var unit: String
}

public struct Report: Codable, Sendable {
    public var generatedAt: Double
    public var modelSource: String
    /// Which model these numbers are for (`NebulaModel.fingerprint`).
    public var modelFingerprint: String = ""
    public var synthetic: Bool
    public var testSessions: [String]
    public var evaluation: EvaluationResult
    public var pipeline: Percentiles?
    public var checks: [GateCheck]
    /// Gestures that met every target and may ship.
    public var passing: [String]
    public var holds: [String: Double]
    public var notes: [String]

    public var pass: Bool { checks.allSatisfy(\.pass) }

    public static func make(evaluation e: EvaluationResult, model: NebulaModel, synthetic: Bool, pipeline: Percentiles?,
                            targets: Targets = Targets(), expected: [String] = Gesture.allCases.map(\.rawValue)) -> Report {
        var checks: [GateCheck] = []
        var passing: [String] = []
        for g in expected {
            let s = e.scores[g] ?? GestureScore(gesture: g)
            let ok = s.examples > 0 && s.recall >= targets.recall
            checks.append(GateCheck(name: "recall \(g) (\(s.recognized)/\(s.examples))", value: s.recall, target: targets.recall, pass: ok, unit: "ratio"))
            let ffForG = e.falseFires.filter { $0.gesture == g }.count
            if ok && ffForG == 0 { passing.append(g) }
        }
        checks.append(GateCheck(name: "wrong-gesture rate", value: e.wrongGestureRate, target: targets.wrongGestureRate,
                                pass: e.wrongGestureRate <= targets.wrongGestureRate, unit: "ratio"))
        checks.append(GateCheck(name: "false fires per armed hour (\(e.falseFires.count) in \(String(format: "%.1f", e.armedSeconds / 60)) min)",
                                value: e.falseFiresPerHour, target: targets.falseFiresPerHour,
                                pass: e.armedSeconds > 0 && e.falseFiresPerHour <= targets.falseFiresPerHour, unit: "/h"))
        checks.append(GateCheck(name: "recognizer per-frame p95", value: e.recognizer.p95, target: targets.recognizerP95Ms,
                                pass: e.recognizer.count > 0 && e.recognizer.p95 <= targets.recognizerP95Ms, unit: "ms"))
        if let p = pipeline, p.count > 0 {
            checks.append(GateCheck(name: "Nebula latency p95 (camera frame → action posted)", value: p.p95, target: targets.pipelineP95Ms, pass: p.p95 <= targets.pipelineP95Ms, unit: "ms"))
            checks.append(GateCheck(name: "Nebula latency p99", value: p.p99, target: targets.pipelineP99Ms, pass: p.p99 <= targets.pipelineP99Ms, unit: "ms"))
        }
        var notes: [String] = []
        if synthetic { notes.append("SYNTHETIC DATA: these numbers show the pipeline works end to end. They are not evidence about real hands.") }
        if e.armedSeconds < 4 * 3600 {
            notes.append(String(format: "Only %.1f armed minutes were tested; a rate of 1 false fire per 4 hours can't be confirmed from less than 4 hours.", e.armedSeconds / 60))
        }
        for (g, s) in e.scores where s.examples > 0 && s.examples < 100 && s.recall >= 0.99 {
            notes.append("\(g): \(s.examples) test examples, so 99% means no misses at all; one miss would read \(String(format: "%.1f%%", 100 * Double(s.examples - 1) / Double(s.examples))).")
        }
        if pipeline == nil || pipeline!.count == 0 {
            notes.append("Nebula's live latency (camera → action) hasn't been measured yet: it comes from the app's latency log on your Mac.")
        }
        var holds: [String: Double] = [:]
        for g in Gesture.allCases where g.kind != .movement { holds[g.rawValue] = model.tuning(for: g).hold }
        return Report(generatedAt: Date().timeIntervalSince1970, modelSource: model.source, modelFingerprint: model.fingerprint, synthetic: synthetic,
                      testSessions: e.sessions, evaluation: e, pipeline: pipeline, checks: checks,
                      passing: passing.sorted(), holds: holds, notes: notes)
    }

    public func text() -> String {
        var out: [String] = []
        let e = evaluation
        out.append("NEBULA ACCURACY AND LATENCY REPORT")
        out.append(synthetic ? "Data: SYNTHETIC (not your hands)" : "Data: recorded sessions, held-out test split")
        out.append("Model: \(modelSource)   Test sessions: \(testSessions.count)   Frames: \(e.frames)")
        out.append("")
        let names = Gesture.allCases.map(\.rawValue) + e.confusion.keys.filter { Gesture(rawValue: $0) == nil }.sorted()
        let columns = names + ["none"]
        let short: (String) -> String = { s in String(s.prefix(6)).padding(toLength: 7, withPad: " ", startingAt: 0) }
        out.append("Confusion (rows: what was made; columns: what fired first)")
        out.append("".padding(toLength: 14, withPad: " ", startingAt: 0) + columns.map(short).joined())
        for row in names where e.confusion[row] != nil {
            var line = row.padding(toLength: 14, withPad: " ", startingAt: 0)
            for c in columns {
                let n = e.confusion[row]?[c] ?? 0
                line += (n == 0 ? "." : "\(n)").padding(toLength: 7, withPad: " ", startingAt: 0)
            }
            let other = (e.confusion[row] ?? [:]).filter { !columns.contains($0.key) }
            if !other.isEmpty { line += " " + other.map { "\($0.key)=\($0.value)" }.joined(separator: " ") }
            out.append(line)
        }
        out.append("")
        out.append("Per gesture              recall   precision   examples   hold    time to fire")
        for g in Gesture.allCases {
            let s = e.scores[g.rawValue] ?? GestureScore(gesture: g.rawValue)
            let hold = holds[g.rawValue].map { String(format: "%.2fs", $0) } ?? "move"
            out.append(g.rawValue.padding(toLength: 24, withPad: " ", startingAt: 0)
                + String(format: "%6.1f%%   %7.1f%%   %8d   ", 100 * s.recall, 100 * s.precision, s.examples)
                + hold.padding(toLength: 5, withPad: " ", startingAt: 0)
                + String(format: "   %6.0f ms", 1000 * s.meanTimeToFire))
        }
        out.append("")
        out.append(String(format: "Wrong-gesture rate: %.2f%% (%d of %d examples)", 100 * e.wrongGestureRate, e.wrongGesture, e.examples))
        out.append(String(format: "False fires: %d in %.1f armed minutes = %.2f per hour", e.falseFires.count, e.armedSeconds / 60, e.falseFiresPerHour))
        for f in e.falseFires.prefix(12) {
            out.append("  \(f.session) at " + String(format: "%.2fs", f.time) + ": \(f.gesture) (\(f.context))")
        }
        if e.falseFires.count > 12 { out.append("  … \(e.falseFires.count - 12) more") }
        out.append("")
        out.append(String(format: "Recognizer per frame (features + both judges + decision): p50 %.3f ms  p95 %.3f ms  p99 %.3f ms  max %.3f ms  (%d frames)",
                          e.recognizer.p50, e.recognizer.p95, e.recognizer.p99, e.recognizer.max, e.recognizer.count))
        if let p = pipeline, p.count > 0 {
            out.append(String(format: "Nebula latency, camera frame → action posted: p50 %.2f ms  p95 %.2f ms  p99 %.2f ms  (%d actions)", p.p50, p.p95, p.p99, p.count))
        }
        out.append("")
        out.append("Risky pairs")
        for (title, members) in riskyPairs {
            let parts = members.filter { $0 != "nothing" }.map { m -> String in
                let row = e.confusion[m] ?? [:]
                let crossed = members.filter { $0 != m }.map { row[$0] ?? 0 }.reduce(0, +)
                return "\(m)→other \(crossed)"
            }
            out.append("  \(title): " + parts.joined(separator: ", "))
        }
        out.append("")
        out.append("Targets")
        for c in checks {
            let v = c.unit == "ratio" ? String(format: "%.2f%%", 100 * c.value) : String(format: "%.3f ", c.value) + c.unit
            let t = c.unit == "ratio" ? String(format: "%.2f%%", 100 * c.target) : String(format: "%.3f ", c.target) + c.unit
            out.append("  [\(c.pass ? "PASS" : "FAIL")] \(c.name): \(v) (target \(c.name.hasPrefix("recall") ? "≥" : "≤") \(t))")
        }
        out.append("")
        out.append("Gestures meeting every target: \(passing.isEmpty ? "none" : passing.joined(separator: ", "))")
        for n in notes { out.append("Note: \(n)") }
        out.append(pass ? "RESULT: PASS" : "RESULT: FAIL")
        return out.joined(separator: "\n")
    }
}
