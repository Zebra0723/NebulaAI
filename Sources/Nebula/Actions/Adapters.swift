import AppKit
import ApplicationServices
import NebulaCore

/// What an action did, as far as Nebula could tell.
struct ActionOutcome {
    var text: String
    /// true: the effect was read back. false: it demonstrably didn't happen. nil: can't tell.
    var verified: Bool?
}

/// One adapter per app: how a window action reaches that app and only that app.
/// Keys and scrolls are CGEvents posted to the app's pid. Media and slides go through
/// the app's own interface (Apple Events to that app, JavaScript in the active tab of
/// that browser window). Scripts are compiled once, and each app's Apple Event
/// connection is warmed up the moment the app comes to the front, so the call is
/// already fast when a gesture fires.
final class Adapters {
    static let shared = Adapters()

    /// Apple Events run here, one at a time, never on the vision queue or the main thread.
    private let queue = DispatchQueue(label: "ai.galaxy.nebula.appleevents", qos: .userInteractive)
    private var scripts: [String: NSAppleScript] = [:]
    private var previewItems: [pid_t: (next: AXUIElement, previous: AXUIElement)] = [:]

    // MARK: - Pre-warming

    /// Called when an app comes to the front.
    func prewarm(_ target: WindowTarget) {
        let adapter = AppAdapter.forBundle(target.bundleID)
        guard adapter != .other else { return }
        queue.async {
            // Compiling loads the scripting component; one harmless event opens the connection
            // (and asks for Automation permission now, not mid-gesture).
            switch adapter {
            case .safari, .chrome, .arc:
                _ = self.script(Self.playPauseSource(adapter))
                self.run(Self.ping(target.bundleID))
            case .keynote:
                _ = self.script(Self.keynoteSource(next: true))
                _ = self.script(Self.keynoteSource(next: false))
                self.run(Self.ping(target.bundleID))
            case .spotify, .music:
                for verb in ["next track", "previous track", "playpause"] { _ = self.script(Self.playerSource(target.bundleID, verb)) }
                self.run(Self.ping(target.bundleID))
            case .preview:
                self.findPreviewItems(pid: target.pid)
            case .other:
                break
            }
        }
    }

    // MARK: - Actions

    /// Performs a window action on `target` with `adapter`. Keystrokes post immediately on the
    /// calling (vision) queue; Apple Events go to the Apple Event queue. `done` gets the
    /// outcome once the effect has been checked, off the hot path.
    func perform(_ action: WindowAction, on target: WindowTarget, adapter: AppAdapter, done: @escaping (ActionOutcome) -> Void) {
        let name = target.appName
        switch (adapter, action) {
        case (.safari, .next), (.chrome, .next):
            keyAndCheckTitle(KeyCombo(keyCode: 30, command: true, shift: true, key: "]"), target, "Next tab · \(name)", done)
        case (.safari, .previous), (.chrome, .previous):
            keyAndCheckTitle(KeyCombo(keyCode: 33, command: true, shift: true, key: "["), target, "Previous tab · \(name)", done)
        case (.arc, .next):
            keyAndCheckTitle(KeyCombo(keyCode: 125, command: true, option: true, key: "down"), target, "Next tab · \(name)", done)
        case (.arc, .previous):
            keyAndCheckTitle(KeyCombo(keyCode: 126, command: true, option: true, key: "up"), target, "Previous tab · \(name)", done)
        case (.safari, .playPause), (.chrome, .playPause), (.arc, .playPause):
            queue.async {
                let result = self.run(Self.playPauseSource(adapter))
                let label = target.windowTitle.isEmpty ? name : Self.short(target.windowTitle)
                switch result {
                case "playing": done(ActionOutcome(text: "Playing · \(label)", verified: true))
                case "paused": done(ActionOutcome(text: "Paused · \(label)", verified: true))
                case "none": done(ActionOutcome(text: "Nothing playing in this tab", verified: false))
                default:
                    // Without JavaScript, YouTube still has its own play/pause key: K, sent to this browser only.
                    if Self.isYouTube(target.windowTitle) {
                        KeyEvents.press(KeyCombo(keyCode: 40, key: "k"), toPID: target.pid)
                        ActionLog.write("play/pause: script refused (\(self.lastError?.number ?? 0)), pressed K for YouTube")
                        done(ActionOutcome(text: "Play/pause · YouTube", verified: nil))
                    } else {
                        done(ActionOutcome(text: self.browserFailure(name), verified: false))
                    }
                }
            }
        case (.keynote, .next), (.keynote, .previous):
            let next = action == .next
            queue.async {
                let before = self.run(Self.keynoteSlideSource)
                let after = self.run(Self.keynoteSource(next: next))
                let moved = before != nil && after != nil && before != after
                done(ActionOutcome(text: "\(next ? "Next" : "Previous") slide · Keynote" + (after.map { " (\($0))" } ?? ""),
                                   verified: after == nil ? false : moved))
            }
        case (.preview, .next), (.preview, .previous):
            queue.async {
                let before = TargetTracker.shared.liveTitle()
                guard let items = self.previewItems[target.pid] ?? self.findPreviewItems(pid: target.pid) else {
                    return done(ActionOutcome(text: "Couldn't find Preview's Go menu", verified: false))
                }
                let item = action == .next ? items.next : items.previous
                let ok = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                usleep(200_000)
                let after = TargetTracker.shared.liveTitle()
                done(ActionOutcome(text: "\(action == .next ? "Next" : "Previous") page · Preview",
                                   verified: ok ? (before != after ? true : nil) : false))
            }
        case (.spotify, _), (.music, _):
            let verb = action == .next ? "next track" : (action == .previous ? "previous track" : "playpause")
            queue.async {
                let before = self.run(Self.playerStateSource(target.bundleID))
                _ = self.run(Self.playerSource(target.bundleID, verb))
                usleep(350_000)
                let after = self.run(Self.playerStateSource(target.bundleID))
                let changed = before != nil && after != nil && before != after
                let text: String
                switch action {
                case .next: text = "Next track · \(name)"
                case .previous: text = "Previous track · \(name)"
                default: text = (after?.hasSuffix("|playing") == true ? "Playing · " : "Paused · ") + name
                }
                done(ActionOutcome(text: text, verified: after == nil ? false : changed))
            }
        default:
            done(ActionOutcome(text: "Nothing to control in \(name)", verified: nil))
        }
    }

    private func keyAndCheckTitle(_ combo: KeyCombo, _ target: WindowTarget, _ text: String, _ done: @escaping (ActionOutcome) -> Void) {
        let before = target.windowTitle
        KeyEvents.press(combo, toPID: target.pid)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            let after = TargetTracker.shared.liveTitle()
            done(ActionOutcome(text: text, verified: after.map { $0 != before }))
        }
    }

    // MARK: - Scripts

    private func script(_ source: String) -> NSAppleScript? {
        if let s = scripts[source] { return s }
        guard let s = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        s.compileAndReturnError(&error)
        scripts[source] = s
        return s
    }

    /// Runs a compiled script on the Apple Event queue (call from that queue). nil on error.
    @discardableResult
    private func run(_ source: String) -> String? {
        lastError = nil
        guard let s = script(source) else {
            lastError = (0, "couldn't compile the script")
            return nil
        }
        var error: NSDictionary?
        let result = s.executeAndReturnError(&error)
        if let error {
            lastError = ((error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0,
                         error[NSAppleScript.errorMessage] as? String ?? "unknown error")
            return nil
        }
        return result.stringValue ?? ""
    }

    /// The last script error on the Apple Event queue: its number and the app's own message.
    private var lastError: (number: Int, message: String)?

    /// Why a browser refused, in words that say what to do.
    private func browserFailure(_ name: String) -> String {
        guard let e = lastError else { return "\(name) didn't answer" }
        ActionLog.write("Apple Event to \(name) failed: \(e.number) \(e.message)")
        switch e.number {
        case -1743:
            return "Nebula isn't allowed to control \(name): Privacy & Security → Automation"
        case -1728, -1719:
            return "No \(name) window to control"
        case -1712:
            return "\(name) took too long to answer"
        default:
            let m = e.message.lowercased()
            if m.contains("javascript") && (m.contains("turned off") || m.contains("allow") || m.contains("disabled")) {
                return "\(name) blocks it: View → Developer → Allow JavaScript from Apple Events"
            }
            return "\(name) said: \(e.message) (\(e.number))"
        }
    }

    private static func ping(_ bundleID: String) -> String {
        "tell application id \"\(bundleID)\" to return name"
    }

    /// Pauses whatever is playing in the tab, or plays the first media element.
    private static let playPauseJS = "(function(){var m=Array.prototype.slice.call(document.querySelectorAll('video,audio'));if(!m.length)return 'none';var p=m.filter(function(x){return !x.paused&&!x.ended})[0];if(p){p.pause();return 'paused';}var v=m.filter(function(x){return x.readyState>0})[0]||m[0];v.play();return 'playing';})()"

    static func playPauseSource(_ adapter: AppAdapter) -> String {
        switch adapter {
        case .safari:
            return "tell application id \"com.apple.Safari\" to do JavaScript \"\(playPauseJS)\" in current tab of front window"
        case .chrome:
            return "tell application id \"com.google.Chrome\" to execute active tab of front window javascript \"\(playPauseJS)\""
        default:
            return "tell application id \"company.thebrowser.Browser\" to tell front window to tell active tab to execute javascript \"\(playPauseJS)\""
        }
    }

    static let keynoteSlideSource = """
    tell application id "com.apple.iWork.Keynote" to return slide number of current slide of front document as text
    """

    static func keynoteSource(next: Bool) -> String {
        """
        tell application id "com.apple.iWork.Keynote"
            if playing then
                \(next ? "show next" : "show previous")
            else
                tell front document
                    set n to slide number of current slide
                    \(next ? "if n < (count of slides) then set current slide to slide (n + 1)" : "if n > 1 then set current slide to slide (n - 1)")
                end tell
            end if
            return slide number of current slide of front document as text
        end tell
        """
    }

    static func playerSource(_ bundleID: String, _ verb: String) -> String {
        "tell application id \"\(bundleID)\" to \(verb)"
    }

    static func playerStateSource(_ bundleID: String) -> String {
        "tell application id \"\(bundleID)\" to return (name of current track) & \"|\" & (player state as text)"
    }

    // MARK: - Preview's menu

    /// Finds Go ▸ Next Page and Previous Page in Preview's menu bar through Accessibility.
    @discardableResult
    private func findPreviewItems(pid: pid_t) -> (next: AXUIElement, previous: AXUIElement)? {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = Self.element(app, kAXMenuBarAttribute) else { return nil }
        for menuBarItem in Self.children(bar) where TargetTracker.string(menuBarItem, kAXTitleAttribute) == "Go" {
            guard let menu = Self.children(menuBarItem).first else { continue }
            let items = Self.children(menu)
            let next = items.first { TargetTracker.string($0, kAXTitleAttribute) == "Next Page" }
            let previous = items.first { TargetTracker.string($0, kAXTitleAttribute) == "Previous Page" }
            if let next, let previous {
                previewItems[pid] = (next, previous)
                return (next, previous)
            }
        }
        return nil
    }

    private static func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success, let v = value else { return nil }
        return (v as! AXUIElement)
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    static func isYouTube(_ title: String) -> Bool {
        title.hasSuffix("YouTube") || title.contains("- YouTube")
    }

    static func short(_ title: String) -> String {
        // "Song name - YouTube" reads best as "YouTube" when it's a site's own suffix.
        for site in ["YouTube", "Spotify", "SoundCloud", "Netflix", "Vimeo", "Twitch"] where title.hasSuffix(site) { return site }
        return title.count > 32 ? String(title.prefix(31)) + "…" : title
    }
}

/// Reads a scroll area's position under a point, to confirm a scroll moved something.
enum ScrollProbe {
    static func position(at point: CGPoint) -> Double? {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, var e = hit else { return nil }
        for _ in 0..<12 {
            if TargetTracker.string(e, kAXRoleAttribute) == (kAXScrollAreaRole as String) {
                var bar: CFTypeRef?
                guard AXUIElementCopyAttributeValue(e, kAXVerticalScrollBarAttribute as CFString, &bar) == .success, let b = bar else { return nil }
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(b as! AXUIElement, kAXValueAttribute as CFString, &value) == .success else { return nil }
                return (value as? NSNumber)?.doubleValue
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent) == .success, let p = parent else { return nil }
            e = p as! AXUIElement
        }
        return nil
    }
}
