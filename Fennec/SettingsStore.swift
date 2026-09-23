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
        static let notifyOnRepair = "notifyOnRepair"
        static let notifyOnDetection = "notifyOnDetection"
        static let showRepairFox = "showRepairFox"
        static let cooldownSeconds = "cooldownSeconds"
        static let hasCompletedFirstRun = "hasCompletedFirstRun"
        static let pausedUntil = "pausedUntil"
        static let pausedIndefinitely = "pausedIndefinitely"
        static let listeningSince = "listeningSince"
    }

    private let defaults: UserDefaults

    /// Default **on**. Fennec cannot act on it until the privileged helper is
    /// enabled, so this is not a surprise-root-access switch; it means that
    /// the moment setup finishes, the product does the thing it promises
    /// without a second decision from the user.
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

    /// The "we already fixed it" banner. On by default, because a silent fix is
    /// indistinguishable from a product that does nothing.
    @Published var notifyOnRepair: Bool {
        didSet { defaults.set(notifyOnRepair, forKey: Key.notifyOnRepair) }
    }

    /// The "we saw it but were not allowed to fix it" banner.
    @Published var notifyOnDetection: Bool {
        didSet { defaults.set(notifyOnDetection, forKey: Key.notifyOnDetection) }
    }

    @Published var showRepairFox: Bool {
        didSet { defaults.set(showRepairFox, forKey: Key.showRepairFox) }
    }

    @Published var cooldownSeconds: Double {
        didSet { defaults.set(cooldownSeconds, forKey: Key.cooldownSeconds) }
    }

    /// Set when the user presses Done in the first-run window. Until then
    /// Fennec opens that window on every launch, because an app whose entire
    /// UI is one menu-bar glyph has no other way to be found.
    @Published var hasCompletedFirstRun: Bool {
        didSet { defaults.set(hasCompletedFirstRun, forKey: Key.hasCompletedFirstRun) }
    }

    /// Persisted as two plain values so a stale timestamp can never outlive
    /// its meaning: an expired date simply resolves to "running" on the next
    /// read, including after a reboot.
    @Published var pausedUntil: Date? {
        didSet { defaults.set(pausedUntil, forKey: Key.pausedUntil) }
    }

    @Published var pausedIndefinitely: Bool {
        didSet { defaults.set(pausedIndefinitely, forKey: Key.pausedIndefinitely) }
    }

    /// When Fennec first started listening on this Mac. Stamped once and
    /// never changed, so the days-without-incident sign has something honest
    /// to count from before there has ever been an incident.
    @Published private(set) var listeningSince: Date {
        didSet { defaults.set(listeningSince, forKey: Key.listeningSince) }
    }

    var pauseState: PauseState {
        get { PauseState(isIndefinite: pausedIndefinitely, until: pausedUntil) }
        set {
            pausedIndefinitely = newValue.isIndefinite
            pausedUntil = newValue.until
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        autoRepairEnabled = defaults.object(forKey: Key.autoRepairEnabled) as? Bool ?? true
        sensitivity = DetectionSensitivity(
            rawValue: defaults.string(forKey: Key.sensitivity) ?? "balanced"
        ) ?? .balanced
        protectMicrophone = defaults.object(forKey: Key.protectMicrophone) as? Bool ?? true
        protectCommunicationApps = defaults.object(forKey: Key.protectCommunicationApps) as? Bool ?? true
        skipBluetooth = defaults.object(forKey: Key.skipBluetooth) as? Bool ?? true
        notifyOnRepair = defaults.object(forKey: Key.notifyOnRepair) as? Bool ?? true
        notifyOnDetection = defaults.object(forKey: Key.notifyOnDetection) as? Bool ?? true
        showRepairFox = defaults.object(forKey: Key.showRepairFox) as? Bool ?? true
        cooldownSeconds = defaults.object(forKey: Key.cooldownSeconds) as? Double ?? 45
        hasCompletedFirstRun = defaults.object(forKey: Key.hasCompletedFirstRun) as? Bool ?? false
        pausedUntil = defaults.object(forKey: Key.pausedUntil) as? Date
        pausedIndefinitely = defaults.object(forKey: Key.pausedIndefinitely) as? Bool ?? false

        if let stored = defaults.object(forKey: Key.listeningSince) as? Date {
            listeningSince = stored
        } else {
            let now = Date()
            listeningSince = now
            defaults.set(now, forKey: Key.listeningSince)
        }
    }
}
