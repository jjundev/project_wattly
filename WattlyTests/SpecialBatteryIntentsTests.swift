import Testing
import AppIntents
import Foundation
@testable import Wattly

@Suite struct SpecialBatteryIntentsTests {
    // MARK: - SetBatteryTopUpIntent Tests

    @Test func setBatteryTopUpIntentMetadata() {
        #expect(SetBatteryTopUpIntent.title == "한 번만 완충 (Top Up)")
    }

    @Test func setBatteryTopUpIntentInitAndDefaults() {
        let defaultIntent = SetBatteryTopUpIntent()
        #expect(defaultIntent.start == true)

        let customIntent = SetBatteryTopUpIntent(start: false)
        #expect(customIntent.start == false)

        var mutatingIntent = SetBatteryTopUpIntent()
        mutatingIntent.start = false
        #expect(mutatingIntent.start == false)
        mutatingIntent.start = true
        #expect(mutatingIntent.start == true)
    }

    // MARK: - SetBatteryHeatProtectionIntent Tests

    @Test func setBatteryHeatProtectionIntentMetadata() {
        #expect(SetBatteryHeatProtectionIntent.title == "발열 보호 설정")
    }

    @Test func setBatteryHeatProtectionIntentInitAndDefaults() {
        let customIntent = SetBatteryHeatProtectionIntent(enabled: true, thresholdCelsius: 38)
        #expect(customIntent.enabled == true)
        #expect(customIntent.thresholdCelsius == 38)

        let customDefaultThresholdIntent = SetBatteryHeatProtectionIntent(enabled: false)
        #expect(customDefaultThresholdIntent.enabled == false)
        #expect(customDefaultThresholdIntent.thresholdCelsius == 35)

        var mutatingIntent = SetBatteryHeatProtectionIntent()
        mutatingIntent.enabled = true
        mutatingIntent.thresholdCelsius = 40
        #expect(mutatingIntent.enabled == true)
        #expect(mutatingIntent.thresholdCelsius == 40)
    }

    @Test func setBatteryHeatProtectionIntentValidationThrowsOnOutOfRangeThreshold() async {
        let lowIntent = SetBatteryHeatProtectionIntent(enabled: true, thresholdCelsius: 29)
        await #expect(throws: BatteryIntentError.invalidParameter("발열 보호 온도는 30°C에서 45°C 사이여야 합니다.")) {
            _ = try await lowIntent.perform()
        }

        let highIntent = SetBatteryHeatProtectionIntent(enabled: true, thresholdCelsius: 46)
        await #expect(throws: BatteryIntentError.invalidParameter("발열 보호 온도는 30°C에서 45°C 사이여야 합니다.")) {
            _ = try await highIntent.perform()
        }
    }
}
