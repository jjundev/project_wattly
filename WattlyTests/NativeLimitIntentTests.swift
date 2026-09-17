import Foundation
import Testing
@testable import Wattly

/// 네이티브 충전 제한 백엔드(macOS 27)에서 단축어가 어떻게 답하는지.
///
/// 세일링과 발열 보호는 이 백엔드가 표현할 수 없다(설정 화면에서도 숨긴다). 그런데 단축어는
/// capability 게이트를 타지 않아서, 예전에는 환경설정만 조용히 바꾸고 "성공"을 돌려줬다 —
/// 사용자 눈에는 켜진 기능이 실제로는 아무 일도 하지 않았다.
@Suite struct NativeLimitIntentTests {
    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "NativeLimitIntentTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func bridge(defaults: UserDefaults) -> BatteryIntentBridge {
        BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { _ in
                let status = BatteryControlServiceStatus(
                    mode: .inhibited,
                    currentPercentage: 80,
                    isPowerAdapterConnected: true,
                    detail: "정상",
                    updatedAt: 100,
                    isHardwareSupported: true,
                    desiredConfiguration: BatteryControlConfiguration(enabled: true, limitPercentage: 80),
                    controlBackend: .nativeLimit)
                return (try? BatteryControlCodec.encode(status), nil)
            })
        })
    }

    @Test func sailingIntentRefusesAndLeavesPreferencesAlone() async throws {
        let defaults = isolatedDefaults()
        let bridge = bridge(defaults: defaults)

        await #expect(throws: BatteryIntentError.hardwareUnsupported) {
            try await bridge.applySailing(enabled: true, delta: 5)
        }
        #expect(defaults.object(forKey: StorageKey.batterySailingEnabled) == nil)
        #expect(defaults.object(forKey: StorageKey.batterySailingDelta) == nil)
    }

    @Test func heatProtectionIntentRefusesAndLeavesPreferencesAlone() async throws {
        let defaults = isolatedDefaults()
        let bridge = bridge(defaults: defaults)

        await #expect(throws: BatteryIntentError.hardwareUnsupported) {
            try await bridge.applyHeatProtection(enabled: true, thresholdCelsius: 40)
        }
        #expect(defaults.object(forKey: StorageKey.batteryHeatProtectionEnabled) == nil)
        #expect(defaults.object(forKey: StorageKey.batteryHeatProtectionThreshold) == nil)
    }

    @Test func limitIntentStillWorksOnTheNativeBackend() async throws {
        let defaults = isolatedDefaults()
        let bridge = bridge(defaults: defaults)

        let status = try await bridge.applyLimit(enabled: true, limitPercentage: 85)
        #expect(status.controlBackend == .nativeLimit)
        #expect(defaults.wattlyBool(StorageKey.batteryLimitEnabled, default: false))
        #expect(defaults.wattlyInt(StorageKey.batteryLimitPercentage, default: 0) == 85)
    }
}
