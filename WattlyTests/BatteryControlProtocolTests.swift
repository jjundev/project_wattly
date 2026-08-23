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
        #expect(safe.lowerHysteresisDelta == 10)
        #expect(safe.resumePercentage == 90)

        // Even without normalizing, the derived values must stay inside their range.
        #expect(decoded.clampedLimitPercentage == 100)
        #expect(decoded.resumePercentage == 90)
    }

    @Test func deltaClampsUpToTenPercent() {
        let configUnder = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 0)
        #expect(configUnder.normalized.lowerHysteresisDelta == 1)

        let configStandard = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 5)
        #expect(configStandard.normalized.lowerHysteresisDelta == 5)

        let configTen = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 10)
        #expect(configTen.normalized.lowerHysteresisDelta == 10)

        let configOver = BatteryControlConfiguration(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 15)
        #expect(configOver.normalized.lowerHysteresisDelta == 10)
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

    @Test func statusRoundTripsHardwareSupport() throws {
        let status = BatteryControlServiceStatus(
            mode: .unsupported,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "이 Mac은 충전 제어를 지원하지 않습니다",
            updatedAt: 1.0,
            appliedLimitPercentage: nil,
            isHardwareSupported: false
        )
        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: try BatteryControlCodec.encode(status)
        )
        #expect(decoded == status)
        #expect(decoded.isHardwareSupported == false)
    }

    @Test func statusFromOlderHelperLeavesHardwareSupportUnknown() throws {
        // A helper predating this field says nothing about capability, which must decode as nil —
        // "unknown", not "unsupported". The settings screen keys its toggle off exactly this.
        let legacy = Data("""
        {"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0}
        """.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: legacy)
        #expect(decoded.isHardwareSupported == nil)
    }

    /// 구버전 도우미의 페이로드에는 이 필드가 없다. 없다고 디코딩이 실패하면
    /// 업데이트한 앱이 기존 도우미와 대화하지 못한다.
    @Test func statusDecodesWithoutAReason() throws {
        let json = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: json)
        #expect(decoded.detailReason == nil)
        #expect(decoded.detail == "충전 중")
    }

    @Test func statusRoundTripsAReason() throws {
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 80,
            isPowerAdapterConnected: true,
            detail: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 12.0,
            appliedLimitPercentage: 80,
            isHardwareSupported: true,
            detailReason: .init(kind: .inhibitedAtLimit, limitPercentage: 80))
        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self, from: BatteryControlCodec.encode(status))
        #expect(decoded == status)
        #expect(decoded.detailReason?.kind == .inhibitedAtLimit)
        #expect(decoded.detailReason?.limitPercentage == 80)
    }

    /// 새 데몬 + 구버전 앱의 반대 방향: 모르는 종류 하나가 상태 전체를 못 읽게 만들면 안 된다.
    @Test func statusSurvivesAnUnknownReasonKind() throws {
        let json = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0,"detailReason":{"kind":"aFutureKind"}}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: json)
        #expect(decoded.detailReason?.kind == .unrecognized)
        #expect(decoded.currentPercentage == 70)
    }

    @Test func statusFromOlderHelperLeavesActivityUnknown() throws {
        let legacy = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: legacy)
        #expect(decoded.activity == nil)
    }

    @Test func statusRoundTripsAnActivity() throws {
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 80,
            isPowerAdapterConnected: true,
            detail: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 12.0,
            appliedLimitPercentage: 80,
            isHardwareSupported: true,
            detailReason: .init(kind: .inhibitedAtLimit, limitPercentage: 80),
            activity: .holdingAtLimit)

        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: BatteryControlCodec.encode(status))

        #expect(decoded == status)
        #expect(decoded.activity == .holdingAtLimit)
    }

    @Test func statusSurvivesUnknownAndMalformedActivityTokens() throws {
        let future = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0,"activity":"futureActivity"}"#.utf8)
        let malformed = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0,"activity":42}"#.utf8)

        let futureDecoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: future)
        let malformedDecoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: malformed)

        #expect(futureDecoded.activity == .unrecognized)
        #expect(malformedDecoded.activity == .unrecognized)
        #expect(futureDecoded.currentPercentage == 70)
        #expect(malformedDecoded.currentPercentage == 70)
    }

    @Test func persistenceMaintenanceFieldsRoundTrip() throws {
        let desired = BatteryControlConfiguration(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 5)
        let maintenance = BatteryMaintenanceRecord(
            trigger: .wake,
            result: .verified,
            occurredAt: 1234,
            reason: nil)
        let input = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 1234,
            appliedLimitPercentage: 85,
            isHardwareSupported: true,
            detailReason: .init(kind: .inhibitedAtLimit, limitPercentage: 85),
            activity: .holdingAtLimit,
            desiredConfiguration: desired,
            actualGate: .inhibited(appliedLimitPercentage: nil),
            releaseVerdict: .verifiedAllowed,
            lastMaintenance: maintenance,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])

        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: BatteryControlCodec.encode(input))

        #expect(decoded.desiredConfiguration == desired)
        #expect(decoded.actualGate == .inhibited(appliedLimitPercentage: nil))
        #expect(decoded.releaseVerdict == .verifiedAllowed)
        #expect(decoded.lastMaintenance == maintenance)
        #expect(decoded.capabilities == [
            .persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1
        ])
    }

    @Test func currentAppDecodesLegacyHelperStatusWithoutPersistenceFields() throws {
        let legacy = Data(#"""
        {
          "mode":"charging",
          "currentPercentage":70,
          "isPowerAdapterConnected":true,
          "detail":"목표치(80%)까지 충전 중",
          "updatedAt":1
        }
        """#.utf8)

        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self, from: legacy)

        #expect(decoded.desiredConfiguration == nil)
        #expect(decoded.actualGate == nil)
        #expect(decoded.releaseVerdict == nil)
        #expect(decoded.lastMaintenance == nil)
        #expect(decoded.capabilities == nil)
    }

    @Test func unknownCapabilityDoesNotBreakTheWholeStatus() throws {
        let payload = Data(#"""
        {
          "mode":"charging",
          "currentPercentage":70,
          "isPowerAdapterConnected":true,
          "detail":"OK",
          "updatedAt":1,
          "capabilities":["future-capability"]
        }
        """#.utf8)
        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self, from: payload)
        #expect(decoded.capabilities == [.unrecognized])
    }

    @Test func futureSafetyValuesDecodeAsUnrecognizedWithoutBreakingStatus() throws {
        let payload = Data(#"""
        {
          "mode":"charging",
          "currentPercentage":70,
          "isPowerAdapterConnected":true,
          "detail":"OK",
          "updatedAt":1,
          "actualGate":{"state":"future-state"},
          "releaseVerdict":"future-verdict",
          "lastMaintenance":{
            "trigger":"future-trigger",
            "result":"future-result",
            "occurredAt":1
          }
        }
        """#.utf8)

        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self, from: payload)

        #expect(decoded.actualGate?.state == .unrecognized)
        #expect(decoded.releaseVerdict == .unrecognized)
        #expect(decoded.releaseVerdict?.isSafeToRemove == false)
        #expect(decoded.lastMaintenance?.trigger == .unrecognized)
        #expect(decoded.lastMaintenance?.result == .unrecognized)
        #expect(decoded.currentPercentage == 70)
    }
}
