import SwiftUI

/// Nebula's look. It's the Galaxy family's night sky: Comet's near-black for the ground,
/// Orbit's glow and spaced small capitals, Nova's serif headlines and hairline cards. What's
/// Nebula's own is the cloud of colour behind everything (violet into teal) and one colour,
/// the pale mint of contact: the live hand, the hold ring and "on". Nowhere else.
///
/// New York for headlines, SF Pro for reading, SF Mono for every number, so latency and
/// confidence line up like a gauge.
enum Theme {
    // Ground and surfaces
    static let ground = Color(red: 0.027, green: 0.031, blue: 0.055)      // #07080E
    static let surface = Color(red: 0.067, green: 0.075, blue: 0.110)     // #11131C
    static let raised = Color(red: 0.102, green: 0.114, blue: 0.161)      // #1A1D29
    static let line = Color(red: 0.145, green: 0.161, blue: 0.216)        // #252937
    static let lineStrong = Color(red: 0.204, green: 0.224, blue: 0.286)  // #343949

    // Type
    static let ink = Color(red: 0.933, green: 0.941, blue: 0.969)         // #EEF0F7
    static let ink2 = Color(red: 0.627, green: 0.651, blue: 0.722)        // #A0A6B8
    static let ink3 = Color(red: 0.416, green: 0.439, blue: 0.514)        // #6A7083

    /// Contact. Used for the live hand, the hold ring and "on", nowhere else.
    static let contact = Color(red: 0.561, green: 0.937, blue: 0.835)     // #8FEFD5
    /// Something went wrong, or missed its target.
    static let warn = Color(red: 0.961, green: 0.643, blue: 0.459)        // #F5A475

    // The cloud: only ever as light, behind things, never as text.
    static let violet = Color(red: 0.604, green: 0.482, blue: 1.0)        // #9A7BFF
    static let teal = Color(red: 0.310, green: 0.839, blue: 0.878)        // #4FD6E0
    static let rose = Color(red: 1.0, green: 0.561, blue: 0.722)          // #FF8FB8

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func label(_ size: CGFloat = 13.5, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func body(_ size: CGFloat = 13.5, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func numeral(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif).monospacedDigit()
    }

    static let radius: CGFloat = 16
}

// MARK: - The sky behind everything

/// Deep ground, a slow cloud of violet and teal, a few fixed stars, and Orbit's faint ruled grid
/// fading out from the top. Brighter while Nebula is on.
struct NebulaBackdrop: View, Equatable {
    var lit = false

    var body: some View {
        ZStack {
            Theme.ground
            RadialGradient(colors: [Theme.violet.opacity(lit ? 0.30 : 0.20), .clear], center: UnitPoint(x: 0.85, y: -0.05),
                           startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Theme.teal.opacity(lit ? 0.20 : 0.11), .clear], center: UnitPoint(x: 0.15, y: 1.05),
                           startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Theme.rose.opacity(0.07), .clear], center: UnitPoint(x: 0.55, y: 0.45),
                           startRadius: 0, endRadius: 420)
            StarField().opacity(0.9)
            GridLines()
                .mask(RadialGradient(colors: [.black, .clear], center: .top, startRadius: 0, endRadius: 520))
                .opacity(0.5)
        }
        .drawingGroup() // one flattened layer: drawn once, not re-composited with every change above it
        .animation(.easeInOut(duration: 0.8), value: lit)
        .allowsHitTesting(false)
    }
}

/// Fixed stars: the same sky every time, never moving, so nothing competes with the hand.
private struct StarField: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> Double {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Double(seed >> 11) / Double(1 << 53)
            }
            for _ in 0..<140 {
                let x = next() * size.width, y = next() * size.height
                let r = 0.4 + next() * 0.9
                let a = 0.15 + next() * 0.45
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(Theme.ink.opacity(a)))
            }
        }
    }
}

private struct GridLines: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 96
            var x: CGFloat = 0
            while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            context.stroke(path, with: .color(Theme.ink.opacity(0.05)), lineWidth: 1)
        }
    }
}

// MARK: - Structure

/// The top of every page: a ruled small-caps label, a serif headline and a line of context.
struct PageTitle<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(eyebrow, color: Theme.ink2)
                Text(title)
                    .font(Theme.display(36))
                    .tracking(-0.4)
                    .foregroundStyle(LinearGradient(colors: [Theme.ink, Theme.ink.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.body(13.5))
                        .foregroundStyle(Theme.ink2)
                        .lineSpacing(2)
                        .frame(maxWidth: 580, alignment: .leading)
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

/// Small spaced capitals after a short rule, above a group.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.ink3
    init(_ text: String, color: Color = Theme.ink3) {
        self.text = text
        self.color = color
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(color.opacity(0.7)).frame(width: 18, height: 1)
            Text(text.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(color)
        }
    }
}

/// A glass panel: a translucent surface over the sky, a hairline, and a faint light along its top edge.
struct Panel<Content: View>: View {
    var padding: CGFloat = 20
    var glow: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(glow: glow)
    }
}

struct Glass: ViewModifier {
    var radius: CGFloat = Theme.radius
    var glow: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                ZStack {
                    shape.fill(Theme.surface.opacity(0.78))
                    if let glow {
                        shape.fill(RadialGradient(colors: [glow.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 360))
                    }
                }
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [Theme.ink.opacity(0.13), Theme.line.opacity(0.6)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
    }
}

extension View {
    func glass(radius: CGFloat = Theme.radius, glow: Color? = nil) -> some View { modifier(Glass(radius: radius, glow: glow)) }
}

struct Divider1: View {
    var body: some View { Rectangle().fill(Theme.line.opacity(0.8)).frame(height: 1) }
}

/// Scrolling page with Nebula's margins.
struct Page<Content: View>: View {
    var maxWidth: CGFloat = 960
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) { content }
                .padding(.horizontal, 48)
                .padding(.top, 56)
                .padding(.bottom, 56)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

/// A short coloured label in a capsule: a gesture's state, a mode.
struct Pill: View {
    let text: String
    var color: Color = Theme.ink2
    var dot = true

    var body: some View {
        HStack(spacing: 6) {
            if dot {
                Circle().fill(color).frame(width: 6, height: 6)
                    .shadow(color: color.opacity(0.7), radius: 4)
            }
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(color)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 1))
    }
}

/// A key on a keyboard, for shortcuts.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.lineStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 0, x: 0, y: 1)
    }
}

/// A symbol in a softly lit tile: how a gesture or a setting shows what it is.
struct SymbolTile: View {
    let symbol: String
    var tint: Color = Theme.violet
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [Theme.ink, tint], startPoint: .top, endPoint: .bottom))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Controls

struct NebulaButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, warn }
    var kind: Kind = .quiet

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind)
    }

    private struct Styled: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(kind == .primary ? Theme.ground : (kind == .warn ? Theme.warn : Theme.ink))
                .padding(.horizontal, 15)
                .frame(height: 31)
                .background {
                    if kind == .primary {
                        Capsule().fill(LinearGradient(colors: [Theme.contact, Theme.teal.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: Theme.contact.opacity(hovering && enabled ? 0.45 : 0.2), radius: hovering ? 12 : 8)
                    } else {
                        Capsule().fill(hovering && enabled ? Theme.lineStrong.opacity(0.7) : Theme.raised.opacity(0.9))
                    }
                }
                .overlay(Capsule().strokeBorder(kind == .primary ? Color.white.opacity(0.25) : Theme.lineStrong, lineWidth: 1))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
        }
    }
}

struct NebulaField: ViewModifier {
    var mono = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(12.5) : Theme.body(13.5))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.ground.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.lineStrong, lineWidth: 1))
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
                Capsule().fill(isOn && enabled
                    ? AnyShapeStyle(LinearGradient(colors: [Theme.contact, Theme.teal], startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Theme.lineStrong))
                Circle().fill(isOn && enabled ? Theme.ground : Theme.ink2).padding(3)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
            .frame(width: 38, height: 22)
            .shadow(color: isOn && enabled ? Theme.contact.opacity(0.35) : .clear, radius: 6)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(isOn ? "On" : "Off")
    }
}

// MARK: - The mark and the ring

/// Nebula's mark: an open ring and, on it, a smaller filled disc set off-centre, like a
/// fingertip meeting a surface. Lit from within while Nebula is on.
struct NebulaGlyph: View {
    var armed = false

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let r = side / 2 - 1
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let ringShading: GraphicsContext.Shading = armed
                ? .color(Theme.contact)
                : .linearGradient(Gradient(colors: [Theme.violet, Theme.teal]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: size.height))
            context.stroke(ring, with: ringShading, lineWidth: max(1.2, side * 0.08))
            // The fingertip sits on the ring, top right: the moment of contact.
            let d = side * 0.34
            let at = CGPoint(x: c.x + r * 0.62, y: c.y - r * 0.62)
            let dot = CGRect(x: at.x - d / 2, y: at.y - d / 2, width: d, height: d)
            context.fill(Path(ellipseIn: dot), with: .color(armed ? Theme.contact : Theme.ink))
        }
        .shadow(color: armed ? Theme.contact.opacity(0.6) : Theme.violet.opacity(0.35), radius: armed ? 6 : 4)
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
                .shadow(color: Theme.contact.opacity(0.6), radius: 4)
        }
    }
}

enum Format {
    static func ms(_ value: Double) -> String { value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value) }
    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
}
