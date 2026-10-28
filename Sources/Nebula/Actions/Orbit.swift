import Foundation

/// Muting and unmuting Orbit, through its own command (`orbit mute` / `orbit unmute`),
/// which writes and removes ~/.local/state/daily-welcome/muted-until.
enum Orbit {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static var command: URL { home.appendingPathComponent(".local/bin/orbit") }
    static var muteFile: URL {
        if let custom = ProcessInfo.processInfo.environment["WELCOME_STATE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom).appendingPathComponent("muted-until")
        }
        return home.appendingPathComponent(".local/state/daily-welcome/muted-until")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: command.path) }

    /// True when Orbit is muted until it's unmuted.
    static var isMuted: Bool {
        guard let text = try? String(contentsOf: muteFile, encoding: .utf8) else { return false }
        let until = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if until == "never" { return true }
        if let end = Double(until) { return end > Date().timeIntervalSince1970 }
        return false
    }

    /// Runs `orbit mute` (no duration: until unmuted) or `orbit unmute`, then reads the file to
    /// confirm. Off the hot path; calls back with whether Orbit ended up in the wanted state.
    static func set(muted: Bool, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard isInstalled else { return completion(false, "Orbit isn't installed") }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [command.path, muted ? "mute" : "unmute"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home.path)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            // Typed, not spoken: Orbit's voice gate doesn't apply.
            env["ORBIT_FROM_CONSOLE"] = "1"
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return completion(false, "Couldn't run orbit") }
            process.waitUntilExit()
            let ok = isMuted == muted
            completion(ok, ok ? (muted ? "Orbit muted" : "Orbit unmuted") : "Orbit didn't change")
        }
    }
}
