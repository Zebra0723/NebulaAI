import AllocCounter
import Foundation
import XCTest
@testable import NebulaCore
@testable import NebulaSim

/// The build gates. These fail the build when a number misses its target.
///
/// With recordings available (NEBULA_DATA pointing at a folder of sessions and
/// NEBULA_MODEL at a trained model) they run on the held-out test sessions. Without
/// them, the latency and allocation gates still run on synthetic sessions, and the
/// accuracy gate is skipped and says so: only your recordings can pass it.
final class GateTests: XCTestCase {
    static let env = ProcessInfo.processInfo.environment

    static let recordings: [Recording]? = {
        guard let dir = env["NEBULA_DATA"], !dir.isEmpty else { return nil }
        return try? Recording.loadAll(in: URL(fileURLWithPath: dir))
    }()

    static let recordedModel: NebulaModel? = {
        guard let path = env["NEBULA_MODEL"], let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? NebulaModel.decode(data)
    }()

    /// A small synthetic corpus and a model trained on it, for when there's no real data.
    static let synthetic: (model: NebulaModel, sessions: [Recording]) = {
        var options = SynthOptions()
        options.repetitions = 4
        options.nothingMinutes = 1
        let corpus = SynthCorpus.make(seed: 11, sessions: 4, options: options)
        let (train, _, test) = Trainer.split(corpus)
        var model = Bootstrap.emptyModel()
        var mlp = MLPTrainingOptions()
        mlp.epochs = 6
        model.classifier.mlp = MLPModel.train(examples: Trainer.examples(from: train, model: model),
                                              classCount: Pose.builtinCount, options: mlp)
        return (model, test)
    }()

    func testRecognizerTimePerFrameP95IsUnder2ms() throws {
        let model = Self.recordedModel ?? Self.synthetic.model
        let sessions = Self.recordings ?? Self.synthetic.sessions
        let r = Recognizer(model: model)
        var samples: [Float] = []
        samples.reserveCapacity(sessions.reduce(0) { $0 + $1.frames.count })
        for rec in sessions {
            r.reset()
            for frame in rec.frames {
                let t0 = Monotonic.nanoseconds()
                r.process(frame)
                samples.append(Float(Double(Monotonic.nanoseconds() - t0) / 1e6))
            }
        }
        let p = Percentiles(samples)
        print(String(format: "Recognizer per frame over %d frames: p50 %.4f ms, p95 %.4f ms, p99 %.4f ms, max %.3f ms", p.count, p.p50, p.p95, p.p99, p.max))
        XCTAssertGreaterThan(p.count, 1000)
        XCTAssertLessThanOrEqual(p.p95, Targets().recognizerP95Ms, "per-frame recognizer time p95 above 2 ms")
    }

    func testThePerFramePathNeverAllocates() throws {
        try XCTSkipIf(nebula_alloc_supported() == 0, "allocation counting needs glibc (runs on Linux CI)")
        let model = Self.synthetic.model
        let r = Recognizer(model: model)
        let frames = Self.synthetic.sessions.flatMap(\.frames)
        // Warm up: first-use work (lazy globals, caches) is not the per-frame path.
        for f in frames.prefix(500) { r.process(f) }
        var worst = 0
        for f in frames {
            nebula_alloc_begin()
            r.process(f)
            let n = nebula_alloc_end()
            if n > 0 && worst == 0 { nebula_alloc_print_trace() }
            worst = max(worst, n)
        }
        XCTAssertEqual(worst, 0, "a frame allocated \(worst) times")
    }

    func testTheLatencyLogNeverAllocatesWhenRecording() throws {
        try XCTSkipIf(nebula_alloc_supported() == 0, "allocation counting needs glibc")
        let log = LatencyLog(capacity: 128)
        log.record(1)
        nebula_alloc_begin()
        for i in 0..<1000 { log.record(Float(i)) }
        XCTAssertEqual(nebula_alloc_end(), 0)
        XCTAssertEqual(log.count, 128)
    }

    /// Every accuracy target, on held-out recorded sessions.
    func testAccuracyMeetsEveryTargetOnHeldOutRecordings() throws {
        guard let recordings = Self.recordings, let model = Self.recordedModel else {
            throw XCTSkip("No recordings: set NEBULA_DATA and NEBULA_MODEL. The accuracy gate only passes on your own data.")
        }
        let (_, _, test) = Trainer.split(recordings)
        XCTAssertFalse(test.isEmpty, "no held-out test sessions")
        let report = Report.make(evaluation: Evaluator.evaluate(test, model: model), model: model,
                                 synthetic: test.contains { $0.info.synthetic }, pipeline: nil)
        print(report.text())
        XCTAssertFalse(report.synthetic, "the accuracy gate can't be passed with synthetic data")
        for check in report.checks {
            XCTAssertTrue(check.pass, "\(check.name): \(check.value) misses \(check.target)")
        }
    }

    /// The whole pipeline, end to end, on synthetic sessions. Not a target: a smoke test
    /// that recording → training → evaluation hangs together.
    func testThePipelineRunsEndToEndOnSyntheticSessions() {
        let e = Evaluator.evaluate(Self.synthetic.sessions, model: Self.synthetic.model)
        XCTAssertGreaterThan(e.examples, 20)
        XCTAssertGreaterThan(e.armedSeconds, 30)
        let recognized = e.scores.values.reduce(0) { $0 + $1.recognized }
        XCTAssertGreaterThan(Double(recognized) / Double(e.examples), 0.6, "most synthetic examples are recognized")
    }
}
