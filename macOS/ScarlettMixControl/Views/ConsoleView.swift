import SwiftUI

/// Device ▸ Debug Console (⌥⌘D). Live log of everything the app sends to
/// and reads from the 18i20, plus a command line that speaks the same
/// grammar as `scarlett_ctl` against the app's open handle.
struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var kinds = Set(LogKind.allCases)
    @State private var follow = true
    @FocusState private var inputFocused: Bool

    private var entries: [ConsoleLog.Entry] {
        model.console.entries.filter { kinds.contains($0.kind) }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider().overlay(Theme.stroke)
            log
            Divider().overlay(Theme.stroke)
            prompt
        }
        .background(Theme.well)
        .frame(minWidth: 640, minHeight: 360)
        .preferredColorScheme(.dark)
        .onAppear { inputFocused = true }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(LogKind.allCases, id: \.self) { kind in
                let on = kinds.contains(kind)
                Button {
                    if on { kinds.remove(kind) } else { kinds.insert(kind) }
                } label: {
                    Text(kind.rawValue)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(on ? Self.color(kind) : Theme.tertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(on ? Self.color(kind).opacity(0.14) : .clear, in: .capsule)
                        .overlay(Capsule().strokeBorder(on ? Self.color(kind).opacity(0.5) : Theme.stroke))
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
                .controlSize(.small)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.console.export(kinds), forType: .string)
            }
            .controlSize(.small)
            Button("Clear") { model.console.clear() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.panel)
    }

    private var log: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(entries) { row($0).id($0.id) }
                }
                .padding(8)
                .textSelection(.enabled)
            }
            .onChange(of: model.console.entries.last?.id) { _, last in
                guard follow, let last else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    private func row(_ e: ConsoleLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(e.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
                .foregroundStyle(Theme.tertiary)
            Text(e.kind.rawValue)
                .foregroundStyle(Self.color(e.kind))
                .frame(width: 56, alignment: .leading)
            Text(e.text)
                .foregroundStyle(e.kind == .reply ? Theme.text : Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private var prompt: some View {
        HStack(spacing: 8) {
            Text("›")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.solo)
            TextField("help · dump · route 0 38 · bus 1 -2560 · matrix 0 0 · coreaudio · state · clear", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($inputFocused)
                .onSubmit(submit)
                .onKeyPress(.upArrow) { recall(-1) }
                .onKeyPress(.downArrow) { recall(1) }
            if !model.isConnected {
                Text("device not open")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.mute)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.panel)
    }

    private func submit() {
        let line = input
        input = ""
        historyIndex = nil
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if history.last != line { history.append(line) }
        follow = true
        model.runConsole(line)
        inputFocused = true
    }

    private func recall(_ step: Int) -> KeyPress.Result {
        guard !history.isEmpty else { return .ignored }
        let i = max(0, min(history.count, (historyIndex ?? history.count) + step))
        historyIndex = i
        input = i < history.count ? history[i] : ""
        return .handled
    }

    static func color(_ kind: LogKind) -> Color {
        switch kind {
        case .write: Theme.control
        case .read: Theme.meterGreen
        case .event: Theme.secondary
        case .error: Theme.mute
        case .command: Theme.solo
        case .reply: Theme.text
        }
    }
}
