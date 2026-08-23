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
    /// A helper that keeps answering `.unsupported` on hardware that *does* have a register — the
    /// write reaches it and is refused — is a different case: each re-push re-arms the engine's
    /// write budget, so a flat cadence would mean three failed SMC writes a minute forever. Back off
    /// instead of stopping, so a genuinely transient failure still recovers on its own.
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

    /// Minimum spacing between hardware re-asserts. `configureBattery` is an XPC entry point, so its
    /// call rate is set by whatever is calling it rather than by the helper — and a re-assert is by
    /// construction a non-transitioning write, the one thing the SMC-traffic rule forbids doing in a
    /// loop. The real callers (an app launch, a wake, a settings edit) are minutes apart, so a floor
    /// costs them nothing and bounds everything else. A skipped re-assert is harmless: the next
    /// launch, wake, or edit push covers it, as does the next hysteresis transition. Note the app's
    /// reconcile pass is NOT what covers it — that compares an applied limit derived from
    /// configuration, so a silently cleared register looks like perfect agreement to it.
    public static let reassertMinimumInterval = 60.0

    /// Whether enough time has passed since the last hardware re-assert to allow another.
    public static func shouldReassert(now: TimeInterval, lastReassertAt: TimeInterval?) -> Bool {
        guard let lastReassertAt else { return true }
        return now - lastReassertAt >= reassertMinimumInterval
    }

    public static func supportsPersistentPolicy(status: BatteryControlServiceStatus) -> Bool {
        status.capabilities?.contains(.persistedPolicyV1) == true
            && status.capabilities?.contains(.hardwareGateReadbackV1) == true
            && status.capabilities?.contains(.systemPowerEventsV1) == true
    }

    /// True when the helper is reachable but does not have the requested normalized policy.
    /// `.unavailable` is left alone on purpose — installing or connecting belongs to the settings
    /// screen, where the user can see an auth prompt, not to a background loop.
    public static func shouldReapply(
        configuration: BatteryControlConfiguration,
        status: BatteryControlServiceStatus
    ) -> Bool {
        let requested = configuration.normalized
        guard status.mode != .unavailable else { return false }
        // Hardware with no charge-control register will never accept the configuration, so
        // re-pushing is not a recovery there — just traffic. `nil` is "unknown" and still retries.
        guard status.isHardwareSupported != false else { return false }
        if supportsPersistentPolicy(status: status), let desired = status.desiredConfiguration {
            return desired.normalized != requested
        }
        if requested.enabled {
            return status.appliedLimitPercentage != requested.clampedLimitPercentage
        }
        return status.appliedLimitPercentage != nil || status.mode == .inhibited
    }

    /// A configure response is accepted only when it acknowledges the entire normalized policy
    /// and did not record a failed maintenance pass. Disabled policies additionally require
    /// hardware release evidence before the UI can present them as settled.
    public static func accepted(
        configuration: BatteryControlConfiguration,
        by status: BatteryControlServiceStatus
    ) -> Bool {
        guard status.desiredConfiguration?.normalized == configuration.normalized,
              let maintenance = status.lastMaintenance,
              maintenance.result != .failed else { return false }
        if !configuration.enabled {
            return status.actualGate?.state == .allowed
                || status.releaseVerdict?.isSafeToRemove == true
        }
        guard maintenance.trigger == .clientConfiguration,
              maintenance.result == .applied || maintenance.result == .verified else { return false }
        guard let gate = status.actualGate else { return false }
        return gate.state != .unreadable && gate.state != .unrecognized
    }

    /// True when turning the opt-in on has to run the privileged installer. A helper that already
    /// answers is reused, so enabling the charge limit after fan control never asks for a second
    /// admin authentication.
    public static func shouldRunInstaller(mode: BatteryControlServiceMode) -> Bool {
        mode == .unavailable
    }
}
