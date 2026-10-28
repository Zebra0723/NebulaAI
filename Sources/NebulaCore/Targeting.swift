#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Which window an action lands on, decided as pure logic so every rule is
// tested. The app feeds it what macOS says is in front; it answers with one
// target and one adapter, or with nothing and the reason.

/// The frontmost app and its focused window, as cached on app activation.
public struct WindowTarget: Sendable, Equatable {
    public var pid: Int32
    public var bundleID: String
    public var appName: String
    public var hasFocusedWindow: Bool
    public var windowTitle: String
    /// The focused window's frame in global screen coordinates (top-left origin).
    public var frame: (x: Double, y: Double, width: Double, height: Double)
    public var isFullScreen: Bool

    public init(pid: Int32, bundleID: String, appName: String, hasFocusedWindow: Bool, windowTitle: String = "",
                frame: (x: Double, y: Double, width: Double, height: Double) = (0, 0, 0, 0), isFullScreen: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.hasFocusedWindow = hasFocusedWindow
        self.windowTitle = windowTitle
        self.frame = frame
        self.isFullScreen = isFullScreen
    }

    public static func == (a: WindowTarget, b: WindowTarget) -> Bool {
        a.pid == b.pid && a.bundleID == b.bundleID && a.hasFocusedWindow == b.hasFocusedWindow
            && a.windowTitle == b.windowTitle && a.isFullScreen == b.isFullScreen
            && a.frame.x == b.frame.x && a.frame.y == b.frame.y && a.frame.width == b.frame.width && a.frame.height == b.frame.height
    }
}

/// How an app is driven. Anything not listed is `.other`: scroll works, nothing else does.
public enum AppAdapter: String, Sendable, CaseIterable {
    case safari, chrome, arc, keynote, preview, spotify, music, other

    public static func forBundle(_ id: String) -> AppAdapter {
        switch id {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview": return .safari
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary": return .chrome
        case "company.thebrowser.Browser": return .arc
        case "com.apple.iWork.Keynote", "com.apple.Keynote": return .keynote
        case "com.apple.Preview": return .preview
        case "com.spotify.client": return .spotify
        case "com.apple.Music": return .music
        default: return .other
        }
    }

    public var isBrowser: Bool { self == .safari || self == .chrome || self == .arc }

    /// What a swipe moves through in this app.
    public var itemName: String {
        switch self {
        case .safari, .chrome, .arc: return "tab"
        case .keynote: return "slide"
        case .preview: return "page"
        case .spotify, .music: return "track"
        case .other: return ""
        }
    }

    public func supports(_ action: WindowAction) -> Bool {
        switch action {
        case .scroll: return true
        case .next, .previous: return self != .other
        case .playPause: return isBrowser || self == .spotify || self == .music
        }
    }
}

public enum WindowAction: Sendable, Equatable {
    case next, previous, playPause, scroll

    public init?(_ gesture: Gesture) {
        switch gesture {
        case .swipeRight: self = .next
        case .swipeLeft: self = .previous
        case .openPalm: self = .playPause
        case .scroll: self = .scroll
        default: return nil
        }
    }
}

public enum TargetDecision: Sendable, Equatable {
    case deliver(WindowTarget, AppAdapter)
    /// Do nothing, and say why in the HUD.
    case nothing(String)
}

public enum TargetPolicy {
    public static let nebulaBundleID = "ai.galaxy.nebula"

    /// Apps whose windows are the system's, not yours: never a target.
    public static let systemBundleIDs: Set<String> = [
        "com.apple.loginwindow", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight", "com.apple.WindowManager",
        "com.apple.screencaptureui", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
        "com.apple.coreservices.uiagent", "com.apple.ScreenSaver.Engine", "com.apple.wallpaper.agent",
    ]

    /// The one rule for window actions: resolved when the gesture fires, delivered only to
    /// the frontmost app's focused window, and only if that's still the app that was in
    /// front when the gesture began.
    ///
    /// - Parameters:
    ///   - startPID: the frontmost app's pid when the gesture began (its first cue).
    ///   - current: the frontmost app now, re-checked just before posting.
    public static func decide(_ action: WindowAction, startPID: Int32?, current: WindowTarget?) -> TargetDecision {
        guard let current else { return .nothing("Nothing in front to control") }
        if current.bundleID == nebulaBundleID { return .nothing("Nebula is in front") }
        if systemBundleIDs.contains(current.bundleID) { return .nothing("Nothing to control here") }
        if let startPID, startPID != current.pid { return .nothing("The app changed during the gesture") }
        guard current.hasFocusedWindow else { return .nothing("No window to control in \(current.appName)") }
        let adapter = AppAdapter.forBundle(current.bundleID)
        guard adapter.supports(action) else { return .nothing("Nothing to control in \(current.appName)") }
        return .deliver(current, adapter)
    }

    /// The HUD line for a delivered window action, e.g. "Next tab · Safari".
    public static func describe(_ action: WindowAction, _ adapter: AppAdapter, appName: String, playing: Bool? = nil) -> String {
        switch action {
        case .next: return "Next \(adapter.itemName) · \(appName)"
        case .previous: return "Previous \(adapter.itemName) · \(appName)"
        case .playPause:
            if let playing { return "\(playing ? "Playing" : "Paused") · \(appName)" }
            return "Play/pause · \(appName)"
        case .scroll: return "Scrolling · \(appName)"
        }
    }

    /// Where a scroll event goes: the middle of the focused window, so it scrolls that
    /// window even if the pointer is somewhere else.
    public static func scrollPoint(_ t: WindowTarget) -> (x: Double, y: Double) {
        (t.frame.x + t.frame.width / 2, t.frame.y + t.frame.height / 2)
    }
}

/// Turns the hand's movement into scroll pixels: trackpad-like, faster hands go further.
public struct ScrollMapping: Sendable, Codable, Equatable {
    /// Pixels per palm length at a gentle pace.
    public var gain: Double = 900
    /// Above 1, quick movements go disproportionately further, like a trackpad.
    public var acceleration: Double = 1.35
    /// Natural: hand up, content up (like fingers on a trackpad).
    public var natural = true

    public init() {}

    /// `delta` is the hand's movement this frame in palm lengths, up positive; `dt` seconds.
    public func pixels(delta: Float, dt: Double) -> Double {
        guard dt > 0 else { return 0 }
        let speed = abs(Double(delta)) / dt // palm lengths per second
        let scaled = gain * pow(speed, acceleration) * dt
        let sign: Double = delta >= 0 ? 1 : -1
        // CGEvent scroll: positive moves content down (reveals what's above).
        return (natural ? -sign : sign) * scaled
    }
}
