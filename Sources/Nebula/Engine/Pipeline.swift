import AVFoundation
import CoreMedia
import Foundation
import NebulaCore
import Vision

/// What the Practice screen draws, published at most 30 times a second.
struct LiveSnapshot {
    var hasHand = false
    /// The followed hand's joints in mirror-view unit coordinates (0...1, origin top-left).
    var joints: [CGPoint] = []
    var confidences: [Float] = []
    var otherHand: [CGPoint] = []
    var face: CGRect?
    var status = RecognizerStatus()
    var fps: Double = 0
    var lastEvent: String = ""
}

/// The camera → joints → gesture pipeline. Everything per frame runs on one dedicated
/// userInteractive serial queue, reuses one hand-pose request and one sequence handler,
/// and posts actions from right here. Only the snapshot for the UI goes to the main thread.
final class Pipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let visionQueue = DispatchQueue(label: "ai.galaxy.nebula.vision", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "ai.galaxy.nebula.session", qos: .userInitiated)
    private let faceQueue = DispatchQueue(label: "ai.galaxy.nebula.face", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()

    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private let sequence = VNSequenceRequestHandler()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let faceSequence = VNSequenceRequestHandler()

    private static let jointNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip, .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip, .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    // Vision-queue state.
    private(set) var recognizer: Recognizer
    var router: ActionRouter?
    /// Practice: recognize and show, but never act.
    var actionsEnabled = false
    var recorder: RecordingWriter?
    private var frameCount = 0
    private var lastArrival: UInt64 = 0
    private var intervalEMA: Double = 1.0 / 30
    private var lastPublish: UInt64 = 0
    private var faceLock = NSLock()
    private var cachedFace: (box: FaceBox, at: Double)?
    private var faceInFlight = false
    private var recent: [Frame] = []
    private var recentIndex = 0

    // Timing, all milliseconds.
    let visionTime = LatencyLog(capacity: 2048)
    let recognizerTime = LatencyLog(capacity: 2048)
    /// Camera frame delivered → decision made (and any actions posted), every frame.
    let frameTime = LatencyLog(capacity: 2048)
    /// Capture → delivered: the camera's own pipeline, outside Nebula's control.
    let captureAge = LatencyLog(capacity: 2048)
    private(set) var droppedStale = 0

    /// Main thread: the newest snapshot, and when a hand was last seen.
    var onSnapshot: ((LiveSnapshot) -> Void)?
    var onEvent: ((RecognizerEvent) -> Void)?
    private(set) var lastHandSeen = Date()
    private(set) var targetFPS: Double = 30
    private(set) var resolution = ""

    init(model: NebulaModel) {
        recognizer = Recognizer(model: model)
        super.init()
        recent = Array(repeating: Frame(time: 0), count: 240)
    }

    // MARK: - Camera

    enum CameraError: Error { case noCamera, notAllowed }

    /// Configures the camera once, up front, so arming only has to start it. Picks the highest
    /// frame rate the camera offers at the smallest size that keeps hand pose accurate, and pins
    /// the frame duration so dim light can't stretch exposure and drop the frame rate.
    func configure(highResolution: Bool) throws {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else { throw CameraError.noCamera }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.noCamera }
        session.addInput(input)

        let minWidth: Int32 = highResolution ? 1280 : 640
        var best: (format: AVCaptureDevice.Format, rate: Double, area: Int32)?
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width >= minWidth else { continue }
            let rate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let area = dims.width * dims.height
            if let b = best {
                // Faster first; at the same speed, smaller.
                if rate > b.rate + 0.5 || (abs(rate - b.rate) <= 0.5 && area < b.area) { best = (format, rate, area) }
            } else {
                best = (format, rate, area)
            }
        }
        if let best {
            try device.lockForConfiguration()
            device.activeFormat = best.format
            let rate = min(best.rate, 60)
            let duration = CMTime(value: 1000, timescale: CMTimeScale(rate * 1000))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            targetFPS = rate
            let dims = CMVideoFormatDescriptionGetDimensions(best.format.formatDescription)
            resolution = "\(dims.width)×\(dims.height) at \(Int(rate.rounded())) fps"
        }

        if !session.outputs.contains(output) {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self, queue: visionQueue)
            guard session.canAddOutput(output) else { throw CameraError.noCamera }
            session.addOutput(output)
        }
    }

    func start() {
        sessionQueue.async { if !self.session.isRunning { self.session.startRunning() } }
        visionQueue.async { self.recognizer.reset() }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
        visionQueue.async { self.recognizer.reset() }
    }

    /// Swaps in a new recognizer (new model, custom gestures, switches) between frames.
    func use(model: NebulaModel, customs: [CustomGesture], disabled: Set<String>) {
        let next = Recognizer(model: model, customs: customs)
        for g in Gesture.allCases where disabled.contains(g.rawValue) { next.setEnabled(g.index, false) }
        for (i, c) in customs.enumerated() where disabled.contains(c.id) || !c.enabled {
            next.setEnabled(Recognizer.customBase + i, false)
        }
        visionQueue.async { self.recognizer = next }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let arrival = Monotonic.nanoseconds()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        captureAge.record(Float((now - pts) * 1000))
        if lastArrival > 0 {
            let dt = Double(arrival &- lastArrival) / 1e9
            intervalEMA += 0.05 * (dt - intervalEMA)
        }
        lastArrival = arrival
        // Never act on a stale frame: if this one waited more than two frame intervals, skip it.
        if now - pts > 2.5 / max(targetFPS, 1) {
            droppedStale += 1
            return
        }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)

        try? sequence.perform([handRequest], on: pixels, orientation: .up)
        let visionDone = Monotonic.nanoseconds()
        visionTime.record(Float(Double(visionDone &- arrival) / 1e6))

        var frame = Frame(time: pts, aspect: Float(width) / Float(max(height, 1)))
        if let results = handRequest.results {
            for (i, obs) in results.prefix(2).enumerated() {
                var hand = Hand()
                switch obs.chirality {
                case .left: hand.chirality = .left
                case .right: hand.chirality = .right
                default: hand.chirality = .unknown
                }
                for (j, name) in Self.jointNames.enumerated() {
                    if let p = try? obs.recognizedPoint(name) {
                        hand.x[j] = Float(p.location.x)
                        hand.y[j] = Float(p.location.y)
                        hand.confidence[j] = p.confidence
                    }
                }
                if i == 0 { frame.hand0 = hand } else { frame.hand1 = hand }
                frame.handCount = i + 1
            }
        }
        // The face rectangle comes from a separate queue about ten times a second; faces move
        // slowly, and the hot path never waits for it.
        faceLock.lock()
        if let face = cachedFace, pts - face.at < 1.0 { frame.setFace(face.box) }
        let launchFace = !faceInFlight && frameCount % 6 == 0
        if launchFace { faceInFlight = true }
        faceLock.unlock()
        if launchFace { detectFace(pixels, at: pts) }

        let r0 = Monotonic.nanoseconds()
        recognizer.process(frame)
        recognizerTime.record(Float(Double(Monotonic.nanoseconds() &- r0) / 1e6))
        for e in 0..<recognizer.eventCount {
            let event = recognizer.event(e)
            if actionsEnabled { router?.handle(event, arrival: arrival, frameTime: pts) }
            if let onEvent { DispatchQueue.main.async { onEvent(event) } }
        }
        frameTime.record(Float(Double(Monotonic.nanoseconds() &- arrival) / 1e6))

        recent[recentIndex] = frame
        recentIndex = (recentIndex + 1) % recent.count
        recorder?.append(frame)
        frameCount += 1
        if frame.handCount > 0 { lastHandSeen = Date() }
        publish(frame, arrival: arrival)
    }

    private func detectFace(_ pixels: CVPixelBuffer, at pts: Double) {
        faceQueue.async {
            try? self.faceSequence.perform([self.faceRequest], on: pixels, orientation: .up)
            let box = (self.faceRequest.results ?? []).max { $0.boundingBox.width < $1.boundingBox.width }?.boundingBox
            self.faceLock.lock()
            if let box {
                self.cachedFace = (FaceBox(x: Float(box.minX), y: Float(box.minY), width: Float(box.width), height: Float(box.height)), pts)
            }
            self.faceInFlight = false
            self.faceLock.unlock()
        }
    }

    private func publish(_ frame: Frame, arrival: UInt64) {
        guard let onSnapshot, arrival &- lastPublish > 33_000_000 else { return }
        lastPublish = arrival
        var snap = LiveSnapshot()
        snap.status = recognizer.status
        snap.fps = 1 / max(intervalEMA, 1e-3)
        let followed = recognizer.status.hand
        for i in 0..<frame.handCount {
            let h = frame.hand(i)
            let points = (0..<21).map { CGPoint(x: CGFloat(1 - h.x[$0]), y: CGFloat(1 - h.y[$0])) }
            if i == followed || (followed < 0 && i == 0) {
                snap.hasHand = true
                snap.joints = points
                snap.confidences = (0..<21).map { h.confidence[$0] }
            } else {
                snap.otherHand = points
            }
        }
        if frame.hasFace {
            let f = frame.face
            snap.face = CGRect(x: CGFloat(1 - f.x - f.width), y: CGFloat(1 - f.y - f.height), width: CGFloat(f.width), height: CGFloat(f.height))
        }
        DispatchQueue.main.async { onSnapshot(snap) }
    }

    /// The last few seconds of frames, oldest first (for saving a near-miss or a wrong fire).
    func recentFrames(seconds: Double, completion: @escaping ([Frame]) -> Void) {
        visionQueue.async {
            let ordered = Array(self.recent[self.recentIndex...] + self.recent[..<self.recentIndex]).filter { $0.time > 0 }
            guard let last = ordered.last?.time else { return completion([]) }
            completion(ordered.filter { $0.time >= last - seconds })
        }
    }

    var measuredFPS: Double { 1 / max(intervalEMA, 1e-3) }
}
