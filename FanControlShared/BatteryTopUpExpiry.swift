import Foundation

/// "한 번만 완충"(Top Up)이 스스로 끝나야 하는지에 대한 **유일한** 판정.
///
/// Top Up의 원래 종료 조건은 어댑터 분리 하나뿐이었다. 데스크톱처럼 늘 꽂아 두는 사용자가 켜고 잊으면
/// 배터리는 무기한 100%에 머문다 — Battery University BU-808 Table 3 기준 25°C에서 100% 유지는
/// 연 20% 용량 손실(40% 유지는 4%)이므로, 충전 제한 앱이 존재하는 이유와 정면으로 충돌한다.
///
/// 판정을 순수 함수로 떼어 둔 이유는 두 가지다. 하나는 시간이 얽힌 상태 기계를 실시간 대기 없이
/// 테스트하기 위해서고, 다른 하나는 **예외를 넣을 자리를 한 곳으로 고정**하기 위해서다. 배터리
/// 캘리브레이션 모드가 최종 100% 홀드 단계에서 같은 `topUpActive` 원시 명령을 빌려 쓸 예정인데,
/// 그때 만료가 절차를 중간에 끊으면 안 된다. 그 예외는 아래 `calibrationActive` 한 줄이 된다.
public enum BatteryTopUpExpiry {
    /// 100% 도달 후 이만큼 지나면 Top Up을 자동 해제한다. 설정에 노출하지 않는 고정 상수다 —
    /// 노출하려면 `@AppStorage` 키 하나가 `StorageKey`/`Defaults`/`SettingsReset`/설정 UI/30개
    /// 언어 번역을 함께 끌고 오므로, 값이 실제로 문제가 된다는 근거가 생긴 뒤에 하는 편이 싸다.
    public static let duration: TimeInterval = 12 * 60 * 60

    /// 사용자에게 보여 줄 시간 수. 문구가 상수와 갈라지지 않도록 문자열에 12를 직접 쓰지 않는다.
    public static var durationHours: Int { Int(duration / 3600) }

    public enum Decision: Equatable, Sendable {
        /// 할 일 없음.
        case none
        /// 완충 도달 시각을 이 값으로 기록(또는 재고정)한다.
        case stamp(TimeInterval)
        /// Top Up을 해제하고 원래 정책으로 되돌린다.
        case expire
    }

    /// - Parameters:
    ///   - topUpActive: 헬퍼가 실제로 들고 있는 Top Up 상태.
    ///   - isHoldingAtFull: 이번 샘플에서 엔진이 100% 홀드로 판정했는지
    ///     (`BatteryControlStatusReason.Kind.topUpComplete`). SoC 정수를 직접 보지 않는 이유는,
    ///     엔진이 이미 하드웨어 게이트까지 반영해 내린 결론이 이것이기 때문이다.
    ///   - reachedFullAt: 저장된 완충 도달 시각. 아직 도달 전이면 `nil`.
    ///   - now: 벽시계. 잠자기 동안에도 진행해야 하므로 단조 시계를 쓰면 안 된다.
    ///   - calibrationActive: 캘리브레이션 절차가 `topUpActive`를 빌려 쓰는 중인지.
    ///     `BatteryControlCoordinator`가 엔진 설정에서 읽어 넘긴다.
    ///     캘리브레이션 중에는 만료뿐 아니라 **최초 스탬프도 찍지 않는다** — 절차가 자기 시계를
    ///     따로 가질지, 아니면 시계 자체가 없어야 할지는 캘리브레이션 설계가 정할 몫이다.
    public static func decide(
        topUpActive: Bool,
        isHoldingAtFull: Bool,
        reachedFullAt: TimeInterval?,
        now: TimeInterval,
        duration: TimeInterval = BatteryTopUpExpiry.duration,
        calibrationActive: Bool = false
    ) -> Decision {
        guard topUpActive, !calibrationActive else { return .none }
        guard let reachedFullAt else {
            // 충전이 오래 걸린 시간은 만료 시계에 넣지 않는다. 시계는 100%에 닿은 순간 시작한다.
            return isHoldingAtFull ? .stamp(now) : .none
        }
        // 사용자가 시계를 되돌리거나 NTP가 뒤로 점프하면 스탬프가 미래에 남는다. 그대로 두면 만료가
        // 영원히 오지 않으므로 현재로 재고정한다 — 손해는 최대 한 주기 연장뿐이다.
        guard now >= reachedFullAt else { return .stamp(now) }
        return now - reachedFullAt >= duration ? .expire : .none
    }
}
