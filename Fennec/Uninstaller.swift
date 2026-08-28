import AppKit
import Foundation
import ServiceManagement

/// Removing Fennec, completely.
///
/// The failure this exists to prevent is the one a Mac forum reviewer can
/// demonstrate in thirty seconds with no special knowledge: drag Fennec to
/// the Trash and the **root LaunchDaemon stays registered**. So does the
/// login item, and the support folder. The only unregister path lived inside
/// the application that no longer exists.
///
/// For a product whose whole pitch is restraint, being uninstallable is not a
/// polish item. It is the claim.
enum UninstallPlan {
    struct Step: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable {
            case helper
            case loginItem
            case supportFiles
            case preferences
            case bundle
        }

        let kind: Kind
        let title: String
        let detail: String

        var id: String { kind.rawValue }
    }

    /// What removal will actually do, given the current state. Steps that
    /// would be no-ops are omitted rather than reported as "done", because a
    /// checklist of things that did not happen teaches the user nothing.
    static func steps(
        /// **Registered**, not reachable. `.requiresApproval` is registered:
        /// keying this off `RepairHelperState.isEnabled` silently dropped the
        /// daemon from the plan and then reported "Fennec is removed".
        helperInstalled: Bool,
        loginItemEnabled: Bool,
        keepLogs: Bool,
        canRemoveBundle: Bool
    ) -> [Step] {
        var steps: [Step] = []

        if helperInstalled {
            steps.append(Step(
                kind: .helper,
                title: "Unregister the root helper",
                detail: "Removes the LaunchDaemon from Background Task Management. This is the step "
                    + "that does not happen if you only drag Fennec to the Trash."
            ))
        }
        if loginItemEnabled {
            steps.append(Step(
                kind: .loginItem,
                title: "Remove the login item",
                detail: "Fennec stops starting with your Mac."
            ))
        }
        if !keepLogs {
            steps.append(Step(
                kind: .supportFiles,
                title: "Delete the event log and repair history",
                detail: "~/Library/Application Support/Fennec"
            ))
        }
        steps.append(Step(
            kind: .preferences,
            title: "Forget Fennec's settings",
            detail: "Sensitivity, safety switches, and the pause state."
        ))
        if canRemoveBundle {
            steps.append(Step(
                kind: .bundle,
                title: "Move Fennec to the Trash",
                detail: "Then Fennec quits."
            ))
        }
        return steps
    }

    /// The sentence above the button. Names the consequence, not the process.
    static func summary(keepLogs: Bool) -> String {
        keepLogs
            ? "Fennec will unregister its root helper, remove its login item, forget its settings, and move itself to the Trash. Your event log and repair history stay where they are."
            : "Fennec will unregister its root helper, remove its login item, delete its log and repair history, forget its settings, and move itself to the Trash."
    }

    static let manualFallback = """
        If Fennec is already in the Trash, the helper can still be removed from the command line:

        sudo launchctl bootout system/com.ludicrousdesigns.Fennec.helper
        rm -rf ~/Library/Application\\ Support/Fennec
        defaults delete com.ludicrousdesigns.Fennec
        """
}

/// One step's verdict. Reported per step, honestly, because "uninstall
/// failed" tells a user nothing they can act on.
enum UninstallStepResult: Equatable, Sendable {
    case done
    case failed(String)

    var succeeded: Bool { self == .done }
}

@MainActor
final class Uninstaller: ObservableObject {
    @Published private(set) var results: [UninstallPlan.Step.Kind: UninstallStepResult] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var finished = false

    private let helperService = SMAppService.daemon(plistName: AppConstants.helperPlistName)

    /// Everything except quitting, which the caller does once it has shown the
    /// results. Deliberately sequential and deliberately not transactional:
    /// each step is independently useful, so a failure part-way through still
    /// leaves the machine better off than it started.
    func run(keepLogs: Bool, steps: [UninstallPlan.Step]) async {
        guard !isRunning else { return }
        isRunning = true
        results = [:]

        for step in steps {
            switch step.kind {
            case .helper:
                results[.helper] = perform {
                    if helperService.status != .notRegistered && helperService.status != .notFound {
                        try helperService.unregister()
                    }
                }
            case .loginItem:
                results[.loginItem] = perform {
                    let mainApp = SMAppService.mainApp
                    if mainApp.status != .notRegistered && mainApp.status != .notFound {
                        try mainApp.unregister()
                    }
                }
            case .supportFiles:
                results[.supportFiles] = perform {
                    let directory = EventLogger.defaultDirectory()
                    if FileManager.default.fileExists(atPath: directory.path) {
                        try FileManager.default.removeItem(at: directory)
                    }
                }
            case .preferences:
                UserDefaults.standard.removePersistentDomain(forName: AppConstants.appBundleIdentifier)
                results[.preferences] = .done
            case .bundle:
                // Never trash the app while the daemon is still registered.
                // That is precisely the state ground rule 12 exists to
                // prevent: a root LaunchDaemon pointing at a binary in the
                // Trash, and no app left to retry the removal from.
                if results[.helper]?.succeeded == false {
                    results[.bundle] = .failed(
                        "Left in place on purpose: the root helper is still registered, "
                        + "so Fennec is still here to retry."
                    )
                } else {
                    results[.bundle] = await recycleBundle()
                }
            }
        }

        isRunning = false
        finished = true
    }

    var allSucceeded: Bool {
        !results.isEmpty && results.values.allSatisfy(\.succeeded)
    }

    /// True when the app is still on disk, so the user can try again.
    var canRetry: Bool {
        results[.bundle]?.succeeded != true
    }

    /// Only the failures, phrased so the user knows what is left on their Mac
    /// and named by the step they will recognise rather than by an enum case.
    var failureSummary: String? {
        let failures = results.compactMap { kind, result -> String? in
            guard case .failed(let message) = result else { return nil }
            return "· \(Self.label(for: kind)): \(message)"
        }.sorted()
        guard !failures.isEmpty else { return nil }
        return "macOS refused part of the removal:\n" + failures.joined(separator: "\n")
    }

    private static func label(for kind: UninstallPlan.Step.Kind) -> String {
        switch kind {
        case .helper: return "Root helper"
        case .loginItem: return "Login item"
        case .supportFiles: return "Log and repair history"
        case .preferences: return "Settings"
        case .bundle: return "Move to Trash"
        }
    }

    /// Lets the user try again after a partial failure without relaunching.
    func reset() {
        guard !isRunning else { return }
        results = [:]
        finished = false
    }

    private func perform(_ work: () throws -> Void) -> UninstallStepResult {
        do {
            try work()
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func recycleBundle() async -> UninstallStepResult {
        let url = Bundle.main.bundleURL
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { _, error in
                Task { @MainActor in
                    continuation.resume(returning: error.map { .failed($0.localizedDescription) } ?? .done)
                }
            }
        }
    }
}
