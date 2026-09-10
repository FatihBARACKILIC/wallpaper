import ServiceManagement

/// "Open at login" toggle. `SMAppService` registers the app itself, so there is
/// no helper bundle to ship.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether macOS still holds a registration for this app at all — including
    /// one waiting for the user's approval, which `isEnabled` reports as off.
    /// The uninstaller needs the difference: "not switched on" and "not
    /// registered" are not the same thing.
    static var isRegistered: Bool {
        switch SMAppService.mainApp.status {
        case .notRegistered, .notFound: false
        default: true
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
