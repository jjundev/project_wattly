import Foundation

/// Pure decisions for the battery charge limit, the counterpart to `FanControlPolicy`. Every
/// branch here is exercised by unit tests; the SwiftUI bridge and the settings screen only wire
/// them up.
public enum BatteryControlPolicy {
    /// How long to wait before re-checking that the helper still holds the user's limit. The helper
    /// comes back from a `KeepAlive` relaunch, a `kickstart`, or a crash with an empty configuration,
    /// and nothing else would notice: `onChange` needs a user edit and the wake notification needs a
    /// sleep. One status round-trip a minute is the cost of never silently losing the limit.
    ///
    /// A helper that keeps answering `.unsupported` is a different case: each re-push re-arms the
    /// engine's write budget, so a flat cadence would mean three failed SMC writes a minute forever
    /// on a Mac that will never accept one — exactly the loop the project forbids. Back off instead
    /// of stopping, so a genuinely transient failure still recovers on its own.
    public static func reconcileInterval(consecutiveUnsupported: Int) -> Double {
        switch consecutiveUnsupported {
        case ..<1: return 60.0
        case 1...3: return 300.0
        default: return 900.0
        }
    }

    /// How often the settings screen re-reads the helper's status while the limit is on. A one-shot
    /// read would freeze the status dot: the interesting moment — reaching the limit — happens
    /// minutes after the window opens.
    public static let statusPollInterval = 5.0

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
