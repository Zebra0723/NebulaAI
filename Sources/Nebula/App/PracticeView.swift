import NebulaCore
import SwiftUI

struct PracticeView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var recorder: Recorder
    @State private var plan: Recorder.Plan = .gestures
    @State private var conditions = Recorder.Conditions()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                PageTitle(eyebrow: "Practice", title: "See what Nebula sees") {
                    Button(engine.isCameraOn ? "Stop camera" : "Start camera") {
                        if engine.arming == .practice { engine.stopPractice() } else if engine.arming == .off { engine.startPractice() }
                    }
                    .buttonStyle(NebulaButtonStyle(kind: engine.isCameraOn ? .quiet : .primary))
                }
                stage
                if let warning = engine.lightWarning {
                    Text(warning).font(Theme.body(12.5)).foregroundStyle(Theme.warn)
                }
                readout
            }
            .padding(.horizontal, 40)
            .padding(.top, 52)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Rectangle().fill(Theme.line).frame(width: 1)
            ScrollView { side.padding(24) }
                .scrollIndicators(.hidden)
                .frame(width: 340)
                .background(Theme.surface)
        }
    }

    // MARK: - The live hand

    private var stage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(engine.flash ? Color.white : Theme.surface)
            if engine.isCameraOn {
                SkeletonView(snapshot: engine.live).padding(18)
            } else {
                VStack(spacing: 8) {
                    NebulaGlyph().frame(width: 28, height: 28).opacity(0.6)
                    Text("The camera is off").font(Theme.display(15)).foregroundStyle(Theme.ink2)
                    Text("Start it to see your hand as Nebula does: 21 points, no image kept.")
                        .font(Theme.body(12.5)).foregroundStyle(Theme.ink3)
                }
            }
            VStack {
                HStack {
                    if engine.isCameraOn { verdict }
                    Spacer()
                    if engine.live.status.holdGesture >= 0 {
                        HoldRing(progress: Double(engine.live.status.holdProgress), lineWidth: 4).frame(width: 46, height: 46)
                    }
                }
                Spacer()
                if recorder.running { promptBar }
            }
            .padding(18)
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
    }

    private var verdict: some View {
        let s = engine.live.status
        let agreed = s.agreed > 0 ? (Pose(rawValue: s.agreed)?.name ?? "custom") : nil
        return VStack(alignment: .leading, spacing: 4) {
            Text(agreed.map { "Sees: \($0)" } ?? (s.handVisible ? "Sees a hand" : rejectionText(s.rejection)))
                .font(Theme.display(17))
                .foregroundStyle(agreed != nil ? Theme.contact : Theme.ink)
            Text(String(format: "A %@ %.2f · B %@ %.2f (lead %.2f)",
                        (Pose(rawValue: s.judgeA)?.name ?? "—") as NSString, s.judgeAScore,
                        (Pose(rawValue: s.judgeB.top)?.name ?? "—") as NSString, s.judgeB.confidence, s.judgeB.margin))
                .font(Theme.mono(11)).foregroundStyle(Theme.ink2)
            if let last = engine.lastEvent, Date().timeIntervalSince(last.at) < 2 {
                Text("Fired: \(last.text)").font(Theme.mono(11)).foregroundStyle(Theme.contact)
            }
        }
        .padding(12)
        .background(Theme.ground.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func rejectionText(_ r: FeatureExtractor.Rejection) -> String {
        switch r {
        case .none: return "No hand"
        case .lowConfidence: return "Hand unclear"
        case .touchingEdge: return "Hand at the edge"
        case .tooFar: return "Hand too far away"
        case .tooNear: return "Hand too close"
        }
    }

    private var promptBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recorder.prompt).font(Theme.display(22)).foregroundStyle(recorder.phase == "now" ? Theme.contact : Theme.ink)
            if !recorder.detail.isEmpty { Text(recorder.detail).font(Theme.body(13)).foregroundStyle(Theme.ink2) }
            ProgressView(value: recorder.progress).tint(Theme.contact)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ground.opacity(0.85), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Numbers

    private var readout: some View {
        let l = engine.latency
        return HStack(spacing: 12) {
            Gauge3(title: "Nebula latency", subtitle: "frame → action posted", p: l.actions.count > 0 ? l.actions : l.perFrame,
                   target: 10, note: l.actions.count > 0 ? "\(l.actions.count) actions" : "per frame, no actions yet")
            Gauge3(title: "Vision", subtitle: "hand pose", p: l.vision, target: nil, note: nil)
            Gauge3(title: "Recognizer", subtitle: "features, judges, decision", p: l.recognizer, target: 2, note: nil)
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Camera")
                Text(String(format: "%.0f fps", engine.live.fps)).font(Theme.numeral(22))
                Text(engine.pipeline.resolution).font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
                Text(String(format: "camera age p50 %.0f ms", l.captureAge.p50)).font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    // MARK: - Recorder and enrollment

    private var side: some View {
        VStack(alignment: .leading, spacing: 18) {
            Eyebrow("Recorder")
            Text("Saves joints and labels only, never images.").font(Theme.body(12.5)).foregroundStyle(Theme.ink2)
            Picker("", selection: $plan) {
                ForEach(Recorder.Plan.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .disabled(recorder.running)
            Text(planHelp).font(Theme.body(12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)

            if plan != .enrollment {
                field("Light") {
                    Picker("", selection: $conditions.lighting) {
                        ForEach(["daylight", "lamp at night", "backlit", "overhead"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                field("Distance") {
                    Picker("", selection: $conditions.distanceCm) {
                        ForEach([40, 70, 100], id: \.self) { Text("\($0) cm").tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                field("Hand") {
                    Picker("", selection: $conditions.hand) {
                        ForEach(["right", "left", "both"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                if plan == .nothing {
                    field("Minutes") { Stepper("\(Int(conditions.minutes))", value: $conditions.minutes, in: 2...30, step: 1) }
                } else {
                    field("Of each") { Stepper("\(conditions.reps)", value: $conditions.reps, in: 3...30) }
                }
            }
            Button(recorder.running ? "Stop recording" : "Start recording") {
                if recorder.running { recorder.stop(saved: true) } else { recorder.start(plan, conditions) }
            }
            .buttonStyle(NebulaButtonStyle(kind: recorder.running ? .warn : .primary))
            .disabled(engine.isArmed)
            if engine.isArmed {
                Text("Turn Nebula off to record: practice never acts on your windows.").font(Theme.body(11.5)).foregroundStyle(Theme.ink3)
            }
            if recorder.savedSessions > 0 {
                Text("\(recorder.savedSessions) session\(recorder.savedSessions == 1 ? "" : "s") saved this time.").font(Theme.mono(11)).foregroundStyle(Theme.ink2)
            }
            if let busy = engine.busy { Text(busy).font(Theme.body(12)).foregroundStyle(Theme.contact) }
            Divider1()
            Eyebrow("Latency test")
            Toggle("Flash the screen when an action fires", isOn: $engine.flashTestOn).font(Theme.body(12.5))
            Text("Film your hand and this screen with a phone in slow motion; count frames from the hand's movement to the flash.")
                .font(Theme.body(11.5)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            if !engine.log.isEmpty {
                Divider1()
                Eyebrow("Recent")
                ForEach(Array(engine.log.prefix(6).enumerated()), id: \.offset) { _, line in
                    Text(line).font(Theme.body(11.5)).foregroundStyle(Theme.ink2)
                }
            }
        }
    }

    private var planHelp: String {
        switch plan {
        case .gestures: return "Prompts each gesture in turn: get ready, then do it during \"Now\", then rest."
        case .nothing: return "Just use your Mac. Everything recorded counts as \"nothing\": Nebula must never fire on it."
        case .nearMiss: return "Poses that look almost like a gesture. Nebula must not fire on these either."
        case .enrollment: return "About ten of each gesture, then Nebula fits itself to your hands."
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Text(label).font(Theme.body(12.5)).foregroundStyle(Theme.ink2).frame(width: 70, alignment: .leading)
            content()
        }
    }
}

private struct Gauge3: View {
    let title: String
    let subtitle: String
    let p: Percentiles
    let target: Double?
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(title)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: p.p95 < 10 ? "%.1f" : "%.0f", p.p95)).font(Theme.numeral(22))
                    .foregroundStyle(target.map { p.count > 0 && p.p95 > $0 ? Theme.warn : Theme.ink } ?? Theme.ink)
                Text("ms p95").font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
            }
            Text(String(format: "p50 %.2f · p99 %.2f", p.p50, p.p99)).font(Theme.mono(10.5)).foregroundStyle(Theme.ink2)
            Text(note ?? subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The hand as 21 points and its bones, mirrored like a mirror.
struct SkeletonView: View {
    let snapshot: LiveSnapshot

    private static let bones: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8), (5, 9), (9, 10), (10, 11), (11, 12),
        (9, 13), (13, 14), (14, 15), (15, 16), (13, 17), (0, 17), (17, 18), (18, 19), (19, 20),
    ]

    var body: some View {
        Canvas { context, size in
            func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
            if let face = snapshot.face {
                let r = CGRect(x: face.minX * size.width, y: face.minY * size.height, width: face.width * size.width, height: face.height * size.height)
                context.stroke(Path(roundedRect: r, cornerRadius: 12), with: .color(Theme.line), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            for (hand, color) in [(snapshot.otherHand, Theme.ink3), (snapshot.joints, Theme.contact)] where hand.count == 21 {
                var path = Path()
                for (a, b) in Self.bones {
                    path.move(to: point(hand[a]))
                    path.addLine(to: point(hand[b]))
                }
                context.stroke(path, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                for (i, p) in hand.enumerated() {
                    let c = point(p)
                    let r: CGFloat = i == 0 ? 5 : 3.5
                    let alpha = i < snapshot.confidences.count && color == Theme.contact ? Double(max(0.25, snapshot.confidences[i])) : 0.8
                    context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color.opacity(alpha)))
                }
            }
        }
    }
}
