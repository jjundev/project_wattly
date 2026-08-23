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
    /// (`.charging`)에서는 데몬이 이미 같은 사유를 돌려주지만, 그 값 자체는 그대로 통과시키므로
    /// 여기 문구와 반드시 같게 유지해야 하는 것은 아니다.
    static func disabledStatusText(locale: Locale) -> String {
        BatteryStatusText.text(reason: .init(kind: .limitDisabled), detail: "", locale: locale)
    }

    /// 하위 항목(한도 선택기 · 상태 줄 · 안내 배너)을 그릴지 여부.
    ///
    /// 명시적인 `false`만 숨긴다. `nil`은 "도우미가 아직 답하지 않았다"이며, 답이 없다는 이유로
    /// Mac을 불가능하다고 단정하면 정상 하드웨어에서 UI가 사라진다.
    static func areDetailsVisible(isHardwareSupported: Bool?) -> Bool {
        isHardwareSupported != false
    }

    /// 토글을 조작할 수 있는지.
    ///
    /// 불가능한 하드웨어에서는 켤 수 없다. 그러나 **이미 켜져 있는 값은 끌 수 있어야 한다.** 충전
    /// 제어 레지스터는 기종이 아니라 펌웨어를 따라가므로(`BatteryControlKeys` 참고), 오늘 잘 쓰던
    /// Mac이 macOS 업데이트 한 번으로 지원 대상에서 빠질 수 있다. 그때 저장된 `true`는 그대로 남아
    /// 토글은 켜짐으로 표시된 채 조작 불가가 되고, 사용자에게는 전체 설정 초기화 말고 빠져나갈
    /// 길이 없어진다.
    ///
    /// 렌더링이 저장값을 대신 꺼주지 않는 것은 의도다(`SettingsBatterySection` 상단 주석): 같은
    /// 환경설정이 이 기능을 지원하는 Mac에 도달하는 순간 그 값은 틀린 값이 된다. 그래서 끄는 행위는
    /// 사용자에게 남기고, 이 함수는 그 길만 열어 둔다.
    static func isToggleEnabled(isHardwareSupported: Bool?, isLimitOn: Bool) -> Bool {
        areDetailsVisible(isHardwareSupported: isHardwareSupported) || isLimitOn
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
                       reason: BatteryControlStatusReason?,
                       detail: String,
                       locale: Locale) -> Status {
        // 데몬의 사유/문장을 사용자 언어로 푼 것. 아래 모든 분기가 이 값을 쓴다.
        let resolved = BatteryStatusText.text(reason: reason, detail: detail, locale: locale)

        if isInstalling {
            return Status(dot: .orange, text: String(localized: "도우미 설치 중…", locale: locale))
        }
        if !isLimitOn {
            switch mode {
            case .unavailable:
                // 도우미가 없다는 사실은 사용자가 일부러 끈 기능과 무관하다. 빨간 점 +
                // "도우미에 연결되지 않음"을 여기 띄우면 고장으로 읽힌다.
                return Status(dot: .faint, text: disabledStatusText(locale: locale))
            case .charging:
                // 정상적으로 꺼진 상태. 데몬의 사유가 이미 `limitDisabled`이므로 그대로 통과시킨다.
                return Status(dot: .faint, text: resolved)
            case .inhibited, .unsupported:
                // 껐는데 하드웨어가 아직 물고 있거나 해제 쓰기가 실패한 상태. 회색 점 + "비활성화됨"으로
                // 덮으면 충전을 멈춘 Mac을 두고 "정상적으로 꺼졌다"고 단언하는 셈이 된다.
                // 이때 사유는 대개 `releaseFailed`이지만 유일한 경우는 아니다 — `FanControlDaemon`의
                // `sampleBatteryAndEvaluate`는 전원 소스를 아예 읽지 못하면 `isHardwareSupported`가
                // `true`인 채로도 `.unsupported` + `powerSourceUnreadable`을 내보내며, 그 상태 역시
                // `areDetailsVisible`을 통과해 여기로 온다. 어느 쪽이든 데몬이 실제로 정한 문구를
                // 그대로 보여주는 것이 중요하다 — 그게 사용자가 할 수 있는 유일한 복구 안내다.
                return Status(dot: .orange, text: resolved)
            }
        }
        switch mode {
        case .inhibited: return Status(dot: .orange, text: resolved)
        case .charging: return Status(dot: .green, text: resolved)
        case .unavailable: return Status(dot: .red, text: resolved)
        case .unsupported:
            // `.faint`가 아니라 `.orange`다: 켜짐 + 이 줄이 보이는 상태(`areDetailsVisible`을 통과한
            // 상태)에서 `.unsupported`는 등록 자체가 없는 Mac일 수 없다 — 그런 Mac은 이 행을 아예
            // 그리지 않는다. 그래서 여기서는 항상 실제 실패("이 Mac에서 충전 제어를 적용하지
            // 못했습니다")이고, 꺼짐 상태의 같은 모드와 마찬가지로 조치가 필요하다는 뜻의 점을 받아야
            // 한다. 가장 조용한 점(`.faint`)에 실패를 숨기는 것은 잘못이다.
            return Status(dot: .orange, text: resolved)
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
    /// 도우미가 "이 Mac은 불가능하다"고 명시적으로 답했다면 다시 묻지 않는다. 그 답은 영구적인
    /// 사실이라 재질문으로 바뀔 수 없고, 그 상태에서는 `areDetailsVisible == false`라 갱신할 화면
    /// 자체가 없다. 이 확인이 없으면 제한이 켜진 채로 지원되지 않는 Mac에 남은 사용자는 5초마다
    /// XPC 왕복과 루트 데몬의 전원 소스 읽기를 영원히 유발한다.
    ///
    /// 켜져 있으면 항상 읽는다 — 관심 있는 순간(한도 도달)이 창을 연 뒤 몇 분 뒤에 온다.
    ///
    /// 꺼져 있을 때는 문구가 바뀔 수 있는 상태에서만 읽는다. `.charging`은 정상적으로 꺼진 상태라
    /// 문구가 상수이고, `.unavailable`은 도우미가 없어 다시 물어봐야 답할 주체가 없다 — 둘 다
    /// 폴링해봐야 `batteryStatus` XPC → 데몬의 IOKit 전원 소스 읽기만 유발한다. 반대로
    /// `.inhibited`/`.unsupported`는 "껐는데 하드웨어가 아직 물고 있다"이고, 데몬이 스스로
    /// 재시도해 풀어내는 상태다. 여기서 읽지 않으면 사용자가 안내대로 어댑터를 다시 꽂아 실제로
    /// 복구된 뒤에도 화면은 실패 문구에 멈춰 있게 된다. `.unsupported`가 두 가지(레지스터 없음 /
    /// 쓰기 실패)를 함께 뜻하기 때문에, 영구적인 쪽을 걸러내는 일은 위의 `isHardwareSupported`
    /// 확인이 맡는다.
    static func shouldPollStatus(isLimitOn: Bool,
                                 mode: BatteryControlServiceMode,
                                 isHardwareSupported: Bool?) -> Bool {
        if isHardwareSupported == false { return false }
        if isLimitOn { return true }
        switch mode {
        case .inhibited, .unsupported: return true
        case .charging, .unavailable: return false
        }
    }
}
