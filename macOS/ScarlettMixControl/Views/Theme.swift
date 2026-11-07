import SwiftUI

/// Visual language: a dark graphite console. Colour is reserved for meaning —
/// each mix has its own accent, state buttons use MixControl's conventions
/// (mute red, solo yellow, PFL green, dim yellow, monitor-controlled blue).
enum Theme {
    static let window = Color(red: 0.070, green: 0.074, blue: 0.086)
    static let panel = Color(red: 0.105, green: 0.111, blue: 0.128)
    static let raised = Color(red: 0.150, green: 0.158, blue: 0.180)
    static let well = Color(red: 0.052, green: 0.055, blue: 0.064)
    static let stroke = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.14)

    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.56)
    static let tertiary = Color.white.opacity(0.34)

    static let mute = Color(red: 1.00, green: 0.30, blue: 0.27)
    static let solo = Color(red: 1.00, green: 0.80, blue: 0.10)
    static let pfl = Color(red: 0.25, green: 0.84, blue: 0.42)
    static let control = Color(red: 0.26, green: 0.56, blue: 1.00)
    static let meterGreen = Color(red: 0.24, green: 0.86, blue: 0.47)
    static let meterYellow = Color(red: 1.00, green: 0.80, blue: 0.16)
    static let meterRed = Color(red: 1.00, green: 0.27, blue: 0.23)

    /// One accent per mix bus.
    static let mixAccents: [Color] = [
        Color(red: 0.20, green: 0.80, blue: 0.78),  // teal
        Color(red: 0.35, green: 0.60, blue: 1.00),  // blue
        Color(red: 0.62, green: 0.48, blue: 1.00),  // violet
        Color(red: 1.00, green: 0.42, blue: 0.66),  // pink
        Color(red: 1.00, green: 0.58, blue: 0.24),  // orange
        Color(red: 0.95, green: 0.82, blue: 0.30),  // gold
        Color(red: 0.58, green: 0.86, blue: 0.34),  // lime
        Color(red: 0.40, green: 0.82, blue: 1.00),  // sky
    ]

    static func accent(mixBus bus: Int) -> Color { mixAccents[bus % mixAccents.count] }

    /// Source colour: inputs warm, DAW cool, mixes use their accent.
    static func color(forSource id: Int) -> Color {
        switch SourceKind(id: id) {
        case .off: tertiary
        case .analog, .spdif, .adat: Color(red: 1.00, green: 0.66, blue: 0.36)
        case .daw: Color(red: 0.52, green: 0.72, blue: 1.00)
        case .mix(let b): accent(mixBus: b)
        }
    }

    static let mono = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let label = Font.system(size: 10, weight: .semibold)
    static let caption = Font.system(size: 9, weight: .semibold).width(.condensed)
}

struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke))
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}

/// Small uppercase section heading.
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Theme.secondary)
    }
}
