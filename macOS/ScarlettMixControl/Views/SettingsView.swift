import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Enable experimental hardware features", isOn: $model.experimental)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("These use USB commands recovered from the MixControl 1.10.6 app that haven't been verified on this unit yet:")
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Level meters (polled 20× per second)", systemImage: "chart.bar.fill")
                        Label("Mono monitor sum", systemImage: "circle.lefthalf.filled")
                        Label("File ▸ Save to Hardware (writes flash)", systemImage: "memorychip")
                    }
                    .padding(.leading, 4)
                    Text("Everything else — routing, mixer, monitor level, dim, mutes and pad — uses verified commands and works with this off.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize()
        .preferredColorScheme(.dark)
    }
}
