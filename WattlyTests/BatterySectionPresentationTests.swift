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

    @Test func offStateIsAlwaysGreyAndConstant() {
        // 데몬이 꺼짐 상태에서 돌려주는 문구와 같은 상수. 도우미가 없어서 .unavailable(빨강)이
        // 들어와도 사용자가 일부러 끈 기능에 경고를 띄우지 않는다.
        let modes: [BatteryControlServiceMode] = [.unavailable, .charging, .inhibited, .unsupported]
        for mode in modes {
            let s = BatterySectionPresentation.status(isLimitOn: false, isInstalling: false,
                                                     mode: mode, detail: "무시되어야 하는 문구")
            #expect(s == .init(dot: .faint, text: "충전 제한 비활성화됨"))
        }
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
