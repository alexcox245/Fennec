import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var lastError: String?

    private let service = SMAppService.mainApp

    init() {
        refresh()
    }

    func refresh() {
        isEnabled = service.status == .enabled
        requiresApproval = service.status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if service.status == .notRegistered || service.status == .notFound {
                    try service.register()
                }
            } else if service.status != .notRegistered && service.status != .notFound {
                try service.unregister()
            }
            lastError = nil
        } catch {
            refresh()
            if enabled && (service.status == .requiresApproval || service.status == .enabled) {
                lastError = nil
            } else {
                lastError = error.localizedDescription
                return
            }
        }

        refresh()
        if requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
