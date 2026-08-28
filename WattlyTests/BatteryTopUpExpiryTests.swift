import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryTopUpExpiryTests {
    @Test func defaultDurationIsTwelveHours() {
        #expect(BatteryTopUpExpiry.duration == 12 * 3600)
        #expect(BatteryTopUpExpiry.durationHours == 12)
    }

    /// Top Up이 꺼져 있으면 시계는 돌지 않는다.
    @Test func doesNothingWhileTopUpIsOff() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: false, isHoldingAtFull: true,
            reachedFullAt: nil, now: 1_000) == .none)
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: false, isHoldingAtFull: true,
            reachedFullAt: 0, now: 1_000_000) == .none)
    }

    /// 100%에 도달하기 전에는 스탬프를 찍지 않는다 — 충전에 걸리는 시간은 만료 시계에 포함되지 않는다.
    @Test func doesNotStampWhileStillChargingUp() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: false,
            reachedFullAt: nil, now: 1_000) == .none)
    }

    @Test func stampsOnTheFirstFullHoldObservation() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: nil, now: 1_000) == .stamp(1_000))
    }

    /// 이미 스탬프가 있으면 다시 찍지 않는다 (도달 시각이 뒤로 밀리면 영원히 만료되지 않는다).
    @Test func doesNotRestampAnExistingStamp() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 1_000, now: 2_000) == .none)
    }

    /// 발열 보호 등으로 100% 홀드가 잠시 풀려도 시계는 계속 간다.
    @Test func keepsCountingWhenTheHoldIsTemporarilyLost() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: false,
            reachedFullAt: 1_000, now: 1_000 + 12 * 3600) == .expire)
    }

    @Test func expiresExactlyAtTheBoundaryAndNotBefore() {
        let stamp: TimeInterval = 10_000
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: stamp, now: stamp + 12 * 3600 - 1) == .none)
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: stamp, now: stamp + 12 * 3600) == .expire)
    }

    /// 잠자기를 12시간 건너뛰어도 벽시계 비교라 한 번에 만료된다.
    @Test func expiresAfterALongSleepGap() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 0, now: 30 * 3600) == .expire)
    }

    /// 시계가 뒤로 점프하면 스탬프가 미래에 남는다. 그대로 두면 영구 미만료가 되므로 현재로 재고정한다.
    @Test func reanchorsWhenTheClockMovesBackwards() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 5_000, now: 1_000) == .stamp(1_000))
    }

    /// 캘리브레이션 예외 자리. 지금은 호출자가 없고 기본값은 false다.
    @Test func neverExpiresWhileCalibrationOwnsTheTopUpPrimitive() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 0, now: 30 * 3600,
            calibrationActive: true) == .none)
    }

    @Test func honoursAnInjectedDuration() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 0, now: 60, duration: 60) == .expire)
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 0, now: 59, duration: 60) == .none)
    }
}
