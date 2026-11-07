import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            if model.conflict != nil { ConflictBanner() }
            if model.status == .busy { BusyBanner() }
            MixerPanel()
                .frame(minHeight: 430)
            HStack(alignment: .top, spacing: 10) {
                RoutingPanel()
                DevicePanel()
                MonitorPanel()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Theme.window)
        .frame(minWidth: 1240, minHeight: 820)
        .navigationTitle(model.windowTitle)
        .navigationSubtitle(model.isEdited ? "Edited" : "")
        .overlay(alignment: .bottom) { NoticeToast() }
        .alert(item: $model.confirmation) { c in
            switch c {
            case .saveToHardware:
                Alert(title: Text("Save to Hardware?"),
                      message: Text("Writes the current mixer, routing and monitor state to the 18i20's flash memory so it works standalone. This uses a command recovered from MixControl that hasn't been verified on this unit."),
                      primaryButton: .destructive(Text("Save to Hardware")) { model.perform(.saveToHardware) },
                      secondaryButton: .cancel())
            case .factoryDefaults:
                Alert(title: Text("Restore Factory Defaults?"),
                      message: Text("Resets mixer, routing and monitor settings to MixControl's defaults and sends them to the device."),
                      primaryButton: .destructive(Text("Restore")) { model.perform(.factoryDefaults) },
                      secondaryButton: .cancel())
            case .clearAll:
                Alert(title: Text("Clear All Settings?"),
                      message: Text("Routes every output to Off and silences every mix. You will hear nothing until you set things up again."),
                      primaryButton: .destructive(Text("Clear")) { model.perform(.clearAll) },
                      secondaryButton: .cancel())
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ConflictBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Theme.solo)
            VStack(alignment: .leading, spacing: 1) {
                Text("The 18i20 has different settings from this document.")
                    .font(.system(size: 12, weight: .semibold))
                Text("You edited while it was disconnected. Nothing has been written yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Use Hardware Settings") { model.useHardwareState() }
            Button("Send This Document") { model.sendDocumentToHardware() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Theme.solo.opacity(0.09), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.solo.opacity(0.4)))
    }
}

private struct BusyBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").foregroundStyle(Theme.solo)
            VStack(alignment: .leading, spacing: 1) {
                Text("Another app is holding the 18i20.")
                    .font(.system(size: 12, weight: .semibold))
                Text("Quit Google Chrome (WebMIDI), disable FocusriteControlServer, or stop any running scarlett_ctl daemon. Retrying automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.solo.opacity(0.09), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.solo.opacity(0.4)))
    }
}

private struct NoticeToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: 10) {
                Text(notice).font(.system(size: 12, weight: .medium))
                Button {
                    model.notice = nil
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: .capsule)
            .overlay(Capsule().strokeBorder(Theme.strokeStrong))
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: notice) {
                try? await Task.sleep(for: .seconds(6))
                model.notice = nil
            }
        }
    }
}
