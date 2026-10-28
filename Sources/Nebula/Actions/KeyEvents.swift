import AppKit
import CoreGraphics
import NebulaCore

/// Keystrokes and scrolls as CGEvents, straight from the pipeline: no AppleScript round trip.
enum KeyEvents {
    /// Every event Nebula posts carries this tag (so other Galaxy bodies can tell).
    static let tag: Int64 = 0x4E42_4C41
    private static let source = CGEventSource(stateID: .hidSystemState)

    static func flags(_ combo: KeyCombo) -> CGEventFlags {
        var f: CGEventFlags = []
        if combo.command { f.insert(.maskCommand) }
        if combo.shift { f.insert(.maskShift) }
        if combo.option { f.insert(.maskAlternate) }
        if combo.control { f.insert(.maskControl) }
        if [123, 124, 125, 126].contains(combo.keyCode) { f.insert(.maskSecondaryFn); f.insert(.maskNumericPad) }
        return f
    }

    /// A key press delivered to one app only. Never a global event.
    static func press(_ combo: KeyCombo, toPID pid: pid_t) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false) else { return }
        let f = flags(combo)
        down.flags = f
        up.flags = f
        down.setIntegerValueField(.eventSourceUserData, value: tag)
        up.setIntegerValueField(.eventSourceUserData, value: tag)
        down.postToPid(pid)
        up.postToPid(pid)
    }

    /// A key press the whole system sees. Only for summoning Nova, whose ⌃Space is a
    /// system-wide hotkey that no single app receives.
    ///
    /// It types the shortcut the way hands do: each modifier pressed, the key pressed and
    /// released, the modifiers released. Hotkey systems can ignore a lone key that merely
    /// carries modifier flags.
    static func pressGlobally(_ combo: KeyCombo) {
        var modifiers: [(CGKeyCode, CGEventFlags)] = []
        if combo.control { modifiers.append((59, .maskControl)) }
        if combo.option { modifiers.append((58, .maskAlternate)) }
        if combo.shift { modifiers.append((56, .maskShift)) }
        if combo.command { modifiers.append((55, .maskCommand)) }

        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: tag)
            e.post(tap: .cghidEventTap)
        }

        var held: CGEventFlags = []
        for (key, flag) in modifiers {
            held.insert(flag)
            post(key, down: true, flags: held)
        }
        post(combo.keyCode, down: true, flags: held)
        post(combo.keyCode, down: false, flags: held)
        for (key, flag) in modifiers.reversed() {
            held.remove(flag)
            post(key, down: false, flags: held)
        }
    }

    /// A pixel scroll for one app's window. `point` is in global top-left coordinates, inside
    /// that window. A plain mouse-wheel event, no trackpad phases and not "continuous": that is
    /// the one form every app accepts from a synthetic source.
    ///
    /// Posted at the HID level by default, where the window server delivers it like a real
    /// wheel. `direct` posts it to the app's pid only, for an app that ignores the other way.
    static func scroll(pixels: Int32, at point: CGPoint, toPID pid: pid_t, direct: Bool) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        e.location = point
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        if direct { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
    }
}
