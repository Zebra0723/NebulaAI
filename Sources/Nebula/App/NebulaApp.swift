import AppKit
import Carbon
import Combine
import SwiftUI

@main
enum NebulaMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--test-targeting") {
            // End-to-end targeting tests with real windows (see TargetingSelfTest).
            app.setActivationPolicy(.accessory)
            TargetingSelfTest.run()
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only until the window opens
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let engine = Engine()
    private lazy var window = AppWindowController(engine: engine)
    private var watch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        watch = engine.$arming.sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }

        // fn+F1: holding fn makes the top row send F1.
        hotKey = HotKey(keyCode: UInt32(kVK_F1)) { [weak self] in self?.engine.toggleArmed() }

        Permissions.requestAccessibilityIfNeeded()
        engine.start()
        if Permissions.firstRun { window.show(.practice) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await GalaxyLink.shared.goodbye()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    // MARK: - Menu bar

    private func updateIcon() {
        statusItem.button?.image = Self.icon(armed: engine.isArmed)
        statusItem.button?.toolTip = engine.isArmed ? "Nebula is watching for gestures" : "Nebula is off"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state: String
        switch engine.arming {
        case .off: state = "Off: the camera is off"
        case .armed: state = "On: watching for gestures"
        case .approval(let until): state = "On for an approval, \(max(0, Int(until.timeIntervalSinceNow))) s left"
        case .practice: state = "Practice: nothing acts"
        }
        let header = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item(engine.isArmed ? "Turn Off" : "Turn On", #selector(toggle), "fn F1"))
        if !engine.pending.isEmpty {
            let waiting = NSMenuItem(title: "Waiting on you: \(engine.pending[0].title)", action: nil, keyEquivalent: "")
            waiting.isEnabled = false
            menu.addItem(waiting)
        }
        if !Permissions.hasAccessibility {
            menu.addItem(item("Grant Accessibility…", #selector(grantAccessibility), nil))
        }
        menu.addItem(item("That Was Wrong (save the last 3 s)", #selector(wrong), nil))
        menu.addItem(.separator())
        menu.addItem(item("Gestures", #selector(openGestures), nil))
        menu.addItem(item("Practice", #selector(openPractice), nil))
        menu.addItem(item("Settings…", #selector(openSettings), nil))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nebula", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func item(_ title: String, _ action: Selector, _ hint: String?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let hint { i.toolTip = hint }
        return i
    }

    @objc private func toggle() { engine.toggleArmed() }
    @objc private func wrong() { engine.reportWrongFire() }
    @objc private func grantAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openGestures() { window.show(.gestures) }
    @objc private func openPractice() { window.show(.practice) }
    @objc private func openSettings() { window.show(.settings) }

    /// The mark as a template image: a ring with a dot touching it; filled when armed.
    private static func icon(armed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.6)
            let ring = rect.insetBy(dx: 3, dy: 3)
            let r = ring.width / 2
            // The fingertip on the ring, top right (y is up here).
            let tip = CGRect(x: ring.midX + r * 0.62 - 2.6, y: ring.midY + r * 0.62 - 2.6, width: 5.2, height: 5.2)
            if armed {
                ctx.fillEllipse(in: ring)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: ring.insetBy(dx: 3.2, dy: 3.2))
                ctx.setBlendMode(.normal)
                ctx.fillEllipse(in: ring.insetBy(dx: 5.2, dy: 5.2))
            } else {
                ctx.strokeEllipse(in: ring)
            }
            ctx.setBlendMode(.normal)
            ctx.fillEllipse(in: tip)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = armed ? "Nebula on" : "Nebula off"
        return image
    }

    // MARK: - Main menu (while the window is open)

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Nebula", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = item("Settings…", #selector(openSettings), nil)
        settingsItem.keyEquivalent = ","
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Nebula", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Nebula", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return main
    }
}

/// Camera (asked for when you first turn Nebula on) and Accessibility (for keystrokes,
/// scrolls and reading the focused window).
enum Permissions {
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityIfNeeded() {
        guard !hasAccessibility else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Adds Nebula to the Accessibility list (macOS only lists an app once it has asked)
    /// and opens that list.
    static func openAccessibilitySettings() {
        requestAccessibilityIfNeeded()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static var firstRun: Bool {
        let key = "NebulaLaunched"
        defer { UserDefaults.standard.set(true, forKey: key) }
        return !UserDefaults.standard.bool(forKey: key)
    }
}
