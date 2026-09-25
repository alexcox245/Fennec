import Combine
import Foundation

enum RepairMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case askFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatically"
        case .askFirst: return "Ask me first"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "Repair crackling when the safety checks allow it."
        case .askFirst: return "Show a repair window when crackling is detected."
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let repairMode = "repairMode"
        /// Read only for migration from versions that exposed a boolean.
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

    @Published var repairMode: RepairMode {
        didSet {
            defaults.set(repairMode.rawValue, forKey: Key.repairMode)
            defaults.set(repairMode == .automatic, forKey: Key.autoRepairEnabled)
        }
    }

    /// Source compatibility for the existing switch while the UI moves to
    /// an explicit two-choice picker. Assigning it also persists the new mode.
    var autoRepairEnabled: Bool {
        get { repairMode == .automatic }
        set { repairMode = newValue ? .automatic : .askFirst }
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

    /// Set when the user finishes or closes the first-run window. Until then
    /// Fennec opens it on launch, because a menu-bar app is easy to miss.
    @Published var hasCompletedFirstRun: Bool {
        didSet { defaults.set(hasCompletedFirstRun, forKey: Key.hasCompletedFirstRun) }
    }

    /// Setup can still need attention after onboarding is dismissed. Reopen
    /// the welcome window only until the user has completed or closed it.
    var shouldShowWelcomeOnReopen: Bool { !hasCompletedFirstRun }

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

        let storedMode = defaults.string(forKey: Key.repairMode).flatMap(RepairMode.init(rawValue:))
        let explicitLegacyMode = (defaults.object(forKey: Key.autoRepairEnabled) as? Bool)
            .map { $0 ? RepairMode.automatic : .askFirst }
        // A saved choice always wins, including the older boolean preference.
        // Fresh installs start in Automatic; a missing value on older installs
        // has the same meaning as their original implicit automatic default.
        let initialRepairMode = storedMode ?? explicitLegacyMode ?? .automatic
        repairMode = initialRepairMode
        defaults.set(initialRepairMode.rawValue, forKey: Key.repairMode)
        defaults.set(initialRepairMode == .automatic, forKey: Key.autoRepairEnabled)
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
