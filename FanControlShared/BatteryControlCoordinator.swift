import Foundation

public final class BatteryControlCoordinator: @unchecked Sendable {
    public static let capabilities: [BatteryControlCapability] = [
        .persistedPolicyV1,
        .hardwareGateReadbackV1,
        .systemPowerEventsV1,
    ]

    private let ownerUID: UInt32
    private let store: any BatteryPolicyStoring
    private let engine: BatteryControlEngine
    private let now: @Sendable () -> TimeInterval

    public private(set) var latestStatus: BatteryControlServiceStatus
    public private(set) var isSafeToServe = true

    public var needsSampling: Bool {
        engine.needsSampling
            || latestStatus.releaseVerdict == .failed
            || latestStatus.actualGate?.state == .inhibited
    }

    public init(
        ownerUID: UInt32,
        store: any BatteryPolicyStoring,
        engine: BatteryControlEngine,
        now: @escaping @Sendable () -> TimeInterval
    ) {
        self.ownerUID = ownerUID
        self.store = store
        self.engine = engine
        self.now = now
        let reason = BatteryControlStatusReason(kind: .initializing)
        latestStatus = BatteryControlServiceStatus(
            mode: .unavailable,
            currentPercentage: 0,
            isPowerAdapterConnected: false,
            detail: reason.legacyKoreanDetail,
            updatedAt: 0,
            detailReason: reason,
            capabilities: Self.capabilities)
    }

    public func restore(
        currentSoC: Int,
        isPluggedIn: Bool
    ) -> BatteryControlServiceStatus {
        do {
            let (desired, ownershipFailure) = try resolvedStoredPolicy()
            engine.configure(desired)
            let status = engine.verifyAndUpdate(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn)
            let failure = ownershipFailure ?? hardwareFailureReason(in: status)
            return publish(
                status,
                trigger: .startup,
                result: failure == nil ? .verified : .failed,
                reason: failure)
        } catch {
            engine.configure(.init(enabled: false))
            if isRollbackFailure(error) {
                isSafeToServe = false
                _ = releaseForTermination()
                return publish(
                    latestStatus,
                    trigger: .startup,
                    result: .failed,
                    reason: .init(kind: .persistenceReadFailed))
            }
            let status = engine.verifyAndUpdate(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn)
            return publish(
                status,
                trigger: .startup,
                result: .failed,
                reason: .init(kind: .persistenceReadFailed))
        }
    }

    public func restoreWithoutPowerReading() -> BatteryControlServiceStatus {
        do {
            let (desired, ownershipFailure) = try resolvedStoredPolicy()
            engine.configure(desired)
            let gate = engine.hydrateHardwareState()
            if !desired.enabled {
                let verdict = engine.releaseVerified()
                let reason = ownershipFailure
                    ?? (verdict.isSafeToRemove
                        ? nil : .init(kind: .releaseFailed))
                return publish(
                    statusForMissingPowerSource(
                        actualGate: verdict == .verifiedAllowed ? .allowed : gate,
                        releaseVerdict: verdict),
                    trigger: .startup,
                    result: ownershipFailure != nil
                        ? .failed
                        : (verdict.isSafeToRemove ? .released : .failed),
                    reason: reason)
            }
            return publish(
                statusForMissingPowerSource(actualGate: gate),
                trigger: .startup,
                result: .skipped,
                reason: .init(kind: .powerSourceUnreadable))
        } catch {
            engine.configure(.init(enabled: false))
            if isRollbackFailure(error) {
                isSafeToServe = false
                _ = releaseForTermination()
                return publish(
                    latestStatus,
                    trigger: .startup,
                    result: .failed,
                    reason: .init(kind: .persistenceReadFailed))
            }
            let gate = engine.hydrateHardwareState()
            let verdict = engine.releaseVerified()
            return publish(
                statusForMissingPowerSource(
                    actualGate: verdict == .verifiedAllowed ? .allowed : gate,
                    releaseVerdict: verdict),
                trigger: .startup,
                result: .failed,
                reason: .init(kind: .persistenceReadFailed))
        }
    }

    public func configure(
        _ requested: BatteryControlConfiguration,
        trigger: BatteryMaintenanceTrigger,
        currentSoC: Int,
        isPluggedIn: Bool
    ) -> BatteryControlServiceStatus {
        let normalized = requested.normalized
        do {
            try store.save(.init(
                ownerUID: ownerUID,
                configuration: normalized,
                updatedAt: now()))
        } catch {
            if isRollbackFailure(error) {
                isSafeToServe = false
                engine.configure(.init(enabled: false))
                _ = releaseForTermination()
            }
            return publish(
                latestStatus,
                trigger: trigger,
                result: .failed,
                reason: .init(kind: .persistenceWriteFailed))
        }

        engine.configure(normalized)
        if !normalized.enabled {
            let verdict = engine.releaseVerified()
            var status = engine.statusForCurrentBelief(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn)
            status.releaseVerdict = verdict
            if verdict == .verifiedAllowed {
                status.actualGate = .allowed
            }
            return publish(
                status,
                trigger: trigger,
                result: verdict.isSafeToRemove ? .released : .failed,
                reason: verdict.isSafeToRemove
                    ? nil : .init(kind: .releaseFailed))
        }
        let status = engine.verifyAndUpdate(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn)
        let failure = hardwareFailureReason(in: status)
        return publish(
            status,
            trigger: trigger,
            result: failure == nil ? .applied : .failed,
            reason: failure)
    }

    public func configureWithoutPowerReading(
        _ requested: BatteryControlConfiguration,
        trigger: BatteryMaintenanceTrigger
    ) -> BatteryControlServiceStatus {
        let normalized = requested.normalized
        do {
            try store.save(.init(
                ownerUID: ownerUID,
                configuration: normalized,
                updatedAt: now()))
        } catch {
            if isRollbackFailure(error) {
                isSafeToServe = false
                engine.configure(.init(enabled: false))
                _ = releaseForTermination()
            }
            return publish(
                latestStatus,
                trigger: trigger,
                result: .failed,
                reason: .init(kind: .persistenceWriteFailed))
        }

        engine.configure(normalized)
        let gate = engine.hydrateHardwareState()
        if !normalized.enabled {
            let verdict = engine.releaseVerified()
            return publish(
                statusForMissingPowerSource(
                    actualGate: verdict == .verifiedAllowed ? .allowed : gate,
                    releaseVerdict: verdict),
                trigger: trigger,
                result: verdict.isSafeToRemove ? .released : .failed,
                reason: verdict.isSafeToRemove
                    ? nil : .init(kind: .releaseFailed))
        }
        return publish(
            statusForMissingPowerSource(actualGate: gate),
            trigger: trigger,
            result: .skipped,
            reason: .init(kind: .powerSourceUnreadable))
    }

    public func sample(
        currentSoC: Int,
        isPluggedIn: Bool
    ) -> BatteryControlServiceStatus {
        var status = engine.update(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn)
        status.desiredConfiguration = engine.configuration
        status.lastMaintenance = latestStatus.lastMaintenance
        status.capabilities = Self.capabilities
        latestStatus = status
        return status
    }

    public func reconcile(
        trigger: BatteryMaintenanceTrigger,
        currentSoC: Int,
        isPluggedIn: Bool
    ) -> BatteryControlServiceStatus {
        if trigger == .wake || trigger == .adapterTransition {
            engine.beginRecoveryWindow()
        }
        let status = engine.verifyAndUpdate(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn)
        let failure = hardwareFailureReason(in: status)
        return publish(
            status,
            trigger: trigger,
            result: failure == nil ? .verified : .failed,
            reason: failure)
    }

    @discardableResult
    public func releaseForTermination() -> Bool {
        engine.beginRecoveryWindow()
        var verdict = BatteryReleaseVerdict.failed
        for _ in 0..<BatteryControlEngine.maxConsecutiveWriteFailures {
            verdict = engine.releaseVerified()
            if verdict.isSafeToRemove {
                break
            }
        }

        var status = engine.statusForCurrentBelief(
            currentSoC: latestStatus.currentPercentage,
            isPluggedIn: latestStatus.isPowerAdapterConnected)
        status.releaseVerdict = verdict
        if verdict == .verifiedAllowed {
            status.actualGate = .allowed
        }
        _ = publish(
            status,
            trigger: .termination,
            result: verdict.isSafeToRemove ? .released : .failed,
            reason: verdict.isSafeToRemove
                ? nil : .init(kind: .releaseFailed))
        return verdict.isSafeToRemove
    }

    private func publish(
        _ engineStatus: BatteryControlServiceStatus,
        trigger: BatteryMaintenanceTrigger,
        result: BatteryMaintenanceResult,
        reason: BatteryControlStatusReason?
    ) -> BatteryControlServiceStatus {
        var status = engineStatus
        status.desiredConfiguration = engine.configuration
        status.lastMaintenance = .init(
            trigger: trigger,
            result: result,
            occurredAt: now(),
            reason: reason)
        status.capabilities = Self.capabilities
        latestStatus = status
        return status
    }

    private func resolvedStoredPolicy() throws -> (
        configuration: BatteryControlConfiguration,
        ownershipFailure: BatteryControlStatusReason?
    ) {
        guard let stored = try store.load() else {
            return (.init(enabled: false), nil)
        }
        guard stored.ownerUID == ownerUID else {
            return (
                .init(enabled: false),
                .init(kind: .policyOwnerMismatch))
        }
        return (stored.configuration, nil)
    }

    private func isRollbackFailure(_ error: any Error) -> Bool {
        guard let storeError = error as? BatteryPolicyStoreError else {
            return false
        }
        if case .rollbackFailed = storeError {
            return true
        }
        return false
    }

    private func statusForMissingPowerSource(
        actualGate: BatteryHardwareGate,
        releaseVerdict: BatteryReleaseVerdict? = nil
    ) -> BatteryControlServiceStatus {
        let reason = BatteryControlStatusReason(kind: .powerSourceUnreadable)
        let mode: BatteryControlServiceMode
        if !engine.isHardwareSupported {
            mode = .unsupported
        } else if actualGate.state == .inhibited {
            mode = .inhibited
        } else if actualGate.state == .allowed {
            mode = .charging
        } else {
            mode = .unavailable
        }
        return BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: 0,
            isPowerAdapterConnected: false,
            detail: reason.legacyKoreanDetail,
            updatedAt: now(),
            appliedLimitPercentage: engine.configuration.enabled
                && actualGate.state == .inhibited
                ? engine.configuration.clampedLimitPercentage : nil,
            isHardwareSupported: engine.isHardwareSupported,
            detailReason: reason,
            actualGate: actualGate,
            releaseVerdict: releaseVerdict,
            capabilities: Self.capabilities)
    }

    private func hardwareFailureReason(
        in status: BatteryControlServiceStatus
    ) -> BatteryControlStatusReason? {
        switch status.detailReason?.kind {
        case .applyFailed, .releaseFailed, .hardwareReadbackFailed:
            return status.detailReason
        default:
            break
        }
        guard status.actualGate?.state != .unreadable,
              status.actualGate?.state != .unrecognized
        else {
            return .init(kind: .hardwareReadbackFailed)
        }
        return nil
    }
}
