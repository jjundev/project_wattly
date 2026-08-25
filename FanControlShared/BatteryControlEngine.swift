import Foundation

public protocol BatteryControlHardwareProtocol: Sendable {
    /// Which charge-control register generation this Mac exposes, probed from the hardware rather
    /// than inferred from the architecture, the model or the macOS version — the generation tracks
    /// the firmware, which moves under a machine that never changed.
    var registerSet: BatteryControlRegisterSet { get }
    func readChargingGate(targetLimit: Int) -> BatteryHardwareGate
    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool
    func setDischargingActive(_ active: Bool) -> Bool
    func releaseChargingControlAndVerify() -> BatteryReleaseVerification
}

public final class BatteryControlEngine: @unchecked Sendable {
    private enum FailureProvenance: Equatable {
        case ordinary
        case verifiedRelease
    }

    /// Consecutive failed SMC writes before the engine stops trying. The global constraint forbids
    /// writing registers in a loop, and a machine that rejects the write would otherwise be written
    /// to on every tick forever. Recovery is deliberately slow rather than busy: `configure` clears
    /// the latch, and the app's reconcile pass re-pushes the configuration, backing its cadence off
    /// the longer the hardware keeps refusing.
    public static let maxConsecutiveWriteFailures = 3

    private let hardware: BatteryControlHardwareProtocol
    private var config: BatteryControlConfiguration
    private var isCurrentlyInhibited: Bool = false
    private var isCurrentlyDischarging: Bool = false
    private var topUpCompletedHold: Bool = false
    private var hasInitializedState: Bool = false
    private var lastWriteFailed: Bool = false
    private var consecutiveWriteFailures: Int = 0
    private var failureProvenance: FailureProvenance?
    private var lastVerifiedGate: BatteryHardwareGate?
    private var isInHeatProtection: Bool = false
    private var heatProtectionTriggeredAt: TimeInterval?

    private var isWriteLatched: Bool {
        consecutiveWriteFailures >= Self.maxConsecutiveWriteFailures
    }

    /// The engine is failing at work that matters: either the user asked for the limit, or the
    /// hardware is still inhibiting and the release will not land — the state where the Mac
    /// silently refuses to charge. A failure on work nobody asked for stays quiet.
    private var hasActionableFailure: Bool {
        lastWriteFailed && (config.isActive || isCurrentlyInhibited || isCurrentlyDischarging)
    }

    /// A permanent fact about the Mac, not a state the engine can retry its way out of. Public
    /// because the daemon builds a status by hand when the power source cannot be read at all, and
    /// that status has to carry the same answer — otherwise the one machine class most likely to be
    /// unsupported is the one that never reports it.
    public var isHardwareSupported: Bool {
        hardware.registerSet.canDriveCharging
    }

    /// Whether the Mac's hardware supports active discharge control via CHIE.
    public var isDischargeHardwareSupported: Bool {
        hardware.registerSet.isDischargeSupported
    }

    public init(
        hardware: BatteryControlHardwareProtocol,
        initialConfig: BatteryControlConfiguration = .init()
    ) {
        self.hardware = hardware
        self.config = initialConfig.normalized
    }

    public var configuration: BatteryControlConfiguration { config }

    func statusForCurrentBelief(
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> BatteryControlServiceStatus {
        let target = config.topUpActive ? 100 : (config.manualDischargeActive ? config.clampedManualDischargeTarget : config.clampedLimitPercentage)
        return status(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            target: target,
            temperatureCelsius: temperatureCelsius,
            now: now)
    }

    public func beginRecoveryWindow() {
        consecutiveWriteFailures = 0
        lastWriteFailed = false
        failureProvenance = nil
    }

    @discardableResult
    public func hydrateHardwareState() -> BatteryHardwareGate {
        guard isHardwareSupported else { return .unreadable }
        let gate = hardware.readChargingGate(
            targetLimit: config.clampedLimitPercentage)
        lastVerifiedGate = gate
        switch gate.state {
        case .allowed:
            isCurrentlyInhibited = false
            hasInitializedState = true
            if failureProvenance == .verifiedRelease {
                beginRecoveryWindow()
            }
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
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> BatteryControlServiceStatus {
        guard isHardwareSupported else {
            return status(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn,
                target: config.clampedLimitPercentage,
                temperatureCelsius: temperatureCelsius,
                now: now)
        }
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
                        target: config.clampedLimitPercentage,
                        temperatureCelsius: temperatureCelsius,
                        now: now)
                }
                isCurrentlyInhibited = false
                hasInitializedState = true
            }
        }
        guard hasInitializedState else {
            return verificationFailureStatus(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn,
                temperatureCelsius: temperatureCelsius,
                now: now)
        }
        return update(currentSoC: currentSoC, isPluggedIn: isPluggedIn, temperatureCelsius: temperatureCelsius, now: now)
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
        return config.isActive || isCurrentlyInhibited || isCurrentlyDischarging || (!hasInitializedState && !isWriteLatched)
    }

    public func configure(_ newConfig: BatteryControlConfiguration) {
        // A new configuration is the user — or the app's reconcile pass — asking again, so clear
        // the latch and let the next tick spend a fresh set of attempts.
        beginRecoveryWindow()
        let normalized = newConfig.normalized
        if normalized.topUpActive != config.topUpActive || normalized.clampedLimitPercentage != config.clampedLimitPercentage || normalized.topUpActive {
            topUpCompletedHold = false
        }
        config = normalized
    }

    /// Legacy wake entry point retained until the daemon moves to `verifyAndUpdate`. It reasserts
    /// only a believed active hold and still verifies the write through `attemptWrite`.
    public func reassertHardwareState() {
        guard config.isActive else { return }
        if isCurrentlyDischarging {
            _ = attemptDischargeWrite(active: true)
        }
        if isCurrentlyInhibited {
            let target = config.topUpActive ? 100 : (config.manualDischargeActive ? config.clampedManualDischargeTarget : config.clampedLimitPercentage)
            if !attemptWrite(inhibited: true, targetLimit: target) {
                // The reassertion did not verify, so the next update must rebuild a known baseline.
                hasInitializedState = false
            }
        }
    }

    public func update(
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> BatteryControlServiceStatus {
        // No register means no write can ever succeed. Short-circuit before the normalization gate
        // so the budget is not spent proving a permanent fact three times over.
        guard isHardwareSupported else {
            return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn,
                          target: config.clampedLimitPercentage, temperatureCelsius: temperatureCelsius, now: now)
        }

        // Until the hardware is confirmed at a known state the state machine cannot be trusted, so
        // it does not run at all. This also keeps a failing normalization from spending the write
        // budget on a transition whose starting point is a guess.
        guard normalizeOnFirstUpdate() else {
            return status(currentSoC: currentSoC, isPluggedIn: isPluggedIn,
                          target: config.clampedLimitPercentage, temperatureCelsius: temperatureCelsius, now: now)
        }

        if !isPluggedIn {
            topUpCompletedHold = false
        }

        // 1. Evaluate Heat Protection
        if config.heatProtectionEnabled && isPluggedIn {
            if let temp = temperatureCelsius {
                let threshold = Double(config.clampedHeatProtectionThresholdCelsius)
                let resumeTemp = Double(config.resumeTemperatureCelsius)
                let minCooldown = config.clampedHeatProtectionMinCooldownSeconds

                if !isInHeatProtection && temp >= threshold {
                    isInHeatProtection = true
                    heatProtectionTriggeredAt = now
                } else if isInHeatProtection {
                    let elapsed = now - (heatProtectionTriggeredAt ?? now)
                    let cooledDown = temp <= resumeTemp
                    let cooldownElapsed = elapsed >= minCooldown
                    if cooledDown && cooldownElapsed {
                        isInHeatProtection = false
                        heatProtectionTriggeredAt = nil
                    }
                }
            } else if isInHeatProtection {
                // Fail-Closed: keep heat protection active, preserve heatProtectionTriggeredAt
                isInHeatProtection = true
            }
        } else {
            isInHeatProtection = false
            heatProtectionTriggeredAt = nil
        }

        // 2. Evaluate State Pipeline
        let target: Int
        var shouldDischarge: Bool = false
        var shouldInhibit: Bool = false

        if !isPluggedIn {
            target = config.clampedLimitPercentage
            shouldDischarge = false
            shouldInhibit = false
        } else if isInHeatProtection {
            // Thermal Protection (>= 35°C): Immediately CHIE = 0x00, CHTE = 0x01, cancel discharge.
            target = config.clampedLimitPercentage
            shouldDischarge = false
            shouldInhibit = true
        } else if config.manualDischargeActive {
            // Manual Discharge Mode
            let manualTarget = config.clampedManualDischargeTarget
            target = manualTarget
            if currentSoC >= 15 && isDischargeHardwareSupported && currentSoC > manualTarget {
                shouldDischarge = true
                // Forced discharge needs both gates: CHIE isolates the adapter while the normal
                // charging gate remains inhibited. Releasing CHTE/CH0B here leaves CHIE active but
                // does not make the battery supply the system on current Apple silicon firmware.
                shouldInhibit = true
            } else {
                shouldDischarge = false
                shouldInhibit = true
            }
        } else if config.topUpActive {
            // Top-Up Mode
            target = 100
            shouldDischarge = false
            if currentSoC >= 100 {
                topUpCompletedHold = true
                shouldInhibit = true
            } else {
                shouldInhibit = false
            }
        } else if config.enabled && config.autoDischargeEnabled && !topUpCompletedHold && currentSoC >= 15 && isDischargeHardwareSupported && (isCurrentlyDischarging ? currentSoC > config.clampedLimitPercentage : currentSoC > config.clampedLimitPercentage + 1) {
            // Auto Discharge Mode
            target = config.clampedLimitPercentage
            shouldDischarge = true
            shouldInhibit = true
        } else if config.enabled {
            // Standard Hysteresis
            target = config.clampedLimitPercentage
            shouldDischarge = false
            shouldInhibit = isCurrentlyInhibited
                ? currentSoC > config.resumePercentage
                : currentSoC >= target
        } else {
            // Disabled
            target = config.clampedLimitPercentage
            shouldDischarge = false
            shouldInhibit = false
        }

        // 3. Hardware Transitions
        var transitionFailed = false

        // A. If discharge needs to stop, turn off discharge first
        if !shouldDischarge && isCurrentlyDischarging {
            if attemptDischargeWrite(active: false) {
                isCurrentlyDischarging = false
            } else {
                transitionFailed = true
            }
        }

        // B. Inhibit transition
        if shouldInhibit != isCurrentlyInhibited {
            let inhibitTarget = shouldInhibit ? target : 100
            if attemptWrite(inhibited: shouldInhibit, targetLimit: inhibitTarget) {
                isCurrentlyInhibited = shouldInhibit
            } else {
                transitionFailed = true
            }
        }

        // C. If discharge needs to start, turn on discharge
        if shouldDischarge && !isCurrentlyDischarging {
            if attemptDischargeWrite(active: true) {
                isCurrentlyDischarging = true
            } else {
                transitionFailed = true
            }
        }

        if !transitionFailed && shouldDischarge == isCurrentlyDischarging && shouldInhibit == isCurrentlyInhibited {
            if failureProvenance != .verifiedRelease {
                beginRecoveryWindow()
            }
        }

        return status(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            target: target,
            temperatureCelsius: temperatureCelsius,
            now: now
        )
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
        _ = hardware.setDischargingActive(false)
        isCurrentlyDischarging = false
        guard attemptWrite(inhibited: false, targetLimit: 100) else { return false }
        isCurrentlyInhibited = false
        hasInitializedState = true
        return true
    }

    /// Legacy shutdown entry point retained until daemon coordination uses `releaseVerified`.
    /// Unlike all new paths, it preserves the installed helper's one unverified last-chance write.
    public func release() {
        _ = hardware.setDischargingActive(false)
        isCurrentlyDischarging = false
        guard isCurrentlyInhibited || !hasInitializedState else { return }
        if hardware.setChargingInhibited(false, targetLimit: 100) {
            isCurrentlyInhibited = false
            if failureProvenance != .verifiedRelease {
                beginRecoveryWindow()
            }
        }
    }

    public func releaseVerified() -> BatteryReleaseVerification {
        _ = hardware.setDischargingActive(false)
        isCurrentlyDischarging = false
        guard !isWriteLatched else { return .init(verdict: .failed) }
        let verification = hardware.releaseChargingControlAndVerify()
        guard verification.isSafeToRemove else {
            consecutiveWriteFailures += 1
            lastWriteFailed = true
            failureProvenance = .verifiedRelease
            return verification
        }
        isCurrentlyInhibited = false
        hasInitializedState = true
        beginRecoveryWindow()
        lastVerifiedGate = verification.verdict == .verifiedAllowed ? .allowed : .unreadable
        return verification
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
            if failureProvenance == nil {
                failureProvenance = .ordinary
            }
            return false
        }
        let verified = hardware.readChargingGate(targetLimit: targetLimit)
        guard gateMatches(verified, inhibited: inhibited, targetLimit: targetLimit) else {
            consecutiveWriteFailures += 1
            lastWriteFailed = true
            if failureProvenance == nil {
                failureProvenance = .ordinary
            }
            lastVerifiedGate = verified
            return false
        }
        lastVerifiedGate = verified
        beginRecoveryWindow()
        return true
    }

    private func attemptDischargeWrite(active: Bool) -> Bool {
        guard !isWriteLatched else { return false }
        guard hardware.setDischargingActive(active) else {
            consecutiveWriteFailures += 1
            lastWriteFailed = true
            if failureProvenance == nil {
                failureProvenance = .ordinary
            }
            return false
        }
        beginRecoveryWindow()
        return true
    }

    private func detailReason(
        isPluggedIn: Bool,
        target: Int,
        currentSoC: Int,
        temperatureCelsius: Double?,
        now: TimeInterval
    ) -> BatteryControlStatusReason {
        if !isHardwareSupported { return .init(kind: .hardwareUnsupported) }
        if hasActionableFailure {
            // A failed release is the opposite failure from a failed apply: control IS applied and
            // stuck on, so telling the user it could not be applied would be actively misleading.
            return .init(kind: isCurrentlyInhibited ? .releaseFailed : .applyFailed)
        }
        if isInHeatProtection {
            guard let temp = temperatureCelsius else {
                return .init(kind: .batterySensorUnreadable)
            }
            let threshold = config.clampedHeatProtectionThresholdCelsius
            let resume = config.resumeTemperatureCelsius
            let elapsed = now - (heatProtectionTriggeredAt ?? now)
            let remainingCooldown = max(0, Int((config.clampedHeatProtectionMinCooldownSeconds - elapsed).rounded()))

            if temp <= Double(resume) && remainingCooldown > 0 {
                return .init(
                    kind: .heatProtectionCooldown,
                    currentTemperatureCelsius: temp,
                    cooldownRemainingSeconds: remainingCooldown
                )
            }
            return .init(
                kind: .heatProtectionActive,
                currentTemperatureCelsius: temp,
                thresholdTemperatureCelsius: threshold,
                resumeTemperatureCelsius: resume
            )
        }
        if !isPluggedIn {
            return .init(kind: .onBatteryPower)
        }
        if config.manualDischargeActive {
            if isCurrentlyDischarging {
                return .init(kind: .dischargingManual, limitPercentage: target)
            }
            return .init(kind: .inhibitedAtLimit, limitPercentage: target)
        }
        if config.topUpActive {
            if currentSoC >= 100 || topUpCompletedHold {
                return .init(kind: .topUpComplete, limitPercentage: 100)
            }
            return .init(kind: .topUpCharging, limitPercentage: 100)
        }
        if isCurrentlyDischarging {
            return .init(kind: .dischargingToTarget, limitPercentage: target)
        }
        if isCurrentlyInhibited {
            if currentSoC < target {
                return .init(kind: .sailing, limitPercentage: target, resumePercentage: config.resumePercentage)
            }
            return .init(kind: .inhibitedAtLimit, limitPercentage: target)
        }
        if !config.enabled { return .init(kind: .limitDisabled) }
        return .init(kind: .chargingToTarget, limitPercentage: target)
    }

    private func status(
        currentSoC: Int,
        isPluggedIn: Bool,
        target: Int,
        temperatureCelsius: Double?,
        now: TimeInterval
    ) -> BatteryControlServiceStatus {
        let reason = detailReason(isPluggedIn: isPluggedIn, target: target, currentSoC: currentSoC, temperatureCelsius: temperatureCelsius, now: now)
        let mode: BatteryControlServiceMode
        if !isHardwareSupported || hasActionableFailure {
            mode = .unsupported
        } else if isCurrentlyInhibited {
            mode = .inhibited
        } else {
            mode = .charging
        }
        let appliedLimit: Int?
        if isHardwareSupported && !hasActionableFailure && (config.enabled || config.manualDischargeActive || config.topUpActive) {
            appliedLimit = target
        } else {
            appliedLimit = nil
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
            appliedLimitPercentage: appliedLimit,
            isHardwareSupported: isHardwareSupported,
            detailReason: reason,
            // The reason is already the single authoritative decision for this sample. Deriving
            // activity here keeps the new app, the legacy sentence, and the hardware mode aligned.
            activity: BatteryControlActivity.inferred(from: reason),
            actualGate: lastVerifiedGate,
            batteryTemperatureCelsius: temperatureCelsius
        )
    }

    private func verificationFailureStatus(
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
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
            actualGate: lastVerifiedGate ?? .unreadable,
            batteryTemperatureCelsius: temperatureCelsius)
    }
}
