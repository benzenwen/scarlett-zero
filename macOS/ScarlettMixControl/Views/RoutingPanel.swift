import SwiftUI

struct RoutingPanel: View {
    @Environment(AppModel.self) private var model

    private let groups: [(title: String, outputs: [Int], columns: Int)] = [
        ("Monitor", [0, 1], 2),
        ("Line", Array(2...9), 4),
        ("S/PDIF", Outputs.spdif, 2),
        ("ADAT", Outputs.adat, 4),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Routing")
                Spacer()
                Menu {
                    ForEach(RoutingPreset.allCases) { p in
                        Button(p.rawValue) { p.apply(to: &model.doc) }
                            .help(p.help)
                    }
                } label: {
                    Label("Preset", systemImage: "square.grid.3x3.topleft.filled")
                        .font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            }
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    group(groups[0]).gridCellColumns(1)
                    group(groups[1]).gridCellColumns(2)
                }
                GridRow {
                    group(groups[2]).gridCellColumns(1)
                    group(groups[3]).gridCellColumns(2)
                }
            }
        }
        .padding(14)
        .panel()
    }

    private func group(_ g: (title: String, outputs: [Int], columns: Int)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(g.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 84), spacing: 6), count: g.columns),
                      alignment: .leading, spacing: 6) {
                ForEach(g.outputs, id: \.self) { OutputCell(output: $0) }
            }
        }
    }
}

struct OutputCell: View {
    @Environment(AppModel.self) private var model
    let output: Int

    var body: some View {
        let unavailable = Outputs.isADATUpper(output) && !model.adatUpperAvailable
        let listened = model.listen != nil && output < 2
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(shortName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                if let hp = Outputs.headphone(output) {
                    Image(systemName: "headphones")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                        .help("Headphones \(hp) mirror this output")
                }
                if listened {
                    Text("PFL")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Theme.pfl)
                }
            }
            SourceMenu(current: model.doc.routing[output], includeMixes: true) { id in
                model.doc.routing[output] = id
            }
        }
        .disabled(unavailable)
        .opacity(unavailable ? 0.35 : 1)
        .help(unavailable ? "ADAT 5–8 are unavailable at 88.2/96 kHz" : Outputs.label(output))
    }

    private var shortName: String {
        switch output {
        case 0, 1: "Mon \(output + 1)"
        case 2...9: "Line \(output + 1)"
        case 10, 11: output == 10 ? "S/PDIF L" : "S/PDIF R"
        default: "ADAT \(output - 11)"
        }
    }
}
