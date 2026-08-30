import Foundation

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
}
