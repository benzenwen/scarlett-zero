import Foundation

enum ConnectionStatus: Equatable, Sendable {
    case searching
    /// Not plugged in (or powered off).
    case disconnected
    /// Plugged in, but another process holds the device (Chrome WebMIDI,
    /// FocusriteControlServer, or a running `scarlett_ctl daemon`).
    case busy
    /// Released by the user so the CLI can use it.
    case released
    case connected

    var label: String {
        switch self {
        case .searching: "Searching"
        case .disconnected: "Disconnected"
        case .busy: "In Use"
        case .released: "Released"
        case .connected: "Connected"
        }
    }
}

/// Linear levels 0…1 (12-bit device value / 4095), indexed by source id
/// (0–37) and by mix bus (0–7).
struct MeterFrame: Sendable {
    var sources = [Float](repeating: 0, count: 38)
    var mixes = [Float](repeating: 0, count: DeviceMap.mixBusCount)
}

struct HardwareMonitor: Equatable, Sendable {
    var levelDB: Double
    var mute: Bool
    var dim: Bool
}

enum SessionEvent: Sendable {
    case status(ConnectionStatus)
    case connected(HardwareImage, sampleRate: Int)
    case clock(source: Int, sampleRate: Int)
    case meters(MeterFrame)
    case monitor(HardwareMonitor)
    case writeFailed(String)
    case log(LogKind, String)
}

enum LogKind: String, Sendable, CaseIterable {
    case write, read, event, error, command, reply
}

/// Owns the IOKit handle. All device I/O happens on one serial queue, which
/// honours the brief's operational rules: open once and hold the handle,
/// never re-open in a tight loop, never touch matrix node ≥ 144.
///
/// Writes are declarative: callers `submit` the whole desired
/// `HardwareImage`; the session diffs against what it last wrote and sends
/// only the changes, so a fader drag coalesces naturally (latest wins).
final class DeviceSession: @unchecked Sendable {
    struct Polling: Equatable, Sendable {
        var meters = false
        var hardwareMonitor = false
        var experimental = false
    }

    var onEvent: (@Sendable (SessionEvent) -> Void)?

    private let queue = DispatchQueue(label: "scarlett.device", qos: .userInteractive)
    private var device: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var tick = -1
    private var autoConnect = true
    private var status: ConnectionStatus = .searching
    private var polling = Polling()

    private var written: HardwareImage?
    /// Set after a full read: the next flush writes everything, not just the
    /// diff. Matrix registers read 0 dB after power-up whatever the DSP is
    /// doing, so `written` only becomes true once we've written it ourselves.
    private var resyncPending = false
    private var desired: HardwareImage?
    private var flushPending = false
    private var readFailures = 0
    private var lastClock: (Int, Int) = (0, 0)
    private var lastMonitor: HardwareMonitor?
    private var meterFailures = 0
    private var metersSeen = false

    private static let tickInterval: DispatchTimeInterval = .milliseconds(50)

    func start() {
        queue.async { [self] in
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.tickInterval)
            t.setEventHandler { [weak self] in self?.onTick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            close()
        }
    }

    func setPolling(_ p: Polling) {
        queue.async { [self] in
            polling = p
            meterFailures = 0
            metersSeen = false
            if !p.hardwareMonitor { lastMonitor = nil }
        }
    }

    /// Declare the state the device should be in.
    func submit(_ image: HardwareImage) {
        queue.async { [self] in
            desired = image
            guard !flushPending else { return }
            flushPending = true
            // Coalesce bursts (fader drags) into one pass per ~10 ms.
            queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
                flushPending = false
                flush()
            }
        }
    }

    /// Drop the handle so `scarlett_ctl` can use the device.
    func release() {
        queue.async { [self] in
            autoConnect = false
            close()
            publish(.released)
        }
    }

    func reconnect() {
        queue.async { [self] in
            autoConnect = true
            close()
            publish(.searching)
            tick = -1   // attempt on next tick
        }
    }

    /// Re-read everything from the device and hand it to the app as if newly
    /// connected (Device ▸ Reload from Hardware).
    func reload() {
        queue.async { [self] in
            guard let device, let image = readImage(device) else {
                log(.error, "reload failed: device not open")
                return
            }
            written = image
            resyncPending = true
            desired = nil
            let rate = Int(sc_read_sample_rate(device))
            log(.read, "reloaded full state from device")
            onEvent?(.connected(image, sampleRate: rate))
        }
    }

    /// Debug console: run one line of scarlett_ctl grammar against the open
    /// handle and reply with the same single-line EDN the CLI prints.
    func execute(_ line: String, completion: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            let argv = line.split(whereSeparator: \.isWhitespace).map(String.init)
            completion(run(argv))
        }
    }

    /// EXPERIMENTAL: persist state to the unit's flash.
    func saveToFlash(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard let device else { return completion(false) }
            completion(sc_save_to_flash(device) == kIOReturnSuccess)
        }
    }

    /// EXPERIMENTAL: hardware mono-sum per analog output pair (1…5).
    func setMono(_ on: Bool, pairs: [Int]) {
        queue.async { [self] in
            guard let device else { return }
            for pair in 1...5 {
                _ = sc_write_monitor_mono(device, Int32(pair), (on && pairs.contains(pair)) ? 1 : 0)
            }
        }
    }

    // MARK: - Queue-confined

    private func publish(_ s: ConnectionStatus) {
        guard s != status else { return }
        status = s
        log(s == .busy ? .error : .event, "device \(s.label.lowercased())")
        onEvent?(.status(s))
    }

    private func log(_ kind: LogKind, _ text: String) {
        onEvent?(.log(kind, text))
    }

    private static func hex(_ rc: IOReturn) -> String { "0x" + String(UInt32(bitPattern: rc), radix: 16) }

    private func onTick() {
        tick += 1
        guard let device else {
            // Probe for the device once a second; attempt to open at most
            // every two seconds so we never hammer IOKit.
            guard autoConnect, tick % 20 == 0 || tick == 0 else { return }
            tryOpen()
            return
        }

        if tick % 40 == 0 { pollClock(device) }
        if polling.meters, meterFailures < 20 { pollMeters(device) }
        if polling.hardwareMonitor, tick % 2 == 0 { pollMonitor(device) }
    }

    private func tryOpen() {
        guard sc_present() != 0 else {
            publish(.disconnected)
            return
        }
        if status == .busy, tick % 40 != 0 { return }

        var handle: OpaquePointer?
        let rc = sc_open(&handle)
        guard rc == SC_OK, let handle else {
            publish(rc == SC_ERR_BUSY ? .busy : .disconnected)
            return
        }
        device = handle
        readFailures = 0
        guard let image = readImage(handle) else {
            close()
            publish(.busy)
            return
        }
        written = image
        resyncPending = true
        desired = nil
        let rate = Int(sc_read_sample_rate(handle))
        lastClock = (image.clock, rate)
        log(.read, "read full state: clock \(image.clock), device rate \(rate), 20 routes, 18 mixer inputs, 144 matrix nodes, 21 buses")
        publish(.connected)
        onEvent?(.connected(image, sampleRate: rate))
    }

    private func close() {
        if let device { sc_close(device) }
        device = nil
        written = nil
        lastMonitor = nil
    }

    private func readImage(_ d: OpaquePointer) -> HardwareImage? {
        var hw = HardwareImage()
        let clock = Int(sc_read_clock_source(d))
        guard clock > 0 else { return nil }
        hw.clock = clock
        for o in 0..<DeviceMap.outputCount {
            let v = Int(sc_read_route(d, Int32(o)))
            guard v >= 0 else { return nil }
            hw.routing[o] = v
        }
        for s in 0..<DeviceMap.mixerInputCount {
            let v = Int(sc_read_mixer_input(d, Int32(s)))
            guard v >= 0 else { return nil }
            hw.mixerInputs[s] = v
        }
        for n in 0..<DeviceMap.matrixNodeCount {   // 0…143, never beyond
            let v = sc_read_matrix_gain(d, Int32(n))
            guard v != SC_READ_FAIL_GAIN else { return nil }
            hw.matrix[n] = Int16(truncatingIfNeeded: v)
        }
        for b in 0..<DeviceMap.busCount {
            let v = sc_read_bus_volume(d, Int32(b))
            guard v != -9999 else { return nil }
            hw.buses[b] = Int16(truncatingIfNeeded: v)
        }
        return hw
    }

    private func flush() {
        guard let device, var w = written, let d = desired else { return }
        var failure: String?

        // Each write is logged in scarlett_ctl grammar, so it can be replayed.
        func check(_ rc: IOReturn, _ what: String, _ cmd: String) -> Bool {
            if rc == kIOReturnSuccess {
                log(.write, cmd)
                return true
            }
            log(.error, "\(cmd)  → failed \(Self.hex(rc))")
            failure = failure ?? "\(what) failed (\(Self.hex(rc)))"
            return false
        }

        let all = resyncPending
        if all { log(.event, "writing full state once — device read-back isn't live until written") }
        if d.clock != w.clock, check(sc_write_clock_source(device, Int32(d.clock)), "Clock source", "clock \(d.clock)") {
            w.clock = d.clock
        }
        for o in 0..<DeviceMap.outputCount where all || d.routing[o] != w.routing[o] {
            if check(sc_write_route(device, Int32(o), Int32(d.routing[o])), "Routing", "route \(o) \(d.routing[o])") {
                w.routing[o] = d.routing[o]
            }
        }
        for s in 0..<DeviceMap.mixerInputCount where all || d.mixerInputs[s] != w.mixerInputs[s] {
            if check(sc_write_mixer_input(device, Int32(s), Int32(d.mixerInputs[s])), "Mixer input", "mixer \(s) \(d.mixerInputs[s])") {
                w.mixerInputs[s] = d.mixerInputs[s]
            }
        }
        for n in 0..<DeviceMap.matrixNodeCount where all || d.matrix[n] != w.matrix[n] {
            if check(sc_write_matrix_gain(device, Int32(n), d.matrix[n]), "Mixer gain", "matrix \(n) \(d.matrix[n])") {
                w.matrix[n] = d.matrix[n]
            }
        }
        for b in 0..<DeviceMap.busCount where all || d.buses[b] != w.buses[b] {
            if check(sc_write_bus_volume(device, Int32(b), d.buses[b]), "Output volume", "bus \(b) \(d.buses[b])") {
                w.buses[b] = d.buses[b]
            }
        }
        written = w
        if failure == nil { resyncPending = false }
        if let failure { onEvent?(.writeFailed(failure)) }
    }

    private func pollClock(_ d: OpaquePointer) {
        let source = Int(sc_read_clock_source(d))
        let rate = Int(sc_read_sample_rate(d))
        guard source > 0, rate > 0 else {
            readFailures += 1
            if readFailures >= 3 {
                close()
                publish(.disconnected)
            }
            return
        }
        readFailures = 0
        if (source, rate) != lastClock {
            lastClock = (source, rate)
            log(.read, "clock changed: source \(source), device rate \(rate)")
            onEvent?(.clock(source: source, sampleRate: rate))
        }
    }

    private func pollMeters(_ d: OpaquePointer) {
        var inputs = [UInt16](repeating: 0, count: 18)
        var daw = [UInt16](repeating: 0, count: 20)
        var mixes = [UInt16](repeating: 0, count: 8)
        let ok = inputs.withUnsafeMutableBufferPointer { sc_read_meters_inputs(d, $0.baseAddress) } == 18
            && daw.withUnsafeMutableBufferPointer { sc_read_meters_daw(d, $0.baseAddress) } == 20
            && mixes.withUnsafeMutableBufferPointer { sc_read_meters_mixes(d, $0.baseAddress) } == 8
        guard ok else {
            meterFailures += 1   // stop asking after repeated failures
            if meterFailures == 1 { log(.error, "meter read failed") }
            if meterFailures == 20 { log(.error, "meter reads failed 20× in a row — polling stopped (toggle experimental to retry)") }
            return
        }
        if !metersSeen {
            metersSeen = true
            log(.read, "meters responding: in \(inputs) daw \(daw) mix \(mixes)")
        }
        meterFailures = 0
        var frame = MeterFrame()
        for (i, v) in daw.enumerated() { frame.sources[SourceID.daw0 + i] = Float(v) / 4095 }
        for (i, v) in inputs.enumerated() { frame.sources[SourceID.analog0 + i] = Float(v) / 4095 }
        for (i, v) in mixes.enumerated() { frame.mixes[i] = Float(v) / 4095 }
        onEvent?(.meters(frame))
    }

    private func pollMonitor(_ d: OpaquePointer) {
        var s = sc_monitor_state()
        guard sc_read_monitor_state(d, &s) == 0 else { return }
        let m = HardwareMonitor(levelDB: -Double(s.knob_atten_db), mute: s.mute != 0, dim: s.dim != 0)
        if m != lastMonitor {
            lastMonitor = m
            log(.read, "front panel: knob \(Int(m.levelDB)) dB, mute \(m.mute), dim \(m.dim)")
            onEvent?(.monitor(m))
        }
    }
}

// MARK: - Debug console commands (scarlett_ctl grammar)

private extension DeviceSession {
    func edn(_ pairs: [(Int, Int)]) -> String {
        "{" + pairs.map { "\($0.0) \($0.1)" }.joined(separator: " ") + "}"
    }

    static func parseInt(_ s: String) -> Int? {
        s.lowercased().hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
    }

    func run(_ argv: [String]) -> String {
        guard let cmd = argv.first else { return "" }
        let args = argv.dropFirst().compactMap(Self.parseInt)
        if cmd == "help" { return Self.help }
        guard let d = device else {
            return cmd == "ping" ? "{:ok true :device-open false}" : "{:error \"device not open\"}"
        }
        switch (cmd, args.count) {
        case ("ping", _):
            return "{:ok true :device-open true}"
        case ("rate", _):
            return "{:rate \(sc_read_sample_rate(d))}"
        case ("clock", 0):
            return "{:source \(sc_read_clock_source(d)) :rate \(sc_read_sample_rate(d))}"
        case ("clock", _):
            let rc = sc_write_clock_source(d, Int32(args[0]))
            guard rc == kIOReturnSuccess else { return "{:error \"write failed\" :code \(Self.hex(rc))}" }
            let v = Int(sc_read_clock_source(d))
            written?.clock = v
            return "{:ok true :source \(v)}"
        case ("route", 0):
            return edn((0..<DeviceMap.outputCount).map { ($0, Int(sc_read_route(d, Int32($0)))) })
        case ("route", _) where args.count >= 2:
            guard (0..<DeviceMap.outputCount).contains(args[0]) else { return "{:error \"output index must be 0-19\"}" }
            let before = sc_read_route(d, Int32(args[0]))
            let rc = sc_write_route(d, Int32(args[0]), Int32(args[1]))
            guard rc == kIOReturnSuccess else { return "{:error \"write failed\" :code \(Self.hex(rc))}" }
            let after = Int(sc_read_route(d, Int32(args[0])))
            written?.routing[args[0]] = after
            return "{:ok true :output \(args[0]) :before \(before) :after \(after)}"
        case ("mixer", 0):
            return edn((0..<DeviceMap.mixerInputCount).map { ($0, Int(sc_read_mixer_input(d, Int32($0)))) })
        case ("mixer", _) where args.count >= 2:
            guard (0..<DeviceMap.mixerInputCount).contains(args[0]) else { return "{:error \"mixer slot must be 0-17\"}" }
            let before = sc_read_mixer_input(d, Int32(args[0]))
            let rc = sc_write_mixer_input(d, Int32(args[0]), Int32(args[1]))
            guard rc == kIOReturnSuccess else { return "{:error \"write failed\" :code \(Self.hex(rc))}" }
            let after = Int(sc_read_mixer_input(d, Int32(args[0])))
            written?.mixerInputs[args[0]] = after
            return "{:ok true :slot \(args[0]) :before \(before) :after \(after)}"
        case ("bus", 0):
            return "{" + (0..<DeviceMap.busCount).map {
                "\($0) {:volume \(sc_read_bus_volume(d, Int32($0))) :mute \(sc_read_bus_mute(d, Int32($0)))}"
            }.joined(separator: " ") + "}"
        case ("bus", _) where args.count >= 2:
            guard (0..<DeviceMap.busCount).contains(args[0]) else { return "{:error \"bus index must be 0-20\"}" }
            guard let raw = Int16(exactly: args[1]) else { return "{:error \"volume raw must fit in int16\"}" }
            let before = sc_read_bus_volume(d, Int32(args[0]))
            let rc = sc_write_bus_volume(d, Int32(args[0]), raw)
            guard rc == kIOReturnSuccess else { return "{:error \"write failed\" :code \(Self.hex(rc))}" }
            let after = sc_read_bus_volume(d, Int32(args[0]))
            written?.buses[args[0]] = Int16(truncatingIfNeeded: after)
            return "{:ok true :bus \(args[0]) :before \(before) :after \(after)}"
        case ("matrix", 0):
            return edn((0..<DeviceMap.matrixNodeCount).compactMap {
                let v = Int(sc_read_matrix_gain(d, Int32($0)))
                return v == Int(Gain.silenceRaw) ? nil : ($0, v)
            })
        case ("matrix", _) where args.count >= 2:
            guard (0..<DeviceMap.matrixNodeCount).contains(args[0]) else { return "{:error \"matrix node must be 0-143\"}" }
            guard let raw = Int16(exactly: args[1]) else { return "{:error \"gain raw must fit in int16\"}" }
            let before = sc_read_matrix_gain(d, Int32(args[0]))
            let rc = sc_write_matrix_gain(d, Int32(args[0]), raw)
            guard rc == kIOReturnSuccess else { return "{:error \"write failed\" :code \(Self.hex(rc))}" }
            let after = sc_read_matrix_gain(d, Int32(args[0]))
            written?.matrix[args[0]] = Int16(truncatingIfNeeded: after)
            return "{:ok true :node \(args[0]) :before \(before) :after \(after)}"
        case ("dump", _):
            return ["clock", "route", "mixer", "bus", "matrix"].map { "\($0) \(run([$0]))" }.joined(separator: "\n")
        case ("meters", _):
            guard polling.experimental else { return "{:error \"meters are experimental — enable in Settings\"}" }
            var i = [UInt16](repeating: 0, count: 18), w = [UInt16](repeating: 0, count: 20), m = [UInt16](repeating: 0, count: 8)
            let a = i.withUnsafeMutableBufferPointer { sc_read_meters_inputs(d, $0.baseAddress) }
            let b = w.withUnsafeMutableBufferPointer { sc_read_meters_daw(d, $0.baseAddress) }
            let c = m.withUnsafeMutableBufferPointer { sc_read_meters_mixes(d, $0.baseAddress) }
            return "{:inputs \(a < 0 ? "nil" : "\(i)") :daw \(b < 0 ? "nil" : "\(w)") :mixes \(c < 0 ? "nil" : "\(m)")}"
        case ("monitor", _):
            guard polling.experimental else { return "{:error \"monitor state is experimental — enable in Settings\"}" }
            var st = sc_monitor_state()
            guard sc_read_monitor_state(d, &st) == 0 else { return "{:error \"read failed\"}" }
            return "{:knob-atten-db \(st.knob_atten_db) :mute \(st.mute != 0) :dim \(st.dim != 0)}"
        case ("save", _):
            return "{:error \"use File ▸ Save to Hardware… (experimental, confirmed)\"}"
        default:
            return "{:error \"unknown command or missing args\" :cmd \"\(argv.joined(separator: " "))\"}  (try: help)"
        }
    }

    static let help = """
    scarlett_ctl grammar, run against the app's open handle (raw values, EDN replies):
      ping | rate | dump
      clock [1|2|3]            1 internal, 2 S/PDIF, 3 ADAT
      route [OUT SRC]          OUT 0–19, SRC source id (46 = Off)
      mixer [SLOT SRC]         SLOT 0–17
      bus [BUS RAW]            BUS 0–20, RAW int16 (1/256 dB; -32768 = −∞)
      matrix [NODE RAW]        NODE 0–143 (= slot*8 + mix bus)
      meters | monitor         experimental reads (Settings)
    Console writes bypass the document — use Device ▸ Reload from Hardware to adopt them.
    """
}
