import SwiftUI

/// MixControl-style source picker: Off / Inputs ▸ / DAW ▸ (/ Mixes ▸).
struct SourceMenu: View {
    @Environment(AppModel.self) private var model
    let current: Int
    var includeMixes = false
    /// Narrow strips: short label, no chevron.
    var compact = false
    /// Mixer channel being edited, to grey out sources other channels use.
    var channel: Int? = nil
    var onSelect: (Int) -> Void

    var body: some View {
        Menu {
            item(SourceID.off)
            Menu("Inputs") { ForEach(Sources.hardwareInputs, id: \.self) { item($0) } }
            Menu("DAW") { ForEach(Sources.daw, id: \.self) { item($0) } }
            if includeMixes {
                Menu("Mixes") { ForEach(Sources.mixes, id: \.self) { item($0) } }
            }
        } label: {
            PillLabel(text: compact && !isMix(current) ? SourceKind(id: current).shortLabel : model.doc.sourceLabel(current),
                      color: color(current),
                      dimmed: SourceID.isOff(current),
                      compact: compact)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// Mixes take their slot's accent, so both sides of a stereo mix match.
    private func color(_ id: Int) -> Color {
        if case .mix(let bus) = SourceKind(id: id) {
            return Theme.accent(mixBus: model.doc.slot(containing: bus).bus)
        }
        return Theme.color(forSource: id)
    }

    private func isMix(_ id: Int) -> Bool {
        if case .mix = SourceKind(id: id) { return true }
        return false
    }

    @ViewBuilder
    private func item(_ id: Int) -> some View {
        let selected = id == current || (SourceID.isOff(id) && SourceID.isOff(current))
        let unavailable = (SourceKind(id: id).isADATUpper && !model.adatUpperAvailable)
            || (channel.map { model.doc.sourceInUse(id, excludingChannel: $0) } ?? false)
        Button {
            onSelect(id)
        } label: {
            if selected {
                Label(model.doc.sourceLabel(id), systemImage: "checkmark")
            } else {
                Text(model.doc.sourceLabel(id))
            }
        }
        .disabled(unavailable && !selected)
    }
}
