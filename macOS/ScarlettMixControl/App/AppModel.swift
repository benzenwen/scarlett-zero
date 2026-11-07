import AppKit
import Observation
import UniformTypeIdentifiers

/// App state. The document is the source of truth while connected: every
/// change is rendered by `MixEngine` and handed to the device session, which
/// writes only what differs.
///
/// On connect, if the saved document renders to exactly what the device
/// reports it's kept (with its pans, links, names); otherwise the app
/// rebuilds a document from the hardware — unless you edited offline, in
/// which case it asks which side wins. Either way the chosen state is then
/// written in full once: after power-up the 18i20's matrix registers read
/// back 0 dB regardless of what the mixer is doing, so a read alone can't be
/// trusted to describe what you hear.
@MainActor @Observable
final class AppModel {
    var doc: MixerDocument {
        didSet { if doc != oldValue { documentDidChange() } }
    }
    var listen: Listen? {
        didSet { if listen != oldValue { push() } }
    }
    var status: ConnectionStatus = .searching
    /// Streaming rate from CoreAudio — the one that matters and can be set.
    var sampleRate: Int?
    var availableRates: [Int] = []
    /// Rate the mixer protocol reports (wIndex 0x2900), for diagnosis.
    var deviceReportedRate: Int?
    var documentURL: URL?
    var isEdited = false
    var editedOffline = false
    /// Hardware state that disagrees with an offline-edited document.
    var conflict: HardwareImage?
    var selectedMixBus = 0
    var notice: String?
    var confirmation: Confirmation?

    var experimental: Bool {
        didSet {
            UserDefaults.standard.set(experimental, forKey: Self.experimentalKey)
            if !experimental { meters.reset() }
            updatePolling()
        }
    }

    let meters = MeterStore()
    let console = ConsoleLog()

    @ObservationIgnored private let session = DeviceSession()
    @ObservationIgnored private let audioRate = AudioRate()
    @ObservationIgnored private var suppressPush = false
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    static let experimentalKey = "experimentalHardware"
    static let fileExtension = "scarlettmix"

    enum Confirmation: Identifiable {
        case saveToHardware, factoryDefaults, clearAll
        var id: Self { self }
    }

    /// Debug: `SCARLETT_OFFLINE=1` never opens the device and never autosaves
    /// (for UI work and screenshots without touching hardware).
    @ObservationIgnored private let offline = ProcessInfo.processInfo.environment["SCARLETT_OFFLINE"] == "1"

    init() {
        experimental = UserDefaults.standard.bool(forKey: Self.experimentalKey)
        doc = offline ? .factoryDefault : (Self.loadAutosave() ?? .factoryDefault)
        session.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        audioRate.onChange = { [weak self] rate, available in
            guard let self else { return }
            if rate != sampleRate, let rate { console.append(.event, "CoreAudio sample rate: \(rate) Hz") }
            sampleRate = rate
            availableRates = available
        }
        updatePolling()
        if offline {
            status = .disconnected
        } else {
            audioRate.start()
            session.start()
        }
    }

    func shutdown() {
        autosaveNow()
        session.stop()
    }

    // MARK: - Derived

    var isConnected: Bool { status == .connected }
    var canWrite: Bool { isConnected && conflict == nil }

    var windowTitle: String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// ADAT outputs/inputs 5–8 vanish at 88.2/96 kHz (S/MUX).
    var adatUpperAvailable: Bool { (sampleRate ?? 48_000) < 88_200 }

    // MARK: - Session events

    private func handle(_ event: SessionEvent) {
        switch event {
        case .status(let s):
            status = s
            if s != .connected { listen = nil }
            audioRate.refresh()
        case .connected(let hw, let rate):
            deviceReportedRate = rate
            adopt(hw)
        case .clock(let source, let rate):
            deviceReportedRate = rate
            if let clock = DeviceMap.Clock(rawValue: source), clock != doc.clock {
                withoutPush { doc.clock = clock }
            }
        case .meters(let frame):
            meters.ingest(frame)
        case .monitor(let m):
            guard experimental, doc.monitor.hardwareControl else { return }
            doc.monitor.levelDB = m.levelDB
            doc.monitor.dim = m.dim
            doc.monitor.mute = m.mute
        case .writeFailed(let message):
            notice = message
        case .log(let kind, let text):
            console.append(kind, text)
        }
    }

    private func adopt(_ hw: HardwareImage) {
        if MixEngine.matches(doc, hw) {
            console.append(.event, "document matches hardware — kept")
            withoutPush { doc.clock = DeviceMap.Clock(rawValue: hw.clock) ?? doc.clock }
        } else if editedOffline {
            console.append(.event, "hardware differs from offline-edited document — asking")
            conflict = hw
        } else {
            console.append(.event, "document rebuilt from hardware state")
            replaceFromHardware(hw)
        }
        push()
    }

    private func replaceFromHardware(_ hw: HardwareImage) {
        var derived = MixEngine.document(from: hw)
        // Keep names — they're software-only and harmless to carry over.
        for i in derived.inputs.indices { derived.inputs[i].name = doc.inputs[i].name }
        for m in derived.mixes.indices { derived.mixes[m].name = doc.mixes[m].name }
        withoutPush { doc = derived }
        selectedMixBus = 0
    }

    /// Conflict resolution: keep what the device has.
    func useHardwareState() {
        guard let hw = conflict else { return }
        conflict = nil
        editedOffline = false
        replaceFromHardware(hw)
        push()
    }

    /// Conflict resolution: send this document to the device.
    func sendDocumentToHardware() {
        conflict = nil
        editedOffline = false
        push()
    }

    func releaseDevice() { session.release() }
    func reconnectDevice() { session.reconnect() }

    /// Device ▸ Reload from Hardware: re-read everything and adopt it.
    func reloadFromHardware() {
        conflict = nil
        editedOffline = false
        session.reload()
    }

    func setSampleRate(_ rate: Int) {
        console.append(.command, "set CoreAudio sample rate \(rate) Hz")
        if let error = audioRate.set(rate) {
            notice = error
            console.append(.error, error)
        }
    }

    /// Debug console input, in scarlett_ctl grammar.
    func runConsole(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        console.append(.command, trimmed)
        switch trimmed {
        case "clear":
            console.clear()
        case "state":
            let hw = MixEngine.image(for: doc, listen: listen)
            console.append(.reply, "{:clock \(hw.clock) :routing \(hw.routing) :mixer-inputs \(hw.mixerInputs)}")
            console.append(.reply, "{:buses \(hw.buses)}")
            console.append(.reply, "{:matrix \(hw.matrix)}")
        case "coreaudio":
            console.append(.reply, "{:rate \(sampleRate.map(String.init) ?? "nil") :available \(availableRates) :device-reported \(deviceReportedRate.map(String.init) ?? "nil")}")
        default:
            session.execute(trimmed) { [weak self] reply in
                Task { @MainActor in self?.console.append(.reply, reply) }
            }
        }
    }

    // MARK: - Writes

    private func documentDidChange() {
        guard !suppressPush else { return }
        isEdited = true
        if !isConnected { editedOffline = true }
        if !doc.mixSlots.contains(where: { $0.bus == selectedMixBus }) {
            selectedMixBus = doc.slot(containing: selectedMixBus).bus
        }
        push()
        scheduleAutosave()
    }

    private func push() {
        guard canWrite else { return }
        session.submit(MixEngine.image(for: doc, listen: listen))
    }

    private func withoutPush(_ body: () -> Void) {
        suppressPush = true
        body()
        suppressPush = false
        scheduleAutosave()
    }

    private func updatePolling() {
        session.setPolling(.init(
            meters: experimental,
            hardwareMonitor: experimental && doc.monitor.hardwareControl,
            experimental: experimental))
    }

    func setHardwareControl(_ on: Bool) {
        doc.monitor.hardwareControl = on
        updatePolling()
    }

    func setMono(_ on: Bool) {
        doc.monitor.mono = on
        guard experimental, isConnected else { return }
        let pairs = (1...5).filter { doc.monitor.modes[($0 - 1) * 2] == .controlled }
        session.setMono(on, pairs: pairs)
    }

    // MARK: - Menu actions

    func perform(_ c: Confirmation) {
        switch c {
        case .saveToHardware:
            session.saveToFlash { [weak self] ok in
                Task { @MainActor in
                    self?.notice = ok ? "Saved to hardware." : "Save to hardware failed."
                }
            }
        case .factoryDefaults:
            load(.factoryDefault, url: nil)
        case .clearAll:
            load(.cleared, url: nil)
        }
    }

    private func load(_ newDoc: MixerDocument, url: URL?) {
        conflict = nil
        editedOffline = !isConnected
        listen = nil
        doc = newDoc
        documentURL = url
        isEdited = false
        selectedMixBus = 0
        updatePolling()
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.documentType, Self.legacyType]
        panel.message = "Open a Scarlett MixControl snapshot (.\(Self.fileExtension) or legacy .18i20)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "18i20" {
                load(try LegacySnapshot.load(data), url: nil)
                notice = "Imported \(url.lastPathComponent). Save to keep it in the new format."
            } else {
                load(try JSONDecoder().decode(MixerDocument.self, from: data), url: url)
            }
        } catch {
            notice = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func save() {
        guard let url = documentURL else { return saveAs() }
        write(to: url)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.documentType]
        panel.nameFieldStringValue = windowTitle
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            try Self.encode(doc).write(to: url, options: .atomic)
            documentURL = url
            isEdited = false
        } catch {
            notice = "Couldn't save: \(error.localizedDescription)"
        }
    }

    static let documentType = UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json
    static let legacyType = UTType(filenameExtension: "18i20", conformingTo: .xml) ?? .xml

    // MARK: - Autosave (Application Support), restores pans/links/names

    private static var autosaveURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appending(path: "Scarlett MixControl/Current.\(fileExtension)")
    }

    private static func loadAutosave() -> MixerDocument? {
        guard let url = autosaveURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MixerDocument.self, from: data)
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.autosaveNow()
        }
    }

    private func autosaveNow() {
        guard !offline, let url = Self.autosaveURL, let data = try? Self.encode(doc) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func encode(_ doc: MixerDocument) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(doc)
    }
}
