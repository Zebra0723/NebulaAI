import AppKit
import AVFoundation
import NebulaCore

/// Live latency numbers for the Practice screen and Settings.
struct LatencyStats: Equatable {
    var actions = Percentiles([])
    var perFrame = Percentiles([])
    var vision = Percentiles([])
    var recognizer = Percentiles([])
    var captureAge = Percentiles([])
}

/// Nebula's state, owned by the main thread. The pipeline does the per-frame work on its
/// own queue; this decides when the camera is on and keeps the screens up to date.
@MainActor
final class Engine: ObservableObject {
    enum Arming: Equatable {
        case off
        /// Gestures act.
        case armed(since: Date)
        /// Armed for a pending approval only, until the deadline.
        case approval(until: Date)
        /// Practice: the camera is on, gestures are recognized and shown, nothing acts.
        case practice
    }

    @Published private(set) var arming: Arming = .off
    @Published var settings = NebulaSettings.load() { didSet { settingsChanged(oldValue) } }
    @Published private(set) var live = LiveSnapshot()
    @Published private(set) var latency = LatencyStats()
    @Published private(set) var cameraProblem: String?
    @Published private(set) var lightWarning: String?
    @Published private(set) var report: Report?
    @Published private(set) var busy: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var pending: [GalaxyLink.Approval] = []
    @Published private(set) var linkConnected = false
    @Published private(set) var approvalsSupported = true
    @Published private(set) var customs: [SavedCustomGesture] = CustomStore.load()
    @Published private(set) var lastEvent: (text: String, at: Date)?
    @Published var flash = false

    let gate = GateFile.bundled()
    private(set) var model = ModelStore.load() { didSet { modelFingerprint = model.fingerprint } }
    private var modelFingerprint = ""
    let hud = HUD()
    let pipeline: Pipeline
    let router: ActionRouter
    let recorder: Recorder
    private var timers: [Timer] = []
    private var approvalVersion = 0
    private var lastRecentNonFire: (gesture: Int, at: Date)?

    var isCameraOn: Bool { arming != .off }
    var isArmed: Bool {
        switch arming {
        case .armed, .approval: return true
        default: return false
        }
    }

    init() {
        pipeline = Pipeline(model: model)
        router = ActionRouter(hud: hud)
        recorder = Recorder()
        recorder.engine = self
        modelFingerprint = model.fingerprint
        report = Self.loadReport()
        wire()
    }

    private func wire() {
        router.disarm = { [weak self] why in DispatchQueue.main.async { self?.disarm(why) } }
        router.decideApproval = { [weak self] approve, done in
            Task { @MainActor in
                guard let self else { return }
                done(await self.decide(approve: approve))
            }
        }
        router.flashTest = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.flashTestOn else { return }
                self.flash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.flash = false }
            }
        }
        pipeline.router = router
        pipeline.onSnapshot = { [weak self] snap in self?.live = snap }
        pipeline.onEvent = { [weak self] event in self?.observe(event) }
        applyRecognizer()
    }

    /// While on, the Practice view turns white the instant an action posts: film the hand and
    /// the screen in slow motion to measure end-to-end latency.
    @Published var flashTestOn = false

    func start() {
        TargetTracker.shared.onActivate = { target in Adapters.shared.prewarm(target) }
        TargetTracker.shared.start()
        // Configure the camera now, so turning on only has to start it (if access is granted yet).
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { ensureCamera() }
        observeSystem()
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.saveLatency() }
        })
        Task { await self.galaxyLoop() }
        Task { await self.approvalLoop() }
    }

    // MARK: - Arming

    func toggleArmed() {
        if isArmed { disarm("Turned off") } else { arm() }
    }

    @discardableResult
    private func ensureCamera() -> Bool {
        if pipeline.configured { return true }
        do {
            try pipeline.configure(highResolution: settings.highResolution)
            cameraProblem = nil
            return true
        } catch {
            cameraProblem = "No camera available."
            return false
        }
    }

    /// Asks for camera access when it hasn't been decided, then runs `then` if granted.
    private func withCamera(_ then: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if ensureCamera() { then() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { if granted { self.withCamera(then) } }
            }
        default:
            cameraProblem = "Camera access is off. Turn it on for Nebula in System Settings → Privacy & Security → Camera."
            hud.show("Camera access is off", symbol: "video.slash", warn: true)
        }
    }

    func arm() {
        withCamera { self.armNow() }
    }

    private func armNow() {
        guard !isArmed else { return }
        if arming == .practice { turnOff() }
        arming = .armed(since: Date())
        setActions(true)
        pipeline.start()
        hud.show("Nebula on", symbol: "hand.raised")
    }

    func armForApproval() {
        guard settings.approvalMode, arming == .off, AVCaptureDevice.authorizationStatus(for: .video) == .authorized, ensureCamera() else { return }
        arming = .approval(until: Date().addingTimeInterval(60))
        setActions(true)
        pipeline.start()
        hud.show("Waiting for your thumbs up or down", symbol: "hand.thumbsup")
    }

    func startPractice() {
        withCamera { self.startPracticeNow() }
    }

    private func startPracticeNow() {
        guard arming == .off else { return }
        arming = .practice
        setActions(false)
        pipeline.start()
    }

    func stopPractice() {
        if arming == .practice { turnOff() }
    }

    func disarm(_ reason: String) {
        guard arming != .off else { return }
        turnOff()
        note(reason)
    }

    private func turnOff() {
        arming = .off
        setActions(false)
        if recorder.running { recorder.stop() }
        pipeline.stop()
        live = LiveSnapshot()
    }

    private func setActions(_ on: Bool) {
        let p = pipeline
        p.visionQueue.async { p.actionsEnabled = on }
    }

    private func observeSystem() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.disarm("Screen locked") }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.disarm("Mac went to sleep") }
            }
        }
    }

    private func tick() {
        switch arming {
        case .approval(let until) where Date() > until:
            disarm("Approval window ended")
        case .armed:
            if Date().timeIntervalSince(pipeline.lastHandSeen) > settings.autoOffMinutes * 60 {
                disarm("No hand for \(Int(settings.autoOffMinutes)) minutes")
            }
        default:
            break
        }
        if isCameraOn {
            latency = LatencyStats(actions: router.latency.percentiles(), perFrame: pipeline.frameTime.percentiles(),
                                   vision: pipeline.visionTime.percentiles(), recognizer: pipeline.recognizerTime.percentiles(),
                                   captureAge: pipeline.captureAge.percentiles())
            // The frame duration is pinned, so a slower rate means the camera is starved for light.
            let fps = pipeline.measuredFPS
            lightWarning = fps < pipeline.targetFPS * 0.8 && fps > 1
                ? String(format: "The room is too dark to hold %.0f fps (getting %.0f). Turn on a light.", pipeline.targetFPS, fps)
                : nil
        }
    }

    private func saveLatency() {
        let p = router.latency.percentiles()
        guard p.count > 0, let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: Paths.latency, options: .atomic)
    }

    // MARK: - Events (main thread copies, for screens and candidate logging)

    private func observe(_ event: RecognizerEvent) {
        switch event {
        case .fired(let id):
            lastEvent = (titleFor(id), Date())
            // An immediate repeat right after a hold that didn't make it: the first try was a
            // near-miss worth learning from.
            if let miss = lastRecentNonFire, miss.gesture == id, Date().timeIntervalSince(miss.at) < 2 {
                saveCandidate(label: gestureKey(id), kind: .gestures, note: "near-miss before a fire")
            }
            lastRecentNonFire = nil
        case .cancelled(let id):
            lastRecentNonFire = (id, Date())
        default:
            break
        }
    }

    func titleFor(_ id: Int) -> String {
        id >= Recognizer.customBase
            ? (customs.indices.contains(id - Recognizer.customBase) ? customs[id - Recognizer.customBase].spec.name : "Custom")
            : Gesture.at(id).title
    }

    private func gestureKey(_ id: Int) -> String {
        id >= Recognizer.customBase
            ? (customs.indices.contains(id - Recognizer.customBase) ? customs[id - Recognizer.customBase].id : "custom")
            : Gesture.at(id).rawValue
    }

    /// "That was wrong": the last three seconds become a hard negative for the next training run.
    func reportWrongFire() {
        saveCandidate(label: "nearMiss:wrongFire", kind: .nearMiss, note: "wrong fire, from the menu")
        hud.show("Saved as a wrong fire", symbol: "tray.and.arrow.down")
    }

    private func saveCandidate(label: String, kind: SessionInfo.Kind, note: String) {
        pipeline.recentFrames(seconds: 3) { frames in
            guard let first = frames.first?.time, let last = frames.last?.time else { return }
            let info = SessionInfo(id: "candidate-\(Int(Date().timeIntervalSince1970 * 1000))", kind: kind, notes: note)
            let rec = Recording(info: info, frames: frames, labels: [SegmentLabel(gesture: label, start: first, end: last)])
            try? rec.write(to: Paths.candidates.appendingPathComponent(info.id + ".jsonl"))
        }
    }

    // MARK: - Gestures, model and proof

    /// What may act: gestures the newest report on the model in use passed (or the build's gate,
    /// before any report), minus what you've switched off.
    var proven: Set<String> {
        var set: Set<String>
        // Proof is for one exact model: change the model (calibration, a custom gesture) and the
        // report has to be run again before anything acts.
        let fingerprint = modelFingerprint
        if let report, report.modelFingerprint == fingerprint, !report.synthetic {
            set = Set(report.passing)
        } else if gate.mode != "recorder" && gate.modelFingerprint == fingerprint {
            set = Set(gate.passing)
        } else {
            set = []
        }
        for c in customs where c.recall >= 0.99 { set.insert(c.id) }
        return set
    }

    func isOn(_ key: String) -> Bool { !settings.disabled.contains(key) }

    func setOn(_ key: String, _ on: Bool) {
        if on { settings.disabled.remove(key) } else { settings.disabled.insert(key) }
    }

    private func settingsChanged(_ old: NebulaSettings) {
        settings.save()
        if old.highResolution != settings.highResolution && pipeline.configured {
            let wasOn = isCameraOn
            pipeline.stop()
            try? pipeline.configure(highResolution: settings.highResolution)
            if wasOn { pipeline.start() }
        }
        applyRecognizer()
    }

    func applyRecognizer() {
        var m = model
        if settings.careful {
            for g in Gesture.allCases where g.kind != .movement {
                var t = m.tuning(for: g)
                t.hold += 0.1
                m.tuning[g.rawValue] = t
            }
        }
        var holds: [Int: Double] = [:]
        for g in Gesture.allCases { holds[g.index] = m.tuning(for: g).hold }
        for (i, c) in customs.enumerated() { holds[Recognizer.customBase + i] = c.gesture.tuning.hold }
        pipeline.use(model: m, customs: customs.map(\.gesture), disabled: settings.disabled)
        let router = self.router, settings = self.settings, customs = self.customs, proven = self.proven
        pipeline.visionQueue.async {
            router.settings = settings
            router.customs = customs
            router.holdLengths = holds
            router.proven = proven
        }
    }

    static func loadReport() -> Report? {
        guard let data = try? Data(contentsOf: Paths.report) else { return nil }
        return try? JSONDecoder().decode(Report.self, from: data)
    }

    /// Trains on your recordings (train sessions), tunes on validation, and measures on the
    /// held-out test sessions. The report decides which gestures may act.
    func trainAndReport() {
        guard busy == nil else { return }
        busy = "Training on your recordings…"
        let base = model
        let customGestures = customs.map(\.gesture)
        let latencyLog = router.latency
        Task.detached(priority: .userInitiated) {
            let all = (try? Recording.loadAll(in: Paths.recordings)) ?? []
            let usable = all.filter { $0.info.kind != .enrollment }
            let (train, validation, test) = Trainer.split(usable)
            guard !train.isEmpty, !test.isEmpty else {
                await MainActor.run {
                    self.busy = nil
                    self.note("Not enough recordings to report on yet: record at least four sessions of each kind.")
                    if all.contains(where: { $0.info.kind == .enrollment }) { self.personalize() }
                }
                return
            }
            var trained = Trainer.train(train, validation: validation, base: base, source: "recorded")
            let enrollment = all.filter { $0.info.kind == .enrollment }
            if !enrollment.isEmpty || !customGestures.isEmpty {
                trained = Trainer.personalize(trained, enrollment: enrollment, library: usable, customs: customGestures)
            }
            let final = trained
            let evaluation = Evaluator.evaluate(test, model: final)
            let pipelineLatency = latencyLog.percentiles()
            let report = Report.make(evaluation: evaluation, model: final, synthetic: test.contains { $0.info.synthetic },
                                     pipeline: pipelineLatency.count > 0 ? pipelineLatency : nil)
            try? ModelStore.save(final)
            if let data = try? JSONEncoder().encode(report) { try? data.write(to: Paths.report, options: .atomic) }
            await MainActor.run {
                self.model = final
                self.report = report
                self.busy = nil
                self.applyRecognizer()
                self.note(report.pass ? "Every target met." : "Report ready: some targets missed.")
            }
        }
    }

    /// Personal calibration after enrollment.
    func personalize() {
        guard busy == nil else { return }
        busy = "Fitting Nebula to your hands…"
        let base = model
        let customGestures = customs.map(\.gesture)
        Task.detached(priority: .userInitiated) {
            let all = (try? Recording.loadAll(in: Paths.recordings)) ?? []
            let enrollment = all.filter { $0.info.kind == .enrollment }
            let library = all.filter { $0.info.kind != .enrollment }
            var lines: [String] = []
            let personal = Trainer.personalize(base, enrollment: enrollment, library: library, customs: customGestures,
                                               log: { lines.append($0) })
            try? ModelStore.save(personal)
            let notes = lines
            await MainActor.run {
                self.model = personal
                self.busy = nil
                self.applyRecognizer()
                notes.forEach { self.note($0) }
                self.note("Calibrated. Run the report to see which gestures meet their targets.")
            }
        }
    }

    // MARK: - Custom gestures

    /// Saves a verified custom gesture with the model it was verified on, and that model's report
    /// (Judge B relearned every pose, so the built-in gestures were measured again too).
    func saveCustom(_ saved: SavedCustomGesture, model newModel: NebulaModel, report newReport: Report?) {
        customs.removeAll { $0.id == saved.id }
        customs.append(saved)
        CustomStore.save(customs)
        model = newModel
        try? ModelStore.save(newModel)
        if let newReport {
            report = newReport
            if let data = try? JSONEncoder().encode(newReport) { try? data.write(to: Paths.report, options: .atomic) }
        }
        applyRecognizer()
    }

    func removeCustom(_ id: String) {
        customs.removeAll { $0.id == id }
        // Labels follow list order: renumber, then Judge B relearns without the removed one.
        for i in customs.indices { customs[i].gesture.label = Pose.builtinCount + i }
        CustomStore.save(customs)
        applyRecognizer()
        trainAndReport()
    }

    /// Recordings of custom gestures (kept with the enrollment sessions).
    func customRecordings() -> [Recording] {
        ((try? Recording.loadAll(in: Paths.enrollment)) ?? []).filter { $0.info.notes.hasPrefix("custom:") }
    }

    var currentModel: NebulaModel { model }

    // MARK: - Galaxy

    private func galaxyLoop() async {
        while true {
            let ok = await GalaxyLink.shared.heartbeat()
            linkConnected = ok
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    /// Long-polls pending approvals: the camera arms the moment a body starts waiting.
    private func approvalLoop() async {
        while true {
            if let response = await GalaxyLink.shared.pendingApprovals(since: approvalVersion) {
                approvalVersion = response.version
                let hadNone = pending.isEmpty
                pending = response.pending
                approvalsSupported = true
                if hadNone && !pending.isEmpty { armForApproval() }
            } else {
                approvalsSupported = await GalaxyLink.shared.approvalsSupported
                // Link down or too old for approvals: try again in a while, not in a tight loop.
                try? await Task.sleep(nanoseconds: (approvalsSupported ? 5 : 300) * 1_000_000_000)
            }
        }
    }

    /// Thumbs up or down: decides the oldest pending approval.
    func decide(approve: Bool) async -> String {
        guard let first = pending.sorted(by: { $0.createdAt < $1.createdAt }).first else {
            return linkConnected ? "Nothing is waiting for a yes or no" : "Galaxy Link isn't running"
        }
        guard let decided = await GalaxyLink.shared.decide(first.id, approve: approve) else {
            return "Couldn't reach Galaxy Link"
        }
        pending.removeAll { $0.id == decided.id }
        if case .approval = arming, pending.isEmpty { disarm("Approval answered") }
        return "\(approve ? "Approved" : "Rejected"): \(decided.title)"
    }

    func note(_ line: String) {
        log.insert(line, at: 0)
        if log.count > 50 { log.removeLast() }
    }
}
