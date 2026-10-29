import Foundation

/// Nebula's connection to Galaxy Link (galaxyd), as body `nebula`.
///
/// Fails soft like every body: when Link isn't running, calls return nil and Nebula
/// carries on alone. Approvals come in by long poll, so the camera arms the moment a
/// body starts waiting on a yes or no, and a decision reaches that body at once.
actor GalaxyLink {
    static let shared = GalaxyLink()
    static let body = "nebula"

    static let intro = "Hi everyone, I'm Nebula, the touch of GalaxyAI. I watch for hand gestures on the Mac, " +
        "only while I'm switched on: a thumbs up or down answers anything you're waiting on, a finger to the lips " +
        "mutes Orbit, a peace sign calls Nova, and a few more steer whatever window is in front. " +
        "Ask for a yes or no and I'll turn the camera on for a minute so our human can give it with a hand."

    struct Approval: Codable, Identifiable, Equatable {
        let id: String
        let from: String
        let title: String
        let detail: String
        let status: String
        let createdAt: Double
        let expiresAt: Double
    }

    struct PendingResponse: Codable {
        let version: Int
        let pending: [Approval]
    }

    struct LinkTask: Codable {
        let id: String
        let status: String
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Galaxy", isDirectory: true)

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        config.connectionProxyDictionary = [:] // loopback only, never through a proxy
        return URLSession(configuration: config)
    }()

    /// False when this galaxyd predates approvals (no /v1/approvals).
    private(set) var approvalsSupported = true

    // MARK: - Plumbing

    private func token() -> String? {
        let t = (try? String(contentsOf: Self.home.appendingPathComponent("token"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t?.isEmpty == false ? t : nil
    }

    private func baseURL() -> URL {
        let port = (try? String(contentsOf: Self.home.appendingPathComponent("port"), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return URL(string: "http://127.0.0.1:\(port ?? 7740)")!
    }

    /// (status, body) for any response; nil when Link isn't reachable.
    private func call(_ method: String, _ path: String, body: Any? = nil, timeout: TimeInterval = 10) async -> (Int, Data)? {
        guard let token = token(), let url = URL(string: path, relativeTo: baseURL()) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.body, forHTTPHeaderField: "X-Galaxy-Body")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    private func ok(_ result: (Int, Data)?) -> Data? {
        guard let (status, data) = result, (200..<300).contains(status), status != 204 else { return nil }
        return data
    }

    // MARK: - Presence

    @discardableResult
    func hello() async -> Bool {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return ok(await call("POST", "/v1/hello", body: [
            "name": "Nebula", "version": version, "powers": ["gestures", "approvals", "gesture_training"], "intro": Self.intro,
        ])) != nil
    }

    func heartbeat() async -> Bool {
        if ok(await call("POST", "/v1/heartbeat", body: [String: String]())) != nil { return true }
        return await hello()
    }

    func goodbye() async {
        _ = await call("POST", "/v1/goodbye", body: [String: String](), timeout: 2)
    }

    func isRunning() async -> Bool {
        guard let url = URL(string: "/v1/health", relativeTo: baseURL()) else { return false }
        guard let (_, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 2)) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func note(_ summary: String) async {
        _ = await call("POST", "/v1/events", body: ["kind": "activity", "summary": summary])
    }

    // MARK: - Approvals

    /// Pending approvals, returning as soon as the set differs from `version` (or after ~25 s).
    func pendingApprovals(since version: Int) async -> PendingResponse? {
        let result = await call("GET", "/v1/approvals/pending?since=\(version)&wait=25", timeout: 35)
        if result?.0 == 404 {
            approvalsSupported = false
            return nil
        }
        approvalsSupported = true
        return ok(result).flatMap { try? JSONDecoder().decode(PendingResponse.self, from: $0) }
    }

    /// Approves or rejects. The waiting body hears it immediately.
    func decide(_ id: String, approve: Bool) async -> Approval? {
        ok(await call("POST", "/v1/approvals/\(id)/decide", body: ["decision": approve ? "approve" : "reject", "via": "gesture"]))
            .flatMap { try? JSONDecoder().decode(Approval.self, from: $0) }
    }

    // MARK: - Training

    /// An item Link hands Nebula. Only Galaxy Trainer's workouts ("workout") come here.
    struct InboxItem: Codable {
        let id: Int
        let kind: String
        let taskId: String
        let text: String
    }

    /// Waits up to ~25 s for something new. nil when Link isn't there.
    func inbox() async -> [InboxItem]? {
        ok(await call("GET", "/v1/inbox?wait=25", timeout: 35)).flatMap { try? JSONDecoder().decode([InboxItem].self, from: $0) }
    }

    /// Nebula's answer to a workout: its results, as JSON.
    @discardableResult
    func practiceAnswer(id: String, answer: String) async -> Bool {
        ok(await call("POST", "/v1/practice/\(id)/answer", body: ["answer": answer], timeout: 30)) != nil
    }

    /// What Galaxy Trainer has taught Nebula: the lessons switched on, and the latest workout results.
    struct TrainingNotes: Sendable {
        let lessons: [String]
        let results: [String]
    }

    func training() async -> TrainingNotes? {
        guard let data = ok(await call("GET", "/v1/training/nebula")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let lessons = (json["lessons"] as? [[String: Any]] ?? [])
            .filter { ($0["active"] as? Bool) == true }
            .compactMap { $0["text"] as? String }
        let results = (json["thread"] as? [[String: Any]] ?? [])
            .filter { ($0["kind"] as? String) == "results" }
            .compactMap { $0["text"] as? String }
        return TrainingNotes(lessons: lessons, results: Array(results.suffix(2)))
    }

    /// A line in Nebula's 1:1 with the trainer, which you can read in Galaxy Trainer.
    func postToTrainer(_ text: String) async {
        _ = await call("POST", "/v1/training/nebula/thread", body: ["kind": "message", "text": text])
    }

    // MARK: - Comet

    /// Sends a message to the user through Comet (iMessage), as a handoff Comet picks up.
    func sendThroughComet(title: String, text: String) async -> LinkTask? {
        ok(await call("POST", "/v1/tasks", body: [
            "to": "comet", "power": "imessage", "title": title,
            "instructions": "Text this to the user exactly as written, from Nebula:\n\n\(text)",
        ])).flatMap { try? JSONDecoder().decode(LinkTask.self, from: $0) }
    }
}
