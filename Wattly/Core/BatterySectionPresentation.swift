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
    }

    /// 도우미가 없어서 모드가 `.unavailable`일 때만 쓰는 대체 문구. 사용자가 일부러 끈 기능 옆에
    /// "도우미에 연결되지 않음"을 띄우면 고장으로 읽히기 때문이다. 정상적으로 꺼진 상태
    /// (`.charging`)에서는 데몬이 이미 이것과 같은 문자열을 `detail`로 돌려주지만, 그 값 자체는
    /// 그대로 통과시키므로 여기 상수와 반드시 같게 유지해야 하는 것은 아니다.
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
    /// 덮어쓰면 안 된다. 그다음이 꺼짐인데, 꺼짐 상태는 균일하지 않다. `BatteryControlEngine`의
    /// `hasActionableFailure`가 `isCurrentlyInhibited`일 때도 실패를 "말이 되는" 것으로 취급하므로,
    /// 토글을 끈 뒤에도 하드웨어가 아직 충전을 막고 있는 채로 남을 수 있다. 그래서 모드별로 갈린다:
    /// `.unavailable`(도우미 자체가 없음)만 사용자가 일부러 끈 기능과 무관한 사실이라 회색 점 +
    /// 고정 문구로 덮고, 나머지(`.charging`도 포함해)는 데몬의 `detail`을 그대로 보여준다 —
    /// `.inhibited`/`.unsupported`에서는 그게 "충전이 멈췄다"는, 사용자가 실제로 행동할 수 있는
    /// 유일한 안내이기 때문이다.
    static func status(isLimitOn: Bool,
                       isInstalling: Bool,
                       mode: BatteryControlServiceMode,
                       detail: String) -> Status {
        if isInstalling { return Status(dot: .orange, text: "도우미 설치 중…") }
        if !isLimitOn {
            switch mode {
            case .unavailable:
                // 도우미가 없다는 사실은 사용자가 일부러 끈 기능과 무관하다. 빨간 점 +
                // "도우미에 연결되지 않음"을 여기 띄우면 고장으로 읽힌다.
                return Status(dot: .faint, text: disabledStatusText)
            case .charging:
                // 정상적으로 꺼진 상태. 데몬의 `detail`이 이미 `disabledStatusText`와 같은
                // 문자열이므로 그대로 통과시킨다 — 상수를 다시 쓰면 두 곳이 조용히 어긋난다.
                return Status(dot: .faint, text: detail)
            case .inhibited, .unsupported:
                // 껐는데 하드웨어가 아직 물고 있거나 해제 쓰기가 실패한 상태. 회색 점 + "비활성화됨"으로
                // 덮으면 충전을 멈춘 Mac을 두고 "정상적으로 꺼졌다"고 단언하는 셈이 된다.
                // `detail`은 이때 "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)"이며,
                // 그게 사용자가 할 수 있는 유일한 복구 안내다.
                return Status(dot: .orange, text: detail)
            }
        }
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
