import Observation

/// Live meter levels with peak hold and latching clip, kept apart from
/// `AppModel` so 20 Hz meter updates only redraw meters.
@MainActor @Observable
final class MeterStore {
    /// Meter key: source id 0–37, or `mixKey(bus)` for mix outputs.
    typealias Key = Int
    static func mixKey(_ bus: Int) -> Key { 100 + bus }

    private(set) var levels: [Key: Float] = [:]
    private(set) var peaks: [Key: Float] = [:]
    private(set) var clips: Set<Key> = []
    private(set) var active = false

    private static let clipThreshold: Float = 4094 / 4095

    func ingest(_ frame: MeterFrame) {
        active = true
        var next: [Key: Float] = [:]
        for (id, v) in frame.sources.enumerated() { next[id] = v }
        for (b, v) in frame.mixes.enumerated() { next[Self.mixKey(b)] = v }
        for (k, v) in next {
            if v > peaks[k, default: 0] { peaks[k] = v }
            if v >= Self.clipThreshold { clips.insert(k) }
        }
        levels = next
    }

    func level(_ key: Key?) -> Float { key.flatMap { levels[$0] } ?? 0 }
    func peak(_ key: Key?) -> Float { key.flatMap { peaks[$0] } ?? 0 }
    func clipped(_ key: Key?) -> Bool { key.map { clips.contains($0) } ?? false }

    func resetPeak(_ keys: [Key]) {
        for k in keys {
            peaks[k] = nil
            clips.remove(k)
        }
    }

    func reset() {
        levels = [:]
        peaks = [:]
        clips = []
        active = false
    }

    /// Meter key for a mixer input's source (nil when Off or a mix).
    static func key(forSource id: Int) -> Key? { (0...37).contains(id) ? id : nil }
}
