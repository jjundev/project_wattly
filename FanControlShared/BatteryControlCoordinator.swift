import Foundation

public final class BatteryControlCoordinator: @unchecked Sendable {
    public static let capabilities: [BatteryControlCapability] = [
        .persistedPolicyV1,
        .hardwareGateReadbackV1,
        .systemPowerEventsV1,
        .calibrationV1,
    ]

    private let ownerUID: UInt32
    private let store: any BatteryPolicyStoring
    private let engine: BatteryControlEngine
    private let now: @Sendable () -> TimeInterval
    /// Top Up이 100%에 도달한 벽시계 시각. 저장 파일의 값을 그대로 미러링한다 — 이 값은 앱이
    /// 되밀어 주는 `BatteryControlConfiguration`이 아니라 코디네이터가 소유한다.
    private var topUpReachedFullAt: TimeInterval?

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
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil
    ) -> BatteryControlServiceStatus {
        do {
            var (desired, ownershipFailure) = try resolvedStoredPolicy()
            if !isPluggedIn && desired.topUpActive && !desired.calibrationActive {
                desired.topUpActive = false
                try? persistPolicy(desired)
                // 쓰기가 실패해도 Top Up은 끝났다. 미러를 남겨 두면 다음 Top Up의 `configure`가
                // 낡은 시각을 그대로 저장해, 켜자마자 만료되는 상태로 시작한다.
                topUpReachedFullAt = nil
            }
            engine.configure(desired)
            if !desired.isActive {
                return publishDisabledRestore(
                    currentSoC: currentSoC,
                    isPluggedIn: isPluggedIn,
                    temperatureCelsius: temperatureCelsius,
                    resolutionFailure: ownershipFailure)
            }
            let status = engine.verifyAndUpdate(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn,
                temperatureCelsius: temperatureCelsius)
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
            return publishDisabledRestore(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn,
                temperatureCelsius: temperatureCelsius,
                resolutionFailure: .init(kind: .persistenceReadFailed))
        }
    }

    public func restoreWithoutPowerReading() -> BatteryControlServiceStatus {
        do {
            let (desired, ownershipFailure) = try resolvedStoredPolicy()
            engine.configure(desired)
            let gate = engine.hydrateHardwareState()
            if !desired.isActive {
                let verification = engine.releaseVerified()
                let reason = ownershipFailure
                    ?? (verification.isSafeToRemove
                        ? nil : .init(kind: .releaseFailed))
                return publish(
                    statusForMissingPowerSource(
                        actualGate: verification.verdict == .verifiedAllowed ? .allowed : gate,
                        releaseVerdict: verification.verdict,
                        releaseVerification: verification),
                    trigger: .startup,
                    result: ownershipFailure != nil
                        ? .failed
                        : (verification.isSafeToRemove ? .released : .failed),
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
            let verification = engine.releaseVerified()
            return publish(
                statusForMissingPowerSource(
                    actualGate: verification.verdict == .verifiedAllowed ? .allowed : gate,
                    releaseVerdict: verification.verdict,
                    releaseVerification: verification),
                trigger: .startup,
                result: .failed,
                reason: .init(kind: .persistenceReadFailed))
        }
    }

    public func configure(
        _ requested: BatteryControlConfiguration,
        trigger: BatteryMaintenanceTrigger,
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil
    ) -> BatteryControlServiceStatus {
        var normalized = requested.normalized
        if normalized.manualDischargeActive {
            normalized.topUpActive = false
        } else if normalized.topUpActive {
            normalized.manualDischargeActive = false
        }
        // 캘리브레이션은 충전 단계에서 `topUpActive`를 빌려 쓰므로 그것과는 공존하지만,
        // 수동 방전과는 같은 CHIE를 다투므로 공존할 수 없다 (결정 #24).
        if normalized.calibrationActive {
            normalized.manualDischargeActive = false
        }
        do {
            try persistPolicy(normalized)
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
        if !normalized.isActive {
            let verification = engine.releaseVerified()
            var status = engine.statusForCurrentBelief(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn,
                temperatureCelsius: temperatureCelsius)
            status.releaseVerdict = verification.verdict
            status.releaseVerification = verification
            if verification.verdict == .verifiedAllowed {
                status.actualGate = .allowed
            }
            return publish(
                status,
                trigger: trigger,
                result: verification.isSafeToRemove ? .released : .failed,
                reason: verification.isSafeToRemove
                    ? nil : .init(kind: .releaseFailed))
        }
        let status = engine.verifyAndUpdate(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius)
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
        var normalized = requested.normalized
        if normalized.manualDischargeActive {
            normalized.topUpActive = false
        } else if normalized.topUpActive {
            normalized.manualDischargeActive = false
        }
        // 캘리브레이션은 충전 단계에서 `topUpActive`를 빌려 쓰므로 그것과는 공존하지만,
        // 수동 방전과는 같은 CHIE를 다투므로 공존할 수 없다 (결정 #24).
        if normalized.calibrationActive {
            normalized.manualDischargeActive = false
        }
        do {
            try persistPolicy(normalized)
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
        if !normalized.isActive {
            let verification = engine.releaseVerified()
            return publish(
                statusForMissingPowerSource(
                    actualGate: verification.verdict == .verifiedAllowed ? .allowed : gate,
                    releaseVerdict: verification.verdict,
                    releaseVerification: verification),
                trigger: trigger,
                result: verification.isSafeToRemove ? .released : .failed,
                reason: verification.isSafeToRemove
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
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil
    ) -> BatteryControlServiceStatus {
        if !isPluggedIn && engine.configuration.manualDischargeActive
            && !engine.configuration.calibrationActive {
            var updatedConfig = engine.configuration
            updatedConfig.manualDischargeActive = false
            engine.configure(updatedConfig)
        }
        var status = engine.update(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius)
        if let expired = evaluateTopUpExpiry(
            status: status,
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius) {
            return expired
        }
        status.desiredConfiguration = engine.configuration
        status.lastMaintenance = latestStatus.lastMaintenance
        status.capabilities = Self.capabilities
        latestStatus = status
        return status
    }

    public func reconcile(
        trigger: BatteryMaintenanceTrigger,
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil
    ) -> BatteryControlServiceStatus {
        if trigger == .wake || trigger == .adapterTransition {
            engine.beginRecoveryWindow()
        }

        // 캘리브레이션 중에는 어댑터 분리가 종료 사유가 아니다. 방전 단계는 자연 방전으로
        // 이어지고, 충전 단계는 앱 FSM이 `paused(needsAdapter)`로 잡아 재연결을 기다린다.
        if !isPluggedIn && !engine.configuration.calibrationActive
            && (engine.configuration.topUpActive || engine.configuration.manualDischargeActive) {
            var updatedConfig = engine.configuration
            updatedConfig.topUpActive = false
            updatedConfig.manualDischargeActive = false
            do {
                try persistPolicy(updatedConfig)
            } catch {
                // If persistence write fails, proceed with in-memory policy reset
            }
            // 쓰기가 실패해도 Top Up은 끝났다. 미러를 남겨 두면 다음 Top Up의 `configure`가
            // 낡은 시각을 그대로 저장해, 켜자마자 만료되는 상태로 시작한다.
            topUpReachedFullAt = nil
            engine.configure(updatedConfig)
        }

        let status = engine.verifyAndUpdate(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius)
        // 잠자기 동안에는 5초 타이머가 돌지 않는다. 12시간을 자고 깨어난 Mac은 여기서 만료된다.
        if let expired = evaluateTopUpExpiry(
            status: status,
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius) {
            return expired
        }
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
        var verification = BatteryReleaseVerification(verdict: .failed)
        for _ in 0..<BatteryControlEngine.maxConsecutiveWriteFailures {
            verification = engine.releaseVerified()
            if verification.isSafeToRemove {
                break
            }
        }

        var status = engine.statusForCurrentBelief(
            currentSoC: latestStatus.currentPercentage,
            isPluggedIn: latestStatus.isPowerAdapterConnected)
        status.releaseVerdict = verification.verdict
        status.releaseVerification = verification
        if verification.verdict == .verifiedAllowed {
            status.actualGate = .allowed
        }
        _ = publish(
            status,
            trigger: .termination,
            result: verification.isSafeToRemove ? .released : .failed,
            reason: verification.isSafeToRemove
                ? nil : .init(kind: .releaseFailed))
        return verification.isSafeToRemove
    }

    /// 정책 저장의 유일한 경로. Top Up이 꺼져 있으면 도달 시각도 함께 지운다 — 남겨 두면 다음
    /// Top Up이 켜지자마자 즉시 만료된다.
    ///
    /// 미러(`topUpReachedFullAt`)는 **쓰기가 성공한 뒤에만** 갱신한다. 실패한 쓰기가 메모리 상태를
    /// 먼저 바꿔 버리면, 재시도해야 할 만료가 스스로 재시도 조건을 지워 버린다.
    private func persistPolicy(_ configuration: BatteryControlConfiguration) throws {
        var persisted = configuration
        persisted.manualDischargeActive = false
        // `calibrationActive`는 의도적으로 남긴다. 앱이 죽어도 엔진의 하한 가드가 살아 있어야
        // 최악이 "하한 도달 후 홀드"라는 설계된 안전 상태로 끝난다 (결정 #35).
        let stamp = persisted.topUpActive ? topUpReachedFullAt : nil
        try store.save(.init(
            ownerUID: ownerUID,
            configuration: persisted,
            updatedAt: now(),
            topUpReachedFullAt: stamp))
        topUpReachedFullAt = stamp
    }

    /// Top Up 자동 만료의 **유일한** 판정 지점.
    ///
    /// 캘리브레이션 모드가 최종 100% 홀드 단계에서 같은 `topUpActive` 원시 명령을 빌려 쓰게 되면,
    /// 그 예외가 아래 `calibrationActive:` 인자다.
    ///
    /// 만료를 실제로 수행한 경우에만 상태를 반환한다(이미 `publish`까지 마친 상태다). `nil`이면
    /// 호출자는 평소 경로를 그대로 진행하면 된다.
    private func evaluateTopUpExpiry(
        status: BatteryControlServiceStatus,
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double?
    ) -> BatteryControlServiceStatus? {
        switch BatteryTopUpExpiry.decide(
            topUpActive: engine.configuration.topUpActive,
            isHoldingAtFull: status.detailReason?.kind == .topUpComplete,
            reachedFullAt: topUpReachedFullAt,
            now: now(),
            calibrationActive: engine.configuration.calibrationActive
        ) {
        case .none:
            return nil
        case .stamp(let moment):
            // `persistPolicy`는 미러에서 기록할 시각을 읽으므로 쓰기 전에 세워야 한다. 쓰기가
            // 실패하면 세운 값을 도로 물려, 다음 샘플이 `.stamp`를 다시 내고 재시도하게 한다 —
            // 미러를 그대로 두면 `decide`가 두 번 다시 `.stamp`를 내지 않아 영영 저장되지 않는다.
            let previous = topUpReachedFullAt
            topUpReachedFullAt = moment
            do {
                try persistPolicy(engine.configuration)
            } catch {
                topUpReachedFullAt = previous
            }
            return nil
        case .expire:
            var updated = engine.configuration
            updated.topUpActive = false
            do {
                try persistPolicy(updated)
            } catch {
                // 저장이 실패하면 파일과 하드웨어가 갈라진다. 엔진도 스탬프도 그대로 두고 물러나면,
                // 5초 뒤 다음 샘플이 같은 `.expire` 판정에 다시 도달해 쓰기를 재시도한다.
                return nil
            }
            engine.configure(updated)
            let settled = engine.verifyAndUpdate(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn,
                temperatureCelsius: temperatureCelsius)
            let failure = hardwareFailureReason(in: settled)
            return publish(
                settled,
                trigger: .topUpExpired,
                result: failure == nil ? .applied : .failed,
                reason: failure)
        }
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
            topUpReachedFullAt = nil
            return (.init(enabled: false), nil)
        }
        guard stored.ownerUID == ownerUID else {
            topUpReachedFullAt = nil
            return (
                .init(enabled: false),
                .init(kind: .policyOwnerMismatch))
        }
        var config = stored.configuration
        config.manualDischargeActive = false
        // 데몬 재시작 뒤에도 12시간 시계가 이어지도록 파일의 값을 미러링한다.
        topUpReachedFullAt = config.topUpActive ? stored.topUpReachedFullAt : nil
        return (config, nil)
    }

    private func publishDisabledRestore(
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil,
        resolutionFailure: BatteryControlStatusReason?
    ) -> BatteryControlServiceStatus {
        let verification = engine.releaseVerified()
        var status = engine.statusForCurrentBelief(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius)
        status.releaseVerdict = verification.verdict
        status.releaseVerification = verification
        if verification.verdict == .verifiedAllowed {
            status.actualGate = .allowed
        }
        let releaseFailure = verification.isSafeToRemove
            ? nil : BatteryControlStatusReason(kind: .releaseFailed)
        return publish(
            status,
            trigger: .startup,
            result: resolutionFailure != nil
                ? .failed
                : (verification.isSafeToRemove ? .released : .failed),
            reason: resolutionFailure ?? releaseFailure)
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
        releaseVerdict: BatteryReleaseVerdict? = nil,
        releaseVerification: BatteryReleaseVerification? = nil
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
            isDischargeHardwareSupported: engine.isDischargeHardwareSupported,
            detailReason: reason,
            actualGate: actualGate,
            releaseVerdict: releaseVerdict,
            releaseVerification: releaseVerification,
            capabilities: Self.capabilities)
    }

    private func hardwareFailureReason(
        in status: BatteryControlServiceStatus
    ) -> BatteryControlStatusReason? {
        switch status.detailReason?.kind {
        case .applyFailed, .releaseFailed, .hardwareReadbackFailed:
            return status.detailReason
        case .hardwareUnsupported where engine.configuration.isActive:
            return status.detailReason
        default:
            break
        }
        if engine.configuration.isActive, status.actualGate == nil {
            return .init(kind: .hardwareReadbackFailed)
        }
        guard status.actualGate?.state != .unreadable,
              status.actualGate?.state != .unrecognized
        else {
            return .init(kind: .hardwareReadbackFailed)
        }
        return nil
    }
}
