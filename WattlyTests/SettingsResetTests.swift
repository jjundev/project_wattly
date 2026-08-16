import Testing
import Foundation
@testable import Wattly

/// Pure-seam tests for "기본값으로 되돌리기" (issue 13 §2). `SettingsReset.applyDefaults` writes
/// every persisted key back to its `Defaults` value over an injected `UserDefaults`, and
/// re-syncs the login item through the same error-reverting path as the toggle. No SwiftUI.
/// Each test uses a uniquely-named throwaway suite so parallel runs stay isolated.
struct SettingsResetTests {

    /// Captures the last `setEnabled` call so we can assert reset re-registers the default.
    final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
        var enabled: Bool
        private(set) var lastSet: Bool?
        init(enabled: Bool) { self.enabled = enabled }
        var isEnabled: Bool { enabled }
        func setEnabled(_ e: Bool) throws { lastSet = e; enabled = e }
    }

    /// A throwaway defaults store, uniquely named per test so swift-testing's parallel
    /// execution can't let two tests clobber the same suite.
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "SettingsResetTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func generalSectionContractAndResetOperation() {
        let d = makeDefaults(#function)
        d.set(ThemeMode.light.rawValue, forKey: StorageKey.theme)
        SettingsReset.applyDefaults(into: d, login: nil)
        #expect(d.string(forKey: StorageKey.theme) == Defaults.theme.rawValue)
    }

    @Test func resetRestoresEveryScalarKey() {
        let d = makeDefaults(#function)
        // Dirty every key with a non-default value.
        d.set(ThemeMode.light.rawValue, forKey: StorageKey.theme)
        d.set(PollInterval.s5.rawValue, forKey: StorageKey.pollInterval)
        d.set(PowerMode.performance.rawValue, forKey: StorageKey.powerMode)
        d.set(PanelMode.b.rawValue, forKey: StorageKey.panelMode)
        d.set(CardKind.cpu.rawValue, forKey: StorageKey.heroMetric)
        d.set(false, forKey: StorageKey.menubarTextEnabled)
        d.set(false, forKey: StorageKey.kineticNotchMotionEnabled)
        d.set(KineticNotchSource.compute.rawValue, forKey: StorageKey.kineticNotchSource)
        d.set(KineticNotchSpeed.responsive.rawValue, forKey: StorageKey.kineticNotchSpeed)
        d.set(false, forKey: StorageKey.powerSmoothed)
        d.set(7, forKey: StorageKey.memoryProcessLimit)
        d.set(7, forKey: StorageKey.powerProcessLimit)
        d.set("xyz", forKey: StorageKey.expandedCards)

        SettingsReset.applyDefaults(into: d, login: nil)

        #expect(d.string(forKey: StorageKey.theme) == Defaults.theme.rawValue)
        #expect(d.string(forKey: StorageKey.pollInterval) == Defaults.pollInterval.rawValue)
        #expect(d.string(forKey: StorageKey.powerMode) == PowerMode.eco.rawValue)
        #expect(Defaults.panelMode == .c)
        #expect(PanelMode.c.label == "히어로 + 리스트")
        #expect(d.string(forKey: StorageKey.panelMode) == PanelMode.c.rawValue)
        #expect(d.string(forKey: StorageKey.heroMetric) == Defaults.heroMetric.rawValue)
        #expect(d.bool(forKey: StorageKey.menubarTextEnabled) == Defaults.menubarTextEnabled)
        #expect(d.bool(forKey: StorageKey.kineticNotchMotionEnabled) == Defaults.kineticNotchMotionEnabled)
        #expect(Defaults.kineticNotchSource == .power)
        #expect(d.string(forKey: StorageKey.kineticNotchSource) == KineticNotchSource.power.rawValue)
        #expect(d.string(forKey: StorageKey.kineticNotchSpeed) == Defaults.kineticNotchSpeed.rawValue)
        #expect(d.bool(forKey: StorageKey.powerSmoothed) == Defaults.powerSmoothed)
        #expect(d.object(forKey: StorageKey.memoryProcessLimit) != nil)
        #expect(d.integer(forKey: StorageKey.memoryProcessLimit) == Defaults.memoryProcessLimit)
        #expect(d.object(forKey: StorageKey.powerProcessLimit) != nil)
        #expect(d.integer(forKey: StorageKey.powerProcessLimit) == Defaults.powerProcessLimit)
        #expect(d.string(forKey: StorageKey.expandedCards) == "")          // 가정 C
        // Decode back rather than compare raw strings: CardOrder's CSV is deterministic, but
        // Thresholds serializes a dictionary whose JSON key order is not — compare by value.
        #expect(CardOrder(rawValue: d.string(forKey: StorageKey.cardOrder) ?? "") == Defaults.cardOrder)
        #expect(Thresholds(rawValue: d.string(forKey: StorageKey.thresholds) ?? "") == Defaults.thresholds)
    }

    @Test func resetWritesEveryCardShowAndMenuKey() {
        let d = makeDefaults(#function)
        SettingsReset.applyDefaults(into: d, login: nil)

        for card in CardKind.allCases {
            #expect(d.object(forKey: StorageKey.show(card)) != nil)
            #expect(d.bool(forKey: StorageKey.show(card)) == (Defaults.show[card] ?? true))
            // Every card gets a menu key, including `.battery` (a real menu chip now, default off).
            #expect(d.object(forKey: StorageKey.menu(card)) != nil)
            #expect(d.bool(forKey: StorageKey.menu(card)) == (Defaults.menuMetrics[card] ?? false))
        }
        #expect(d.bool(forKey: StorageKey.menu(.battery)) == false)
    }

    @Test func resetWritesMenuMemPressureKey() {
        let d = makeDefaults(#function)
        d.set(true, forKey: StorageKey.menuMemPressure)

        SettingsReset.applyDefaults(into: d, login: nil)

        #expect(d.bool(forKey: StorageKey.menuMemPressure) == Defaults.menuMemPressureEnabled)
    }

    @Test func resetWritesMenuBatteryTempKey() {
        let d = makeDefaults(#function)
        d.set(true, forKey: StorageKey.menuBatteryTemp)

        SettingsReset.applyDefaults(into: d, login: nil)

        #expect(d.bool(forKey: StorageKey.menuBatteryTemp) == Defaults.menuBatteryTempEnabled)
    }

    @Test func resetWritesEveryCoreClockKey() {
        let d = makeDefaults(#function)
        for prefix in ["S", "P", "E"] { d.set(true, forKey: StorageKey.menuCoreClock(prefix)) }

        SettingsReset.applyDefaults(into: d, login: nil)

        for prefix in ["S", "P", "E"] {
            #expect(d.bool(forKey: StorageKey.menuCoreClock(prefix)) == (Defaults.menuCoreClockEnabled[prefix] ?? false))
        }
    }

    @Test func resetReenablesLoginItem() {
        let d = makeDefaults(#function)
        let login = FakeLoginItem(enabled: false)

        SettingsReset.applyDefaults(into: d, login: login)

        #expect(login.lastSet == Defaults.loginItem)   // default is ON
        #expect(login.isEnabled == Defaults.loginItem)
        #expect(d.bool(forKey: StorageKey.loginItem) == Defaults.loginItem)
    }

    @Test func resetWritesDefaultFanCurve() {
        let defaults = makeDefaults(#function)
        // Pre-dirty the key with a non-default value.
        defaults.set(FanCurve(rpms: Array(repeating: 3000, count: 15)).rawValue, forKey: StorageKey.fanCurve)

        SettingsReset.applyDefaults(into: defaults)

        let raw = defaults.string(forKey: StorageKey.fanCurve)
        #expect(raw == Defaults.fanCurve.rawValue)
        #expect(FanCurve(rawValue: raw ?? "")?.rpms == Defaults.fanCurve.rpms)
    }

    @Test func resetDisablesFanControl() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: StorageKey.fanControlEnabled)

        SettingsReset.applyDefaults(into: defaults)

        #expect(defaults.bool(forKey: StorageKey.fanControlEnabled) == false)
    }

    @Test func resetHidesBatteryEfficiency() {
        let defaults = makeDefaults(#function)
        defaults.set(true, forKey: StorageKey.showBatteryEfficiency)

        SettingsReset.applyDefaults(into: defaults)

        #expect(Defaults.showBatteryEfficiency == false)
        #expect(defaults.object(forKey: StorageKey.showBatteryEfficiency) != nil)
        #expect(defaults.bool(forKey: StorageKey.showBatteryEfficiency) == false)
    }

    @Test func cardVisibilityDefaultsAndMutations() {
        var visibility = CardVisibility()
        #expect(visibility.isShown(.cpu))
        #expect(visibility.isShown(.power))
        #expect(visibility.activeCards.contains(.cpu))
        #expect(visibility.activeCards.contains(.power))

        visibility.setShown(.gpu, false)
        #expect(!visibility.isShown(.gpu))
        #expect(visibility.activeCards.contains(.cpu))
        #expect(!visibility.activeCards.contains(.gpu))

        visibility.setShown(.gpu, true)
        #expect(visibility.isShown(.gpu))
        #expect(visibility.activeCards.contains(.gpu))
    }

    @Test func cardVisibilityUserDefaultsRoundTrip() {
        let d = makeDefaults(#function)
        var visibility = CardVisibility()
        visibility.setShown(.cpu, false)
        visibility.setShown(.power, false)
        visibility.write(to: d)

        let loaded = CardVisibility(userDefaults: d)
        #expect(loaded == visibility)
        #expect(!loaded.isShown(.cpu))
        #expect(!loaded.isShown(.power))
        #expect(loaded.isShown(.gpu))
    }

    @Test func menuBarSelectionDefaultsAndMutations() {
        var selection = MenuBarSelection()
        #expect(!selection.isSelected(.cpu))
        #expect(!selection.isSelected(.gpu))
        #expect(selection.isSelected(.power))
        #expect(!selection.isBatteryTempSelected)
        #expect(!selection.isMemPressureSelected)
        #expect(!selection.isCoreClockSelected("S"))

        #expect(selection.items == [.card(.power)])
        #expect(selection.requiredCards == [.power])

        selection.setSelected(.gpu, true)
        selection.setCoreClockSelected("S", true)
        selection.setMemPressureSelected(true)
        selection.setBatteryTempSelected(true)

        #expect(selection.isSelected(.gpu))
        #expect(selection.isCoreClockSelected("S"))
        #expect(selection.isMemPressureSelected)
        #expect(selection.isBatteryTempSelected)

        #expect(selection.items == [
            .coreClock(prefix: "S"),
            .card(.gpu),
            .card(.power),
            .batteryTemp,
            .memPressure
        ])
        #expect(selection.requiredCards == [.cpu, .gpu, .power, .mem, .battery])
    }

    @Test func menuBarSelectionUserDefaultsRoundTrip() {
        let d = makeDefaults(#function)
        var selection = MenuBarSelection()
        selection.setSelected(.power, false)
        selection.setSelected(.cpu, true)
        selection.setCoreClockSelected("P", true)
        selection.setMemPressureSelected(true)
        selection.write(to: d)

        let loaded = MenuBarSelection(userDefaults: d)
        #expect(loaded == selection)
        #expect(loaded.isSelected(.cpu))
        #expect(!loaded.isSelected(.power))
        #expect(loaded.isCoreClockSelected("P"))
        #expect(loaded.isMemPressureSelected)
        #expect(!loaded.isBatteryTempSelected)
    }

    @Test func layoutSegmentOptionOrdering() {
        #expect(PanelMode.allCases == [.a, .c, .b])
        #expect(PanelMode.allCases.map(\.label) == ["스택 행", "히어로 + 리스트", "카드 그리드"])
    }

    @Test func systemOptionCopyConsistency() {
        #expect(ThemeMode.allCases.map(\.label) == ["라이트", "다크", "시스템"])
    }
}
