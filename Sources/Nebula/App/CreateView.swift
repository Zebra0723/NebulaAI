import NebulaCore
import SwiftUI

/// The AI gesture builder. You describe; Claude designs a movement and an action; Nebula checks
/// it against everything you've recorded and sends Claude back to the drawing board if it would
/// misfire. Claude's replies reach you through Comet. Then you record examples, and it saves
/// only at 99% or better on examples it didn't learn from.
@MainActor
final class CreateModel: ObservableObject {
    struct Turn: Identifiable {
        let id = UUID()
        let fromUser: Bool
        let text: String
    }

    enum Stage: Equatable { case describing, designing, checking, ready, recording, verifying, saved }

    @Published var draft = ""
    @Published private(set) var turns: [Turn] = []
    @Published private(set) var stage: Stage = .describing
    @Published private(set) var design: GestureDesigner.Design?
    @Published private(set) var clash: ClashReport?
    @Published private(set) var verification: CustomVerification?
    @Published private(set) var error: String?
    @Published private(set) var cometNote: String?
    private var history: [(role: String, text: String)] = []

    func send(_ engine: Engine) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        turns.append(Turn(fromUser: true, text: text))
        Task { await designLoop(engine, request: text) }
    }

    /// Asks Claude, checks the design, and retries with the clash details (twice at most).
    private func designLoop(_ engine: Engine, request: String) async {
        guard let key = Keychain.apiKey else {
            error = "Add an Anthropic API key in Settings first."
            return
        }
        error = nil
        let existing = Gesture.allCases.map { "\($0.title): \($0.movement)" } + engine.customs.map { "\($0.spec.name): \($0.spec.movement)" }
        var clashes: [String] = []
        for attempt in 0..<3 {
            stage = .designing
            do {
                let d = try await GestureDesigner(apiKey: key).design(request: request, history: history, existing: existing, clashes: clashes)
                stage = .checking
                let model = engine.currentModel
                let report = await Task.detached(priority: .userInitiated) { () -> ClashReport in
                    let recordings = (try? Recording.loadAll(in: Paths.recordings)) ?? []
                    return CustomGestureCheck.check(d.spec, against: recordings.filter { $0.info.kind != .enrollment }, model: model)
                }.value
                history.append((role: "user", text: attempt == 0 ? request : request + "\n\n(checks failed: \(clashes.joined(separator: "; ")))"))
                history.append((role: "assistant", text: Self.summary(d)))
                if report.ok || attempt == 2 {
                    design = d
                    clash = report
                    turns.append(Turn(fromUser: false, text: d.reply))
                    stage = report.ok ? .ready : .describing
                    await sendThroughComet(d.reply, name: d.spec.name)
                    return
                }
                clashes = report.problems
            } catch {
                self.error = error.localizedDescription
                stage = .describing
                return
            }
        }
    }

    private static func summary(_ d: GestureDesigner.Design) -> String {
        "Designed \"\(d.spec.name)\": \(d.spec.movement). Action: \(d.spec.action.summary). " +
            "Conditions: " + d.spec.rule.conditions.map { "\($0.feature) \($0.min.map { "≥\($0)" } ?? "") \($0.max.map { "≤\($0)" } ?? "")" }.joined(separator: ", ")
    }

    private func sendThroughComet(_ text: String, name: String) async {
        if await GalaxyLink.shared.sendThroughComet(title: "Nebula: \(name)", text: text) != nil {
            cometNote = "Sent to you through Comet."
        } else {
            cometNote = "Galaxy Link isn't running, so Comet didn't get this one. It's shown here."
        }
    }

    func record(_ engine: Engine) {
        guard let d = design else { return }
        stage = .recording
        let id = "custom-" + d.spec.name.lowercased().replacingOccurrences(of: " ", with: "-")
        engine.recorder.startCustom(id: id, title: d.spec.name, movement: d.spec.movement, reps: 12) { [weak self] in
            Task { @MainActor in self?.verify(engine, id: id) }
        }
    }

    private func verify(_ engine: Engine, id: String) {
        guard let d = design else { return }
        stage = .verifying
        let base = engine.currentModel
        let existing = engine.customs.map(\.gesture)
        let examples = engine.customRecordings().filter { $0.info.notes == "custom:\(id)" }
        var tuning = GestureTuning()
        tuning.hold = d.spec.hold
        let gesture = CustomGesture(id: id, name: d.spec.name, rule: d.spec.rule, label: Pose.builtinCount + existing.count, tuning: tuning)
        Task {
            let v = await Task.detached(priority: .userInitiated) { () -> CustomVerification in
                let library = ((try? Recording.loadAll(in: Paths.recordings)) ?? []).filter { $0.info.kind != .enrollment }
                return CustomGestureCheck.verify(gesture, examples: examples, library: library, base: base, customs: existing)
            }.value
            verification = v
            stage = .ready
        }
    }

    func save(_ engine: Engine) {
        guard let d = design, let v = verification, v.passes else { return }
        let id = "custom-" + d.spec.name.lowercased().replacingOccurrences(of: " ", with: "-")
        var tuning = GestureTuning()
        tuning.hold = d.spec.hold
        let gesture = CustomGesture(id: id, name: d.spec.name, rule: d.spec.rule, label: Pose.builtinCount + engine.customs.count, tuning: tuning)
        engine.saveCustom(SavedCustomGesture(spec: d.spec, gesture: gesture, recall: v.recall, heldOut: v.heldOut), model: v.model, report: v.report)
        stage = .saved
        turns.append(Turn(fromUser: false, text: "Saved. \(d.spec.name) is live, and runs on the Mac with no tokens."))
    }

    func reset() {
        turns = []
        history = []
        design = nil
        clash = nil
        verification = nil
        stage = .describing
        error = nil
        cometNote = nil
    }
}

struct CreateView: View {
    @ObservedObject var engine: Engine
    @StateObject private var model = CreateModel()

    var body: some View {
        Page(maxWidth: 820) {
            PageTitle(eyebrow: "Create", title: "Design a gesture",
                      subtitle: "Describe what you'd like. Claude designs the exact movement and action; Nebula checks it against your recordings before you record it. Replies also arrive through Comet.") {
                if !model.turns.isEmpty { Button("Start over") { model.reset() }.buttonStyle(NebulaButtonStyle()) }
            }
            if Recorder.gestureLabels.isEmpty == false && engine.customs.count >= Recognizer.maxCustoms {
                Text("You have \(Recognizer.maxCustoms) custom gestures, the most Nebula keeps. Remove one to add another.")
                    .font(Theme.body(12.5)).foregroundStyle(Theme.warn)
            }
            if model.turns.isEmpty { suggestions }
            ForEach(model.turns) { turn in
                TurnBubble(turn: turn)
            }
            if let note = model.cometNote { Text(note).font(Theme.mono(11)).foregroundStyle(Theme.ink3) }
            if let design = model.design { designCard(design) }
            if let error = model.error { Text(error).font(Theme.body(12.5)).foregroundStyle(Theme.warn) }
            stageLine
            HStack(spacing: 10) {
                TextField(model.turns.isEmpty ? "A gesture to reopen the last closed tab, maybe a pinky up?" : "Ask for a change…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .nebulaField()
                    .onSubmit { model.send(engine) }
                Button("Send") { model.send(engine) }
                    .buttonStyle(NebulaButtonStyle(kind: .primary))
                    .disabled(model.stage == .designing || model.stage == .checking || model.draft.isEmpty)
            }
        }
    }

    @ViewBuilder private var stageLine: some View {
        switch model.stage {
        case .designing: working("Claude is designing…")
        case .checking: working("Checking against your recordings…")
        case .recording: working("Recording examples in Practice…")
        case .verifying: working("Teaching Judge B and testing on held-out examples…")
        default: EmptyView()
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(Theme.body(12.5)).foregroundStyle(Theme.contact)
        }
    }

    /// Ideas to start from, before the first message.
    private var suggestions: some View {
        let ideas: [(String, String)] = [
            ("arrow.uturn.backward", "Reopen the last closed tab"),
            ("camera.viewfinder", "Take a screenshot of the window in front"),
            ("forward.end", "Skip to the next song with two fingers flicked"),
            ("moon", "Turn on Do Not Disturb"),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Try one of these")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(ideas.indices, id: \.self) { i in
                    let idea = ideas[i]
                    Button { model.draft = idea.1 } label: {
                        HStack(spacing: 12) {
                            SymbolTile(symbol: idea.0, tint: Theme.violet, size: 30)
                            Text(idea.1).font(Theme.body(13)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .glass(radius: 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func designCard(_ d: GestureDesigner.Design) -> some View {
        Panel(glow: Theme.violet) {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("Design")
                HStack(spacing: 12) {
                    SymbolTile(symbol: "wand.and.stars", tint: Theme.rose, size: 36)
                    Text(d.spec.name).font(Theme.display(22))
                }
                Text(d.spec.movement).font(Theme.body(13.5)).foregroundStyle(Theme.ink2)
                Text("Action: \(d.spec.action.summary)").font(Theme.body(13))
                Text(String(format: "Hold %.2f s · %d conditions", d.spec.hold, d.spec.rule.conditions.count))
                    .font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                Divider1()
                if let clash = model.clash {
                    if clash.ok {
                        Text(String(format: "Passed the checks: no fire in %.0f minutes of ordinary movement and near-misses, and no overlap with any gesture.", clash.nothingSeconds / 60))
                            .font(Theme.body(12.5)).foregroundStyle(Theme.contact)
                    } else {
                        ForEach(clash.problems, id: \.self) { Text($0).font(Theme.body(12.5)).foregroundStyle(Theme.warn) }
                        Text("Describe something else, or ask Claude for another idea.").font(Theme.body(12)).foregroundStyle(Theme.ink3)
                    }
                }
                if let v = model.verification {
                    Text(String(format: "%d of %d held-out examples recognized (%.0f%%), %d false fires.", v.recognized, v.heldOut, v.recall * 100, v.falseFires))
                        .font(Theme.mono(11.5)).foregroundStyle(v.passes ? Theme.contact : Theme.warn)
                    if !v.passes {
                        Text("Below 99%: it can't be saved. Record again, holding the pose more consistently, or ask for a clearer movement.")
                            .font(Theme.body(12)).foregroundStyle(Theme.ink3)
                    }
                }
                HStack(spacing: 10) {
                    Button("Record 12 examples") { model.record(engine) }
                        .buttonStyle(NebulaButtonStyle())
                        .disabled(!(model.clash?.ok ?? false) || model.stage == .recording || model.stage == .verifying)
                    Button("Save") { model.save(engine) }
                        .buttonStyle(NebulaButtonStyle(kind: .primary))
                        .disabled(!(model.verification?.passes ?? false) || model.stage == .saved)
                }
            }
        }
    }
}

/// One message: yours on the right in violet, Claude's on the left in glass, with Nebula's mark.
private struct TurnBubble: View {
    let turn: CreateModel.Turn

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if turn.fromUser { Spacer(minLength: 120) } else {
                NebulaGlyph().frame(width: 18, height: 18).padding(.top, 10)
            }
            Text(turn.text)
                .font(Theme.body(13.5))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .padding(.horizontal, 15).padding(.vertical, 11)
                .background {
                    if turn.fromUser {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.violet.opacity(0.34), Theme.violet.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
                .modifier(BubbleGlass(on: !turn.fromUser))
                .textSelection(.enabled)
            if !turn.fromUser { Spacer(minLength: 120) }
        }
    }
}

private struct BubbleGlass: ViewModifier {
    let on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.glass(radius: 16) } else { content }
    }
}
