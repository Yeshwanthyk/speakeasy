import AVFoundation
import XCTest
@testable import Speakeasy

final class MicrophoneDeviceTests: XCTestCase {
    func testEnumerationKeepsOnlyInputDevicesAndSortsStableNames() {
        let hardware = FakeCoreAudioHardware(descriptors: [
            AudioInputDeviceDescriptor(deviceID: 1, uid: "output", name: "Speakers", inputChannelCount: 0),
            AudioInputDeviceDescriptor(deviceID: 2, uid: "z", name: "USB Mic", inputChannelCount: 1),
            AudioInputDeviceDescriptor(deviceID: 3, uid: "a", name: "Built-in Mic", inputChannelCount: 2)
        ])
        let provider = CoreAudioInputDeviceProvider(hardware: hardware)

        XCTAssertEqual(
            provider.enumerateInputDevices(),
            [
                MicrophoneDevice(uid: "a", name: "Built-in Mic"),
                MicrophoneDevice(uid: "z", name: "USB Mic")
            ]
        )
    }

    func testLatestLevelOverwritesAndBoundsSingleSnapshot() {
        let level = LatestMicrophoneLevel()
        level.publish(level: 0.25)
        let first = level.latest()
        level.publish(level: 4)
        let second = level.latest()

        XCTAssertEqual(first.normalizedLevel, 0.25)
        XCTAssertEqual(second.normalizedLevel, 1)
        XCTAssertEqual(second.sequence, first.sequence + 1)

        level.publish(level: -.infinity)
        XCTAssertEqual(level.latest().normalizedLevel, 0)
    }

    func testLevelComputesFromSamplesWithoutGrowingStorage() {
        let level = LatestMicrophoneLevel()
        let samples = [Float](repeating: 0.5, count: 4)
        samples.withUnsafeBufferPointer { level.publish(samples: $0) }

        XCTAssertEqual(level.latest().normalizedLevel, 0.5, accuracy: 0.0001)
        XCTAssertEqual(level.latest().sequence, 1)
    }
}

private final class FakeCoreAudioHardware: CoreAudioHardwareProviding {
    let descriptors: [AudioInputDeviceDescriptor]

    init(descriptors: [AudioInputDeviceDescriptor]) {
        self.descriptors = descriptors
    }

    func inputDeviceDescriptors() -> [AudioInputDeviceDescriptor] { descriptors }

    func defaultInputDeviceUID() -> String? { nil }

    func setInputDevice(uid: String, on audioUnit: AudioUnit?) throws {}
}
