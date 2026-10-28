// nebula-report: trains, tunes and proves the recognizer from recorded sessions.
//
//   nebula-report train  --data DIR --out model.json        train on the train split, tune on validation
//   nebula-report report --data DIR --model model.json      confusion matrix, recall, precision, false fires, latency
//   nebula-report gate   --data DIR --model model.json      the report, exiting 1 if any target is missed
//   nebula-report bench  --data DIR --model model.json      per-frame recognizer time; exits 1 above 2 ms at p95
//   nebula-report personalize --model M --enrollment DIR --out M2
//   nebula-report synth  --out DIR                          a synthetic corpus, for testing the pipeline only
//
// --data defaults to ~/Library/Application Support/Nebula/Recordings, where the app records.

import Foundation
import NebulaCore
import NebulaSim

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--" + name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains("--" + name) }

let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nebula")
let dataDir = URL(fileURLWithPath: option("data") ?? support.appendingPathComponent("Recordings").path)
let modelPath = option("model") ?? support.appendingPathComponent("model.json").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("nebula-report: " + message + "\n").utf8))
    exit(2)
}

func loadModel(_ path: String) -> NebulaModel {
    guard let data = FileManager.default.contents(atPath: path) else { fail("no model at \(path)") }
    do {
        var model = try NebulaModel.decode(data)
        model.adoptCurrentQuality()
        return model
    } catch { fail("can't read \(path): \(error)") }
}

func loadData() -> [Recording] {
    do {
        let all = try Recording.loadAll(in: dataDir)
        if all.isEmpty { fail("no recordings in \(dataDir.path). Record sessions in Nebula's Practice screen first.") }
        return all
    } catch { fail("can't read recordings: \(error)") }
}

func describe(_ recs: [Recording], _ title: String) {
    let minutes = recs.reduce(0) { $0 + $1.duration } / 60
    let examples = recs.reduce(0) { $0 + $1.labels.filter { !$0.isNegative }.count }
    print("  \(title): \(recs.count) sessions, " + String(format: "%.1f min", minutes) + ", \(examples) gesture examples")
}

/// The newest pipeline latency log the app wrote, if there is one.
func pipelineLatency() -> Percentiles? {
    let path = option("latency") ?? support.appendingPathComponent("latency.json").path
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONDecoder().decode(Percentiles.self, from: data)
}

func makeReport(_ model: NebulaModel) -> Report {
    let (_, _, test) = Trainer.split(loadData())
    if test.isEmpty { fail("no test sessions yet: every fourth session of each kind is held out for testing") }
    let synthetic = test.contains { $0.info.synthetic }
    let evaluation = Evaluator.evaluate(test, model: model)
    return Report.make(evaluation: evaluation, model: model, synthetic: synthetic, pipeline: pipelineLatency())
}

func writeJSON<T: Encodable>(_ value: T, to path: String) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        try encoder.encode(value).write(to: URL(fileURLWithPath: path))
    } catch { fail("can't write \(path): \(error)") }
}

switch command {
case "synth":
    guard let out = option("out") else { fail("synth needs --out DIR") }
    var options = SynthOptions()
    if let r = option("reps").flatMap(Int.init) { options.repetitions = r }
    if let m = option("minutes").flatMap(Double.init) { options.nothingMinutes = m }
    if let f = option("fps").flatMap(Double.init) { options.fps = f }
    let seed = option("seed").flatMap(UInt64.init) ?? 7
    let sessions = option("sessions").flatMap(Int.init) ?? 8
    let corpus = SynthCorpus.make(seed: seed, sessions: sessions, options: options)
    let dir = URL(fileURLWithPath: out)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for rec in corpus {
        do { try rec.write(to: dir.appendingPathComponent(rec.info.id + ".jsonl")) } catch { fail("\(error)") }
    }
    print("Wrote \(corpus.count) synthetic sessions to \(out)")

case "train":
    let all = loadData()
    let (train, validation, test) = Trainer.split(all)
    print("Sessions (split by session, never by frame):")
    describe(train, "train")
    describe(validation, "validation")
    describe(test, "test (held out, not used here)")
    if train.isEmpty { fail("no training sessions") }
    let base = option("base").map(loadModel) ?? Bootstrap.emptyModel()
    let synthetic = all.contains { $0.info.synthetic }
    let kind = Trainer.JudgeBKind(rawValue: option("judge-b") ?? "mlp") ?? .mlp
    let model = Trainer.train(train, validation: validation, base: base,
                              source: synthetic ? "synthetic" : "recorded \(ISO8601DateFormatter().string(from: Date()))", kind: kind,
                              log: { print("  " + $0) })
    let out = option("out") ?? modelPath
    do { try model.encoded().write(to: URL(fileURLWithPath: out)) } catch { fail("can't write \(out): \(error)") }
    print("Wrote \(out)")

case "report", "gate":
    let model = loadModel(modelPath)
    let report = makeReport(model)
    print(report.text())
    if let json = option("json") { writeJSON(report, to: json) }
    if let gateFile = option("gate-file") {
        // What the app may let act: only gestures that met every target.
        struct GateFile: Encodable { let mode: String; let passing: [String]; let generatedAt: Double; let summary: String; let modelFingerprint: String }
        let failing = Gesture.allCases.map(\.rawValue).filter { !report.passing.contains($0) }
        writeJSON(GateFile(mode: "proven", passing: report.synthetic ? [] : report.passing, generatedAt: report.generatedAt,
                           summary: report.pass ? "Every target met on held-out sessions." :
                               "Below target, so switched off: \(failing.joined(separator: ", ")).",
                           modelFingerprint: report.modelFingerprint), to: gateFile)
    }
    if command == "gate" {
        if report.synthetic && !flag("allow-synthetic") {
            print("GATE: FAIL. The test data is synthetic; only your recordings can pass the gate.")
            exit(1)
        }
        exit(report.pass ? 0 : 1)
    }

case "bench":
    let model = loadModel(modelPath)
    let recs = loadData()
    // Warm up, then time every frame of every session.
    _ = Evaluator.evaluate(Array(recs.prefix(1)), model: model)
    let e = Evaluator.evaluate(recs, model: model)
    let p = e.recognizer
    print(String(format: "Recognizer per frame over %d frames: p50 %.3f ms  p95 %.3f ms  p99 %.3f ms  max %.3f ms",
                 p.count, p.p50, p.p95, p.p99, p.max))
    let ok = p.p95 <= Targets().recognizerP95Ms
    print(ok ? "BENCH: PASS (p95 ≤ 2 ms)" : "BENCH: FAIL (p95 above 2 ms)")
    exit(ok ? 0 : 1)

case "diagnose":
    // Why does a gesture not register? For every labelled window, the middle of the window:
    // Judge A's score for the expected pose, the condition that fails most, and Judge B's vote.
    let model = loadModel(modelPath)
    let recs = loadData()
    let rules = model.poseRules()
    var failing: [String: [String: Int]] = [:]
    var aScores: [String: [Float]] = [:]
    var bTop: [String: [String: Int]] = [:]
    var rejections: [String: [String: Int]] = [:]
    for rec in recs {
        let r = Recognizer(model: model)
        let windows = rec.labels.filter { !$0.isNegative }
        for frame in rec.frames {
            let o = r.observe(frame)
            guard let w = windows.first(where: { frame.time >= $0.start + ($0.end - $0.start) * 0.35 && frame.time <= $0.start + ($0.end - $0.start) * 0.65 }),
                  let g = w.expected else { continue }
            let name = w.gesture
            guard o.valid && !o.partial else { rejections[name, default: [:]]["\(o.rejection)", default: 0] += 1; continue }
            let pose = g.pose.rawValue
            let compiled = CompiledRules(rules)
            let score = compiled.score(pose, o.features)
            aScores[name, default: []].append(score)
            bTop[name, default: [:]][Pose(rawValue: o.b.top)?.name ?? "\(o.b.top)", default: 0] += 1
            for c in rules[pose].conditions {
                let f = Feature.named(c.feature)!
                let v = o.features[f.rawValue]
                if let lo = c.min, v < lo { failing[name, default: [:]]["\(c.feature) < \(lo)", default: 0] += 1 }
                if let hi = c.max, v > hi { failing[name, default: [:]]["\(c.feature) > \(hi)", default: 0] += 1 }
            }
        }
    }
    for name in aScores.keys.sorted() {
        let s = aScores[name]!.sorted()
        print("\(name): \(s.count) mid-window frames, Judge A median " + String(format: "%.2f", s[s.count / 2])
              + String(format: ", %.0f%% ≥ 0.75", 100 * Double(s.filter { $0 >= 0.75 }.count) / Double(s.count)))
        print("   Judge B says: " + (bTop[name] ?? [:]).sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let worst = (failing[name] ?? [:]).filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(4)
        if !worst.isEmpty { print("   outside range: " + worst.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")) }
        if let rj = rejections[name] { print("   unusable frames: " + rj.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
    }
    // Sideways strokes: what each one in a swipe or wave window counted as, or why not.
    var strokes: [String: [StrokeOutcome: Int]] = [:]
    for rec in recs {
        let r = Recognizer(model: model, lenient: true)
        let windows = rec.labels.filter { $0.expected?.kind == .movement }
        var seen = 0
        for frame in rec.frames {
            r.process(frame)
            guard r.strokesJudged != seen else { continue }
            seen = r.strokesJudged
            if let w = windows.first(where: { frame.time >= $0.start && frame.time <= $0.end + 0.3 }) {
                strokes[w.gesture, default: [:]][r.lastStroke, default: 0] += 1
            }
        }
    }
    if !strokes.isEmpty {
        print("\nSideways strokes in swipe and wave windows:")
        for (name, counts) in strokes.sorted(by: { $0.key < $1.key }) {
            print("   \(name): " + counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        }
    }

    // What counts: replayed through the whole recognizer as the app runs it (trial mode),
    // did each gesture you made actually fire, and did anything fire that shouldn't have?
    let result = Evaluator.evaluate(recs, model: model, lenient: true)
    print("\nWould fire, in trial mode:")
    for (name, s) in result.scores.sorted(by: { $0.key < $1.key }) where s.examples > 0 {
        print("   \(name): \(s.recognized) of \(s.examples)" + (s.examples > s.recognized ? "" : "  ✓")
              + (s.meanTimeToFire > 0 ? String(format: "  (%.2f s after you start)", s.meanTimeToFire) : ""))
    }
    let wrong = result.confusion.flatMap { exp, fired in fired.filter { $0.key != exp && $0.key != "none" }.map { "\(exp) → \($0.key) \($0.value)" } }
    if !wrong.isEmpty { print("   mixed up: " + wrong.sorted().joined(separator: ", ")) }
    var falseBy: [String: Int] = [:]
    for f in result.falseFires { falseBy["\(f.gesture) during \(f.context)", default: 0] += 1 }
    print("   false fires: \(result.falseFires.count)" + (falseBy.isEmpty ? "" : " — "
          + falseBy.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", ")))

case "trace":
    // Frame by frame through the windows of one gesture: what each judge saw and what fired.
    let model = loadModel(modelPath)
    let want = option("gesture") ?? "openPalm"
    let limit = option("limit").flatMap(Int.init) ?? 3
    var shown = 0
    for rec in loadData() where shown < limit {
        let r = Recognizer(model: model)
        let windows = rec.labels.filter { $0.gesture == want }
        var lastWindow = -1.0
        for frame in rec.frames {
            r.process(frame)
            guard let w = windows.first(where: { frame.time >= $0.start - 0.1 && frame.time <= $0.end + 0.3 }) else { continue }
            if w.start != lastWindow { lastWindow = w.start; shown += 1; print("--- \(rec.info.id) \(w.gesture) \(String(format: "%.2f–%.2f", w.start, w.end))") }
            if shown > limit { break }
            let st = r.status
            let f = r.features
            var line = String(format: "%7.3f ", frame.time)
            line += st.handVisible ? "A=\(Pose(rawValue: st.judgeA)?.name ?? "?")" + String(format: "(%.2f) ", st.judgeAScore) : "no hand(\(st.rejection)) "
            if st.handVisible {
                line += "B=\(Pose(rawValue: st.judgeB.top)?.name ?? "?")" + String(format: "(%.2f/%.2f) ", st.judgeB.confidence, st.judgeB.margin)
                line += "agree=\(st.agreed) " + String(format: "v=(%.1f,%.1f) spd=%.1f ", f[Feature.velocityX.rawValue], f[Feature.velocityY.rawValue], f[Feature.speed.rawValue])
                line += "hold=\(st.holdGesture)" + String(format: "@%.2f", st.holdProgress)
            }
            let events = (0..<r.eventCount).map { "\(r.event($0))" }
            if !events.isEmpty { line += "  ** " + events.joined(separator: " ") }
            print(line)
        }
    }

case "personalize":
    guard let dir = option("enrollment"), let out = option("out") else { fail("personalize needs --enrollment DIR --out FILE") }
    let model = loadModel(modelPath)
    let enrollment = (try? Recording.loadAll(in: URL(fileURLWithPath: dir))) ?? []
    let personal = Trainer.personalize(model, enrollment: enrollment, library: loadData(), log: { print("  " + $0) })
    do { try personal.encoded().write(to: URL(fileURLWithPath: out)) } catch { fail("\(error)") }
    print("Wrote \(out)")

default:
    print("""
    nebula-report train|report|gate|bench|personalize|synth
      --data DIR      recordings (default ~/Library/Application Support/Nebula/Recordings)
      --model FILE    model (default ~/Library/Application Support/Nebula/model.json)
      --out FILE      where train/personalize write
      --json FILE     report as JSON too
      --latency FILE  the app's pipeline latency log (default …/Nebula/latency.json)
    """)
}
