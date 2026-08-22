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
}
