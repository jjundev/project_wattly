import Foundation

/// 클램쉘 방전의 잠자기 차단을 "지금 켜야 하는가 / 꺼야 하는가"에 대한 **유일한** 판정.
///
/// 배경: CHIE 강제 방전 중에는 macOS가 배터리 구동으로 보고, powerd는 `DesktopMode && AC`가
/// 아니면 뚜껑 닫힘에 잠자기를 건다. 잠들면 방전은 정지한다(602초에 −0.01%p, 실측).
/// `PreventUserIdleSystemSleep`·`caffeinate`·`AppliesOnLidClose` 어설션은 이 OS에서 통하지
/// 않아(마지막 것은 루트에서도 거부) 시스템 전역 `SleepDisabled`를 쓴다. 그 설정은 재부팅을
/// 넘어 남으므로, 켜는 조건은 좁고 끄는 경로는 여러 겹이어야 한다.
///
/// 순수 함수로 떼어 둔 이유는 `BatteryTopUpExpiry`와 같다 — 시간이 얽힌 전이를 실제 대기 없이
/// 테이블 테스트하고, 만료 예외를 넣을 자리를 한 곳으로 고정한다.
public enum BatteryClamshellSleepPolicy {
    /// 켠 뒤 이만큼 지나면 무조건 해제한다. Top Up 만료와 같은 12시간 — 실측 방전 속도
    /// 0.11~0.33 %p/분이면 수동 100→50%가 최대 약 8시간, 캘리브레이션 100→20%가 약 7시간이다.
    public static let duration: TimeInterval = 12 * 60 * 60

    /// 사용자에게 보여 줄 시간 수. 문구가 상수와 갈라지지 않도록 문자열에 12를 직접 쓰지 않는다.
    public static var durationHours: Int { Int(duration / 3600) }

    public enum Decision: Equatable, Sendable {
        case none
        /// 마커를 저장하고 `SleepDisabled`를 켠다.
        case engage
        /// 스탬프가 미래에 있다(시계 역행). 이 시각으로 재고정한다.
        case restamp(TimeInterval)
        /// `SleepDisabled`를 끄고 마커를 지운다.
        case disengage
        /// `.disengage` + 같은 방전 세션 동안 재개 금지 래치.
        case expire
    }

    /// - Parameters:
    ///   - allowed: 앱이 보낸 `clamshellDischargeAllowed`(옵트인 && 외장 디스플레이).
    ///   - isDischarging: 엔진의 `isDischargingNow` — CHIE가 실제로 걸려 있는지.
    ///   - inhibitedAt: Wattly가 켠 시각(소유 마커). 우리가 켜지 않았으면 `nil`.
    ///   - expiredForCurrentDischarge: 이번 방전 세션에서 이미 만료됐는지. 코디네이터가
    ///     `isDischarging`이 거짓이 되는 순간 리셋한다.
    ///   - now: 벽시계. 잠자기 동안에도 진행해야 하므로 단조 시계를 쓰면 안 된다.
    public static func decide(
        allowed: Bool,
        isDischarging: Bool,
        inhibitedAt: TimeInterval?,
        expiredForCurrentDischarge: Bool,
        now: TimeInterval,
        duration: TimeInterval = BatteryClamshellSleepPolicy.duration
    ) -> Decision {
        guard let inhibitedAt else {
            guard allowed, isDischarging, !expiredForCurrentDischarge else { return .none }
            return .engage
        }
        // 소유 중. 조건이 하나라도 깨지면 만료보다 먼저 해제한다 — 방전이 끝난 뒤 `.expire`로
        // 래치를 세우면 다음 방전이 클램쉘을 못 쓴다.
        guard allowed, isDischarging else { return .disengage }
        guard now >= inhibitedAt else { return .restamp(now) }
        return now - inhibitedAt >= duration ? .expire : .none
    }
}
