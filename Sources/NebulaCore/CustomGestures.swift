// Custom gestures meet the same bar as the built-in ones. A design from the
// Create screen is checked against every recording before it can be saved:
// it must never fire on "nothing" or near-miss footage, and it must not look
// like any existing gesture. Then the person records examples, Judge B
// learns them, and it saves only at 99% or better.

import Foundation

/// What a custom gesture does when it fires. Deliberately small: nothing here can
/// reach past the frontmost window except the Galaxy actions.
public enum CustomAction: Codable, Sendable, Equatable {
    /// A keyboard shortcut, posted to the frontmost app only, e.g. "cmd+shift+t".
    case keys(String)
    /// One of the window actions every adapter understands.
    case window(String) // "next", "previous", "playPause"
    /// A Galaxy action.
    case galaxy(String) // "summonNova", "muteOrbit", "unmuteOrbit", "approve", "reject"

    public var summary: String {
        switch self {
        case .keys(let k): return "Press \(KeyCombo.parse(k)?.display ?? k) in the frontmost window"
        case .window(let w): return ["next": "Next tab, slide, page or track", "previous": "Previous tab, slide, page or track",
                                     "playPause": "Play or pause in the frontmost window"][w] ?? w
        case .galaxy(let g): return ["summonNova": "Summon Nova", "muteOrbit": "Mute Orbit", "unmuteOrbit": "Unmute Orbit",
                                     "approve": "Approve the pending Galaxy approval", "reject": "Reject the pending Galaxy approval"][g] ?? g
        }
    }

    public func validate() -> String? {
        switch self {
        case .keys(let k): return KeyCombo.parse(k) == nil ? "can't read the shortcut \"\(k)\"" : nil
        case .window(let w): return ["next", "previous", "playPause"].contains(w) ? nil : "no window action \(w)"
        case .galaxy(let g):
            return ["summonNova", "muteOrbit", "unmuteOrbit", "approve", "reject"].contains(g) ? nil : "no Galaxy action \(g)"
        }
    }
}

/// A keyboard shortcut like "cmd+shift+t", parsed to a macOS virtual key code and modifiers.
public struct KeyCombo: Sendable, Equatable {
    public var keyCode: UInt16
    public var command = false, shift = false, option = false, control = false
    public var key: String

    public init(keyCode: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false, key: String) {
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.key = key
    }

    public var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }

    static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48,
        "space": 49, "`": 50, "delete": 51, "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "pageup": 116, "pagedown": 121,
        "home": 115, "end": 119,
    ]

    public static func parse(_ text: String) -> KeyCombo? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let code = codes[last] else { return nil }
        var combo = KeyCombo(keyCode: code, key: last)
        for p in parts.dropLast() {
            switch p {
            case "cmd", "command", "⌘": combo.command = true
            case "shift", "⇧": combo.shift = true
            case "opt", "option", "alt", "⌥": combo.option = true
            case "ctrl", "control", "⌃": combo.control = true
            default: return nil
            }
        }
        return combo
    }
}

/// A custom gesture as Claude designs it: a held pose and what it does.
public struct CustomGestureSpec: Codable, Sendable, Equatable {
    public var name: String
    /// The exact movement, in words, for the person.
    public var movement: String
    public var rule: PoseRule
    public var action: CustomAction
    public var hold: Double

    public init(name: String, movement: String, rule: PoseRule, action: CustomAction, hold: Double = 0.2) {
        self.name = name
        self.movement = movement
        self.rule = rule
        self.action = action
        self.hold = hold
    }
}

public struct ClashReport: Sendable, Equatable {
    /// Would-be fires (held, still, at the hold) on nothing and near-miss footage.
    public var firesOnNothing = 0
    public var nothingSeconds = 0.0
    /// Built-in gestures whose recorded examples this pose also matches, with the share of their frames.
    public var overlaps: [String: Double] = [:]
    public var problems: [String] = []
    public var ok: Bool { problems.isEmpty }
}

public enum CustomGestureCheck {
    /// Share of a gesture's frames a new pose may match before it counts as overlapping.
    public static let overlapLimit = 0.02

    /// Runs the design's rule over every recording: Judge A alone, with the real hold and
    /// stillness rules, since Judge B can't know a pose no one has recorded yet.
    public static func check(_ spec: CustomGestureSpec, against recordings: [Recording], model: NebulaModel) -> ClashReport {
        var report = ClashReport()
        if let problem = spec.rule.validate() { report.problems.append(problem); return report }
        if let problem = spec.action.validate() { report.problems.append(problem); return report }
        let rules = CompiledRules(model.poseRules() + [spec.rule])
        let pose = rules.poseCount - 1
        let enter = GestureTuning().enter
        var matchedFrames: [String: Int] = [:]
        var totalFrames: [String: Int] = [:]
        for rec in recordings {
            let r = Recognizer(model: model)
            let windows = rec.labels.filter { !$0.isNegative }
            var holdStart: Double?
            var fired = false
            for frame in rec.frames {
                let o = r.observe(frame)
                let w = windows.first { frame.time >= $0.start && frame.time <= $0.end }
                guard o.valid && !o.partial else { holdStart = nil; fired = false; continue }
                let score = rules.score(pose, o.features)
                let still = o.features[Feature.speed.rawValue] <= model.motion.stillSpeed
                if let w, let g = w.expected {
                    totalFrames[g.rawValue, default: 0] += 1
                    if score >= enter { matchedFrames[g.rawValue, default: 0] += 1 }
                    holdStart = nil
                    continue
                }
                if score >= enter && still {
                    if holdStart == nil { holdStart = frame.time }
                    if !fired && frame.time - holdStart! >= spec.hold {
                        report.firesOnNothing += 1
                        fired = true
                    }
                } else {
                    holdStart = nil
                    fired = false
                }
            }
            report.nothingSeconds += rec.duration - windows.reduce(0) { $0 + ($1.end - $1.start) }
        }
        for (g, total) in totalFrames where total > 0 {
            let share = Double(matchedFrames[g, default: 0]) / Double(total)
            if share > overlapLimit { report.overlaps[g] = share }
        }
        if report.firesOnNothing > 0 {
            report.problems.append("It would have fired \(report.firesOnNothing) times in \(Int(report.nothingSeconds / 60)) minutes of ordinary hand movement.")
        }
        for (g, share) in report.overlaps.sorted(by: { $0.value > $1.value }) {
            report.problems.append("It looks like \(Gesture(rawValue: g)?.title ?? g) in " + String(format: "%.0f%%", share * 100) + " of those recordings.")
        }
        return report
    }
}

public struct CustomVerification: Sendable {
    public var model: NebulaModel
    public var heldOut: Int
    public var recognized: Int
    public var falseFires: Int
    /// The built-in gestures measured again on the retrained model.
    public var report: Report?
    public var recall: Double { heldOut == 0 ? 0 : Double(recognized) / Double(heldOut) }
    /// Saves only at 99% or better on examples Judge B didn't learn from, with no false fire.
    public var passes: Bool { heldOut >= 3 && recall >= 0.99 && falseFires == 0 }
}

extension CustomGestureCheck {
    /// After the person records examples: Judge B learns the new pose from most of them
    /// (plus all the existing training data), then it's tested on the rest, which it never
    /// saw, and on the held-out "nothing" sessions.
    public static func verify(_ custom: CustomGesture, examples: [Recording], library: [Recording], base: NebulaModel,
                              customs existing: [CustomGesture]) -> CustomVerification {
        let all = existing + [custom]
        // Hold out the last third of the examples, by window.
        var learn: [Recording] = []
        var test: [Recording] = []
        for rec in examples {
            let windows = rec.labels.filter { $0.gesture == custom.id }
            let cut = Int((Double(windows.count) * 2 / 3).rounded(.down))
            var a = rec, b = rec
            a.labels = Array(windows.prefix(cut))
            b.labels = Array(windows.dropFirst(cut))
            // Frames outside the learning windows count as "nothing" only in the test half.
            if let end = a.labels.last?.end { a.frames = rec.frames.filter { $0.time <= end + 0.5 } }
            if let start = b.labels.first?.start { b.frames = rec.frames.filter { $0.time >= start - 0.5 } }
            learn.append(a)
            test.append(b)
        }
        let (train, _, heldOut) = Trainer.split(library)
        var model = base
        model.classifier = Trainer.trainClassifier(train + learn, base: base, customs: all)
        var verification = CustomVerification(model: model, heldOut: 0, recognized: 0, falseFires: 0, report: nil)
        let id = Recognizer.customBase + all.count - 1
        for rec in test {
            let e = Evaluator.evaluate([rec], model: model, customs: all)
            verification.heldOut += e.scores[custom.id]?.examples ?? 0
            verification.recognized += e.scores[custom.id]?.recognized ?? 0
        }
        // Every held-out session: the custom gesture must never fire there, and the built-in
        // gestures are measured again, since Judge B relearned everything.
        let e = Evaluator.evaluate(heldOut, model: model, customs: all)
        verification.falseFires = e.falseFires.filter { $0.gesture == custom.id }.count
            + e.scores.filter { $0.key == custom.id }.reduce(0) { $0 + $1.value.wrongFires }
        verification.report = Report.make(evaluation: e, model: model, synthetic: heldOut.contains { $0.info.synthetic }, pipeline: nil)
        _ = id
        return verification
    }
}
