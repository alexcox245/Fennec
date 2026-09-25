import AppKit
import Foundation
import ServiceManagement

/// What macOS currently thinks about Fennec as a login item.
///
/// `SMAppService.Status` is a raw four-case enum; this wraps it with the two
/// things the UI needs and it does not have: a name a person recognises and
/// a sentence saying what to do next.
enum LoginItemState: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown(String)

    var isEnabled: Bool { self == .enabled }
    var requiresApproval: Bool { self == .requiresApproval }
    /// An item awaiting approval still has a registration to remove.
    var isRegistered: Bool {
        switch self {
        case .notRegistered, .notFound: return false
        case .enabled, .requiresApproval, .unknown: return true
        }
    }

    var title: String {
        switch self {
        case .enabled: return "On"
        case .requiresApproval: return "Approval required"
        case .notRegistered: return "Off"
        case .notFound: return "Off"
        case .unknown: return "Unavailable"
        }
    }

    var detail: String {
        switch self {
        case .enabled:
            return "Fennec starts with your Mac and waits in the menu bar."
        case .requiresApproval:
            return "macOS is holding this until you allow Fennec in Login Items & Extensions."
        case .notRegistered, .notFound:
            return "Fennec only listens while you have it open."
        case .unknown(let message):
            return message
        }
    }

    static func from(_ status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown("macOS reported a Service Management status Fennec does not recognise.")
        }
    }
}

/// Launch at login, via `SMAppService.mainApp`.
///
/// The hard part is not registering; it is that the answer can change
/// outside the app. The user can switch Fennec off in System Settings →
/// General → Login Items & Extensions at any time, and macOS does not tell
/// us. So this re-reads status every time the app comes forward, and every
/// time the menu or Settings window appears.
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var state: LoginItemState = .notRegistered
    @Published private(set) var lastError: String?

    private let service = SMAppService.mainApp
    private var activationObserver: NSObjectProtocol?

    var isEnabled: Bool { state.isEnabled }
    var requiresApproval: Bool { state.requiresApproval }

    init() {
        refresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func refresh() {
        state = LoginItemState.from(service.status)
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? enable() : disable()
    }

    func enable() {
        do {
            if service.status == .notRegistered || service.status == .notFound {
                try service.register()
            }
            lastError = nil
        } catch {
            // Service Management frequently updates its own state before the
            // error surfaces, so never conclude failure without re-reading.
            refresh()
            if state.isEnabled || state.requiresApproval {
                lastError = nil
            } else {
                lastError = Self.explain(error)
                return
            }
        }

        refresh()
        if state.requiresApproval {
            openSettings()
        }
    }

    func disable() {
        do {
            if service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
            lastError = nil
        } catch {
            refresh()
            if state.isEnabled {
                lastError = Self.explain(error)
                return
            }
            lastError = nil
        }
        refresh()
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// `SMAppServiceErrorDomain` messages are accurate and useless. Almost
    /// every real failure here has the same cause, so say that instead.
    static func explain(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "SMAppServiceErrorDomain" {
            return "macOS would not add Fennec as a login item (\(nsError.code)). "
                + "This usually means Fennec is not in your Applications folder, or the copy you are running is not signed."
        }
        return error.localizedDescription
    }
}
