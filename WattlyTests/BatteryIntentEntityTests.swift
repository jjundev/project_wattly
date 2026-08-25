import Testing
import AppIntents
import Foundation
@testable import Wattly

@Suite struct BatteryIntentEntityTests {
    @Test func batteryStateEntityProperties() {
        let entity = BatteryStateEntity(
            percentage: 80,
            isCharging: true,
            isPowerAdapterConnected: true,
            temperatureCelsius: 32.5,
            netWatts: -15.2,
            timeRemainingMinutes: 120,
            healthPercentage: 98
        )

        #expect(entity.percentage == 80)
        #expect(entity.isCharging == true)
        #expect(entity.isPowerAdapterConnected == true)
        #expect(entity.temperatureCelsius == 32.5)
        #expect(entity.netWatts == -15.2)
        #expect(entity.timeRemainingMinutes == 120)
        #expect(entity.healthPercentage == 98)
    }

    @Test func batteryLimitConfigEntityProperties() {
        let entity = BatteryLimitConfigEntity(
            isEnabled: true,
            limitPercentage: 80,
            isSailingEnabled: true,
            sailingDelta: 5,
            isHeatProtectionEnabled: true,
            isTopUpActive: false
        )

        #expect(entity.isEnabled == true)
        #expect(entity.limitPercentage == 80)
        #expect(entity.isSailingEnabled == true)
        #expect(entity.sailingDelta == 5)
        #expect(entity.isHeatProtectionEnabled == true)
        #expect(entity.isTopUpActive == false)
    }

    @Test func batteryIntentErrorLocalizationKeys() {
        let notInstalled = BatteryIntentError.helperNotInstalled
        let unsupported = BatteryIntentError.hardwareUnsupported
        let xpcFailed = BatteryIntentError.xpcCommunicationFailed("Timeout")
        let invalidParam = BatteryIntentError.invalidParameter("Out of range")

        #expect(notInstalled.errorDescription != nil)
        #expect(unsupported.errorDescription != nil)
        #expect(xpcFailed.errorDescription != nil)
        #expect(invalidParam.errorDescription != nil)
    }
}
