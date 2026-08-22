import Foundation

/// Pure decisions for the battery charge limit, the counterpart to `FanControlPolicy`. Every
/// branch here is exercised by unit tests; the SwiftUI bridge and the settings screen only wire
/// them up.
public enum BatteryControlPolicy {
    /// How often the always-mounted bridge re-checks that the helper still holds the user's limit.
    /// The helper comes back from a `KeepAlive` relaunch, a `kickstart`, or a crash with an empty
    /// configuration, and nothing else would notice: `onChange` needs a user edit and the wake
    /// notification needs a sleep. One status round-trip a minute is the cost of never silently
    /// losing the limit.
    public static let reconcileInterval = 60.0

    /// True when the helper is reachable but is not enforcing the limit the user opted into.
    /// `.unavailable` is left alone on purpose — installing or connecting belongs to the settings
    /// screen, where the user can see an auth prompt, not to a background loop.
    public static func shouldReapply(enabled: Bool,
                                     limitPercentage: Int,
                                     status: BatteryControlServiceStatus) -> Bool {
        guard enabled, status.mode != .unavailable else { return false }
        return status.appliedLimitPercentage != limitPercentage
    }

    /// True when turning the opt-in on has to run the privileged installer. A helper that already
    /// answers is reused, so enabling the charge limit after fan control never asks for a second
    /// admin authentication.
    public static func shouldRunInstaller(mode: BatteryControlServiceMode) -> Bool {
        mode == .unavailable
    }
}
