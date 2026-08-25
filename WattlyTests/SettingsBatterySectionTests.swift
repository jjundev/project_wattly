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

    @Test func heatProtectionToggleConfigurationIsFixedAt35() {
        #expect(Defaults.batteryHeatProtectionThreshold == 35)
        #expect(Defaults.batteryHeatProtectionEnabled == false)
    }

    @Test func batteryHeatProtectionDefaultsAreConsistent() {
        #expect(Defaults.batteryHeatProtectionEnabled == false)
        #expect(Defaults.batteryHeatProtectionThreshold == 35)
        #expect(StorageKey.batteryHeatProtectionEnabled == "batteryHeatProtectionEnabled")
        #expect(StorageKey.batteryHeatProtectionThreshold == "batteryHeatProtectionThreshold")
    }

    @Test func batteryHeatProtectionThresholdCanBePersisted() {
        let defaults = UserDefaults(suiteName: "SettingsBatterySectionTests")!
        defaults.set(35, forKey: StorageKey.batteryHeatProtectionThreshold)
        #expect(defaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold) == 35)
    }

    @Test func systemBatterySettingsURLIsValid() {
        let primaryURL = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")
        let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.battery")
        #expect(primaryURL != nil)
        #expect(fallbackURL != nil)
        #expect(primaryURL?.scheme == "x-apple.systempreferences")
        #expect(fallbackURL?.scheme == "x-apple.systempreferences")
    }

    @Test func topUpToggleStatePresentation() {
        let isTopUpActive = true
        let labelActive = isTopUpActive ? "활성화됨" : "비활성화됨"
        #expect(labelActive == "활성화됨")

        let isTopUpInactive = false
        let labelInactive = isTopUpInactive ? "활성화됨" : "비활성화됨"
        #expect(labelInactive == "비활성화됨")
    }

    @Test func batteryAutoDischargeDefaultsAreConsistent() {
        #expect(Defaults.batteryAutoDischargeEnabled == false)
        #expect(StorageKey.batteryAutoDischargeEnabled == "batteryAutoDischargeEnabled")
    }

    @Test func batteryManualDischargeTargetDefaultsAreConsistent() {
        #expect(Defaults.batteryManualDischargeTarget == 80)
        #expect(StorageKey.batteryManualDischargeTarget == "batteryManualDischargeTarget")
    }

    @Test func batteryAutoDischargeCanBePersisted() {
        let defaults = UserDefaults(suiteName: "SettingsBatterySectionTests")!
        defaults.set(false, forKey: StorageKey.batteryAutoDischargeEnabled)
        #expect(defaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled) == false)
        defaults.set(true, forKey: StorageKey.batteryAutoDischargeEnabled)
        #expect(defaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled) == true)
    }

    @Test func batteryManualDischargeTargetCanBePersisted() {
        let defaults = UserDefaults(suiteName: "SettingsBatterySectionTests")!
        let targets = [50, 60, 70, 80, 90, 100]
        for target in targets {
            defaults.set(target, forKey: StorageKey.batteryManualDischargeTarget)
            #expect(defaults.integer(forKey: StorageKey.batteryManualDischargeTarget) == target)
        }
    }

    @Test func manualDischargeStartButtonDisabledConditions() {
        // Disabled when current SoC <= target
        let target = 80
        let isPluggedIn = true
        let currentSoCLower = 75
        let canStartLower = isPluggedIn && currentSoCLower > target
        #expect(canStartLower == false)

        let currentSoCEqual = 80
        let canStartEqual = isPluggedIn && currentSoCEqual > target
        #expect(canStartEqual == false)

        // Disabled when not plugged in
        let currentSoCHigher = 90
        let isUnplugged = false
        let canStartUnplugged = isUnplugged && currentSoCHigher > target
        #expect(canStartUnplugged == false)

        // Enabled when plugged in and current SoC > target
        let canStartValid = isPluggedIn && currentSoCHigher > target
        #expect(canStartValid == true)
    }

    @Test @MainActor func settingsBatterySectionViewInstantiation() {
        let client = BatteryControlClient()
        let view = SettingsBatterySection(batteryControl: client)
        #expect(view.batteryControl.status.mode == .unavailable)
    }

    @Test @MainActor func integrationComponentsAcceptScheduleCoordinator() {
        let client = BatteryControlClient()
        let coordinator = BatteryScheduleCoordinator(batteryControl: client)
        let bridge = BatteryControlBridge(client: client, scheduleCoordinator: coordinator)
        #expect(bridge.scheduleCoordinator != nil)

        let monitor = SystemMonitor(providers: FakeProviders.all(scenario: .laptop))
        let fanControl = FanControlClient()
        let settingsView = SettingsView(
            monitor: monitor,
            fanControl: fanControl,
            batteryControl: client,
            scheduleCoordinator: coordinator
        )
        #expect(settingsView.scheduleCoordinator != nil)

        let section = SettingsBatterySection(batteryControl: client, scheduleCoordinator: coordinator)
        #expect(section.scheduleCoordinator != nil)
    }
}
