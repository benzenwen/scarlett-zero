import SwiftUI

struct MixerPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let slot = model.doc.slot(containing: model.selectedMixBus)
        VStack(alignment: .leading, spacing: 10) {
            MixTabs()
            HStack(alignment: .top, spacing: 10) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(model.doc.strips) { strip in
                            ChannelStripView(strip: strip, slot: slot)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.visible)
                Rectangle().fill(Theme.stroke).frame(width: 1)
                MixOutputStrip(slot: slot)
            }
        }
        .padding(12)
        .panel()
    }
}

// MARK: - Tabs

struct MixTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            SectionTitle(text: "Mixer")
                .padding(.trailing, 6)
            ForEach(model.doc.mixSlots) { slot in
                let selected = slot.buses.contains(model.selectedMixBus)
                let accent = Theme.accent(mixBus: slot.bus)
                Button {
                    model.selectedMixBus = slot.bus
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(accent).frame(width: 7, height: 7)
                        Text(model.doc.mixName(slot))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        if slot.stereo {
                            Text("ST")
                                .font(.system(size: 8, weight: .heavy))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Theme.well, in: .rect(cornerRadius: 3))
                                .foregroundStyle(Theme.secondary)
                        }
                        if model.doc.mixes[slot.bus].mute {
                            Image(systemName: "speaker.slash.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.mute)
                        }
                    }
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .padding(.horizontal, 10)
                    .frame(minWidth: slot.stereo ? 120 : 76, minHeight: 26)
                    .background(selected ? accent.opacity(0.18) : Theme.raised, in: .capsule)
                    .overlay(Capsule().strokeBorder(selected ? accent.opacity(0.7) : Theme.stroke))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if slot.bus % 2 == 0 {
                        Button(slot.stereo ? "Split into Mono Mixes \(slot.bus + 1) and \(slot.bus + 2)"
                                           : "Pair Mix \(slot.bus + 1) + Mix \(slot.bus + 2) as Stereo") {
                            toggleStereo(slot.bus)
                        }
                    }
                }
                // Link between each odd/even pair of tabs, like the channel strips.
                if slot.bus % 2 == 0 {
                    MixLinkButton(bus: slot.bus, linked: slot.stereo, accent: accent) { toggleStereo(slot.bus) }
                }
            }
            Spacer()
            if !model.experimental {
                SettingsLink {
                    Label("Meters off", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
                .help("Level meters use an unverified USB command. Enable experimental hardware features in Settings to try them.")
                .padding(.trailing, 8)
            }
            ConnectionBadge()
        }
    }
}

/// Device status at the top right of the mixer: connection, rate, clock.
struct ConnectionBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.9), radius: 3)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            if model.experimental {
                Text("EXP")
                    .font(.system(size: 8, weight: .heavy))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.solo.opacity(0.18), in: .rect(cornerRadius: 3))
                    .foregroundStyle(Theme.solo)
                    .help("Experimental hardware features are on")
            }
        }
    }

    private var color: Color {
        switch model.status {
        case .connected: Theme.meterGreen
        case .busy: Theme.solo
        case .released: Theme.control
        default: Theme.mute
        }
    }

    private var text: String {
        guard model.status == .connected else { return "18i20 · \(model.status.label)" }
        let rate = model.sampleRate.map { String(format: "%g kHz", Double($0) / 1000) } ?? ""
        return "18i20 · \(rate) · \(model.doc.clock.label)"
    }
}

extension MixTabs {
    private func toggleStereo(_ bus: Int) {
        let pair = bus / 2
        model.doc.setStereo(!model.doc.stereoMixPairs[pair], mixPair: pair)
        model.selectedMixBus = bus
    }
}

/// Chain toggle between Mix n and Mix n+1: pairs them into one stereo mix.
private struct MixLinkButton: View {
    let bus: Int
    let linked: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(linked ? accent : Theme.tertiary)
                .frame(width: 22, height: 22)
                .background(linked ? accent.opacity(0.18) : .clear, in: .circle)
                .overlay(Circle().strokeBorder(linked ? accent.opacity(0.5) : Theme.stroke))
                // Plain buttons only hit-test drawn pixels; without this the
                // unlinked state is clickable only on the glyph and ring.
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(linked ? "Split back into mono Mix \(bus + 1) and Mix \(bus + 2)"
                     : "Pair Mix \(bus + 1) and Mix \(bus + 2) as one stereo mix (enables pan)")
        .accessibilityLabel(linked ? "Unlink Mix \(bus + 1) and \(bus + 2)" : "Link Mix \(bus + 1) and \(bus + 2) as stereo")
    }
}

// MARK: - Channel strip

struct ChannelStripView: View {
    @Environment(AppModel.self) private var model
    let strip: MixerDocument.Strip
    let slot: MixerDocument.MixSlot

    private var accent: Color { Theme.accent(mixBus: slot.bus) }
    private var settings: Binding<MixerDocument.ChannelSettings> {
        Binding(get: { model.doc.mixes[slot.bus].channels[strip.channel] },
                set: { model.doc.mixes[slot.bus].channels[strip.channel] = $0 })
    }

    var body: some View {
        @Bindable var model = model
        let ch = settings.wrappedValue
        let listening = model.listen == .strip(strip.channel)

        VStack(spacing: 7) {
            header
            // Source(s)
            HStack(spacing: 3) {
                ForEach(strip.channels, id: \.self) { c in
                    SourceMenu(current: model.doc.inputs[c].source, compact: true, channel: c) { id in
                        model.doc.inputs[c].source = id
                    }
                }
            }
            // Pan / balance
            VStack(spacing: 2) {
                PanSlider(value: settings.pan, accent: accent)
                    .disabled(!slot.stereo)
                    .opacity(slot.stereo ? 1 : 0.35)
                Text(slot.stereo ? PanSlider.label(ch.pan) : "—")
                    .font(Theme.mono)
                    .foregroundStyle(Theme.tertiary)
            }
            .help(slot.stereo ? (strip.linked ? "Balance" : "Pan")
                  : "Pan works in stereo mixes — click the link between the Mix \(slot.bus / 2 * 2 + 1) and Mix \(slot.bus / 2 * 2 + 2) tabs to pair them")
            // Fader + meter
            HStack(alignment: .bottom, spacing: 2) {
                Fader(dB: settings.gainDB, accent: accent)
                meter
            }
            .frame(maxHeight: .infinity)
            Text(Gain.format(ch.gainDB))
                .font(Theme.mono)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(Theme.well, in: .rect(cornerRadius: 4))
            // M / S / PFL
            HStack(spacing: 3) {
                LitButton(title: "M", isOn: ch.mute, color: Theme.mute, help: "Mute") {
                    settings.wrappedValue.mute.toggle()
                }
                LitButton(title: "S", isOn: ch.solo, color: Theme.solo, help: "Solo in this mix") {
                    settings.wrappedValue.solo.toggle()
                }
            }
            LitButton(title: "PFL", isOn: listening, color: Theme.pfl,
                      help: "Pre-fade listen on Monitor Outputs 1/2") {
                model.listen = listening ? nil : .strip(strip.channel)
            }
            TextField(model.doc.stripName(strip), text: $model.doc.inputs[strip.channel].name)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text)
                .padding(.vertical, 3)
                .background(Theme.well, in: .rect(cornerRadius: 4))
        }
        .padding(5)
        .frame(width: strip.linked ? 118 : 64)
        .background(Theme.raised.opacity(0.55), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(listening ? Theme.pfl.opacity(0.7) : Theme.stroke))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(strip.linked ? "\(strip.channel + 1)–\(strip.channel + 2)" : "\(strip.channel + 1)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
            if strip.channel % 2 == 0 {
                Button {
                    model.doc.setLinked(!strip.linked, pair: strip.channel / 2)
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(strip.linked ? accent : Theme.tertiary)
                        .frame(width: 20, height: 16)
                        .background(strip.linked ? accent.opacity(0.18) : .clear, in: .rect(cornerRadius: 4))
                        .contentShape(.rect(cornerRadius: 4))   // whole button, not just the glyph
                }
                .buttonStyle(.plain)
                .help(strip.linked ? "Unlink stereo pair" : "Link \(strip.channel + 1) and \(strip.channel + 2) as a stereo pair")
            }
        }
    }

    private var meter: some View {
        let keys = strip.channels.map { MeterStore.key(forSource: model.doc.inputs[$0].source) }
        return Meter(levels: keys.map { model.meters.level($0) },
                     peaks: keys.map { model.meters.peak($0) },
                     clipped: keys.contains { model.meters.clipped($0) },
                     active: model.meters.active) {
            model.meters.resetPeak(keys.compactMap { $0 })
        }
    }
}

// MARK: - Mix output strip

struct MixOutputStrip: View {
    @Environment(AppModel.self) private var model
    let slot: MixerDocument.MixSlot

    private var accent: Color { Theme.accent(mixBus: slot.bus) }
    private var mix: Binding<MixerDocument.Mix> {
        Binding(get: { model.doc.mixes[slot.bus] }, set: { model.doc.mixes[slot.bus] = $0 })
    }
    /// Automatic names ("Mix 1", "Mix 1+2") show as the placeholder so they
    /// follow the stereo link; typing one back in clears the custom name.
    private var customName: Binding<String> {
        Binding(get: {
            let name = model.doc.mixes[slot.bus].name
            return MixerDocument.isAutomaticMixName(name) ? "" : name
        }, set: {
            model.doc.mixes[slot.bus].name = MixerDocument.isAutomaticMixName($0) ? "" : $0
        })
    }

    var body: some View {
        @Bindable var model = model
        let m = mix.wrappedValue
        let listening = model.listen == .mix(slot.bus)
        let keys = slot.buses.map { MeterStore.mixKey($0) }

        VStack(spacing: 7) {
            HStack {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text("OUTPUT")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Theme.secondary)
                Spacer()
            }
            // Destinations
            HStack(spacing: 3) {
                ForEach(slot.buses, id: \.self) { bus in
                    DestinationMenu(bus: bus, side: slot.stereo ? (bus == slot.bus ? "L" : "R") : nil)
                }
            }
            HStack(spacing: 3) {
                copyMenu
                LitButton(title: "Stereo", isOn: slot.stereo, color: accent, help: slot.bus % 2 == 0
                          ? "Pair Mix \(slot.bus + 1) and Mix \(slot.bus + 2) as one stereo mix"
                          : "Only odd-numbered mixes can become stereo") {
                    model.doc.setStereo(!slot.stereo, mixPair: slot.bus / 2)
                    model.selectedMixBus = slot.bus
                }
                .disabled(slot.bus % 2 != 0)
            }
            HStack(alignment: .bottom, spacing: 6) {
                Fader(dB: mix.gainDB, accent: accent)
                Meter(levels: keys.map { model.meters.level($0) },
                      peaks: keys.map { model.meters.peak($0) },
                      clipped: keys.contains { model.meters.clipped($0) },
                      active: model.meters.active) { model.meters.resetPeak(keys) }
            }
            .frame(maxHeight: .infinity)
            Text(Gain.format(m.gainDB))
                .font(Theme.mono)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                .background(Theme.well, in: .rect(cornerRadius: 4))
            HStack(spacing: 3) {
                LitButton(title: "M", isOn: m.mute, color: Theme.mute, help: "Mute this mix") {
                    mix.wrappedValue.mute.toggle()
                }
                LitButton(title: "PFL", isOn: listening, color: Theme.pfl,
                          help: "Listen to this mix on Monitor Outputs 1/2") {
                    model.listen = listening ? nil : .mix(slot.bus)
                }
            }
            TextField(model.doc.defaultMixName(slot), text: customName)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(accent)
                .padding(.vertical, 4)
                .background(Theme.well, in: .rect(cornerRadius: 5))
        }
        .padding(8)
        .frame(width: 150)
        .background(accent.opacity(0.07), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(listening ? 0.9 : 0.35)))
    }

    private var copyMenu: some View {
        let targets = model.doc.mixSlots.filter { $0.stereo == slot.stereo && $0.bus != slot.bus }
        return Menu {
            if targets.isEmpty {
                Text(slot.stereo ? "No other stereo mixes" : "No other mono mixes")
            }
            ForEach(targets) { t in
                Button(model.doc.mixName(t)) { model.doc.copyMix(from: slot.bus, to: t.bus) }
            }
        } label: {
            Text("Copy To…")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, minHeight: 20)
                .background(Theme.raised, in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.stroke))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Copy faders, pans, mutes and solos to another mix")
    }
}

/// Multi-select of outputs fed by one mix bus. Shows the output's name, or
/// "Many…" when several are selected — as MixControl did.
struct DestinationMenu: View {
    @Environment(AppModel.self) private var model
    let bus: Int
    let side: String?

    var body: some View {
        let dests = model.doc.destinations(ofBus: bus)
        let many = side == nil ? "\(dests.count) outputs" : "\(dests.count) outs"
        let text = dests.isEmpty ? "None" : dests.count == 1 ? Outputs.shortLabel(dests[0]) : many
        Menu {
            Section(side.map { "Mix \(bus + 1) (\($0)) → " } ?? "Mix \(bus + 1) →") {
                ForEach(0..<DeviceMap.outputCount, id: \.self) { o in
                    let on = dests.contains(o)
                    Toggle(isOn: Binding(
                        get: { on },
                        set: { model.doc.routing[o] = $0 ? SourceID.mix0 + bus : SourceID.off })
                    ) {
                        Text(Outputs.shortLabel(o))
                    }
                    .disabled(Outputs.isADATUpper(o) && !model.adatUpperAvailable)
                }
            }
        } label: {
            PillLabel(text: (side.map { "\($0) " } ?? "") + text,
                      color: Theme.accent(mixBus: model.doc.slot(containing: bus).bus),
                      dimmed: dests.isEmpty, compact: side != nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(dests.map(Outputs.label).joined(separator: ", "))
    }
}
