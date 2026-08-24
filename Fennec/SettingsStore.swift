import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let autoRepairEnabled = "autoRepairEnabled"
        static let sensitivity = "sensitivity"
        static let protectMicrophone = "protectMicrophone"
        static let protectCommunicationApps = "protectCommunicationApps"
        static let skipBluetooth = "skipBluetooth"
        static let notifyOnDetection = "notifyOnDetection"
        static let cooldownSeconds = "cooldownSeconds"
    }

    private let defaults: UserDefaults

    @Published var autoRepairEnabled: Bool {
        didSet { defaults.set(autoRepairEnabled, forKey: Key.autoRepairEnabled) }
    }

    @Published var sensitivity: DetectionSensitivity {
        didSet { defaults.set(sensitivity.rawValue, forKey: Key.sensitivity) }
    }

    @Published var protectMicrophone: Bool {
        didSet { defaults.set(protectMicrophone, forKey: Key.protectMicrophone) }
    }

    @Published var protectCommunicationApps: Bool {
        didSet { defaults.set(protectCommunicationApps, forKey: Key.protectCommunicationApps) }
    }

    @Published var skipBluetooth: Bool {
        didSet { defaults.set(skipBluetooth, forKey: Key.skipBluetooth) }
    }

    @Published var notifyOnDetection: Bool {
        didSet { defaults.set(notifyOnDetection, forKey: Key.notifyOnDetection) }
    }

    @Published var cooldownSeconds: Double {
        didSet { defaults.set(cooldownSeconds, forKey: Key.cooldownSeconds) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        autoRepairEnabled = defaults.object(forKey: Key.autoRepairEnabled) as? Bool ?? false
        sensitivity = DetectionSensitivity(
            rawValue: defaults.string(forKey: Key.sensitivity) ?? "balanced"
        ) ?? .balanced
        protectMicrophone = defaults.object(forKey: Key.protectMicrophone) as? Bool ?? true
        protectCommunicationApps = defaults.object(forKey: Key.protectCommunicationApps) as? Bool ?? true
        skipBluetooth = defaults.object(forKey: Key.skipBluetooth) as? Bool ?? true
        notifyOnDetection = defaults.object(forKey: Key.notifyOnDetection) as? Bool ?? true
        cooldownSeconds = defaults.object(forKey: Key.cooldownSeconds) as? Double ?? 45
    }
}
