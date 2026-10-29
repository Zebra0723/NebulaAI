import Foundation

/// One change Nebula's mind proposes to a gesture's tuning. Nil keeps that knob as it is.
public struct TuningChange: Codable, Sendable, Equatable {
    public var gesture: String
    public var hold: Double?
    public var confidence: Float?
    public var margin: Float?
    public var cooldown: Double?
    public var why: String

    public init(gesture: String, hold: Double? = nil, confidence: Float? = nil, margin: Float? = nil,
                cooldown: Double? = nil, why: String = "") {
        self.gesture = gesture
        self.hold = hold
        self.confidence = confidence
        self.margin = margin
        self.cooldown = cooldown
        self.why = why
    }
}

/// How Nebula's mind is allowed to change its own tuning, and how it decides whether a change
/// was an improvement. The AI proposes; this keeps every knob inside safe bounds, moves each one
/// a little at a time, and only keeps a new tuning that measures at least as well on your
/// recordings. So "I've fixed it" always comes with the numbers that show it.
public enum Tuner {
    public static let holdRange: ClosedRange<Double> = 0.08...0.6
    public static let confidenceRange: ClosedRange<Double> = 0.4...0.92
    public static let marginRange: ClosedRange<Double> = 0.08...0.5
    public static let cooldownRange: ClosedRange<Double> = 0.2...2.5
    /// The most any knob moves in one go: a quarter of where it is.
    public static let maxStep = 0.25

    /// `new`, kept within `range` and within a quarter of `old`.
    static func step(_ old: Double, _ new: Double, _ range: ClosedRange<Double>) -> Double {
        let lo = max(range.lowerBound, old * (1 - maxStep))
        let hi = min(range.upperBound, old * (1 + maxStep))
        guard lo <= hi, new.isFinite else { return old }
        return min(max(new, lo), hi)
    }

    /// Applies the changes within bounds. Returns the new model and one line per gesture changed.
    public static func apply(_ changes: [TuningChange], to model: NebulaModel) -> (model: NebulaModel, lines: [String]) {
        var m = model
        var lines: [String] = []
        for change in changes {
            guard let gesture = Gesture(rawValue: change.gesture) else { continue }
            var t = m.tuning(for: gesture)
            let before = t
            // Movement gestures fire on the stroke, with no hold to tune.
            if let hold = change.hold, t.hold > 0 { t.hold = step(t.hold, hold, holdRange) }
            if let c = change.confidence { t.confidence = Float(step(Double(t.confidence), Double(c), confidenceRange)) }
            if let g = change.margin { t.margin = Float(step(Double(t.margin), Double(g), marginRange)) }
            if let cd = change.cooldown { t.cooldown = step(t.cooldown, cd, cooldownRange) }
            guard t != before else { continue }
            m.tuning[gesture.rawValue] = t
            var parts: [String] = []
            if t.hold != before.hold { parts.append("hold \(fmt(before.hold))→\(fmt(t.hold)) s") }
            if t.confidence != before.confidence { parts.append("confidence \(fmt(Double(before.confidence)))→\(fmt(Double(t.confidence)))") }
            if t.margin != before.margin { parts.append("margin \(fmt(Double(before.margin)))→\(fmt(Double(t.margin)))") }
            if t.cooldown != before.cooldown { parts.append("cooldown \(fmt(before.cooldown))→\(fmt(t.cooldown)) s") }
            lines.append("\(gesture.rawValue): \(parts.joined(separator: ", "))\(change.why.isEmpty ? "" : " (\(change.why))")")
        }
        return (m, lines)
    }

    static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    /// Share of labelled examples recognised, 0 to 1.
    public static func recall(_ e: EvaluationResult) -> Double {
        let examples = e.scores.values.reduce(0) { $0 + $1.examples }
        let recognized = e.scores.values.reduce(0) { $0 + $1.recognized }
        return examples == 0 ? 0 : Double(recognized) / Double(examples)
    }

    /// Keep the new tuning only if it's no worse anywhere that matters (no more false fires, no
    /// more wrong gestures, recall within half a point) and better somewhere.
    public static func accepts(before: EvaluationResult, after: EvaluationResult) -> Bool {
        let fewerFalse = after.falseFires.count < before.falseFires.count
        let fewerWrong = after.wrongGesture < before.wrongGesture
        let moreRecall = recall(after) > recall(before) + 0.005
        return after.falseFires.count <= before.falseFires.count
            && after.wrongGesture <= before.wrongGesture
            && recall(after) >= recall(before) - 0.005
            && (fewerFalse || fewerWrong || moreRecall)
    }

    /// One line with the numbers, for the trainer and for you.
    public static func compare(before: EvaluationResult, after: EvaluationResult) -> String {
        let pct = { (v: Double) in String(format: "%.1f%%", v * 100) }
        return "false fires \(before.falseFires.count)→\(after.falseFires.count), wrong gestures \(before.wrongGesture)→\(after.wrongGesture), "
            + "recognised \(pct(recall(before)))→\(pct(recall(after))) on \(after.examples) recorded examples"
    }
}
