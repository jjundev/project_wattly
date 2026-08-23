import Testing
import Foundation
import AppKit
@testable import Wattly

@Suite struct BatterySectionPresentationTests {

    private let en = Locale(identifier: "en")
    private let ko = Locale(identifier: "ko")

    // MARK: - 하위 항목 노출

    @Test func configurationControlsAreVisibleWhenSupportIsTrueOrUnknown() {
        // nil = 도우미가 아직 답하지 않았거나 구버전이라 말해줄 수 없는 상태.
        // "모른다"를 "불가능하다"로 취급하면 정상 Mac에서 UI가 사라진다.
        #expect(BatterySectionPresentation.showsConfigurationControls(isHardwareSupported: true))
        #expect(BatterySectionPresentation.showsConfigurationControls(isHardwareSupported: nil))
    }

    @Test func configurationControlsHideOnlyOnExplicitlyUnsupportedHardware() {
        #expect(!BatterySectionPresentation.showsConfigurationControls(isHardwareSupported: false))
    }

    // MARK: - 한도 선택기

    @Test func limitPickerFollowsTheToggle() {
        #expect(BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: true) == true)
        #expect(BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: false) == false)
    }

    @Test func limitPickerExplainsItselfOnlyWhenDisabled() {
        #expect(BatterySectionPresentation.limitPickerDisabledReason(isLimitOn: true) == nil)
        #expect(BatterySectionPresentation.limitPickerDisabledReason(isLimitOn: false)
                == "충전 제한을 켜면 한도를 조절할 수 있습니다.")
    }

    // MARK: - 상태 줄

    @Test func installingOutranksEverything() {
        // 설치 중에는 토글이 이미 ON이지만, 순서가 뒤집히면 설치 진행 표시가 사라진다.
        for isOn in [true, false] {
            let s = BatterySectionPresentation.status(isLimitOn: isOn, isInstalling: true,
                                                     mode: .unavailable,
                                                     reason: nil, detail: "도우미에 연결되지 않음",
                                                     locale: ko)
            #expect(s == .init(indicator: .installing, text: "도우미 설치 중…"))
        }
    }

    // 꺼짐 상태는 균일하지 않다 — `FanControlShared/BatteryControlEngine.swift`의
    // `hasActionableFailure`(`lastWriteFailed && (config.enabled || isCurrentlyInhibited)`)를 보면,
    // 토글을 끈 뒤에도 `isCurrentlyInhibited` 때문에 실패가 계속 "말이 되는" 상태로 남을 수 있다.
    // 그 경우 데몬은 `.unsupported` 모드 + "충전을 다시 시작하지 못했습니다" 같은 사용자가 실제로
    // 취할 수 있는 복구 안내를 돌려준다. 이 문구를 상수로 덮으면 충전이 멈춘 Mac을 두고 "정상적으로
    // 꺼졌다"고 거짓말하는 셈이 되고, `shouldPollStatus(isLimitOn: false) == false`라 다음 폴링이
    // 없으니 절대 스스로 바로잡히지 않는다.

    @Test func offAndUnavailableStillReportsTheConnectionFailure() {
        // 연결 실패는 토글과 무관한 현재 상태이므로 꺼짐 문구로 덮지 않는다.
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                 mode: .unavailable,
                                                 reason: nil, detail: "무시되어야 하는 문구",
                                                 locale: ko)
        #expect(s == .init(indicator: .unavailable, text: "무시되어야 하는 문구"))
    }

    @Test func offAndChargingPassesTheDaemonsDetailThrough() {
        // 정상적으로 꺼진 상태. 데몬이 이미 같은 뜻의 문구를 돌려주므로 상수로 다시 쓰지 않고
        // 그대로 통과시킨다 — 상수를 또 쓰면 두 곳이 조용히 어긋날 수 있다.
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                 mode: .charging,
                                                 reason: nil, detail: "충전 제한 비활성화됨",
                                                 locale: ko)
        #expect(s == .init(indicator: .inactive, text: "충전 제한 비활성화됨"))
    }

    @Test func offAndUnsupportedSurfacesTheActionableFailure() {
        // 토글을 껐는데 해제 SMC 쓰기가 실패해 하드웨어가 아직 충전을 막고 있는 상태
        // (`hasActionableFailure`의 `isCurrentlyInhibited` 분기). 회색 점 + 상수로 덮으면 충전이
        // 멈춘 사실을 감추게 되므로, 주황 점과 함께 사용자가 실제로 할 수 있는 복구 안내를 보여준다.
        let s = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .unsupported,
            reason: nil, detail: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)",
            locale: ko)
        #expect(s == .init(indicator: .failure,
                           text: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)"))
    }

    @Test func offAndInhibitedSurfacesTheVerifiedHardwareState() {
        // 꺼짐 + 여전히 억제 중. 아직 해제 쓰기가 반영되지 않은 과도기라도 회색 상수로 덮지 않고
        // 데몬의 실제 문구를 보여준다.
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                 mode: .inhibited,
                                                 reason: .init(kind: .inhibitedAtLimit,
                                                               limitPercentage: 80),
                                                 detail: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)",
                                                 locale: ko)
        #expect(s == .init(indicator: .holdingAtLimit,
                           text: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)"))
    }

    @Test func onStateMapsModeToFallbackIndicatorAndPassesDetailThrough() {
        let cases: [(BatteryControlServiceMode, BatterySectionPresentation.Indicator)] = [
            (.inhibited, .holdingAtLimit),
            (.charging, .chargingToLimit),
            (.unavailable, .unavailable),
            (.unsupported, .failure),
        ]
        for (mode, indicator) in cases {
            let s = BatterySectionPresentation.status(isLimitOn: true, isInstalling: false,
                                                     mode: mode,
                                                     reason: nil, detail: "데몬 문구",
                                                     locale: ko)
            #expect(s == .init(indicator: indicator, text: "데몬 문구"))
        }
    }

    // MARK: - 도우미 설치 버튼

    @Test func installButtonAppearsOnlyWhenTheFeatureIsOnAndTheHelperIsMissing() {
        #expect(BatterySectionPresentation.isInstallButtonVisible(isLimitOn: true, mode: .unavailable) == true)
        #expect(BatterySectionPresentation.isInstallButtonVisible(isLimitOn: true, mode: .charging) == false)
        // 꺼져 있으면 관리자 암호를 물을 이유가 없다 — 토글을 켜는 경로가 설치를 수행한다.
        #expect(BatterySectionPresentation.isInstallButtonVisible(isLimitOn: false, mode: .unavailable) == false)
    }

    // MARK: - 폴링

    // 꺼짐 상태의 문구가 전부 상수이던 시절의 전제는 `e311a7f` 이후로 더는 참이 아니다 —
    // `.inhibited`/`.unsupported`는 이제 데몬의 살아있는 `detail`을 그대로 보여주므로, 그 값이
    // 바뀔 수 있는 동안은 계속 다시 읽어야 한다. `.charging`/`.unavailable`만 여전히 상수라서
    // 폴링해봐야 데몬의 IOKit 전원 소스 읽기만 유발하고 화면은 그대로다.

    @Test func pollingRunsWhenOnRegardlessOfMode() {
        for mode: BatteryControlServiceMode in [.inhibited, .charging, .unavailable, .unsupported] {
            #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: true, mode: mode) == true)
        }
    }

    @Test func pollingStopsWhenOffAndSettled() {
        // `.charging` = 정상적으로 꺼짐, `.unavailable` = 도우미가 없어 물어봐야 답할 주체가 없음.
        // 둘 다 문구가 상수라 다시 읽어도 바뀌지 않는다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .charging) == false)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .unavailable) == false)
    }

    @Test func pollingContinuesWhenOffAndStillRecovering() {
        // 껐는데 하드웨어가 아직 물고 있거나 해제 쓰기가 실패한 상태 — 데몬이 스스로 재시도해
        // 풀어내므로, 여기서 폴링을 멈추면 사용자가 어댑터를 다시 꽂아 실제로 복구된 뒤에도 화면은
        // 실패 문구에 얼어붙는다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .inhibited) == true)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .unsupported) == true)
    }

    // MARK: - 현지화 (plan 2026-08-23)

    @Test func statusTextFollowsTheLocale() {
        let s = BatterySectionPresentation.status(isLimitOn: true, isInstalling: false,
                                                  mode: .charging,
                                                  reason: .init(kind: .chargingToTarget, limitPercentage: 80),
                                                  detail: "목표치(80%)까지 충전 중",
                                                  locale: en)
        #expect(s == .init(indicator: .chargingToLimit, text: "Charging to 80%"))
    }

    @Test func installingTextIsLocalized() {
        let s = BatterySectionPresentation.status(isLimitOn: true, isInstalling: true,
                                                  mode: .unavailable, reason: nil, detail: "",
                                                  locale: en)
        #expect(s == .init(indicator: .installing, text: "Installing helper…"))
    }

    /// 구버전 도우미용 로컬 fallback도 번역돼야 한다.
    @Test func disabledSubstituteTextIsLocalized() {
        #expect(BatterySectionPresentation.disabledStatusText(locale: en) == "Charge limit off")
        #expect(BatterySectionPresentation.disabledStatusText(locale: ko) == "충전 제한 비활성화됨")
    }

    /// 껐는데 하드웨어가 아직 물고 있는 상태. 회복 안내가 사라지지도, 한국어로 남지도 않아야 한다.
    @Test func stuckAfterTurningOffStaysLoudAndTranslated() {
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                  mode: .unsupported,
                                                  reason: .init(kind: .releaseFailed),
                                                  detail: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)",
                                                  locale: en)
        #expect(s == .init(indicator: .failure,
                           text: "Could not resume charging (try reconnecting the power adapter)"))
    }

    @Test func everyActivityHasAStableSemanticIndicator() {
        let cases: [(BatteryControlActivity, BatterySectionPresentation.Indicator)] = [
            (.inactive, .inactive),
            (.chargingToLimit, .chargingToLimit),
            (.holdingAtLimit, .holdingAtLimit),
            (.onBatteryPower, .onBatteryPower),
            (.sailing, .sailing),
            (.heatProtection, .heatProtection),
            (.topUp, .topUp),
            (.discharging, .discharging),
            (.calibration, .calibration),
        ]

        for (activity, indicator) in cases {
            let status = BatterySectionPresentation.status(
                isLimitOn: true,
                isInstalling: false,
                mode: .charging,
                // Future helpers keep `detail` for an app that knows this activity token but does
                // not yet know their newer reason token. The indicator and prose stay independent.
                reason: .init(kind: .unrecognized),
                detail: "상태 문구",
                locale: ko,
                activity: activity)
            #expect(status == .init(indicator: indicator, text: "상태 문구"))
        }
    }

    @Test func helperErrorsOutrankToggleActivityAndFreshness() {
        let unavailable = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .unavailable,
            reason: nil, detail: "도우미에 연결되지 않음", locale: ko,
            activity: .topUp, updatedAt: 100, now: 200)
        let failed = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .unsupported,
            reason: .init(kind: .applyFailed), detail: "이 Mac에서 충전 제어를 적용하지 못했습니다",
            locale: ko, activity: .topUp, updatedAt: 100, now: 200)

        #expect(unavailable.indicator == .unavailable)
        #expect(failed.indicator == .failure)
    }

    @Test func hardwareUnsupportedHasItsOwnReachableIndicator() {
        let status = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .unsupported,
            reason: .init(kind: .hardwareUnsupported),
            detail: "이 Mac은 충전 제어를 지원하지 않습니다",
            locale: ko, activity: nil)

        #expect(status == .init(indicator: .hardwareUnsupported,
                               text: "이 Mac은 충전 제어를 지원하지 않습니다"))
        #expect(BatterySectionPresentation.showsConfigurationControls(
            isHardwareSupported: false) == false)
    }

    @Test func explicitActivityWinsAndOlderHelperFallsBackToReason() {
        let explicit = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .inhibited,
            reason: .init(kind: .inhibitedAtLimit, limitPercentage: 80), detail: "상태 문구",
            locale: ko, activity: .heatProtection)
        let fallback = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .inhibited,
            reason: .init(kind: .inhibitedAtLimit, limitPercentage: 80), detail: "상태 문구",
            locale: ko, activity: nil)

        #expect(explicit.indicator == .heatProtection)
        #expect(fallback.indicator == .holdingAtLimit)
    }

    @Test func verifiedInactiveActivityOutranksAnOptimisticLocalToggle() {
        let status = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: false, mode: .charging,
            reason: .init(kind: .limitDisabled), detail: "충전 제한 비활성화됨",
            locale: ko, activity: .inactive)

        #expect(status == .init(indicator: .inactive, text: "충전 제한 비활성화됨"))
    }

    @Test func statusBecomesStaleOnlyAfterThreePollIntervals() {
        let atBoundary = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: false, mode: .charging,
            reason: .init(kind: .chargingToTarget, limitPercentage: 80), detail: "상태 문구",
            locale: ko, activity: .chargingToLimit, updatedAt: 100, now: 115)
        let stale = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: false, mode: .charging,
            reason: .init(kind: .chargingToTarget, limitPercentage: 80), detail: "상태 문구",
            locale: ko, activity: .chargingToLimit, updatedAt: 100, now: 115.001)

        #expect(atBoundary.indicator == .chargingToLimit)
        #expect(atBoundary.text == "목표치(80%)까지 충전 중")
        #expect(stale == .init(indicator: .stale, text: "확인 중..."))
    }

    @Test func unavailableAndInstallingAreNeverRelabeledAsStale() {
        let unavailable = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: false, mode: .unavailable,
            reason: nil, detail: "도우미에 연결되지 않음", locale: ko,
            activity: nil, updatedAt: 100, now: 200)
        let installing = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: true, mode: .charging,
            reason: nil, detail: "상태 문구", locale: ko,
            activity: .chargingToLimit, updatedAt: 100, now: 200)

        #expect(unavailable.indicator == .unavailable)
        #expect(installing.indicator == .installing)
    }

    @Test func indicatorsExposeStableSymbolsAndNonColorMeaning() {
        #expect(BatterySectionPresentation.Indicator.chargingToLimit.symbolName == "bolt.circle.fill")
        #expect(BatterySectionPresentation.Indicator.holdingAtLimit.symbolName == "pause.circle.fill")
        #expect(BatterySectionPresentation.Indicator.heatProtection.symbolName == "thermometer")
        #expect(BatterySectionPresentation.Indicator.failure.symbolName == "exclamationmark.triangle.fill")
        #expect(BatterySectionPresentation.Indicator.hardwareUnsupported.symbolName == "nosign")
        #expect(BatterySectionPresentation.Indicator.stale.symbolName == "clock.fill")

        #expect(BatterySectionPresentation.Indicator.chargingToLimit.tone == .green)
        #expect(BatterySectionPresentation.Indicator.failure.tone == .orange)
        #expect(BatterySectionPresentation.Indicator.unavailable.tone == .red)
        #expect(BatterySectionPresentation.Indicator.hardwareUnsupported.tone == .red)
        #expect(BatterySectionPresentation.Indicator.inactive.tone == .faint)
    }

    @Test func everyIndicatorSymbolExistsOnTheRunningMacOS() {
        for indicator in BatterySectionPresentation.Indicator.allCases {
            #expect(NSImage(systemSymbolName: indicator.symbolName,
                            accessibilityDescription: nil) != nil,
                    "Missing SF Symbol: \(indicator.symbolName)")
        }
    }

    /// 한도 선택기의 사유는 **카탈로그 키**로 남는다. 뷰가 `LocalizedStringKey`로 푼다.
    @Test func limitPickerReasonStaysAKey() {
        #expect(BatterySectionPresentation.limitPickerDisabledReason(isLimitOn: false)
                == "충전 제한을 켜면 한도를 조절할 수 있습니다.")
    }
}
