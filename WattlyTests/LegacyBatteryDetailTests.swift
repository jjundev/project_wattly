import Testing
import Foundation
@testable import Wattly

/// 설치된 도우미는 앱과 따로 갱신된다 — 앱이 이미 응답하는 도우미를 교체하지 않기 때문이다.
/// 그래서 업데이트한 앱은 한동안 구버전 데몬의 한국어 문장만 받는다. 이 표는 그 문장들을
/// 되돌려 읽어서, 구버전 도우미를 쓰는 사용자도 자기 언어로 상태를 보게 한다.
@Suite struct LegacyBatteryDetailTests {

    @Test func recognizesEveryFixedSentence() {
        let table: [(String, BatteryControlStatusReason.Kind)] = [
            ("초기화 중", .initializing),
            ("전원 소스를 읽을 수 없습니다", .powerSourceUnreadable),
            ("이 Mac은 충전 제어를 지원하지 않습니다", .hardwareUnsupported),
            ("충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)", .releaseFailed),
            ("이 Mac에서 충전 제어를 적용하지 못했습니다", .applyFailed),
            ("충전 제한 비활성화됨", .limitDisabled),
            ("배터리 전원으로 구동 중", .onBatteryPower)
        ]
        for (sentence, kind) in table {
            let parsed = LegacyBatteryDetail.reason(from: sentence)
            #expect(parsed?.kind == kind, "\(sentence)")
            #expect(parsed?.limitPercentage == nil, "\(sentence)")
        }
    }

    /// 보간된 두 문장은 카탈로그 조회로는 절대 잡히지 않는다 — 이 파서만이 유일한 경로다.
    @Test func extractsTheLimitFromTheInterpolatedSentences() {
        for limit in [50, 80, 85, 100] {
            let inhibited = LegacyBatteryDetail.reason(
                from: "충전 제한 \(limit)% 도달 (전원 어댑터 바이패스 구동)")
            #expect(inhibited?.kind == .inhibitedAtLimit, "\(limit)")
            #expect(inhibited?.limitPercentage == limit, "\(limit)")

            let charging = LegacyBatteryDetail.reason(from: "목표치(\(limit)%)까지 충전 중")
            #expect(charging?.kind == .chargingToTarget, "\(limit)")
            #expect(charging?.limitPercentage == limit, "\(limit)")
        }
    }

    /// XPC 오류 설명처럼 도우미가 만든 게 아닌 문자열은 그대로 통과해야 한다 —
    /// 억지로 어떤 상태로 우겨넣으면 진짜 오류가 숨는다.
    @Test func leavesUnknownTextAlone() {
        #expect(LegacyBatteryDetail.reason(from: "Couldn't communicate with a helper application.") == nil)
        #expect(LegacyBatteryDetail.reason(from: "") == nil)
        #expect(LegacyBatteryDetail.reason(from: "충전 제한") == nil)
        #expect(LegacyBatteryDetail.reason(from: "도우미에 연결되지 않음") == nil)
    }

    @Test func parsesLegacySailingString() {
        let parsed = LegacyBatteryDetail.reason(from: "Sailing 중 (75% 도달 시 충전)")
        #expect(parsed?.kind == .sailing)
        #expect(parsed?.resumePercentage == 75)
        #expect(parsed?.limitPercentage == nil)
    }

    @Test func parsesLegacyHeatProtectionString() {
        let parsedActive = LegacyBatteryDetail.reason(from: "발열 보호 중 (배터리 37.5°C / 34°C 이하 시 재개)")
        #expect(parsedActive?.kind == .heatProtectionActive)
        #expect(parsedActive?.currentTemperatureCelsius == 37.5)
        #expect(parsedActive?.resumeTemperatureCelsius == 34)

        let parsedCooldown = LegacyBatteryDetail.reason(from: "발열 보호 쿨다운 중 (120초 후 충전 재개)")
        #expect(parsedCooldown?.kind == .heatProtectionCooldown)
        #expect(parsedCooldown?.cooldownRemainingSeconds == 120)

        let parsedUnreadable = LegacyBatteryDetail.reason(from: "배터리 온도 센서를 읽을 수 없습니다")
        #expect(parsedUnreadable?.kind == .batterySensorUnreadable)
    }

    /// 껍데기는 맞는데 가운데가 숫자가 아닌 경우. nil을 돌려 원문을 그대로 보여줘야 한다.
    @Test func rejectsAMalformedLimit() {
        #expect(LegacyBatteryDetail.reason(from: "충전 제한 팔십% 도달 (전원 어댑터 바이패스 구동)") == nil)
        #expect(LegacyBatteryDetail.reason(from: "목표치(%)까지 충전 중") == nil)
        #expect(LegacyBatteryDetail.reason(from: "충전 제한 % 도달 (전원 어댑터 바이패스 구동)") == nil)
        #expect(LegacyBatteryDetail.reason(from: "Sailing 중 (% 도달 시 충전)") == nil)
        #expect(LegacyBatteryDetail.reason(from: "Sailing 중 (칠십오% 도달 시 충전)") == nil)
    }

    /// 현재 데몬이 내보내는 모든 문장을 이 파서가 알아봐야 한다. 이 어서션은 두 표가
    /// **오늘** 일치함을 보장할 뿐, 하나로 합쳐도 된다는 뜻이 아니다 —
    /// 파일 주석과 `BatteryControlStatusReason.legacyKoreanDetail`의 설명을 읽을 것.
    @Test func coversEveryReasonTheCurrentDaemonEmits() {
        for kind in BatteryControlStatusReason.Kind.allCases where kind != .unrecognized {
            let sentence = BatteryControlStatusReason(kind: kind, limitPercentage: 80).legacyKoreanDetail
            #expect(LegacyBatteryDetail.reason(from: sentence)?.kind == kind, "\(kind): \(sentence)")
        }
    }
}
