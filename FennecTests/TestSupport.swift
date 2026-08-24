import CoreAudio
import Foundation

/// Shared fixtures. Kept deliberately small: these tests exercise pure logic
/// only, so nothing here touches Core Audio, the helper, or the user's disk
/// outside a temporary directory.
enum Fixture {
    static let builtInSpeakers = AudioDeviceSnapshot(
        id: 61,
        name: "MacBook Pro Speakers",
        uid: "BuiltInSpeakerDevice",
        sampleRate: 48_000,
        transport: .builtIn,
        isAlive: true
    )

    static let bluetoothHeadphones = AudioDeviceSnapshot(
        id: 84,
        name: "AirPods Max",
        uid: "00-11-22-33",
        sampleRate: 48_000,
        transport: .bluetooth,
        isAlive: true
    )

    static func batch(
        at date: Date,
        overloads: UInt64 = 0,
        abnormalStops: UInt64 = 0,
        defaultOutputChanges: UInt64 = 0,
        sampleRateChanges: UInt64 = 0,
        deviceStateChanges: UInt64 = 0,
        serviceRestarts: UInt64 = 0,
        device: AudioDeviceSnapshot = builtInSpeakers
    ) -> AudioSignalBatch {
        AudioSignalBatch(
            date: date,
            overloads: overloads,
            abnormalStops: abnormalStops,
            defaultOutputChanges: defaultOutputChanges,
            sampleRateChanges: sampleRateChanges,
            deviceStateChanges: deviceStateChanges,
            serviceRestarts: serviceRestarts,
            device: device
        )
    }

    /// A fixed instant so every duration assertion is exact.
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func temporaryDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FennecTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
