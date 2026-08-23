import Foundation

/// 설정 › 배터리 충전 제어 섹션의 순수 표시 판단. SwiftUI도 I/O도 없다 —
/// `CardPresentation` / `Accessibility` / `BatteryControlPolicy`와 같은 방식으로,
/// 뷰가 내리던 결정을 테이블 테스트가 가능한 함수로 옮겨둔 것이다.
///
/// 배경: 예전에는 하위 항목 전체가 `batteryLimitEnabled` 뒤에 숨어 있어서, 토글을 켜기 전에는
/// 이 기능이 무엇을 하는지 볼 수 없었다. 이제 하위 항목은 항상 보이고, **조작할 수 없는 부분만**
/// 비활성으로 표시한다.
enum BatterySectionPresentation {

    /// 상태 점의 의미. 색이 아니라 의미를 돌려주므로 테스트가 `Color`에 의존하지 않는다.
    enum Dot: String, Equatable {
        case green, orange, red, faint
    }

    struct Status: Equatable {
        let dot: Dot
        let text: String

        init(dot: Dot, text: String) {
            self.dot = dot
            self.text = text
        }
    }

    /// 꺼짐 상태에서 상태 줄에 고정으로 띄우는 문구. 데몬이 `config.enabled == false`일 때
    /// 돌려주는 `detail`과 같은 문자열이다 (`BatteryControlEngine.detailText`).
    static let disabledStatusText = "충전 제한 비활성화됨"

    /// 하위 항목(한도 선택기 · 상태 줄 · 안내 배너)을 그릴지 여부.
    ///
    /// 명시적인 `false`만 숨긴다. `nil`은 "도우미가 아직 답하지 않았다"이며, 답이 없다는 이유로
    /// Mac을 불가능하다고 단정하면 정상 하드웨어에서 UI가 사라진다.
    static func areDetailsVisible(isHardwareSupported: Bool?) -> Bool {
        isHardwareSupported != false
    }

    /// 한도 선택기를 조작할 수 있는지. 꺼짐 상태에서는 보이되 만질 수 없다.
    static func isLimitPickerEnabled(isLimitOn: Bool) -> Bool {
        isLimitOn
    }

    /// 비활성 상태의 사유 문구 (VoiceOver 힌트로도 쓰인다). 활성일 때는 `nil`.
    static func limitPickerDisabledReason(isLimitOn: Bool) -> String? {
        isLimitOn ? nil : "충전 제한을 켜면 한도를 조절할 수 있습니다."
    }

    /// 상태 점 + 문구.
    ///
    /// 순서가 의미를 갖는다. 설치 중이 가장 위 — 설치 중에는 토글이 이미 ON이지만 그 진행을
    /// 덮어쓰면 안 된다. 그다음이 꺼짐: 꺼짐 상태에서는 모드를 아예 보지 않고 회색 점 + 고정
    /// 문구를 쓴다. 도우미가 없을 때 들어오는 `.unavailable`(빨간 점 + "도우미에 연결되지 않음")을
    /// 사용자가 **일부러 끈** 기능 옆에 띄우면 고장으로 읽히기 때문이다.
    static func status(isLimitOn: Bool,
                       isInstalling: Bool,
                       mode: BatteryControlServiceMode,
                       detail: String) -> Status {
        if isInstalling { return Status(dot: .orange, text: "도우미 설치 중…") }
        if !isLimitOn { return Status(dot: .faint, text: disabledStatusText) }
        switch mode {
        case .inhibited: return Status(dot: .orange, text: detail)
        case .charging: return Status(dot: .green, text: detail)
        case .unavailable: return Status(dot: .red, text: detail)
        case .unsupported: return Status(dot: .faint, text: detail)
        }
    }

    /// "도우미 설치" 복구 버튼을 띄울지 여부. 이 버튼은 관리자 암호 프롬프트를 띄우므로,
    /// 사용자가 켜지도 않은 기능 때문에 암호를 묻지 않는다. 토글을 켜는 경로가 이미 설치를
    /// 수행하니 잃는 기능도 없다.
    static func isInstallButtonVisible(isLimitOn: Bool, mode: BatteryControlServiceMode) -> Bool {
        isLimitOn && mode == .unavailable
    }

    /// 설정 화면이 상태를 주기적으로 다시 읽어야 하는지.
    ///
    /// 꺼짐 상태의 문구는 상수라 폴링해도 절대 바뀌지 않는다. 반면 폴링 한 번은
    /// `batteryStatus` XPC → 데몬의 `sampleBatteryAndEvaluate(force: true)` → IOKit 전원 소스
    /// 읽기를 유발한다. 바뀌지 않을 값을 위해 그 비용을 낼 이유가 없다.
    static func shouldPollStatus(isLimitOn: Bool) -> Bool {
        isLimitOn
    }
}
