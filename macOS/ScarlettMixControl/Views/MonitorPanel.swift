import SwiftUI

struct MonitorPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let mon = model.doc.monitor
        let hw = model.experimental && mon.hardwareControl

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Monitor")
                Spacer()
                Menu {
                    ForEach(MonitorPreset.allCases) { p in
                        Button(p.rawValue) { p.apply(to: &model.doc) }
                    }
                } label: {
                    Label("Preset", systemImage: "hifispeaker.2")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }

            HStack(alignment: .center, spacing: 18) {
                outputGrid
                VStack(spacing: 6) {
                    LevelKnob(dB: $model.doc.monitor.levelDB, disabled: hw)
                    Text(mon.levelDB <= MixerDocument.monitorFloorDB ? "−∞ dB" : "\(Int(mon.levelDB)) dB")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(mon.dim ? Theme.solo : Theme.text)
                    if hw {
                        Text("FRONT PANEL")
                            .font(.system(size: 8, weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(Theme.control)
                    }
                }
                .frame(width: 104)
                VStack(spacing: 5) {
                    LitButton(title: "DIM", isOn: mon.dim, color: Theme.solo, width: 64, height: 24,
                              help: "Dim −18 dB") { model.doc.monitor.dim.toggle() }
                        .disabled(hw)
                    LitButton(title: "MUTE", isOn: mon.mute, color: Theme.mute, width: 64, height: 24,
                              help: "Mute all monitor-controlled outputs") { model.doc.monitor.mute.toggle() }
                        .disabled(hw)
                    HStack(spacing: 4) {
                        LitButton(title: "L", isOn: mon.muteLeft, color: Theme.mute, width: 30, height: 22,
                                  help: "Mute odd-numbered (left) outputs") { model.doc.monitor.muteLeft.toggle() }
                        LitButton(title: "R", isOn: mon.muteRight, color: Theme.mute, width: 30, height: 22,
                                  help: "Mute even-numbered (right) outputs") { model.doc.monitor.muteRight.toggle() }
                    }
                    LitButton(title: "−20 PAD", isOn: mon.pad, color: Theme.control, width: 64, height: 22,
                              help: "−20 dB on Monitor Outputs 1/2 (applied as output attenuation)") {
                        model.doc.monitor.pad.toggle()
                    }
                }
            }

            HStack(spacing: 6) {
                LitButton(title: "MONO", isOn: mon.mono, color: Theme.control, height: 22,
                          help: model.experimental ? "Sum each controlled output pair to mono (experimental)"
                                                   : "Needs experimental hardware features (Settings)") {
                    model.setMono(!mon.mono)
                }
                .disabled(!model.experimental)
                LitButton(title: "HW CONTROL", isOn: hw, color: Theme.control, height: 22,
                          help: model.experimental ? "Follow the front-panel VOLUME knob, DIM and MUTE (experimental)"
                                                   : "Needs experimental hardware features (Settings)") {
                    model.setHardwareControl(!mon.hardwareControl)
                }
                .disabled(!model.experimental)
            }
        }
        .padding(14)
        .panel()
    }

    /// Ten analog outputs: odd on top, even below. Click cycles controlled ↔
    /// muted; ⇧-click sets fixed (full level, not controlled).
    private var outputGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                ForEach(0..<2) { row in
                    GridRow {
                        ForEach(0..<5) { col in
                            MonitorOutputButton(index: col * 2 + row)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                legend(Theme.control, "Controlled")
                legend(Theme.mute, "Muted")
                legend(Theme.raised, "Fixed (⇧)")
            }
        }
        .fixedSize()
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.strokeStrong))
            Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiary)
        }
    }
}

private struct MonitorOutputButton: View {
    @Environment(AppModel.self) private var model
    let index: Int

    var body: some View {
        let mode = model.doc.monitor.modes[index]
        let color: Color = switch mode {
        case .controlled: Theme.control
        case .muted: Theme.mute
        case .fixed: Theme.raised
        }
        Button {
            let fixed = NSEvent.modifierFlags.contains(.shift)
            model.doc.monitor.modes[index] = fixed ? .fixed : (mode == .controlled ? .muted : .controlled)
        } label: {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(mode == .fixed ? Theme.secondary : .white)
                .frame(width: 30, height: 30)
                .background(color.opacity(mode == .fixed ? 1 : 0.85), in: .rect(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(mode == .fixed ? Theme.stroke : color))
                .shadow(color: mode == .fixed ? .clear : color.opacity(0.35), radius: 4)
        }
        .buttonStyle(.plain)
        .help(help(mode))
    }

    private func help(_ mode: MixerDocument.MonitorMode) -> String {
        let name = Outputs.label(index)
        switch mode {
        case .controlled: return "\(name): follows monitor level. Click to mute; ⇧-click for fixed level."
        case .muted: return "\(name): muted. Click to control; ⇧-click for fixed level."
        case .fixed: return "\(name): fixed at full level — not controlled. Click to control."
        }
    }
}
