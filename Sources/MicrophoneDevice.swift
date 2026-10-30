import AudioToolbox
import CoreAudio
import Foundation

struct MicrophoneDevice: Equatable, Identifiable, Sendable {
    let uid: String
    let name: String

    var id: String { uid }
}

/// How a device connects, from `kAudioDevicePropertyTransportType`.
enum AudioInputTransport: Equatable, Sendable {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case virtual
    case aggregate
    case other

    init(coreAudio transport: UInt32) {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
        case kAudioDeviceTransportTypeBluetooth: self = .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE: self = .bluetoothLE
        case kAudioDeviceTransportTypeUSB: self = .usb
        case kAudioDeviceTransportTypeVirtual: self = .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
        default: self = .other
        }
    }

    var isBluetooth: Bool { self == .bluetooth || self == .bluetoothLE }
}

struct AudioInputDeviceDescriptor: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let inputChannelCount: Int
    var transport: AudioInputTransport = .other
}

/// Opening a Bluetooth headset's microphone switches it to the hands-free
/// profile: input drops to narrowband and the user's audio sounds like a
/// phone call for as long as the engine runs. When the user has not picked a
/// microphone, the system route uses the built-in one instead.
enum InputRoutePolicy {
    static func systemRouteSubstitute(
        defaultUID: String?,
        devices: [AudioInputDeviceDescriptor],
        avoidBluetooth: Bool
    ) -> String? {
        guard avoidBluetooth,
              let defaultUID,
              let current = devices.first(where: { $0.uid == defaultUID }),
              current.transport.isBluetooth else {
            return nil
        }
        // Never stand in with virtual or aggregate inputs; they may be silent.
        return devices.first { $0.transport == .builtIn && $0.inputChannelCount > 0 }?.uid
    }
}

enum BluetoothMicrophonePreference {
    static let key = "avoidBluetoothMicrophone"

    static func isAvoidingBluetooth(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}

protocol CoreAudioHardwareProviding: AnyObject {
    func inputDeviceDescriptors() -> [AudioInputDeviceDescriptor]
    func defaultInputDeviceUID() -> String?
    func setInputDevice(uid: String, on audioUnit: AudioUnit?) throws
    func setDefaultInputDevice(on audioUnit: AudioUnit?) throws
}

extension CoreAudioHardwareProviding {
    func setDefaultInputDevice(on audioUnit: AudioUnit?) throws {
        guard let uid = defaultInputDeviceUID() else { throw MicrophoneDeviceError.deviceUnavailable }
        try setInputDevice(uid: uid, on: audioUnit)
    }
}

protocol AudioInputDeviceProviding: AnyObject {
    func enumerateInputDevices() -> [MicrophoneDevice]
    func defaultInputDeviceUID() -> String?
    func setInputDevice(uid: String, on audioUnit: AudioUnit?) throws
    func setDefaultInputDevice(on audioUnit: AudioUnit?) throws
}

extension AudioInputDeviceProviding {
    func defaultInputDeviceUID() -> String? { nil }
    func setDefaultInputDevice(on audioUnit: AudioUnit?) throws {
        if let uid = defaultInputDeviceUID() { try setInputDevice(uid: uid, on: audioUnit) }
    }
}

enum MicrophoneDeviceError: Error, Equatable {
    case deviceUnavailable
    case audioUnitUnavailable
    case routeChangeFailed(OSStatus)
}

final class CoreAudioInputDeviceProvider: AudioInputDeviceProviding {
    private let hardware: CoreAudioHardwareProviding
    private let avoidBluetooth: () -> Bool

    init(
        hardware: CoreAudioHardwareProviding = SystemCoreAudioHardware(),
        avoidBluetooth: @escaping () -> Bool = { BluetoothMicrophonePreference.isAvoidingBluetooth() }
    ) {
        self.hardware = hardware
        self.avoidBluetooth = avoidBluetooth
    }

    /// The device "System Default" records from after the Bluetooth policy.
    func systemRouteUID() -> String? {
        let defaultUID = hardware.defaultInputDeviceUID()
        return InputRoutePolicy.systemRouteSubstitute(
            defaultUID: defaultUID,
            devices: hardware.inputDeviceDescriptors(),
            avoidBluetooth: avoidBluetooth()
        ) ?? defaultUID
    }

    func enumerateInputDevices() -> [MicrophoneDevice] {
        hardware.inputDeviceDescriptors()
            .filter { $0.inputChannelCount > 0 && !$0.uid.isEmpty && !$0.name.isEmpty }
            .map { MicrophoneDevice(uid: $0.uid, name: $0.name) }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    || (lhs.name == rhs.name && lhs.uid < rhs.uid)
            }
    }

    func defaultInputDeviceUID() -> String? {
        hardware.defaultInputDeviceUID()
    }

    func setInputDevice(uid: String, on audioUnit: AudioUnit?) throws {
        guard enumerateInputDevices().contains(where: { $0.uid == uid }) else {
            throw MicrophoneDeviceError.deviceUnavailable
        }
        try hardware.setInputDevice(uid: uid, on: audioUnit)
    }

    func setDefaultInputDevice(on audioUnit: AudioUnit?) throws {
        guard audioUnit != nil else { return } // Test input nodes have no CoreAudio unit.
        if let substitute = InputRoutePolicy.systemRouteSubstitute(
            defaultUID: hardware.defaultInputDeviceUID(),
            devices: hardware.inputDeviceDescriptors(),
            avoidBluetooth: avoidBluetooth()
        ) {
            try hardware.setInputDevice(uid: substitute, on: audioUnit)
            return
        }
        try hardware.setDefaultInputDevice(on: audioUnit)
    }
}

private final class SystemCoreAudioHardware: CoreAudioHardwareProviding {
    func inputDeviceDescriptors() -> [AudioInputDeviceDescriptor] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard let uid = stringProperty(
                for: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            ),
            let name = stringProperty(
                for: deviceID,
                selector: kAudioDevicePropertyDeviceNameCFString,
                scope: kAudioObjectPropertyScopeGlobal
            ) else {
                return nil
            }

            return AudioInputDeviceDescriptor(
                deviceID: deviceID,
                uid: uid,
                name: name,
                inputChannelCount: inputChannelCount(for: deviceID),
                transport: AudioInputTransport(coreAudio: transportType(for: deviceID))
            )
        }
    }

    func defaultInputDeviceUID() -> String? {
        let deviceID = defaultInputDeviceID()
        guard deviceID != kAudioObjectUnknown else { return nil }
        return stringProperty(
            for: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private func defaultInputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr else { return kAudioObjectUnknown }
        return deviceID
    }

    func setDefaultInputDevice(on audioUnit: AudioUnit?) throws {
        try setDevice(defaultInputDeviceID(), on: audioUnit)
    }

    func setInputDevice(uid: String, on audioUnit: AudioUnit?) throws {
        guard let audioUnit else {
            throw MicrophoneDeviceError.audioUnitUnavailable
        }
        guard let descriptor = inputDeviceDescriptors().first(where: { $0.uid == uid }) else {
            throw MicrophoneDeviceError.deviceUnavailable
        }

        try setDevice(descriptor.deviceID, on: audioUnit)
    }

    private func setDevice(_ id: AudioDeviceID, on audioUnit: AudioUnit?) throws {
        guard let audioUnit else { throw MicrophoneDeviceError.audioUnitUnavailable }
        guard id != kAudioObjectUnknown else { throw MicrophoneDeviceError.deviceUnavailable }
        var deviceID = id
        let status = withUnsafeBytes(of: &deviceID) { bytes in
            AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                bytes.baseAddress,
                UInt32(bytes.count)
            )
        }
        guard status == noErr else {
            throw MicrophoneDeviceError.routeChangeFailed(status)
        }
    }

    private func stringProperty(
        for deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }

    private func transportType(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transport) == noErr else {
            return 0
        }
        return transport
    }

    private func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        var data = [UInt8](repeating: 0, count: Int(dataSize))
        let status = data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return OSStatus(kAudioHardwareBadPropertySizeError)
            }
            return AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                baseAddress
            )
        }
        guard status == noErr else { return 0 }
        return data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            let bufferList = UnsafeMutableAudioBufferListPointer(
                baseAddress.assumingMemoryBound(to: AudioBufferList.self)
            )
            return bufferList.reduce(0) { result, buffer in
                result + Int(buffer.mNumberChannels)
            }
        }
    }
}

struct MicrophoneLevelSnapshot: Equatable, Sendable {
    let normalizedLevel: Float
    let sequence: UInt64
}

final class LatestMicrophoneLevel: @unchecked Sendable {
    private let lock = UnfairLock()
    private var snapshot = MicrophoneLevelSnapshot(normalizedLevel: 0, sequence: 0)

    func publish(samples: UnsafeBufferPointer<Float>) {
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        let rms = samples.isEmpty ? 0 : sqrt(sumOfSquares / Float(samples.count))
        publish(level: rms)
    }

    func publish(level: Float) {
        let boundedLevel = level.isFinite ? min(max(level, 0), 1) : 0
        lock.withLock {
            snapshot = MicrophoneLevelSnapshot(
                normalizedLevel: boundedLevel,
                sequence: snapshot.sequence &+ 1
            )
        }
    }

    func latest() -> MicrophoneLevelSnapshot {
        lock.withLock { snapshot }
    }
}

enum MicrophoneSelectionStore {
    private static let key = "selectedMicrophoneUID"

    static func selectedUID(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    static func persist(uid: String?, defaults: UserDefaults = .standard) {
        if let uid {
            defaults.set(uid, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
