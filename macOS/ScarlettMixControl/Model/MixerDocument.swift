import Foundation

/// The complete, persistable state of the app — what MixControl called a
/// "snapshot". Hardware only knows routing, matrix gains, and bus volumes;
/// everything richer (pan, mute, solo, stereo link, names, monitor modes) is
/// software state that `MixEngine` flattens into device writes.
struct MixerDocument: Codable, Equatable, Sendable {
    /// 2: the monitor section drives the firmware's knob set (mem 0x0a);
    /// see `migrated()`.
    var version = 2
    var clock: DeviceMap.Clock = .internal_
    /// Output index (0–19) → source id.
    var routing: [Int] = Array(repeating: SourceID.off, count: DeviceMap.outputCount)
    var inputs: [MixerInput] = (0..<DeviceMap.mixerInputCount).map { _ in MixerInput() }
    /// Channel pair k links mixer inputs 2k (L) and 2k+1 (R).
    var linkedPairs: [Bool] = Array(repeating: false, count: DeviceMap.mixerInputCount / 2)
    /// Mix pair k makes mix buses 2k/2k+1 one stereo mix.
    var stereoMixPairs: [Bool] = Array(repeating: false, count: DeviceMap.mixBusCount / 2)
    var mixes: [Mix] = (0..<DeviceMap.mixBusCount).map { _ in Mix() }
    var monitor = MonitorState()
    /// Bus volumes the app doesn't model (0 = master, 11–20 = digital outs),
    /// carried through untouched so the app never clobbers them.
    var passthroughBuses: [Int16] = Array(repeating: 0, count: DeviceMap.busCount)

    struct MixerInput: Codable, Equatable, Sendable {
        var source: Int = SourceID.off
        var name: String = ""
    }

    struct ChannelSettings: Codable, Equatable, Sendable {
        var gainDB: Double? = nil
        /// Pan (mono channel in stereo mix) or balance (linked pair), −1…+1.
        var pan: Double = 0
        var mute = false
        var solo = false
    }

    struct Mix: Codable, Equatable, Sendable {
        var name: String = ""
        var gainDB: Double? = 0
        var mute = false
        var channels: [ChannelSettings] = Array(repeating: ChannelSettings(), count: DeviceMap.mixerInputCount)
    }

    enum MonitorMode: String, Codable, Sendable {
        /// Follows the monitor level, dim, and mutes (MixControl's blue).
        case controlled
        /// Muted (red).
        case muted
        /// Fixed at full level, not controlled (grey).
        case fixed
    }

    struct MonitorState: Codable, Equatable, Sendable {
        var modes: [MonitorMode] = Array(repeating: .fixed, count: DeviceMap.analogOutputCount)
        var levelDB: Double = 0
        var dim = false
        var mute = false
        var muteLeft = false
        var muteRight = false
        var pad = false
        var mono = false
        var hardwareControl = false
    }

    static let dimDB = -18.0
    static let padDB = -20.0
    static let monitorFloorDB = -127.0
}

// MARK: - Structure queries

extension MixerDocument {
    /// A mix "slot" is what the UI shows as one tab: a mono bus, or a stereo pair.
    struct MixSlot: Hashable, Identifiable, Sendable {
        /// Leading bus index (0–7). For stereo, the pair is (bus, bus+1).
        let bus: Int
        let stereo: Bool
        var id: Int { bus }
        var buses: [Int] { stereo ? [bus, bus + 1] : [bus] }
    }

    var mixSlots: [MixSlot] {
        var slots: [MixSlot] = []
        var bus = 0
        while bus < DeviceMap.mixBusCount {
            if bus % 2 == 0, stereoMixPairs[bus / 2] {
                slots.append(MixSlot(bus: bus, stereo: true))
                bus += 2
            } else {
                slots.append(MixSlot(bus: bus, stereo: false))
                bus += 1
            }
        }
        return slots
    }

    func slot(containing bus: Int) -> MixSlot {
        mixSlots.first { $0.buses.contains(bus) } ?? MixSlot(bus: bus, stereo: false)
    }

    /// A channel "strip" is a mono mixer input or a linked pair.
    struct Strip: Hashable, Identifiable, Sendable {
        let channel: Int
        let linked: Bool
        var id: Int { channel }
        var channels: [Int] { linked ? [channel, channel + 1] : [channel] }
    }

    var strips: [Strip] {
        var result: [Strip] = []
        var c = 0
        while c < DeviceMap.mixerInputCount {
            if c % 2 == 0, linkedPairs[c / 2] {
                result.append(Strip(channel: c, linked: true))
                c += 2
            } else {
                result.append(Strip(channel: c, linked: false))
                c += 1
            }
        }
        return result
    }

    func isLinked(_ channel: Int) -> Bool { linkedPairs[channel / 2] }
    func stripLeader(_ channel: Int) -> Int { isLinked(channel) ? channel & ~1 : channel }

    func mixName(_ slot: MixSlot) -> String {
        let custom = mixes[slot.bus].name
        if !Self.isAutomaticMixName(custom) { return custom }
        return defaultMixName(slot)
    }

    /// "Mix 3" mono, "Mix 3+4" stereo — MixControl's convention.
    func defaultMixName(_ slot: MixSlot) -> String {
        slot.stereo ? "Mix \(slot.bus + 1)+\(slot.bus + 2)" : "Mix \(slot.bus + 1)"
    }

    /// Empty, or a name MixControl generated ("Mix 3", "Mix 3+4"). These track
    /// the stereo link instead of sticking as custom names.
    static func isAutomaticMixName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.wholeMatch(of: /Mix \d+(\s*\+\s*\d+)?/) != nil
    }

    func stripName(_ strip: Strip) -> String {
        let custom = inputs[strip.channel].name
        if !custom.isEmpty { return custom }
        return strip.linked ? "\(strip.channel + 1) + \(strip.channel + 2)" : "\(strip.channel + 1)"
    }

    /// Source label, resolving mix ids against names and stereo pairing:
    /// "Mix 1+2 L", "Monitor Mix R" (short enough for the routing pills).
    func sourceLabel(_ id: Int) -> String {
        guard case .mix(let bus) = SourceKind(id: id) else { return SourceKind(id: id).label }
        let slot = slot(containing: bus)
        let name = mixName(slot)
        guard slot.stereo else { return name }
        return "\(name) \(bus == slot.bus ? "L" : "R")"
    }

    /// Outputs currently fed by a given mix bus.
    func destinations(ofBus bus: Int) -> [Int] {
        routing.indices.filter { routing[$0] == SourceID.mix0 + bus }
    }

    func sourceInUse(_ id: Int, excludingChannel channel: Int) -> Bool {
        guard !SourceID.isOff(id) else { return false }
        return inputs.indices.contains { $0 != channel && inputs[$0].source == id }
    }
}

// MARK: - Mutations that keep invariants

extension MixerDocument {
    /// Version 1 never wrote the firmware's monitor registers, so whatever
    /// the device's flash held kept the front knob live. Keep it live rather
    /// than jump outputs to the software level on first connect: turn HW
    /// Control on, and if nothing was controlled, give the knob Monitor 1/2.
    func migrated() -> MixerDocument {
        var doc = self
        if doc.version < 2 {
            doc.monitor.hardwareControl = true
            if !doc.monitor.modes.contains(.controlled) {
                doc.monitor.modes[0] = .controlled
                doc.monitor.modes[1] = .controlled
            }
            doc.version = 2
        }
        return doc
    }

    mutating func setLinked(_ linked: Bool, pair: Int) {
        linkedPairs[pair] = linked
        guard linked else { return }
        let l = pair * 2
        // The pair's settings live on the left channel; start centred.
        for m in mixes.indices { mixes[m].channels[l].pan = 0 }
        if inputs[l].name == inputs[l + 1].name { inputs[l + 1].name = "" }
    }

    mutating func setStereo(_ stereo: Bool, mixPair: Int) {
        stereoMixPairs[mixPair] = stereo
        guard stereo else { return }
        let l = mixPair * 2
        // Stereo mixes start with mono channels centred.
        for c in mixes[l].channels.indices where !isLinked(c) { mixes[l].channels[c].pan = 0 }
    }

    /// MixControl's "Copy Mix To…": faders, pans, mutes, solos (and the mix fader).
    mutating func copyMix(from source: Int, to target: Int) {
        let name = mixes[target].name
        mixes[target] = mixes[source]
        mixes[target].name = name
    }
}
