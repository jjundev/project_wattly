import Foundation

/// `decide`의 전 입력. 시스템 접근이 전혀 없는 값 묶음이라 어떤 조합이든 테스트로 만들 수 있다.
public struct CalibrationInput: Equatable, Sendable {
    public var step: CalibrationStep
    public var timers: CalibrationTimers
    /// **데몬 `status.currentPercentage`(IOPS) 전용.** `BatterySample.percentage`를 넣으면
    /// 안 된다 — raw 비율은 98.99%가 천장이라 완충 단계가 영원히 끝나지 않는다.
    public var soc: Int
    /// **`AdapterDetails.Watts > 0`을 포함해 판정한 값.** CHIE 강제 방전 중에는
    /// `ExternalConnected`도 IOPS도 "배터리 전원"이라고 거짓말한다.
    public var isAdapterPresent: Bool
    public var isHeatProtected: Bool
    public var helperReady: Bool
    public var dischargeSupported: Bool
    public var isSleepGap: Bool
    public var isChargeStalled: Bool
    /// SoC나 단계가 마지막으로 움직인 뒤 흐른 벽시계 시간. 잠자기 동안에도 흐른다.
    public var secondsSinceProgress: TimeInterval

    public init(
        step: CalibrationStep,
        timers: CalibrationTimers,
        soc: Int,
        isAdapterPresent: Bool,
        isHeatProtected: Bool,
        helperReady: Bool,
        dischargeSupported: Bool,
        isSleepGap: Bool,
        isChargeStalled: Bool,
        secondsSinceProgress: TimeInterval
    ) {
        self.step = step
        self.timers = timers
        self.soc = soc
        self.isAdapterPresent = isAdapterPresent
        self.isHeatProtected = isHeatProtected
        self.helperReady = helperReady
        self.dischargeSupported = dischargeSupported
        self.isSleepGap = isSleepGap
        self.isChargeStalled = isChargeStalled
        self.secondsSinceProgress = secondsSinceProgress
    }
}

public enum CalibrationDecision: Equatable, Sendable {
    case hold(CalibrationPrimitive)
    case advance(to: CalibrationStep, primitive: CalibrationPrimitive)
    case pause(CalibrationPause)
    /// 실패에는 반드시 사유가 붙는다. 참조 구현들이 못 한 것이 정확히 이것이다 —
    /// 사용자가 "무엇 때문에 멈췄는지" 알 수 없으면 복구할 방법도 없다.
    case finish(CalibrationOutcome, failure: CalibrationFailure?)
}

/// 시작 버튼을 막는 조건. 순서가 곧 화면에 뜨는 순서다.
public enum CalibrationBlocker: String, Equatable, Sendable, CaseIterable {
    case helperUnavailable
    /// 응답은 하지만 `calibration-v1`을 모르는 헬퍼. 그대로 두면 20% 방전 요청이 조용히
    /// 50%에서 멈춰 절차가 영원히 안 끝난다. 카드 안 인라인 업데이트 버튼으로 해소한다.
    case helperTooOld
    case hardwareUnsupported
    case dischargeUnsupported
    case adapterDisconnected
    case heatProtectionActive
    case otherActivityRunning
    /// macOS "최적화된 배터리 충전"을 껐다는 사용자 확인. 설정 키를 읽을 방법이 없어
    /// 확인으로 대신하지만, 켜져 있으면 절차가 6시간 타임아웃까지 갔다가 실패한다.
    case optimizedChargingUnconfirmed
    /// 약 10시간이 걸리고 방전 7시간 동안 뚜껑을 열어둬야 한다는 확인.
    case durationUnconfirmed
}

/// 캘리브레이션 절차의 모든 판단. SwiftUI도 I/O도 `Date()`도 없다 —
/// `BatteryControlPolicy` / `PollPolicy` / `BatterySectionPresentation`과 같은 방식으로,
/// 코디네이터가 내리던 결정을 테이블 테스트가 가능한 함수로 모아 둔 것이다.
///
/// 아래 상수들은 대부분 개발기(Mac17,2 / M5 / macOS 26.6.2) 실측에서 나왔다. 각 값의
/// 근거를 주석에 남기는 이유는, 웹 조사와 코드 독해만으로 세운 원안의 값 중 셋이 실기에서
/// 뒤집혔기 때문이다.
public enum BatteryCalibration {

    // MARK: - 상수

    /// 방전 하한. AlDente는 10~15%를 노리다 11% 부근의 펌웨어 벽에 막히는 중이고(issue #1784),
    /// 20%는 그 절벽 위에 안전 마진을 두고 앉는다. 사용자에게 노출하지 않는다.
    public static let floorPercentage = 20

    /// 완충 인정에 필요한 `soc >= 100 && !isCharging` 지속 시간.
    /// 임계 전력(W)을 두지 않는 이유: 테이퍼가 8.01W → 0.00W 한 스텝에 절벽처럼 떨어져
    /// 튜닝할 구간 자체가 없다. `FullyCharged` 플래그는 완충 후에도 `No`로 남아 못 쓴다.
    public static let fullSettleSeconds: TimeInterval = 60

    /// 저잔량 안정화. BMS가 하한 경계에서 재학습할 짧은 정지 구간.
    public static let soakLowSeconds: TimeInterval = 600
    /// 최종 완충 후 안정화. 캘리브레이션의 charge flag를 세우는 것이 이 구간이다.
    public static let soakFinalSeconds: TimeInterval = 3600

    /// 방전 정체 인정 시간. 펌웨어가 더 이상 내려주지 않는 지점을 실패로 부르면 절차가
    /// 영원히 끝나지 않는다 — 참조 구현의 대표적 행 사유가 이것이다.
    public static let dischargeStallSeconds: TimeInterval = 900

    /// tick 간격이 이보다 벌어지면 그 사이 Mac이 잤다고 본다. 코디네이터 tick은 10초라
    /// 90초는 넉넉한 여유이면서 clamshell sleep(최소 수십 초)을 놓치지 않는다.
    public static let sleepGapSeconds: TimeInterval = 90

    public static let chargePhaseTimeout: TimeInterval = 6 * 3600
    /// 방전은 실측 0.113~0.331 %p/분으로 부하에 따라 3배 흔들린다. 100→20%가 4~7시간이라
    /// 원안의 10시간으로는 여유가 부족했다.
    public static let dischargePhaseTimeout: TimeInterval = 12 * 3600

    /// 일시정지 누적 상한. 열보호를 끄지 않는 대가로 정지가 길어질 수 있어 상한이 필요하다.
    /// 잠자기는 여기에 들어가지 않는다 (`CalibrationPause.consumesBudget`).
    public static let pauseBudgetSeconds: TimeInterval = 2 * 3600

    /// 진행이 전혀 없는 채로 이만큼 지나면 조용히 취소하고 원설정을 되돌린다. 뚜껑을 밤새
    /// 닫아둔 절차가 영원히 매달리는 것을 끊는 유일한 장치다.
    public static let staleAbandonSeconds: TimeInterval = 12 * 3600

    /// Battery University: "once every three months **or after 40 partial cycles**".
    public static let cooldownDays = 90
    public static let cooldownCycles = 40

    /// 충전 정체 판정: 어댑터가 붙고 게이트도 열렸는데 충전 전류가 이 값 아래로 이만큼
    /// 지속되면 외부 요인이 막고 있는 것이다. 실기에서 "최적화된 배터리 충전"이 켜져 있을 때
    /// `ChargingCurrent`가 100 mA에 머물렀다.
    public static let chargeStallMilliamps = 300
    public static let chargeStallSeconds: TimeInterval = 600

    /// 캘리브레이션과 무관하게 하루 안에 관측된 `AppleRawMaxCapacity` 변동폭.
    /// 완료 리포트는 용량 숫자 옆에 이 값을 반드시 함께 적는다.
    public static let naturalCapacityDriftMilliampHours = 86

    /// ETA 기본값 (실측 중앙값). 관측값이 생기면 코디네이터가 그것으로 대체한다.
    public static let defaultChargeRatePercentPerMinute = 0.73
    public static let defaultDischargeRatePercentPerMinute = 0.22

    // MARK: - 타이머 누적

    /// 한 tick만큼 타이머를 전진시킨다.
    ///
    /// - Parameters:
    ///   - elapsed: 직전 tick 이후 흐른 벽시계 시간.
    ///   - isSleepGap: `elapsed > sleepGapSeconds`. 이 경우 관측 누적을 **버린다** —
    ///     clamshell sleep은 "SoC 무변화"와 signature가 같아서, 버리지 않으면 60%에서
    ///     뚜껑을 20분 덮은 것이 하한 도달로 오인된다.
    ///   - isPaused: 예산을 소모하는 일시정지인지 (`CalibrationPause.consumesBudget`).
    ///   - isFullSettled: `soc >= 100 && !isCharging`.
    ///   - isChargeStalled: 충전 단계인데 충전 전류가 `chargeStallMilliamps` 미만.
    public static func tick(
        _ timers: CalibrationTimers,
        elapsed: TimeInterval,
        isSleepGap: Bool,
        isPaused: Bool,
        soc: Int,
        isFullSettled: Bool,
        isChargeStalled: Bool
    ) -> CalibrationTimers {
        guard elapsed > 0 else { return timers }
        var next = timers

        if isSleepGap {
            next.socUnchangedSeconds = 0
            next.fullHoldSeconds = 0
            next.chargeStalledSeconds = 0
            next.lastSoC = soc
            return next
        }

        if isPaused {
            // 일시정지 중에는 안정화 타이머가 멈춘다 — 멈추지 않으면 "대기 60분"이 실제로는
            // 억제 상태로 흘러가 그 구간이 무의미해진다.
            next.pausedTotalSeconds += elapsed
            return next
        }

        next.stepActiveSeconds += elapsed
        next.socUnchangedSeconds = (next.lastSoC == soc) ? next.socUnchangedSeconds + elapsed : 0
        next.fullHoldSeconds = isFullSettled ? next.fullHoldSeconds + elapsed : 0
        next.chargeStalledSeconds = isChargeStalled ? next.chargeStalledSeconds + elapsed : 0
        next.lastSoC = soc
        return next
    }

    // MARK: - 상태 전이

    public static func stepTimeout(for step: CalibrationStep) -> TimeInterval? {
        switch step {
        case .chargeToFull, .rechargeToFull: return chargePhaseTimeout
        case .dischargeToFloor: return dischargePhaseTimeout
        case .preflight, .soakLow, .soakFinal, .restoring: return nil
        }
    }

    /// 이번 tick에 무엇을 할지. 판정 순서 자체가 설계이므로 함부로 재배열하지 말 것 —
    /// 특히 잠자기가 예산 소모 일시정지들보다 **먼저** 와야 예산이 보호된다.
    public static func decide(_ input: CalibrationInput) -> CalibrationDecision {
        // 0. 원복 단계는 조건 없이 끝난다. 실제 원복은 코디네이터가 이미 수행한 뒤다.
        if input.step == .restoring { return .finish(.completed, failure: nil) }

        // 1. 12시간 무진행. 뚜껑을 밤새 닫아둔 경우가 여기로 들어온다. 실패가 아니라
        //    조용한 취소로 끝내고 원설정을 되돌린다.
        if input.secondsSinceProgress >= staleAbandonSeconds {
            return .finish(.expired, failure: nil)
        }

        // 2. 잠자기. 예산을 쓰지 않고, 정체 관측은 `tick`이 이미 버렸다.
        if input.isSleepGap { return .pause(.systemSleep) }

        // 3. 일시정지 예산 소진. 아래 세 개의 `.pause` 판정(헬퍼 부재/열보호/어댑터)보다
        //    반드시 먼저 와야 한다 — 그 셋 중 하나가 계속 발동 중이면 `decide`는 매 tick
        //    거기서 멈춰 서고 이 판정까지 내려오지 못한다. 그러면 사용자가 손댈 수 없는
        //    일시정지(예: 열보호)가 두 시간을 넘겨도 아무도 알아채지 못하다가, 정지 사유가
        //    풀리는 바로 그 tick에야 예산 소진으로 실패해 버려 절차가 문제 해결 직후에
        //    죽는다. 예산이 실제로 막아야 하는 것이 정확히 그 경우이므로 이 검사가 위에 있어야
        //    한다.
        if input.timers.pausedTotalSeconds >= pauseBudgetSeconds {
            return .finish(.failed, failure: .pauseBudgetExhausted)
        }

        // 4. 헬퍼 부재. 하드웨어는 마지막 원시 상태를 그대로 들고 있다.
        if !input.helperReady { return .pause(.helperUnavailable) }

        // 5. CHIE가 없으면 절차 자체가 성립하지 않는다. preflight가 이미 막지만,
        //    실행 중 하드웨어 판정이 뒤집히는 경우까지 여기서 닫는다.
        if !input.dischargeSupported {
            return .finish(.failed, failure: .dischargeUnsupported)
        }

        // 6. 열보호는 절대 자동 비활성화하지 않는다. 발동하면 기다린다.
        if input.isHeatProtected { return .pause(.heatProtection) }

        // 7. 어댑터. 방전 단계만 어댑터 없이도 진행된다.
        if input.step != .dischargeToFloor && !input.isAdapterPresent {
            return .pause(.needsAdapter)
        }

        // 8. 단계 타임아웃.
        if let timeout = stepTimeout(for: input.step),
           input.timers.stepActiveSeconds >= timeout {
            return .finish(.failed, failure: .stepTimeout)
        }

        // 9. 외부 요인이 충전을 막고 있다. 실기에서 macOS "최적화된 배터리 충전"이 켜져
        //    있으면 우리가 게이트를 열어도 충전이 시작되지 않았다 — 막는 이유를 아무 레지스터도
        //    보고하지 않은 채로.
        if input.step.primitive == .chargeToFull,
           input.soc < 100,
           input.isChargeStalled,
           input.timers.chargeStalledSeconds >= chargeStallSeconds {
            return .pause(.externalChargeBlock)
        }

        // 10. 단계 완료 판정.
        if isStepComplete(input), let next = input.step.next {
            return .advance(to: next, primitive: next.primitive)
        }
        return .hold(input.step.primitive)
    }

    private static func isStepComplete(_ input: CalibrationInput) -> Bool {
        switch input.step {
        case .preflight:
            return true
        case .chargeToFull, .rechargeToFull:
            return input.timers.fullHoldSeconds >= fullSettleSeconds
        case .dischargeToFloor:
            // 목표 도달, 또는 정체. 정체를 성공으로 처리하지 않으면 펌웨어 벽에서 절차가
            // 영원히 끝나지 않는다.
            return input.soc <= floorPercentage
                || input.timers.socUnchangedSeconds >= dischargeStallSeconds
        case .soakLow:
            return input.timers.stepActiveSeconds >= soakLowSeconds
        case .soakFinal:
            return input.timers.stepActiveSeconds >= soakFinalSeconds
        case .restoring:
            return true
        }
    }

    // MARK: - Preflight

    public static func preflightBlockers(
        helperMode: BatteryControlServiceMode,
        capabilities: [BatteryControlCapability]?,
        isHardwareSupported: Bool?,
        isDischargeHardwareSupported: Bool?,
        isAdapterPresent: Bool,
        isHeatProtected: Bool,
        isTopUpActive: Bool,
        isManualDischargeActive: Bool,
        hasConfirmedOptimizedChargingOff: Bool,
        hasConfirmedDuration: Bool
    ) -> [CalibrationBlocker] {
        var blockers: [CalibrationBlocker] = []
        if helperMode == .unavailable {
            blockers.append(.helperUnavailable)
        } else if capabilities?.contains(.calibrationV1) != true {
            blockers.append(.helperTooOld)
        }
        // `nil`은 "모름"이지 "미지원"이 아니다. 모름으로 사용자를 막지 않는다.
        if isHardwareSupported == false { blockers.append(.hardwareUnsupported) }
        if isDischargeHardwareSupported == false { blockers.append(.dischargeUnsupported) }
        if !isAdapterPresent { blockers.append(.adapterDisconnected) }
        if isHeatProtected { blockers.append(.heatProtectionActive) }
        if isTopUpActive || isManualDischargeActive { blockers.append(.otherActivityRunning) }
        if !hasConfirmedOptimizedChargingOff { blockers.append(.optimizedChargingUnconfirmed) }
        if !hasConfirmedDuration { blockers.append(.durationUnconfirmed) }
        return blockers
    }

    /// 마지막 완료로부터 90일도, 사이클 40회도 지나지 않았는가. 둘 중 하나만 넘겨도
    /// 쿨다운은 끝난 것으로 본다 (Battery University의 "3개월 **또는** 40 부분 사이클").
    public static func isWithinCooldown(
        lastCompletedAt: Date?,
        cycleCountAtLastCompletion: Int?,
        currentCycleCount: Int?,
        now: Date
    ) -> Bool {
        guard let lastCompletedAt else { return false }
        let elapsedDays = now.timeIntervalSince(lastCompletedAt) / 86_400
        if elapsedDays >= Double(cooldownDays) { return false }
        if let before = cycleCountAtLastCompletion, let current = currentCycleCount,
           current - before >= cooldownCycles { return false }
        return true
    }

    // MARK: - 예상 시간

    /// 현재 단계부터 끝까지의 예상 분. 실측 방전 속도가 0.113~0.331 %p/분으로 3배 흔들리므로
    /// 고정 추정치를 쓰지 않고, 관측 속도가 있으면 그것을 받는다.
    public static func estimatedRemainingMinutes(
        step: CalibrationStep,
        soc: Int,
        chargeRatePercentPerMinute: Double? = nil,
        dischargeRatePercentPerMinute: Double? = nil
    ) -> Int {
        // 0에 가까운 속도는 무한대를 만든다. 바닥을 깔아 둔다.
        let chargeRate = max(0.05, chargeRatePercentPerMinute ?? defaultChargeRatePercentPerMinute)
        let dischargeRate = max(0.05, dischargeRatePercentPerMinute ?? defaultDischargeRatePercentPerMinute)
        var minutes = 0.0
        var projectedSoC = Double(soc)
        var cursor: CalibrationStep? = step
        while let current = cursor {
            switch current {
            case .preflight, .restoring:
                break
            case .chargeToFull, .rechargeToFull:
                minutes += max(0, 100 - projectedSoC) / chargeRate
                projectedSoC = 100
            case .dischargeToFloor:
                minutes += max(0, projectedSoC - Double(floorPercentage)) / dischargeRate
                projectedSoC = Double(floorPercentage)
            case .soakLow:
                minutes += soakLowSeconds / 60
            case .soakFinal:
                minutes += soakFinalSeconds / 60
            }
            cursor = current.next
        }
        return Int(minutes.rounded())
    }

    /// 관측된 속도를 이전 추정치에 섞는다. 실측 방전 속도가 0.113~0.331 %p/분으로 흔들려
    /// 한 샘플을 그대로 쓰면 ETA가 튀고, 고정값을 쓰면 3배까지 틀린다.
    public static func blendedRate(previous: Double?, sample: Double) -> Double {
        guard let previous else { return sample }
        return previous * 0.7 + sample * 0.3
    }

    // MARK: - 완료 리포트

    /// 이 절차가 실제로 한 일. 셀 회복도 수명 연장도 아니다.
    public static func completionHeadline(locale: Locale) -> String {
        String(localized: "잔량 표시 보정 완료", locale: locale)
    }

    /// 용량 mAh는 참고값이다.
    ///
    /// 1회 사이클로 최대 용량 추정치가 움직이는지 실기로 확인했고, 관측된 변화(+35 mAh)는
    /// 같은 하루 안의 자연 변동폭(86 mAh)에 묻혔다. 게다가 최종값이 `DesignCapacity`와 정확히
    /// 일치한 순간이 있었던 것으로 보아 BMS가 상단을 클램프하는 듯하며, 건강한 배터리에서는
    /// "개선"이 구조적으로 표시될 수 없다. 그래서 숫자만 보여주면 사용자가 노이즈를 성과로
    /// 읽는다 — 변동폭을 반드시 함께 적는다.
    public static func capacityNote(
        beginMilliampHours: Int?,
        endMilliampHours: Int?,
        locale: Locale
    ) -> String? {
        guard let beginMilliampHours, let endMilliampHours else { return nil }
        let formatString = String(localized: "최대 용량 추정치 %lld → %lld mAh (참고값 · 자연 변동폭 %lld mAh)", locale: locale)
        return String(format: formatString, Int64(beginMilliampHours), Int64(endMilliampHours), Int64(naturalCapacityDriftMilliampHours))
    }

    // MARK: - 표시 문구

    public static func stepLabel(_ step: CalibrationStep, locale: Locale) -> String {
        switch step {
        case .preflight: return String(localized: "시작 준비", locale: locale)
        case .chargeToFull: return String(localized: "100%까지 충전", locale: locale)
        case .dischargeToFloor: return String(localized: "20%까지 방전", locale: locale)
        case .soakLow: return String(localized: "저잔량 안정화 (10분)", locale: locale)
        case .rechargeToFull: return String(localized: "다시 100%까지 충전", locale: locale)
        case .soakFinal: return String(localized: "최종 안정화 (60분)", locale: locale)
        case .restoring: return String(localized: "원래 설정으로 복원", locale: locale)
        }
    }

    public static func pauseText(_ pause: CalibrationPause, locale: Locale) -> String {
        switch pause {
        case .needsAdapter:
            return String(localized: "일시정지: 전원 어댑터를 다시 연결해 주세요", locale: locale)
        case .heatProtection:
            return String(localized: "일시정지: 발열 보호 작동 중 (식으면 자동으로 이어집니다)", locale: locale)
        case .helperUnavailable:
            return String(localized: "일시정지: 도우미에 연결되지 않았습니다", locale: locale)
        case .systemSleep:
            return String(localized: "일시정지: 잠자기 상태입니다 (뚜껑을 열면 이어집니다)", locale: locale)
        case .externalChargeBlock:
            return String(localized: "일시정지: 충전이 시작되지 않습니다. \"최적화된 배터리 충전\"을 꺼 주세요", locale: locale)
        }
    }

    public static func blockerText(_ blocker: CalibrationBlocker, locale: Locale) -> String {
        switch blocker {
        case .helperUnavailable:
            return String(localized: "도우미가 설치되어 있지 않습니다.", locale: locale)
        case .helperTooOld:
            return String(localized: "설치된 도우미가 캘리브레이션을 지원하지 않습니다. 업데이트가 필요합니다.", locale: locale)
        case .hardwareUnsupported:
            return String(localized: "이 Mac은 충전 제어를 지원하지 않습니다.", locale: locale)
        case .dischargeUnsupported:
            return String(localized: "이 Mac은 강제 방전을 지원하지 않아 캘리브레이션을 할 수 없습니다.", locale: locale)
        case .adapterDisconnected:
            return String(localized: "전원 어댑터를 연결해 주세요.", locale: locale)
        case .heatProtectionActive:
            return String(localized: "발열 보호가 작동 중입니다. 배터리가 식은 뒤에 시작해 주세요.", locale: locale)
        case .otherActivityRunning:
            return String(localized: "한 번만 완충 또는 수동 방전이 진행 중입니다. 먼저 끝내 주세요.", locale: locale)
        case .optimizedChargingUnconfirmed:
            return String(localized: "시스템 설정 › 배터리에서 \"최적화된 배터리 충전\"을 껐습니다.", locale: locale)
        case .durationUnconfirmed:
            return String(localized: "약 10시간이 걸리며, 방전 구간 약 7시간 동안은 뚜껑을 열어 두어야 합니다. 화면은 꺼져도 됩니다.", locale: locale)
        }
    }

    /// 팝오버 배터리 카드에 붙는 한 줄. 일시정지 중이면 단계 대신 사유를 말한다 —
    /// 멈춘 이유가 남은 시간보다 먼저 알아야 할 정보다.
    public static func summaryLine(
        step: CalibrationStep,
        pause: CalibrationPause?,
        remainingMinutes: Int,
        locale: Locale
    ) -> String {
        if let pause { return pauseText(pause, locale: locale) }
        return String(
            format: String(localized: "캘리브레이션: %@ · 남은 시간 약 %@", locale: locale),
            locale: locale,
            stepLabel(step, locale: locale),
            BatterySectionPresentation.formatDuration(minutes: remainingMinutes, locale: locale))
    }
}
