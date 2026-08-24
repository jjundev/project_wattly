import Foundation

/// Turns a charge-limit status into text in the user's language.
///
/// This is the app-side half of the split introduced by
/// `FanControlShared/BatteryControlStatusReason.swift`: the root daemon reports *why* the limit is
/// in the state it is in, and this decides *what that says* — the only place that can, since it is
/// the only one of the two processes with resources and a locale.
///
/// Pure and locale-injected, like `CardPresentation` / `Accessibility` / `MenuBarText`, so every
/// language it can produce is reachable from a test rather than only from a running app.
enum BatteryStatusText {

    /// Which reason to believe, given a status that may carry a code, a sentence, or both.
    ///
    /// Order matters. A code from the running helper is authoritative; the sentence is either the
    /// back-compat copy beside it or — on a helper too old to send a code — the only thing there.
    /// `nil` means the text is not ours at all (a macOS XPC error description, say), and the caller
    /// should show it as it stands.
    static func resolve(reason: BatteryControlStatusReason?,
                        detail: String) -> BatteryControlStatusReason? {
        if let reason, reason.kind != .unrecognized { return reason }
        return LegacyBatteryDetail.reason(from: detail)
    }

    static func text(reason: BatteryControlStatusReason?,
                     detail: String,
                     locale: Locale) -> String {
        text(resolvedReason: resolve(reason: reason, detail: detail),
             detail: detail,
             locale: locale)
    }

    /// Renders a reason the caller has already resolved. This keeps presentation code from
    /// independently interpreting the same legacy payload for its icon and its text.
    static func text(resolvedReason: BatteryControlStatusReason?,
                     detail: String,
                     locale: Locale) -> String {
        guard let resolved = resolvedReason else {
            // Not a status of ours. A catalog lookup still gets the app's own `detail` literals
            // translated, and returns anything else — system error text, already localized by
            // macOS — untouched.
            return String(localized: detail, locale: locale)
        }

        // Mirrors `BatteryControlStatusReason.legacyKoreanDetail`, but every arm is a catalog key.
        let target = Int64(resolved.limitPercentage ?? 100)
        switch resolved.kind {
        case .initializing:
            return String(localized: "초기화 중", locale: locale)
        case .powerSourceUnreadable:
            return String(localized: "전원 소스를 읽을 수 없습니다", locale: locale)
        case .hardwareUnsupported:
            return String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: locale)
        case .releaseFailed:
            return String(localized: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)",
                          locale: locale)
        case .applyFailed:
            return String(localized: "이 Mac에서 충전 제어를 적용하지 못했습니다", locale: locale)
        case .inhibitedAtLimit:
            return String(format: String(localized: "충전 제한 %lld%% 도달 (전원 어댑터 바이패스 구동)",
                                         locale: locale),
                          locale: locale, target)
        case .limitDisabled:
            return String(localized: "충전 제한 비활성화됨", locale: locale)
        case .chargingToTarget:
            return String(format: String(localized: "목표치(%lld%%)까지 충전 중", locale: locale),
                          locale: locale, target)
        case .onBatteryPower:
            return String(localized: "배터리 전원으로 구동 중", locale: locale)
        case .sailing:
            let resume = Int64(resolved.resumePercentage ?? max(45, Int(target) - 2))
            return String(format: String(localized: "Sailing 중 (%lld%% 도달 시 재충전)", locale: locale),
                          locale: locale, resume)
        case .heatProtectionActive:
            let tempStr = resolved.currentTemperatureCelsius.map { String(format: "%.1f", $0) } ?? "?"
            let resume = Int64(resolved.resumeTemperatureCelsius ?? 34)
            return String(format: String(localized: "발열 보호 중 (배터리 %@°C, %lld°C 도달 시 재충전)", locale: locale),
                          locale: locale, tempStr, resume)
        case .heatProtectionCooldown:
            let remaining = Int64(resolved.cooldownRemainingSeconds ?? 0)
            return String(format: String(localized: "발열 보호 쿨다운 중 (%lld초 후 충전 재개)", locale: locale),
                          locale: locale, remaining)
        case .batterySensorUnreadable:
            return String(localized: "배터리 온도 센서를 읽을 수 없습니다", locale: locale)
        case .persistenceReadFailed:
            return String(localized: "저장된 충전 정책을 읽지 못해 충전 허용 상태로 복구합니다", locale: locale)
        case .persistenceWriteFailed:
            return String(localized: "충전 정책을 안전하게 저장하지 못했습니다", locale: locale)
        case .policyOwnerMismatch:
            return String(localized: "다른 사용자가 이 Mac의 충전 정책을 관리하고 있습니다", locale: locale)
        case .hardwareReadbackFailed:
            return String(localized: "충전 제어 하드웨어 상태를 확인하지 못했습니다", locale: locale)
        case .unrecognized:
            // `resolve` never returns this, but the switch has to be total. Falling back to the
            // sentence is what the caller would want anyway.
            return String(localized: detail, locale: locale)
        }
    }

    /// The alert body for an install that succeeded while the configuration push did not. The
    /// embedded status goes through `text(reason:detail:locale:)` first, so the sentence is not
    /// half-translated.
    static func installFailureMessage(reason: BatteryControlStatusReason?,
                                      detail: String,
                                      locale: Locale) -> String {
        String(format: String(localized: "도우미는 설치했지만 충전 제한을 적용하지 못했습니다: %@",
                              locale: locale),
               locale: locale,
               text(reason: reason, detail: detail, locale: locale))
    }
}
