import Foundation

public protocol BatteryControlHardwareProtocol: Sendable {
    /// Which charge-control register generation this Mac exposes, probed from the hardware rather
    /// than inferred from the architecture.
    var registerSet: BatteryControlRegisterSet { get }
    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool
}

public final class BatteryControlEngine: @unchecked Sendable {
    /// Consecutive failed SMC writes before the engine stops trying. The global constraint forbids
    /// writing registers in a loop, and a machine that rejects the write would otherwise be written
    /// to on every tick forever. Recovery is deliberately slow rather than busy: `configure` clears
    /// the latch, and the app's reconcile pass re-pushes the configuration, backing its cadence off
    /// the longer the hardware keeps refusing.
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

    /// The engine is failing at work that matters: either the user asked for the limit, or the
    /// hardware is still inhibiting and the release will not land — the state where the Mac
    /// silently refuses to charge. A failure on work nobody asked for stays quiet.
    private var hasActionableFailure: Bool {
        lastWriteFailed && (config.enabled || isCurrentlyInhibited)
    }

    /// A permanent fact about the Mac, not a state the engine can retry its way out of.
    private var isHardwareSupported: Bool {
        hardware.registerSet != .unsupported
    }

    public init(hardware: BatteryControlHardwareProtocol, initialConfig: BatteryControlConfiguration = .init()) {
        self.hardware = hardware
        self.config = initialConfig.normalized
    }

    /// True while the engine still has something a fresh power reading could change. With the
    /// limit off and the charger already back to normal there is nothing to evaluate, so the
    /// daemon can skip its IOPS snapshot entirely instead of copying one on every tick. A parked
    /// engine that has exhausted its write budget is included in that: it cannot act on a sample
    /// until `configure` re-arms it, and `configure` clears the latch.
    public var needsSampling: Bool {
        // A Mac with no charge-control register cannot act on any reading, so it should never ask
        // the daemon for one. The XPC status path forces a sample regardless, so the settings
        // screen still gets a fresh answer to show.
        guard isHardwareSupported else { return false }
        return config.enabled || isCurrentlyInhibited || (!hasInitializedState && !isWriteLatched)
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

    /// Re-writes the charge-inhibit register to what the engine already believes, rather than
    /// trusting that a sleep cycle preserved it. Nothing downstream could detect a register cleared
    /// behind the engine's back: the reported applied limit is derived from configuration, not from
    /// the register, so the app's reconcile pass would see perfect agreement and do nothing.
    ///
    /// Only an active inhibit needs this. Nothing but this engine ever sets the register, so a
    /// belief of "not inhibiting" cannot silently drift into the opposite.
    ///
    /// The opt-in is part of the condition too: if the user has switched the limit off and the
    /// release write has not landed yet, re-asserting would push the hardware the wrong way while
    /// the next tick is still trying to let go.
    ///
    /// This deliberately does NOT route through `normalizeOnFirstUpdate`. That path exists for a
    /// cold start, where the belief is worthless, and it clears `isCurrentlyInhibited` as part of
    /// forcing a known baseline. On wake the belief is the very thing worth keeping: erasing it
    /// would drop a hold the hysteresis band still wants, and a battery resting at 84 % under an
    /// 85 % limit would resume charging on every lid-open.
    public func reassertHardwareState() {
        guard config.enabled, isCurrentlyInhibited else { return }
        if !attemptWrite(inhibited: true, targetLimit: config.clampedLimitPercentage) {
            // The re-assert did not land, so the register's real state is now genuinely unknown.
            // Hand it to the normalization gate, which parks and reports honestly until a write
            // succeeds — and a nil applied limit is what makes the app re-push and re-arm the budget.
            // Handing this to the normalization gate deliberately costs an in-band hold: the gate
            // releases before re-deriving, so a battery resting between the resume and target
            // thresholds recharges once. That is the price of never guessing at a register we could
            // not write, and it is gated behind an SMC write failure rather than any normal path.
            hasInitializedState = false
        }
    }

    public func update(currentSoC: Int, isPluggedIn: Bool) -> BatteryControlServiceStatus {
        // No register means no write can ever succeed. Short-circuit before the normalization gate
        // so the budget is not spent proving a permanent fact three times over.
        guard isHardwareSupported else {
            return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn,
                          target: config.clampedLimitPercentage)
        }

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
    /// Mac would stop charging permanently.
    ///
    /// There is deliberately no give-up branch. Until this write lands, the engine's idea of the
    /// hardware state is a guess, and running the state machine on a guess is how a stuck battery
    /// becomes a silent one. Parking here keeps the status honest (`.unsupported`, nil applied
    /// limit), which is exactly the signal the app's reconcile pass re-pushes `configure` on — and
    /// `configure` clears the latch, buying another set of attempts.
    /// `attemptWrite` still caps the hardware calls at `maxConsecutiveWriteFailures`, so parking
    /// costs no further SMC traffic until the next `configure` re-arms the budget —
    /// `BatteryControlPolicy.reconcileInterval(consecutiveUnsupported:)` is what keeps those
    /// re-arms far apart.
    private func normalizeOnFirstUpdate() -> Bool {
        guard !hasInitializedState else { return true }
        guard attemptWrite(inhibited: false, targetLimit: 100) else { return false }
        isCurrentlyInhibited = false
        hasInitializedState = true
        return true
    }

    /// The last chance to hand the battery back before the daemon exits, so it bypasses the failure
    /// latch on purpose: leaving the register set would stop the Mac charging with no helper left
    /// to ever clear it. An engine that never confirmed the hardware state is included — that is
    /// precisely the crashed-daemon case, where the register may well be latched and this is the
    /// only remaining chance to clear it. Worst case is one extra failed write per daemon exit.
    public func release() {
        guard isCurrentlyInhibited || !hasInitializedState else { return }
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
        if !isHardwareSupported { return "이 Mac은 충전 제어를 지원하지 않습니다" }
        if hasActionableFailure {
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
        if !isHardwareSupported || hasActionableFailure {
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
            // Report the limit actually being enforced. A failed write means nothing is, and so
            // does a Mac with no register — reporting `nil` is what makes the app's reconcile pass
            // re-push and clear the latch in the one of those two cases that can recover.
            appliedLimitPercentage: (isHardwareSupported && config.enabled && !hasActionableFailure)
                ? config.clampedLimitPercentage : nil,
            isHardwareSupported: isHardwareSupported
        )
    }
}
