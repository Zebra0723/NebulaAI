import AppKit
import NebulaCore

/// End-to-end targeting tests with real app windows, run inside Nebula.app so they use
/// Nebula's own Accessibility and Automation permissions:
///
///     /Applications/Nebula.app/Contents/MacOS/Nebula --test-targeting
///
/// Each test opens two windows of one app plus another app's window, fires a gesture
/// through the real action router, and checks that only the frontmost window changed.
/// It opens and closes windows in Safari, Preview and TextEdit (and Keynote if
/// installed), so run it when you're not using them.
@MainActor
enum TargetingSelfTest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static func run() {
        Task { @MainActor in
            TargetTracker.shared.start()
            let hud = HUD()
            let router = ActionRouter(hud: hud)
            router.proven = Set(Gesture.allCases.map(\.rawValue))
            let queue = DispatchQueue(label: "ai.galaxy.nebula.selftest", qos: .userInteractive)
            var results: [(String, String?)] = []
            let tests: [(String, () async throws -> Void)] = [
                ("Safari: swipe changes the tab in the front window only", { try await safariTabs(router, queue) }),
                ("Safari, full screen: swipe still changes the front window only", { try await safariFullScreen(router, queue) }),
                ("Preview: swipe turns the page in the front document only", { try await previewPages(router, queue) }),
                ("TextEdit: scroll moves the front window, not the one under the pointer", { try await textEditScroll(router, queue) }),
                ("Switching apps mid-gesture does nothing", { try await switchMidGesture() }),
                ("No focused window does nothing", { try await noFocusedWindow(router, queue) }),
                ("Notes-like app: swipe does nothing", { try await otherAppSwipe(router, queue) }),
                ("Keynote: swipe moves the slide in the front document only", { try await keynoteSlides(router, queue) }),
                ("Two displays: the window on the other display is untouched", { try await twoDisplays(router, queue) }),
            ]
            for (name, test) in tests {
                do {
                    try await test()
                    results.append((name, nil))
                    print("PASS  \(name)")
                } catch let skip as Skip {
                    results.append((name, "skipped: \(skip.reason)"))
                    print("SKIP  \(name): \(skip.reason)")
                } catch {
                    results.append((name, "\(error)"))
                    print("FAIL  \(name): \(error)")
                }
            }
            cleanUp()
            let failed = results.filter { $0.1 != nil && !$0.1!.hasPrefix("skipped") }.count
            print(failed == 0 ? "All targeting tests passed." : "\(failed) targeting test(s) failed.")
            exit(failed == 0 ? 0 : 1)
        }
    }

    struct Skip: Error { let reason: String }

    // MARK: - Helpers

    @discardableResult
    static func script(_ source: String) throws -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw Failure("AppleScript: \(error[NSAppleScript.errorMessage] ?? error)") }
        return result?.stringValue ?? ""
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    static func activate(_ bundleID: String) async {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        await pause(0.8) // let the tracker see it, and gestures span less than this
    }

    /// Fires a gesture through the router exactly as the pipeline does.
    static func fire(_ g: Gesture, _ router: ActionRouter, _ queue: DispatchQueue) async {
        queue.sync { router.handle(.fired(g.index), arrival: Monotonic.nanoseconds(), frameTime: Monotonic.seconds()) }
        await pause(0.9)
    }

    static func installed(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    // MARK: - Tests

    static func safariSetup() throws {
        try script("""
        tell application "Safari"
            activate
            make new document with properties {URL:"data:text/html,<title>B1</title>B1"}
            tell front window to make new tab with properties {URL:"data:text/html,<title>B2</title>B2"}
            make new document with properties {URL:"data:text/html,<title>A1</title>A1"}
            tell front window to make new tab with properties {URL:"data:text/html,<title>A2</title>A2"}
            tell front window to set current tab to tab 1
        end tell
        """)
        try script("tell application \"TextEdit\" to make new document with properties {text:\"bystander\"}")
    }

    static func safariTabIndices() throws -> (front: String, back: String) {
        let s = try script("""
        tell application "Safari" to return ((index of current tab of window 1) as text) & "," & ((index of current tab of window 2) as text)
        """)
        let parts = s.split(separator: ",").map(String.init)
        return (parts.first ?? "", parts.last ?? "")
    }

    static func safariTabs(_ router: ActionRouter, _ queue: DispatchQueue) async throws {
        guard installed("com.apple.Safari") else { throw Skip(reason: "Safari isn't installed") }
        try safariSetup()
        await activate("com.apple.Safari")
        let before = try safariTabIndices()
        await fire(.swipeRight, router, queue)
        let after = try safariTabIndices()
        try expect(after.front != before.front, "front window's tab didn't change (\(before.front) → \(after.front))")
        try expect(after.back == before.back, "the back window's tab changed (\(before.back) → \(after.back))")
        await fire(.swipeLeft, router, queue)
        try expect(try safariTabIndices().front == before.front, "swipe left didn't go back")
    }

    static func safariFullScreen(_ router: ActionRouter, _ queue: DispatchQueue) async throws {
        guard installed("com.apple.Safari") else { throw Skip(reason: "Safari isn't installed") }
        await activate("com.apple.Safari")
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first?.processIdentifier else {
            throw Skip(reason: "Safari isn't running")
        }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let w = value else {
            throw Failure("no focused Safari window")
        }
        let window = w as! AXUIElement
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
        await pause(1.5)
        let before = try safariTabIndices()
        await fire(.swipeRight, router, queue)
        let after = try safariTabIndices()
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        await pause(1.5)
        try expect(after.front != before.front, "full screen: front tab didn't change")
        try expect(after.back == before.back, "full screen: the other window's tab changed")
    }

    static func makePDF(_ name: String, pages: Int) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return url }
        for _ in 0..<pages {
            ctx.beginPDFPage(nil)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    static func previewPages(_ router: ActionRouter, _ queue: DispatchQueue) async throws {
        let a = makePDF("nebula-test-A.pdf", pages: 5), b = makePDF("nebula-test-B.pdf", pages: 5)
        NSWorkspace.shared.open([b], withApplicationAt: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")!,
                                configuration: NSWorkspace.OpenConfiguration())
        await pause(1.5)
        NSWorkspace.shared.open([a], withApplicationAt: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")!,
                                configuration: NSWorkspace.OpenConfiguration())
        await pause(1.5)
        await activate("com.apple.Preview")
        let titleBack = try script("tell application \"System Events\" to tell process \"Preview\" to return name of window 2")
        let before = TargetTracker.shared.liveTitle()
        await fire(.swipeRight, router, queue)
        let after = TargetTracker.shared.liveTitle()
        let titleBackAfter = try script("tell application \"System Events\" to tell process \"Preview\" to return name of window 2")
        try expect(before != after, "front document's page didn't change (title \(before ?? "?"))")
        try expect(titleBack == titleBackAfter, "the back document changed")
    }

    static func textEditScroll(_ router: ActionRouter, _ queue: DispatchQueue) async throws {
        let long = (1...400).map { "Line \($0)" }.joined(separator: "\\n")
        try script("tell application \"TextEdit\" to make new document with properties {text:\"\(long)\"}")
        try script("tell application \"TextEdit\" to make new document with properties {text:\"\(long)\"}")
        await activate("com.apple.TextEdit")
        // Put the pointer over the back window: the scroll must still go to the front one.
        try script("tell application \"TextEdit\" to set bounds of window 1 to {80, 80, 700, 600}")
        try script("tell application \"TextEdit\" to set bounds of window 2 to {760, 80, 1380, 600}")
        await pause(0.6)
        CGWarpMouseCursorPosition(CGPoint(x: 1070, y: 340))
        let front = CGPoint(x: 390, y: 340), back = CGPoint(x: 1070, y: 340)
        let f0 = ScrollProbe.position(at: front), b0 = ScrollProbe.position(at: back)
        queue.sync { router.handle(.fired(Gesture.scroll.index), arrival: Monotonic.nanoseconds(), frameTime: Monotonic.seconds()) }
        for i in 0..<30 {
            queue.sync { router.handle(.scroll(-0.12), arrival: Monotonic.nanoseconds(), frameTime: Monotonic.seconds() + Double(i) / 60) }
            await pause(1.0 / 60)
        }
        queue.sync { router.handle(.ended(Gesture.scroll.index), arrival: Monotonic.nanoseconds(), frameTime: Monotonic.seconds()) }
        await pause(0.5)
        let f1 = ScrollProbe.position(at: front), b1 = ScrollProbe.position(at: back)
        try expect(f0 != nil && f1 != nil && f0 != f1, "front window didn't scroll (\(f0 ?? -1) → \(f1 ?? -1))")
        try expect(b0 == b1, "the window under the pointer scrolled (\(b0 ?? -1) → \(b1 ?? -1))")
    }

    static func switchMidGesture() async throws {
        await activate("com.apple.Safari")
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first?.activate()
        await pause(0.15)
        // A held gesture that began 0.3 s ago, in Safari.
        let snap = TargetTracker.shared.snapshot(changedWithin: 0.5)
        let decision = TargetPolicy.decide(.next, startPID: snap.changedRecently ? -1 : snap.target?.pid, current: snap.target)
        try expect(decision == .nothing("The app changed during the gesture"), "expected nothing, got \(decision)")
    }

    static func noFocusedWindow(_ router: ActionRouter, _ queue: DispatchQueue) async throws {
        try script("tell application \"TextEdit\" to close every document saving no")
        await activate("com.apple.TextEdit")
        let snap = TargetTracker.shared.snapshot(changedWithin: 0)
        try expect(snap.target?.hasFocusedWindow == false, "TextEdit still has a focused window")
        let decision = TargetPolicy.decide(.scroll, startPID: snap.target?.pid, current: snap.target)
        guard case .nothing = decision else { throw Failure("expected nothing, got \(decision)") }
    }

    static func otherAppSwipe(_ router: ActionRouter, _ queue: DispatchQueue) async throws {
        try script("tell application \"TextEdit\" to make new document with properties {text:\"unchanged\"}")
        await activate("com.apple.TextEdit")
        let before = try script("tell application \"TextEdit\" to return text of document 1")
        await fire(.swipeRight, router, queue)
        await fire(.openPalm, router, queue)
        let after = try script("tell application \"TextEdit\" to return text of document 1")
        try expect(before == after, "TextEdit changed")
    }

    static func keynoteSlides(_ router: ActionRouter, _ queue: DispatchQueue) async throws {
        guard installed("com.apple.iWork.Keynote") else { throw Skip(reason: "Keynote isn't installed") }
        try script("""
        tell application id "com.apple.iWork.Keynote"
            activate
            set b to make new document
            tell b to repeat 3 times
                make new slide
            end repeat
            set a to make new document
            tell a to repeat 3 times
                make new slide
            end repeat
            tell a to set current slide to slide 1
        end tell
        """)
        await activate("com.apple.iWork.Keynote")
        let read = "tell application id \"com.apple.iWork.Keynote\" to return ((slide number of current slide of document 1) as text) & \",\" & ((slide number of current slide of document 2) as text)"
        let before = try script(read)
        await fire(.swipeRight, router, queue)
        let after = try script(read)
        try expect(before.split(separator: ",").first != after.split(separator: ",").first, "front document's slide didn't change")
        try expect(before.split(separator: ",").last == after.split(separator: ",").last, "the other document's slide changed")
        try script("tell application id \"com.apple.iWork.Keynote\" to close every document saving no")
    }

    static func twoDisplays(_ router: ActionRouter, _ queue: DispatchQueue) async throws {
        guard NSScreen.screens.count > 1 else { throw Skip(reason: "only one display is connected") }
        guard installed("com.apple.Safari") else { throw Skip(reason: "Safari isn't installed") }
        try safariSetup()
        let second = NSScreen.screens[1].frame
        let primaryHeight = NSScreen.screens[0].frame.height
        let top = primaryHeight - second.maxY
        try script("tell application \"Safari\" to set bounds of window 2 to {\(Int(second.minX) + 40), \(Int(top) + 40), \(Int(second.minX) + 640), \(Int(top) + 500)}")
        await activate("com.apple.Safari")
        let before = try safariTabIndices()
        await fire(.swipeRight, router, queue)
        let after = try safariTabIndices()
        try expect(after.front != before.front, "front tab didn't change")
        try expect(after.back == before.back, "the window on the other display changed")
    }

    static func cleanUp() {
        _ = try? script("tell application \"Safari\" to close (every window whose name starts with \"A\" or name starts with \"B\")")
        _ = try? script("tell application \"TextEdit\" to close every document saving no")
        _ = try? script("tell application \"Preview\" to close every window")
    }
}
