import Testing
import Foundation
@testable import Wattly

@Suite("HelperHealthStatusTests")
struct HelperHealthStatusTests {
    private let currentUID: UInt32 = 501
    private let requiredCapabilities: [BatteryControlCapability] = [
        .persistedPolicyV1,
        .hardwareGateReadbackV1,
        .systemPowerEventsV1
    ]

    @Test func resolvesNotInstalledWhenPlistOrBinaryMissing() {
        // Plist not installed
        let state1 = HelperHealthStatus.resolve(
            ownership: .notInstalled,
            currentUID: currentUID,
            batteryMode: .unavailable,
            fanMode: .unavailable,
            bundledBinaryExists: true,
            installedBinaryExists: false,
            binaryMatch: nil,
            capabilities: nil
        )
        #expect(state1 == .notInstalled)

        // Plist exists but installed binary missing
        let state2 = HelperHealthStatus.resolve(
            ownership: .owner(currentUID),
            currentUID: currentUID,
            batteryMode: .unavailable,
            fanMode: .unavailable,
            bundledBinaryExists: true,
            installedBinaryExists: false,
            binaryMatch: nil,
            capabilities: nil
        )
        #expect(state2 == .notInstalled)
    }

    @Test func resolvesOwnershipMismatchWhenOwnerUIDDiffers() {
        let otherUID: UInt32 = 502
        let state = HelperHealthStatus.resolve(
            ownership: .owner(otherUID),
            currentUID: currentUID,
            batteryMode: .charging,
            fanMode: .controlling,
            bundledBinaryExists: true,
            installedBinaryExists: true,
            binaryMatch: true,
            capabilities: requiredCapabilities
        )
        #expect(state == .ownershipMismatch(ownerUID: otherUID))
    }

    @Test func resolvesUnavailableWhenProcessNotResponding() {
        let state = HelperHealthStatus.resolve(
            ownership: .owner(currentUID),
            currentUID: currentUID,
            batteryMode: .unavailable,
            fanMode: .unavailable,
            bundledBinaryExists: true,
            installedBinaryExists: true,
            binaryMatch: true,
            capabilities: nil
        )
        #expect(state == .unavailable(detail: "도우미에 연결되지 않음"))
    }

    @Test func resolvesUpdateAvailableWhenCapabilitiesMissing() {
        let state = HelperHealthStatus.resolve(
            ownership: .owner(currentUID),
            currentUID: currentUID,
            batteryMode: .charging,
            fanMode: .controlling,
            bundledBinaryExists: true,
            installedBinaryExists: true,
            binaryMatch: true,
            capabilities: [.persistedPolicyV1] // missing 2 capabilities
        )
        #expect(state == .updateAvailable(reason: "필수 기능(하드웨어 게이트 / 시스템 전원 감지) 업데이트 필요"))
    }

    @Test func resolvesUpdateAvailableWhenBinaryMismatch() {
        let state = HelperHealthStatus.resolve(
            ownership: .owner(currentUID),
            currentUID: currentUID,
            batteryMode: .charging,
            fanMode: .controlling,
            bundledBinaryExists: true,
            installedBinaryExists: true,
            binaryMatch: false, // bundle binary differs from installed
            capabilities: requiredCapabilities
        )
        #expect(state == .updateAvailable(reason: "최신 앱 번들 도우미 바이너리 업데이트 사용 가능"))
    }

    @Test func resolvesRunningWhenAllHealthy() {
        let state = HelperHealthStatus.resolve(
            ownership: .owner(currentUID),
            currentUID: currentUID,
            batteryMode: .charging,
            fanMode: .controlling,
            bundledBinaryExists: true,
            installedBinaryExists: true,
            binaryMatch: true,
            capabilities: requiredCapabilities
        )
        #expect(state == .running)
    }
}
