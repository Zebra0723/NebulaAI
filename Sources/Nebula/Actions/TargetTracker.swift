import AppKit
import ApplicationServices
import NebulaCore

/// Knows, at all times, which app is in front and which of its windows has focus,
/// so resolving the target when a gesture fires costs nothing. Updated on app
/// activation and on the app's focused-window, move and resize notifications;
/// read from the vision queue.
final class TargetTracker {
    static let shared = TargetTracker()

    private let lock = NSLock()
    private var current: WindowTarget?
    private var focusedWindow: AXUIElement?
    private var appElement: AXUIElement?
    private var lastChange: Double = 0
    private var observer: AXObserver?
    /// Called on the main thread whenever the frontmost app changes (adapters pre-warm here).
    var onActivate: ((WindowTarget) -> Void)?

    private init() {}

    /// Starts listening. Main thread.
    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.activated(app)
        }
        if let app = NSWorkspace.shared.frontmostApplication { activated(app) }
    }

    /// The target as of now, and whether the frontmost app changed within `window` seconds
    /// (a gesture that began in another app must do nothing).
    func snapshot(changedWithin window: Double) -> (target: WindowTarget?, changedRecently: Bool, focusedWindow: AXUIElement?) {
        lock.lock()
        defer { lock.unlock() }
        return (current, Monotonic.seconds() - lastChange < window, focusedWindow)
    }

    /// The last check before posting: is the cached app still the frontmost one?
    func stillFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    // MARK: - Updates

    private func activated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        lock.lock()
        appElement = element
        lastChange = Monotonic.seconds()
        lock.unlock()
        refreshWindow(app: app, element: element)
        observe(pid: pid, element: element, app: app)
        if let t = lock.locked({ current }) { onActivate?(t) }
    }

    private func refreshWindow(app: NSRunningApplication, element: AXUIElement) {
        var window: AXUIElement?
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success, let v = value {
            window = (v as! AXUIElement)
        }
        var target = WindowTarget(pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "",
                                  appName: app.localizedName ?? "this app", hasFocusedWindow: window != nil)
        if let window {
            target.windowTitle = Self.string(window, kAXTitleAttribute) ?? ""
            if let frame = Self.frame(window) { target.frame = (frame.minX, frame.minY, frame.width, frame.height) }
            target.isFullScreen = Self.bool(window, "AXFullScreen") ?? false
        }
        lock.lock()
        current = target
        focusedWindow = window
        lock.unlock()
    }

    private func observe(pid: pid_t, element: AXUIElement, app: NSRunningApplication) {
        if let old = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        observer = nil
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<TargetTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.focusChanged()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let obs = created else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowMovedNotification,
                     kAXWindowResizedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(obs, element, name as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    private func focusChanged() {
        guard let app = NSWorkspace.shared.frontmostApplication, let element = lock.locked({ appElement }) else { return }
        refreshWindow(app: app, element: element)
    }

    // MARK: - AX helpers

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let pv = posValue, let sv = sizeValue else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &point)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// The window's current title, read fresh (for checking that a tab or page changed).
    func liveTitle() -> String? {
        guard let window = lock.locked({ focusedWindow }) else { return nil }
        return Self.string(window, kAXTitleAttribute)
    }
}

extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
