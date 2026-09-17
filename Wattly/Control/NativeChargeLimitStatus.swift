import Foundation

/// 네이티브 백엔드가 한 요청에 필요한 배터리 사실. `batteryMilliamps`는 +충전 / −방전이고,
/// 못 읽으면 `nil`이다(그때는 "방전 중" 표시를 포기하고 "유지 중"으로 본다).
struct NativeLimitBatteryReading: Equatable, Sendable {
    var percentage: Int
    var isPluggedIn: Bool
    var batteryMilliamps: Int?
}

enum NativeLimitWriteOutcome: Equatable, Sendable {
    case none
    case applied
    case failed
}

/// 루트 도우미가 만들던 `BatteryControlServiceStatus`를 네이티브 백엔드용으로 합성한다. 순수 함수.
///
/// 브리지·정책·표시·단축어·스케줄은 이 DTO만 읽는다. 그래서 여기서 도우미와 같은 모양을 내는
/// 것이 "기존 코드를 고치지 않는다"는 설계의 전부다 — 특히 `BatteryControlPolicy.accepted`가
/// 요구하는 `desiredConfiguration`·`actualGate`, 그리고 `shouldReapply`를
/// `desiredConfiguration` 비교 경로로 보내는 세 capability.
enum NativeChargeLimitStatus {
    static let capabilities: [BatteryControlCapability] = [
        .persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1
    ]
    /// 제한 초과 상태에서 펌웨어가 배터리를 끌어 쓰는 중이라고 볼 전류. 실측 drain은
    /// −650~−1000 mA였고 유지 중에는 정확히 0 mA라, −100은 둘 사이의 넉넉한 문턱이다.
    static let drainThresholdMilliamps = -100
    /// `detailReason`이 항상 있으므로 앱은 이 문장을 쓰지 않는다. 구버전 호환 필드를 비워 두지
    /// 않으려는 값일 뿐이다.
    static let detail = "시스템 충전 제한 사용 중"

    static func make(
        configuration: BatteryControlConfiguration,
        reading: NativeLimitBatteryReading,
        native: NativeLimitSnapshot?,
        availableLimits: [Int],
        outcome: NativeLimitWriteOutcome,
        now: TimeInterval
    ) -> BatteryControlServiceStatus {
        let configuration = configuration.normalized
        let applied: Int? = native?.state == .on ? native?.limit : nil
        let limit = applied ?? NativeChargeLimitPlan.snapped(
            configuration.clampedLimitPercentage, to: availableLimits)

        var mode = BatteryControlServiceMode.charging
        var gate = BatteryHardwareGate.allowed
        var activity = BatteryControlActivity.inactive
        var reason: BatteryControlStatusReason

        if native == nil {
            reason = .init(kind: .hardwareReadbackFailed)
            gate = .unreadable
        } else if outcome == .failed {
            let wantsControl = configuration.enabled || configuration.topUpActive
            reason = .init(kind: wantsControl ? .applyFailed : .releaseFailed)
        } else if !configuration.enabled, !configuration.topUpActive {
            reason = .init(kind: .limitDisabled)
        } else if !reading.isPluggedIn {
            reason = .init(kind: .onBatteryPower)
            activity = .onBatteryPower
        } else if configuration.topUpActive {
            let isFull = reading.percentage >= 100
            reason = .init(kind: isFull ? .topUpComplete : .topUpCharging)
            activity = .topUp
            if isFull {
                mode = .inhibited
                gate = .inhibited(appliedLimitPercentage: nil)
            }
        } else if reading.percentage > limit,
                  let milliamps = reading.batteryMilliamps,
                  milliamps <= drainThresholdMilliamps {
            reason = .init(kind: .dischargingToTarget, limitPercentage: limit)
            activity = .discharging
            mode = .inhibited
            gate = .inhibited(appliedLimitPercentage: limit)
        } else if reading.percentage >= limit {
            reason = .init(kind: .inhibitedAtLimit, limitPercentage: limit)
            activity = .holdingAtLimit
            mode = .inhibited
            gate = .inhibited(appliedLimitPercentage: limit)
        } else {
            reason = .init(kind: .chargingToTarget, limitPercentage: limit)
            activity = .chargingToLimit
        }

        return BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: reading.percentage,
            isPowerAdapterConnected: reading.isPluggedIn,
            detail: detail,
            updatedAt: now,
            appliedLimitPercentage: applied,
            isHardwareSupported: true,
            isDischargeHardwareSupported: false,
            detailReason: reason,
            activity: activity,
            desiredConfiguration: configuration,
            actualGate: gate,
            capabilities: capabilities,
            controlBackend: .nativeLimit)
    }

    static func powerSourceUnreadable(
        configuration: BatteryControlConfiguration,
        now: TimeInterval
    ) -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 0,
            isPowerAdapterConnected: false,
            detail: detail,
            updatedAt: now,
            isHardwareSupported: true,
            isDischargeHardwareSupported: false,
            detailReason: .init(kind: .powerSourceUnreadable),
            activity: .inactive,
            desiredConfiguration: configuration.normalized,
            actualGate: .unreadable,
            capabilities: capabilities,
            controlBackend: .nativeLimit)
    }
}
