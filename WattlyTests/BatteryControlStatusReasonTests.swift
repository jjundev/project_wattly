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
}
