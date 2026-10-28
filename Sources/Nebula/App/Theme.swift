import SwiftUI

/// Nebula's look: a deep blue-black ground, quiet slate surfaces, soft white type,
/// and one colour, the pale mint of contact: the hold ring, the live hand, "armed".
/// SF Pro Rounded for headlines (it's the body that touches), SF Pro for reading,
/// SF Mono for every number, so latency and confidence line up like a gauge.
enum Theme {
    // Ground and surfaces
    static let ground = Color(red: 0.047, green: 0.055, blue: 0.075)      // #0C0E13
    static let surface = Color(red: 0.075, green: 0.086, blue: 0.110)     // #13161C
    static let raised = Color(red: 0.102, green: 0.114, blue: 0.145)      // #1A1D25
    static let line = Color(red: 0.149, green: 0.165, blue: 0.204)        // #262A34
    static let lineStrong = Color(red: 0.204, green: 0.224, blue: 0.271)  // #343945

    // Type
    static let ink = Color(red: 0.925, green: 0.937, blue: 0.957)         // #ECEFF4
    static let ink2 = Color(red: 0.588, green: 0.620, blue: 0.682)        // #969EAE
    static let ink3 = Color(red: 0.384, green: 0.408, blue: 0.459)        // #626875

    /// Contact. Used for the live hand, the hold ring and "armed", nowhere else.
    static let contact = Color(red: 0.561, green: 0.937, blue: 0.835)     // #8FEFD5
    /// Something went wrong, or missed its target.
    static let warn = Color(red: 0.961, green: 0.643, blue: 0.459)        // #F5A475

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func body(_ size: CGFloat = 13.5, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func numeral(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

// MARK: - Structure

/// The top of every page: a small label, a rounded headline and a line under it.
struct PageTitle<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(eyebrow)
                Text(title)
                    .font(Theme.display(34))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.body(13.5))
                        .foregroundStyle(Theme.ink2)
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension PageTitle where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Small spaced capitals above a group.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.ink3
    init(_ text: String, color: Color = Theme.ink3) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(color)
    }
}

/// A rounded panel on the ground.
struct Panel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

struct Divider1: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

/// Scrolling page with Nebula's margins.
struct Page<Content: View>: View {
    var maxWidth: CGFloat = 920
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) { content }
                .padding(.horizontal, 48)
                .padding(.top, 52)
                .padding(.bottom, 48)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Controls

struct NebulaButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, warn }
    var kind: Kind = .quiet

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(kind == .primary ? Theme.ground : (kind == .warn ? Theme.warn : Theme.ink))
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(kind == .primary ? Theme.contact : Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(kind == .primary ? Color.clear : Theme.lineStrong, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

struct NebulaField: ViewModifier {
    var mono = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(12.5) : Theme.body(13.5))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

extension View {
    func nebulaField(mono: Bool = false) -> some View { modifier(NebulaField(mono: mono)) }
}

/// A switch in the app's colours.
struct NebulaToggle: View {
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        Button { if enabled { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn && enabled ? Theme.contact : Theme.lineStrong)
                Circle().fill(isOn && enabled ? Theme.ground : Theme.ink2).padding(3)
            }
            .frame(width: 36, height: 21)
            .animation(.easeOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(isOn ? "On" : "Off")
    }
}

// MARK: - The mark and the ring

/// Nebula's mark: an open ring and, inside it, a smaller filled disc set off-centre,
/// like a fingertip meeting a surface.
struct NebulaGlyph: View {
    var armed = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let r = side / 2 - 1
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            context.stroke(ring, with: .color(armed ? Theme.contact : Theme.ink2), lineWidth: max(1.2, side * 0.08))
            // The fingertip sits on the ring, top right: the moment of contact.
            let d = side * 0.34
            let at = CGPoint(x: c.x + r * 0.62, y: c.y - r * 0.62)
            let dot = CGRect(x: at.x - d / 2, y: at.y - d / 2, width: d, height: d)
            context.fill(Path(ellipseIn: dot), with: .color(armed ? Theme.contact : Theme.ink))
        }
    }
}

/// The hold ring: fills as a held gesture approaches its fire.
struct HoldRing: View {
    var progress: Double
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(Theme.contact, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

enum Format {
    static func ms(_ value: Double) -> String { value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value) }
    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}
