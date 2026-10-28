import NebulaCore
import SwiftUI

struct GesturesView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        Page {
            PageTitle(eyebrow: "Gestures", title: "What your hands can do",
                      subtitle: "A gesture acts only once its numbers meet every target on your own recordings. Window gestures act on the window in front, and only that window.")
            if engine.gate.mode == "recorder" && engine.report == nil && !engine.settings.trial {
                Panel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recording build").font(Theme.display(16))
                        Text("No gesture acts yet: there are no recordings to prove them on. For a quick try, run Quick start in Practice (10 minutes). To prove them, follow the full recording plan.")
                            .font(Theme.body(13)).foregroundStyle(Theme.ink2)
                    }
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(Gesture.allCases.enumerated()), id: \.element) { i, g in
                    if i > 0 { Divider1() }
                    GestureRow(title: g.title, movement: g.movement, action: g.action,
                               key: g.rawValue, hold: g.kind == .movement ? nil : engine.currentModel.tuning(for: g).hold,
                               score: engine.report?.evaluation.scores[g.rawValue], engine: engine)
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))

            if !engine.customs.isEmpty {
                Eyebrow("Your gestures")
                VStack(spacing: 0) {
                    ForEach(Array(engine.customs.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider1() }
                        GestureRow(title: c.spec.name, movement: c.spec.movement, action: c.spec.action.summary, key: c.id,
                                   hold: c.spec.hold, score: nil, engine: engine,
                                   customNote: String(format: "%.0f%% on %d held-out examples", c.recall * 100, c.heldOut),
                                   remove: { engine.removeCustom(c.id) })
                    }
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            }
        }
    }
}

private struct GestureRow: View {
    let title: String
    let movement: String
    let action: String
    let key: String
    let hold: Double?
    let score: GestureScore?
    @ObservedObject var engine: Engine
    var customNote: String?
    var remove: (() -> Void)?

    private var proven: Bool { engine.proven.contains(key) }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(title).font(Theme.display(16))
                    if let hold { Text(String(format: "hold %.2f s", hold)).font(Theme.mono(10.5)).foregroundStyle(Theme.ink3) }
                }
                Text(movement).font(Theme.body(13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                    Text(action).font(Theme.body(12.5)).foregroundStyle(Theme.ink)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                NebulaToggle(isOn: Binding(get: { engine.isOn(key) && proven }, set: { engine.setOn(key, $0) }), enabled: proven)
                Text(status).font(Theme.mono(10.5)).foregroundStyle(proven ? Theme.ink3 : Theme.warn)
                    .multilineTextAlignment(.trailing)
                if let remove {
                    Button("Remove", action: remove).buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
            }
            .frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var status: String {
        if engine.isTrialOnly(key) { return "Trial: not proven yet" }
        if let customNote { return customNote }
        if let s = score, s.examples > 0 {
            return String(format: "%.1f%% recall · %.1f%% precision\n%d test examples", s.recall * 100, s.precision * 100, s.examples)
        }
        return proven ? "Proven at build" : "Not proven yet"
    }
}
