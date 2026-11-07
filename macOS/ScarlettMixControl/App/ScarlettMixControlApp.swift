import SwiftUI

@main
struct ScarlettMixControlApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        // One window, like MixControl: a second window would fight the first
        // for the device's single USB user client.
        Window("Scarlett MixControl", id: "main") {
            MainWindow()
                .environment(model)
                .onAppear {
                    delegate.model = model
                    #if DEBUG
                    DebugSnapshot.scheduleIfRequested(model: model)
                    #endif
                }
        }
        .defaultSize(width: 1480, height: 900)
        .commands { AppCommands(model: model) }

        Window("Debug Console", id: "console") {
            ConsoleView()
                .environment(model)
        }
        .defaultSize(width: 820, height: 480)
        .keyboardShortcut("d", modifiers: [.command, .option])

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.open() }
                .keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }
                .keyboardShortcut("s")
            Button("Save As…") { model.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Save to Hardware…") { model.confirmation = .saveToHardware }
                .disabled(!(model.experimental && model.isConnected))
            Button("Restore Factory Defaults…") { model.confirmation = .factoryDefaults }
            Button("Clear All Settings…") { model.confirmation = .clearAll }
        }
        CommandMenu("Device") {
            if model.status == .released {
                Button("Reconnect") { model.reconnectDevice() }
            } else {
                Button("Release for Command Line") { model.releaseDevice() }
                    .disabled(!model.isConnected)
            }
            Button("Reload from Hardware") { model.reloadFromHardware() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.isConnected)
            Divider()
            Button("Debug Console") { openWindow(id: "console") }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Divider()
            Button("Stop Listening (PFL)") { model.listen = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(model.listen == nil)
        }
    }
}
