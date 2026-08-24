import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryControlStatusReasonTests {

    @Test func roundTripsThroughJSON() throws {
        let reason = BatteryControlStatusReason(kind: .inhibitedAtLimit, limitPercentage: 80)
        let data = try BatteryControlCodec.encode(reason)
        let decoded = try BatteryControlCodec.decode(BatteryControlStatusReason.self, from: data)
        #expect(decoded == reason)
    }

    @Test func encodesKindAsItsRawToken() throws {
        let data = try BatteryControlCodec.encode(
            BatteryControlStatusReason(kind: .chargingToTarget, limitPercentage: 85))
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"chargingToTarget\""))
        #expect(json.contains("85"))
    }

    /// 새 데몬 + 구버전 앱. 모르는 토큰에서 상태 전체 디코딩이 실패하면, 앱은 배터리 상태를
    /// 아예 못 읽는다 — 문구 하나 때문에 기능이 통째로 죽는 셈이다.
    @Test func unknownKindDecodesAsUnrecognizedRatherThanThrowing() throws {
        let json = Data(#"{"kind":"someFutureState","limitPercentage":90}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlStatusReason.self, from: json)
        #expect(decoded.kind == .unrecognized)
        #expect(decoded.limitPercentage == 90)
    }

    @Test func limitIsOptionalAndAbsentByDefault() throws {
        let json = Data(#"{"kind":"limitDisabled"}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlStatusReason.self, from: json)
        #expect(decoded.kind == .limitDisabled)
        #expect(decoded.limitPercentage == nil)
        #expect(BatteryControlStatusReason(kind: .limitDisabled).limitPercentage == nil)
    }

    /// `kind`가 문자열조차 아닌 경우 (예: 숫자). `Kind`의 관대한 디코딩이 미치지 못하는, 한 단계
    /// 위의 실패 모드다 — 이 필드 하나 때문에 구조체 전체 디코딩이 실패하면 안 된다.
    @Test func garbledKindDecodesAsUnrecognizedRatherThanThrowing() throws {
        let json = Data(#"{"kind":42,"limitPercentage":90}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlStatusReason.self, from: json)
        #expect(decoded.kind == .unrecognized)
        #expect(decoded.limitPercentage == 90)
    }

    /// `limitPercentage`가 정수가 아니라 문자열로 온 경우. 키가 아예 없는 것과 달리, 있는데
    /// 타입이 틀리면 합성된 `Codable`은 예외를 던진다 — 그 예외가 이 필드에서 멈추게 한다.
    @Test func malformedLimitDecodesAsNilRatherThanThrowing() throws {
        let json = Data(#"{"kind":"limitDisabled","limitPercentage":"80"}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlStatusReason.self, from: json)
        #expect(decoded.kind == .limitDisabled)
        #expect(decoded.limitPercentage == nil)
    }

    /// 이 문자열들은 구버전 **앱**이 읽는 값이다. 바꾸면 그 앱의 상태 줄이 깨진다.
    @Test func legacyKoreanDetailMatchesTheShippedWording() {
        #expect(BatteryControlStatusReason(kind: .initializing).legacyKoreanDetail == "초기화 중")
        #expect(BatteryControlStatusReason(kind: .powerSourceUnreadable).legacyKoreanDetail
                == "전원 소스를 읽을 수 없습니다")
        #expect(BatteryControlStatusReason(kind: .hardwareUnsupported).legacyKoreanDetail
                == "이 Mac은 충전 제어를 지원하지 않습니다")
        #expect(BatteryControlStatusReason(kind: .releaseFailed).legacyKoreanDetail
                == "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)")
        #expect(BatteryControlStatusReason(kind: .applyFailed).legacyKoreanDetail
                == "이 Mac에서 충전 제어를 적용하지 못했습니다")
        #expect(BatteryControlStatusReason(kind: .inhibitedAtLimit, limitPercentage: 80).legacyKoreanDetail
                == "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)")
        #expect(BatteryControlStatusReason(kind: .limitDisabled).legacyKoreanDetail == "충전 제한 비활성화됨")
        #expect(BatteryControlStatusReason(kind: .chargingToTarget, limitPercentage: 85).legacyKoreanDetail
                == "목표치(85%)까지 충전 중")
        #expect(BatteryControlStatusReason(kind: .onBatteryPower).legacyKoreanDetail == "배터리 전원으로 구동 중")
    }

    /// 한도가 필요한 종류인데 값이 없는 경우. 크래시도, "nil%"도 안 된다.
    @Test func legacyDetailSurvivesAMissingLimit() {
        #expect(BatteryControlStatusReason(kind: .inhibitedAtLimit).legacyKoreanDetail
                == "충전 제한 100% 도달 (전원 어댑터 바이패스 구동)")
        #expect(BatteryControlStatusReason(kind: .chargingToTarget).legacyKoreanDetail
                == "목표치(100%)까지 충전 중")
    }

    @Test func everyKindHasNonEmptyLegacyCopy() {
        for kind in BatteryControlStatusReason.Kind.allCases where kind != .unrecognized {
            #expect(!BatteryControlStatusReason(kind: kind).legacyKoreanDetail.isEmpty, "\(kind)")
        }
    }

    @Test func sailingReasonEncodesAndDecodesWithResumePercentage() throws {
        let reason = BatteryControlStatusReason(kind: .sailing, limitPercentage: 80, resumePercentage: 75)
        let data = try JSONEncoder().encode(reason)
        let decoded = try JSONDecoder().decode(BatteryControlStatusReason.self, from: data)
        #expect(decoded.kind == .sailing)
        #expect(decoded.limitPercentage == 80)
        #expect(decoded.resumePercentage == 75)
        #expect(decoded.legacyKoreanDetail == "Sailing 중 (75% 도달 시 충전)")
    }

    @Test func heatProtectionStatusReasonsEncodeAndDecode() throws {
        let activeReason = BatteryControlStatusReason(
            kind: .heatProtectionActive,
            currentTemperatureCelsius: 37.5,
            thresholdTemperatureCelsius: 36,
            resumeTemperatureCelsius: 34
        )
        let activeData = try JSONEncoder().encode(activeReason)
        let decodedActive = try JSONDecoder().decode(BatteryControlStatusReason.self, from: activeData)
        #expect(decodedActive.kind == .heatProtectionActive)
        #expect(decodedActive.currentTemperatureCelsius == 37.5)
        #expect(decodedActive.thresholdTemperatureCelsius == 36)
        #expect(decodedActive.resumeTemperatureCelsius == 34)

        let cooldownReason = BatteryControlStatusReason(
            kind: .heatProtectionCooldown,
            currentTemperatureCelsius: 33.2,
            cooldownRemainingSeconds: 120
        )
        let cooldownData = try JSONEncoder().encode(cooldownReason)
        let decodedCooldown = try JSONDecoder().decode(BatteryControlStatusReason.self, from: cooldownData)
        #expect(decodedCooldown.kind == .heatProtectionCooldown)
        #expect(decodedCooldown.currentTemperatureCelsius == 33.2)
        #expect(decodedCooldown.cooldownRemainingSeconds == 120)

        let unreadableReason = BatteryControlStatusReason(kind: .batterySensorUnreadable)
        let unreadableData = try JSONEncoder().encode(unreadableReason)
        let decodedUnreadable = try JSONDecoder().decode(BatteryControlStatusReason.self, from: unreadableData)
        #expect(decodedUnreadable.kind == .batterySensorUnreadable)
    }
}
