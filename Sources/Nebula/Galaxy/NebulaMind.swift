import Foundation
import NebulaCore

/// Nebula's mind. Nebula reads hands on-device with no AI in the loop, so this is how what
/// Galaxy Trainer teaches it turns into a change in how it behaves:
///
/// 1. Reads its playbook (the trainer's lessons) and its latest workout results from Galaxy Link.
/// 2. Asks Claude for small changes to its tuning (how long a pose is held, how sure it must be,
///    the cooldown) that act on those lessons.
/// 3. Applies them within safe bounds (`Tuner`), measures old and new on your recordings, and
///    keeps the new tuning only if it's no worse anywhere and better somewhere.
/// 4. Tells the trainer exactly what changed and the numbers, or that nothing was kept and why.
///
/// It runs when the lessons or results have changed, only while Nebula isn't watching or busy.
/// Tokens are spent only then (your Nebula API key, the same one Create uses).
@MainActor
final class NebulaMind {
    static let shared = NebulaMind()
    static let model = "claude-sonnet-5-5"
    private let fingerprintKey = "NebulaMind.lastSeen"
    private var thinking = false

    /// Checks every half hour; thinks only when there's something new to act on.
    func loop(engine: Engine) async {
        try? await Task.sleep(nanoseconds: 120_000_000_000)
        while true {
            await think(engine: engine)
            try? await Task.sleep(nanoseconds: 1_800_000_000_000)
        }
    }

    func think(engine: Engine, force: Bool = false) async {
        guard !thinking, !engine.isArmed, engine.busy == nil, !WorkoutRunner.shared.running, let apiKey = Keychain.apiKey else { return }
        guard let notes = await GalaxyLink.shared.training(), !(notes.lessons.isEmpty && notes.results.isEmpty) else { return }
        let fingerprint = (notes.lessons + notes.results).joined(separator: "\n")
        if !force && UserDefaults.standard.string(forKey: fingerprintKey) == fingerprint { return }
        thinking = true
        defer { thinking = false }

        let base = engine.currentModel
        let proposal: (changes: [TuningChange], summary: String)
        do {
            proposal = try await Self.propose(apiKey: apiKey, lessons: notes.lessons, results: notes.results, model: base)
        } catch {
            engine.note("Nebula's mind couldn't think: \(error.localizedDescription)")
            return
        }
        let changes = proposal.changes
        let summary = proposal.summary
        UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
        let (candidate, lines) = Tuner.apply(changes, to: base)
        guard !lines.isEmpty else {
            await GalaxyLink.shared.postToTrainer("I read the playbook and results and left my tuning as it is. \(summary)")
            return
        }

        // Measure both on the recorded test sessions, off the main thread.
        let verdict = await Task.detached(priority: .utility) { () -> (kept: Bool, numbers: String)? in
            let all = (try? Recording.loadAll(in: Paths.recordings)) ?? []
            let test = Trainer.split(all.filter { $0.info.kind != .enrollment }).test
            guard !test.isEmpty else { return nil }
            let before = Evaluator.evaluate(test, model: base)
            let after = Evaluator.evaluate(test, model: candidate)
            return (Tuner.accepts(before: before, after: after), Tuner.compare(before: before, after: after))
        }.value

        let changed = lines.map { "- \($0)" }.joined(separator: "\n")
        guard let verdict else {
            await GalaxyLink.shared.postToTrainer("I'd change:\n\(changed)\nbut there are no recorded test sessions to check it against, so I haven't changed anything. Record some in Nebula's Record screen.")
            return
        }
        if verdict.kept {
            engine.adoptTuned(candidate, note: "Tuned from Galaxy Trainer's lessons: \(lines.count) gesture\(lines.count == 1 ? "" : "s") changed")
            await GalaxyLink.shared.postToTrainer("Changed my tuning from your lessons:\n\(changed)\nMeasured on my recordings: \(verdict.numbers). Kept.")
            await GalaxyLink.shared.note("tuned \(lines.count) gesture\(lines.count == 1 ? "" : "s") from the trainer's lessons")
        } else {
            await GalaxyLink.shared.postToTrainer("Tried:\n\(changed)\nMeasured on my recordings: \(verdict.numbers). That's no better, so I kept my old tuning.")
        }
    }

    // MARK: - Claude

    struct MindError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func propose(apiKey: String, lessons: [String], results: [String], model: NebulaModel) async throws -> (changes: [TuningChange], summary: String) {
        let tuning = Gesture.allCases.map { g -> String in
            let t = model.tuning(for: g)
            return "\(g.rawValue) (\(g.kind.rawValue)): hold \(t.hold) s, confidence \(t.confidence), margin \(t.margin), cooldown \(t.cooldown) s"
        }.joined(separator: "\n")
        let prompt = """
        Galaxy Trainer's lessons for Nebula:
        \(lessons.isEmpty ? "(none yet)" : lessons.map { "- \($0)" }.joined(separator: "\n"))

        Nebula's latest workout results (JSON; accuracy is 0 to 1):
        \(results.isEmpty ? "(none yet)" : results.joined(separator: "\n"))

        Nebula's current tuning:
        \(tuning)
        """
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4000,
            "system": Self.system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": Self.schema]],
        ]
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw MindError(message: status == 401 ? "the API key didn't work (set one in Settings)" : message)
        }
        guard let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let out = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let list = out["changes"] as? [[String: Any]] else {
            throw MindError(message: "Claude's answer wasn't a set of tuning changes")
        }
        let changes = list.compactMap { c -> TuningChange? in
            guard let gesture = c["gesture"] as? String else { return nil }
            return TuningChange(gesture: gesture,
                                hold: (c["hold"] as? NSNumber)?.doubleValue,
                                confidence: (c["confidence"] as? NSNumber)?.floatValue,
                                margin: (c["margin"] as? NSNumber)?.floatValue,
                                cooldown: (c["cooldown"] as? NSNumber)?.doubleValue,
                                why: c["why"] as? String ?? "")
        }
        return (changes: changes, summary: out["summary"] as? String ?? "")
    }

    static let system = """
    You are Nebula's mind. Nebula is a gesture-control app on a Mac: it reads one hand from the webcam and fires \
    a gesture when two judges agree on a pose held still long enough. You turn Galaxy Trainer's lessons and \
    Nebula's workout results into small changes to its tuning. For each gesture: hold is seconds the pose must be \
    held (0.08 to 0.6; movement gestures have none), confidence is how sure the second judge must be (0.4 to 0.92), \
    margin is its lead over its second choice (0.08 to 0.5), cooldown is seconds before it can fire again (0.2 to 2.5). \
    Raise hold, confidence or margin for a gesture that fires when it shouldn't; lower them a little for one that \
    misses real attempts. Change only what the lessons or results point to, at most a quarter of the current value, \
    and leave everything else out (null). Every change is measured on the user's recordings and kept only if it's \
    better, so propose what you think will measurably help. summary: one or two plain sentences for the trainer.
    """

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "changes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "gesture": ["type": "string", "enum": Gesture.allCases.map(\.rawValue)],
                        "hold": ["type": ["number", "null"]],
                        "confidence": ["type": ["number", "null"]],
                        "margin": ["type": ["number", "null"]],
                        "cooldown": ["type": ["number", "null"]],
                        "why": ["type": "string"],
                    ],
                    "required": ["gesture", "hold", "confidence", "margin", "cooldown", "why"],
                    "additionalProperties": false,
                ],
            ],
            "summary": ["type": "string"],
        ],
        "required": ["changes", "summary"],
        "additionalProperties": false,
    ]
}
