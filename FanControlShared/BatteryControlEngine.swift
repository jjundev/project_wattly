import Foundation

public protocol BatteryControlHardwareProtocol: Sendable {
    /// Which charge-control register generation this Mac exposes, probed from the hardware rather
    /// than inferred from the architecture, the model or the macOS version — the generation tracks
    /// the firmware, which moves under a machine that never changed.
    var registerSet: BatteryControlRegisterSet { get }
    func readChargingGate(targetLimit: Int) -> BatteryHardwareGate
    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool
    func releaseChargingControlAndVerify() -> BatteryReleaseVerdict
}

public extension BatteryControlHardwareProtocol {
    /// Production parsing is supplied by the hardware adapter. Until an adapter implements
    /// readback, the only safe answer is that the gate could not be verified.
    func readChargingGate(targetLimit: Int) -> BatteryHardwareGate { .unreadable }

    /// Production verified release is supplied by the hardware adapter in the generation parser
    /// slice. An adapter without that implementation cannot prove that it is safe to stop.
    func releaseChargingControlAndVerify() -> BatteryReleaseVerdict { .failed }
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
    private var lastVerifiedGate: BatteryHardwareGate?

    private var isWriteLatched: Bool {
        consecutiveWriteFailures >= Self.maxConsecutiveWriteFailures
    }

    /// The engine is failing at work that matters: either the user asked for the limit, or the
    /// hardware is still inhibiting and the release will not land — the state where the Mac
    /// silently refuses to charge. A failure on work nobody asked for stays quiet.
    private var hasActionableFailure: Bool {
        lastWriteFailed && (config.enabled || isCurrentlyInhibited)
    }

    /// A permanent fact about the Mac, not a state the engine can retry its way out of. Public
    /// because the daemon builds a status by hand when the power source cannot be read at all, and
    /// that status has to carry the same answer — otherwise the one machine class most likely to be
    /// unsupported is the one that never reports it.
    public var isHardwareSupported: Bool {
        hardware.registerSet.canDriveCharging
    }

    public init(
        hardware: BatteryControlHardwareProtocol,
        initialConfig: BatteryControlConfiguration = .init()
    ) {
        self.hardware = hardware
        self.config = initialConfig.normalized
    }

    public var configuration: BatteryControlConfiguration { config }

    public func beginRecoveryWindow() {
        consecutiveWriteFailures = 0
        lastWriteFailed = false
    }

    @discardableResult
    public func hydrateHardwareState() -> BatteryHardwareGate {
        let gate = hardware.readChargingGate(
            targetLimit: config.clampedLimitPercentage)
        lastVerifiedGate = gate
        switch gate.state {
        case .allowed:
            isCurrentlyInhibited = false
            hasInitializedState = true
        case .inhibited:
            isCurrentlyInhibited = true
            hasInitializedState = true
        case .unreadable, .unrecognized:
            if attemptWrite(inhibited: false, targetLimit: 100) {
                isCurrentlyInhibited = false
                hasInitializedState = true
            } else {
                hasInitializedState = false
            }
        }
        return lastVerifiedGate ?? .unreadable
    }

    public func verifyAndUpdate(
        currentSoC: Int,
        isPluggedIn: Bool
    ) -> BatteryControlServiceStatus {
        let gate = hydrateHardwareState()
        if gate.state == .inhibited {
            let staleIntelLimit = gate.appliedLimitPercentage.map {
                $0 != config.clampedLimitPercentage
            } ?? false
            if staleIntelLimit {
                guard attemptWrite(inhibited: false, targetLimit: 100) else {
                    hasInitializedState = false
                    return status(
                        currentSoC: currentSoC,
                        isPluggedIn: isPluggedIn,
                        target: config.clampedLimitPercentage)
                }
                isCurrentlyInhibited = false
                hasInitializedState = true
            }
        }
        guard hasInitializedState else {
            return verificationFailureStatus(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn)
        }
        return update(currentSoC: currentSoC, isPluggedIn: isPluggedIn)
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
        // A new configuration is the user — or the app's reconcile pass — asking again, so clear
        // the latch and let the next tick spend a fresh set of attempts.
        beginRecoveryWindow()
        config = newConfig.normalized
    }

    /// Legacy wake entry point retained until the daemon moves to `verifyAndUpdate`. It reasserts
    /// only a believed active hold and still verifies the write through `attemptWrite`.
    public func reassertHardwareState() {
        guard config.enabled, isCurrentlyInhibited else { return }
        if !attemptWrite(inhibited: true, targetLimit: config.clampedLimitPercentage) {
            // The reassertion did not verify, so the next update must rebuild a known baseline.
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

    /// Legacy shutdown entry point retained until daemon coordination uses `releaseVerified`.
    /// Unlike all new paths, it preserves the installed helper's one unverified last-chance write.
    public func release() {
        guard isCurrentlyInhibited || !hasInitializedState else { return }
        if hardware.setChargingInhibited(false, targetLimit: 100) {
            isCurrentlyInhibited = false
            consecutiveWriteFailures = 0
            lastWriteFailed = false
        }
    }

    public func releaseVerified() -> BatteryReleaseVerdict {
        guard !isWriteLatched else { return .failed }
        let verdict = hardware.releaseChargingControlAndVerify()
        guard verdict.isSafeToRemove else {
            consecutiveWriteFailures += 1
            lastWriteFailed = true
            return verdict
        }
        isCurrentlyInhibited = false
        hasInitializedState = true
        beginRecoveryWindow()
        lastVerifiedGate = verdict == .verifiedAllowed ? .allowed : .unreadable
        return verdict
    }

    private func gateMatches(
        _ gate: BatteryHardwareGate,
        inhibited: Bool,
        targetLimit: Int
    ) -> Bool {
        if inhibited {
            guard gate.state == .inhibited else { return false }
            return gate.appliedLimitPercentage.map { $0 == targetLimit } ?? true
        }
        return gate.state == .allowed
    }

    /// Every routine hardware write and its readback go through here, so the failure latch has
    /// exactly one home and a write acknowledgement is never mistaken for verified hardware state.
    private func attemptWrite(inhibited: Bool, targetLimit: Int) -> Bool {
        guard !isWriteLatched else { return false }
        guard hardware.setChargingInhibited(inhibited, targetLimit: targetLimit) else {
            consecutiveWriteFailures += 1
            lastWriteFailed = true
            return false
        }
        let verified = hardware.readChargingGate(targetLimit: targetLimit)
        guard gateMatches(verified, inhibited: inhibited, targetLimit: targetLimit) else {
            consecutiveWriteFailures += 1
            lastWriteFailed = true
            lastVerifiedGate = verified
            return false
        }
        lastVerifiedGate = verified
        consecutiveWriteFailures = 0
        lastWriteFailed = false
        return true
    }

    private func detailReason(isPluggedIn: Bool, target: Int, currentSoC: Int) -> BatteryControlStatusReason {
        if !isHardwareSupported { return .init(kind: .hardwareUnsupported) }
        if hasActionableFailure {
            // A failed release is the opposite failure from a failed apply: control IS applied and
            // stuck on, so telling the user it could not be applied would be actively misleading.
            return .init(kind: isCurrentlyInhibited ? .releaseFailed : .applyFailed)
        }
        if isCurrentlyInhibited {
            if currentSoC < target {
                return .init(kind: .sailing, limitPercentage: target, resumePercentage: config.resumePercentage)
            }
            return .init(kind: .inhibitedAtLimit, limitPercentage: target)
        }
        if !config.enabled { return .init(kind: .limitDisabled) }
        return isPluggedIn
            ? .init(kind: .chargingToTarget, limitPercentage: target)
            : .init(kind: .onBatteryPower)
    }

    private func status(currentSoC: Int, isPluggedIn: Bool, target: Int) -> BatteryControlServiceStatus {
        let reason = detailReason(isPluggedIn: isPluggedIn, target: target, currentSoC: currentSoC)
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
            // Derived from the reason so the two can never disagree — an older app reads this
            // sentence while a current one reads the code beside it.
            detail: reason.legacyKoreanDetail,
            updatedAt: Date().timeIntervalSince1970,
            // Report the limit actually being enforced. A failed write means nothing is, and so
            // does a Mac with no register — reporting `nil` is what makes the app's reconcile pass
            // re-push and clear the latch in the one of those two cases that can recover.
            appliedLimitPercentage: (isHardwareSupported && config.enabled && !hasActionableFailure)
                ? config.clampedLimitPercentage : nil,
            isHardwareSupported: isHardwareSupported,
            detailReason: reason,
            // The reason is already the single authoritative decision for this sample. Deriving
            // activity here keeps the new app, the legacy sentence, and the hardware mode aligned.
            activity: BatteryControlActivity.inferred(from: reason),
            actualGate: lastVerifiedGate
        )
    }

    private func verificationFailureStatus(
        currentSoC: Int,
        isPluggedIn: Bool
    ) -> BatteryControlServiceStatus {
        let reason = BatteryControlStatusReason(kind: .hardwareReadbackFailed)
        return BatteryControlServiceStatus(
            mode: .unsupported,
            currentPercentage: currentSoC,
            isPowerAdapterConnected: isPluggedIn,
            detail: reason.legacyKoreanDetail,
            updatedAt: Date().timeIntervalSince1970,
            appliedLimitPercentage: nil,
            isHardwareSupported: isHardwareSupported,
            detailReason: reason,
            activity: nil,
            actualGate: lastVerifiedGate ?? .unreadable)
    }
}
