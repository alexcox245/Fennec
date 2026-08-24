import Foundation
import Security

enum CodeSigningRequirementError: LocalizedError {
    case cannotInspectSelf(OSStatus)
    case missingSigningInformation
    case missingTeamIdentifier

    var errorDescription: String? {
        switch self {
        case .cannotInspectSelf(let status):
            return "Could not inspect this executable's code signature (OSStatus \(status))."
        case .missingSigningInformation:
            return "The executable has no readable code-signing information."
        case .missingTeamIdentifier:
            return "The executable has no Team ID. Select an Apple Development or Developer ID signing team in Xcode."
        }
    }
}

enum CodeSigningRequirement {
    static func peerRequirement(bundleIdentifier: String) throws -> String {
        if let teamIdentifier = try currentTeamIdentifier() {
            return "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        }

        #if DEBUG
        // Ad-hoc signing is useful for local development, but identifier-only
        // validation is deliberately limited to DEBUG builds.
        return "identifier \"\(bundleIdentifier)\""
        #else
        throw CodeSigningRequirementError.missingTeamIdentifier
        #endif
    }

    private static func currentTeamIdentifier() throws -> String? {
        var code: SecCode?
        let copySelfStatus = SecCodeCopySelf([], &code)
        guard copySelfStatus == errSecSuccess, let code else {
            throw CodeSigningRequirementError.cannotInspectSelf(copySelfStatus)
        }

        // SecCodeRef and SecStaticCodeRef share the same underlying opaque
        // struct; the C API accepts a dynamic code object here, but Swift
        // imports the two typedefs as unrelated types.
        let staticCode = unsafeBitCast(code, to: SecStaticCode.self)

        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard informationStatus == errSecSuccess else {
            throw CodeSigningRequirementError.cannotInspectSelf(informationStatus)
        }
        guard let information = rawInformation as? [String: Any] else {
            throw CodeSigningRequirementError.missingSigningInformation
        }

        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
