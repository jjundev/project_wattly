import Testing
import Foundation
import AppKit
@testable import Wattly

@Suite struct BatterySectionPresentationTests {

    private let en = Locale(identifier: "en")
    private let ko = Locale(identifier: "ko")

    // MARK: - 유지보수 증거

    @Test func persistentHelperShowsLastWakeVerification() {
        let record = BatteryMaintenanceRecord(
            trigger: .wake, result: .verified, occurredAt: 100, reason: nil)
        let status = BatterySectionPresentation.maintenanceStatus(
            ownership: .owner(UInt32(getuid())),
            currentUID: UInt32(getuid()),
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1],
            record: record,
            locale: ko,
            timestampText: { _ in "21:04" })
        #expect(status == .init(
            tone: .faint,
            text: "마지막 확인: 절전 해제 · 성공 · 21:04",
            action: nil))
    }

    @Test func missingCapabilitiesOfferHelperUpdate() {
        let status = BatterySectionPresentation.maintenanceStatus(
            ownership: .owner(UInt32(getuid())),
            currentUID: UInt32(getuid()),
            capabilities: nil,
            record: nil,
            locale: ko,
            timestampText: { _ in "21:04" })
        #expect(status?.action == .updateHelper)
        #expect(status?.text == "앱 종료·Sleep 유지를 사용하려면 도우미 업데이트가 필요합니다.")
    }

    @Test func failedMaintenanceOffersRetry() {
        let record = BatteryMaintenanceRecord(
            trigger: .wake,
            result: .failed,
            occurredAt: 100,
            reason: .init(kind: .hardwareReadbackFailed))
        let status = BatterySectionPresentation.maintenanceStatus(
            ownership: .owner(UInt32(getuid())),
            currentUID: UInt32(getuid()),
            capabilities: BatteryControlCoordinator.capabilities,
            record: record,
            locale: ko,
            timestampText: { _ in "21:04" })
        #expect(status?.tone == .red)
        #expect(status?.action == .retry)
    }

    @Test func skippedMaintenanceDoesNotClaimASuccessfulCheck() {
        let record = BatteryMaintenanceRecord(
            trigger: .wake,
            result: .skipped,
            occurredAt: 100,
            reason: .init(kind: .powerSourceUnreadable))
        let status = BatterySectionPresentation.maintenanceStatus(
            ownership: .owner(UInt32(getuid())),
            currentUID: UInt32(getuid()),
            capabilities: BatteryControlCoordinator.capabilities,
            record: record,
            locale: ko,
            timestampText: { _ in "21:04" })
        #expect(status?.tone == .red)
        #expect(status?.text == "전원 소스를 읽을 수 없습니다")
        #expect(status?.action == .retry)
    }

    @Test func foreignOwnershipOutranksMissingCapabilities() {
        let status = BatterySectionPresentation.maintenanceStatus(
            ownership: .owner(502),
            currentUID: 501,
            capabilities: nil,
            record: nil,
            locale: ko,
            timestampText: { _ in "21:04" })
        #expect(status?.tone == .red)
        #expect(status?.action == .transferOwnership)
    }

    @Test func invalidOwnershipOffersTransfer() {
        let status = BatterySectionPresentation.maintenanceStatus(
            ownership: .invalidMetadata,
            currentUID: 501,
            capabilities: BatteryControlCoordinator.capabilities,
            record: nil,
            locale: ko,
            timestampText: { _ in "21:04" })
        #expect(status?.action == .transferOwnership)
    }

    @Test func capableHelperWithoutEvidenceShowsPendingCheck() {
        let status = BatterySectionPresentation.maintenanceStatus(
            ownership: .owner(501),
            currentUID: 501,
            capabilities: BatteryControlCoordinator.capabilities,
            record: nil,
            locale: ko,
            timestampText: { _ in "21:04" })
        #expect(status == .init(tone: .faint, text: "충전 정책 확인 전", action: nil))
    }

    @Test func successfulConfigurationShowsItsTrigger() {
        let status = BatterySectionPresentation.maintenanceStatus(
            ownership: .owner(501),
            currentUID: 501,
            capabilities: BatteryControlCoordinator.capabilities,
            record: .init(trigger: .clientConfiguration, result: .applied, occurredAt: 100, reason: nil),
            locale: ko,
            timestampText: { _ in "21:04" })
        #expect(status?.text == "마지막 확인: 설정 변경 · 성공 · 21:04")
    }

    @Test func maintenancePopoverShowsTheLastCheckOrPendingState() {
        let lastCheck = BatterySectionPresentation.MaintenanceStatus(
            tone: .faint,
            text: "마지막 확인: 설정 변경 · 성공 · 21:04",
            action: nil)

        #expect(BatterySectionPresentation.maintenancePopoverText(lastCheck, locale: ko)
                == "마지막 확인: 설정 변경 · 성공 · 21:04")
        #expect(BatterySectionPresentation.maintenancePopoverText(nil, locale: ko)
                == "충전 정책 확인 전")
    }

    /// `maintenanceStatus`는 절대 nil을 돌려주지 않고 `.green`도 내보내지 않는다 — 성공했을
    /// 때조차 `.faint`다. 그래서 아이콘은 문제를 알리는 톤(`.red`/`.orange`)일 때만 경고
    /// 삼각형이고, 그 외(`.faint`/`.green`)는 물음표를 유지해야 한다.
    @Test func maintenanceStatusSymbolNameWarnsOnlyForRedOrOrangeTone() {
        let cases: [(tone: BatterySectionPresentation.Tone, expectedSymbol: String)] = [
            (.red, "exclamationmark.triangle.fill"),
            (.orange, "exclamationmark.triangle.fill"),
            (.faint, "questionmark.circle"),
            (.green, "questionmark.circle"),
        ]
        for (tone, expectedSymbol) in cases {
            let status = BatterySectionPresentation.MaintenanceStatus(tone: tone, text: "x", action: nil)
            #expect(status.symbolName == expectedSymbol, "tone \(tone) should map to \(expectedSymbol)")
        }
    }

    @Test func maintenanceActionsHaveLocalizedVoiceOverLabels() {
        #expect(BatterySectionPresentation.maintenanceActionLabel(.retry, locale: en) == "Check Again")
        #expect(BatterySectionPresentation.maintenanceActionLabel(.updateHelper, locale: en) == "Update Helper")
        #expect(BatterySectionPresentation.maintenanceActionLabel(.transferOwnership, locale: en)
                == "Transfer Ownership")
    }

    @Test func maintenancePopoverUsesEverySupportedLocale() {
        let locales = ["ar", "cs", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi",
                       "hu", "id", "it", "ja", "ko", "nb", "nl", "pl", "pt-BR", "pt-PT",
                       "ro", "ru", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant"]
        let triggers: [BatteryMaintenanceTrigger] = [
            .startup, .wake, .clientConfiguration, .adapterTransition, .termination,
            .topUpExpired, .unrecognized,
        ]
        let reasons: [BatteryControlStatusReason.Kind] = [
            .persistenceReadFailed, .persistenceWriteFailed, .policyOwnerMismatch, .hardwareReadbackFailed,
        ]
        let actions: [BatterySectionPresentation.MaintenanceAction] = [.retry, .updateHelper, .transferOwnership]

        func successfulText(trigger: BatteryMaintenanceTrigger, locale: Locale) -> String {
            BatterySectionPresentation.maintenanceStatus(
                ownership: .owner(501), currentUID: 501,
                capabilities: BatteryControlCoordinator.capabilities,
                record: .init(trigger: trigger, result: .verified, occurredAt: 100, reason: nil),
                locale: locale, timestampText: { _ in "21:04" })!.text
        }

        for identifier in locales where identifier != "ko" {
            let locale = Locale(identifier: identifier)
            for trigger in triggers {
                #expect(successfulText(trigger: trigger, locale: locale)
                        != successfulText(trigger: trigger, locale: ko),
                        "\(identifier): \(trigger) translated text fell back to Korean")
            }
            for reason in reasons {
                let translated = BatterySectionPresentation.maintenanceStatus(
                    ownership: .owner(501), currentUID: 501,
                    capabilities: BatteryControlCoordinator.capabilities,
                    record: .init(trigger: .wake, result: .failed, occurredAt: 100,
                                  reason: .init(kind: reason)), locale: locale)!.text
                let korean = BatterySectionPresentation.maintenanceStatus(
                    ownership: .owner(501), currentUID: 501,
                    capabilities: BatteryControlCoordinator.capabilities,
                    record: .init(trigger: .wake, result: .failed, occurredAt: 100,
                                  reason: .init(kind: reason)), locale: ko)!.text
                #expect(translated != korean, "\(identifier): \(reason) fell back to Korean")
            }
            for action in actions {
                #expect(BatterySectionPresentation.maintenanceActionLabel(action, locale: locale)
                        != BatterySectionPresentation.maintenanceActionLabel(action, locale: ko),
                        "\(identifier): \(action) fell back to Korean")
            }
            let foreignOwner = BatterySectionPresentation.maintenanceStatus(
                ownership: .owner(502), currentUID: 501, capabilities: nil, record: nil,
                locale: locale)!.text
            let koreanForeignOwner = BatterySectionPresentation.maintenanceStatus(
                ownership: .owner(502), currentUID: 501, capabilities: nil, record: nil,
                locale: ko)!.text
            #expect(foreignOwner != koreanForeignOwner,
                    "\(identifier): foreign-owner recovery fell back to Korean")
        }
    }

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

    @Test func theToggleStaysUsableWhileItReadsOnEvenOnHardwareThatCannotDoIt() {
        // 지원되는(또는 아직 모르는) 하드웨어에서는 언제나 조작할 수 있다.
        for supported: Bool? in [true, nil] {
            for isOn in [true, false] {
                #expect(BatterySectionPresentation.isToggleEnabled(isHardwareSupported: supported,
                                                                    isLimitOn: isOn) == true)
            }
        }

        // 불가능한 하드웨어에서 꺼져 있으면 켤 수 없다 — 켜봐야 아무 일도 일어나지 않는다.
        #expect(BatterySectionPresentation.isToggleEnabled(isHardwareSupported: false,
                                                            isLimitOn: false) == false)

        // ...그러나 이미 켜져 있다면 끌 수 있어야 한다. 펌웨어가 바뀌며 지원이 사라진 Mac에는 저장된
        // `true`가 그대로 남는데, 그 값을 앱이 대신 꺼주지 않는 것은 의도된 설계다(SettingsBatterySection
        // 상단 주석). 이 한 칸이 열려 있지 않으면 사용자에게는 전체 설정 초기화 말고 빠져나갈 길이 없다.
        #expect(BatterySectionPresentation.isToggleEnabled(isHardwareSupported: false,
                                                            isLimitOn: true) == true)
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
            #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: true, mode: mode,
                                                                isHardwareSupported: true) == true)
        }
    }

    @Test func pollingStopsWhenOffAndSettled() {
        // `.charging` = 정상적으로 꺼짐, `.unavailable` = 도우미가 없어 물어봐야 답할 주체가 없음.
        // 둘 다 문구가 상수라 다시 읽어도 바뀌지 않는다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .charging,
                                                            isHardwareSupported: true) == false)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .unavailable,
                                                            isHardwareSupported: true) == false)
    }

    @Test func pollingContinuesWhenOffAndStillRecovering() {
        // 껐는데 하드웨어가 아직 물고 있거나 해제 쓰기가 실패한 상태 — 데몬이 스스로 재시도해
        // 풀어내므로, 여기서 폴링을 멈추면 사용자가 어댑터를 다시 꽂아 실제로 복구된 뒤에도 화면은
        // 실패 문구에 얼어붙는다.
        //
        // `.unsupported` 모드는 두 가지를 뜻한다 — 레지스터가 아예 없거나(영구), 쓰기가 계속
        // 실패하거나(`BatteryControlEngine`의 `!isHardwareSupported || hasActionableFailure`, 일시적).
        // 전자는 `isHardwareSupported == false`로 걸러져 폴링이 멎지만, 후자는 데몬이 재시도로
        // 빠져나올 수 있는 상태이므로 여기서는 `isHardwareSupported: true`로 두어 폴링이 계속돼야
        // 한다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .inhibited,
                                                            isHardwareSupported: true) == true)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .unsupported,
                                                            isHardwareSupported: true) == true)
    }

    @Test func pollingStopsOnHardwareThatCanNeverChangeItsAnswer() {
        // 영구적인 사실에는 재질문이 없다. 이 상태에서는 설정 컨트롤도 숨겨지는데, 5초마다
        // XPC 왕복과 루트 데몬의 IOKit 전원 소스 읽기가 무한히 돌 이유가 없다.
        // 한도가 켜져 있어도 마찬가지다 — 켜짐은 사용자의 저장값일 뿐, 하드웨어의 답을 바꾸지 못한다.
        for isOn in [true, false] {
            for mode: BatteryControlServiceMode in [.inhibited, .charging, .unavailable, .unsupported] {
                #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: isOn, mode: mode,
                                                                    isHardwareSupported: false) == false)
            }
        }
    }

    @Test func pollingSurvivesAnUnansweredHelper() {
        // `nil`은 "아직 답이 없다"이지 "불가능하다"가 아니다. 여기서 폴링을 멈추면 도우미가 처음
        // 답하기 전에 창을 연 사용자는 영영 답을 못 받는다 — 다시 물어볼 유일한 주체가 이 루프다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: true, mode: .unavailable,
                                                            isHardwareSupported: nil) == true)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false, mode: .unsupported,
                                                            isHardwareSupported: nil) == true)
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

    @Test func reasonlessLegacyOnBatteryPayloadKeepsItsIconAndTextAligned() {
        let legacyActivities: [BatteryControlActivity?] = [nil, .unrecognized]

        for activity in legacyActivities {
            let status = BatterySectionPresentation.status(
                isLimitOn: true, isInstalling: false, mode: .charging,
                reason: nil, detail: "배터리 전원으로 구동 중",
                locale: en, activity: activity)

            #expect(status == .init(indicator: .onBatteryPower, text: "Running on battery"))
        }
    }

    @Test func legacyUnsupportedPayloadUsesTheSameResolvedReasonAsItsText() {
        let status = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: false, mode: .unsupported,
            reason: .init(kind: .unrecognized),
            detail: "이 Mac은 충전 제어를 지원하지 않습니다",
            locale: en, activity: nil)

        #expect(status == .init(indicator: .hardwareUnsupported,
                                text: "This Mac does not support charge control"))
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

    @Test func recoveringStatusStillBecomesStaleWhilePollingContinues() {
        let status = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .inhibited,
            reason: .init(kind: .inhibitedAtLimit, limitPercentage: 80),
            detail: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)",
            locale: ko, activity: .holdingAtLimit, updatedAt: 100, now: 115.001)

        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false,
                                                            mode: .inhibited,
                                                            isHardwareSupported: true) == true)
        #expect(status == .init(indicator: .stale, text: "확인 중..."))
    }

    @Test func offAndSettledStatusNeverBecomesStaleAfterPollingStops() {
        let status = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .charging,
            reason: .init(kind: .limitDisabled), detail: "충전 제한 비활성화됨",
            locale: ko, activity: .inactive, updatedAt: 100, now: 200)

        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false,
                                                            mode: .charging,
                                                            isHardwareSupported: true) == false)
        #expect(status == .init(indicator: .inactive, text: "충전 제한 비활성화됨"))
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

    // MARK: - Sailing Mode

    @Test func sailingRangeDescriptionShowsStopAndResumePercentages() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let koDesc = BatterySectionPresentation.sailingRangeDescription(limit: 80, delta: 5, locale: ko)
        #expect(koDesc == "80% 도달 시 충전 정지, 75%에서 재충전")

        let enDesc = BatterySectionPresentation.sailingRangeDescription(limit: 80, delta: 5, locale: en)
        #expect(enDesc == "Stops at 80%, recharges at 75%")
    }

    @Test func sailingPresetsAreValid() {
        #expect(BatterySectionPresentation.sailingDeltaPresets == [2, 5, 10])
    }

    // MARK: - Heat Protection

    @Test func shouldPollStatusWhenHeatProtectionIsEnabledEvenIfLimitIsOff() {
        #expect(BatterySectionPresentation.shouldPollStatus(
            isLimitOn: false,
            isHeatProtectionOn: true,
            mode: .charging,
            isHardwareSupported: true
        ) == true)
    }

    @Test func isInstallButtonVisibleAndToggleEnabledWithHeatProtection() {
        #expect(BatterySectionPresentation.isInstallButtonVisible(
            isLimitOn: false,
            isHeatProtectionOn: true,
            mode: .unavailable
        ) == true)
        #expect(BatterySectionPresentation.isInstallButtonVisible(
            isLimitOn: false,
            isHeatProtectionOn: false,
            mode: .unavailable
        ) == false)

        #expect(BatterySectionPresentation.isToggleEnabled(
            isHardwareSupported: false,
            isLimitOn: false,
            isHeatProtectionOn: true
        ) == true)
    }

    // MARK: - Top Up

    @Test func topUpStatusRendersTopUpIndicator() {
        let ko = Locale(identifier: "ko")
        let statusCharging = BatterySectionPresentation.status(
            isLimitOn: true,
            isInstalling: false,
            mode: .charging,
            reason: .init(kind: .topUpCharging, limitPercentage: 100),
            detail: "한 번만 완충 중 (100%까지 충전)",
            locale: ko,
            activity: .topUp
        )
        #expect(statusCharging.indicator == .topUp)
        #expect(statusCharging.indicator.symbolName == "arrow.up.circle.fill")
        #expect(statusCharging.indicator.tone == .green)
        #expect(statusCharging.text == "한 번만 완충 중 (100%까지 충전)")

        let statusComplete = BatterySectionPresentation.status(
            isLimitOn: true,
            isInstalling: false,
            mode: .inhibited,
            reason: .init(kind: .topUpComplete, limitPercentage: 100),
            detail: "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)",
            locale: ko,
            activity: .topUp
        )
        #expect(statusComplete.indicator == .topUp)
        #expect(statusComplete.text == "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
    }

    @Test func shouldPollStatusReturnsTrueDuringActiveTopUp() {
        #expect(BatterySectionPresentation.shouldPollStatus(
            isLimitOn: false,
            isHeatProtectionOn: false,
            isTopUpOn: true,
            mode: .charging,
            isHardwareSupported: true
        ) == true)
    }

    // MARK: - Schedule Chip Presentation

    @Test func upcomingSchedulePresentationFormatting() {
        let schedule = BatteryChargingSchedule(
            name: "출근 완충",
            time: ScheduleTime(hour: 7, minute: 30),
            action: .startTopUp
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let triggerDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 7, minute: 30))!

        let text = BatterySectionPresentation.upcomingScheduleText(
            schedule: schedule,
            triggerDate: triggerDate
        )

        #expect(text != nil)
        #expect(text?.contains("07:30") == true)
        #expect(text?.contains("완충") == true)

        #expect(BatterySectionPresentation.upcomingScheduleText(schedule: nil, triggerDate: triggerDate) == nil)
        #expect(BatterySectionPresentation.upcomingScheduleText(schedule: schedule, triggerDate: nil) == nil)
    }

    // MARK: - Discharge Presentation

    @Test func dischargeIndicatorProperties() {
        #expect(BatterySectionPresentation.Indicator.discharging.symbolName == "arrow.down.circle.fill")
        #expect(BatterySectionPresentation.Indicator.discharging.tone == .orange)
    }

    @Test func dischargePresentationText() {
        let textKo = BatterySectionPresentation.dischargeDescription(target: 70, currentSoC: 85, watts: -18.4, locale: ko)
        #expect(textKo == "수동 방전 진행 중")

        let textEn = BatterySectionPresentation.dischargeDescription(target: 70, currentSoC: 85, watts: -18.4, locale: en)
        #expect(textEn == "Manual discharge in progress")
    }

    @Test func estimatedDischargeTimeCalculation() {
        // 85% -> 70% with 70Wh capacity at 18.4W: delta = 15% of 70Wh = 10.5Wh; 10.5 / 18.4 * 60 = 34.23 min -> 34 min
        let koTime = BatterySectionPresentation.estimatedDischargeTime(
            currentSoC: 85,
            targetSoC: 70,
            netWatts: 18.4,
            capacityWh: 70.0,
            locale: ko
        )
        #expect(koTime == "약 34분 남음")

        let enTime = BatterySectionPresentation.estimatedDischargeTime(
            currentSoC: 85,
            targetSoC: 70,
            netWatts: -18.4,
            capacityWh: 70.0,
            locale: en
        )
        #expect(enTime == "About 34 min remaining")

        // Already at or below target
        #expect(BatterySectionPresentation.estimatedDischargeTime(
            currentSoC: 70, targetSoC: 70, netWatts: 18.4, capacityWh: 70.0, locale: ko) == nil)
        #expect(BatterySectionPresentation.estimatedDischargeTime(
            currentSoC: 60, targetSoC: 70, netWatts: 18.4, capacityWh: 70.0, locale: ko) == nil)

        // Idle power (< 0.5W)
        #expect(BatterySectionPresentation.estimatedDischargeTime(
            currentSoC: 85, targetSoC: 70, netWatts: 0.1, capacityWh: 70.0, locale: ko) == nil)
    }

    @Test func dischargeAndPowerFlowLabels() {
        #expect(BatterySectionPresentation.adapterPowerBlockedText(locale: ko) == "0.0 W (차단됨)")
        #expect(BatterySectionPresentation.adapterPowerBlockedText(locale: en) == "0.0 W (Blocked)")

        #expect(BatterySectionPresentation.topUpHoldText(locale: ko) == "완충 완료 (어댑터 전원 구동)")
        #expect(BatterySectionPresentation.topUpHoldText(locale: en) == "Top-Up Complete (Adapter Power)")

        #expect(BatterySectionPresentation.forcedDischargeText(locale: ko) == "배터리 (수동 방전 중)")
        #expect(BatterySectionPresentation.forcedDischargeText(locale: en) == "Battery (Manual Discharge)")

        #expect(BatterySectionPresentation.startDischargeButtonText(targetSoC: 70, locale: ko) == "방전 시작")
        #expect(BatterySectionPresentation.startDischargeButtonText(targetSoC: 70, locale: en) == "Start Discharge")
    }

    @Test func powerSupplyVisibilityUsesEffectiveAdapterStateDuringForcedDischarge() {
        #expect(BatterySectionPresentation.shouldShowPowerSupplySection(
            sampleExternalConnected: false,
            serviceAdapterConnected: true,
            activity: .discharging,
            manualDischargeActive: true,
            powerFlowScenario: .batteryOnly
        ))

        #expect(BatterySectionPresentation.shouldShowPowerSupplySection(
            sampleExternalConnected: false,
            serviceAdapterConnected: false,
            activity: .discharging,
            manualDischargeActive: false,
            powerFlowScenario: .batteryOnly
        ))

        #expect(BatterySectionPresentation.shouldShowPowerSupplySection(
            sampleExternalConnected: false,
            serviceAdapterConnected: false,
            activity: nil,
            manualDischargeActive: false,
            powerFlowScenario: .activeDischarge
        ))

        #expect(!BatterySectionPresentation.shouldShowPowerSupplySection(
            sampleExternalConnected: false,
            serviceAdapterConnected: false,
            activity: nil,
            manualDischargeActive: false,
            powerFlowScenario: .batteryOnly
        ))

        #expect(!BatterySectionPresentation.shouldShowPowerSupplySection(
            sampleExternalConnected: true,
            serviceAdapterConnected: true,
            activity: .discharging,
            manualDischargeActive: true,
            powerFlowScenario: nil
        ))
    }

    @Test func batteryControlRowsVisibilityPolicy() {
        // 1. Normal plugged in with adapter connected -> true
        #expect(BatterySectionPresentation.shouldShowBatteryControlRows(
            sampleCharging: false,
            sampleExternalConnected: true,
            serviceAdapterConnected: true,
            activity: .holdingAtLimit,
            manualDischargeActive: false
        ))

        // 2. Active forced discharge -> true
        #expect(BatterySectionPresentation.shouldShowBatteryControlRows(
            sampleCharging: false,
            sampleExternalConnected: false,
            serviceAdapterConnected: false,
            activity: .discharging,
            manualDischargeActive: true
        ))

        // 3. Forced discharge stop transition (activity holding, desired config active) -> true
        #expect(BatterySectionPresentation.shouldShowBatteryControlRows(
            sampleCharging: false,
            sampleExternalConnected: false,
            serviceAdapterConnected: false,
            activity: .holdingAtLimit,
            manualDischargeActive: true
        ))

        // 4. Pure battery unplugged (all false) -> false
        #expect(!BatterySectionPresentation.shouldShowBatteryControlRows(
            sampleCharging: false,
            sampleExternalConnected: false,
            serviceAdapterConnected: false,
            activity: nil,
            manualDischargeActive: false
        ))
    }

    @Test func topUpRowVisibilityPolicy() {
        // Setting ON + Top-up Inactive + Discharge Inactive -> Shown
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false, isDischargeActive: false))
        // Setting OFF + Top-up Inactive + Discharge Inactive -> Hidden
        #expect(!BatterySectionPresentation.shouldShowTopUpRow(showSetting: false, isTopUpActive: false, isDischargeActive: false))
        // Setting OFF + Top-up Active + Discharge Inactive -> Shown (Safety override)
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: false, isTopUpActive: true, isDischargeActive: false))
        // Setting ON + Top-up Active + Discharge Inactive -> Shown
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: true, isDischargeActive: false))
        // Discharge Active + Top-up Inactive -> Hidden (Mutual exclusion)
        #expect(!BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false, isDischargeActive: true))
        // Dual active (abnormal edge case) -> Shown (Emergency fallback)
        #expect(BatterySectionPresentation.shouldShowTopUpRow(showSetting: false, isTopUpActive: true, isDischargeActive: true))
    }

    @Test func manualDischargeRowVisibilityPolicy() {
        // Setting ON, SoC 90 > target 80, not discharging, top-up inactive -> Shown
        #expect(BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: true,
            isDischarging: false,
            isTopUpActive: false,
            currentSoC: 90,
            targetSoC: 80
        ))

        // Setting ON, SoC 70 <= target 80, not discharging, top-up inactive -> Hidden (SoC below target)
        #expect(!BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: true,
            isDischarging: false,
            isTopUpActive: false,
            currentSoC: 70,
            targetSoC: 80
        ))

        // Setting OFF, not discharging, top-up inactive -> Hidden even if SoC > target
        #expect(!BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: false,
            isDischarging: false,
            isTopUpActive: false,
            currentSoC: 90,
            targetSoC: 80
        ))

        // Setting OFF, actively discharging, top-up inactive -> Shown (Safety override)
        #expect(BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: false,
            isDischarging: true,
            isTopUpActive: false,
            currentSoC: 70,
            targetSoC: 80
        ))

        // Top-up active, discharge inactive -> Hidden (Mutual exclusion even if setting ON and SoC > target)
        #expect(!BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: true,
            isDischarging: false,
            isTopUpActive: true,
            currentSoC: 90,
            targetSoC: 80
        ))

        // Dual active (abnormal edge case) -> Shown (Emergency fallback to allow stopping)
        #expect(BatterySectionPresentation.shouldShowManualDischargeRow(
            showSetting: false,
            isDischarging: true,
            isTopUpActive: true,
            currentSoC: 70,
            targetSoC: 80
        ))
    }

    @Test func batteryControlRowsMutualExclusionPolicy() {
        // Case 1: Top-up active -> Top-up shown, Discharge hidden
        let topUp1 = BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: true, isDischargeActive: false)
        let discharge1 = BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: true, isDischarging: false, isTopUpActive: true, currentSoC: 90, targetSoC: 80)
        #expect(topUp1 == true)
        #expect(discharge1 == false)

        // Case 2: Discharge active -> Top-up hidden, Discharge shown
        let topUp2 = BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false, isDischargeActive: true)
        let discharge2 = BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: true, isDischarging: true, isTopUpActive: false, currentSoC: 90, targetSoC: 80)
        #expect(topUp2 == false)
        #expect(discharge2 == true)

        // Case 3: Both inactive, both settings ON, SoC > target -> Both shown
        let topUp3 = BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false, isDischargeActive: false)
        let discharge3 = BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: true, isDischarging: false, isTopUpActive: false, currentSoC: 90, targetSoC: 80)
        #expect(topUp3 == true)
        #expect(discharge3 == true)

        // Case 4: Both inactive, both settings ON, SoC <= target -> Top-up shown, Discharge hidden
        let topUp4 = BatterySectionPresentation.shouldShowTopUpRow(showSetting: true, isTopUpActive: false, isDischargeActive: false)
        let discharge4 = BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: true, isDischarging: false, isTopUpActive: false, currentSoC: 70, targetSoC: 80)
        #expect(topUp4 == true)
        #expect(discharge4 == false)

        // Case 5: Both active (edge case) -> Both shown (Safety override)
        let topUp5 = BatterySectionPresentation.shouldShowTopUpRow(showSetting: false, isTopUpActive: true, isDischargeActive: true)
        let discharge5 = BatterySectionPresentation.shouldShowManualDischargeRow(showSetting: false, isDischarging: true, isTopUpActive: true, currentSoC: 70, targetSoC: 80)
        #expect(topUp5 == true)
        #expect(discharge5 == true)
    }

    @Test func batteryControlSectionDividerAndContainerGating() {
        // Both rows hidden -> Entire section hidden (no Divider rendered)
        #expect(!BatterySectionPresentation.shouldShowBatteryControlSection(
            showControlRows: true,
            willShowTopUp: false,
            willShowDischarge: false
        ))

        // Top up shown -> Section shown
        #expect(BatterySectionPresentation.shouldShowBatteryControlSection(
            showControlRows: true,
            willShowTopUp: true,
            willShowDischarge: false
        ))

        // Discharge shown -> Section shown
        #expect(BatterySectionPresentation.shouldShowBatteryControlSection(
            showControlRows: true,
            willShowTopUp: false,
            willShowDischarge: true
        ))

        // showControlRows false (e.g. unplugged and not discharging) -> Section hidden regardless
        #expect(!BatterySectionPresentation.shouldShowBatteryControlSection(
            showControlRows: false,
            willShowTopUp: true,
            willShowDischarge: true
        ))
    }

    @Test func topUpExpiredTriggerHasItsOwnKoreanSentence() {
        let ko = Locale(identifier: "ko")
        let text = BatterySectionPresentation.maintenanceStatus(
            ownership: .owner(501), currentUID: 501,
            capabilities: BatteryControlCoordinator.capabilities,
            record: .init(trigger: .topUpExpired, result: .applied,
                          occurredAt: 100, reason: nil),
            locale: ko, timestampText: { _ in "21:04" })!.text
        #expect(text.contains("완충 자동 해제"))
    }

    /// 모르는 trigger는 예전처럼 관용 디코딩으로 `.unrecognized`가 되어야 한다 —
    /// 구버전 앱이 신버전 헬퍼의 상태 전체를 잃지 않게 하는 장치다.
    @Test func topUpExpiredTriggerRoundTripsAndDegradesGracefully() throws {
        let data = try JSONEncoder().encode(BatteryMaintenanceTrigger.topUpExpired)
        #expect(String(data: data, encoding: .utf8) == "\"topUpExpired\"")
        let unknown = try JSONDecoder().decode(
            BatteryMaintenanceTrigger.self, from: "\"someFutureTrigger\"".data(using: .utf8)!)
        #expect(unknown == .unrecognized)
    }

    @Test func topUpDescriptionNamesBothEndConditions() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let korean = BatterySectionPresentation.topUpDescription(hours: 12, locale: ko)
        #expect(korean.contains("어댑터를 분리하거나"))
        #expect(korean.contains("12시간"))
        #expect(korean.contains("100%"))

        let english = BatterySectionPresentation.topUpDescription(hours: 12, locale: en)
        #expect(english.contains("12 hours"))
        #expect(english != korean)
    }

    @Test func manualDischargeDisabledReasonTests() {
        // 1. Can start discharge -> nil
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 80,
            targetSoC: 70,
            isHardwareSupported: true,
            isToggleEnabled: true,
            locale: ko
        ) == nil)
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 80,
            targetSoC: 70,
            isHardwareSupported: true,
            isToggleEnabled: true,
            locale: en
        ) == nil)

        // 2. 하드웨어 미지원 또는 토글 비활성 -> 조건과 일치하는 문구를 쓴다.
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: false, isToggleEnabled: true, locale: ko
        ) == "이 Mac은 충전 제어를 지원하지 않습니다")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: false, isToggleEnabled: true, locale: en
        ) == "This Mac does not support charge control")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: true, isToggleEnabled: false, locale: ko
        ) == "이 Mac은 충전 제어를 지원하지 않습니다")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: true, isToggleEnabled: false, locale: en
        ) == "This Mac does not support charge control")

        // 2-b. 충전 제어는 되지만 CHIE 강제 방전을 지원하지 않는 Mac.
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: true, isDischargeHardwareSupported: false,
            isToggleEnabled: true, locale: ko
        ) == "이 Mac은 강제 방전을 지원하지 않습니다.")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: true, isDischargeHardwareSupported: false,
            isToggleEnabled: true, locale: en
        ) == "This Mac does not support force discharge.")

        // 3. Not plugged in -> "전원 어댑터가 연결되어 있어야 방전할 수 있습니다." / "Connect power adapter to start discharge."
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: false,
            currentSoC: 80,
            targetSoC: 70,
            isHardwareSupported: true,
            isToggleEnabled: true,
            locale: ko
        ) == "전원 어댑터가 연결되어 있어야 방전할 수 있습니다.")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: false,
            currentSoC: 80,
            targetSoC: 70,
            isHardwareSupported: true,
            isToggleEnabled: true,
            locale: en
        ) == "Connect power adapter to start discharge.")

        // 4. currentSoC <= targetSoC -> "현재 배터리 잔량이 목표 잔량 이하입니다." / "Battery level is already at or below target."
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 70,
            targetSoC: 70,
            isHardwareSupported: true,
            isToggleEnabled: true,
            locale: ko
        ) == "현재 배터리 잔량이 목표 잔량 이하입니다.")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 60,
            targetSoC: 70,
            isHardwareSupported: true,
            isToggleEnabled: true,
            locale: ko
        ) == "현재 배터리 잔량이 목표 잔량 이하입니다.")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 70,
            targetSoC: 70,
            isHardwareSupported: true,
            isToggleEnabled: true,
            locale: en
        ) == "Battery level is already at or below target.")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 60,
            targetSoC: 70,
            isHardwareSupported: true,
            isToggleEnabled: true,
            locale: en
        ) == "Battery level is already at or below target.")
    }

    /// 강제 방전 레지스터의 유무는 충전 제어와 다른 축이다. 나머지 조건이 전부 맞아도 이쪽이
    /// 막히면 방전은 시작되지 않는다. `nil`(구버전 도우미)은 호출부가 "모름 = 지원"으로 접어
    /// 넘기므로, 순수 함수는 `false`만 미지원으로 취급한다.
    @Test func manualDischargeDisabledReasonReportsUnsupportedDischargeHardware() {
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 80,
            targetSoC: 70,
            isHardwareSupported: true,
            isDischargeHardwareSupported: false,
            isToggleEnabled: true,
            locale: ko
        ) == "이 Mac은 강제 방전을 지원하지 않습니다.")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 80,
            targetSoC: 70,
            isHardwareSupported: true,
            isDischargeHardwareSupported: false,
            isToggleEnabled: true,
            locale: en
        ) == "This Mac does not support force discharge.")

        // 충전 제어 자체가 막혀 있으면 그쪽 사유가 먼저다 — 사용자가 손댈 수 있는 축이니까.
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 80,
            targetSoC: 70,
            isHardwareSupported: false,
            isDischargeHardwareSupported: false,
            isToggleEnabled: true,
            locale: ko
        ) == "이 Mac은 충전 제어를 지원하지 않습니다")

        // 방전 하드웨어가 없으면 어댑터 미연결·목표 미달보다 이쪽이 먼저 보고된다.
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: false,
            currentSoC: 60,
            targetSoC: 70,
            isHardwareSupported: true,
            isDischargeHardwareSupported: false,
            isToggleEnabled: true,
            locale: ko
        ) == "이 Mac은 강제 방전을 지원하지 않습니다.")

        // 지원하는 Mac은 종전과 동일하게 통과한다 (기본값도 마찬가지).
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 80,
            targetSoC: 70,
            isHardwareSupported: true,
            isDischargeHardwareSupported: true,
            isToggleEnabled: true,
            locale: ko
        ) == nil)
    }

    /// 버튼의 활성 여부와 화면에 뜨는 사유가 갈라지지 않아야 한다.
    @Test func isManualDischargeActionableMirrorsDisabledReason() {
        let cases: [(Bool, Int, Int, Bool, Bool, Bool)] = [
            (true, 80, 70, true, true, true),
            (true, 80, 70, true, false, true),
            (true, 80, 70, false, true, true),
            (true, 80, 70, true, true, false),
            (false, 80, 70, true, true, true),
            (true, 70, 70, true, true, true),
            (true, 100, 99, true, true, true),
            (true, 100, 100, true, true, true),
        ]
        for (plugged, soc, target, hw, dischargeHW, toggle) in cases {
            let reason = BatterySectionPresentation.manualDischargeDisabledReason(
                isPluggedIn: plugged,
                currentSoC: soc,
                targetSoC: target,
                isHardwareSupported: hw,
                isDischargeHardwareSupported: dischargeHW,
                isToggleEnabled: toggle,
                locale: ko)
            let actionable = BatterySectionPresentation.isManualDischargeActionable(
                isPluggedIn: plugged,
                currentSoC: soc,
                targetSoC: target,
                isHardwareSupported: hw,
                isDischargeHardwareSupported: dischargeHW,
                isToggleEnabled: toggle)
            #expect(actionable == (reason == nil))
        }
    }

    /// 목표 100%는 `currentSoC > target`을 만족시킬 수 없어 컨트롤을 영구히 죽인다.
    @Test func clampedManualDischargeTargetKeepsTheControlReachable() {
        #expect(BatterySectionPresentation.manualDischargeTargetRange == 50...99)
        #expect(BatterySectionPresentation.clampedManualDischargeTarget(100) == 99)
        #expect(BatterySectionPresentation.clampedManualDischargeTarget(120) == 99)
        #expect(BatterySectionPresentation.clampedManualDischargeTarget(80) == 80)
        #expect(BatterySectionPresentation.clampedManualDischargeTarget(50) == 50)
        #expect(BatterySectionPresentation.clampedManualDischargeTarget(0) == 50)
        #expect(BatterySectionPresentation.clampedManualDischargeTarget(
            Defaults.batteryManualDischargeTarget) == Defaults.batteryManualDischargeTarget)

        // 클램프를 거치면 만충 상태에서 방전을 시작할 수 있다. 거치지 않으면 못 한다.
        #expect(BatterySectionPresentation.isManualDischargeActionable(
            isPluggedIn: true, currentSoC: 100, targetSoC: 100) == false)
        #expect(BatterySectionPresentation.isManualDischargeActionable(
            isPluggedIn: true,
            currentSoC: 100,
            targetSoC: BatterySectionPresentation.clampedManualDischargeTarget(100)) == true)
    }
}


