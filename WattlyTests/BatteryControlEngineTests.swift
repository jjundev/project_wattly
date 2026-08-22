import Foundation
import Testing
@testable import Wattly

final class MockBatteryHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    var isAppleSilicon: Bool = true
    var chargingInhibited: Bool = false
    var appliedLimit: Int = 100
    /// Counts EVERY call, including a redundant one — a retry has to be visible to the tests.
    var writeCount: Int = 0
    var writeShouldFail: Bool = false

    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
        writeCount += 1
        if writeShouldFail { return false }
        chargingInhibited = inhibited
        appliedLimit = targetLimit
        return true
    }
}

struct BatteryControlEngineTests {
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

    @Test func intelMacReceivesCustomTargetLimit() {
        let mockHW = MockBatteryHardware()
        mockHW.isAppleSilicon = false
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
}
