import Foundation

/// 설정 › 배터리 충전 제어 섹션의 순수 표시 판단. SwiftUI도 I/O도 없다 —
/// `CardPresentation` / `Accessibility` / `BatteryControlPolicy`와 같은 방식으로,
/// 뷰가 내리던 결정을 테이블 테스트가 가능한 함수로 옮겨둔 것이다.
///
/// 배경: 예전에는 하위 항목 전체가 `batteryLimitEnabled` 뒤에 숨어 있어서, 토글을 켜기 전에는
/// 이 기능이 무엇을 하는지 볼 수 없었다. 이제 하위 항목은 항상 보이고, **조작할 수 없는 부분만**
/// 비활성으로 표시한다.
enum BatterySectionPresentation {

    enum Tone: String, Equatable {
        case green, orange, red, faint
    }

    enum Indicator: String, Equatable, CaseIterable {
        case installing
        case stale
        case inactive
        case chargingToLimit
        case holdingAtLimit
        case onBatteryPower
        case sailing
        case heatProtection
        case topUp
        case discharging
        case calibration
        case unavailable
        case hardwareUnsupported
        case failure

        var symbolName: String {
            switch self {
            case .installing: return "arrow.down.circle.fill"
            case .stale: return "clock.fill"
            case .inactive, .holdingAtLimit: return "pause.circle.fill"
            case .chargingToLimit: return "bolt.circle.fill"
            case .onBatteryPower: return "battery.100"
            case .sailing: return "arrow.left.and.right.circle.fill"
            case .heatProtection: return "thermometer"
            case .topUp: return "arrow.up.circle.fill"
            case .discharging: return "arrow.down.circle.fill"
            case .calibration: return "arrow.triangle.2.circlepath"
            case .hardwareUnsupported: return "nosign"
            case .unavailable, .failure: return "exclamationmark.triangle.fill"
            }
        }

        var tone: Tone {
            switch self {
            case .inactive, .stale: return .faint
            case .chargingToLimit, .onBatteryPower, .topUp: return .green
            case .installing, .holdingAtLimit, .sailing, .heatProtection,
                 .discharging, .calibration, .failure:
                return .orange
            case .unavailable, .hardwareUnsupported: return .red
            }
        }
    }

    struct Status: Equatable {
        let indicator: Indicator
        let text: String
    }

    static let staleAfter = 15.0

    /// 구버전 도우미가 activity와 인식 가능한 reason을 모두 보내지 않은 경우에만 쓰는 꺼짐 문구.
    static func disabledStatusText(locale: Locale) -> String {
        BatteryStatusText.text(reason: .init(kind: .limitDisabled), detail: "", locale: locale)
    }

    /// 한도 선택기와 안내 배너를 그릴지 여부. 상태 줄은 항상 보인다.
    ///
    /// 명시적인 `false`만 숨긴다. `nil`은 "도우미가 아직 답하지 않았다"이며, 답이 없다는 이유로
    /// Mac을 불가능하다고 단정하면 정상 하드웨어에서 UI가 사라진다.
    static func showsConfigurationControls(isHardwareSupported: Bool?) -> Bool {
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

    /// 상태 아이콘 + 문구. 설치 → 오류/미지원 → stale → 검증된 activity → 로컬 fallback 순이다.
    static func status(isLimitOn: Bool,
                       isInstalling: Bool,
                       mode: BatteryControlServiceMode,
                       reason: BatteryControlStatusReason?,
                       detail: String,
                       locale: Locale,
                       activity: BatteryControlActivity? = nil,
                       updatedAt: TimeInterval = 0,
                       now: TimeInterval = 0) -> Status {
        let effectiveReason = BatteryStatusText.resolve(reason: reason, detail: detail)
        let resolvedText = BatteryStatusText.text(resolvedReason: effectiveReason,
                                                  detail: detail,
                                                  locale: locale)

        if isInstalling {
            return Status(indicator: .installing,
                          text: String(localized: "도우미 설치 중…", locale: locale))
        }

        // Connection and hardware errors outrank freshness, verified activity, and the local
        // toggle. `.unavailable` is a current local connection result, not an old remote sample.
        switch mode {
        case .unavailable:
            return Status(indicator: .unavailable, text: resolvedText)
        case .unsupported:
            return Status(indicator: effectiveReason?.kind == .hardwareUnsupported
                          ? .hardwareUnsupported : .failure,
                          text: resolvedText)
        case .charging, .inhibited:
            break
        }

        // A zero timestamp is the client's initial state and means "no remote sample". Exactly
        // three polling intervals stays current; only a strictly older sample becomes stale.
        if shouldPollStatus(isLimitOn: isLimitOn, mode: mode),
           updatedAt > 0,
           now >= updatedAt,
           now - updatedAt > staleAfter {
            return Status(indicator: .stale,
                          text: String(localized: "확인 중...", locale: locale))
        }

        if let resolvedActivity = BatteryControlActivity.resolved(explicit: activity,
                                                                  reason: effectiveReason) {
            return Status(indicator: indicator(for: resolvedActivity), text: resolvedText)
        }

        // The local toggle is the least authoritative input. It is used only when an old helper
        // sent neither activity nor a recognized reason and the mode carries no finer meaning.
        if !isLimitOn {
            return Status(indicator: .inactive, text: disabledStatusText(locale: locale))
        }

        return Status(indicator: mode == .inhibited ? .holdingAtLimit : .chargingToLimit,
                      text: resolvedText)
    }

    private static func indicator(for activity: BatteryControlActivity) -> Indicator {
        switch activity {
        case .inactive: return .inactive
        case .chargingToLimit: return .chargingToLimit
        case .holdingAtLimit: return .holdingAtLimit
        case .onBatteryPower: return .onBatteryPower
        case .sailing: return .sailing
        case .heatProtection: return .heatProtection
        case .topUp: return .topUp
        case .discharging: return .discharging
        case .calibration: return .calibration
        case .unrecognized:
            // `BatteryControlActivity.resolved` never returns this. Keep a total switch so a future
            // caller cannot turn an unknown token into a confident normal activity.
            return .failure
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
    /// 켜져 있으면 항상 읽는다 — 관심 있는 순간(한도 도달)이 창을 연 뒤 몇 분 뒤에 온다.
    ///
    /// 꺼져 있을 때는 문구가 바뀔 수 있는 상태에서만 읽는다. `.charging`은 정상적으로 꺼진 상태라
    /// 문구가 상수이고, `.unavailable`은 도우미가 없어 다시 물어봐야 답할 주체가 없다 — 둘 다
    /// 폴링해봐야 `batteryStatus` XPC → 데몬의 IOKit 전원 소스 읽기만 유발한다. 반대로
    /// `.inhibited`/`.unsupported`는 "껐는데 하드웨어가 아직 물고 있다"이고, 데몬이 스스로
    /// 재시도해 풀어내는 상태다. 여기서 읽지 않으면 사용자가 안내대로 어댑터를 다시 꽂아 실제로
    /// 복구된 뒤에도 화면은 실패 문구에 멈춰 있게 된다.
    static func shouldPollStatus(isLimitOn: Bool, mode: BatteryControlServiceMode) -> Bool {
        if isLimitOn { return true }
        switch mode {
        case .inhibited, .unsupported: return true
        case .charging, .unavailable: return false
        }
    }
}
