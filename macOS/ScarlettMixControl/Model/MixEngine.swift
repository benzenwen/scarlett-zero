import Foundation

/// Everything the device holds that the app reads or writes.
struct HardwareImage: Equatable, Sendable {
    var clock: Int = 1
    var routing: [Int] = Array(repeating: SourceID.off, count: DeviceMap.outputCount)
    var mixerInputs: [Int] = Array(repeating: SourceID.off, count: DeviceMap.mixerInputCount)
    var matrix: [Int16] = Array(repeating: Gain.silenceRaw, count: DeviceMap.matrixNodeCount)
    var buses: [Int16] = Array(repeating: 0, count: DeviceMap.busCount)
    /// Write-only: the device can't report these, so they never take part in
    /// matching and are always written in full after a read.
    var monitor = MonitorRegisters()

    static func node(input: Int, bus: Int) -> Int { input * DeviceMap.mixBusCount + bus }
}

/// The firmware's own monitor control (MixControl 1.10.6 disassembly,
/// verified 2026-11-07). Bit n = analog output n.
struct MonitorRegisters: Equatable, Sendable {
    /// mem 0x0a: outputs the firmware attenuates by the front knob, with or
    /// without a host. MixControl: controlled outputs when HW Control is on,
    /// otherwise none.
    var knobMask: UInt32 = 0
    /// mem 0x0b/0x0c: controlled outputs (front MUTE/DIM), always written.
    var buttonMask: UInt32 = 0
    /// DAC mute per analog output: red outputs, and L/R mutes.
    var dacMute = Array(repeating: false, count: DeviceMap.analogOutputCount)
}

/// Transient pre-fade listen: temporarily re-routes Monitor Outputs 1/2.
enum Listen: Equatable, Sendable {
    case strip(Int)   // channel strip leader
    case mix(Int)     // mix slot leading bus
}

/// Pure translation between `MixerDocument` and `HardwareImage`.
enum MixEngine {

    // MARK: Document → hardware

    static func image(for doc: MixerDocument, listen: Listen? = nil) -> HardwareImage {
        var hw = HardwareImage()
        hw.clock = doc.clock.rawValue
        hw.routing = routing(for: doc, listen: listen)
        hw.mixerInputs = doc.inputs.map(\.source)
        hw.matrix = matrix(for: doc)
        hw.buses = buses(for: doc)
        hw.monitor = monitorRegisters(for: doc)
        return hw
    }

    static func routing(for doc: MixerDocument, listen: Listen?) -> [Int] {
        var routing = doc.routing
        switch listen {
        case .strip(let c):
            let l = doc.inputs[c].source
            let r = doc.isLinked(c) ? doc.inputs[c + 1].source : l
            routing[0] = l
            routing[1] = r
        case .mix(let bus):
            let slot = doc.slot(containing: bus)
            routing[0] = SourceID.mix0 + slot.bus
            routing[1] = SourceID.mix0 + (slot.stereo ? slot.bus + 1 : slot.bus)
        case nil:
            break
        }
        return routing
    }

    static func matrix(for doc: MixerDocument) -> [Int16] {
        var m = Array(repeating: Gain.silenceRaw, count: DeviceMap.matrixNodeCount)
        for slot in doc.mixSlots {
            let mix = doc.mixes[slot.bus]
            let soloing = doc.strips.contains { mix.channels[$0.channel].solo }

            for c in 0..<DeviceMap.mixerInputCount {
                let leader = doc.stripLeader(c)
                let ch = mix.channels[leader]
                let silenced = mix.mute || ch.mute || (soloing && !ch.solo)
                let base: Double? = silenced ? nil : Gain.sum(ch.gainDB, mix.gainDB)

                if !slot.stereo {
                    m[HardwareImage.node(input: c, bus: slot.bus)] = Gain.raw(base)
                } else if doc.isLinked(c) {
                    // Linked pair into stereo mix: L→L, R→R, balance trims.
                    let bal = PanLaw.balance(ch.pan)
                    let isLeft = c == leader
                    let own = isLeft ? slot.bus : slot.bus + 1
                    let other = isLeft ? slot.bus + 1 : slot.bus
                    m[HardwareImage.node(input: c, bus: own)] = Gain.raw(Gain.sum(base, isLeft ? bal.left : bal.right))
                    m[HardwareImage.node(input: c, bus: other)] = Gain.silenceRaw
                } else {
                    let pan = PanLaw.balance(ch.pan)
                    m[HardwareImage.node(input: c, bus: slot.bus)] = Gain.raw(Gain.sum(base, pan.left))
                    m[HardwareImage.node(input: c, bus: slot.bus + 1)] = Gain.raw(Gain.sum(base, pan.right))
                }
            }
        }
        return m
    }

    /// Bus 0 and digital buses pass through; analog buses 1–10 carry the
    /// monitor section (MixControl's blue/red/grey output buttons).
    ///
    /// With HW Control the firmware applies the front knob, DIM and MUTE to
    /// controlled outputs itself, so their output gain stays at 0 dB (plus
    /// pad); applying the polled knob here too would attenuate twice.
    static func buses(for doc: MixerDocument) -> [Int16] {
        var b = doc.passthroughBuses
        let mon = doc.monitor
        for i in 0..<DeviceMap.analogOutputCount {
            let gain: Double?
            switch mon.modes[i] {
            case .fixed:
                gain = 0
            case .muted:
                gain = nil
            case .controlled:
                let sideMuted = i % 2 == 0 ? mon.muteLeft : mon.muteRight
                if sideMuted {
                    gain = nil
                } else if mon.hardwareControl {
                    gain = mon.pad && i < 2 ? MixerDocument.padDB : 0
                } else if mon.mute || mon.levelDB <= MixerDocument.monitorFloorDB {
                    gain = nil
                } else {
                    gain = mon.levelDB
                        + (mon.dim ? MixerDocument.dimDB : 0)
                        + (mon.pad && i < 2 ? MixerDocument.padDB : 0)
                }
            }
            b[i + 1] = Gain.raw(gain, ceiling: 0)
        }
        return b
    }

    static func monitorRegisters(for doc: MixerDocument) -> MonitorRegisters {
        let mon = doc.monitor
        var r = MonitorRegisters()
        for i in 0..<DeviceMap.analogOutputCount {
            let controlled = mon.modes[i] == .controlled
            if controlled { r.buttonMask |= 1 << i }
            let sideMuted = i % 2 == 0 ? mon.muteLeft : mon.muteRight
            r.dacMute[i] = mon.modes[i] == .muted || (controlled && sideMuted)
        }
        r.knobMask = mon.hardwareControl ? r.buttonMask : 0
        return r
    }

    // MARK: Hardware → document

    /// Best-effort reconstruction when there's no saved document that matches
    /// the hardware: every mix mono, every channel at its matrix gain, centred.
    static func document(from hw: HardwareImage) -> MixerDocument {
        var doc = MixerDocument()
        doc.clock = DeviceMap.Clock(rawValue: hw.clock) ?? .internal_
        doc.routing = hw.routing
        for i in doc.inputs.indices { doc.inputs[i].source = hw.mixerInputs[i] }
        for bus in 0..<DeviceMap.mixBusCount {
            doc.mixes[bus].gainDB = 0
            for c in 0..<DeviceMap.mixerInputCount {
                doc.mixes[bus].channels[c].gainDB = Gain.dB(hw.matrix[HardwareImage.node(input: c, bus: bus)])
            }
        }
        doc.passthroughBuses = hw.buses

        // Monitor: 0 dB → fixed, −∞ → muted, anything else → controlled.
        var level: Double?
        for i in 0..<DeviceMap.analogOutputCount {
            switch Gain.dB(hw.buses[i + 1]) {
            case nil: doc.monitor.modes[i] = .muted
            case 0?: doc.monitor.modes[i] = .fixed
            case let dB?:
                doc.monitor.modes[i] = .controlled
                level = level ?? dB
            }
        }
        doc.monitor.levelDB = level ?? 0
        // Nothing attenuated in software: assume the firmware default of the
        // front knob driving Monitor 1/2 (their output gain stays 0 dB, so
        // this still matches the hardware).
        if level == nil {
            doc.monitor.modes[0] = .controlled
            doc.monitor.modes[1] = .controlled
            doc.monitor.hardwareControl = true
        }
        return doc
    }

    /// True if the document, rendered without a listen override, is exactly
    /// what the device holds — i.e. it's safe to show it as the current state.
    static func matches(_ doc: MixerDocument, _ hw: HardwareImage) -> Bool {
        var rendered = image(for: doc)
        rendered.clock = hw.clock       // clock is live device state, not a match criterion
        rendered.monitor = hw.monitor   // write-only registers can't be compared
        return rendered == hw
    }
}
