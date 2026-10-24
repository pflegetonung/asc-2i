import Foundation
import Observation
import ServiceManagement

/// Обёртка над SMAppService: регистрирует само приложение как Login Item.
@Observable final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    private(set) var status = SMAppService.mainApp.status
    private(set) var lastError: String?

    var isEnabled: Bool {
        get { status == .enabled || status == .requiresApproval }
        set { setEnabled(newValue) }
    }

    var requiresApproval: Bool { status == .requiresApproval }

    /// При самом первом запуске включаем автозапуск — это поведение по умолчанию.
    func enableOnFirstLaunch() {
        let key = "didConfigureLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}
