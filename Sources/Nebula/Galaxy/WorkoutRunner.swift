import Foundation
import NebulaCore
import NebulaSim

/// Galaxy Trainer's workouts, run on Nebula: a simulated hand in front of Nebula.
///
/// The trainer designs each workout around the gestures and conditions Nebula gets
/// wrong. This runs it on Nebula's own simulator through the real recognizer (no
/// camera), round after round with sloppy, real-world hands, then learns from those
/// hands: it retrains on them alongside your recordings and keeps the new model only
/// if it beats the current one on a fixed test (your recorded test sessions plus a
/// fixed set of sloppy ones). The results go back to the trainer, numbers and all.
///
/// Everything heavy runs off the main thread, so Nebula keeps answering Link,
/// approvals and your hands the whole time. If you switch Nebula on mid-workout, the
/// workout stops at the end of its round and reports what it has.
@MainActor
final class WorkoutRunner {
    static let shared = WorkoutRunner()
    private(set) var running = false

    /// A flag the workout checks between rounds, set from the main thread.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func run(id: String, text: String, engine: Engine) async {
        guard !running else { return } // one at a time; the trainer waits and falls back
        guard let spec = try? JSONDecoder().decode(WorkoutSpec.self, from: Data(text.utf8)), !spec.focus.isEmpty else { return }
        running = true
        defer { running = false }
        engine.note("Galaxy Trainer workout started")

        let minutes = min(max(spec.minutes ?? 12, 2), 30)
        let start = Date()
        let end = start.addingTimeInterval(minutes * 60)
        // The last part of the time is for learning from what the workout found.
        let learnFor = minutes >= 8 ? max(3 * 60, minutes * 60 * 0.35) : 0
        let drillUntil = end.addingTimeInterval(-learnFor)
        let base = engine.currentModel
        let customs = engine.customs.map(\.gesture)
        let stop = StopFlag()

        // Watch for you switching Nebula on: real use always wins over practice.
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if engine.isArmed { stop.set() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { watcher.cancel() }

        let seed = UInt64(start.timeIntervalSince1970 * 1000)
        let outcome = await Task.detached(priority: .utility) { () -> (results: WorkoutResults, candidate: NebulaModel?) in
            var (results, corpus) = Workout.run(spec, model: base, customs: customs, seed: seed, deadline: drillUntil, stop: { stop.isSet })
            guard learnFor > 0, !stop.isSet, Date() < end, !corpus.isEmpty else { return (results, nil) }
            // Learn from the sloppy hands, then check against a fixed test before keeping anything.
            let all = (try? Recording.loadAll(in: Paths.recordings)) ?? []
            let usable = all.filter { $0.info.kind != .enrollment }
            let (train, validation, test) = Trainer.split(usable)
            var candidate = Trainer.train(train + corpus.prefix(36), validation: validation.isEmpty ? Array(corpus.suffix(6)) : validation,
                                          base: base, source: "workout")
            let enrollment = all.filter { $0.info.kind == .enrollment }
            if !enrollment.isEmpty || !customs.isEmpty {
                candidate = Trainer.personalize(candidate, enrollment: enrollment, library: usable, customs: customs)
            }
            let fixed = test + Workout.benchmark()
            let before = Evaluator.evaluate(fixed, model: base, customs: customs)
            let after = Evaluator.evaluate(fixed, model: candidate, customs: customs)
            let kept = Tuner.accepts(before: before, after: after)
            results.model = WorkoutResults.ModelChange(replaced: kept, before: Tuner.recall(before), after: Tuner.recall(after))
            results.notes = kept
                ? "Learned from \(corpus.count) sloppy sessions: \(Tuner.compare(before: before, after: after)). Kept the new model."
                : "Tried learning from \(corpus.count) sloppy sessions: \(Tuner.compare(before: before, after: after)). Not better, so kept the old model."
            return (results, kept ? candidate : nil)
        }.value

        var results = outcome.results
        if stop.isSet { results.notes = "Stopped early because Nebula was switched on. " + results.notes }
        if let candidate = outcome.candidate, !engine.isArmed {
            engine.adoptTuned(candidate, note: "New model from a Galaxy Trainer workout: \(results.notes)")
        }
        if let data = try? JSONEncoder().encode(results), let json = String(data: data, encoding: .utf8) {
            await GalaxyLink.shared.practiceAnswer(id: id, answer: json)
        }
        engine.note("Galaxy Trainer workout done: \(Int((results.overall * 100).rounded()))% over \(results.rounds) rounds")
        // Once the trainer has posted these results, the mind tunes from them too.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            await NebulaMind.shared.think(engine: engine)
        }
    }
}
