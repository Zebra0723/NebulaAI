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
    static func pressGlobally(_ combo: KeyCombo) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false) else { return }
        let f = flags(combo)
        down.flags = f
        up.flags = f
        down.setIntegerValueField(.eventSourceUserData, value: tag)
        up.setIntegerValueField(.eventSourceUserData, value: tag)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// A pixel scroll for one app, positioned inside its window so it scrolls that window
    /// wherever the pointer is. `point` is in global top-left coordinates.
    static func scroll(pixels: Int32, at point: CGPoint, toPID pid: pid_t, phase: Int64) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0) else { return }
        e.location = point
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.eventSourceUserData, value: tag)
        e.postToPid(pid)
    }
}
