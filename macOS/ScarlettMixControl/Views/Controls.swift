import SwiftUI

// MARK: - Fader

/// Vertical fader. Drag to move (hold ⌥ for fine control), double-click
/// the cap for 0 dB — as in MixControl.
struct Fader: View {
    @Binding var dB: Double?
    var accent: Color
    var maxDB: Double = Gain.faderMaxDB

    @State private var dragStart: Double?

    private let capHeight: CGFloat = 30
    private let marks: [Double] = [6, 0, -10, -20, -40, -60]

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.height - capHeight
            let pos = FaderTaper.position(for: dB)
            let y = (1 - pos) * travel

            ZStack(alignment: .top) {
                // Scale
                ForEach(marks.filter { $0 <= maxDB }, id: \.self) { mark in
                    let my = (1 - FaderTaper.position(for: mark)) * travel + capHeight / 2
                    HStack(spacing: 0) {
                        Rectangle().fill(mark == 0 ? Theme.secondary : Theme.tertiary)
                            .frame(width: mark == 0 ? 9 : 5, height: 1)
                        Spacer()
                        Rectangle().fill(mark == 0 ? Theme.secondary : Theme.tertiary)
                            .frame(width: mark == 0 ? 9 : 5, height: 1)
                    }
                    .offset(y: my)
                }
                // Track and fill
                Capsule().fill(Theme.well)
                    .frame(width: 4)
                    .padding(.vertical, capHeight / 2)
                Capsule().fill(accent.opacity(0.55))
                    .frame(width: 4, height: max(0, travel - y))
                    .offset(y: y + capHeight / 2)
                // Cap
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.22)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(accent).frame(height: 2))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.18)))
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
                    .frame(width: 26, height: capHeight)
                    .offset(y: y)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let start = dragStart ?? pos
                        if dragStart == nil { dragStart = pos }
                        let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1.0
                        let p = start - Double(g.translation.height / max(travel, 1)) * fine
                        let v = FaderTaper.dB(at: p).map { min($0, maxDB) }
                        dB = v.map { ($0 * 10).rounded() / 10 }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { dB = 0 })
        }
        .frame(width: 34)
        .accessibilityElement()
        .accessibilityLabel("Fader")
        .accessibilityValue(Gain.format(dB) + " dB")
        .accessibilityAdjustableAction { dir in
            let cur = dB ?? -60
            dB = min(maxDB, cur + (dir == .increment ? 1 : -1))
        }
    }
}

// MARK: - Meter

/// Bargraph meter, dBFS −60…0 with green/yellow/red zones, a peak tick, and
/// a latching clip cap. Click to reset peak and clip.
struct Meter: View {
    var levels: [Float]
    var peaks: [Float]
    var clipped: Bool
    var active: Bool
    var onReset: () -> Void

    static let floorDB: Double = -60
    /// dBFS marks drawn beside the bars, labelled without the minus sign.
    static let marks: [Double] = [0, -6, -12, -18, -24, -36, -48, -60]

    static func fraction(_ linear: Float) -> CGFloat {
        guard linear > 0 else { return 0 }
        return fraction(dB: 20 * log10(Double(linear)))
    }

    static func fraction(dB: Double) -> CGFloat {
        CGFloat(max(0, min(1, (dB - floorDB) / -floorDB)))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1) {
            VStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(clipped ? Theme.meterRed : Theme.well)
                    .frame(height: 5)
                HStack(spacing: 2) {
                    ForEach(levels.indices, id: \.self) { i in
                        bar(levels[i], peak: peaks[safe: i] ?? 0)
                    }
                }
            }
            .frame(width: CGFloat(levels.count) * 7 - 2)
            scale
        }
        .opacity(active ? 1 : 0.45)
        .contentShape(Rectangle())
        .onTapGesture(perform: onReset)
        .help(active ? "Level in dBFS — click to reset peak and clip" : "Meters need experimental hardware features (Settings)")
    }

    private func bar(_ level: Float, peak: Float) -> some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Theme.well))
            let f = Self.fraction(level)
            if f > 0 {
                let h = size.height * f
                let fill = CGRect(x: 0, y: size.height - h, width: size.width, height: h)
                ctx.fill(Path(roundedRect: fill, cornerRadius: 2),
                         with: .linearGradient(
                            Gradient(stops: [
                                .init(color: Theme.meterGreen, location: 0),
                                .init(color: Theme.meterGreen, location: 0.62),
                                .init(color: Theme.meterYellow, location: 0.86),
                                .init(color: Theme.meterRed, location: 1),
                            ]),
                            startPoint: CGPoint(x: 0, y: size.height), endPoint: .zero))
            }
            let p = Self.fraction(peak)
            if p > 0 {
                let py = size.height * (1 - p)
                ctx.fill(Path(CGRect(x: 0, y: py, width: size.width, height: 1.5)), with: .color(.white.opacity(0.8)))
            }
        }
        .frame(width: 5)
    }

    /// Sits under the clip light so its marks line up with the bars.
    private var scale: some View {
        Canvas { ctx, size in
            var lastY = -CGFloat.infinity
            for mark in Self.marks {
                let y = size.height * (1 - Self.fraction(dB: mark))
                // Thin out labels on short strips rather than overlap them;
                // 0 and the floor always show.
                let ends = mark == 0 || mark == Self.floorDB
                guard ends || (y - lastY >= 9 && size.height - y >= 9) else { continue }
                lastY = y
                ctx.fill(Path(CGRect(x: 0, y: y - 0.5, width: 2, height: 1)),
                         with: .color(mark == 0 ? Theme.secondary : Theme.tertiary))
                let label = Text(mark == 0 ? "0" : "\(Int(-mark))")
                    .font(.system(size: 7, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(mark == 0 ? Theme.secondary : Theme.tertiary)
                let ly = min(max(y, 4), size.height - 4)
                ctx.draw(label, at: CGPoint(x: 3, y: ly), anchor: .leading)
            }
        }
        .frame(width: 12)
        .padding(.top, 7)
        .accessibilityHidden(true)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - Pan

/// Horizontal pan/balance slider, −1…+1. Double-click to centre.
struct PanSlider: View {
    @Binding var value: Double
    var accent: Color
    @State private var start: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = (value + 1) / 2 * w
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.well).frame(height: 4)
                Rectangle().fill(Theme.tertiary).frame(width: 1, height: 8).offset(x: w / 2)
                Capsule().fill(accent.opacity(0.7))
                    .frame(width: abs(x - w / 2), height: 4)
                    .offset(x: min(x, w / 2))
                Circle().fill(Color(white: 0.85))
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .offset(x: x - 5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let s = start ?? value
                    if start == nil { start = value }
                    let v = s + Double(g.translation.width / max(w, 1)) * 2
                    value = (max(-1, min(1, v)) * 100).rounded() / 100
                }
                .onEnded { _ in start = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("Pan")
        .accessibilityValue(PanSlider.label(value))
    }

    static func label(_ v: Double) -> String {
        let n = Int((abs(v) * 100).rounded())
        return n == 0 ? "C" : (v < 0 ? "L\(n)" : "R\(n)")
    }
}

// MARK: - Knob

/// Large rotary level knob with a value arc (monitor level, −127…0 dB).
struct LevelKnob: View {
    @Binding var dB: Double
    var disabled: Bool
    var range: ClosedRange<Double> = -127...0
    @State private var start: Double?

    private static let sweep = 270.0

    /// Knob uses the fader taper's shape so the top of travel is fine-grained.
    private var fraction: Double {
        let lo = FaderTaper.position(for: range.lowerBound), hi = FaderTaper.position(for: range.upperBound)
        return (FaderTaper.position(for: dB) - lo) / (hi - lo)
    }

    private func dB(forFraction f: Double) -> Double {
        let lo = FaderTaper.position(for: range.lowerBound), hi = FaderTaper.position(for: range.upperBound)
        let p = lo + max(0, min(1, f)) * (hi - lo)
        return max(range.lowerBound, min(range.upperBound, FaderTaper.dB(at: p) ?? range.lowerBound))
    }

    var body: some View {
        let angle = -Self.sweep / 2 + fraction * Self.sweep
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweep / 360)
                .stroke(Theme.well, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(90 + (360 - Self.sweep) / 2))
            Circle()
                .trim(from: 0, to: fraction * Self.sweep / 360)
                .stroke(AngularGradient(colors: [Theme.control, Color(red: 0.3, green: 0.9, blue: 0.7)],
                                        center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(Self.sweep)),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(90 + (360 - Self.sweep) / 2))
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.34), Color(white: 0.16)], center: .init(x: 0.4, y: 0.3), startRadius: 2, endRadius: 50))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.6), radius: 6, y: 4)
                .padding(12)
            Capsule().fill(Color.white.opacity(0.9))
                .frame(width: 3, height: 13)
                .offset(y: -24)
                .rotationEffect(.degrees(angle))
        }
        .frame(width: 92, height: 92)
        .opacity(disabled ? 0.55 : 1)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                guard !disabled else { return }
                let s = start ?? fraction
                if start == nil { start = fraction }
                let fine = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1.0
                dB = (self.dB(forFraction: s - Double(g.translation.height) / 220 * fine)).rounded()
            }
            .onEnded { _ in start = nil })
        .accessibilityElement()
        .accessibilityLabel("Monitor level")
        .accessibilityValue("\(Int(dB)) dB")
        .accessibilityAdjustableAction { dir in
            guard !disabled else { return }
            dB = max(range.lowerBound, min(range.upperBound, dB + (dir == .increment ? 1 : -1)))
        }
    }
}

// MARK: - Buttons

/// Compact lit toggle (M / S / PFL / Dim …).
struct LitButton: View {
    let title: String
    var isOn: Bool
    var color: Color
    var width: CGFloat? = nil
    var height: CGFloat = 20
    var help: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Theme.secondary)
                .frame(maxWidth: width == nil ? .infinity : width, minHeight: height, maxHeight: height)
                .background(isOn ? color : Theme.raised, in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isOn ? color.opacity(0.9) : Theme.stroke))
                .shadow(color: isOn ? color.opacity(0.45) : .clear, radius: 5)
        }
        .buttonStyle(.plain)
        .help(help ?? title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Pill that opens a menu, used for source selection.
struct PillLabel: View {
    let text: String
    var color: Color
    var dimmed = false
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            Circle().fill(color).frame(width: compact ? 4 : 5, height: compact ? 4 : 5)
            Text(text)
                .font(.system(size: compact ? 9.5 : 10, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if !compact {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .foregroundStyle(dimmed ? Theme.tertiary : Theme.text)
        .padding(.horizontal, compact ? 4 : 7)
        .frame(height: 22)
        .background(Theme.raised, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.stroke))
    }
}
