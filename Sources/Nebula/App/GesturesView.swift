import NebulaCore
import SwiftUI

struct GesturesView: View {
    @ObservedObject var engine: Engine
    @ObservedObject var navigation: Navigation

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)]

    var body: some View {
        Page {
            PageTitle(eyebrow: "Gestures", title: "What your hands can do",
                      subtitle: "Window gestures act on the window in front, and only that window. Each one acts once it's proven on your own recordings, or straight away in trial mode.")
            hero
            group("Hold a pose", gestures: Gesture.all.filter { $0.kind == .held })
            group("Move", gestures: Gesture.all.filter { $0.kind == .movement })
            group("Slide and turn", gestures: Gesture.all.filter { $0.kind == .continuous })

            if !engine.customs.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Eyebrow("Your gestures")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(engine.customs, id: \.id) { c in
                            GestureCard(title: c.spec.name, movement: c.spec.movement, action: c.spec.action.summary, key: c.id,
                                        symbol: "wand.and.stars", tint: Theme.rose, hold: c.spec.hold, score: nil, engine: engine,
                                        customNote: String(format: "%.0f%% on %d held-out", c.recall * 100, c.heldOut),
                                        remove: { engine.removeCustom(c.id) })
                        }
                    }
                }
            }
        }
    }

    // MARK: - The state of things, at the top

    private var live: Int { Gesture.all.filter { engine.proven.contains($0.rawValue) && engine.isOn($0.rawValue) }.count }

    private var hero: some View {
        let on = engine.isArmed
        let noneYet = engine.gate.mode == "recorder" && engine.report == nil && !engine.settings.trial
        return HStack(alignment: .center, spacing: 20) {
            ZStack {
                Circle().fill(RadialGradient(colors: [(on ? Theme.contact : Theme.violet).opacity(0.35), .clear],
                                             center: .center, startRadius: 0, endRadius: 44))
                    .frame(width: 88, height: 88)
                NebulaGlyph(armed: on).frame(width: 34, height: 34)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(on ? "Nebula is watching" : "Nebula is off").font(Theme.display(22))
                    if engine.settings.trial { Pill(text: "Trial mode", color: Theme.violet) }
                }
                Text(noneYet
                     ? "No gesture can act yet. Quick start in Practice takes about ten minutes, then they all work in trial mode."
                     : on ? "\(live) of \(Gesture.count) gestures live. Wave to turn off, or press fn F1."
                          : "\(live) of \(Gesture.count) gestures ready. Press fn F1 to turn on; the camera stays off until you do.")
                    .font(Theme.body(13)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if noneYet {
                Button("Quick start") { navigation.section = .practice }.buttonStyle(NebulaButtonStyle(kind: .primary))
            } else {
                Button(on ? "Turn off" : "Turn on") { engine.toggleArmed() }
                    .buttonStyle(NebulaButtonStyle(kind: on ? .quiet : .primary))
                    .disabled(engine.arming == .practice)
            }
        }
        .padding(22)
        .glass(radius: 20, glow: on ? Theme.contact : Theme.violet)
        .animation(.easeOut(duration: 0.25), value: on)
    }

    private func group(_ title: String, gestures: [NebulaCore.Gesture]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(title)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(gestures, id: \.self) { g in
                    GestureCard(title: g.title, movement: g.movement, action: g.action, key: g.rawValue,
                                symbol: g.symbol, tint: g.tint,
                                hold: g.kind == .movement ? nil : engine.currentModel.tuning(for: g).hold,
                                score: engine.report?.evaluation.scores[g.rawValue], engine: engine)
                }
            }
        }
    }
}

extension NebulaCore.Gesture {
    /// What the gesture does, as a symbol: the action is what you remember.
    var symbol: String {
        switch self {
        case .openPalm: return "playpause"
        case .thumbsUp: return "hand.thumbsup"
        case .thumbsDown: return "hand.thumbsdown"
        case .peace: return "sparkle"
        case .fingerToLips: return "speaker.slash"
        case .handToEar: return "ear"
        case .swipeLeft: return "arrow.left"
        case .swipeRight: return "arrow.right"
        case .scroll: return "arrow.up.and.down"
        case .volumeKnob: return "dial.medium"
        case .wave: return "hand.wave"
        }
    }

    var tint: Color {
        switch kind {
        case .held: return Theme.violet
        case .movement: return Theme.teal
        case .continuous: return Theme.rose
        }
    }
}

private struct GestureCard: View {
    let title: String
    let movement: String
    let action: String
    let key: String
    let symbol: String
    let tint: Color
    let hold: Double?
    let score: GestureScore?
    @ObservedObject var engine: Engine
    var customNote: String?
    var remove: (() -> Void)?
    @State private var hovering = false

    private var proven: Bool { engine.proven.contains(key) }
    private var on: Bool { engine.isOn(key) && proven }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                SymbolTile(symbol: symbol, tint: tint, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.display(17))
                    Text(action).font(Theme.body(12.5)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                NebulaToggle(isOn: Binding(get: { on }, set: { engine.setOn(key, $0) }), enabled: proven)
            }
            Text(movement)
                .font(Theme.body(12.5)).foregroundStyle(Theme.ink2)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Divider1()
            HStack(spacing: 8) {
                status
                Spacer(minLength: 6)
                if let detail { Text(detail).font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).lineLimit(1) }
                if let remove {
                    Button("Remove", action: remove).buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink3)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 186, alignment: .topLeading)
        .glass(glow: hovering ? tint : nil)
        .opacity(proven ? 1 : 0.85)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder private var status: some View {
        if !proven {
            Pill(text: "Not proven yet", color: Theme.warn)
        } else if !engine.isOn(key) {
            Pill(text: "Off", color: Theme.ink3)
        } else if engine.isTrialOnly(key) {
            Pill(text: "Trial", color: Theme.violet)
        } else {
            Pill(text: "Live", color: Theme.contact)
        }
    }

    private var detail: String? {
        if let customNote { return customNote }
        if let s = score, s.examples > 0 { return String(format: "%.1f%% recall · %.1f%% precision", s.recall * 100, s.precision * 100) }
        if let hold { return String(format: "hold %.2f s", hold) }
        return nil
    }
}
