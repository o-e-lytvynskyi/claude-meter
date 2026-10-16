import ServiceManagement

/// Login-item state, backed by `SMAppService` (macOS 13+). Nothing is stored in
/// UserDefaults — the registration itself is the source of truth, so the
/// checkmark cannot drift from what the system actually does.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Returns an error text, nil on success.
    static func apply(_ wanted: Bool) -> String? {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return error.localizedDescription
        }
        return needsApproval ? "Approve ClaudeMeter in System Settings → General → Login Items." : nil
    }
}
