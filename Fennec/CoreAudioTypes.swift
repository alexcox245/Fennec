import CoreAudio
import Darwin
import Foundation

enum AudioTransport: String, Codable, Sendable {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case thunderbolt
    case displayPort
    case hdmi
    case airPlay
    case aggregate
    case virtual
    case other

    var title: String {
        switch self {
        case .builtIn: return "Built-in"
        case .bluetooth: return "Bluetooth"
        case .bluetoothLE: return "Bluetooth LE"
        case .usb: return "USB"
        case .thunderbolt: return "Thunderbolt"
        case .displayPort: return "DisplayPort"
        case .hdmi: return "HDMI"
        case .airPlay: return "AirPlay"
        case .aggregate: return "Aggregate"
        case .virtual: return "Virtual"
        case .other: return "Other"
        }
    }

    var isBluetooth: Bool {
        self == .bluetooth || self == .bluetoothLE
    }
}

struct AudioDeviceSnapshot: Equatable, Sendable {
    let id: AudioObjectID
    let name: String
    let uid: String
    let sampleRate: Double
    let transport: AudioTransport
    let isAlive: Bool

    static let unavailable = AudioDeviceSnapshot(
        id: kAudioObjectUnknown,
        name: "No output device",
        uid: "",
        sampleRate: 0,
        transport: .other,
        isAlive: false
    )
}

struct AudioProcessSnapshot: Identifiable, Equatable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleIdentifier: String
    let processName: String
    let isRunningInput: Bool
    let isRunningOutput: Bool

    var id: AudioObjectID { objectID }
}

struct AudioSignalBatch: Equatable, Sendable {
    let date: Date
    let overloads: UInt64
    let abnormalStops: UInt64
    let defaultOutputChanges: UInt64
    let sampleRateChanges: UInt64
    let deviceStateChanges: UInt64
    let serviceRestarts: UInt64
    let device: AudioDeviceSnapshot

    var containsFailureSignal: Bool {
        overloads > 0 || abnormalStops > 0
    }
}

enum AudioSignalKind: String, Codable, Sendable {
    case processorOverload
    case ioStoppedAbnormally
}
