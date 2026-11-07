import SwiftUI

struct DevicePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Device")

            VStack(alignment: .leading, spacing: 2) {
                Text("Scarlett 18i20")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                Text("1st Gen · USB 2.0")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }

            StatusRow(title: "USB", value: model.status.label, color: statusColor)
            Menu {
                ForEach(model.availableRates.isEmpty ? DeviceMap.sampleRates : model.availableRates, id: \.self) { rate in
                    Button {
                        model.setSampleRate(rate)
                    } label: {
                        if rate == model.sampleRate {
                            Label(rateLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(rateLabel(rate))
                        }
                    }
                }
                Divider()
                Button("Open Audio MIDI Setup…") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
                }
            } label: {
                StatusRow(title: "Sample Rate",
                          value: model.sampleRate.map { rateLabel($0) } ?? "—",
                          color: Theme.text) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(model.sampleRate == nil)
            .help("Sets the 18i20's rate in macOS (same as Audio MIDI Setup). Quit your DAW first. With S/PDIF or ADAT sync, match the source's rate.")

            if let reported = model.deviceReportedRate, let rate = model.sampleRate, reported != rate {
                Button {
                    model.setSampleRate(reported)
                } label: {
                    Text("Device clock reports \(rateLabel(reported)) — match it")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.solo)
                }
                .buttonStyle(.plain)
                .help("The mixer protocol reports a different rate than macOS is streaming at")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Sync Source")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                Picker("Sync Source", selection: $model.doc.clock) {
                    ForEach(DeviceMap.Clock.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            deviceButton
        }
        .padding(14)
        .frame(width: 200)
        .panel()
    }

    private var statusColor: Color {
        switch model.status {
        case .connected: Theme.meterGreen
        case .busy: Theme.solo
        case .released: Theme.control
        default: Theme.mute
        }
    }

    @ViewBuilder
    private var deviceButton: some View {
        if model.status == .released {
            Button("Reconnect") { model.reconnectDevice() }
                .controlSize(.small)
                .help("Take the device back from the command-line tool")
        } else {
            Button("Release for CLI") { model.releaseDevice() }
                .controlSize(.small)
                .disabled(model.status != .connected)
                .help("Close the USB handle so scarlett_ctl / bb scarlett can use the device")
        }
    }

    private func rateLabel(_ hz: Int) -> String {
        hz % 1000 == 0 ? "\(hz / 1000) kHz" : String(format: "%.1f kHz", Double(hz) / 1000)
    }
}

private struct StatusRow<Accessory: View>: View {
    let title: String
    let value: String
    let color: Color
    @ViewBuilder var accessory: Accessory

    init(title: String, value: String, color: Color, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.value = value
        self.color = color
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            accessory
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Theme.well, in: .rect(cornerRadius: 7))
    }
}
