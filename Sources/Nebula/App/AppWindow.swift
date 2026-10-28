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
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                switch navigation.section {
                case .gestures: GesturesView(engine: engine)
                case .create: CreateView(engine: engine)
                case .practice: PracticeView(engine: engine, recorder: engine.recorder)
                case .settings: SettingsView(engine: engine)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground)
        }
        .ignoresSafeArea()
        .foregroundStyle(Theme.ink)
        .tint(Theme.contact)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                NebulaGlyph(armed: engine.isArmed).frame(width: 18, height: 18)
                Text("Nebula").font(Theme.display(19))
            }
            .padding(.horizontal, 12)
            .padding(.top, 54)
            .padding(.bottom, 26)

            ForEach(AppSection.allCases) { section in
                SidebarRow(section: section, selected: navigation.section == section) { navigation.section = section }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Button { engine.toggleArmed() } label: {
                    HStack(spacing: 8) {
                        Circle().fill(engine.isArmed ? Theme.contact : Theme.lineStrong).frame(width: 7, height: 7)
                        Text(engine.isArmed ? "On" : "Off").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        Spacer()
                        Text("fn F1").font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                Text(engine.linkConnected ? "Galaxy Link connected" : "Galaxy Link not running")
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 4)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 12)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
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
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.contact : Theme.ink2)
                Text(section.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.raised : (hovering ? Theme.raised.opacity(0.5) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
