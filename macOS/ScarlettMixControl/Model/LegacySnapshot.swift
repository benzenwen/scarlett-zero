import Foundation

/// Imports MixControl `.18i20` snapshot files (`<USB18i20Snapshot>` XML).
///
/// Format notes (from MixControl 1.10.6's bundled `Default.18i20`):
/// - Router `<xp>` text is "srcType srcIdx dstType dstIdx". Types:
///   0 analog, 1 ADAT, 2 S/PDIF, 3 DAW/host, 5 mix, 6 off.
/// - `<monset>` has one flag per analog output (1 = follows monitor).
/// - `chanms` is a bitmask of linked channels; `busms` of stereo mix buses.
/// - Mixer gains are fader positions 0…1, converted via `MixControlFaderLaw`.
enum LegacySnapshot {
    enum ImportError: LocalizedError {
        case notASnapshot
        var errorDescription: String? { "This file isn't a Scarlett 18i20 MixControl snapshot." }
    }

    static func load(_ data: Data) throws -> MixerDocument {
        let xml = try XMLDocument(data: data)
        guard let root = xml.rootElement(), root.name == "USB18i20Snapshot" else {
            throw ImportError.notASnapshot
        }
        var doc = MixerDocument()
        importRouter(root, into: &doc)
        importMonitor(root, into: &doc)
        importMixer(root, into: &doc)
        return doc
    }

    // MARK: Router

    static func sourceID(type: Int, index: Int) -> Int {
        switch type {
        case 0: SourceID.analog0 + index
        case 1: SourceID.adat0 + index
        case 2: SourceID.spdif0 + index
        case 3: SourceID.daw0 + index
        case 5: SourceID.mix0 + index
        default: SourceID.off
        }
    }

    private static func importRouter(_ root: XMLElement, into doc: inout MixerDocument) {
        for xp in root.elements(path: "USB18i20Router/xpoints/xp") {
            let f = ints(xp.stringValue)
            guard f.count == 4 else { continue }
            let src = sourceID(type: f[0], index: f[1])
            let (dt, di) = (f[2], f[3])
            switch dt {
            case 0 where di < 10: doc.routing[di] = src
            case 1 where di < 8: doc.routing[12 + di] = src
            case 2 where di < 2: doc.routing[10 + di] = src
            case 5 where di < DeviceMap.mixerInputCount: doc.inputs[di].source = src
            default: break   // 3 = capture to host: not user-routable in MixControl
            }
        }
    }

    // MARK: Monitor

    private static func importMonitor(_ root: XMLElement, into doc: inout MixerDocument) {
        guard let mon = root.elements(path: "USB18i20Monitor").first else { return }
        if let hwc = mon.elements(forName: "hwc").first {
            doc.monitor.hardwareControl = (Int(hwc.stringValue ?? "") ?? 0) != 0
        }
        if let set = mon.elements(forName: "monset").first {
            for (i, flag) in ints(set.stringValue).prefix(10).enumerated() {
                // 1 = controlled. 2 is our guess for muted; 0 = fixed.
                doc.monitor.modes[i] = flag == 1 ? .controlled : flag == 2 ? .muted : .fixed
            }
        }
        if let gain = mon.elements(forName: "gain").first {
            doc.monitor.levelDB = min(0, Double(gain.stringValue ?? "") ?? 0)
            doc.monitor.pad = gain.attribute(forName: "pad")?.stringValue == "1"
        }
    }

    // MARK: Mixer

    private static func importMixer(_ root: XMLElement, into doc: inout MixerDocument) {
        guard let mixer = root.elements(path: "USB18i20Mixer").first else { return }

        if let globals = mixer.elements(forName: "globals").first {
            let chanms = Int(globals.attr("chanms")) ?? 0
            let busms = Int(globals.attr("busms")) ?? 0
            for k in doc.linkedPairs.indices { doc.linkedPairs[k] = chanms & (1 << (2 * k)) != 0 }
            for k in doc.stereoMixPairs.indices { doc.stereoMixPairs[k] = busms & (1 << (2 * k)) != 0 }
            for ip in globals.elements(path: "mixips/ip") {
                guard let c = Int(ip.attr("c")), c < DeviceMap.mixerInputCount else { continue }
                doc.inputs[c].name = ip.attr("name")
                let f = ints(ip.stringValue)
                if f.count == 2 { doc.inputs[c].source = sourceID(type: f[0], index: f[1]) }
            }
        }

        for mix in mixer.elements(path: "mixes/mix") {
            guard let m = Int(mix.attr("m")), m < DeviceMap.mixBusCount else { continue }
            doc.mixes[m].name = mix.attr("name")
            doc.mixes[m].mute = mix.attr("mute") == "1"
            doc.mixes[m].gainDB = MixControlFaderLaw.dB(Double(mix.attr("gain")) ?? 0)
            for chan in mix.elements(path: "chans/chan") {
                guard let c = Int(chan.attr("c")), c < DeviceMap.mixerInputCount else { continue }
                let linked = doc.linkedPairs[c / 2]
                let panKey = linked ? "b" : "p"
                doc.mixes[m].channels[c] = .init(
                    gainDB: MixControlFaderLaw.dB(Double(chan.attr("g")) ?? 0),
                    pan: (Double(chan.attr(panKey)) ?? 0.5) * 2 - 1,
                    mute: chan.attr("m") == "1",
                    solo: chan.attr("s") == "1")
            }
        }
    }

    private static func ints(_ s: String?) -> [Int] {
        (s ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    }
}

private extension XMLElement {
    func attr(_ name: String) -> String { attribute(forName: name)?.stringValue ?? "" }

    func elements(path: String) -> [XMLElement] {
        var level = [self]
        for part in path.split(separator: "/") {
            level = level.flatMap { $0.elements(forName: String(part)) }
        }
        return level
    }
}
