// Recorded sessions: labelled joint sequences, never images.
//
// One session is one JSON Lines file. The first line describes the session,
// then one line per camera frame (joints as integers to keep files small),
// and label lines saying which gesture was being made when.
//
//   {"session":{...}}
//   {"t":12.3456,"a":1.3333,"h":[[2,5123,4410,93, ...]],"f":[4100,5200,2100,2800]}
//   {"label":{"gesture":"thumbsUp","start":12.1,"end":13.4}}

import Foundation

public struct SessionInfo: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Deliberate examples of gestures, each inside a labelled window.
        case gestures
        /// Ordinary hand activity: typing, mouse, drinking, talking, stretching...
        case nothing
        /// The poses most like each gesture without being it.
        case nearMiss
        /// Personal calibration examples.
        case enrollment
    }

    public enum Role: String, Codable, Sendable, CaseIterable {
        case train, validation, test
    }

    public var id: String
    public var kind: Kind
    public var startedAt: Double
    public var lighting: String
    public var distanceCm: Int
    public var hands: String
    public var notes: String
    public var fps: Double
    /// Train, tune or test. Assigned per session, never per frame.
    public var role: Role?
    public var synthetic: Bool

    public init(id: String, kind: Kind, startedAt: Double = Date().timeIntervalSince1970, lighting: String = "",
                distanceCm: Int = 0, hands: String = "", notes: String = "", fps: Double = 0, role: Role? = nil,
                synthetic: Bool = false) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.lighting = lighting
        self.distanceCm = distanceCm
        self.hands = hands
        self.notes = notes
        self.fps = fps
        self.role = role
        self.synthetic = synthetic
    }
}

public struct SegmentLabel: Codable, Sendable, Equatable {
    /// A `Gesture` raw value; "volumeUp"/"volumeDown" for the knob with a direction;
    /// "nothing" or "nearMiss:<what>" for windows that must not fire; or a custom gesture id.
    public var gesture: String
    public var start: Double
    public var end: Double

    public init(gesture: String, start: Double, end: Double) {
        self.gesture = gesture
        self.start = start
        self.end = end
    }

    /// The gesture this window is an example of, if it is one.
    public var expected: Gesture? {
        switch gesture {
        case "volumeUp", "volumeDown": return .volumeKnob
        default: return Gesture(rawValue: gesture)
        }
    }

    public var isNegative: Bool { gesture == "nothing" || gesture.hasPrefix("nearMiss") }
}

public struct Recording: Sendable {
    public var info: SessionInfo
    public var frames: [Frame]
    public var labels: [SegmentLabel]

    public init(info: SessionInfo, frames: [Frame] = [], labels: [SegmentLabel] = []) {
        self.info = info
        self.frames = frames
        self.labels = labels
    }

    public var duration: Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.time - first.time
    }

    // MARK: - Encoding

    public static func encodeFrame(_ frame: Frame) -> String {
        var s = "{\"t\":"
        s += String(format: "%.5f", frame.time)
        s += ",\"a\":" + String(format: "%.4f", frame.aspect)
        s += ",\"h\":["
        for i in 0..<frame.handCount {
            let h = frame.hand(i)
            if i > 0 { s += "," }
            s += "[\(h.chirality.rawValue)"
            for j in 0..<21 {
                s += ",\(Int((h.x[j] * 10000).rounded())),\(Int((h.y[j] * 10000).rounded())),\(Int((h.confidence[j] * 100).rounded()))"
            }
            s += "]"
        }
        s += "]"
        if frame.hasFace {
            let f = frame.face
            s += ",\"f\":[\(Int((f.x * 10000).rounded())),\(Int((f.y * 10000).rounded())),\(Int((f.width * 10000).rounded())),\(Int((f.height * 10000).rounded()))]"
        }
        s += "}"
        return s
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        lines.reserveCapacity(frames.count + labels.count + 1)
        lines.append(String(decoding: try encoder.encode(["session": info]), as: UTF8.self))
        for f in frames { lines.append(Recording.encodeFrame(f)) }
        for l in labels { lines.append(String(decoding: try encoder.encode(["label": l]), as: UTF8.self)) }
        return lines.joined(separator: "\n") + "\n"
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Decoding

    private struct FrameLine: Decodable {
        var t: Double
        var a: Float
        var h: [[Int]]
        var f: [Int]?
    }

    private struct SessionLine: Decodable { var session: SessionInfo }
    private struct LabelLine: Decodable { var label: SegmentLabel }

    public static func decode(_ text: String) throws -> Recording {
        let decoder = JSONDecoder()
        var info: SessionInfo?
        var frames: [Frame] = []
        var labels: [SegmentLabel] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let data = Data(raw.utf8)
            if raw.hasPrefix("{\"t\"") {
                let line = try decoder.decode(FrameLine.self, from: data)
                frames.append(frame(from: line))
            } else if raw.hasPrefix("{\"session\"") {
                info = try decoder.decode(SessionLine.self, from: data).session
            } else if raw.hasPrefix("{\"label\"") {
                labels.append(try decoder.decode(LabelLine.self, from: data).label)
            }
        }
        guard let info else { throw RecordingError.noSessionLine }
        frames.sort { $0.time < $1.time }
        return Recording(info: info, frames: frames, labels: labels.sorted { $0.start < $1.start })
    }

    private static func frame(from line: FrameLine) -> Frame {
        var frame = Frame(time: line.t, aspect: line.a, handCount: min(line.h.count, 2))
        for (i, values) in line.h.prefix(2).enumerated() where values.count >= 64 {
            var hand = Hand()
            hand.chirality = Chirality(rawValue: UInt8(clamping: values[0])) ?? .unknown
            for j in 0..<21 {
                hand.set(Joint(rawValue: j)!, Float(values[1 + j * 3]) / 10000, Float(values[2 + j * 3]) / 10000,
                         confidence: Float(values[3 + j * 3]) / 100)
            }
            if i == 0 { frame.hand0 = hand } else { frame.hand1 = hand }
        }
        if let f = line.f, f.count == 4 {
            frame.setFace(FaceBox(x: Float(f[0]) / 10000, y: Float(f[1]) / 10000, width: Float(f[2]) / 10000,
                                  height: Float(f[3]) / 10000))
        }
        return frame
    }

    public static func load(_ url: URL) throws -> Recording {
        try decode(String(contentsOf: url, encoding: .utf8))
    }

    /// Every session in a folder (and its subfolders), oldest first.
    public static func loadAll(in folder: URL) throws -> [Recording] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var out: [Recording] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            out.append(try load(url))
        }
        return out.sorted { $0.info.startedAt < $1.info.startedAt }
    }
}

public enum RecordingError: Error, CustomStringConvertible {
    case noSessionLine
    public var description: String { "a recording must start with a session line" }
}

/// Appends a session to disk as it's recorded, frame by frame, so nothing is lost if the app quits.
public final class RecordingWriter {
    private let handle: FileHandle
    public let url: URL
    private var buffer = ""

    public init(url: URL, info: SessionInfo) throws {
        self.url = url
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        buffer = String(decoding: try encoder.encode(["session": info]), as: UTF8.self) + "\n"
        flush()
    }

    public func append(_ frame: Frame) {
        buffer += Recording.encodeFrame(frame) + "\n"
        if buffer.utf8.count > 64 * 1024 { flush() }
    }

    public func append(_ label: SegmentLabel) {
        if let data = try? JSONEncoder().encode(["label": label]) {
            buffer += String(decoding: data, as: UTF8.self) + "\n"
        }
        flush()
    }

    public func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(Data(buffer.utf8))
        buffer = ""
    }

    public func close() {
        flush()
        try? handle.close()
    }
}
