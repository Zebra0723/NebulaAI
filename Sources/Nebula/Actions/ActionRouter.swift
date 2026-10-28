import AppKit
import ApplicationServices
import NebulaCore

/// Turns recognizer events into actions, on the vision queue, the moment they happen.
/// Window actions resolve their target at the instant of firing and go only to the
/// frontmost app's focused window. Every action is timed from the camera frame's arrival
/// to the moment it's posted, and checked afterwards, off the hot path.
final class ActionRouter: @unchecked Sendable {
    /// Camera frame delivered → action posted, milliseconds.
    let latency = LatencyLog(capacity: 4096)

    /// Hooks into the rest of the app (all called off the vision queue or async).
    var disarm: (String) -> Void = { _ in }
    var decideApproval: (Bool, @escaping (String) -> Void) -> Void = { _, done in done("Galaxy Link isn't connected") }
    var flashTest: () -> Void = {}
    let hud: HUD

    var settings = NebulaSettings()
    var customs: [SavedCustomGesture] = []
    var holdLengths: [Int: Double] = [:]
    /// Gestures the accuracy gate proved (raw values and custom ids). Others never act.
    var proven: Set<String> = []

    private var scroll: (target: WindowTarget, mapping: ScrollMapping, carry: Double, lastTime: Double)?
    /// Where the scroll area was when scrolling began, read off the hot path.
    private let probeLock = NSLock()
    private var probeStart: Double?
    /// Set when scrolls sent straight to the app didn't move it: deliver at the point instead.
    private var scrollAtPoint = false
    private var knobEngaged = false

    init(hud: HUD) {
        self.hud = hud
    }

    // MARK: - Events

    /// Called on the vision queue for each event, with the frame's arrival time (ns, monotonic).
    func handle(_ event: RecognizerEvent, arrival: UInt64, frameTime: Double) {
        switch event {
        case .cue(let id):
            hud.showHold(title: title(id), seconds: holdLengths[id] ?? 0.15)
        case .cancelled:
            hud.cancelHold()
        case .fired(let id):
            fire(id, arrival: arrival, frameTime: frameTime)
        case .scroll(let delta):
            scrollStep(delta, arrival: arrival, frameTime: frameTime)
        case .volume(let step):
            guard knobEngaged else { return }
            if let level = SystemVolume.step(step) {
                record(arrival)
                hud.show(String(format: "Volume %.0f%%", level * 100), symbol: step > 0 ? "speaker.wave.3" : "speaker.wave.1")
            }
        case .ended(let id):
            if id == Gesture.scroll.index { endScroll() }
            if id == Gesture.volumeKnob.index { knobEngaged = false }
        }
    }

    private func title(_ id: Int) -> String {
        if id >= Recognizer.customBase {
            let i = id - Recognizer.customBase
            return i < customs.count ? customs[i].spec.name : "Custom gesture"
        }
        return Gesture.at(id).title
    }

    private func record(_ arrival: UInt64) {
        latency.record(Float(Double(Monotonic.nanoseconds() &- arrival) / 1e6))
    }

    private func allowed(_ key: String) -> Bool {
        proven.contains(key) && !settings.disabled.contains(key)
    }

    private func fire(_ id: Int, arrival: UInt64, frameTime: Double) {
        if id >= Recognizer.customBase {
            let i = id - Recognizer.customBase
            guard i < customs.count, allowed(customs[i].id) else { return }
            runCustom(customs[i], arrival: arrival)
            return
        }
        let g = Gesture.at(id)
        guard allowed(g.rawValue) else {
            hud.show("\(g.title) isn't proven yet", symbol: "exclamationmark.circle", warn: true)
            return
        }
        flashTest()
        switch g {
        case .openPalm, .swipeLeft, .swipeRight:
            windowAction(WindowAction(g)!, gesture: g, arrival: arrival)
        case .scroll:
            beginScroll(arrival: arrival, frameTime: frameTime)
        case .volumeKnob:
            knobEngaged = true
            hud.show("Volume knob", symbol: "dial.medium")
        case .thumbsUp, .thumbsDown:
            let approve = g == .thumbsUp
            record(arrival)
            decideApproval(approve) { [hud] text in hud.show(text, symbol: approve ? "hand.thumbsup" : "hand.thumbsdown") }
        case .peace:
            summonNova(arrival: arrival)
        case .fingerToLips, .handToEar:
            let mute = g == .fingerToLips
            record(arrival)
            Orbit.set(muted: mute) { [hud] ok, text in
                hud.show(text, symbol: mute ? "speaker.slash" : "speaker.wave.2", warn: !ok)
                ActionLog.write("\(g.rawValue) → \(text)")
            }
        case .wave:
            record(arrival)
            disarm("You waved")
        }
    }

    // MARK: - Window actions

    /// How long before the fire the gesture began: a front-app change inside it cancels the action.
    private func gestureSpan(_ g: Gesture) -> Double {
        g.kind == .movement ? 0.8 : (holdLengths[g.index] ?? 0.15) + 0.35
    }

    private func windowAction(_ action: WindowAction, gesture g: Gesture, arrival: UInt64) {
        let snap = TargetTracker.shared.snapshot(changedWithin: gestureSpan(g))
        let decision = TargetPolicy.decide(action, startPID: snap.changedRecently ? -1 : snap.target?.pid, current: snap.target)
        guard case .deliver(let target, let adapter) = decision else {
            if case .nothing(let why) = decision { hud.show(why, symbol: "circle.dashed") }
            ActionLog.write("\(g.rawValue) → nothing: \(decision)")
            return
        }
        // The last check, just before posting.
        guard TargetTracker.shared.stillFrontmost(target.pid) else {
            hud.show("The app changed during the gesture", symbol: "circle.dashed")
            return
        }
        Adapters.shared.perform(action, on: target, adapter: adapter) { [hud] outcome in
            if outcome.verified == false {
                hud.show("Didn't work: \(outcome.text)", symbol: "exclamationmark.triangle", warn: true)
            } else {
                hud.show(outcome.text, symbol: Self.symbol(action))
            }
            ActionLog.write("\(g.rawValue) → \(target.bundleID) \"\(target.windowTitle)\": \(outcome.text) verified=\(outcome.verified.map { "\($0)" } ?? "unknown")")
        }
        record(arrival)
    }

    private static func symbol(_ action: WindowAction) -> String {
        switch action {
        case .next: return "arrow.right"
        case .previous: return "arrow.left"
        case .playPause: return "playpause"
        case .scroll: return "arrow.up.and.down"
        }
    }

    // MARK: - Scroll

    private func beginScroll(arrival: UInt64, frameTime: Double) {
        let snap = TargetTracker.shared.snapshot(changedWithin: gestureSpan(.scroll))
        let decision = TargetPolicy.decide(.scroll, startPID: snap.changedRecently ? -1 : snap.target?.pid, current: snap.target)
        guard case .deliver(let target, _) = decision else {
            if case .nothing(let why) = decision { hud.show(why, symbol: "circle.dashed") }
            return
        }
        var mapping = ScrollMapping()
        mapping.natural = settings.naturalScroll
        let point = TargetPolicy.scrollPoint(target)
        scroll = (target, mapping, 0, frameTime)
        guard AXIsProcessTrusted() else {
            hud.show("Scrolling needs Accessibility: menu bar → Grant Accessibility", symbol: "exclamationmark.triangle", warn: true)
            scroll = nil
            return
        }
        probeLock.locked {
            probeStart = nil
            scrollAtPoint = false
        }
        let where_ = CGPoint(x: point.x, y: point.y)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let start = ScrollProbe.position(at: where_)
            self?.probeLock.locked { self?.probeStart = start }
        }
        // Half a second in: if the window hasn't moved, this app ignores scrolls sent to it
        // directly, so deliver them at the point inside its window instead.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let start = self.probeLock.locked { self.probeStart }
            guard let start, let now = ScrollProbe.position(at: where_), abs(now - start) < 0.0005 else { return }
            self.probeLock.locked { self.scrollAtPoint = true }
            ActionLog.write("scroll → \(target.bundleID) ignored direct scrolls; delivering at the window's point")
        }
        record(arrival)
        hud.show("Scrolling · \(target.appName)", symbol: "arrow.up.and.down")
    }

    private func scrollStep(_ delta: Float, arrival: UInt64, frameTime: Double) {
        guard var s = scroll else { return }
        let dt = min(max(frameTime - s.lastTime, 1.0 / 120), 0.1)
        s.lastTime = frameTime
        s.carry += s.mapping.pixels(delta: delta, dt: dt)
        let whole = s.carry.rounded(.towardZero)
        s.carry -= whole
        scroll = s
        guard whole != 0, TargetTracker.shared.stillFrontmost(s.target.pid) else { return }
        let point = TargetPolicy.scrollPoint(s.target)
        KeyEvents.scroll(pixels: Int32(clamping: Int(whole)), at: CGPoint(x: point.x, y: point.y), toPID: s.target.pid,
                         direct: probeLock.locked { !scrollAtPoint })
        record(arrival)
    }

    private func endScroll() {
        guard let s = scroll else { return }
        scroll = nil
        let point = TargetPolicy.scrollPoint(s.target)
        let start = probeLock.locked { probeStart }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) { [hud] in
            let end = ScrollProbe.position(at: CGPoint(x: point.x, y: point.y))
            if let start, let end, abs(start - end) < 0.0005 {
                hud.show("Didn't scroll: \(s.target.appName)", symbol: "exclamationmark.triangle", warn: true)
                ActionLog.write("scroll → \(s.target.bundleID): didn't move")
            } else {
                ActionLog.write("scroll → \(s.target.bundleID): moved \(start.map { String($0) } ?? "?") → \(end.map { String($0) } ?? "?")")
            }
        }
    }

    // MARK: - Galaxy and custom

    private func summonNova(arrival: UInt64) {
        guard let nova = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.galaxy.nova").first else {
            hud.show("Nova isn't running", symbol: "sparkle", warn: true)
            return
        }
        let before = Self.onScreenWindows(nova.processIdentifier)
        KeyEvents.pressGlobally(KeyCombo(keyCode: 49, control: true, key: "space"))
        record(arrival)
        // Check it worked: Nova's panel is a new on-screen window. If ⌃Space didn't reach it
        // (another app or an input-source shortcut took it), open Nova directly instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [hud] in
            if Self.onScreenWindows(nova.processIdentifier) > before {
                hud.show("Nova", symbol: "sparkle")
                ActionLog.write("peace → Nova (⌃Space)")
            } else {
                if let url = nova.bundleURL {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
                hud.show("Nova (⌃Space didn't reach it, so opened it)", symbol: "sparkle")
                ActionLog.write("peace → ⌃Space had no effect; opened Nova directly")
            }
        }
    }

    /// How many of an app's windows are on screen right now.
    private static func onScreenWindows(_ pid: pid_t) -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }.count
    }

    private func runCustom(_ custom: SavedCustomGesture, arrival: UInt64) {
        switch custom.spec.action {
        case .keys(let text):
            guard let combo = KeyCombo.parse(text) else { return }
            let snap = TargetTracker.shared.snapshot(changedWithin: custom.spec.hold + 0.35)
            // Same rule as every window action: the frontmost focused window, or nothing.
            let decision = TargetPolicy.decide(.scroll, startPID: snap.changedRecently ? -1 : snap.target?.pid, current: snap.target)
            guard case .deliver(let target, _) = decision, TargetTracker.shared.stillFrontmost(target.pid) else {
                if case .nothing(let why) = decision { hud.show(why, symbol: "circle.dashed") }
                return
            }
            KeyEvents.press(combo, toPID: target.pid)
            record(arrival)
            hud.show("\(combo.display) · \(target.appName)", symbol: "keyboard")
        case .window(let name):
            let action: WindowAction = name == "next" ? .next : (name == "previous" ? .previous : .playPause)
            windowAction(action, gesture: action == .next ? .swipeRight : (action == .previous ? .swipeLeft : .openPalm), arrival: arrival)
        case .galaxy(let name):
            switch name {
            case "summonNova": summonNova(arrival: arrival)
            case "muteOrbit", "unmuteOrbit":
                record(arrival)
                Orbit.set(muted: name == "muteOrbit") { [hud] ok, text in hud.show(text, symbol: "speaker.slash", warn: !ok) }
            case "approve", "reject":
                record(arrival)
                decideApproval(name == "approve") { [hud] text in hud.show(text, symbol: "checkmark.circle") }
            default: break
            }
        }
        ActionLog.write("custom \(custom.id) → \(custom.spec.action.summary)")
    }
}
