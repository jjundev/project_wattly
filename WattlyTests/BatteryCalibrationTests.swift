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

    @Test func sleepGapOutranksPausedSoTheBudgetIsProtected() {
        var timers = makeTimers(lastSoC: 60)
        timers.pausedTotalSeconds = 300
        timers.socUnchangedSeconds = 600
        timers.fullHoldSeconds = 40
        timers.chargeStalledSeconds = 120

        // 잠자기와 일시정지가 동시에 참이면 잠자기가 이긴다 — 그래야 예산이 안 깎인다.
        let out = BatteryCalibration.tick(
            timers, elapsed: 1200, isSleepGap: true, isPaused: true,
            soc: 60, isFullSettled: false, isChargeStalled: false)

        #expect(out.pausedTotalSeconds == 300)
        #expect(out.socUnchangedSeconds == 0)
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

struct BatteryCalibrationDecideTests {
    private func input(
        step: CalibrationStep = .chargeToFull,
        timers: CalibrationTimers = CalibrationTimers(),
        soc: Int = 50,
        isAdapterPresent: Bool = true,
        isHeatProtected: Bool = false,
        helperReady: Bool = true,
        dischargeSupported: Bool = true,
        isSleepGap: Bool = false,
        isChargeStalled: Bool = false,
        secondsSinceProgress: TimeInterval = 0
    ) -> CalibrationInput {
        CalibrationInput(
            step: step, timers: timers, soc: soc,
            isAdapterPresent: isAdapterPresent, isHeatProtected: isHeatProtected,
            helperReady: helperReady, dischargeSupported: dischargeSupported,
            isSleepGap: isSleepGap, isChargeStalled: isChargeStalled,
            secondsSinceProgress: secondsSinceProgress)
    }

    // MARK: 정상 전이

    @Test func preflightAdvancesIntoTheFirstCharge() {
        #expect(BatteryCalibration.decide(input(step: .preflight))
            == .advance(to: .chargeToFull, primitive: .chargeToFull))
    }

    @Test func chargeHoldsUntilFullIsSettledForAMinute() {
        var timers = CalibrationTimers()
        timers.fullHoldSeconds = 50
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, timers: timers, soc: 100))
            == .hold(.chargeToFull))
        timers.fullHoldSeconds = 60
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, timers: timers, soc: 100))
            == .advance(to: .dischargeToFloor, primitive: .dischargeToFloor))
    }

    @Test func dischargeAdvancesAtTheFloor() {
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, soc: 21, isAdapterPresent: true))
            == .hold(.dischargeToFloor))
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, soc: 20, isAdapterPresent: true))
            == .advance(to: .soakLow, primitive: .holdAtFloor))
    }

    @Test func dischargeStallCountsAsSuccessNotFailure() {
        var timers = CalibrationTimers()
        timers.socUnchangedSeconds = BatteryCalibration.dischargeStallSeconds
        // 펌웨어가 더 내려주지 않는 지점. 실패로 부르면 절차가 영원히 안 끝난다.
        #expect(BatteryCalibration.decide(input(step: .dischargeToFloor, timers: timers, soc: 24))
            == .advance(to: .soakLow, primitive: .holdAtFloor))
    }

    @Test func soakStepsAdvanceOnTheirOwnClock() {
        var timers = CalibrationTimers()
        timers.stepActiveSeconds = BatteryCalibration.soakLowSeconds - 1
        #expect(BatteryCalibration.decide(input(step: .soakLow, timers: timers, soc: 20))
            == .hold(.holdAtFloor))
        timers.stepActiveSeconds = BatteryCalibration.soakLowSeconds
        #expect(BatteryCalibration.decide(input(step: .soakLow, timers: timers, soc: 20))
            == .advance(to: .rechargeToFull, primitive: .chargeToFull))

        timers.stepActiveSeconds = BatteryCalibration.soakFinalSeconds
        #expect(BatteryCalibration.decide(input(step: .soakFinal, timers: timers, soc: 100))
            == .advance(to: .restoring, primitive: .restore))
    }

    @Test func restoringFinishesTheRun() {
        #expect(BatteryCalibration.decide(input(step: .restoring))
            == .finish(.completed, failure: nil))
    }

    // MARK: 일시정지

    @Test func sleepPausesWithoutSpendingTheBudget() {
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, isSleepGap: true)) == .pause(.systemSleep))
        #expect(CalibrationPause.systemSleep.consumesBudget == false)
    }

    @Test func chargeStepsPauseWhenTheAdapterIsGoneButDischargeDoesNot() {
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, isAdapterPresent: false))
            == .pause(.needsAdapter))
        #expect(BatteryCalibration.decide(input(step: .soakLow, soc: 20, isAdapterPresent: false))
            == .pause(.needsAdapter))
        // 방전 단계는 어댑터가 없어도 자연 방전이 목표에 기여한다.
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, soc: 50, isAdapterPresent: false))
            == .hold(.dischargeToFloor))
    }

    @Test func heatProtectionPausesAndIsNeverDisabled() {
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, isHeatProtected: true))
            == .pause(.heatProtection))
    }

    @Test func missingHelperPauses() {
        #expect(BatteryCalibration.decide(input(step: .soakFinal, helperReady: false))
            == .pause(.helperUnavailable))
    }

    @Test func sustainedChargeStallPausesWithAnActionableReason() {
        var timers = CalibrationTimers()
        timers.chargeStalledSeconds = BatteryCalibration.chargeStallSeconds
        #expect(BatteryCalibration.decide(
            input(step: .chargeToFull, timers: timers, soc: 80, isChargeStalled: true))
            == .pause(.externalChargeBlock))
        // 방전 단계에는 이 판정이 적용되지 않는다.
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, timers: timers, soc: 50, isChargeStalled: true))
            == .hold(.dischargeToFloor))
    }

    // MARK: 종료

    @Test func twelveHoursWithoutProgressCancelsQuietly() {
        // 실패가 아니라 조용한 취소다 — 뚜껑을 밤새 닫아둔 사용자를 실패로 부를 이유가 없다.
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor,
                  secondsSinceProgress: BatteryCalibration.staleAbandonSeconds))
            == .finish(.expired, failure: nil))
    }

    @Test func exhaustedPauseBudgetFails() {
        var timers = CalibrationTimers()
        timers.pausedTotalSeconds = BatteryCalibration.pauseBudgetSeconds
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, timers: timers))
            == .finish(.failed, failure: .pauseBudgetExhausted))
    }

    @Test func stepTimeoutsFail() {
        var timers = CalibrationTimers()
        timers.stepActiveSeconds = BatteryCalibration.chargePhaseTimeout
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, timers: timers, soc: 80))
            == .finish(.failed, failure: .stepTimeout))

        timers.stepActiveSeconds = BatteryCalibration.dischargePhaseTimeout
        #expect(BatteryCalibration.decide(input(step: .dischargeToFloor, timers: timers, soc: 50))
            == .finish(.failed, failure: .stepTimeout))

        // 안정화 단계는 시간이 곧 완료 조건이라 타임아웃이 없다.
        #expect(BatteryCalibration.stepTimeout(for: .soakLow) == nil)
        #expect(BatteryCalibration.stepTimeout(for: .soakFinal) == nil)
    }

    @Test func lostDischargeHardwareFails() {
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, dischargeSupported: false))
            == .finish(.failed, failure: .dischargeUnsupported))
    }

    // MARK: 우선순위

    @Test func expiryOutranksEverythingAndSleepOutranksPauses() {
        // 12시간 무진행은 잠자기·열보호보다 먼저 판정된다.
        #expect(BatteryCalibration.decide(
            input(step: .chargeToFull, isHeatProtected: true, isSleepGap: true,
                  secondsSinceProgress: BatteryCalibration.staleAbandonSeconds))
            == .finish(.expired, failure: nil))
        // 잠자기는 예산을 쓰는 일시정지들보다 먼저 판정된다 — 그래야 예산이 보호된다.
        #expect(BatteryCalibration.decide(
            input(step: .chargeToFull, isAdapterPresent: false,
                  isHeatProtected: true, isSleepGap: true))
            == .pause(.systemSleep))
    }
}
