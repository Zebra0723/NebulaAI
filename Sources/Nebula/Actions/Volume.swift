import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's output volume through CoreAudio: microseconds, no AppleScript.
enum SystemVolume {
    private static func defaultDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    private static var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                            mScope: kAudioDevicePropertyScopeOutput,
                                                            mElement: kAudioObjectPropertyElementMain)

    static func get() -> Float? {
        guard let device = defaultDevice() else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var a = address
        return AudioObjectGetPropertyData(device, &a, 0, nil, &size, &volume) == noErr ? volume : nil
    }

    @discardableResult
    static func set(_ value: Float) -> Bool {
        guard let device = defaultDevice() else { return false }
        var volume = Float32(min(max(value, 0), 1))
        var a = address
        return AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume) == noErr
    }

    /// One knob step: a sixteenth, like the volume keys.
    static func step(_ direction: Int) -> Float? {
        guard let now = get() else { return nil }
        let next = (now * 16).rounded() / 16 + Float(direction) / 16
        return set(next) ? get() : nil
    }
}
