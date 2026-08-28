import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryControlBridgeTests {

    // MARK: - 순수 설정 빌더

    /// The bug this file exists for: the bridge never read `batteryAutoDischargeEnabled` or
    /// `batteryManualDischargeTarget`, so `BatteryControlConfiguration`'s own defaults (false / 80)
    /// reached the daemon on every reconcile and switched auto-discharge back off once a minute.
    @Test func configurationCarriesEveryStoredPreference() {
        let config = BatteryControlBridge.makeConfiguration(
            enabled: true,
            limitPercentage: 85,
            sailingEnabled: true,
            sailingDelta: 5,
            heatProtectionEnabled: true,
            heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true,
            manualDischargeTarget: 70)

        #expect(config.enabled == true)
        #expect(config.limitPercentage == 85)
        #expect(config.lowerHysteresisDelta == 5)
        #expect(config.heatProtectionEnabled == true)
        #expect(config.heatProtectionThresholdCelsius == 38)
        #expect(config.autoDischargeEnabled == true)
        #expect(config.manualDischargeTarget == 70)
        // Transient daemon-side activity is never asserted by the bridge; `shouldReapply`
        // preserves it from the helper's own status instead.
        #expect(config.topUpActive == false)
        #expect(config.manualDischargeActive == false)
    }

    /// Sailing off means the fixed 2-point hysteresis, regardless of the stored delta.
    @Test func sailingOffUsesTheFixedTwoPointDelta() {
        #expect(BatteryControlBridge.effectiveDelta(sailingEnabled: false, sailingDelta: 5) == 2)
        #expect(BatteryControlBridge.effectiveDelta(sailingEnabled: true, sailingDelta: 5) == 5)

        let config = BatteryControlBridge.makeConfiguration(
            enabled: true,
            limitPercentage: 80,
            sailingEnabled: false,
            sailingDelta: 5,
            heatProtectionEnabled: false,
            heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false,
            manualDischargeTarget: 80)
        #expect(config.lowerHysteresisDelta == 2)
    }

    /// The stored defaults the bridge starts from, pinned so a Defaults edit cannot quietly
    /// re-create the original symptom.
    @Test func bridgeDischargeDefaultsMatchStoredDefaults() {
        #expect(Defaults.batteryAutoDischargeEnabled == false)
        #expect(Defaults.batteryManualDischargeTarget == 80)
        #expect(StorageKey.batteryAutoDischargeEnabled == "batteryAutoDischargeEnabled")
        #expect(StorageKey.batteryManualDischargeTarget == "batteryManualDischargeTarget")
    }
}
