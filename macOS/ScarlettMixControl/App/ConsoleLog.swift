import Foundation
import Observation

/// Debug console history: every device write (in scarlett_ctl grammar),
/// reads, connection events, errors, and console commands with replies.
@MainActor @Observable
final class ConsoleLog {
    struct Entry: Identifiable {
        let id: Int
        let date: Date
        let kind: LogKind
        let text: String
    }

    private(set) var entries: [Entry] = []
    private var nextID = 0
    private static let limit = 5_000

    func append(_ kind: LogKind, _ text: String) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            entries.append(Entry(id: nextID, date: .now, kind: kind, text: String(line)))
            nextID += 1
        }
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    func clear() { entries.removeAll() }

    func export(_ kinds: Set<LogKind>) -> String {
        let f = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3))
        return entries.filter { kinds.contains($0.kind) }
            .map { "\($0.date.formatted(f))  \($0.kind.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0))  \($0.text)" }
            .joined(separator: "\n")
    }
}
