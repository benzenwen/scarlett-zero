import CoreAudio
import Foundation

/// The 18i20's sample rate belongs to CoreAudio (usbaudiod streams at the
/// device's nominal rate), not to the mixer protocol. This reads and sets
/// it exactly as Audio MIDI Setup does, and reports changes made elsewhere.
@MainActor
final class AudioRate {
    private(set) var deviceID: AudioObjectID?
    var onChange: ((_ rate: Int?, _ available: [Int]) -> Void)?

    private var listenedDevice: AudioObjectID?
    private let queue = DispatchQueue.main

    private var rateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private lazy var rateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.refresh() }
    }
    private lazy var devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.refresh() }
    }

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue, devicesListener)
        refresh()
    }

    /// Re-find the Scarlett (it comes and goes with USB) and report its rate.
    func refresh() {
        let id = Self.findScarlett()
        if id != listenedDevice {
            if let old = listenedDevice {
                AudioObjectRemovePropertyListenerBlock(old, &rateAddress, queue, rateListener)
            }
            if let id {
                AudioObjectAddPropertyListenerBlock(id, &rateAddress, queue, rateListener)
            }
            listenedDevice = id
        }
        deviceID = id
        onChange?(currentRate, availableRates)
    }

    var currentRate: Int? {
        guard let id = deviceID else { return nil }
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &rateAddress, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return Int(rate.rounded())
    }

    var availableRates: [Int] {
        guard let id = deviceID else { return [] }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.map { Int($0.mMinimum.rounded()) }
    }

    /// Returns an error description, or nil on success.
    func set(_ rate: Int) -> String? {
        guard let id = deviceID else { return "The 18i20 isn't visible to CoreAudio." }
        var value = Float64(rate)
        let status = AudioObjectSetPropertyData(id, &rateAddress, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        return status == noErr ? nil : "CoreAudio refused \(rate) Hz (OSStatus \(status))."
    }

    private static func findScarlett() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { uid(of: $0).contains("Scarlett 18i20") }
    }

    private static func uid(of id: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr, let uid else { return "" }
        return uid.takeRetainedValue() as String
    }
}
