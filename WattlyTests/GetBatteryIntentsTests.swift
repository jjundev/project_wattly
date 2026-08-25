import Testing
import AppIntents
import Foundation
@testable import Wattly

@Suite struct GetBatteryIntentsTests {
    @Test func getBatteryStatusIntentMetadata() {
        #expect(GetBatteryStatusIntent.title == "배터리 상태 가져오기")
    }

    @Test func getBatteryLimitIntentMetadata() {
        #expect(GetBatteryLimitIntent.title == "충전 제한 설정 가져오기")
    }

    @Test func getBatteryStatusIntentPerformsAndReturnsResult() async throws {
        let intent = GetBatteryStatusIntent()
        let result = try await intent.perform()
        guard let state = result.value else {
            Issue.record("Expected non-nil BatteryStateEntity result")
            return
        }
        #expect(state.percentage >= 0)
    }

    @Test func getBatteryLimitIntentPerformsWithCustomUserDefaults() async throws {
        let defaults = UserDefaults.standard
        let prevEnabled = defaults.object(forKey: StorageKey.batteryLimitEnabled)
        let prevLimit = defaults.object(forKey: StorageKey.batteryLimitPercentage)
        defer {
            defaults.set(prevEnabled, forKey: StorageKey.batteryLimitEnabled)
            defaults.set(prevLimit, forKey: StorageKey.batteryLimitPercentage)
        }

        // Test enabled limit
        defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(75, forKey: StorageKey.batteryLimitPercentage)

        let intent = GetBatteryLimitIntent()
        let result = try await intent.perform()
        guard let config = result.value else {
            Issue.record("Expected non-nil BatteryLimitConfigEntity result")
            return
        }
        #expect(config.isEnabled == true)
        #expect(config.limitPercentage == 75)

        // Test disabled limit
        defaults.set(false, forKey: StorageKey.batteryLimitEnabled)
        let resultDisabled = try await intent.perform()
        guard let configDisabled = resultDisabled.value else {
            Issue.record("Expected non-nil BatteryLimitConfigEntity result")
            return
        }
        #expect(configDisabled.isEnabled == false)
    }
}
