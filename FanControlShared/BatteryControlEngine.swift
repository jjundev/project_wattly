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
        if config.enabled && !normalized.enabled && isCurrentlyInhibited {
            if attemptWrite(inhibited: false, targetLimit: 100) { isCurrentlyInhibited = false }
        }
        config = normalized
    }

    public func update(currentSoC: Int, isPluggedIn: Bool) -> BatteryControlServiceStatus {
        guard config.enabled && isPluggedIn else {
            if isCurrentlyInhibited || !hasInitializedState {
                if attemptWrite(inhibited: false, targetLimit: 100) { isCurrentlyInhibited = false }
            }
            hasInitializedState = true
            let detail: String
            if !config.enabled {
                detail = "충전 제한 비활성화됨"
            } else if lastWriteFailed {
                detail = "이 Mac에서 충전 제어를 적용하지 못했습니다"
            } else {
                detail = "배터리 전원으로 구동 중"
            }
            return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn, detail: detail)
        }

        hasInitializedState = true
        let target = config.clampedLimitPercentage

        // Only a transition writes. A failed write deliberately leaves `isCurrentlyInhibited`
        // alone, so the very same branch is re-entered on the next tick — that IS the retry, and
        // it costs no extra state. `attemptWrite` is what stops it after the bound.
        if isCurrentlyInhibited {
            if currentSoC <= config.resumePercentage,
               attemptWrite(inhibited: false, targetLimit: 100) {
                isCurrentlyInhibited = false
            }
        } else if currentSoC >= target,
                  attemptWrite(inhibited: true, targetLimit: target) {
            isCurrentlyInhibited = true
        }

        let detail: String
        if lastWriteFailed {
            detail = "이 Mac에서 충전 제어를 적용하지 못했습니다"
        } else if isCurrentlyInhibited {
            detail = "충전 제한 \(target)% 도달 (전원 어댑터 바이패스 구동)"
        } else {
            detail = "목표치(\(target)%)까지 충전 중"
        }
        return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn, detail: detail)
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
    @discardableResult
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

    private func status(currentSoC: Int, isPluggedIn: Bool, detail: String) -> BatteryControlServiceStatus {
        let mode: BatteryControlServiceMode
        if config.enabled && lastWriteFailed {
            // Only report unsupported for work the user actually asked for; a failed startup
            // normalization while the feature is off is not something to alarm them about.
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
            detail: detail,
            updatedAt: Date().timeIntervalSince1970,
            // Report the limit actually being enforced. A failed write means nothing is, and
            // reporting `nil` is what makes the app's reconcile pass re-push and clear the latch.
            appliedLimitPercentage: (config.enabled && !lastWriteFailed) ? config.clampedLimitPercentage : nil
        )
    }
}
