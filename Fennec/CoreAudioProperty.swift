import AppKit
import CoreAudio
import Darwin
import Foundation

enum CoreAudioReadError: LocalizedError {
    case propertyUnavailable(String)
    case osStatus(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .propertyUnavailable(let property):
            return "Core Audio property unavailable: \(property)."
        case .osStatus(let operation, let status):
            return "\(operation) failed with Core Audio status \(fourCC(status))."
        }
    }

    private func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
        }
        return String(status)
    }
}

enum CoreAudioReader {
    static func defaultOutputDeviceID() throws -> AudioObjectID {
        try readScalar(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal,
            initialValue: AudioObjectID(kAudioObjectUnknown),
            operation: "Reading the default output device"
        )
    }

    static func defaultOutputSnapshot() throws -> AudioDeviceSnapshot {
        let id = try defaultOutputDeviceID()
        guard id != kAudioObjectUnknown else {
            return .unavailable
        }
        return try deviceSnapshot(id: id)
    }

    static func deviceSnapshot(id: AudioObjectID) throws -> AudioDeviceSnapshot {
        let name = (try? readString(
            objectID: id,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal,
            operation: "Reading the output device name"
        )) ?? "Audio device \(id)"

        let uid = (try? readString(
            objectID: id,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal,
            operation: "Reading the output device UID"
        )) ?? ""

        let sampleRate = (try? readScalar(
            objectID: id,
            selector: kAudioDevicePropertyNominalSampleRate,
            scope: kAudioObjectPropertyScopeGlobal,
            initialValue: Float64(0),
            operation: "Reading the output sample rate"
        )) ?? 0

        let transportValue = (try? readScalar(
            objectID: id,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal,
            initialValue: UInt32(kAudioDeviceTransportTypeUnknown),
            operation: "Reading the output transport"
        )) ?? UInt32(kAudioDeviceTransportTypeUnknown)

        let aliveValue = (try? readScalar(
            objectID: id,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            initialValue: UInt32(1),
            operation: "Reading the output device state"
        )) ?? 1

        return AudioDeviceSnapshot(
            id: id,
            name: name,
            uid: uid,
            sampleRate: sampleRate,
            transport: transport(for: transportValue),
            isAlive: aliveValue != 0
        )
    }

    static func activeAudioProcesses() throws -> [AudioProcessSnapshot] {
        let processObjects = try readObjectIDArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal,
            operation: "Reading active Core Audio processes"
        )

        return processObjects.compactMap { processObject in
            guard let pid: pid_t = try? readScalar(
                objectID: processObject,
                selector: kAudioProcessPropertyPID,
                scope: kAudioObjectPropertyScopeGlobal,
                initialValue: pid_t(0),
                operation: "Reading an audio process PID"
            ), pid > 0 else {
                return nil
            }

            let bundleIdentifier = (try? readString(
                objectID: processObject,
                selector: kAudioProcessPropertyBundleID,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "Reading an audio process bundle ID"
            )) ?? ""

            let input: UInt32 = (try? readScalar(
                objectID: processObject,
                selector: kAudioProcessPropertyIsRunningInput,
                scope: kAudioObjectPropertyScopeGlobal,
                initialValue: UInt32(0),
                operation: "Reading audio input activity"
            )) ?? 0

            let output: UInt32 = (try? readScalar(
                objectID: processObject,
                selector: kAudioProcessPropertyIsRunningOutput,
                scope: kAudioObjectPropertyScopeGlobal,
                initialValue: UInt32(0),
                operation: "Reading audio output activity"
            )) ?? 0

            return AudioProcessSnapshot(
                objectID: processObject,
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                processName: processName(for: pid),
                isRunningInput: input != 0,
                isRunningOutput: output != 0
            )
        }
    }

    static func hasProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(objectID, &address)
    }

    private static func readScalar<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        initialValue: T,
        operation: String
    ) throws -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else {
            throw CoreAudioReadError.propertyUnavailable(operation)
        }

        var value = initialValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr else {
            throw CoreAudioReadError.osStatus(operation: operation, status: status)
        }
        return value
    }

    private static func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else {
            throw CoreAudioReadError.propertyUnavailable(operation)
        }

        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr else {
            throw CoreAudioReadError.osStatus(operation: operation, status: status)
        }
        return value.map { $0 as String } ?? ""
    }

    private static func readObjectIDArray(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else {
            throw CoreAudioReadError.propertyUnavailable(operation)
        }

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else {
            throw CoreAudioReadError.osStatus(operation: operation, status: status)
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var values = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        status = values.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        guard status == noErr else {
            throw CoreAudioReadError.osStatus(operation: operation, status: status)
        }
        return values
    }

    private static func processName(for pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_name(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else {
            return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "PID \(pid)"
        }
        return String(cString: buffer)
    }

    private static func transport(for rawValue: UInt32) -> AudioTransport {
        switch rawValue {
        case UInt32(kAudioDeviceTransportTypeBuiltIn): return .builtIn
        case UInt32(kAudioDeviceTransportTypeBluetooth): return .bluetooth
        case UInt32(kAudioDeviceTransportTypeBluetoothLE): return .bluetoothLE
        case UInt32(kAudioDeviceTransportTypeUSB): return .usb
        case UInt32(kAudioDeviceTransportTypeThunderbolt): return .thunderbolt
        case UInt32(kAudioDeviceTransportTypeDisplayPort): return .displayPort
        case UInt32(kAudioDeviceTransportTypeHDMI): return .hdmi
        case UInt32(kAudioDeviceTransportTypeAirPlay): return .airPlay
        case UInt32(kAudioDeviceTransportTypeAggregate): return .aggregate
        case UInt32(kAudioDeviceTransportTypeVirtual): return .virtual
        default: return .other
        }
    }
}
