import Foundation

/// Where Fennec is installed, and whether that will work.
///
/// `SMAppService` registration binds to the app's bundle path. Enabling the
/// helper from `~/Downloads` and later moving the app to Applications leaves
/// macOS holding a registration that points at a bundle which is no longer
/// there, and the only symptom Fennec can show for that is "Enabled, not
/// responding", which explains nothing.
///
/// The README documented this landmine. Documenting a landmine is not the
/// same as guarding it, so this is the guard.
enum InstallLocation: Equatable, Sendable {
    /// `/Applications` or `~/Applications`. Registration is durable here.
    case applications
    /// Anywhere else. Registration may work today and break on the next move.
    case elsewhere(String)
    /// A build running out of Xcode's DerivedData. Expected during
    /// development; not something to nag about in a release.
    case developmentBuild

    var isSupported: Bool {
        switch self {
        case .applications, .developmentBuild: return true
        case .elsewhere: return false
        }
    }

    /// `nil` when there is nothing to say.
    var warning: String? {
        switch self {
        case .applications:
            return nil
        case .developmentBuild:
            return "This is a development build running from Xcode's build folder. "
                + "Registration is tied to the bundle path, so it will break when the build is replaced."
        case .elsewhere(let folder):
            return "Fennec is running from \(folder). macOS ties the repair helper's registration to "
                + "the app's location, so moving Fennec later will silently break it. "
                + "Move Fennec to your Applications folder first."
        }
    }

    var actionTitle: String? {
        switch self {
        case .applications: return nil
        case .developmentBuild: return "Reveal in Finder"
        case .elsewhere: return "Move to Applications"
        }
    }

    /// Copies the running bundle into `/Applications`, replacing any older
    /// copy (the replaced one goes to the Trash, not oblivion). The caller
    /// relaunches from the returned URL; the original stays where it is for
    /// the user to discard, because deleting things out from under people is
    /// not this app's style.
    static func moveToApplications(bundleURL: URL = Bundle.main.bundleURL) throws -> URL {
        let destination = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(bundleURL.lastPathComponent)
        let source = bundleURL.standardizedFileURL
        guard source.path != destination.path else { return destination }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    static func current(bundleURL: URL = Bundle.main.bundleURL) -> InstallLocation {
        classify(bundleURL)
    }

    /// Pure, so the interesting cases are testable without moving the app.
    static func classify(_ bundleURL: URL) -> InstallLocation {
        let path = bundleURL.standardizedFileURL.path
        let parent = bundleURL.standardizedFileURL.deletingLastPathComponent()
        let parentPath = parent.path

        if parentPath == "/Applications" { return .applications }
        if parentPath.hasSuffix("/Applications") && parentPath.hasPrefix("/Users/") { return .applications }
        // Xcode products live under DerivedData/…/Build/Products/<config>.
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") { return .developmentBuild }

        // Say where it actually is, using the name a person would recognise.
        let folder = parentPath.hasPrefix(NSHomeDirectory())
            ? "~" + parentPath.dropFirst(NSHomeDirectory().count)
            : parentPath
        return .elsewhere(folder.isEmpty ? parentPath : String(folder))
    }
}
