import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryStatusTextTests {
    private let en = Locale(identifier: "en")
    private let ja = Locale(identifier: "ja")
    private let ko = Locale(identifier: "ko")

    // MARK: - 어느 출처를 믿을지

    @Test func structuredReasonWinsOverTheSentence() {
        // 데몬이 코드를 보냈다면 문장은 하위 호환용 잔재다. 코드를 믿는다.
        let resolved = BatteryStatusText.resolve(
            reason: .init(kind: .onBatteryPower),
            detail: "충전 제한 비활성화됨")
        #expect(resolved?.kind == .onBatteryPower)
    }

    @Test func fallsBackToParsingTheSentence() {
        let resolved = BatteryStatusText.resolve(reason: nil, detail: "목표치(85%)까지 충전 중")
        #expect(resolved?.kind == .chargingToTarget)
        #expect(resolved?.limitPercentage == 85)
    }

    /// 신버전 데몬 + 구버전 앱이 아니라, 구버전 앱 코드가 신버전 데몬을 만난 경우.
    /// 모르는 코드는 무시하고 문장으로 되돌아가야 한다.
    @Test func unrecognizedKindDefersToTheSentence() {
        let resolved = BatteryStatusText.resolve(
            reason: .init(kind: .unrecognized),
            detail: "충전 제한 비활성화됨")
        #expect(resolved?.kind == .limitDisabled)
    }

    @Test func unknownTextResolvesToNothing() {
        #expect(BatteryStatusText.resolve(reason: nil, detail: "Connection interrupted") == nil)
    }

    // MARK: - 현지화

    @Test func rendersFixedReasonsInTheRequestedLanguage() {
        #expect(BatteryStatusText.text(reason: .init(kind: .limitDisabled), detail: "", locale: en)
                == "Charge limit off")
        #expect(BatteryStatusText.text(reason: .init(kind: .limitDisabled), detail: "", locale: ja)
                == "充電上限オフ")
        #expect(BatteryStatusText.text(reason: .init(kind: .limitDisabled), detail: "", locale: ko)
                == "충전 제한 비활성화됨")

        #expect(BatteryStatusText.text(reason: .init(kind: .onBatteryPower), detail: "", locale: en)
                == "Running on battery")
        #expect(BatteryStatusText.text(reason: .init(kind: .hardwareUnsupported), detail: "", locale: en)
                == "This Mac does not support charge control")
        #expect(BatteryStatusText.text(reason: .init(kind: .releaseFailed), detail: "", locale: en)
                == "Could not resume charging (try reconnecting the power adapter)")
        #expect(BatteryStatusText.text(reason: .init(kind: .initializing), detail: "", locale: en)
                == "Initializing")
    }

    @Test func substitutesTheLimitIntoFormattedReasons() {
        #expect(BatteryStatusText.text(reason: .init(kind: .inhibitedAtLimit, limitPercentage: 80),
                                       detail: "", locale: en)
                == "Charge limit 80% reached (running on adapter bypass)")
        #expect(BatteryStatusText.text(reason: .init(kind: .inhibitedAtLimit, limitPercentage: 80),
                                       detail: "", locale: ko)
                == "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)")
        #expect(BatteryStatusText.text(reason: .init(kind: .chargingToTarget, limitPercentage: 85),
                                       detail: "", locale: en)
                == "Charging to 85%")
        #expect(BatteryStatusText.text(reason: .init(kind: .chargingToTarget, limitPercentage: 85),
                                       detail: "", locale: ko)
                == "목표치(85%)까지 충전 중")
        #expect(BatteryStatusText.text(reason: .init(kind: .sailing, limitPercentage: 80, resumePercentage: 75),
                                       detail: "", locale: en)
                == "Sailing (recharging at 75%)")
        #expect(BatteryStatusText.text(reason: .init(kind: .sailing, limitPercentage: 80, resumePercentage: 75),
                                       detail: "", locale: ko)
                == "Sailing 중 (75% 도달 시 재충전)")
    }

    @Test func sailingStatusTextFormatsCorrectlyInKoreanAndEnglish() {
        let reason = BatteryControlStatusReason(kind: .sailing, limitPercentage: 80, resumePercentage: 75)
        let koText = BatteryStatusText.text(reason: reason, detail: "", locale: ko)
        #expect(koText == "Sailing 중 (75% 도달 시 재충전)")

        let enText = BatteryStatusText.text(reason: reason, detail: "", locale: en)
        #expect(enText == "Sailing (recharging at 75%)")
    }

    /// 구버전 도우미를 그대로 쓰는 사용자도 자기 언어로 봐야 한다 — 이 계획의 핵심 약속.
    @Test func localizesASentenceFromAnOlderHelper() {
        #expect(BatteryStatusText.text(reason: nil, detail: "충전 제한 비활성화됨", locale: en)
                == "Charge limit off")
        #expect(BatteryStatusText.text(reason: nil,
                                       detail: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)",
                                       locale: en)
                == "Charge limit 80% reached (running on adapter bypass)")
        #expect(BatteryStatusText.text(reason: nil, detail: "목표치(85%)까지 충전 중", locale: ja)
                == "85% まで充電中")
        #expect(BatteryStatusText.text(reason: nil, detail: "Sailing 중 (75% 도달 시 충전)", locale: en)
                == "Sailing (recharging at 75%)")
    }

    /// 앱 자신이 쓰는 문구(`BatteryControlClient`)도 카탈로그 키다.
    @Test func localizesTheAppsOwnDetailStrings() {
        #expect(BatteryStatusText.text(reason: nil, detail: "도우미에 연결되지 않음", locale: en)
                == "Not connected to helper")
        #expect(BatteryStatusText.text(reason: nil, detail: "도우미 응답 오류", locale: en)
                == "Helper response error")
    }

    /// macOS가 만든 XPC 오류 설명은 이미 사용자 언어다. 건드리지 말고 그대로 통과.
    @Test func passesSystemErrorTextThrough() {
        let systemText = "Couldn’t communicate with a helper application."
        #expect(BatteryStatusText.text(reason: nil, detail: systemText, locale: en) == systemText)
        #expect(BatteryStatusText.text(reason: nil, detail: systemText, locale: ja) == systemText)
    }

    @Test func neverRendersEmptyForAKnownReason() {
        for kind in BatteryControlStatusReason.Kind.allCases where kind != .unrecognized {
            let text = BatteryStatusText.text(reason: .init(kind: kind, limitPercentage: 80),
                                              detail: "", locale: en)
            #expect(!text.isEmpty, "\(kind)")
        }
    }

    // MARK: - 설치 실패 문구

    @Test func buildsTheInstallFailureMessage() {
        #expect(BatteryStatusText.installFailureMessage(
                    reason: .init(kind: .hardwareUnsupported), detail: "", locale: en)
                == "Helper installed, but the charge limit could not be applied: This Mac does not support charge control")
    }

    @Test func installFailureMessageLocalizesAnOlderHelpersSentence() {
        #expect(BatteryStatusText.installFailureMessage(
                    reason: nil, detail: "이 Mac에서 충전 제어를 적용하지 못했습니다", locale: en)
                == "Helper installed, but the charge limit could not be applied: Could not apply charge control on this Mac")
    }

    @Test func heatProtectionStatusTextFormatting() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let activeReason = BatteryControlStatusReason(
            kind: .heatProtectionActive,
            currentTemperatureCelsius: 37.2,
            thresholdTemperatureCelsius: 36,
            resumeTemperatureCelsius: 34
        )
        #expect(BatteryStatusText.text(reason: activeReason, detail: "", locale: ko) == "발열 보호 중 (배터리 37.2°C, 34°C 도달 시 재충전)")
        #expect(BatteryStatusText.text(reason: activeReason, detail: "", locale: en) == "Heat Protection active (Battery 37.2°C, recharges at 34°C)")

        let cooldownReason = BatteryControlStatusReason(
            kind: .heatProtectionCooldown,
            currentTemperatureCelsius: 33.5,
            cooldownRemainingSeconds: 120
        )
        #expect(BatteryStatusText.text(reason: cooldownReason, detail: "", locale: ko) == "발열 보호 쿨다운 중 (120초 후 충전 재개)")
        #expect(BatteryStatusText.text(reason: cooldownReason, detail: "", locale: en) == "Heat Protection cooling down (recharging in 120s)")
    }

    @Test func topUpStatusTextLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let chargingReason = BatteryControlStatusReason(kind: .topUpCharging, limitPercentage: 100)
        let completeReason = BatteryControlStatusReason(kind: .topUpComplete, limitPercentage: 100)

        #expect(BatteryStatusText.text(reason: chargingReason, detail: "", locale: ko)
                == "한 번만 완충 중 (100%까지 충전)")
        #expect(BatteryStatusText.text(reason: chargingReason, detail: "", locale: en)
                == "One-time full charging (up to 100%)")

        #expect(BatteryStatusText.text(reason: completeReason, detail: "", locale: ko)
                == "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
        #expect(BatteryStatusText.text(reason: completeReason, detail: "", locale: en)
                == "One-time full charge complete (holding at 100%, reverts to limit on disconnect)")
    }
}
