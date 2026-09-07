import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryClamshellSleepPolicyTests {
    @Test func defaultDurationIsTwelveHours() {
        #expect(BatteryClamshellSleepPolicy.duration == 12 * 3600)
        #expect(BatteryClamshellSleepPolicy.durationHours == 12)
    }

    /// 옵트인이 없으면 방전 중이어도 아무것도 하지 않는다.
    @Test func doesNothingWhenNotAllowed() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: false, isDischarging: true, inhibitedAt: nil,
            expiredForCurrentDischarge: false, now: 1_000) == .none)
    }

    /// 옵트인이 있어도 CHIE가 걸려 있지 않으면 켜지 않는다.
    @Test func doesNothingWhileNotDischarging() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: false, inhibitedAt: nil,
            expiredForCurrentDischarge: false, now: 1_000) == .none)
    }

    @Test func engagesWhenAllowedAndDischarging() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: nil,
            expiredForCurrentDischarge: false, now: 1_000) == .engage)
    }

    /// 같은 방전 세션에서 이미 12시간을 다 쓴 뒤에는 다시 켜지 않는다 — 앱의 60초 reconcile이
    /// `allowed=true`를 매분 되밀어도 만료가 무력화되면 안 된다.
    @Test func doesNotReengageAfterExpiryWithinTheSameDischarge() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: nil,
            expiredForCurrentDischarge: true, now: 1_000) == .none)
    }

    @Test func staysEngagedWhileConditionsHold() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: 1_000,
            expiredForCurrentDischarge: false, now: 1_000 + 3_600) == .none)
    }

    /// 방전이 끝나면(목표 도달·어댑터 분리·발열 보호·사용자 중지) 즉시 되돌린다.
    @Test func disengagesWhenDischargeStops() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: false, inhibitedAt: 1_000,
            expiredForCurrentDischarge: false, now: 2_000) == .disengage)
    }

    /// 사용자가 옵트인을 끄거나 외장 디스플레이를 뽑으면(앱이 allowed=false를 보냄) 되돌린다.
    @Test func disengagesWhenAllowanceIsWithdrawn() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: false, isDischarging: true, inhibitedAt: 1_000,
            expiredForCurrentDischarge: false, now: 2_000) == .disengage)
    }

    @Test func expiresAfterTheDuration() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: 1_000,
            expiredForCurrentDischarge: false,
            now: 1_000 + BatteryClamshellSleepPolicy.duration) == .expire)
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: 1_000,
            expiredForCurrentDischarge: false,
            now: 1_000 + BatteryClamshellSleepPolicy.duration - 1) == .none)
    }

    /// 시계가 뒤로 점프해 스탬프가 미래에 남으면 만료가 영원히 오지 않는다. Top Up과 같은
    /// 규칙으로 현재 시각에 재고정한다 — 손해는 최대 한 주기 연장뿐이다.
    @Test func restampsWhenTheClockWentBackwards() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: 5_000,
            expiredForCurrentDischarge: false, now: 4_000) == .restamp(4_000))
    }

    /// 만료·해제 판정은 스탬프가 있을 때 allowed/discharging보다 우선하지 않는다 —
    /// 방전이 이미 끝났으면 `.disengage`가 맞고, `.expire`로 래치를 세우면 다음 방전이
    /// 클램쉘을 못 쓴다.
    @Test func disengagePrecedesExpiryWhenDischargeAlreadyStopped() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: false, inhibitedAt: 0,
            expiredForCurrentDischarge: false,
            now: BatteryClamshellSleepPolicy.duration * 2) == .disengage)
    }
}
