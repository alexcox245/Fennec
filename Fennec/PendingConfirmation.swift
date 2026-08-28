import Foundation

/// Something is using audio right now, and repairing would interrupt it.
struct ManualRepairWarning: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
}

/// An explicit request to use the administrator-password path.
///
/// This never happens on its own. An unexplained macOS admin-password dialog
/// is the visual signature of credential phishing, so Fennec always asks first
/// and always shows the literal command it is about to run.
struct AdministratorRepairRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let reason: String
    let command: String
}

/// A question Fennec has to ask before doing something irreversible.
///
/// This exists as a type, rather than two `.alert` modifiers, because of a
/// specific macOS trap. An `.alert` presented from inside a
/// `MenuBarExtra(.window)` scene attaches to the popover's panel, and that
/// panel dismisses the instant it resigns key. Presenting the alert *is* what
/// makes it resign key. The result was a confirmation dialog that flashed and
/// vanished, on the one code path that restarts the audio system.
///
/// So the popover asks inline, in place, without ever giving up key window.
/// Settings is a real window and could use a sheet, but it uses the same card
/// so the two cannot drift apart.
enum PendingConfirmation: Identifiable, Equatable {
    /// Something is listening or recording right now.
    case audioInUse(ManualRepairWarning)
    /// The privileged helper cannot do it, so this needs an admin password.
    case administrator(AdministratorRepairRequest)

    var id: UUID {
        switch self {
        case .audioInUse(let warning): return warning.id
        case .administrator(let request): return request.id
        }
    }

    var title: String {
        switch self {
        case .audioInUse: return "Audio is in use"
        case .administrator: return "This needs your administrator password"
        }
    }

    var message: String {
        switch self {
        case .audioInUse(let warning):
            return warning.message
        case .administrator(let request):
            return request.reason
                + " macOS will ask for your password, and Fennec will run one command:"
        }
    }

    /// Shown in a monospaced register, because AGENTS.md §7 reserves that for
    /// actual data, and because a password prompt the user cannot connect to
    /// a specific command is indistinguishable from a phishing attempt.
    var monospacedDetail: String? {
        switch self {
        case .audioInUse: return nil
        case .administrator(let request): return request.command
        }
    }

    var confirmTitle: String {
        switch self {
        case .audioInUse: return "Repair Anyway"
        case .administrator: return "Continue…"
        }
    }

    var cancelTitle: String { "Cancel" }

    /// Only the first is destructive: it interrupts audio that is in use right
    /// now. The administrator path is merely privileged, and styling it as
    /// destructive would train people to expect red where red does not belong.
    var isDestructive: Bool {
        switch self {
        case .audioInUse: return true
        case .administrator: return false
        }
    }

    /// The whole card as one string, for VoiceOver and for the tests.
    var accessibilityDescription: String {
        [title, message, monospacedDetail].compactMap { $0 }.joined(separator: " ")
    }
}
