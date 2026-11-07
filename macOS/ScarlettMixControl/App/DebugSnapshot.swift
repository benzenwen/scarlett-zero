#if DEBUG
import AppKit

/// Debug aid: `SCARLETT_SNAPSHOT=/path/out.png` renders the main window to a
/// PNG a few seconds after launch and quits. Works without screen-recording
/// permission because it draws the view hierarchy itself.
/// `SCARLETT_SNAPSHOT_MIX=n` selects a mix tab first;
/// `SCARLETT_SNAPSHOT_SETTINGS=1` captures the Settings window instead.
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["SCARLETT_SNAPSHOT"] else { return }
        if let mix = env["SCARLETT_SNAPSHOT_MIX"].flatMap(Int.init) { model.selectedMixBus = mix }
        let settings = env["SCARLETT_SNAPSHOT_SETTINGS"] == "1"
        if settings {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        let isMain: (NSWindow) -> Bool = { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if !settings, let w = NSApp.windows.first(where: isMain) {
                w.setContentSize(NSSize(width: 1480, height: 880))
            }
            try? await Task.sleep(for: .seconds(3))
            let window = settings
                ? NSApp.windows.first { $0.isVisible && !isMain($0) && $0.contentView != nil && $0.frame.width < 900 }
                : NSApp.windows.first(where: isMain)
            if let view = window?.contentView?.superview ?? window?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                do {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                } catch {
                    FileHandle.standardError.write(Data("snapshot: \(error)\n".utf8))
                }
            } else {
                let seen = NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") \($0.title) visible=\($0.isVisible) \(Int($0.frame.width))" }
                FileHandle.standardError.write(Data("snapshot: no window to capture; windows: \(seen)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
