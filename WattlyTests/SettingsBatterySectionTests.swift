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

    @Test func batteryLimitPercentageCanBePersisted() {
        let defaults = UserDefaults(suiteName: "SettingsBatterySectionTests")!
        let presets = [80, 85, 90, 95]
        for preset in presets {
            defaults.set(preset, forKey: StorageKey.batteryLimitPercentage)
            #expect(defaults.integer(forKey: StorageKey.batteryLimitPercentage) == preset)
        }
    }
}
