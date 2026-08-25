import Testing
import AppIntents
import Foundation
@testable import Wattly

@Suite struct SetBatteryLimitIntentsTests {
    // MARK: - SetBatteryLimitIntent Tests

    @Test func setBatteryLimitIntentMetadata() {
        #expect(SetBatteryLimitIntent.title == "충전 한도 설정")
    }

    @Test func setBatteryLimitIntentInitAndDefaults() {
        let defaultIntent = SetBatteryLimitIntent()
        #expect(defaultIntent.limit == 80)
        #expect(defaultIntent.enableLimit == true)

        let customIntent = SetBatteryLimitIntent(limit: 75, enableLimit: false)
        #expect(customIntent.limit == 75)
        #expect(customIntent.enableLimit == false)

        var mutatingIntent = SetBatteryLimitIntent()
        mutatingIntent.limit = 85
        mutatingIntent.enableLimit = true
        #expect(mutatingIntent.limit == 85)
        #expect(mutatingIntent.enableLimit == true)
    }

    @Test func setBatteryLimitIntentValidationThrowsOnOutOfRangeLimit() async {
        let lowIntent = SetBatteryLimitIntent(limit: 49)
        await #expect(throws: BatteryIntentError.invalidParameter("충전 한도는 50%에서 100% 사이여야 합니다.")) {
            _ = try await lowIntent.perform()
        }

        let highIntent = SetBatteryLimitIntent(limit: 101)
        await #expect(throws: BatteryIntentError.invalidParameter("충전 한도는 50%에서 100% 사이여야 합니다.")) {
            _ = try await highIntent.perform()
        }
    }

    // MARK: - SetBatteryLimitEnabledIntent Tests

    @Test func setBatteryLimitEnabledIntentMetadata() {
        #expect(SetBatteryLimitEnabledIntent.title == "충전 제한 켜기/끄기")
    }

    @Test func setBatteryLimitEnabledIntentInit() {
        let customIntent = SetBatteryLimitEnabledIntent(enabled: true)
        #expect(customIntent.enabled == true)

        let customDisabledIntent = SetBatteryLimitEnabledIntent(enabled: false)
        #expect(customDisabledIntent.enabled == false)

        var mutatingIntent = SetBatteryLimitEnabledIntent()
        mutatingIntent.enabled = true
        #expect(mutatingIntent.enabled == true)
    }

    // MARK: - SetBatterySailingIntent Tests

    @Test func setBatterySailingIntentMetadata() {
        #expect(SetBatterySailingIntent.title == "Sailing 모드 설정")
    }

    @Test func setBatterySailingIntentInitAndDefaults() {
        let customIntent = SetBatterySailingIntent(enabled: true, delta: 8)
        #expect(customIntent.enabled == true)
        #expect(customIntent.delta == 8)

        let customDefaultDeltaIntent = SetBatterySailingIntent(enabled: false)
        #expect(customDefaultDeltaIntent.enabled == false)
        #expect(customDefaultDeltaIntent.delta == 5)

        var mutatingIntent = SetBatterySailingIntent()
        mutatingIntent.enabled = true
        mutatingIntent.delta = 3
        #expect(mutatingIntent.enabled == true)
        #expect(mutatingIntent.delta == 3)
    }

    @Test func setBatterySailingIntentValidationThrowsOnOutOfRangeDelta() async {
        let lowIntent = SetBatterySailingIntent(enabled: true, delta: 0)
        await #expect(throws: BatteryIntentError.invalidParameter("Sailing 범위는 1%에서 10% 사이여야 합니다.")) {
            _ = try await lowIntent.perform()
        }

        let highIntent = SetBatterySailingIntent(enabled: true, delta: 11)
        await #expect(throws: BatteryIntentError.invalidParameter("Sailing 범위는 1%에서 10% 사이여야 합니다.")) {
            _ = try await highIntent.perform()
        }
    }
}
