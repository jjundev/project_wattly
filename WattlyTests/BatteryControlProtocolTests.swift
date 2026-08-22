import Foundation
import Testing
@testable import Wattly

struct BatteryControlProtocolTests {
    @Test func configurationRoundTrips() throws {
        let input = BatteryControlConfiguration(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2)
        let encoded = try BatteryControlCodec.encode(input)
        let decoded = try BatteryControlCodec.decode(BatteryControlConfiguration.self, from: encoded)
        #expect(decoded == input)
    }

    @Test func requestCarriesGeneration() throws {
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2)
        let request = BatteryControlConfigurationRequest(configuration: config, generation: 42)
        let encoded = try BatteryControlCodec.encode(request)
        let decoded = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: encoded)
        #expect(decoded == request)
    }

    @Test func statusRoundTrips() throws {
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "충전 제한 활성화됨 (AC 바이패스 구동 중)",
            updatedAt: 1000.0
        )
        let encoded = try BatteryControlCodec.encode(status)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: encoded)
        #expect(decoded == status)
    }

    @Test func limitPercentageClamping() {
        let lowConfig = BatteryControlConfiguration(enabled: true, limitPercentage: 30)
        #expect(lowConfig.clampedLimitPercentage == 50)
        let highConfig = BatteryControlConfiguration(enabled: true, limitPercentage: 110)
        #expect(highConfig.clampedLimitPercentage == 100)
        #expect(lowConfig.resumePercentage == 48) // 50 - 2 = 48
    }

    @Test func hostileDecodedConfigurationIsNormalizedAndSafeUnnormalized() throws {
        // The synthesized init(from:) bypasses the memberwise initializer, so this is exactly
        // what the root daemon receives over XPC.
        let hostile = Data("""
        {"enabled":true,"limitPercentage":999,"lowerHysteresisDelta":900}
        """.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlConfiguration.self, from: hostile)
        #expect(decoded.limitPercentage == 999)   // raw decode is untouched

        let safe = decoded.normalized
        #expect(safe.limitPercentage == 100)
        #expect(safe.lowerHysteresisDelta == 5)
        #expect(safe.resumePercentage == 95)

        // Even without normalizing, the derived values must stay inside their range.
        #expect(decoded.clampedLimitPercentage == 100)
        #expect(decoded.resumePercentage == 95)
    }

    @Test func normalizationLeavesValidValuesAlone() {
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2)
        #expect(config.normalized == config)
    }

    @Test func statusFromOlderHelperDecodesWithoutAppliedLimit() throws {
        let legacy = Data("""
        {"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0}
        """.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: legacy)
        #expect(decoded.appliedLimitPercentage == nil)
        #expect(decoded.mode == .charging)
        #expect(decoded.currentPercentage == 70)
    }

    @Test func statusRoundTripsAppliedLimit() throws {
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 1000.0,
            appliedLimitPercentage: 85
        )
        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: try BatteryControlCodec.encode(status)
        )
        #expect(decoded == status)
        #expect(decoded.appliedLimitPercentage == 85)
    }
}
