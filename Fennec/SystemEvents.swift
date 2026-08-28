import AppKit
import CoreGraphics
import Foundation

/// Moments when the audio graph is legitimately in pieces.
///
/// Core Audio renegotiates the whole output path when a Mac wakes, when the
/// screen unlocks, and when a fast-user-switch hands the console over. Every
/// one of those reliably produces exactly the signals Fennec was built to
/// treat as a failure, so without these windows, the first thing Fennec does
/// when a laptop lid opens is restart the audio daemon. Every day. For every
/// laptop user.
///
/// `AppModel` already had the mechanism: `suppressSignalsUntil`, set to 12 s
/// after a service restart and 2 s after a device change. This just tells it
/// about the three events nobody was watching.
enum SystemEvent: String, CaseIterable, Sendable {
    /// Fennec itself just started. The listener graph is fresh and the first
    /// drain can carry whatever was already queued.
    case launch
    /// The machine woke from sleep.
    case wake
    /// The displays woke, which on a desktop is the common form of "wake".
    case screensWake
    /// The screen was unlocked.
    case screenUnlock
    /// A fast-user-switch made this session the console session.
    case sessionActive

    /// How long to stay quiet afterwards.
    ///
    /// Wake gets the longest window because it is the one that renegotiates
    /// sample rate, re-enumerates devices, and restarts every audio client at
    /// once, often over several seconds.
    var quietSeconds: TimeInterval {
        switch self {
        case .launch: return 8
        case .wake: return 20
        case .screensWake: return 10
        case .screenUnlock: return 10
        case .sessionActive: return 12
        }
    }

    /// Written to the event log so a suppressed window is never a mystery.
    var reason: String {
        switch self {
        case .launch: return "Fennec started; ignoring signals while the listener graph settles."
        case .wake: return "The Mac woke; ignoring signals while Core Audio renegotiates."
        case .screensWake: return "The displays woke; ignoring signals while Core Audio renegotiates."
        case .screenUnlock: return "The screen unlocked; ignoring signals while Core Audio renegotiates."
        case .sessionActive: return "This session became active; ignoring signals while Core Audio renegotiates."
        }
    }
}

/// Subscribes to the system notifications behind `SystemEvent`.
///
/// Screen lock and unlock are only published on the *distributed* notification
/// centre, under names Apple has never formally documented but has shipped
/// unchanged for well over a decade. If they ever stop arriving, Fennec loses
/// a quiet window and gains a false positive; it does not break.
@MainActor
final class SystemEventObserver {
    var onEvent: ((SystemEvent) -> Void)?

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedTokens: [NSObjectProtocol] = []

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        subscribe(workspace, NSWorkspace.didWakeNotification, .wake)
        subscribe(workspace, NSWorkspace.screensDidWakeNotification, .screensWake)
        subscribe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive)

        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsUnlocked"] {
            distributedTokens.append(distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onEvent?(.screenUnlock)
                }
            })
        }
    }

    deinit {
        for (center, token) in tokens {
            center.removeObserver(token)
        }
        for token in distributedTokens {
            DistributedNotificationCenter.default().removeObserver(token)
        }
    }

    private func subscribe(_ center: NotificationCenter, _ name: Notification.Name, _ event: SystemEvent) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onEvent?(event)
            }
        }
        tokens.append((center, token))
    }
}

/// Whether this login session is the one at the keyboard.
///
/// Restarting `coreaudiod` is system-wide: it cuts audio for every logged-in
/// user, every fast-user-switching session, and anything recording in another
/// account. But `RecoverySafetyChecker` can only enumerate *this* user's audio
/// processes, so on a Mac with a second account left logged in, Fennec could
/// cut someone else's call and truthfully report that the machine was clear.
///
/// Automatic repair is therefore gated on being the console session. Manual
/// repair is not: if a person is sitting in front of Fennec pressing the
/// button, they have decided.
enum LoginSession {
    static func isOnConsole() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // No session dictionary at all means the API shape changed, not
            // that we are in the background. Failing closed here would make
            // Fennec silently do nothing forever, which is the harder failure
            // to diagnose of the two.
            return true
        }
        guard let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool else {
            return true
        }
        return onConsole
    }
}
