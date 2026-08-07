import AudioToolbox
import CoreAudio
import Foundation

struct MicrophoneDevice: Equatable, Identifiable, Sendable {
    let uid: String
    let name: String

    var id: String { uid }
}

struct AudioInputDeviceDescriptor: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let inputChannelCount: Int
}

protocol CoreAudioHardwareProviding: AnyObject {
    func inputDeviceDescriptors() -> [AudioInputDeviceDescriptor]
    func defaultInputDeviceUID() -> String?
    func setInputDevice(uid: String, on audioUnit: AudioUnit?) throws
}

protocol AudioInputDeviceProviding: AnyObject {
    func enumerateInputDevices() -> [MicrophoneDevice]
    func defaultInputDeviceUID() -> String?
    func setInputDevice(uid: String, on audioUnit: AudioUnit?) throws
}

extension AudioInputDeviceProviding {
    func defaultInputDeviceUID() -> String? { nil }
}

enum MicrophoneDeviceError: Error, Equatable {
    case deviceUnavailable
    case audioUnitUnavailable
    case routeChangeFailed(OSStatus)
}

final class CoreAudioInputDeviceProvider: AudioInputDeviceProviding {
    private let hardware: CoreAudioHardwareProviding

    init(hardware: CoreAudioHardwareProviding = SystemCoreAudioHardware()) {
        self.hardware = hardware
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
                inputChannelCount: inputChannelCount(for: deviceID)
            )
        }
    }

    func defaultInputDeviceUID() -> String? {
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
        ) == noErr,
        deviceID != kAudioObjectUnknown else {
            return nil
        }
        return stringProperty(
            for: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    func setInputDevice(uid: String, on audioUnit: AudioUnit?) throws {
        guard let audioUnit else {
            throw MicrophoneDeviceError.audioUnitUnavailable
        }
        guard let descriptor = inputDeviceDescriptors().first(where: { $0.uid == uid }) else {
            throw MicrophoneDeviceError.deviceUnavailable
        }

        var deviceID = descriptor.deviceID
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
