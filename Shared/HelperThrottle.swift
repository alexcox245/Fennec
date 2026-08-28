import Foundation

/// The helper's own rate limiter, phrased so both sides agree.
///
/// `HelperService` enforces a 20-second floor between restarts, independently
/// of anything the app asks for, and reports it as `success == false`, which
/// at the XPC layer is indistinguishable from a real failure. Unmarked, the
/// most predictable thing a person does after a manual repair ("did that
/// help? let me press it again") produced a red *Repair failed* receipt and a
/// sounded alarm telling them their Mac was broken when it was not.
///
/// Shared rather than duplicated, so the marker cannot drift between the
/// process that writes it and the process that reads it.
enum HelperThrottle {
    static let marker = "[throttled]"

    static func message(remainingSeconds: Int) -> String {
        "\(marker) Core Audio was restarted moments ago. Fennec can try again in \(remainingSeconds) seconds."
    }

    /// The marker is for the app, not for the user.
    static func userFacing(_ message: String) -> String {
        message.replacingOccurrences(of: marker + " ", with: "")
    }
}
