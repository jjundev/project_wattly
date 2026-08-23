import Foundation
import Testing
@testable import Wattly

final class MockBatteryHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    var registerSet: BatteryControlRegisterSet = .modern
    var reportedGate: BatteryHardwareGate = .allowed
    var chargingInhibited: Bool = false
    var appliedLimit: Int = 100
    /// Counts EVERY call, including a redundant one — a retry has to be visible to the tests.
    var writeCount: Int = 0
    var readCount: Int = 0
    var writeShouldFail: Bool = false
    var onWrite: (() -> Void)?
    var holdReportedGateAfterWrite = false
    var releaseVerdict: BatteryReleaseVerdict = .verifiedAllowed
    var releaseAttemptCount = 0

    func readChargingGate(targetLimit: Int) -> BatteryHardwareGate {
        readCount += 1
        return reportedGate
    }

    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
        writeCount += 1
        onWrite?()
        if writeShouldFail { return false }
        chargingInhibited = inhibited
        appliedLimit = targetLimit
        if !holdReportedGateAfterWrite {
            reportedGate = inhibited
                ? .inhibited(appliedLimitPercentage:
                    registerSet == .intel ? targetLimit : nil)
                : .allowed
        }
        return true
    }

    func releaseChargingControlAndVerify() -> BatteryReleaseVerdict {
        releaseAttemptCount += 1
        if releaseVerdict.isSafeToRemove {
            chargingInhibited = false
            appliedLimit = 100
            reportedGate = releaseVerdict == .verifiedAllowed ? .allowed : .unreadable
        }
        return releaseVerdict
    }
}

struct BatteryControlEngineTests {
    @Test func wakeHydratesAnExistingHoldAndKeepsItInsideTheBand() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let engine = BatteryControlEngine(
            hardware: hardware,
            initialConfig: .init(
                enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2))

        let status = engine.verifyAndUpdate(currentSoC: 84, isPluggedIn: true)

        #expect(status.mode == .inhibited)
        #expect(hardware.writeCount == 0)
        #expect(status.actualGate == .inhibited(appliedLimitPercentage: nil))
    }

    @Test func wakeHydratesAllowedGateAndDoesNotInventAHoldInsideTheBand() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .allowed
        let engine = BatteryControlEngine(
            hardware: hardware,
            initialConfig: .init(
                enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2))

        let status = engine.verifyAndUpdate(currentSoC: 84, isPluggedIn: true)

        #expect(status.mode == .charging)
        #expect(hardware.writeCount == 0)
    }

    @Test func unreadableGateBuildsAKnownAllowedBaselineBeforeEvaluation() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .unreadable
        let engine = BatteryControlEngine(
            hardware: hardware,
            initialConfig: .init(enabled: true, limitPercentage: 85))

        _ = engine.verifyAndUpdate(currentSoC: 80, isPluggedIn: true)

        #expect(hardware.writeCount == 1)
        #expect(hardware.readCount == 2)
        #expect(hardware.chargingInhibited == false)
    }

    @Test func verifiedReleaseReturnsFailedWhenReadbackStillSaysInhibited() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.releaseVerdict = .failed
        let engine = BatteryControlEngine(hardware: hardware)

        #expect(engine.releaseVerified() == .failed)
        #expect(hardware.releaseAttemptCount == 1)
    }

    @Test func verifiedAllowedReleaseLeavesAKnownAllowedState() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let engine = BatteryControlEngine(hardware: hardware)

        #expect(engine.releaseVerified() == .verifiedAllowed)
        let status = engine.update(currentSoC: 80, isPluggedIn: true)

        #expect(hardware.releaseAttemptCount == 1)
        #expect(hardware.writeCount == 0)
        #expect(status.actualGate == .allowed)
    }

    @Test func notControllableReleaseIsSafeWithoutInventingReadableHardware() {
        let hardware = MockBatteryHardware()
        hardware.registerSet = .unsupported
        hardware.reportedGate = .unreadable
        hardware.releaseVerdict = .notControllable
        let engine = BatteryControlEngine(hardware: hardware)

        #expect(engine.releaseVerified() == .notControllable)
        let status = engine.update(currentSoC: 80, isPluggedIn: true)

        #expect(hardware.releaseAttemptCount == 1)
        #expect(hardware.writeCount == 0)
        #expect(status.actualGate == .unreadable)
    }

    @Test func staleIntelLimitIsReleasedBeforeEvaluatingTheCurrentPolicy() {
        let hardware = MockBatteryHardware()
        hardware.registerSet = .intel
        hardware.reportedGate = .inhibited(appliedLimitPercentage: 80)
        hardware.chargingInhibited = true
        hardware.appliedLimit = 80
        let engine = BatteryControlEngine(
            hardware: hardware,
            initialConfig: .init(enabled: true, limitPercentage: 85))

        let status = engine.verifyAndUpdate(currentSoC: 84, isPluggedIn: true)

        #expect(hardware.writeCount == 1)
        #expect(hardware.readCount == 2)
        #expect(hardware.chargingInhibited == false)
        #expect(hardware.appliedLimit == 100)
        #expect(status.mode == .charging)
        #expect(status.actualGate == .allowed)
    }

    @Test func unreadableGateReportsReadbackFailureWhenReleaseCannotBeVerified() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .unreadable
        hardware.holdReportedGateAfterWrite = true
        hardware.onWrite = {
            #expect(hardware.readCount == 1)
        }
        let engine = BatteryControlEngine(
            hardware: hardware,
            initialConfig: .init(enabled: true, limitPercentage: 85))

        let status = engine.verifyAndUpdate(currentSoC: 80, isPluggedIn: true)

        #expect(hardware.writeCount == 1)
        #expect(hardware.readCount == 2)
        #expect(status.mode == .unsupported)
        #expect(status.appliedLimitPercentage == nil)
        #expect(status.detailReason?.kind == .hardwareReadbackFailed)
        #expect(status.actualGate == .unreadable)
    }

    @Test func acknowledgedTransitionRequiresMatchingReadback() {
        let hardware = MockBatteryHardware()
        let engine = BatteryControlEngine(
            hardware: hardware,
            initialConfig: .init(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 70, isPluggedIn: true)
        hardware.holdReportedGateAfterWrite = true
        hardware.reportedGate = .allowed

        let status = engine.update(currentSoC: 85, isPluggedIn: true)

        #expect(status.mode == .unsupported)
        #expect(status.appliedLimitPercentage == nil)
        #expect(status.actualGate == .allowed)
    }

    @Test func ordinaryWritesAndVerifiedReleaseShareOneThreeFailureLatch() {
        let hardware = MockBatteryHardware()
        let engine = BatteryControlEngine(
            hardware: hardware,
            initialConfig: .init(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 70, isPluggedIn: true)
        hardware.writeCount = 0
        hardware.readCount = 0
        hardware.holdReportedGateAfterWrite = true
        hardware.reportedGate = .allowed

        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        hardware.releaseVerdict = .failed
        #expect(engine.releaseVerified() == .failed)

        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(engine.releaseVerified() == .failed)
        #expect(hardware.writeCount == 2)
        #expect(hardware.releaseAttemptCount == 1)
        #expect(hardware.writeCount + hardware.releaseAttemptCount
            == BatteryControlEngine.maxConsecutiveWriteFailures)
    }

    @Test func recoveryWindowRearmsTheSharedFailureLatch() {
        let hardware = MockBatteryHardware()
        hardware.releaseVerdict = .failed
        let engine = BatteryControlEngine(hardware: hardware)
        for _ in 0..<5 { _ = engine.releaseVerified() }
        #expect(hardware.releaseAttemptCount
            == BatteryControlEngine.maxConsecutiveWriteFailures)

        engine.beginRecoveryWindow()
        hardware.releaseVerdict = .verifiedAllowed
        #expect(engine.releaseVerified() == .verifiedAllowed)
        #expect(hardware.releaseAttemptCount
            == BatteryControlEngine.maxConsecutiveWriteFailures + 1)
    }

    @Test func configureOnlyUpdatesDesiredStateAndNormalizesIt() {
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .inhibited(appliedLimitPercentage: nil)
        hardware.chargingInhibited = true
        let engine = BatteryControlEngine(
            hardware: hardware,
            initialConfig: .init(enabled: true, limitPercentage: 85))
        _ = engine.hydrateHardwareState()

        engine.configure(.init(
            enabled: false, limitPercentage: 999, lowerHysteresisDelta: 999))

        #expect(hardware.writeCount == 0)
        #expect(hardware.chargingInhibited)
        #expect(engine.configuration == .init(
            enabled: false, limitPercentage: 100, lowerHysteresisDelta: 10))
    }

    @Test func statusNeverSynthesizesAnActualGateWithoutARead() {
        let hardware = MockBatteryHardware()
        hardware.registerSet = .unsupported
        let engine = BatteryControlEngine(
            hardware: hardware,
            initialConfig: .init(enabled: true, limitPercentage: 85))

        let status = engine.update(currentSoC: 80, isPluggedIn: true)

        #expect(status.actualGate == nil)
        #expect(status.mode == .unsupported)
    }

    @Test func hysteresisTransitionStopsAtLimitAndResumesBelowThreshold() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2))

        // The first update always normalizes the hardware to a known state, so the baseline is one
        // write, not zero. The point of these counts is that no REDUNDANT write happens inside the
        // hysteresis band.
        // 1. Below limit while plugged in -> Charging allowed
        let s1 = engine.update(currentSoC: 84, isPluggedIn: true)
        #expect(s1.mode == .charging)
        #expect(!mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 1)

        // 2. Reaches limit (85%) -> Inhibits charging (1 write)
        let s2 = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(s2.mode == .inhibited)
        #expect(mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 2)

        // 3. Stays at 84% (within hysteresis band) -> Still inhibited, NO redundant SMC write
        let s3 = engine.update(currentSoC: 84, isPluggedIn: true)
        #expect(s3.mode == .inhibited)
        #expect(mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 2) // write count must NOT increase

        // 4. Drops to 83% (resume threshold: 85 - 2 = 83) -> Re-enables charging (1 write)
        let s4 = engine.update(currentSoC: 83, isPluggedIn: true)
        #expect(s4.mode == .charging)
        #expect(!mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 3)
    }

    @Test func disabledConfigReEnablesCharging() {
        let mockHW = MockBatteryHardware()
        mockHW.chargingInhibited = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))

        let status = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(status.mode == .charging)
        #expect(!mockHW.chargingInhibited)
    }

    @Test func theEngineForwardsTheTargetLimitToTheHardware() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 90))

        _ = engine.update(currentSoC: 90, isPluggedIn: true)
        #expect(mockHW.appliedLimit == 90)
    }

    @Test func releaseRestoresChargingWhenInhibited() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))

        _ = engine.update(currentSoC: 80, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        engine.release()
        #expect(!mockHW.chargingInhibited)
        #expect(mockHW.appliedLimit == 100)
    }

    @Test func unpluggingRestoresChargingState() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))

        _ = engine.update(currentSoC: 80, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        let status = engine.update(currentSoC: 79, isPluggedIn: false)
        #expect(status.mode == .charging)
        #expect(!status.isPowerAdapterConnected)
        #expect(!mockHW.chargingInhibited)
    }

    @Test func failedInhibitWriteReportsUnsupportedAndRetriesUpToTheBound() {
        let mockHW = MockBatteryHardware()
        mockHW.writeShouldFail = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))

        let failed = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(failed.mode == .unsupported)
        #expect(failed.appliedLimitPercentage == nil)   // nothing is actually being enforced
        #expect(!mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 1)

        // The state machine did not advance, so the same branch retries — but only up to the
        // bound, because the global constraint forbids writing SMC registers in a loop.
        for _ in 0..<5 { _ = engine.update(currentSoC: 85, isPluggedIn: true) }
        #expect(mockHW.writeCount == BatteryControlEngine.maxConsecutiveWriteFailures)
    }

    @Test func reconfiguringClearsTheFailureLatchAndLetsItTryAgain() {
        let mockHW = MockBatteryHardware()
        mockHW.writeShouldFail = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        for _ in 0..<5 { _ = engine.update(currentSoC: 85, isPluggedIn: true) }
        #expect(mockHW.writeCount == BatteryControlEngine.maxConsecutiveWriteFailures)

        // This is exactly what the app's 60 s reconcile does once it sees a nil applied limit.
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        mockHW.writeShouldFail = false
        let recovered = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(recovered.mode == .inhibited)
        #expect(recovered.appliedLimitPercentage == 85)
        #expect(mockHW.chargingInhibited)
    }

    @Test func failedReleaseWriteRetriesWithinTheBound() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        mockHW.writeShouldFail = true
        let failed = engine.update(currentSoC: 83, isPluggedIn: true)
        #expect(failed.mode == .unsupported)
        #expect(mockHW.chargingInhibited)   // still latched — the release did not take

        mockHW.writeShouldFail = false
        let recovered = engine.update(currentSoC: 83, isPluggedIn: true)
        #expect(recovered.mode == .charging)
        #expect(!mockHW.chargingInhibited)
    }

    @Test func releaseBypassesTheFailureLatchForDaemonShutdown() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        mockHW.writeShouldFail = true
        for _ in 0..<5 { _ = engine.update(currentSoC: 83, isPluggedIn: true) }
        #expect(mockHW.chargingInhibited)   // release kept failing, then the latch stopped trying

        // Shutdown must still try: leaving the register set would stop the Mac charging with no
        // helper left to ever clear it.
        mockHW.writeShouldFail = false
        engine.release()
        #expect(!mockHW.chargingInhibited)
    }

    @Test func statusCarriesTheLimitTheEngineIsEnforcing() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 90))
        #expect(engine.update(currentSoC: 70, isPluggedIn: true).appliedLimitPercentage == 90)

        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 90))
        #expect(engine.update(currentSoC: 70, isPluggedIn: true).appliedLimitPercentage == nil)
    }

    @Test func configureNormalizesHostileValues() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 999, lowerHysteresisDelta: 900))

        let status = engine.update(currentSoC: 100, isPluggedIn: true)
        #expect(status.appliedLimitPercentage == 100)
        #expect(status.mode == .inhibited)
    }

    @Test func needsSamplingIsFalseOnceIdleAndDisabled() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        #expect(engine.needsSampling)   // startup normalization has not run yet

        _ = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(!engine.needsSampling)  // disabled, hardware already normal — nothing to evaluate

        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        #expect(engine.needsSampling)
    }

    @Test func firstUpdateNormalizesHardwareLeftLatchedByACrashedDaemon() {
        // Feature on, battery below the limit, register still latched from a previous process. No
        // transition would ever fire here, so without the normalization the Mac never charges.
        let mockHW = MockBatteryHardware()
        mockHW.chargingInhibited = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))

        let status = engine.update(currentSoC: 60, isPluggedIn: true)
        #expect(!mockHW.chargingInhibited)
        #expect(status.mode == .charging)
        #expect(mockHW.writeCount == 1)
    }

    @Test func failedStartupNormalizationRetriesUpToTheBound() {
        let mockHW = MockBatteryHardware()
        mockHW.writeShouldFail = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))

        // The state machine stays parked until the hardware is at a known state.
        for _ in 0..<5 { _ = engine.update(currentSoC: 60, isPluggedIn: true) }
        #expect(mockHW.writeCount == BatteryControlEngine.maxConsecutiveWriteFailures)

        // And it recovers when the write finally lands.
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))
        mockHW.writeShouldFail = false
        _ = engine.update(currentSoC: 60, isPluggedIn: true)
        #expect(!mockHW.chargingInhibited)
    }

    @Test func staleFailureClearsOnceNoWriteIsDue() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        // Unplug with a transient failure on the release.
        mockHW.writeShouldFail = true
        #expect(engine.update(currentSoC: 84, isPluggedIn: false).mode == .unsupported)

        // Re-plug above the resume threshold: the limit is working and no write is due, so the
        // engine must stop calling itself unsupported.
        mockHW.writeShouldFail = false
        let healthy = engine.update(currentSoC: 90, isPluggedIn: true)
        #expect(healthy.mode == .inhibited)
        #expect(healthy.appliedLimitPercentage == 85)
    }

    @Test func disablingWhileTheReleaseFailsStaysLoudAboutTheStuckBattery() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        mockHW.writeShouldFail = true
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))
        let stuck = engine.update(currentSoC: 85, isPluggedIn: true)

        // The Mac is not charging and the user asked for the limit OFF — this must not report a
        // quiet, contradictory "disabled" state.
        #expect(mockHW.chargingInhibited)
        #expect(stuck.mode == .unsupported)
        #expect(stuck.detail == "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)")
        #expect(stuck.appliedLimitPercentage == nil)
    }

    @Test func failedInhibitTransitionRetriesOnTheNextTick() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        // Let normalization land first, so the failure below is the transition's, not the gate's.
        _ = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(mockHW.writeCount == 1)

        mockHW.writeShouldFail = true
        let failed = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(failed.mode == .unsupported)
        #expect(!mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 2)

        // The state machine did not advance, so the same transition is re-entered.
        mockHW.writeShouldFail = false
        let recovered = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(recovered.mode == .inhibited)
        #expect(mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 3)
    }

    @Test func anUnconfirmedHardwareStateNeverReportsHealth() {
        // Feature on, battery below the limit, register latched by a crashed daemon, and the
        // normalization write will not land. The engine must stay loud rather than fall through to
        // the state machine on a guess — a nil applied limit is what makes the app re-push.
        let mockHW = MockBatteryHardware()
        mockHW.chargingInhibited = true
        mockHW.writeShouldFail = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))

        for _ in 0..<6 {
            let status = engine.update(currentSoC: 60, isPluggedIn: true)
            #expect(mockHW.chargingInhibited)   // the Mac is not charging while we report this
            #expect(status.mode == .unsupported)
            #expect(status.appliedLimitPercentage == nil)
        }
        #expect(mockHW.writeCount == BatteryControlEngine.maxConsecutiveWriteFailures)

        // A re-push clears the latch and buys another set of attempts.
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        mockHW.writeShouldFail = false
        let recovered = engine.update(currentSoC: 60, isPluggedIn: true)
        #expect(!mockHW.chargingInhibited)
        #expect(recovered.mode == .charging)
        #expect(recovered.appliedLimitPercentage == 85)
    }

    @Test func aParkedEngineWithTheFeatureOffStopsAskingForSamples() {
        // Task 6 gates the daemon's IOPS snapshot on `needsSampling`. A Mac that will never accept
        // the write must not be the one machine that samples forever for no benefit.
        let mockHW = MockBatteryHardware()
        mockHW.writeShouldFail = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))

        for _ in 0..<5 { _ = engine.update(currentSoC: 60, isPluggedIn: true) }
        #expect(mockHW.writeCount == BatteryControlEngine.maxConsecutiveWriteFailures)
        #expect(!engine.needsSampling)

        // A re-push re-arms the write budget and the sampling together.
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))
        #expect(engine.needsSampling)
    }

    @Test func releaseStillWritesWhenTheHardwareStateWasNeverConfirmed() {
        // The crashed-daemon scenario the normalization gate exists for: the register really is
        // latched, the engine knows it does not know, and shutdown is the last chance to clear it.
        let mockHW = MockBatteryHardware()
        mockHW.chargingInhibited = true
        mockHW.writeShouldFail = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        for _ in 0..<5 { _ = engine.update(currentSoC: 60, isPluggedIn: true) }
        #expect(mockHW.chargingInhibited)

        mockHW.writeShouldFail = false
        engine.release()
        #expect(!mockHW.chargingInhibited)
    }

    @Test func aFailedNormalizationStaysQuietWhenTheUserNeverAskedForTheLimit() {
        // The alarm is for work the user asked for. With the limit off, a write that will not land
        // is nothing to alarm them about — and mode and detail must agree on that.
        let mockHW = MockBatteryHardware()
        mockHW.writeShouldFail = true
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))

        let status = engine.update(currentSoC: 60, isPluggedIn: true)
        #expect(status.mode == .charging)
        #expect(status.detail == "충전 제한 비활성화됨")
    }

    @Test func reassertingKeepsAHoldThatTheHysteresisBandStillWants() {
        // The everyday case: charge settled at 84 % under an 85 % limit, lid closed and reopened.
        // The hold must survive — releasing here would recharge to 85 % on every wake.
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 85, isPluggedIn: true)
        _ = engine.update(currentSoC: 84, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 2)   // normalize, then inhibit

        engine.reassertHardwareState()
        let afterWake = engine.update(currentSoC: 84, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)          // still holding, not released
        #expect(afterWake.mode == .inhibited)
        #expect(mockHW.writeCount == 3)            // exactly one re-assert write
    }

    @Test func reassertingRestoresARegisterClearedBehindTheEnginesBack() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 90, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        // Something cleared it while the Mac slept. No status field could reveal this.
        mockHW.chargingInhibited = false
        mockHW.appliedLimit = 100

        engine.reassertHardwareState()
        #expect(mockHW.chargingInhibited)
        #expect(mockHW.appliedLimit == 85)
    }

    @Test func reassertingWritesNothingWhenNoHoldIsActive() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 60, isPluggedIn: true)
        let writesBeforeWake = mockHW.writeCount

        // Nothing but this engine sets the register, so "not inhibiting" cannot silently drift.
        engine.reassertHardwareState()
        #expect(mockHW.writeCount == writesBeforeWake)
    }

    @Test func aFailedReassertParksTheEngineInsteadOfAssumingItWorked() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 90, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        mockHW.writeShouldFail = true
        engine.reassertHardwareState()

        // The register's real state is now unknown, so the engine must stop claiming health.
        let parked = engine.update(currentSoC: 90, isPluggedIn: true)
        #expect(parked.mode == .unsupported)
        #expect(parked.appliedLimitPercentage == nil)
    }

    @Test func reassertingDoesNotPushBackWhenTheUserHasSwitchedTheLimitOff() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 90, isPluggedIn: true)
        #expect(mockHW.chargingInhibited)

        // Disable while the release write keeps failing: the engine still believes it is inhibiting.
        mockHW.writeShouldFail = true
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))
        let writesBeforeWake = mockHW.writeCount

        // A wake here must not push the hardware the wrong way while the release is still pending.
        engine.reassertHardwareState()
        #expect(mockHW.writeCount == writesBeforeWake)
    }

    @Test func hardwareWithNoRegisterIsReportedAsPermanentlyUnsupported() {
        let mockHW = MockBatteryHardware()
        mockHW.registerSet = .unsupported
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))

        let status = engine.update(currentSoC: 90, isPluggedIn: true)
        #expect(status.mode == .unsupported)
        #expect(status.isHardwareSupported == false)
        #expect(status.detail == "이 Mac은 충전 제어를 지원하지 않습니다")
        #expect(status.appliedLimitPercentage == nil)
    }

    @Test func firmwareManagedHardwareIsReportedAsUnsupportedAndNeverWritten() {
        // macOS 27 firmware drives the limit itself. Until that ships and this can be implemented
        // against a released OS, the engine reports the feature as unavailable and touches nothing.
        let mockHW = MockBatteryHardware()
        mockHW.registerSet = .firmwareManaged
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))

        for _ in 0..<6 { _ = engine.update(currentSoC: 90, isPluggedIn: true) }
        let status = engine.update(currentSoC: 90, isPluggedIn: true)

        #expect(mockHW.writeCount == 0)
        #expect(status.mode == .unsupported)
        #expect(status.isHardwareSupported == false)
        #expect(status.appliedLimitPercentage == nil)
        // The daemon must stop taking power-source snapshots for a Mac it will never act on, and the
        // status has to carry the reason code the settings screen renders — same two properties the
        // `.unsupported` tests pin, which is the point: the user-visible consequence is identical.
        #expect(!engine.needsSampling)
        #expect(status.detailReason?.kind == .hardwareUnsupported)
    }

    @Test func unsupportedHardwareSpendsNoWriteBudgetAtAll() {
        // "No register" is a permanent fact, not a transient failure. Discovering it three times
        // over would be pure waste, and would report a retryable-looking state.
        let mockHW = MockBatteryHardware()
        mockHW.registerSet = .unsupported
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))

        for _ in 0..<6 { _ = engine.update(currentSoC: 90, isPluggedIn: true) }
        #expect(mockHW.writeCount == 0)
        #expect(!engine.needsSampling)
    }

    @Test func supportedHardwareStillReportsItsCapability() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        #expect(engine.update(currentSoC: 70, isPluggedIn: true).isHardwareSupported == true)
    }

    @Test func unsupportedHardwareSaysSoEvenWithTheLimitOff() {
        // The settings screen has to disable its toggle whether or not the user opted in, so the
        // capability is reported unconditionally rather than folded into the failure path — that
        // path only speaks when the user asked for something. Before this task an unsupported Mac
        // with the limit off reported `.charging` / "충전 제한 비활성화됨".
        let mockHW = MockBatteryHardware()
        mockHW.registerSet = .unsupported
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))

        let status = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(status.mode == .unsupported)
        #expect(status.isHardwareSupported == false)
        #expect(status.detail == "이 Mac은 충전 제어를 지원하지 않습니다")
    }

    @Test func unsupportedHardwareLeavesTheOtherEntryPointsInert() {
        // `update` is not the only way into the hardware. These three read state that the
        // short-circuit now leaves permanently false, so pin what they actually do.
        let mockHW = MockBatteryHardware()
        mockHW.registerSet = .unsupported
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85))
        _ = engine.update(currentSoC: 90, isPluggedIn: true)
        #expect(mockHW.writeCount == 0)

        // Neither of these can act: the engine never came to believe it was inhibiting.
        engine.reassertHardwareState()
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 85))
        #expect(mockHW.writeCount == 0)

        // `release` still spends its one deliberate last-chance attempt. The real hardware turns
        // that into a no-op before any bus traffic, because the register table is empty — but the
        // mock succeeds unconditionally, so the count is what pins the attempt.
        engine.release()
        #expect(mockHW.writeCount == 1)
    }

    /// `detail`과 `detailReason`은 같은 사실의 두 표현이다. 어긋나면 구버전 앱과 신버전 앱이
    /// 서로 다른 이야기를 보게 된다.
    @Test func statusReasonAgreesWithTheKoreanDetail() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        let status = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(status.detailReason?.kind == .chargingToTarget)
        #expect(status.detailReason?.limitPercentage == 80)
        #expect(status.detail == status.detailReason?.legacyKoreanDetail)
    }

    @Test func statusReasonReportsUnsupportedHardware() {
        let mockHW = MockBatteryHardware()
        mockHW.registerSet = .unsupported
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        let status = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(status.detailReason?.kind == .hardwareUnsupported)
        #expect(status.detail == "이 Mac은 충전 제어를 지원하지 않습니다")
    }

    @Test func statusReasonReportsTheDisabledLimit() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: false, limitPercentage: 80))
        let status = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(status.detailReason?.kind == .limitDisabled)
    }

    @Test func statusReasonReportsBatteryPower() {
        // Enabled but unplugged: `!config.enabled` is checked before `isPluggedIn`, so the limit
        // has to be on for this branch to be reachable at all — with it off, `.limitDisabled` wins
        // regardless of plug state.
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        let status = engine.update(currentSoC: 70, isPluggedIn: false)
        #expect(status.detailReason?.kind == .onBatteryPower)
    }

    @Test func normalStatesReportVerifiedBaseActivities() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)

        let inactive = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(inactive.activity == .inactive)

        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        let charging = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(charging.activity == .chargingToLimit)

        let holding = engine.update(currentSoC: 80, isPluggedIn: true)
        #expect(holding.activity == .holdingAtLimit)

        let unplugged = engine.update(currentSoC: 79, isPluggedIn: false)
        #expect(unplugged.activity == .onBatteryPower)
    }

    @Test func failuresAndUnsupportedHardwareDoNotClaimANormalActivity() {
        let unsupportedHardware = MockBatteryHardware()
        unsupportedHardware.registerSet = .unsupported
        let unsupportedEngine = BatteryControlEngine(hardware: unsupportedHardware)
        unsupportedEngine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        #expect(unsupportedEngine.update(currentSoC: 70, isPluggedIn: true).activity == nil)

        let failingHardware = MockBatteryHardware()
        failingHardware.writeShouldFail = true
        let failingEngine = BatteryControlEngine(hardware: failingHardware)
        failingEngine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        #expect(failingEngine.update(currentSoC: 70, isPluggedIn: true).activity == nil)
    }

    @Test func engineReportsSailingStateWhileDischargingWithinHysteresisBand() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 5))

        // 1. Initial plugged in at 79% -> Charging to target
        let s1 = engine.update(currentSoC: 79, isPluggedIn: true)
        #expect(s1.mode == .charging)
        #expect(s1.activity == .chargingToLimit)
        #expect(s1.detailReason?.kind == .chargingToTarget)

        // 2. Reaches limit (80%) -> Inhibited at limit
        let s2 = engine.update(currentSoC: 80, isPluggedIn: true)
        #expect(s2.mode == .inhibited)
        #expect(s2.activity == .holdingAtLimit)
        #expect(s2.detailReason?.kind == .inhibitedAtLimit)
        #expect(s2.detailReason?.limitPercentage == 80)

        // 3. Drops to 79% while still plugged in -> Sailing!
        let s3 = engine.update(currentSoC: 79, isPluggedIn: true)
        #expect(s3.mode == .inhibited)
        #expect(s3.activity == .sailing)
        #expect(s3.detailReason?.kind == .sailing)
        #expect(s3.detailReason?.limitPercentage == 80)
        #expect(s3.detailReason?.resumePercentage == 75)

        // 4. Drops to 76% (above resume 75%) -> Still sailing!
        let s4 = engine.update(currentSoC: 76, isPluggedIn: true)
        #expect(s4.mode == .inhibited)
        #expect(s4.activity == .sailing)
        #expect(s4.detailReason?.kind == .sailing)
        #expect(s4.detailReason?.resumePercentage == 75)

        // 5. Drops to 75% (resume threshold: 80 - 5 = 75) -> Resumes charging to limit
        let s5 = engine.update(currentSoC: 75, isPluggedIn: true)
        #expect(s5.mode == .charging)
        #expect(s5.activity == .chargingToLimit)
        #expect(s5.detailReason?.kind == .chargingToTarget)
    }

    @Test func unpluggingFromSailingStateReportsOnBatteryPower() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 5))

        _ = engine.update(currentSoC: 80, isPluggedIn: true)
        let sSailing = engine.update(currentSoC: 78, isPluggedIn: true)
        #expect(sSailing.activity == .sailing)

        let sUnplugged = engine.update(currentSoC: 78, isPluggedIn: false)
        #expect(sUnplugged.mode == .charging)
        #expect(sUnplugged.activity == .onBatteryPower)
        #expect(sUnplugged.detailReason?.kind == .onBatteryPower)
    }
}
