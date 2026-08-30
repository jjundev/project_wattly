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

        // soakFinalSeconds(3600)는 soakLowSeconds(600)도 만족한다 — soakFinal이 실수로
        // soakLowSeconds를 참조해도 이 지점만 확인하면 통과해 버린다. 문턱 바로 아래에서
        // hold를 고정해야 그 구현이 걸린다.
        timers.stepActiveSeconds = BatteryCalibration.soakFinalSeconds - 1
        #expect(BatteryCalibration.decide(input(step: .soakFinal, timers: timers, soc: 100))
            == .hold(.holdAtFull))
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

    @Test func missingHelperOutranksUnsupportedDischarge() {
        // 헬퍼가 죽으면서 하필 방전 지원 여부까지 false를 보고하는 경우, 복구 가능한
        // 일시정지(헬퍼 부재)가 회복 불가능한 실패(방전 미지원)보다 먼저 판정돼야 한다 —
        // 그래야 헬퍼가 돌아왔을 때 절차를 이어갈 수 있다.
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, helperReady: false, dischargeSupported: false))
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

    @Test func exhaustedPauseBudgetFailsEvenWhileAPauseReasonIsStillActive() {
        // 실제 운용 형태: 열보호가 계속 걸려 있는 채로 예산이 다 찼다. 예산 검사가 세 개의
        // `.pause` 판정보다 아래에 있으면 `decide`는 열보호가 풀릴 때까지 절대 이 지점에
        // 도달하지 못한다 — 즉 열보호가 진행 중인 두 시간 내내 `.pause(.heatProtection)`만
        // 돌려주는 회귀가 생긴다. 이 assert가 그 회귀를 잡는다.
        var timers = CalibrationTimers()
        timers.pausedTotalSeconds = BatteryCalibration.pauseBudgetSeconds

        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, timers: timers, isHeatProtected: true))
            == .finish(.failed, failure: .pauseBudgetExhausted))

        #expect(BatteryCalibration.decide(
            input(step: .chargeToFull, timers: timers, isAdapterPresent: false))
            == .finish(.failed, failure: .pauseBudgetExhausted))

        #expect(BatteryCalibration.decide(
            input(step: .chargeToFull, timers: timers, helperReady: false))
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

struct BatteryCalibrationPreflightTests {
    private func blockers(
        helperMode: BatteryControlServiceMode = .charging,
        capabilities: [BatteryControlCapability]? = [.calibrationV1],
        isHardwareSupported: Bool? = true,
        isDischargeHardwareSupported: Bool? = true,
        isAdapterPresent: Bool = true,
        isHeatProtected: Bool = false,
        isTopUpActive: Bool = false,
        isManualDischargeActive: Bool = false,
        hasConfirmedOptimizedChargingOff: Bool = true,
        hasConfirmedDuration: Bool = true
    ) -> [CalibrationBlocker] {
        BatteryCalibration.preflightBlockers(
            helperMode: helperMode, capabilities: capabilities,
            isHardwareSupported: isHardwareSupported,
            isDischargeHardwareSupported: isDischargeHardwareSupported,
            isAdapterPresent: isAdapterPresent, isHeatProtected: isHeatProtected,
            isTopUpActive: isTopUpActive, isManualDischargeActive: isManualDischargeActive,
            hasConfirmedOptimizedChargingOff: hasConfirmedOptimizedChargingOff,
            hasConfirmedDuration: hasConfirmedDuration)
    }

    @Test func aReadyMachineHasNoBlockers() {
        #expect(blockers().isEmpty)
    }

    @Test func anOldHelperBlocksWithItsOwnReason() {
        // 응답은 잘 하지만 캘리브레이션을 모르는 헬퍼. 전역 `requiredCapabilities`를 건드리지
        // 않고 이 카드 안에서만 막는다.
        #expect(blockers(capabilities: [.persistedPolicyV1]) == [.helperTooOld])
        #expect(blockers(capabilities: nil) == [.helperTooOld])
        #expect(blockers(helperMode: .unavailable, capabilities: nil) == [.helperUnavailable])
    }

    @Test func hardwareAndDischargeSupportBlockSeparately() {
        #expect(blockers(isHardwareSupported: false).contains(.hardwareUnsupported))
        #expect(blockers(isDischargeHardwareSupported: false).contains(.dischargeUnsupported))
        // `nil`은 "모름"이라 막지 않는다.
        #expect(blockers(isHardwareSupported: nil, isDischargeHardwareSupported: nil).isEmpty)
    }

    @Test func runtimeConditionsBlock() {
        #expect(blockers(isAdapterPresent: false).contains(.adapterDisconnected))
        #expect(blockers(isHeatProtected: true).contains(.heatProtectionActive))
        #expect(blockers(isTopUpActive: true).contains(.otherActivityRunning))
        #expect(blockers(isManualDischargeActive: true).contains(.otherActivityRunning))
    }

    @Test func acknowledgementsAreBlockersUntilConfirmed() {
        // #25는 안내가 아니라 차단 조건이다 — 실기에서 "최적화된 배터리 충전"이 켜진 채로는
        // 우리가 게이트를 열어도 충전이 아예 시작되지 않았다.
        #expect(blockers(hasConfirmedOptimizedChargingOff: false)
            .contains(.optimizedChargingUnconfirmed))
        #expect(blockers(hasConfirmedDuration: false).contains(.durationUnconfirmed))
    }

    @Test func cooldownIsNinetyDaysOrFortyCycles() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        // 90일 이내 + 사이클 40회 미만 → 쿨다운 안
        #expect(BatteryCalibration.isWithinCooldown(
            lastCompletedAt: now.addingTimeInterval(-30 * 86_400),
            cycleCountAtLastCompletion: 100, currentCycleCount: 110, now: now))
        // 90일 경과 → 쿨다운 밖
        #expect(BatteryCalibration.isWithinCooldown(
            lastCompletedAt: now.addingTimeInterval(-91 * 86_400),
            cycleCountAtLastCompletion: 100, currentCycleCount: 101, now: now) == false)
        // 사이클 40회 → 쿨다운 밖
        #expect(BatteryCalibration.isWithinCooldown(
            lastCompletedAt: now.addingTimeInterval(-30 * 86_400),
            cycleCountAtLastCompletion: 100, currentCycleCount: 140, now: now) == false)
        // 한 번도 안 돌렸으면 쿨다운이 없다
        #expect(BatteryCalibration.isWithinCooldown(
            lastCompletedAt: nil, cycleCountAtLastCompletion: nil,
            currentCycleCount: 110, now: now) == false)
    }
}

struct BatteryCalibrationReportTests {
    @Test func estimateCoversEveryRemainingStep() {
        // 100%에서 시작: 방전 80%p + soakLow 10분 + 재충전 80%p + soakFinal 60분
        let fromDischarge = BatteryCalibration.estimatedRemainingMinutes(
            step: .dischargeToFloor, soc: 100,
            chargeRatePercentPerMinute: 0.73, dischargeRatePercentPerMinute: 0.22)
        let dischargeTime = 80.0 / 0.22
        let rechargeTime = 80.0 / 0.73
        let expected = Int((dischargeTime + 10 + rechargeTime + 60).rounded())
        #expect(fromDischarge == expected)

        // 뒤로 갈수록 남은 시간이 줄어든다.
        #expect(BatteryCalibration.estimatedRemainingMinutes(step: .soakFinal, soc: 100) == 60)
        #expect(BatteryCalibration.estimatedRemainingMinutes(step: .restoring, soc: 100) == 0)
    }

    @Test func estimateGuardsAgainstAbsurdRates() {
        // 0으로 나누지 않는다.
        #expect(BatteryCalibration.estimatedRemainingMinutes(
            step: .chargeToFull, soc: 50,
            chargeRatePercentPerMinute: 0, dischargeRatePercentPerMinute: 0) > 0)
    }

    @Test func headlineNeverPromisesCapacityRecovery() {
        let ko = BatteryCalibration.completionHeadline(locale: Locale(identifier: "ko"))
        #expect(ko == "잔량 표시 보정 완료")
        #expect(ko.contains("회복") == false)
        #expect(ko.contains("수명") == false)
    }

    @Test func capacityNoteAlwaysCarriesTheNaturalDriftBand() {
        let note = BatteryCalibration.capacityNote(
            beginMilliampHours: 6208, endMilliampHours: 6243,
            locale: Locale(identifier: "ko"))
        #expect(note?.contains("6208") == true)
        #expect(note?.contains("6243") == true)
        // 변동폭을 감춘 채 숫자만 보여주면 사용자가 노이즈를 성과로 읽는다.
        #expect(note?.contains("86") == true)
        #expect(BatteryCalibration.capacityNote(
            beginMilliampHours: nil, endMilliampHours: 6243,
            locale: Locale(identifier: "ko")) == nil)
    }
}

struct BatteryCalibrationCopyTests {
    private let ko = Locale(identifier: "ko")

    @Test func everyStepHasALabel() {
        for step in CalibrationStep.allCases {
            #expect(BatteryCalibration.stepLabel(step, locale: ko).isEmpty == false)
        }
    }

    @Test func everyPauseHasAnExplanation() {
        for pause in CalibrationPause.allCases {
            #expect(BatteryCalibration.pauseText(pause, locale: ko).isEmpty == false)
        }
    }

    @Test func everyBlockerHasAnActionableSentence() {
        for blocker in CalibrationBlocker.allCases {
            #expect(BatteryCalibration.blockerText(blocker, locale: ko).isEmpty == false)
        }
    }

    @Test func theDurationConfirmationSpellsOutTheLidRequirement() {
        // #17의 조건이었다: 10.5시간을 감수하는 대신 안내가 솔직해야 한다.
        let text = BatteryCalibration.blockerText(.durationUnconfirmed, locale: ko)
        #expect(text.contains("뚜껑"))
        #expect(text.contains("10"))
    }

    @Test func theOptimizedChargingBlockerNamesTheSettingToTurnOff() {
        let text = BatteryCalibration.blockerText(.optimizedChargingUnconfirmed, locale: ko)
        #expect(text.contains("최적화된 배터리 충전"))
    }

    @Test func summaryLineNamesTheStepAndTheRemainingTime() {
        let line = BatteryCalibration.summaryLine(
            step: .dischargeToFloor, pause: nil, remainingMinutes: 420, locale: ko)
        #expect(line.contains("20%까지 방전"))
        #expect(line.contains("7"))     // 7시간
    }

    @Test func summaryLinePrefersThePauseReason() {
        let line = BatteryCalibration.summaryLine(
            step: .chargeToFull, pause: .needsAdapter, remainingMinutes: 100, locale: ko)
        #expect(line.contains("어댑터"))
    }
}
