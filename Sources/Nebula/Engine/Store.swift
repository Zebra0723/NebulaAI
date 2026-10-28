import Foundation
import NebulaCore

/// Where Nebula keeps things: ~/Library/Application Support/Nebula. Joint recordings,
/// the model, custom gestures and the latency log. Nothing here ever leaves the Mac.
enum Paths {
    static let support: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nebula", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var recordings: URL { folder("Recordings") }
    static var enrollment: URL { folder("Recordings/Enrollment") }
    /// Near-misses (an immediate repeat after a non-fire) and wrong fires, kept as candidate examples.
    static var candidates: URL { folder("Recordings/Candidates") }
    static var model: URL { support.appendingPathComponent("model.json") }
    static var customs: URL { support.appendingPathComponent("custom-gestures.json") }
    static var latency: URL { support.appendingPathComponent("latency.json") }
    static var report: URL { support.appendingPathComponent("report.json") }
    static var actionLog: URL { support.appendingPathComponent("actions.log") }

    private static func folder(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// What the build's accuracy gate proved. Only gestures it lists may fire.
struct GateFile: Codable {
    /// "recorder": a build made before any data existed; nothing fires.
    var mode: String
    var passing: [String]
    var generatedAt: Double
    var summary: String

    static func bundled() -> GateFile {
        guard let url = Bundle.main.url(forResource: "gate", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let gate = try? JSONDecoder().decode(GateFile.self, from: data) else {
            return GateFile(mode: "recorder", passing: [], generatedAt: 0, summary: "No accuracy report was built into this copy of Nebula.")
        }
        return gate
    }
}

enum ModelStore {
    /// Your trained model if there is one, else the starter model built into the app.
    static func load() -> NebulaModel {
        if let data = try? Data(contentsOf: Paths.model), let model = try? NebulaModel.decode(data) { return model }
        if let url = Bundle.main.url(forResource: "model", withExtension: "json"),
           let data = try? Data(contentsOf: url), let model = try? NebulaModel.decode(data) { return model }
        return Bootstrap.emptyModel()
    }

    static func save(_ model: NebulaModel) throws {
        try model.encoded().write(to: Paths.model, options: .atomic)
    }
}

/// A saved custom gesture: its spec, the recognizer's view of it, and the proof it passed.
struct SavedCustomGesture: Codable, Identifiable, Equatable {
    var id: String { gesture.id }
    var spec: CustomGestureSpec
    var gesture: CustomGesture
    var recall: Double
    var heldOut: Int
}

enum CustomStore {
    static func load() -> [SavedCustomGesture] {
        guard let data = try? Data(contentsOf: Paths.customs) else { return [] }
        return (try? JSONDecoder().decode([SavedCustomGesture].self, from: data)) ?? []
    }

    static func save(_ list: [SavedCustomGesture]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(list).write(to: Paths.customs, options: .atomic)
    }
}

/// Settings, kept in UserDefaults.
struct NebulaSettings: Codable, Equatable {
    /// Minutes without a hand before Nebula disarms itself.
    var autoOffMinutes: Double = 5
    /// Arm for 60 s when a Galaxy body is waiting on a yes or no.
    var approvalMode = true
    /// Standard uses the tuned holds; Careful adds a tenth of a second to every hold.
    var careful = false
    var naturalScroll = true
    /// Gestures switched off by you, by raw value or custom id.
    var disabled: Set<String> = []
    /// 640×480 by default; 1280×720 to compare.
    var highResolution = false

    private static let key = "NebulaSettings"

    static func load() -> NebulaSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(NebulaSettings.self, from: data) else { return NebulaSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// One line per action, for checking what Nebula did and whether it worked.
enum ActionLog {
    private static let queue = DispatchQueue(label: "ai.galaxy.nebula.actionlog", qos: .utility)

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            let text = "\(stamp) \(line)\n"
            if let handle = try? FileHandle(forWritingTo: Paths.actionLog) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? text.write(to: Paths.actionLog, atomically: true, encoding: .utf8)
            }
        }
    }
}
