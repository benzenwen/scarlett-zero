import Foundation

/// dB ↔ device raw. The device speaks signed int16 in 1/256 dB, with
/// 0x8000 reserved for −∞ — the same law as `scarlett.codec` in bb.
/// Throughout the app a gain of `nil` means −∞ (silence).
enum Gain {
    static let silenceRaw: Int16 = -32768
    static let floorDB = -127.99
    static let faderMaxDB = 6.0

    static func raw(_ dB: Double?, ceiling: Double = faderMaxDB) -> Int16 {
        guard let dB, dB > floorDB else { return silenceRaw }
        return Int16((min(dB, ceiling) * 256).rounded())
    }

    static func dB(_ raw: Int16) -> Double? {
        raw == silenceRaw ? nil : Double(raw) / 256
    }

    /// Sum of dB terms where any −∞ term silences the whole.
    static func sum(_ terms: Double?...) -> Double? {
        var total = 0.0
        for t in terms {
            guard let t else { return nil }
            total += t
        }
        return total
    }

    static func amplitudeDB(_ amplitude: Double) -> Double? {
        amplitude <= 0.000_001 ? nil : 20 * log10(amplitude)
    }

    static func format(_ dB: Double?, decimals: Int = 1) -> String {
        guard let dB else { return "−∞" }
        let s = String(format: "%.\(decimals)f", dB)
        return s == "-0.0" || s == "-0" ? s.replacingOccurrences(of: "-", with: "") : s.replacingOccurrences(of: "-", with: "−")
    }
}

/// UI fader taper: position 0…1 ↔ dB. Piecewise-linear through console-style
/// anchors so the region around unity gets most of the travel; 0 dB sits at 80%.
enum FaderTaper {
    private static let anchors: [(pos: Double, dB: Double)] = [
        (0.0, -128), (0.10, -60), (0.25, -40), (0.45, -20),
        (0.62, -10), (0.80, 0), (1.0, 6),
    ]
    static let silenceBelow = 0.004

    static func dB(at position: Double) -> Double? {
        let p = max(0, min(1, position))
        if p < silenceBelow { return nil }
        for (a, b) in zip(anchors, anchors.dropFirst()) where p <= b.pos {
            let t = (p - a.pos) / (b.pos - a.pos)
            return a.dB + t * (b.dB - a.dB)
        }
        return anchors.last!.dB
    }

    static func position(for dB: Double?) -> Double {
        guard let dB else { return 0 }
        let d = max(anchors.first!.dB, min(anchors.last!.dB, dB))
        for (a, b) in zip(anchors, anchors.dropFirst()) where d <= b.dB {
            let t = (d - a.dB) / (b.dB - a.dB)
            return a.pos + t * (b.pos - a.pos)
        }
        return 1
    }
}

/// Pan law. MixControl's mixer routes both mono pan and stereo balance
/// through its `BalanceLaw`, so both behave as balance here: unity on both
/// sides at centre, the opposite side fading linearly to silence (fully left
/// mutes right). `pan` is −1 (L) … +1 (R).
enum PanLaw {
    static func balance(_ pan: Double) -> (left: Double?, right: Double?) {
        let b = max(-1, min(1, pan))
        return (Gain.amplitudeDB(b > 0 ? 1 - b : 1), Gain.amplitudeDB(b < 0 ? 1 + b : 1))
    }
}

/// MixControl's stored fader positions (0…1) → dB. Recovered shape from the
/// 1.10.6 binary (`FaderLaw::fader2dB` is `min + k·(bˣ−1)`), fitted to the
/// three known anchors: 0 → −∞, 0.775137 → 0 dB, 1.0 → +6 dB. Used only for
/// importing legacy `.18i20` snapshot files; approximate away from anchors.
enum MixControlFaderLaw {
    static let unityPosition = 0.775137
    private static let floor = -128.0, span = 134.0

    private static let base: Double = {
        // Solve (1 − b^u)/(1 − b) = 128/134 for b in (0, 1).
        let target = -floor / span
        var lo = 1e-6, hi = 0.999_999
        for _ in 0..<200 {
            let mid = (lo + hi) / 2
            let f = (1 - pow(mid, unityPosition)) / (1 - mid)
            if f > target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }()

    static func dB(_ position: Double) -> Double? {
        guard position > 0.000_5 else { return nil }
        let x = min(1, position)
        return floor + span * (1 - pow(base, x)) / (1 - base)
    }
}
