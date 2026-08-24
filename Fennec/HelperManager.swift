import Foundation
import ServiceManagement

struct HelperCallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum RepairHelperState: Equatable {
    case notConfigured
    case awaitingApproval
    case enabled(reachable: Bool)
    case unavailable(String)

    var title: String {
        switch self {
        case .notConfigured: return "Not configured"
        case .awaitingApproval: return "Approval required"
        case .enabled(let reachable): return reachable ? "Ready" : "Enabled, not responding"
        case .unavailable: return "Unavailable"
        }
    }

    var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    var isReachable: Bool {
        if case .enabled(let reachable) = self { return reachable }
        return false
    }
}

private final class ContinuationGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false
    private let completion: (Result<T, Error>) -> Void

    init(completion: @escaping (Result<T, Error>) -> Void) {
        self.completion = completion
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        completion(result)
    }
}

struct HelperClient: Sendable {
    func ping() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<String> { result in
                continuation.resume(with: result)
            }

            do {
                let connection = try makeConnection()
                connection.interruptionHandler = {
                    gate.finish(.failure(HelperCallError(message: "The repair helper connection was interrupted.")))
                    connection.invalidate()
                }
                connection.invalidationHandler = {
                    gate.finish(.failure(HelperCallError(message: "The repair helper connection became invalid.")))
                }
                connection.activate()

                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    gate.finish(.failure(error))
                    connection.invalidate()
                }) as? FennecHelperProtocol else {
                    gate.finish(.failure(HelperCallError(message: "The repair helper exposed an unexpected XPC interface.")))
                    connection.invalidate()
                    return
                }

                proxy.ping { value in
                    gate.finish(.success(value))
                    connection.invalidate()
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    gate.finish(.failure(HelperCallError(message: "The repair helper did not respond within 5 seconds.")))
                    connection.invalidate()
                }
            } catch {
                gate.finish(.failure(error))
            }
        }
    }

    func restartCoreAudio() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<String> { result in
                continuation.resume(with: result)
            }

            do {
                let connection = try makeConnection()
                connection.interruptionHandler = {
                    gate.finish(.failure(HelperCallError(message: "The repair helper connection was interrupted.")))
                    connection.invalidate()
                }
                connection.invalidationHandler = {
                    gate.finish(.failure(HelperCallError(message: "The repair helper connection became invalid.")))
                }
                connection.activate()

                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    gate.finish(.failure(error))
                    connection.invalidate()
                }) as? FennecHelperProtocol else {
                    gate.finish(.failure(HelperCallError(message: "The repair helper exposed an unexpected XPC interface.")))
                    connection.invalidate()
                    return
                }

                proxy.restartCoreAudio { success, message in
                    if success {
                        gate.finish(.success(message))
                    } else {
                        gate.finish(.failure(HelperCallError(message: message)))
                    }
                    connection.invalidate()
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    gate.finish(.failure(HelperCallError(message: "The Core Audio repair timed out.")))
                    connection.invalidate()
                }
            } catch {
                gate.finish(.failure(error))
            }
        }
    }

    private func makeConnection() throws -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: AppConstants.helperMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: FennecHelperProtocol.self)
        connection.setCodeSigningRequirement(
            try CodeSigningRequirement.peerRequirement(bundleIdentifier: AppConstants.helperBundleIdentifier)
        )
        return connection
    }
}

@MainActor
final class HelperManager: ObservableObject {
    @Published private(set) var state: RepairHelperState = .notConfigured
    @Published private(set) var lastError: String?
    /// Who answered the last `ping`. Shown in About so the disclosure
    /// describes the helper that is actually running, not the one in this
    /// bundle.
    @Published private(set) var identity: HelperIdentity?

    /// This copy of Fennec's build number, for comparison.
    var appBuild: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }

    var versionMismatch: String? { identity?.mismatch(againstAppBuild: appBuild) }

    private let service = SMAppService.daemon(plistName: AppConstants.helperPlistName)
    private let client = HelperClient()

    init() {
        refreshStatus(testReachability: true)
    }

    func refreshStatus(testReachability: Bool = true) {
        switch service.status {
        case .enabled:
            state = .enabled(reachable: false)
            guard testReachability else { return }
            Task {
                do {
                    let reply = try await client.ping()
                    identity = HelperIdentity.parse(reply)
                    state = .enabled(reachable: true)
                    lastError = nil
                } catch {
                    identity = nil
                    state = .enabled(reachable: false)
                    lastError = error.localizedDescription
                }
            }
        case .requiresApproval:
            state = .awaitingApproval
        case .notRegistered, .notFound:
            state = .notConfigured
        @unknown default:
            state = .unavailable("Unknown Service Management status")
        }
    }

    func register() {
        do {
            if service.status == .notRegistered || service.status == .notFound {
                try service.register()
            }
            lastError = nil
        } catch {
            // Service Management can update the registration state before an
            // error reaches the caller. Always re-read status before deciding
            // that setup failed.
            if service.status != .requiresApproval && service.status != .enabled {
                lastError = error.localizedDescription
                state = .unavailable(error.localizedDescription)
                return
            }
        }

        refreshStatus(testReachability: true)
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func unregister() {
        do {
            if service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
            lastError = nil
            identity = nil
            state = .notConfigured
        } catch {
            lastError = error.localizedDescription
            state = .unavailable(error.localizedDescription)
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func restartCoreAudio() async throws -> String {
        try await client.restartCoreAudio()
    }
}
