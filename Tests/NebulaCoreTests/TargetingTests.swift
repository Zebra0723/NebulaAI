import XCTest
@testable import NebulaCore
@testable import NebulaSim

/// "It controls the right thing": every window action goes to the frontmost
/// app's focused window, and only there, or nothing happens.
final class TargetingTests: XCTestCase {
    let safari = WindowTarget(pid: 101, bundleID: "com.apple.Safari", appName: "Safari", hasFocusedWindow: true,
                              windowTitle: "YouTube", frame: (100, 50, 1200, 800))
    let notes = WindowTarget(pid: 202, bundleID: "com.apple.Notes", appName: "Notes", hasFocusedWindow: true)

    func testDeliversToTheFrontmostWindowWithTheRightAdapter() {
        XCTAssertEqual(TargetPolicy.decide(.next, startPID: 101, current: safari), .deliver(safari, .safari))
        XCTAssertEqual(TargetPolicy.decide(.playPause, startPID: 101, current: safari), .deliver(safari, .safari))
    }

    func testSwitchingAppsMidGestureDoesNothing() {
        XCTAssertEqual(TargetPolicy.decide(.next, startPID: 101, current: notes), .nothing("The app changed during the gesture"))
    }

    func testNoFocusedWindowDoesNothing() {
        var finder = safari
        finder.hasFocusedWindow = false
        finder.appName = "Finder"
        finder.bundleID = "com.apple.finder"
        XCTAssertEqual(TargetPolicy.decide(.scroll, startPID: 101, current: finder), .nothing("No window to control in Finder"))
        XCTAssertEqual(TargetPolicy.decide(.scroll, startPID: nil, current: nil), .nothing("Nothing in front to control"))
    }

    func testNebulaOrSystemWindowsInFrontDoNothing() {
        let nebula = WindowTarget(pid: 9, bundleID: TargetPolicy.nebulaBundleID, appName: "Nebula", hasFocusedWindow: true)
        XCTAssertEqual(TargetPolicy.decide(.next, startPID: 9, current: nebula), .nothing("Nebula is in front"))
        let spotlight = WindowTarget(pid: 8, bundleID: "com.apple.Spotlight", appName: "Spotlight", hasFocusedWindow: true)
        if case .deliver = TargetPolicy.decide(.scroll, startPID: 8, current: spotlight) { XCTFail("never a system window") }
    }

    func testAnyOtherAppScrollsAndDoesNothingElse() {
        XCTAssertEqual(TargetPolicy.decide(.scroll, startPID: 202, current: notes), .deliver(notes, .other))
        XCTAssertEqual(TargetPolicy.decide(.next, startPID: 202, current: notes), .nothing("Nothing to control in Notes"))
        XCTAssertEqual(TargetPolicy.decide(.playPause, startPID: 202, current: notes), .nothing("Nothing to control in Notes"))
    }

    func testFullScreenWindowsAreStillTheirAppsWindow() {
        var full = safari
        full.isFullScreen = true
        XCTAssertEqual(TargetPolicy.decide(.next, startPID: 101, current: full), .deliver(full, .safari))
    }

    func testAdaptersCoverThePlan() {
        XCTAssertEqual(AppAdapter.forBundle("com.google.Chrome"), .chrome)
        XCTAssertEqual(AppAdapter.forBundle("company.thebrowser.Browser"), .arc)
        XCTAssertEqual(AppAdapter.forBundle("com.apple.iWork.Keynote"), .keynote)
        XCTAssertEqual(AppAdapter.forBundle("com.apple.Preview"), .preview)
        XCTAssertEqual(AppAdapter.forBundle("com.spotify.client"), .spotify)
        XCTAssertEqual(AppAdapter.forBundle("com.apple.Music"), .music)
        XCTAssertTrue(AppAdapter.keynote.supports(.next))
        XCTAssertFalse(AppAdapter.keynote.supports(.playPause))
        XCTAssertTrue(AppAdapter.spotify.supports(.playPause))
    }

    func testHUDNamesTheActionAndTheTarget() {
        XCTAssertEqual(TargetPolicy.describe(.next, .safari, appName: "Safari"), "Next tab · Safari")
        XCTAssertEqual(TargetPolicy.describe(.previous, .keynote, appName: "Keynote"), "Previous slide · Keynote")
        XCTAssertEqual(TargetPolicy.describe(.playPause, .safari, appName: "YouTube", playing: false), "Paused · YouTube")
    }

    func testScrollLandsInsideTheWindowWhateverThePointerDoes() {
        let p = TargetPolicy.scrollPoint(safari)
        XCTAssertEqual(p.x, 700)
        XCTAssertEqual(p.y, 450)
    }

    func testScrollFollowsTheHandTrackpadStyle() {
        let m = ScrollMapping()
        XCTAssertLessThan(m.pixels(delta: 0.05, dt: 1.0 / 60), 0, "natural: hand up moves content up")
        XCTAssertGreaterThan(m.pixels(delta: -0.05, dt: 1.0 / 60), 0)
        // Faster hands go disproportionately further.
        XCTAssertGreaterThan(abs(m.pixels(delta: 0.1, dt: 1.0 / 60)), 2 * abs(m.pixels(delta: 0.05, dt: 1.0 / 60)))
    }
}

final class CustomGestureTests: XCTestCase {
    func testShortcutsParse() {
        XCTAssertEqual(KeyCombo.parse("cmd+shift+t")?.display, "⇧⌘T")
        XCTAssertEqual(KeyCombo.parse("ctrl+space")?.keyCode, 49)
        XCTAssertNil(KeyCombo.parse("hyper+t"))
        XCTAssertNil(CustomAction.keys("cmd+w").validate())
        XCTAssertNotNil(CustomAction.galaxy("launchMissiles").validate())
    }

    func testADesignThatMatchesOrdinaryHandsIsRejected() {
        // "Any hand at all": fires on everything.
        let lazy = CustomGestureSpec(name: "Lazy", movement: "Any hand", rule: PoseRule(name: "lazy", conditions: [
            Condition(.reachIndex, min: -2, band: 0.1),
        ]), action: .window("next"))
        let corpus = GateTests.synthetic.sessions
        let report = CustomGestureCheck.check(lazy, against: corpus, model: GateTests.synthetic.model)
        XCTAssertFalse(report.ok)
        XCTAssertGreaterThan(report.firesOnNothing, 0)
        XCTAssertFalse(report.overlaps.isEmpty)
    }

    func testADistinctDesignPasses() {
        // Little finger up alone (a "pinky up"): nothing built in looks like it.
        let pinky = CustomGestureSpec(name: "Pinky", movement: "Fist with only the little finger up", rule: PoseRule(name: "pinky", conditions: [
            Condition(.reachLittle, min: 0.8, band: 0.1), Condition(.reachIndex, max: 0.2, band: 0.1),
            Condition(.reachMiddle, max: 0.2, band: 0.1), Condition(.reachRing, max: 0.2, band: 0.1),
        ]), action: .keys("cmd+shift+t"))
        let report = CustomGestureCheck.check(pinky, against: GateTests.synthetic.sessions, model: GateTests.synthetic.model)
        XCTAssertTrue(report.ok, report.problems.joined(separator: "; "))
    }
}
