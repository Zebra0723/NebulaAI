import CoreMedia
import Foundation
import NebulaCore

/// The recorder in the Practice screen: guided sessions that save labelled joint
/// sequences, never images. Each prompt's "Now" window becomes a label on the
/// camera's own clock, so labels and frames line up exactly.
@MainActor
final class Recorder: ObservableObject {
    enum Plan: String, CaseIterable, Identifiable {
        case quickStart, gestures, nothing, nearMiss, enrollment
        var id: String { rawValue }
        var title: String {
            switch self {
            case .quickStart: return "Quick start (10 min)"
            case .gestures: return "Gesture session"
            case .nothing: return "Ordinary use (\"nothing\")"
            case .nearMiss: return "Near-misses"
            case .enrollment: return "Enrollment"
            }
        }
    }

    struct Conditions: Equatable {
        var lighting = "daylight"
        var distanceCm = 70
        var hand = "right"
        var reps = 10
        var minutes = 10.0
    }

    @Published private(set) var running = false
    @Published private(set) var prompt = ""
    @Published private(set) var detail = ""
    @Published private(set) var phase = "" // "ready", "now", "rest"
    @Published private(set) var progress = 0.0
    @Published private(set) var savedSessions = 0
    weak var engine: Engine?
    private var writer: RecordingWriter?
    private var task: Task<Void, Never>?

    /// Every label a gesture session asks for. The knob is two: one each way.
    static let gestureLabels: [(label: String, title: String, movement: String, seconds: Double)] = Gesture.allCases.flatMap { g -> [(label: String, title: String, movement: String, seconds: Double)] in
        let seconds: Double = g.kind == .continuous ? 3.2 : (g.kind == .movement ? 2.2 : 2.0)
        if g == .volumeKnob {
            return [("volumeUp", "Volume up", "Pinch the knob, then twist clockwise", seconds),
                    ("volumeDown", "Volume down", "Pinch the knob, then twist counter-clockwise", seconds)]
        }
        return [(g.rawValue, g.title, g.movement, seconds)]
    }

    static let nearMisses: [(label: String, prompt: String)] = [
        ("restingOpen", "Rest an open hand on the desk"),
        ("twoLoose", "Raise two fingers loosely, not a V and not together"),
        ("fistNoThumb", "Make a fist with the thumb tucked in"),
        ("scratchChin", "Scratch your chin"),
        ("scratchEar", "Scratch near your ear"),
        ("nearMouth", "Rest your hand near your mouth"),
        ("pointUp", "Point a finger up, away from your face"),
        ("thumbSideways", "Fist with the thumb pointing sideways"),
        ("touchHair", "Touch your hair"),
        ("okSign", "Make an OK sign"),
        ("palmAway", "Show the back of your flat hand"),
        ("slowWave", "Move an open hand slowly sideways, as if talking"),
    ]

    static let activities = [
        "Type for a while", "Use the trackpad or mouse", "Drink something", "Touch your face and hair",
        "Talk with your hands", "Stretch", "Pick up your phone and use it", "Reach across the desk",
        "Eat a snack", "Lean back and rest your hands",
    ]

    /// Seconds on the clock frames are stamped with (the Mac's host clock).
    private static func clock() -> Double { Monotonic.seconds() }

    /// Quick start: 8 of each gesture, then 3 minutes of ordinary use, then Nebula fits itself to
    /// your hands and turns trial mode on. Enough to try every gesture; not enough to prove them.
    private func runQuickStart(_ c: Conditions) {
        guard !running, let engine else { return }
        guard open(kind: .enrollment, folder: Paths.enrollment, id: "quickstart-gestures-\(Int(Date().timeIntervalSince1970))", c) else { return }
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            await self.runGestures(reps: 8)
            guard !Task.isCancelled else { return }
            self.closeWriter()
            guard self.open(kind: .nothing, folder: Paths.recordings, id: "quickstart-nothing-\(Int(Date().timeIntervalSince1970))", c) else { return }
            await self.runNothing(minutes: 3)
            self.stop(saved: !Task.isCancelled)
            if !Task.isCancelled {
                engine.settings.trial = true
                engine.personalize()
            }
        }
    }

    private func open(kind: SessionInfo.Kind, folder: URL, id: String, _ c: Conditions) -> Bool {
        guard let engine else { return false }
        let info = SessionInfo(id: id, kind: kind, lighting: c.lighting, distanceCm: c.distanceCm, hands: c.hand,
                               notes: engine.pipeline.resolution, fps: engine.pipeline.targetFPS)
        guard let writer = try? RecordingWriter(url: folder.appendingPathComponent(id + ".jsonl"), info: info) else { return false }
        self.writer = writer
        if engine.arming == .off { engine.startPractice() }
        let pipeline = engine.pipeline
        pipeline.visionQueue.async { pipeline.recorder = writer }
        return true
    }

    private func closeWriter() {
        guard let engine, let writer else { return }
        let pipeline = engine.pipeline
        pipeline.visionQueue.async {
            pipeline.recorder = nil
            writer.close()
        }
        self.writer = nil
        savedSessions += 1
    }

    func start(_ plan: Plan, _ c: Conditions) {
        // Recording never acts on your windows: if gestures are on, switch them off first.
        if let engine, engine.isArmed { engine.disarm("Recording") }
        if plan == .quickStart { return runQuickStart(c) }
        guard !running, let engine else { return }
        let id = "\(plan.rawValue)-\(Int(Date().timeIntervalSince1970))"
        let kind: SessionInfo.Kind = plan == .gestures ? .gestures : plan == .nothing ? .nothing : plan == .nearMiss ? .nearMiss : .enrollment
        let folder = plan == .enrollment ? Paths.enrollment : Paths.recordings
        let info = SessionInfo(id: id, kind: kind, lighting: c.lighting, distanceCm: c.distanceCm, hands: c.hand,
                               notes: engine.pipeline.resolution, fps: engine.pipeline.targetFPS)
        guard let writer = try? RecordingWriter(url: folder.appendingPathComponent(id + ".jsonl"), info: info) else { return }
        self.writer = writer
        if engine.arming == .off { engine.startPractice() }
        let pipeline = engine.pipeline
        pipeline.visionQueue.async { pipeline.recorder = writer }
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            switch plan {
            case .gestures: await self.runGestures(reps: c.reps)
            case .enrollment: await self.runGestures(reps: 10)
            case .nearMiss: await self.runNearMisses(reps: c.reps)
            case .nothing: await self.runNothing(minutes: c.minutes)
            case .quickStart: break
            }
            self.stop(saved: !Task.isCancelled)
            if plan == .enrollment && !Task.isCancelled { self.engine?.personalize() }
        }
    }

    /// Records examples of a custom gesture being created: `reps` prompted windows labelled with its id.
    func startCustom(id: String, title: String, movement: String, reps: Int, done: @escaping () -> Void) {
        guard !running, let engine else { return }
        if engine.isArmed { engine.disarm("Recording") }
        let sessionID = "custom-\(id)-\(Int(Date().timeIntervalSince1970))"
        let info = SessionInfo(id: sessionID, kind: .enrollment, notes: "custom:\(id)", fps: engine.pipeline.targetFPS)
        guard let writer = try? RecordingWriter(url: Paths.enrollment.appendingPathComponent(sessionID + ".jsonl"), info: info) else { return }
        self.writer = writer
        if engine.arming == .off { engine.startPractice() }
        let pipeline = engine.pipeline
        pipeline.visionQueue.async { pipeline.recorder = writer }
        running = true
        task = Task { [weak self] in
            guard let self else { return }
            for i in 0..<reps {
                self.progress = Double(i) / Double(reps)
                self.phase = "ready"
                self.prompt = "Get ready: \(title)"
                self.detail = movement
                guard await self.wait(1.3) else { return }
                self.phase = "now"
                self.prompt = "Now: \(title)"
                let start = Self.clock()
                guard await self.wait(2.0) else { return }
                self.writer?.append(SegmentLabel(gesture: id, start: start, end: Self.clock()))
                self.phase = "rest"
                self.prompt = "Rest"
                guard await self.wait(1.2) else { return }
            }
            self.stop(saved: true)
            done()
        }
    }

    func stop(saved: Bool = true) {
        task?.cancel()
        task = nil
        if let engine, let writer {
            let pipeline = engine.pipeline
            pipeline.visionQueue.async {
                pipeline.recorder = nil
                writer.close()
            }
        }
        if writer != nil && saved { savedSessions += 1 }
        writer = nil
        running = false
        prompt = ""
        detail = ""
        phase = ""
    }

    private func wait(_ seconds: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        return !Task.isCancelled
    }

    private func runGestures(reps: Int) async {
        var order: [(String, String, String, Double)] = []
        for _ in 0..<reps { order += Self.gestureLabels.map { ($0.label, $0.title, $0.movement, $0.seconds) } }
        order.shuffle()
        for (i, item) in order.enumerated() {
            progress = Double(i) / Double(order.count)
            phase = "ready"
            prompt = "Get ready: \(item.1)"
            detail = item.2
            guard await wait(1.3) else { return }
            phase = "now"
            prompt = "Now: \(item.1)"
            let start = Self.clock()
            guard await wait(item.3) else { return }
            writer?.append(SegmentLabel(gesture: item.0, start: start, end: Self.clock()))
            phase = "rest"
            prompt = "Rest"
            detail = "Lower your hand"
            guard await wait(1.2) else { return }
        }
        progress = 1
    }

    private func runNearMisses(reps: Int) async {
        var order: [(String, String)] = []
        for _ in 0..<reps { order += Self.nearMisses.map { ($0.label, $0.prompt) } }
        order.shuffle()
        for (i, item) in order.enumerated() {
            progress = Double(i) / Double(order.count)
            phase = "ready"
            prompt = "Get ready"
            detail = item.1
            guard await wait(1.3) else { return }
            phase = "now"
            prompt = item.1
            let start = Self.clock()
            guard await wait(3) else { return }
            writer?.append(SegmentLabel(gesture: "nearMiss:\(item.0)", start: start, end: Self.clock()))
            phase = "rest"
            prompt = "Rest"
            guard await wait(1) else { return }
        }
        progress = 1
    }

    private func runNothing(minutes: Double) async {
        let total = minutes * 60
        let start = Date()
        var i = 0
        while Date().timeIntervalSince(start) < total {
            phase = "now"
            prompt = "Use your Mac as you normally would"
            detail = "Next: " + Self.activities[i % Self.activities.count] + ". Don't make any gestures."
            progress = Date().timeIntervalSince(start) / total
            i += 1
            guard await wait(min(60, total - Date().timeIntervalSince(start))) else { return }
        }
        progress = 1
    }
}
