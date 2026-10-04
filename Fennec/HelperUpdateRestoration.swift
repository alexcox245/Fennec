import Foundation

enum HelperRegistrationStatus: Equatable {
    case enabled, requiresApproval, notRegistered, unavailable
}

enum HelperUpdateRestorationResult: Equatable {
    case enabled(reachable: Bool)
    case requiresApproval
    case unavailable

    var needsPromptedMode: Bool {
        switch self {
        case .enabled: return false
        case .requiresApproval, .unavailable: return true
        }
    }
}

/// Restores an existing approval without treating a slow daemon spawn as a
/// revoked approval. Dependencies are injected so tests never touch launchd.
@MainActor
enum HelperUpdateRestoration {
    static func restore(
        status: () -> HelperRegistrationStatus,
        register: () -> Void,
        ping: () async -> Bool,
        pause: (TimeInterval) async -> Void
    ) async -> HelperUpdateRestorationResult {
        if status() == .requiresApproval { return .requiresApproval }
        if status() == .notRegistered { register() }

        for check in 0..<10 {
            switch status() {
            case .enabled:
                for attempt in 0..<3 {
                    if attempt > 0 { await pause(1) }
                    // Approval can change while a ping or wait is suspended.
                    guard status() == .enabled else { break }
                    if await ping(), status() == .enabled {
                        return .enabled(reachable: true)
                    }
                }
                switch status() {
                case .enabled: return .enabled(reachable: false)
                case .requiresApproval: return .requiresApproval
                default: return .unavailable
                }
            case .requiresApproval:
                return .requiresApproval
            case .notRegistered:
                // A register immediately after teardown can be lost while
                // Background Task Management settles. Retry once, bounded.
                if check == 4 { register() }
                await pause(0.3)
            case .unavailable:
                return .unavailable
            }
        }
        if status() == .requiresApproval { return .requiresApproval }
        if status() == .enabled { return .enabled(reachable: false) }
        return .unavailable
    }
}

/// Coalesces restoration callers and lets the launch healer wait for the same
/// result instead of unregistering a daemon while restoration is pinging it.
@MainActor
final class HelperUpdateRestorationGate {
    private var task: Task<HelperUpdateRestorationResult, Never>?
    var isRestoring: Bool { task != nil }

    func restore(
        operation: @escaping @MainActor () async -> HelperUpdateRestorationResult
    ) async -> HelperUpdateRestorationResult {
        if let task { return await task.value }
        let task = Task { await operation() }
        self.task = task
        let result = await task.value
        self.task = nil
        return result
    }

    func waitUntilFinished() async {
        if let task { _ = await task.value }
    }
}
