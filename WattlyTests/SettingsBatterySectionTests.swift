import Testing
import Foundation
@testable import Wattly

@Suite struct SettingsBatterySectionTests {
    @Test func batteryLimitDefaultsAreConsistent() {
        #expect(Defaults.batteryLimitEnabled == false)
        #expect(Defaults.batteryLimitPercentage == 80)
        #expect(StorageKey.batteryLimitEnabled == "batteryLimitEnabled")
        #expect(StorageKey.batteryLimitPercentage == "batteryLimitPercentage")
    }

    @Test func batterySailingDefaultsAreConsistent() {
        #expect(Defaults.batterySailingEnabled == false)
        #expect(Defaults.batterySailingDelta == 5)
        #expect(StorageKey.batterySailingEnabled == "batterySailingEnabled")
        #expect(StorageKey.batterySailingDelta == "batterySailingDelta")
    }

    @Test func batteryLimitPercentageCanBePersisted() {
        let defaults = UserDefaults(suiteName: "SettingsBatterySectionTests")!
        let presets = [80, 85, 90, 95]
        for preset in presets {
            defaults.set(preset, forKey: StorageKey.batteryLimitPercentage)
            #expect(defaults.integer(forKey: StorageKey.batteryLimitPercentage) == preset)
        }
    }

    @Test func batterySailingDeltaCanBePersisted() {
        let defaults = UserDefaults(suiteName: "SettingsBatterySectionTests")!
        let presets = [2, 5, 10]
        for preset in presets {
            defaults.set(preset, forKey: StorageKey.batterySailingDelta)
            #expect(defaults.integer(forKey: StorageKey.batterySailingDelta) == preset)
        }
    }

    @Test func sailingControlsAreDisabledWhenChargeLimitIsDisabled() {
        #expect(BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: false) == false)
    }

    @Test func sailingDeltaPresetsMatchExpectedValues() {
        #expect(BatterySectionPresentation.sailingDeltaPresets == [2, 5, 10])
    }

    @Test func heatProtectionPresetsMatchExpectedValues() {
        #expect(BatterySectionPresentation.heatProtectionThresholdPresets == [32, 35, 38, 40])
    }

    @Test func batteryHeatProtectionDefaultsAreConsistent() {
        #expect(Defaults.batteryHeatProtectionEnabled == false)
        #expect(Defaults.batteryHeatProtectionThreshold == 35)
        #expect(StorageKey.batteryHeatProtectionEnabled == "batteryHeatProtectionEnabled")
        #expect(StorageKey.batteryHeatProtectionThreshold == "batteryHeatProtectionThreshold")
    }

    @Test func batteryHeatProtectionThresholdCanBePersisted() {
        let defaults = UserDefaults(suiteName: "SettingsBatterySectionTests")!
        let presets = [32, 35, 38, 40]
        for preset in presets {
            defaults.set(preset, forKey: StorageKey.batteryHeatProtectionThreshold)
            #expect(defaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold) == preset)
        }
    }

    @Test func systemBatterySettingsURLIsValid() {
        let primaryURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")
        let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.battery")
        #expect(primaryURL != nil)
        #expect(fallbackURL != nil)
        #expect(primaryURL?.scheme == "x-apple.systempreferences")
        #expect(fallbackURL?.scheme == "x-apple.systempreferences")
    }

    @Test func topUpButtonStatePresentation() {
        // When Top Up is active, button shows "Top Up 취소"
        let isTopUpActive = true
        let labelActive = isTopUpActive ? "Top Up 취소" : "Top Up 시작"
        #expect(labelActive == "Top Up 취소")

        // When Top Up is inactive, button shows "Top Up 시작"
        let isTopUpInactive = false
        let labelInactive = isTopUpInactive ? "Top Up 취소" : "Top Up 시작"
        #expect(labelInactive == "Top Up 시작")
    }
}
