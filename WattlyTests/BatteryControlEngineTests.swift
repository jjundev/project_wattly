import Foundation
import Testing
@testable import Wattly

final class MockBatteryHardware: BatteryControlHardwareProtocol, @unchecked Sendable {
    var isAppleSilicon: Bool = true
    var chargingInhibited: Bool = false
    var appliedLimit: Int = 100
    var writeCount: Int = 0

    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool {
        if chargingInhibited != inhibited || appliedLimit != targetLimit {
            chargingInhibited = inhibited
            appliedLimit = targetLimit
            writeCount += 1
        }
        return true
    }
}

struct BatteryControlEngineTests {
    @Test func hysteresisTransitionStopsAtLimitAndResumesBelowThreshold() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2))

        // 1. Below limit while plugged in -> Charging allowed
        let s1 = engine.update(currentSoC: 84, isPluggedIn: true)
        #expect(s1.mode == .charging)
        #expect(!mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 0)

        // 2. Reaches limit (85%) -> Inhibits charging (1 write)
        let s2 = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(s2.mode == .inhibited)
        #expect(mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 1)

        // 3. Stays at 84% (within hysteresis band) -> Still inhibited, NO redundant SMC write
        let s3 = engine.update(currentSoC: 84, isPluggedIn: true)
        #expect(s3.mode == .inhibited)
        #expect(mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 1) // write count must NOT increase

        // 4. Drops to 83% (resume threshold: 85 - 2 = 83) -> Re-enables charging (1 write)
        let s4 = engine.update(currentSoC: 83, isPluggedIn: true)
        #expect(s4.mode == .charging)
        #expect(!mockHW.chargingInhibited)
        #expect(mockHW.writeCount == 2)
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
}
