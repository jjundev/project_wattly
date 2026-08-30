import Foundation
import Testing
@testable import Wattly

struct BatteryCalibrationTickTests {
    private func makeTimers(lastSoC: Int?) -> CalibrationTimers {
        CalibrationTimers(lastSoC: lastSoC)
    }

    @Test func activeTickAccumulatesStepTime() {
        let out = BatteryCalibration.tick(
            makeTimers(lastSoC: 60), elapsed: 10, isSleepGap: false, isPaused: false,
            soc: 59, isFullSettled: false, isChargeStalled: false)
        #expect(out.stepActiveSeconds == 10)
        #expect(out.pausedTotalSeconds == 0)
        #expect(out.socUnchangedSeconds == 0)   // SoC가 움직였으니 정체는 리셋
        #expect(out.lastSoC == 59)
    }

    @Test func unchangedSoCAccumulatesStallTime() {
        var timers = makeTimers(lastSoC: 60)
        for _ in 0..<3 {
            timers = BatteryCalibration.tick(
                timers, elapsed: 10, isSleepGap: false, isPaused: false,
                soc: 60, isFullSettled: false, isChargeStalled: false)
        }
        #expect(timers.socUnchangedSeconds == 30)
        #expect(timers.stepActiveSeconds == 30)
    }

    @Test func sleepGapFreezesEverythingAndDropsObservations() {
        var timers = makeTimers(lastSoC: 60)
        timers.stepActiveSeconds = 600
        timers.socUnchangedSeconds = 600
        timers.fullHoldSeconds = 40
        timers.chargeStalledSeconds = 120
        timers.pausedTotalSeconds = 300

        let out = BatteryCalibration.tick(
            timers, elapsed: 1200, isSleepGap: true, isPaused: false,
            soc: 60, isFullSettled: false, isChargeStalled: false)

        // 잠든 시간은 단계 시간에도, 일시정지 예산에도 들어가지 않는다.
        #expect(out.stepActiveSeconds == 600)
        #expect(out.pausedTotalSeconds == 300)
        // 잠들기 전에 쌓인 "무변화" 관측은 버린다 — 이게 clamshell 오작동을 막는 지점이다.
        #expect(out.socUnchangedSeconds == 0)
        #expect(out.fullHoldSeconds == 0)
        #expect(out.chargeStalledSeconds == 0)
        #expect(out.lastSoC == 60)
    }

    @Test func pausedTickSpendsBudgetAndFreezesStepTimer() {
        var timers = makeTimers(lastSoC: 60)
        timers.stepActiveSeconds = 100
        timers.socUnchangedSeconds = 100
        let out = BatteryCalibration.tick(
            timers, elapsed: 10, isSleepGap: false, isPaused: true,
            soc: 60, isFullSettled: false, isChargeStalled: false)
        #expect(out.pausedTotalSeconds == 10)
        #expect(out.stepActiveSeconds == 100)
        #expect(out.socUnchangedSeconds == 100)
    }

    @Test func fullHoldAndChargeStallResetWhenTheConditionBreaks() {
        var timers = makeTimers(lastSoC: 100)
        timers.fullHoldSeconds = 50
        timers.chargeStalledSeconds = 500
        let out = BatteryCalibration.tick(
            timers, elapsed: 10, isSleepGap: false, isPaused: false,
            soc: 100, isFullSettled: false, isChargeStalled: false)
        #expect(out.fullHoldSeconds == 0)
        #expect(out.chargeStalledSeconds == 0)
    }

    @Test func nonPositiveElapsedIsIgnored() {
        let timers = makeTimers(lastSoC: 60)
        let out = BatteryCalibration.tick(
            timers, elapsed: -5, isSleepGap: false, isPaused: false,
            soc: 10, isFullSettled: false, isChargeStalled: false)
        #expect(out == timers)
    }

    @Test func constantsMatchTheVerifiedDesign() {
        #expect(BatteryCalibration.floorPercentage == 20)
        #expect(BatteryCalibration.fullSettleSeconds == 60)
        #expect(BatteryCalibration.soakLowSeconds == 600)
        #expect(BatteryCalibration.soakFinalSeconds == 3600)
        #expect(BatteryCalibration.dischargeStallSeconds == 900)
        #expect(BatteryCalibration.sleepGapSeconds == 90)
        #expect(BatteryCalibration.chargePhaseTimeout == 6 * 3600)
        #expect(BatteryCalibration.dischargePhaseTimeout == 12 * 3600)
        #expect(BatteryCalibration.pauseBudgetSeconds == 2 * 3600)
        #expect(BatteryCalibration.staleAbandonSeconds == 12 * 3600)
        #expect(BatteryCalibration.cooldownDays == 90)
        #expect(BatteryCalibration.cooldownCycles == 40)
        #expect(BatteryCalibration.naturalCapacityDriftMilliampHours == 86)
    }
}
