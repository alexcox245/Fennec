import Foundation

/// Which helper is actually running as root.
///
/// The gap this closes: the About panel makes claims about what the helper
/// can do, but it describes the helper in *this* bundle, not the one macOS
/// has already launched. After an in-place update, the root process may still
/// be the previous binary, and `ping` used to reply with a sentence that had
/// no version in it, so the app's entire vocabulary for that situation was
/// "Enabled, not responding".
///
/// The fix needs no protocol change: `ping` already returns a `String`, so it
/// now returns a parseable one. The privilege boundary is untouched.
struct HelperIdentity: Equatable, Sendable {
    let build: String?
    let executablePath: String?
    let euid: UInt32?
    /// The raw reply, kept so the UI can always show *something* true.
    let raw: String

    /// `ready euid=0 build=7 path=/Applications/Fennec.app/Contents/MacOS/FennecHelper`
    static func parse(_ reply: String) -> HelperIdentity {
        var fields: [String: String] = [:]
        // `path=` is last and is taken as the remainder: the reply is not
        // quoted, so a helper under "/Volumes/Work Drive/…" used to report
        // `path=/Volumes/Work`: a nonexistent path printed as fact in the one
        // panel whose whole purpose is telling the truth about what runs as
        // root. `euid` and `build` still parsed, so the raw fallback never
        // fired either.
        var head = reply
        if let range = reply.range(of: " path=") {
            fields["path"] = String(reply[range.upperBound...])
            head = String(reply[..<range.lowerBound])
        }
        for token in head.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        return HelperIdentity(
            build: fields["build"],
            executablePath: fields["path"].flatMap { $0.isEmpty ? nil : $0 },
            euid: fields["euid"].flatMap(UInt32.init),
            raw: reply
        )
    }

    static func format(build: String, path: String, euid: UInt32) -> String {
        "ready euid=\(euid) build=\(build) path=\(path)"
    }

    var isRoot: Bool { euid == 0 }

    /// `nil` when the running helper matches this copy of Fennec, or when
    /// there is not enough information to say.
    func mismatch(againstAppBuild appBuild: String?) -> String? {
        guard let build, let appBuild, build != appBuild else { return nil }
        return "The helper running as root is build \(build); this copy of Fennec is build \(appBuild). "
            + "Disable and re-enable the helper to replace it."
    }

    /// What to show in the About panel. Always a complete sentence.
    var description: String {
        var parts: [String] = []
        if let build { parts.append("build \(build)") }
        if isRoot { parts.append("running as root") }
        if let executablePath { parts.append(executablePath) }
        return parts.isEmpty ? raw : parts.joined(separator: " · ")
    }
}
