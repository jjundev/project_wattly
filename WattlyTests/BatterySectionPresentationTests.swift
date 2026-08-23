import Testing
import Foundation
@testable import Wattly

@Suite struct BatterySectionPresentationTests {

    private let en = Locale(identifier: "en")
    private let ko = Locale(identifier: "ko")

    // MARK: - 하위 항목 노출

    @Test func detailsAreVisibleWhenHardwareSupportIsTrueOrUnknown() {
        // nil = 도우미가 아직 답하지 않았거나 구버전이라 말해줄 수 없는 상태.
        // "모른다"를 "불가능하다"로 취급하면 정상 Mac에서 UI가 사라진다.
        #expect(BatterySectionPresentation.areDetailsVisible(isHardwareSupported: true) == true)
        #expect(BatterySectionPresentation.areDetailsVisible(isHardwareSupported: nil) == true)
    }

    @Test func detailsAreHiddenOnlyOnAnExplicitNo() {
        #expect(BatterySectionPresentation.areDetailsVisible(isHardwareSupported: false) == false)
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
            #expect(s == .init(dot: .orange, text: "도우미 설치 중…"))
        }
    }

    // 꺼짐 상태는 균일하지 않다 — `FanControlShared/BatteryControlEngine.swift`의
    // `hasActionableFailure`(`lastWriteFailed && (config.enabled || isCurrentlyInhibited)`)를 보면,
    // 토글을 끈 뒤에도 `isCurrentlyInhibited` 때문에 실패가 계속 "말이 되는" 상태로 남을 수 있다.
    // 그 경우 데몬은 `.unsupported` 모드 + "충전을 다시 시작하지 못했습니다" 같은 사용자가 실제로
    // 취할 수 있는 복구 안내를 돌려준다. 이 문구를 상수로 덮으면 충전이 멈춘 Mac을 두고 "정상적으로
    // 꺼졌다"고 거짓말하는 셈이 되고, `shouldPollStatus(isLimitOn: false) == false`라 다음 폴링이
    // 없으니 절대 스스로 바로잡히지 않는다.

    @Test func offAndUnavailableShowsTheFaintConstant() {
        // 도우미가 아예 없는 것은 사용자가 끈 기능과 무관한 사실이다. 빨간 "도우미에 연결되지 않음"을
        // 여기 띄우면 고장으로 읽히므로, 이 한 가지 모드에서만 데몬의 detail을 상수로 덮는다.
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                 mode: .unavailable,
                                                 reason: nil, detail: "무시되어야 하는 문구",
                                                 locale: ko)
        #expect(s == .init(dot: .faint, text: BatterySectionPresentation.disabledStatusText(locale: ko)))
    }

    @Test func offAndChargingPassesTheDaemonsDetailThrough() {
        // 정상적으로 꺼진 상태. 데몬이 이미 같은 뜻의 문구를 돌려주므로 상수로 다시 쓰지 않고
        // 그대로 통과시킨다 — 상수를 또 쓰면 두 곳이 조용히 어긋날 수 있다.
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                 mode: .charging,
                                                 reason: nil, detail: "충전 제한 비활성화됨",
                                                 locale: ko)
        #expect(s == .init(dot: .faint, text: "충전 제한 비활성화됨"))
    }

    @Test func offAndUnsupportedSurfacesTheActionableFailure() {
        // 토글을 껐는데 해제 SMC 쓰기가 실패해 하드웨어가 아직 충전을 막고 있는 상태
        // (`hasActionableFailure`의 `isCurrentlyInhibited` 분기). 회색 점 + 상수로 덮으면 충전이
        // 멈춘 사실을 감추게 되므로, 주황 점과 함께 사용자가 실제로 할 수 있는 복구 안내를 보여준다.
        let s = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .unsupported,
            reason: nil, detail: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)",
            locale: ko)
        #expect(s == .init(dot: .orange, text: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)"))
    }

    @Test func offAndInhibitedSurfacesTheDaemonsDetail() {
        // 꺼짐 + 여전히 억제 중. 아직 해제 쓰기가 반영되지 않은 과도기라도 회색 상수로 덮지 않고
        // 데몬의 실제 문구를 보여준다.
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                 mode: .inhibited,
                                                 reason: nil, detail: "데몬 문구",
                                                 locale: ko)
        #expect(s == .init(dot: .orange, text: "데몬 문구"))
    }

    @Test func onStateMapsModeToDotAndPassesDetailThrough() {
        let cases: [(BatteryControlServiceMode, BatterySectionPresentation.Dot)] = [
            (.inhibited, .orange),
            (.charging, .green),
            (.unavailable, .red),
            // 켜짐 + `.unsupported`는 이 줄이 보이는 한(즉 `areDetailsVisible`을 통과한 한) 등록 자체가
            // 없는 Mac일 수 없다 — 그런 Mac은 이 행을 아예 그리지 않는다. 그래서 여기서는 항상 실제
            // 실패("이 Mac에서 충전 제어를 적용하지 못했습니다")이고, 가장 조용한 점(`.faint`)이 아니라
            // 꺼짐 상태의 같은 모드와 일치하는 주황 점을 받는다.
            (.unsupported, .orange),
        ]
        for (mode, dot) in cases {
            let s = BatterySectionPresentation.status(isLimitOn: true, isInstalling: false,
                                                     mode: mode,
                                                     reason: nil, detail: "데몬 문구",
                                                     locale: ko)
            #expect(s == .init(dot: dot, text: "데몬 문구"))
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
        #expect(s == .init(dot: .green, text: "Charging to 80%"))
    }

    @Test func installingTextIsLocalized() {
        let s = BatterySectionPresentation.status(isLimitOn: true, isInstalling: true,
                                                  mode: .unavailable, reason: nil, detail: "",
                                                  locale: en)
        #expect(s == .init(dot: .orange, text: "Installing helper…"))
    }

    /// 도우미가 없는데 기능도 꺼져 있으면 고장이 아니다 — 그 대체 문구도 번역돼야 한다.
    @Test func disabledSubstituteTextIsLocalized() {
        #expect(BatterySectionPresentation.disabledStatusText(locale: en) == "Charge limit off")
        #expect(BatterySectionPresentation.disabledStatusText(locale: ko) == "충전 제한 비활성화됨")

        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                  mode: .unavailable,
                                                  reason: nil, detail: "도우미에 연결되지 않음",
                                                  locale: en)
        #expect(s == .init(dot: .faint, text: "Charge limit off"))
    }

    /// 껐는데 하드웨어가 아직 물고 있는 상태. 회복 안내가 사라지지도, 한국어로 남지도 않아야 한다.
    @Test func stuckAfterTurningOffStaysLoudAndTranslated() {
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                  mode: .unsupported,
                                                  reason: .init(kind: .releaseFailed),
                                                  detail: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)",
                                                  locale: en)
        #expect(s == .init(dot: .orange,
                           text: "Could not resume charging (try reconnecting the power adapter)"))
    }

    /// 한도 선택기의 사유는 **카탈로그 키**로 남는다. 뷰가 `LocalizedStringKey`로 푼다.
    @Test func limitPickerReasonStaysAKey() {
        #expect(BatterySectionPresentation.limitPickerDisabledReason(isLimitOn: false)
                == "충전 제한을 켜면 한도를 조절할 수 있습니다.")
    }
}
