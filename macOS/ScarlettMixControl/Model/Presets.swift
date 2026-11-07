import Foundation

/// MixControl's Routing Preset… menu (user guide p.27–28).
enum RoutingPreset: String, CaseIterable, Identifiable {
    case clear = "Clear"
    case dawTracking = "DAW Tracking"
    case zeroLatency = "Zero Latency Tracking"
    case mixing = "Mixing"

    var id: String { rawValue }

    var help: String {
        switch self {
        case .clear: "Set every output to Off."
        case .dawTracking: "DAW 1/2 to all analog outputs and headphones — monitor through your DAW."
        case .zeroLatency: "Mix 1/2 to all analog outputs and headphones — monitor through the mixer."
        case .mixing: "DAW n to output n: DAW 1–10 → analog, 11–18 → ADAT, 19–20 → S/PDIF."
        }
    }

    func apply(to doc: inout MixerDocument) {
        switch self {
        case .clear:
            doc.routing = Array(repeating: SourceID.off, count: DeviceMap.outputCount)
        case .dawTracking:
            for o in Outputs.analog { doc.routing[o] = SourceID.daw0 + o % 2 }
        case .zeroLatency:
            // Stereo Mix 1: L → odd outputs, R → even. Mono: Mix 1 → odd,
            // Mix 2 → even. Both land on buses 0/1.
            for o in Outputs.analog { doc.routing[o] = SourceID.mix0 + o % 2 }
        case .mixing:
            for o in Outputs.analog { doc.routing[o] = SourceID.daw0 + o }
            for (i, o) in Outputs.adat.enumerated() { doc.routing[o] = SourceID.daw0 + 10 + i }
            doc.routing[10] = SourceID.daw0 + 18
            doc.routing[11] = SourceID.daw0 + 19
        }
    }
}

/// MixControl's Monitor Preset… menu (user guide p.30; output sets from the
/// app's own 18i20 preset table).
enum MonitorPreset: String, CaseIterable, Identifiable {
    case off = "Off"
    case mono = "Mono"
    case stereo = "Stereo"
    case quad = "Quad"
    case surround21 = "2.1 Surround"
    case surround51 = "5.1 Surround"
    case surround71 = "7.1 Surround"
    case midPhones1 = "Mid + Phones 1"
    case miniPhones2 = "Mini + Phones 2"

    var id: String { rawValue }

    /// 0-based analog outputs this preset puts under monitor control.
    var controlled: [Int] {
        switch self {
        case .off: []
        case .mono: [2]
        case .stereo: [0, 1]
        case .quad: [0, 1, 6, 7]
        case .surround21: [0, 1, 3]
        case .surround51: [0, 1, 2, 3, 6, 7]
        case .surround71: [0, 1, 2, 3, 4, 5, 6, 7]
        case .midPhones1: [6, 7]
        case .miniPhones2: [8, 9]
        }
    }

    /// The "+ Phones" presets add to the current set; the rest replace it
    /// and mute everything they don't control.
    var isAdditive: Bool { self == .midPhones1 || self == .miniPhones2 }

    func apply(to doc: inout MixerDocument) {
        for i in 0..<DeviceMap.analogOutputCount {
            if controlled.contains(i) {
                doc.monitor.modes[i] = .controlled
            } else if !isAdditive {
                doc.monitor.modes[i] = .muted
            }
        }
    }
}

extension MixerDocument {
    /// Transcribed from MixControl's bundled `Default.18i20` snapshot
    /// (`busms=0xFF` → all four mix pairs stereo): Anlg 1–8 and DAW 1/2
    /// (linked) at unity in Mix 1, which feeds L → odd analog outputs and
    /// R → even; the other mixes are faded out; outputs 1–6 follow the
    /// monitor knob. HW Control is on (the file has it off) so the front knob
    /// keeps working the way it does with no host attached.
    static var factoryDefault: MixerDocument {
        var doc = MixerDocument()
        for i in 0..<8 { doc.inputs[i].source = SourceID.analog0 + i }
        doc.inputs[16].source = SourceID.daw0
        doc.inputs[17].source = SourceID.daw0 + 1
        doc.linkedPairs[8] = true
        doc.stereoMixPairs = Array(repeating: true, count: DeviceMap.mixBusCount / 2)
        for c in [0, 1, 2, 3, 4, 5, 6, 7, 16, 17] { doc.mixes[0].channels[c].gainDB = 0 }
        for bus in 1..<DeviceMap.mixBusCount { doc.mixes[bus].gainDB = nil }
        for o in Outputs.analog { doc.routing[o] = SourceID.mix0 + o % 2 }
        doc.monitor.modes = (0..<10).map { $0 < 6 ? .controlled : .fixed }
        doc.monitor.hardwareControl = true
        return doc
    }

    /// "Clear All Settings": nothing routed, nothing mixed.
    static var cleared: MixerDocument {
        var doc = MixerDocument()
        for bus in doc.mixes.indices { doc.mixes[bus].gainDB = nil }
        return doc
    }
}
