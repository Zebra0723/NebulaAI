import AppKit
import SwiftUI

/// The small, quiet strip near the top of the screen: a ring filling while you hold
/// a pose, then what was controlled ("Next tab · Safari") for about a second. It never
/// takes focus or clicks, so it can't become the frontmost window it reports on.
final class HUD {
    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// Safe from any thread.
    func show(_ text: String, symbol: String, warn: Bool = false) {
        DispatchQueue.main.async {
            self.model.mode = .message(text: text, symbol: symbol, warn: warn)
            self.present(for: 1.1)
        }
    }

    /// The cue on the first frame of a hold: the ring fills over `seconds`.
    func showHold(title: String, seconds: Double) {
        DispatchQueue.main.async {
            self.model.mode = .hold(title: title, seconds: seconds, started: Date())
            self.present(for: seconds + 0.6)
        }
    }

    func cancelHold() {
        DispatchQueue.main.async {
            if case .hold = self.model.mode { self.hide() }
        }
    }

    private func present(for seconds: Double) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        return panel
    }

    /// Top centre of the screen you're working on (the one with the pointer).
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 14))
    }
}

final class HUDModel: ObservableObject {
    enum Mode {
        case idle
        case hold(title: String, seconds: Double, started: Date)
        case message(text: String, symbol: String, warn: Bool)
    }
    @Published var mode: Mode = .idle
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            content
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Theme.ground.opacity(0.94), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.lineStrong, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .frame(width: 420, height: 56)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .idle:
            EmptyView()
        case .hold(let title, let seconds, let started):
            HStack(spacing: 10) {
                TimelineView(.animation) { timeline in
                    HoldRing(progress: timeline.date.timeIntervalSince(started) / max(seconds, 0.01), lineWidth: 2.5)
                        .frame(width: 16, height: 16)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
            }
        case .message(let text, let symbol, let warn):
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(warn ? Theme.warn : Theme.contact)
                Text(text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
        }
    }
}
