import AppKit
import AVFoundation
import NebulaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: Engine
    @State private var newKey = ""
    @State private var keySource = Keychain.source
    @State private var accessibility = Permissions.hasAccessibility
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Page {
            PageTitle(eyebrow: "Settings", title: "How Nebula behaves",
                      subtitle: "Nothing here changes what counts as a gesture. That comes from your recordings.")
            section("Turning on and off") {
                row("Auto-off", "Disarm after this long with no hand in view.") {
                    Picker("", selection: $engine.settings.autoOffMinutes) {
                        ForEach([1.0, 2, 5, 10, 20], id: \.self) { Text("\(Int($0)) min").tag($0) }
                    }.labelsHidden().frame(width: 110)
                }
                row("Approval mode", "When a Galaxy body waits on your yes or no, turn the camera on for 60 seconds.") {
                    NebulaToggle(isOn: $engine.settings.approvalMode)
                }
                row("Launch at login", "Start Nebula in the menu bar (the camera stays off).") {
                    NebulaToggle(isOn: Binding(get: { launchAtLogin }, set: { on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }))
                }
            }
            section("Trial mode") {
                row("Let unproven gestures act", "For trying Nebula before the full recording plan. Gestures act without having met the 99% target on your recordings, so expect some misses and false fires. The HUD says \"trial\" while it's on.") {
                    NebulaToggle(isOn: $engine.settings.trial)
                }
            }
            section("Feel") {
                row("Sensitivity", "Careful adds a tenth of a second to every hold. Standard uses the holds the tuning proved.") {
                    Picker("", selection: $engine.settings.careful) {
                        Text("Standard").tag(false)
                        Text("Careful").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                row("Natural scrolling", "Hand up moves the page up, like a trackpad.") { NebulaToggle(isOn: $engine.settings.naturalScroll) }
                row("Camera resolution", "640×480 at the highest frame rate is the default; 1280×720 is there to compare.") {
                    Picker("", selection: $engine.settings.highResolution) {
                        Text("640×480").tag(false)
                        Text("1280×720").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
            }
            reportSection
            section("Anthropic API key") {
                Text(keySource.map { "Using \($0). Only the Create screen uses it." } ?? "No key found. Nebula looks for Nova's key first.")
                    .font(Theme.body(13)).foregroundStyle(Theme.ink2)
                HStack(spacing: 10) {
                    SecureField("Set a key just for Nebula: sk-ant-…", text: $newKey).nebulaField(mono: true)
                    Button("Save") {
                        Keychain.saveNebulaKey(newKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        newKey = ""
                        keySource = Keychain.source
                    }.buttonStyle(NebulaButtonStyle(kind: .primary)).disabled(newKey.isEmpty)
                    if Keychain.source == "Nebula's own key" {
                        Button("Remove") { Keychain.deleteNebulaKey(); keySource = Keychain.source }.buttonStyle(NebulaButtonStyle(kind: .warn))
                    }
                }
            }
            section("Permissions") {
                permission("Camera", camera == .authorized, "Asked for the first time you turn Nebula on.") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                }
                permission("Accessibility", accessibility, "For keystrokes and scrolls to the window in front, and reading which window that is.") {
                    Permissions.openAccessibilitySettings()
                }
                Text("Automation (Safari, Chrome, Arc, Keynote, Spotify, Music) is asked for app by app, the first time each comes to the front.")
                    .font(Theme.body(12)).foregroundStyle(Theme.ink3)
            }
            section("Galaxy") {
                Text(engine.linkConnected ? "Connected to Galaxy Link as nebula." : "Galaxy Link isn't running. Gestures still work; approvals and Comet need it.")
                    .font(Theme.body(13)).foregroundStyle(Theme.ink2)
                if engine.linkConnected && !engine.approvalsSupported {
                    Text("This galaxyd has no approvals API yet. Apply galaxy-patch/ from the NebulaAI repo.").font(Theme.body(12.5)).foregroundStyle(Theme.warn)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibility = Permissions.hasAccessibility
            camera = AVCaptureDevice.authorizationStatus(for: .video)
            keySource = Keychain.source
        }
    }

    // MARK: - Report

    private var reportSection: some View {
        section("Accuracy and latency") {
            HStack(spacing: 10) {
                Button(engine.busy ?? "Train and report from my recordings") { engine.trainAndReport() }
                    .buttonStyle(NebulaButtonStyle(kind: .primary)).disabled(engine.busy != nil)
                Button("Show recordings") { NSWorkspace.shared.open(Paths.recordings) }.buttonStyle(NebulaButtonStyle())
            }
            let l = engine.latency
            Text(String(format: "Live: Nebula latency p50 %.2f · p95 %.2f · p99 %.2f ms (target p95 ≤ 10, p99 ≤ 15)  ·  recognizer p95 %.3f ms (≤ 2)",
                        l.actions.count > 0 ? l.actions.p50 : l.perFrame.p50, l.actions.count > 0 ? l.actions.p95 : l.perFrame.p95,
                        l.actions.count > 0 ? l.actions.p99 : l.perFrame.p99, l.recognizer.p95))
                .font(Theme.mono(11)).foregroundStyle(Theme.ink2)
            if let report = engine.report {
                ScrollView(.horizontal) {
                    Text(report.text())
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .padding(14)
                }
                .background(Theme.ground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
            } else {
                Text(engine.gate.summary.isEmpty ? "No report yet. Record sessions in Practice, then train." : engine.gate.summary)
                    .font(Theme.body(12.5)).foregroundStyle(Theme.ink3)
            }
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SymbolTile(symbol: Self.symbol(title), tint: Self.tint(title), size: 24)
                Text(title).font(Theme.display(17))
            }
            Panel { VStack(alignment: .leading, spacing: 18) { content() } }
        }
    }

    private static func symbol(_ section: String) -> String {
        switch section {
        case "Turning on and off": return "power"
        case "Trial mode": return "flask"
        case "Feel": return "hand.point.up.left"
        case "Accuracy and latency": return "gauge.with.dots.needle.67percent"
        case "Anthropic API key": return "key"
        case "Permissions": return "lock.shield"
        case "Galaxy": return "circle.hexagongrid"
        default: return "circle"
        }
    }

    private static func tint(_ section: String) -> Color {
        switch section {
        case "Turning on and off", "Accuracy and latency": return Theme.teal
        case "Trial mode", "Galaxy": return Theme.violet
        default: return Theme.rose
        }
    }

    private func row<Control: View>(_ title: String, _ detail: String, @ViewBuilder _ control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.label(13.5))
                Text(detail).font(Theme.body(12)).foregroundStyle(Theme.ink2.opacity(0.85)).lineSpacing(1.5)
                    .frame(maxWidth: 520, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            control()
        }
    }

    private func permission(_ name: String, _ granted: Bool, _ detail: String, open: @escaping () -> Void) -> some View {
        row(name, detail) {
            if granted {
                Pill(text: "Granted", color: Theme.contact)
            } else {
                Button("Open Settings", action: open).buttonStyle(NebulaButtonStyle())
            }
        }
    }
}
