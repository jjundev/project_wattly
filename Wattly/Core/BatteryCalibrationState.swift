import Foundation

/// 캘리브레이션 절차의 단계.
///
/// 초안의 8단계에서 `soakHigh`(첫 완충 뒤 고잔량 안정화)가 빠져 7단계가 됐다. 테이퍼는
/// 99→100% 구간의 10분 꼬리에서 일어나고 100%에 닿는 순간 엔진이 게이트를 끊으므로,
/// 그 뒤에는 관측할 테이퍼가 남아 있지 않다 (실기 확인). 고잔량 체류만 1시간 늘릴 뿐이었다.
public enum CalibrationStep: String, Codable, Equatable, Sendable, CaseIterable {
    case preflight
    case chargeToFull
    case dischargeToFloor
    case soakLow
    case rechargeToFull
    case soakFinal
    case restoring

    public var next: CalibrationStep? {
        switch self {
        case .preflight: return .chargeToFull
        case .chargeToFull: return .dischargeToFloor
        case .dischargeToFloor: return .soakLow
        case .soakLow: return .rechargeToFull
        case .rechargeToFull: return .soakFinal
        case .soakFinal: return .restoring
        case .restoring: return nil
        }
    }

    /// 이 단계에서 데몬에 내려보낼 원시 명령. 데몬은 단계 개념을 모르고 이것만 안다.
    public var primitive: CalibrationPrimitive {
        switch self {
        case .preflight: return .idle
        case .chargeToFull, .rechargeToFull: return .chargeToFull
        case .dischargeToFloor: return .dischargeToFloor
        case .soakLow: return .holdAtFloor
        case .soakFinal: return .holdAtFull
        case .restoring: return .restore
        }
    }
}

/// 앱이 데몬에 내리는 원시 명령. 충전 계열은 기존 Top Up 경로를 그대로 빌려 쓴다.
public enum CalibrationPrimitive: String, Codable, Equatable, Sendable {
    /// 아무것도 내려보내지 않는다. `none`이라 부르지 않는 이유는 `Optional.none`과 이름이
    /// 겹쳐 `primitive != .none` 같은 비교가 조용히 다른 뜻이 되기 때문이다.
    case idle
    case chargeToFull
    case holdAtFull
    case dischargeToFloor
    case holdAtFloor
    case restore
}

public enum CalibrationPause: String, Codable, Equatable, Sendable, CaseIterable {
    case needsAdapter
    case heatProtection
    case helperUnavailable
    case systemSleep
    /// 어댑터도 붙어 있고 우리 게이트도 열렸는데 충전이 시작되지 않는다. 실기에서
    /// macOS "최적화된 배터리 충전"이 정확히 이 상태를 만들었다.
    case externalChargeBlock

    /// 시스템 잠자기는 2시간 일시정지 예산을 쓰지 않는다. 사용자가 뚜껑을 닫는 것을
    /// assertion으로 막을 수 없고, 12시간 무진행 자동 취소가 이미 안전망이기 때문이다.
    public var consumesBudget: Bool { self != .systemSleep }
}

public enum CalibrationOutcome: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case expired
    case failed
}

public enum CalibrationFailure: String, Codable, Equatable, Sendable {
    case stepTimeout
    case pauseBudgetExhausted
    case helperLost
    case dischargeUnsupported
}

/// 절차가 누적하는 시간들. 전부 코디네이터가 tick마다 `BatteryCalibration.tick`으로
/// 갱신하며, 판정 함수는 이 값을 읽기만 한다.
public struct CalibrationTimers: Codable, Equatable, Sendable {
    /// 현재 단계에서 깨어 있고 일시정지도 아니었던 시간.
    public var stepActiveSeconds: TimeInterval
    /// 절차 전체에서 누적된 일시정지 시간(잠자기 제외). 유일하게 단계를 넘어 살아남는다.
    public var pausedTotalSeconds: TimeInterval
    /// SoC가 바뀌지 않은 채 흐른 깨어 있던 시간.
    public var socUnchangedSeconds: TimeInterval
    /// `soc >= 100 && !isCharging`이 유지된 시간.
    public var fullHoldSeconds: TimeInterval
    /// 충전 단계인데 충전 전류가 바닥인 채 흐른 시간.
    public var chargeStalledSeconds: TimeInterval
    public var lastSoC: Int?

    public init(
        stepActiveSeconds: TimeInterval = 0,
        pausedTotalSeconds: TimeInterval = 0,
        socUnchangedSeconds: TimeInterval = 0,
        fullHoldSeconds: TimeInterval = 0,
        chargeStalledSeconds: TimeInterval = 0,
        lastSoC: Int? = nil
    ) {
        self.stepActiveSeconds = stepActiveSeconds
        self.pausedTotalSeconds = pausedTotalSeconds
        self.socUnchangedSeconds = socUnchangedSeconds
        self.fullHoldSeconds = fullHoldSeconds
        self.chargeStalledSeconds = chargeStalledSeconds
        self.lastSoC = lastSoC
    }

    /// 단계가 바뀌면 관측 누적은 모두 버리고 일시정지 예산만 이어간다.
    public func resetForNewStep() -> CalibrationTimers {
        CalibrationTimers(pausedTotalSeconds: pausedTotalSeconds)
    }
}

/// 절차 시작 시점의 사용자 설정. 종료 사유와 무관하게 이걸 그대로 되돌린다.
public struct CalibrationSnapshot: Codable, Equatable, Sendable {
    public var limitEnabled: Bool
    public var limitPercentage: Int
    public var sailingEnabled: Bool
    public var sailingDelta: Int
    public var heatProtectionEnabled: Bool
    public var heatProtectionThresholdCelsius: Int
    public var autoDischargeEnabled: Bool
    public var manualDischargeTarget: Int

    public init(
        limitEnabled: Bool,
        limitPercentage: Int,
        sailingEnabled: Bool,
        sailingDelta: Int,
        heatProtectionEnabled: Bool,
        heatProtectionThresholdCelsius: Int,
        autoDischargeEnabled: Bool,
        manualDischargeTarget: Int
    ) {
        self.limitEnabled = limitEnabled
        self.limitPercentage = limitPercentage
        self.sailingEnabled = sailingEnabled
        self.sailingDelta = sailingDelta
        self.heatProtectionEnabled = heatProtectionEnabled
        self.heatProtectionThresholdCelsius = heatProtectionThresholdCelsius
        self.autoDischargeEnabled = autoDischargeEnabled
        self.manualDischargeTarget = manualDischargeTarget
    }
}

/// 지속 저장되는 실행 상태. 앱 메모리가 아니라 이 값이 절차의 진실이다.
public struct CalibrationRunState: Codable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var step: CalibrationStep
    public var timers: CalibrationTimers
    public var pause: CalibrationPause?
    public var snapshot: CalibrationSnapshot
    public var beginMaxCapacityMilliampHours: Int?
    public var beginCycleCount: Int?
    /// SoC나 단계가 마지막으로 실제로 움직인 벽시계 시각. 12시간 무진행 취소의 기준이며,
    /// 잠자기 동안에도 흐른다 — 뚜껑을 밤새 닫아둔 절차를 끊는 것이 목적이기 때문이다.
    public var lastProgressAt: Date
    public var lastTickAt: Date
    /// 데몬에 마지막으로 실제로 내려보낸 원시 명령. 같은 명령을 10초마다 다시 쓰지 않기
    /// 위한 것이다 — 전이가 아닌 반복 write는 SMC 트래픽 규칙이 금지한다.
    public var appliedPrimitive: CalibrationPrimitive?
    /// 종료가 결정됐지만 원복 write가 아직 확인되지 않은 상태. 이 값이 세워진 동안은 `run`을
    /// 지우지 않는다 — 원복 실패 직후 앱이 죽으면 데몬이 캘리브레이션을 영원히 들고 있게 되고,
    /// `BatteryControlClient.reconcile`은 데몬 자신의 `desiredConfiguration`에서 그 상태를
    /// 다시 읽어 매분 되살릴 뿐이라 스스로 못 고친다. `evaluate`가 매 tick 이 값을 보고
    /// 원복을 재시도한다.
    public var finishing: CalibrationOutcome?
    /// `finishing`이 세워졌을 때 함께 기억해야 할 실패 사유. 재시도가 만드는 이력 항목의
    /// `failure`가 원래 종료 사유와 어긋나지 않아야 한다.
    public var finishingFailure: CalibrationFailure?

    public init(
        id: UUID,
        startedAt: Date,
        step: CalibrationStep,
        timers: CalibrationTimers,
        pause: CalibrationPause?,
        snapshot: CalibrationSnapshot,
        beginMaxCapacityMilliampHours: Int?,
        beginCycleCount: Int?,
        lastProgressAt: Date,
        lastTickAt: Date,
        appliedPrimitive: CalibrationPrimitive?,
        finishing: CalibrationOutcome? = nil,
        finishingFailure: CalibrationFailure? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.step = step
        self.timers = timers
        self.pause = pause
        self.snapshot = snapshot
        self.beginMaxCapacityMilliampHours = beginMaxCapacityMilliampHours
        self.beginCycleCount = beginCycleCount
        self.lastProgressAt = lastProgressAt
        self.lastTickAt = lastTickAt
        self.appliedPrimitive = appliedPrimitive
        self.finishing = finishing
        self.finishingFailure = finishingFailure
    }
}

public struct CalibrationHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var outcome: CalibrationOutcome
    public var failure: CalibrationFailure?
    public var beginMaxCapacityMilliampHours: Int?
    public var endMaxCapacityMilliampHours: Int?
    public var beginCycleCount: Int?
    public var endCycleCount: Int?

    public init(
        id: UUID,
        startedAt: Date,
        finishedAt: Date,
        outcome: CalibrationOutcome,
        failure: CalibrationFailure?,
        beginMaxCapacityMilliampHours: Int?,
        endMaxCapacityMilliampHours: Int?,
        beginCycleCount: Int?,
        endCycleCount: Int?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.failure = failure
        self.beginMaxCapacityMilliampHours = beginMaxCapacityMilliampHours
        self.endMaxCapacityMilliampHours = endMaxCapacityMilliampHours
        self.beginCycleCount = beginCycleCount
        self.endCycleCount = endCycleCount
    }
}
