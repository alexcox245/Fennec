import Foundation
import ServiceManagement

struct HelperCallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    /// The helper enforces its own 20-second floor between restarts and
    /// reports it as `success == false`, which is indistinguishable from a
    /// real failure at this layer. The marker lets the app tell a rate limiter
    /// from a fault instead of telling the user their Mac is broken.
    var isThrottled: Bool { message.hasPrefix(HelperThrottle.marker) }
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
    /// True while a `ping` is in flight. Purely cosmetic — no repair gate
    /// reads it, because a probe in progress is not a reason to refuse.
    @Published private(set) var isChecking = false
    /// Who answered the last `ping`. Shown in About so the disclosure
    /// describes the helper that is actually running, not the one in this
    /// bundle.
    @Published private(set) var identity: HelperIdentity?

    /// This copy of Fennec's build number, for comparison.
    var appBuild: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }

    var versionMismatch: String? { identity?.mismatch(againstAppBuild: appBuild) }

    /// Whether macOS holds a registration for the daemon at all — which is a
    /// different question from whether it is answering, and the one that
    /// matters when deciding whether removal has anything to remove.
    /// `.requiresApproval` is registered.
    var isRegistered: Bool {
        service.status != .notRegistered && service.status != .notFound
    }

    private let service = SMAppService.daemon(plistName: AppConstants.helperPlistName)
    private let client = HelperClient()

    /// Set while a registration rebuild is between its teardown and a
    /// resolved outcome, and persisted because that gap can outlive the
    /// process: observed live, `register()` issued right after `unregister()`
    /// bounced off Background Task Management's asynchronous teardown, the
    /// status read `.notRegistered`, and the app was left holding *less* than
    /// it started with — a helper the user had approved, now not registered
    /// at all, with the consent guard (correctly) refusing to touch a
    /// not-registered daemon. Completing an interrupted rebuild is finishing
    /// the user's standing approval, not a new grant, so `refreshStatus` may
    /// register when — and only when — this marker is set.
    private static let rebuildInFlightKey = "helperRegistrationRebuildInFlight"

    private var rebuildInFlight: Bool {
        get { UserDefaults.standard.bool(forKey: Self.rebuildInFlightKey) }
        set {
            if newValue {
                UserDefaults.standard.set(true, forKey: Self.rebuildInFlightKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.rebuildInFlightKey)
            }
        }
    }

    init() {
        refreshStatus(testReachability: true)
    }

    func refreshStatus(testReachability: Bool = true) {
        switch service.status {
        case .enabled:
            // Do NOT publish `reachable: false` here. This method is the
            // `.task` of the popover and every window, so a fully configured
            // Fennec rendered as unconfigured — auto-repair toggle disabled,
            // an orange "Finish setup" card inserted mid-panel — for the
            // duration of every ping. Worse, a detection landing in that gap
            // hit `guard helperManager.state.isReachable` and was skipped as
            // "the helper is not enabled" while it was answering perfectly.
            if !state.isEnabled { state = .enabled(reachable: false) }
            guard testReachability else { return }
            isChecking = true
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
                isChecking = false
            }
        case .requiresApproval:
            state = .awaitingApproval
        case .notRegistered, .notFound:
            if rebuildInFlight {
                try? service.register()
                if service.status != .notRegistered && service.status != .notFound {
                    rebuildInFlight = false
                    // Safe from unbounded recursion: the status just left the
                    // branch that re-enters here.
                    refreshStatus(testReachability: testReachability)
                    return
                }
            }
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

    /// Rebuilds a registration that macOS reports enabled but that is not
    /// producing a helper that answers.
    ///
    /// A registration binds to the bundle path and signature that made it, so
    /// a replaced build or a moved app leaves launchd holding a record it can
    /// no longer spawn — the state every prior version could only describe
    /// ("Enabled, not responding") and never fix. Unregistering and
    /// registering again from the *running* bundle rewrites the record. No
    /// password is involved at any point: these are the same unprivileged
    /// Service Management calls the setup buttons use, and the user's
    /// standing approval either survives (the daemon comes back enabled) or
    /// macOS demands the Login Items toggle again (`.awaitingApproval`, which
    /// the setup UI already explains). When to call this is
    /// `HelperHealPolicy`'s decision, not this method's.
    ///
    /// Returns `true` when the helper answers afterwards.
    func rebuildRegistration() async -> Bool {
        // Confirm the silence first. The last ping may be minutes old, and a
        // healthy registration must never be torn down over stale news.
        if await confirmReachable() { return true }

        guard service.status == .enabled else {
            refreshStatus(testReachability: true)
            return false
        }

        rebuildInFlight = true
        do {
            // The async overload: in an async context Swift resolves to it
            // anyway, and the completion-based teardown is the one Apple
            // documents as safe to follow with a fresh registration.
            try await service.unregister()
        } catch {
            // A record launchd can no longer resolve may refuse to leave
            // cleanly. Registering from this bundle below rewrites it anyway.
        }
        do {
            try service.register()
        } catch {
            // Approval may have been discarded along with the registration.
            // That surfaces as `.requiresApproval` below — a Settings toggle,
            // not a fault to alarm about here.
        }

        // Registration propagates through Background Task Management and smd
        // asynchronously. Observed live on this machine: BTM had already
        // recorded the item `[enabled, allowed]`, yet `status` still read
        // `.notRegistered` for a beat — and one stale read here turned a
        // successful rebuild into "not enabled" with no daemon in launchd at
        // all. Poll briefly instead of trusting the first answer, and issue
        // one more `register()` mid-wait: a register that raced the previous
        // record's teardown can leave the BTM item enabled without ever
        // bootstrapping launchd, and a second call from a settled store
        // completes that bootstrap.
        var settleChecks = 0
        while service.status == .notRegistered || service.status == .notFound {
            settleChecks += 1
            if settleChecks > 8 { break }
            try? await Task.sleep(for: .milliseconds(500))
            if settleChecks == 4 {
                try? service.register()
            }
        }

        switch service.status {
        case .enabled:
            rebuildInFlight = false
            // launchd spawns the helper on demand, and the first ping can
            // race that spawn. Three tries, a second apart, before giving up.
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                if await confirmReachable() { return true }
            }
            state = .enabled(reachable: false)
            return false
        case .requiresApproval:
            rebuildInFlight = false
            state = .awaitingApproval
            return false
        default:
            // Unresolved: the marker stays set, so the next status refresh —
            // this run or the next launch — completes the rebuild instead of
            // stranding the user's approval.
            refreshStatus(testReachability: true)
            return false
        }
    }

    /// One fresh ping, with the published state updated to match the answer.
    private func confirmReachable() async -> Bool {
        do {
            let reply = try await client.ping()
            identity = HelperIdentity.parse(reply)
            state = .enabled(reachable: true)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
