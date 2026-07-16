import Foundation

/// "기본값으로 되돌리기" (issue 13 §2). One place that writes EVERY persisted key back to
/// its `Defaults` value, so reset can never drift from the `@AppStorage` initial values
/// (both read `Defaults` — Settings.swift). Synchronous and `UserDefaults`-injected so the
/// whole thing is unit-testable; direct `set` triggers KVO, so live `@AppStorage` views
/// (popover + settings) re-render immediately.
///
/// The login re-sync reuses the toggle's error-reverting path (`LoginItemControlling`),
/// not a separate fire-and-forget call (grill F6) — and is best-effort: the mirror is
/// already written to `Defaults.loginItem`, so a failed `register()` just leaves the real
/// service untouched (verifiable only in a signed build, 가정 B).
enum SettingsReset {
    static func applyDefaults(into defaults: UserDefaults = .standard,
                              login: LoginItemControlling? = nil) {
        defaults.set(Defaults.theme.rawValue, forKey: StorageKey.theme)
        defaults.set(Defaults.pollInterval.rawValue, forKey: StorageKey.pollInterval)
        defaults.set(Defaults.powerMode.rawValue, forKey: StorageKey.powerMode)
        defaults.set(Defaults.panelMode.rawValue, forKey: StorageKey.panelMode)
        defaults.set(Defaults.heroMetric.rawValue, forKey: StorageKey.heroMetric)
        defaults.set(Defaults.menubarTextEnabled, forKey: StorageKey.menubarTextEnabled)
        defaults.set(Defaults.powerSmoothed, forKey: StorageKey.powerSmoothed)
        defaults.set(Defaults.cardOrder.rawValue, forKey: StorageKey.cardOrder)
        defaults.set(Defaults.thresholds.rawValue, forKey: StorageKey.thresholds)
        defaults.set(Defaults.fanCurve.rawValue, forKey: StorageKey.fanCurve)
        defaults.set(Defaults.fanControlEnabled, forKey: StorageKey.fanControlEnabled)
        defaults.set("", forKey: StorageKey.expandedCards)        // collapse all cards (가정 C)
        defaults.set(Defaults.loginItem, forKey: StorageKey.loginItem)

        // Iterate allCases so every card's menu key is written, including `.battery` (a real
        // menu chip now, default off — see Defaults.menuMetrics).
        for card in CardKind.allCases {
            defaults.set(Defaults.show[card] ?? true, forKey: StorageKey.show(card))
            defaults.set(Defaults.menuMetrics[card] ?? false, forKey: StorageKey.menu(card))
        }
        defaults.set(Defaults.menuMemPressureEnabled, forKey: StorageKey.menuMemPressure)
        for prefix in Defaults.menuCoreClockEnabled.keys {
            defaults.set(Defaults.menuCoreClockEnabled[prefix] ?? false, forKey: StorageKey.menuCoreClock(prefix))
        }

        // Re-sync the real login item to the default (ON). Best-effort.
        try? login?.setEnabled(Defaults.loginItem)
    }
}
