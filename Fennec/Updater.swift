import AppKit
import Combine
import Foundation
import Sparkle

enum UpdatePresentation: Equatable {
    case idle
    case checking
    case available(version: String, releaseNotes: String, informationOnly: Bool, informationURL: URL?)
    case downloading(progress: Double?)
    case extracting(progress: Double?)
    case preparingInstall(version: String)
    case readyToInstall(version: String)
    case installing
    case current
    case failed(String)
}

/// The updater is deliberately user initiated. Sparkle supplies the signed
/// download and installer; this driver keeps every decision in About so an
/// update never arrives or installs on its own.
@MainActor
final class FennecUpdateDriver: NSObject, ObservableObject, SPUUserDriver {
    @Published private(set) var presentation: UpdatePresentation = .idle

    var prepareForInstall: (() async -> Bool)?
    var updateCancelled: (() -> Void)?

    private enum ChoiceKind {
        case available
        case installation
    }

    private var cancellation: (() -> Void)?
    private var pendingChoice: CheckedContinuation<SPUUserUpdateChoice, Never>?
    private var pendingChoiceKind: ChoiceKind?
    private var installAttempt = UUID()
    private var receivedBytes: UInt64 = 0
    private var expectedBytes: UInt64?
    private var versionBeingInstalled = ""

    func show(_ request: SPUUpdatePermissionRequest) async -> SUUpdatePermissionResponse {
        // Updates are checked only after the user presses Check for Updates.
        // No system profile is ever sent to the feed.
        SUUpdatePermissionResponse(
            automaticUpdateChecks: false,
            automaticUpdateDownloading: NSNumber(value: false),
            sendSystemProfile: false
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        presentation = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState) async -> SPUUserUpdateChoice {
        let version = appcastItem.displayVersionString
        versionBeingInstalled = version
        let notes = appcastItem.itemDescription.map(Self.plainText(from:)) ?? ""
        let updateIsAlreadyDownloaded = state.stage == .downloaded || state.stage == .installing
        if updateIsAlreadyDownloaded && !appcastItem.isInformationOnlyUpdate {
            presentation = .readyToInstall(version: version)
        } else {
            presentation = .available(
                version: version,
                releaseNotes: notes,
                informationOnly: appcastItem.isInformationOnlyUpdate,
                informationURL: appcastItem.infoURL
            )
        }
        return await withCheckedContinuation { continuation in
            finishPendingChoice(with: .dismiss)
            pendingChoiceKind = updateIsAlreadyDownloaded ? .installation : .available
            pendingChoice = continuation
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard case let .available(version, _, informationOnly, informationURL) = presentation else { return }
        let notes = String(data: downloadData.data, encoding: .utf8).map(Self.plainText(from:)) ?? ""
        presentation = .available(
            version: version,
            releaseNotes: notes,
            informationOnly: informationOnly,
            informationURL: informationURL
        )
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // The release itself can still be reviewed and installed; the
        // download failure does not invalidate the signed update.
    }

    func showUpdateNotFoundWithError(_ error: any Error) async {
        let userInfo = (error as NSError).userInfo
        let reason = (userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: OSStatus($0.int32Value)) }
        switch reason {
        case .onLatestVersion, .onNewerThanLatestVersion, .none:
            presentation = .current
        case .systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64:
            presentation = .failed("No compatible Fennec update is available for this Mac.")
        case .unknown:
            presentation = .failed(error.localizedDescription)
        @unknown default:
            presentation = .failed(error.localizedDescription)
        }
        cancellation = nil
    }

    func showUpdaterError(_ error: any Error) async {
        updateCancelled?()
        presentation = .failed(error.localizedDescription)
        cancellation = nil
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        receivedBytes = 0
        presentation = .downloading(progress: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength > 0 ? expectedContentLength : nil
        publishDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        publishDownloadProgress()
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        presentation = .extracting(progress: nil)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        presentation = .extracting(progress: min(max(progress, 0), 1))
    }

    func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        presentation = .readyToInstall(version: versionBeingInstalled)
        return await withCheckedContinuation { continuation in
            finishPendingChoice(with: .skip)
            pendingChoiceKind = .installation
            pendingChoice = continuation
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        presentation = .installing
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool) async {
        presentation = .current
    }

    func dismissUpdateInstallation() {
        let wasPreparing = pendingChoiceKind == .installation
            || isPreparingInstall
        finishPendingChoice(with: .skip)
        if wasPreparing { updateCancelled?() }
        cancellation = nil
        if case .installing = presentation { return }
        presentation = .idle
    }

    var isPreparingInstall: Bool {
        if case .preparingInstall = presentation { return true }
        return false
    }

    func chooseDownload() {
        finishPendingChoice(with: .install)
    }

    func cancelAvailableUpdate() {
        finishPendingChoice(with: .dismiss)
        presentation = .idle
    }

    func openInformationURL() {
        guard case let .available(_, _, true, url?) = presentation else { return }
        NSWorkspace.shared.open(url)
        finishPendingChoice(with: .dismiss)
    }

    func cancelCurrentOperation() {
        if pendingChoiceKind == .installation || isPreparingInstall {
            cancelPendingInstallation()
            return
        }

        let cancel = cancellation
        cancellation = nil
        cancel?()
        finishPendingChoice(with: .dismiss)
        presentation = .idle
    }

    func installAndRelaunch() {
        guard pendingChoiceKind == .installation else { return }
        let attempt = UUID()
        installAttempt = attempt
        presentation = .preparingInstall(version: versionBeingInstalled)
        Task { [weak self] in
            guard let self else { return }
            let prepared = await prepareForInstall?() ?? true
            guard installAttempt == attempt else { return }
            guard prepared else {
                finishPendingChoice(with: .skip)
                presentation = .failed("Fennec could not prepare this update. Check the helper status and try again; your existing repair setup is still available.")
                updateCancelled?()
                return
            }
            cancellation = nil
            presentation = .installing
            finishPendingChoice(with: .install)
        }
    }

    func cancelPendingInstallation() {
        installAttempt = UUID()
        let hadChoice = pendingChoiceKind == .installation || isPreparingInstall
        finishPendingChoice(with: .skip)
        if hadChoice { updateCancelled?() }
        cancellation = nil
        presentation = .idle
    }

    func cancelForWindowClose() {
        switch presentation {
        case .checking, .downloading, .extracting:
            cancelCurrentOperation()
        case .available:
            cancelAvailableUpdate()
        case .readyToInstall, .preparingInstall:
            cancelPendingInstallation()
        case .idle, .installing, .current, .failed:
            break
        }
    }

    func presentConfigurationError(_ message: String) {
        presentation = .failed("Fennec could not start update checking: \(message)")
    }

    private func finishPendingChoice(with choice: SPUUserUpdateChoice) {
        guard let pendingChoice else { return }
        self.pendingChoice = nil
        pendingChoiceKind = nil
        pendingChoice.resume(returning: choice)
    }

    private func publishDownloadProgress() {
        let progress = expectedBytes.map { expected in
            min(Double(receivedBytes) / Double(expected), 1)
        }
        presentation = .downloading(progress: progress)
    }

    private static func plainText(from source: String) -> String {
        source
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

@MainActor
final class FennecUpdater: NSObject, ObservableObject {
    static let helperWasRegisteredKey = "updateHelperWasRegistered"
    static var hasUpdateCache: Bool { FennecUpdateCache.exists }

    let driver: FennecUpdateDriver
    private let updater: SPUUpdater
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        driver = FennecUpdateDriver()
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: nil
        )
        super.init()

        driver.prepareForInstall = { [weak self] in
            await self?.model?.prepareForUpdateInstall() ?? true
        }
        driver.updateCancelled = { [weak self] in
            self?.model?.cancelUpdateInstallation()
        }
        model.updaterController = self

        do {
            try updater.start()
        } catch {
            driver.presentConfigurationError(error.localizedDescription)
        }
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    func checkForUpdates() {
        guard updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }
}
