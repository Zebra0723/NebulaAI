import AppKit
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case gestures, create, practice, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .gestures: return "hand.raised"
        case .create: return "wand.and.stars"
        case .practice: return "viewfinder"
        case .settings: return "slider.horizontal.3"
        }
    }
}

@MainActor
final class Navigation: ObservableObject {
    @Published var section: AppSection = .gestures
}

/// The Nebula window: Gestures, Create, Practice, Settings.
@MainActor
final class AppWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let engine: Engine
    private let navigation = Navigation()

    init(engine: Engine) {
        self.engine = engine
    }

    func show(_ section: AppSection? = nil) {
        if let section { navigation.section = section }
        if window == nil { window = makeWindow() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine.stopPractice()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Nebula"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.ground)
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: RootView(navigation: navigation, engine: engine)
            .environment(\.colorScheme, .dark))
        window.center()
        window.setFrameAutosaveName("NebulaWindow")
        return window
    }
}

struct RootView: View {
    @ObservedObject var navigation: Navigation
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.line.opacity(0.8)).frame(width: 1)
            Group {
                switch navigation.section {
                case .gestures: GesturesView(engine: engine, navigation: navigation)
                case .create: CreateView(engine: engine)
                case .practice: PracticeView(engine: engine, recorder: engine.recorder, feed: engine.liveFeed)
                case .settings: SettingsView(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            .id(navigation.section)
        }
        .animation(.easeOut(duration: 0.18), value: navigation.section)
        .background(NebulaBackdrop(lit: engine.isArmed).equatable())
        .ignoresSafeArea()
        .foregroundStyle(Theme.ink)
        .tint(Theme.contact)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 11) {
                NebulaGlyph(armed: engine.isArmed).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nebula").font(Theme.display(21))
                    Text("GALAXY · GESTURES").font(.system(size: 8.5, weight: .semibold)).tracking(1.4).foregroundStyle(Theme.ink3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 54)
            .padding(.bottom, 28)

            ForEach(AppSection.allCases) { section in
                SidebarRow(section: section, selected: navigation.section == section) { navigation.section = section }
            }
            Spacer()
            ArmCard(engine: engine)
            HStack(spacing: 8) {
                Circle().fill(engine.linkConnected ? Theme.contact : Theme.ink3).frame(width: 6, height: 6)
                    .shadow(color: engine.linkConnected ? Theme.contact.opacity(0.7) : .clear, radius: 4)
                Text(engine.linkConnected ? "Galaxy Link connected" : "Galaxy Link not running")
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 12)
        .frame(width: 232)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.ground.opacity(0.55))
    }
}

/// On or off, at the foot of the sidebar: what Nebula is doing right now and the switch for it.
private struct ArmCard: View {
    @ObservedObject var engine: Engine

    private var state: (title: String, detail: String, color: Color) {
        switch engine.arming {
        case .off: return ("Off", "Camera off", Theme.ink3)
        case .armed: return ("On", engine.settings.trial ? "Watching · trial mode" : "Watching for gestures", Theme.contact)
        case .approval: return ("Approval", "Thumbs up or down", Theme.contact)
        case .practice: return ("Practice", "Showing, never acting", Theme.violet)
        }
    }

    var body: some View {
        let s = state
        let on = engine.isArmed
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle().fill(s.color.opacity(0.18)).frame(width: 26, height: 26)
                    Circle().fill(s.color).frame(width: 8, height: 8).shadow(color: s.color, radius: on ? 6 : 0)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.title).font(Theme.label(14))
                    Text(s.detail).font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Button { engine.toggleArmed() } label: {
                HStack(spacing: 6) {
                    Text(on ? "Turn off" : "Turn on")
                    Spacer(minLength: 0)
                    KeyCap(text: "fn")
                    KeyCap(text: "F1")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(NebulaButtonStyle(kind: on ? .quiet : .primary))
            .disabled(engine.arming == .practice)
        }
        .padding(14)
        .glass(radius: 14, glow: on ? Theme.contact : nil)
        .animation(.easeOut(duration: 0.2), value: on)
    }
}

private struct SidebarRow: View {
    let section: AppSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.contact : Theme.ink2)
                Text(section.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.violet.opacity(0.22), Theme.raised.opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.ink.opacity(0.08), lineWidth: 1))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
