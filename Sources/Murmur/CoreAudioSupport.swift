import CoreAudio
import Foundation

/// Thin wrappers over the Core Audio HAL property API, which is verbose and
/// untyped in Swift.
enum CoreAudioSupport {
    /// A process that has opened an audio client somewhere in the system.
    struct Process {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningInput: Bool
    }

    struct Failure: LocalizedError {
        let what: String
        let status: OSStatus
        var errorDescription: String? { "\(what) failed (OSStatus \(status))" }
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw Failure(what: what, status: status) }
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Every process Core Audio knows about (macOS 14.2+). This is how we
    /// tell *which* app has the microphone open, not just that one does.
    static func processes() -> [Process] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.map { id in
            Process(
                objectID: id,
                pid: pid_t(bitPattern: uint32(id, kAudioProcessPropertyPID)),
                bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                isRunningInput: uint32(id, kAudioProcessPropertyIsRunningInput) != 0)
        }
    }

    /// The process object for Murmur itself, so a tap can leave it out.
    static func ownProcessObject() -> AudioObjectID? {
        let pid = ProcessInfo.processInfo.processIdentifier
        return processes().first { $0.pid == pid }?.objectID
    }

    /// Every device that has at least one input stream (a microphone).
    static func inputDevices() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { device in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }

    static func defaultOutputDeviceUID() throws -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device), "Reading the output device")
        guard let uid = string(device, kAudioDevicePropertyDeviceUID) else {
            throw Failure(what: "Reading the output device UID", status: -1)
        }
        return uid
    }

    /// The rate the default output device is actually running at.
    static func defaultOutputSampleRate() -> Double? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device) == noErr else { return nil }
        var rateAddr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &rateAddr, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    /// "Shure MV7 (USB)" style names for the diagnostics log.
    static func defaultInputDescription() -> String {
        describeDefault(kAudioHardwarePropertyDefaultInputDevice)
    }

    static func defaultOutputDescription() -> String {
        describeDefault(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func describeDefault(_ selector: AudioObjectPropertySelector) -> String {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(selector)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device) == noErr,
            device != kAudioObjectUnknown
        else { return "unknown device" }
        let name = string(device, kAudioObjectPropertyName) ?? "unnamed device"
        let transport: String
        switch uint32(device, kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBuiltIn: transport = "built-in"
        case kAudioDeviceTransportTypeUSB: transport = "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = "Bluetooth"
        case kAudioDeviceTransportTypeVirtual: transport = "virtual"
        case kAudioDeviceTransportTypeAggregate: transport = "aggregate"
        default: transport = "other"
        }
        return "\(name) (\(transport))"
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
