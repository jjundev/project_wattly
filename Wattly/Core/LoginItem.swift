import Foundation
import ServiceManagement

/// The login-item seam (issue 13, F1). `SMAppService.mainApp` is the authoritative
/// source of truth; the `@AppStorage(loginItem)` flag is only a display MIRROR the
/// settings toggle reconciles against `isEnabled` on launch.
///
/// A protocol so the toggle's mirror/revert logic and `SettingsReset` are unit-testable
/// without touching the real `launchd` registration (which needs a Developer-ID signed
/// build to actually persist — see plan 13 가정 B; an ad-hoc build calls `register()`
/// without crashing but the OS won't honor it).
protocol LoginItemControlling: Sendable {
    /// Whether the app is currently registered to launch at login.
    var isEnabled: Bool { get }
    /// Register (`true`) or unregister (`false`). Synchronous + throwing — `SMAppService`
    /// exposes `register()`/`unregister()` as `throws`, NOT `async throws` (grill F6).
    func setEnabled(_ enabled: Bool) throws
}

/// Concrete `SMAppService.mainApp` wrapper. macOS 13+; the app targets 14.0 so no
/// `#available` guard is needed (grill D).
struct LoginItem: LoginItemControlling {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            // register() is idempotent-ish: re-registering an already-enabled app is a no-op.
            try service.register()
        } else {
            // Unregistering when not registered throws; treat "already off" as success.
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }
}
