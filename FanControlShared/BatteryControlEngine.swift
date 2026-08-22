import Foundation

public protocol BatteryControlHardwareProtocol: Sendable {
    var isAppleSilicon: Bool { get }
    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool
}

public final class BatteryControlEngine: @unchecked Sendable {
    /// Consecutive failed SMC writes before the engine stops trying. The global constraint forbids
    /// writing registers in a loop, and a machine that rejects the write would otherwise be written
    /// to on every tick forever. Recovery is deliberately slow rather than busy: `configure` clears
    /// the latch, and the app's reconcile pass re-pushes the configuration about once a minute.
    public static let maxConsecutiveWriteFailures = 3

    private let hardware: BatteryControlHardwareProtocol
    private var config: BatteryControlConfiguration
    private var isCurrentlyInhibited: Bool = false
    private var hasInitializedState: Bool = false
    private var lastWriteFailed: Bool = false
    private var consecutiveWriteFailures: Int = 0

    private var isWriteLatched: Bool {
        consecutiveWriteFailures >= Self.maxConsecutiveWriteFailures
    }

    public init(hardware: BatteryControlHardwareProtocol, initialConfig: BatteryControlConfiguration = .init()) {
        self.hardware = hardware
        self.config = initialConfig.normalized
    }

    /// True while the engine still has something a fresh power reading could change. With the
    /// limit off and the charger already back to normal there is nothing to evaluate, so the
    /// daemon can skip its IOPS snapshot entirely instead of copying one on every tick.
    public var needsSampling: Bool {
        config.enabled || isCurrentlyInhibited || !hasInitializedState
    }

    public func configure(_ newConfig: BatteryControlConfiguration) {
        let normalized = newConfig.normalized
        // A new configuration is the user — or the app's reconcile pass — asking again, so clear
        // the latch and let the next tick spend a fresh set of attempts.
        consecutiveWriteFailures = 0
        lastWriteFailed = false
        if config.enabled && !normalized.enabled && isCurrentlyInhibited {
            if attemptWrite(inhibited: false, targetLimit: 100) { isCurrentlyInhibited = false }
        }
        config = normalized
    }

    public func update(currentSoC: Int, isPluggedIn: Bool) -> BatteryControlServiceStatus {
        // Until the hardware is confirmed at a known state the state machine cannot be trusted, so
        // it does not run at all. This also keeps a failing normalization from spending the write
        // budget on a transition whose starting point is a guess.
        guard normalizeOnFirstUpdate() else {
            return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn, target: config.clampedLimitPercentage)
        }

        let target = config.clampedLimitPercentage
        let shouldInhibit: Bool
        if config.enabled && isPluggedIn {
            // Hysteresis: cross up at the target, come back down only at the resume threshold.
            shouldInhibit = isCurrentlyInhibited
                ? currentSoC > config.resumePercentage
                : currentSoC >= target
        } else {
            shouldInhibit = false
        }

        if shouldInhibit != isCurrentlyInhibited {
            // Only a transition writes. A failed write deliberately leaves `isCurrentlyInhibited`
            // alone, so the very same comparison is re-entered on the next tick — that IS the
            // retry. `attemptWrite` is what stops it after the bound.
            if attemptWrite(inhibited: shouldInhibit, targetLimit: shouldInhibit ? target : 100) {
                isCurrentlyInhibited = shouldInhibit
            }
        } else {
            // Nothing is due, so nothing is failing. Without this a single transient failure would
            // mislabel a perfectly healthy engine as unsupported until the next transition — which
            // can be hours away, or never.
            consecutiveWriteFailures = 0
            lastWriteFailed = false
        }

        return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn, target: target)
    }

    /// Hands the hardware back to a known state before the state machine runs for the first time.
    /// A daemon that was SIGKILLed while inhibiting leaves the register latched; if the feature is
    /// on but the battery sits below the limit, no transition would ever fire to clear it and the
    /// Mac would stop charging permanently. Returns whether the engine may proceed.
    private func normalizeOnFirstUpdate() -> Bool {
        guard !hasInitializedState else { return true }
        if attemptWrite(inhibited: false, targetLimit: 100) {
            isCurrentlyInhibited = false
            hasInitializedState = true
            return true
        }
        if isWriteLatched {
            // Out of attempts. Stop blocking the rest of the machine on a write that will not land.
            hasInitializedState = true
            return true
        }
        return false
    }

    /// The last chance to hand the battery back before the daemon exits, so it bypasses the failure
    /// latch on purpose: leaving the register set would stop the Mac charging with no helper left
    /// to ever clear it.
    public func release() {
        guard isCurrentlyInhibited else { return }
        if hardware.setChargingInhibited(false, targetLimit: 100) {
            isCurrentlyInhibited = false
            consecutiveWriteFailures = 0
            lastWriteFailed = false
        }
    }

    /// Every routine hardware write goes through here, so the failure latch has exactly one home.
    private func attemptWrite(inhibited: Bool, targetLimit: Int) -> Bool {
        guard !isWriteLatched else { return false }
        if hardware.setChargingInhibited(inhibited, targetLimit: targetLimit) {
            consecutiveWriteFailures = 0
            lastWriteFailed = false
            return true
        }
        consecutiveWriteFailures += 1
        lastWriteFailed = true
        return false
    }

    private func detailText(isPluggedIn: Bool, target: Int) -> String {
        if lastWriteFailed {
            // A failed release is the opposite failure from a failed apply: control IS applied and
            // stuck on, so telling the user it could not be applied would be actively misleading.
            return isCurrentlyInhibited
                ? "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)"
                : "이 Mac에서 충전 제어를 적용하지 못했습니다"
        }
        if isCurrentlyInhibited { return "충전 제한 \(target)% 도달 (전원 어댑터 바이패스 구동)" }
        if !config.enabled { return "충전 제한 비활성화됨" }
        return isPluggedIn ? "목표치(\(target)%)까지 충전 중" : "배터리 전원으로 구동 중"
    }

    private func status(currentSoC: Int, isPluggedIn: Bool, target: Int) -> BatteryControlServiceStatus {
        let mode: BatteryControlServiceMode
        if lastWriteFailed && (config.enabled || isCurrentlyInhibited) {
            // `isCurrentlyInhibited` matters even with the feature off: a release that will not
            // land is the state where the Mac silently refuses to charge, so it must not be quiet.
            mode = .unsupported
        } else if isCurrentlyInhibited {
            mode = .inhibited
        } else {
            mode = .charging
        }
        return BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: currentSoC,
            isPowerAdapterConnected: isPluggedIn,
            detail: detailText(isPluggedIn: isPluggedIn, target: target),
            updatedAt: Date().timeIntervalSince1970,
            // Report the limit actually being enforced. A failed write means nothing is, and
            // reporting `nil` is what makes the app's reconcile pass re-push and clear the latch.
            appliedLimitPercentage: (config.enabled && !lastWriteFailed) ? config.clampedLimitPercentage : nil
        )
    }
}
