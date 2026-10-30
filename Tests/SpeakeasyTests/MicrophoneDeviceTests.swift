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

    func testBluetoothDefaultIsReplacedByBuiltInMicrophone() {
        let devices = [
            AudioInputDeviceDescriptor(deviceID: 1, uid: "airpods", name: "AirPods", inputChannelCount: 1, transport: .bluetooth),
            AudioInputDeviceDescriptor(deviceID: 2, uid: "builtin", name: "MacBook Pro Microphone", inputChannelCount: 1, transport: .builtIn)
        ]

        XCTAssertEqual(InputRoutePolicy.systemRouteSubstitute(defaultUID: "airpods", devices: devices, avoidBluetooth: true), "builtin")
        XCTAssertNil(InputRoutePolicy.systemRouteSubstitute(defaultUID: "airpods", devices: devices, avoidBluetooth: false))
    }

    func testBluetoothLowEnergyCountsAsBluetooth() {
        let devices = [
            AudioInputDeviceDescriptor(deviceID: 1, uid: "le", name: "Headset", inputChannelCount: 1, transport: .bluetoothLE),
            AudioInputDeviceDescriptor(deviceID: 2, uid: "builtin", name: "Built-in", inputChannelCount: 1, transport: .builtIn)
        ]

        XCTAssertEqual(InputRoutePolicy.systemRouteSubstitute(defaultUID: "le", devices: devices, avoidBluetooth: true), "builtin")
    }

    func testNonBluetoothDefaultIsKept() {
        let devices = [
            AudioInputDeviceDescriptor(deviceID: 1, uid: "usb", name: "USB Mic", inputChannelCount: 1, transport: .usb),
            AudioInputDeviceDescriptor(deviceID: 2, uid: "builtin", name: "Built-in", inputChannelCount: 1, transport: .builtIn)
        ]

        XCTAssertNil(InputRoutePolicy.systemRouteSubstitute(defaultUID: "usb", devices: devices, avoidBluetooth: true))
    }

    func testBluetoothIsKeptWhenNoBuiltInMicrophoneExists() {
        // Lid-closed or desktop Macs: never substitute virtual or aggregate inputs.
        let devices = [
            AudioInputDeviceDescriptor(deviceID: 1, uid: "airpods", name: "AirPods", inputChannelCount: 1, transport: .bluetooth),
            AudioInputDeviceDescriptor(deviceID: 2, uid: "loopback", name: "Loopback", inputChannelCount: 2, transport: .virtual),
            AudioInputDeviceDescriptor(deviceID: 3, uid: "agg", name: "Aggregate", inputChannelCount: 2, transport: .aggregate),
            AudioInputDeviceDescriptor(deviceID: 4, uid: "silent", name: "Built-in Output", inputChannelCount: 0, transport: .builtIn)
        ]

        XCTAssertNil(InputRoutePolicy.systemRouteSubstitute(defaultUID: "airpods", devices: devices, avoidBluetooth: true))
    }

    func testTransportDecodesCoreAudioConstants() {
        XCTAssertEqual(AudioInputTransport(coreAudio: kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(AudioInputTransport(coreAudio: kAudioDeviceTransportTypeBluetoothLE), .bluetoothLE)
        XCTAssertEqual(AudioInputTransport(coreAudio: kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(AudioInputTransport(coreAudio: kAudioDeviceTransportTypeVirtual), .virtual)
        XCTAssertEqual(AudioInputTransport(coreAudio: kAudioDeviceTransportTypeAggregate), .aggregate)
        XCTAssertEqual(AudioInputTransport(coreAudio: kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(AudioInputTransport(coreAudio: 0), .other)
    }

    func testProviderReportsSubstituteRouteForBluetoothDefault() {
        let hardware = FakeCoreAudioHardware(
            descriptors: [
                AudioInputDeviceDescriptor(deviceID: 1, uid: "airpods", name: "AirPods", inputChannelCount: 1, transport: .bluetooth),
                AudioInputDeviceDescriptor(deviceID: 2, uid: "builtin", name: "Built-in", inputChannelCount: 1, transport: .builtIn)
            ],
            defaultUID: "airpods"
        )

        XCTAssertEqual(CoreAudioInputDeviceProvider(hardware: hardware, avoidBluetooth: { true }).systemRouteUID(), "builtin")
        XCTAssertEqual(CoreAudioInputDeviceProvider(hardware: hardware, avoidBluetooth: { false }).systemRouteUID(), "airpods")
    }

    func testAvoidBluetoothPreferenceDefaultsOn() {
        let suite = testDefaultsSuiteName("MicrophoneDeviceTests")
        defer { removeTestDefaults(suite) }
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("No defaults suite") }
        XCTAssertTrue(BluetoothMicrophonePreference.isAvoidingBluetooth(defaults: defaults))
        defaults.set(false, forKey: BluetoothMicrophonePreference.key)
        XCTAssertFalse(BluetoothMicrophonePreference.isAvoidingBluetooth(defaults: defaults))
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
    let defaultUID: String?

    init(descriptors: [AudioInputDeviceDescriptor], defaultUID: String? = nil) {
        self.descriptors = descriptors
        self.defaultUID = defaultUID
    }

    func inputDeviceDescriptors() -> [AudioInputDeviceDescriptor] { descriptors }

    func defaultInputDeviceUID() -> String? { defaultUID }

    func setInputDevice(uid: String, on audioUnit: AudioUnit?) throws {}
}
