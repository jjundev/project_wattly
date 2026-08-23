import Testing
import Foundation
@testable import Wattly

@Suite struct BatterySectionPresentationTests {

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
                                                     mode: .unavailable, detail: "도우미에 연결되지 않음")
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
                                                 mode: .unavailable, detail: "무시되어야 하는 문구")
        #expect(s == .init(dot: .faint, text: BatterySectionPresentation.disabledStatusText))
    }

    @Test func offAndChargingPassesTheDaemonsDetailThrough() {
        // 정상적으로 꺼진 상태. 데몬이 이미 같은 뜻의 문구를 돌려주므로 상수로 다시 쓰지 않고
        // 그대로 통과시킨다 — 상수를 또 쓰면 두 곳이 조용히 어긋날 수 있다.
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                 mode: .charging, detail: "충전 제한 비활성화됨")
        #expect(s == .init(dot: .faint, text: "충전 제한 비활성화됨"))
    }

    @Test func offAndUnsupportedSurfacesTheActionableFailure() {
        // 토글을 껐는데 해제 SMC 쓰기가 실패해 하드웨어가 아직 충전을 막고 있는 상태
        // (`hasActionableFailure`의 `isCurrentlyInhibited` 분기). 회색 점 + 상수로 덮으면 충전이
        // 멈춘 사실을 감추게 되므로, 주황 점과 함께 사용자가 실제로 할 수 있는 복구 안내를 보여준다.
        let s = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .unsupported,
            detail: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)")
        #expect(s == .init(dot: .orange, text: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)"))
    }

    @Test func offAndInhibitedSurfacesTheDaemonsDetail() {
        // 꺼짐 + 여전히 억제 중. 아직 해제 쓰기가 반영되지 않은 과도기라도 회색 상수로 덮지 않고
        // 데몬의 실제 문구를 보여준다.
        let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                 mode: .inhibited, detail: "데몬 문구")
        #expect(s == .init(dot: .orange, text: "데몬 문구"))
    }

    @Test func onStateMapsModeToDotAndPassesDetailThrough() {
        let cases: [(BatteryControlServiceMode, BatterySectionPresentation.Dot)] = [
            (.inhibited, .orange),
            (.charging, .green),
            (.unavailable, .red),
            (.unsupported, .faint),
        ]
        for (mode, dot) in cases {
            let s = BatterySectionPresentation.status(isLimitOn: true, isInstalling: false,
                                                     mode: mode, detail: "데몬 문구")
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

    @Test func pollingRunsOnlyWhileTheLimitIsOn() {
        // 꺼짐 상태의 문구는 상수라 폴링해도 바뀌지 않는다. 폴링 한 번은 데몬의 IOKit 전원 소스
        // 읽기를 유발하므로, 바뀌지 않을 값을 위해 돌리지 않는다.
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: true) == true)
        #expect(BatterySectionPresentation.shouldPollStatus(isLimitOn: false) == false)
    }
}
