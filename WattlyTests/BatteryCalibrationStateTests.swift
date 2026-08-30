import Foundation
import Testing
@testable import Wattly

struct BatteryCalibrationStateTests {
    @Test func stepChainVisitsEveryStepExactlyOnce() {
        var visited: [CalibrationStep] = []
        var cursor: CalibrationStep? = .preflight
        while let step = cursor {
            visited.append(step)
            cursor = step.next
        }
        #expect(visited == [.preflight, .chargeToFull, .dischargeToFloor,
                            .soakLow, .rechargeToFull, .soakFinal, .restoring])
        #expect(visited.count == CalibrationStep.allCases.count)
        #expect(CalibrationStep.restoring.next == nil)
    }

    @Test func stepsMapToTheirDaemonPrimitive() {
        #expect(CalibrationStep.preflight.primitive == .idle)
        #expect(CalibrationStep.chargeToFull.primitive == .chargeToFull)
        #expect(CalibrationStep.rechargeToFull.primitive == .chargeToFull)
        #expect(CalibrationStep.dischargeToFloor.primitive == .dischargeToFloor)
        #expect(CalibrationStep.soakLow.primitive == .holdAtFloor)
        #expect(CalibrationStep.soakFinal.primitive == .holdAtFull)
        #expect(CalibrationStep.restoring.primitive == .restore)
    }

    @Test func onlySystemSleepIsFreeOfThePauseBudget() {
        #expect(CalibrationPause.systemSleep.consumesBudget == false)
        for pause in CalibrationPause.allCases where pause != .systemSleep {
            #expect(pause.consumesBudget)
        }
    }

    @Test func newStepKeepsOnlyThePauseBudget() {
        var timers = CalibrationTimers()
        timers.stepActiveSeconds = 500
        timers.pausedTotalSeconds = 120
        timers.socUnchangedSeconds = 300
        timers.fullHoldSeconds = 30
        timers.chargeStalledSeconds = 60
        timers.lastSoC = 77

        let reset = timers.resetForNewStep()
        #expect(reset.pausedTotalSeconds == 120)
        #expect(reset.stepActiveSeconds == 0)
        #expect(reset.socUnchangedSeconds == 0)
        #expect(reset.fullHoldSeconds == 0)
        #expect(reset.chargeStalledSeconds == 0)
        #expect(reset.lastSoC == nil)
    }

    @Test func runStateRoundTripsThroughJSON() throws {
        let state = CalibrationRunState(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1000),
            step: .dischargeToFloor,
            timers: CalibrationTimers(),
            pause: .heatProtection,
            snapshot: CalibrationSnapshot(
                limitEnabled: true, limitPercentage: 80,
                sailingEnabled: false, sailingDelta: 5,
                heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
                autoDischargeEnabled: true, manualDischargeTarget: 80),
            beginMaxCapacityMilliampHours: 6208,
            beginCycleCount: 112,
            lastProgressAt: Date(timeIntervalSince1970: 2000),
            lastTickAt: Date(timeIntervalSince1970: 2010),
            appliedPrimitive: .dischargeToFloor)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(CalibrationRunState.self, from: data) == state)
    }

    @Test func historyEntryRoundTripsThroughJSON() throws {
        let entry = CalibrationHistoryEntry(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 37_800),
            outcome: .completed,
            failure: nil,
            beginMaxCapacityMilliampHours: 6208,
            endMaxCapacityMilliampHours: 6243,
            beginCycleCount: 112,
            endCycleCount: 113)
        let data = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(CalibrationHistoryEntry.self, from: data) == entry)
    }
}
