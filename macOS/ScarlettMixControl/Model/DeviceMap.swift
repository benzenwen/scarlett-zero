import Foundation

/// Static facts about the Scarlett 18i20 Gen 1: source ids, outputs, labels.
/// Numeric ids match `scarlett.device` (Babashka) and the project brief.
/// Labels follow MixControl's own wording so the UI reads familiar.
enum DeviceMap {
    static let outputCount = 20
    static let busCount = 21
    static let mixerInputCount = 18
    static let mixBusCount = 8
    static let analogOutputCount = 10
    static let matrixNodeCount = mixerInputCount * mixBusCount

    static let sampleRates = [44_100, 48_000, 88_200, 96_000]

    enum Clock: Int, CaseIterable, Codable, Sendable {
        case internal_ = 1, spdif = 2, adat = 3
        var label: String {
            switch self {
            case .internal_: "Internal"
            case .spdif: "S/PDIF"
            case .adat: "ADAT"
            }
        }
    }
}

// MARK: - Sources

enum SourceID {
    static let daw0 = 0        // DAW 1–20      → 0–19
    static let analog0 = 20    // Anlg In 1–8   → 20–27
    static let spdif0 = 28     // SPDIF L/R     → 28–29
    static let adat0 = 30      // ADAT In 1–8   → 30–37
    static let mix0 = 38       // Mix 1–8       → 38–45
    /// MixControl parks unused routes on Mix 9 (0x2e) rather than 255.
    static let off = 46
    static let offExplicit = 255

    static func isOff(_ id: Int) -> Bool { id == 46 || id == 47 || id == offExplicit }
}

enum SourceKind: Equatable, Sendable {
    case off
    case analog(Int)   // 0-based
    case spdif(Int)
    case adat(Int)
    case daw(Int)
    case mix(Int)

    init(id: Int) {
        switch id {
        case 0...19: self = .daw(id)
        case 20...27: self = .analog(id - 20)
        case 28...29: self = .spdif(id - 28)
        case 30...37: self = .adat(id - 30)
        case 38...45: self = .mix(id - 38)
        default: self = .off
        }
    }

    /// MixControl label, e.g. "Anlg In 3", "SPDIF L", "DAW 12". Mixes are
    /// labelled by the document, which knows names and stereo pairing.
    var label: String {
        switch self {
        case .off: "Off"
        case .analog(let n): "Anlg In \(n + 1)"
        case .spdif(let n): n == 0 ? "SPDIF L" : "SPDIF R"
        case .adat(let n): "ADAT In \(n + 1)"
        case .daw(let n): "DAW \(n + 1)"
        case .mix(let n): "Mix \(n + 1)"
        }
    }

    /// Compact label for narrow strips: "In 3", "SPDIF L", "ADAT 2", "DAW 12".
    var shortLabel: String {
        switch self {
        case .analog(let n): "In \(n + 1)"
        case .adat(let n): "ADAT \(n + 1)"
        case .spdif(let n): n == 0 ? "SPD L" : "SPD R"
        default: label
        }
    }

    var isADATUpper: Bool {
        if case .adat(let n) = self { return n >= 4 }
        return false
    }
}

enum Sources {
    static let hardwareInputs: [Int] = Array(20...37)
    static let daw: [Int] = Array(0...19)
    static let mixes: [Int] = Array(38...45)
}

// MARK: - Outputs

enum Outputs {
    /// Routing-grid label, e.g. "Monitor Output 1", "Line Output 7".
    static func label(_ index: Int) -> String {
        switch index {
        case 0, 1: "Monitor Output \(index + 1)"
        case 2...9: "Line Output \(index + 1)"
        case 10, 11: "SPDIF Output \(index - 9)"
        default: "ADAT Output \(index - 11)"
        }
    }

    /// Compact label used on mixer destination buttons ("Mon. 1", "Anlg Out 3").
    static func shortLabel(_ index: Int) -> String {
        switch index {
        case 0, 1: "Mon. \(index + 1)"
        case 2...9: "Anlg Out \(index + 1)"
        case 10: "SPDIF OP L"
        case 11: "SPDIF OP R"
        default: "ADAT \(index - 11)"
        }
    }

    /// Headphones 1 mirrors Line Outputs 7/8, Headphones 2 mirrors 9/10.
    static func headphone(_ index: Int) -> Int? {
        switch index {
        case 6, 7: 1
        case 8, 9: 2
        default: nil
        }
    }

    static func isADATUpper(_ index: Int) -> Bool { (16...19).contains(index) }

    static let analog = Array(0...9)
    static let spdif = [10, 11]
    static let adat = Array(12...19)
}
