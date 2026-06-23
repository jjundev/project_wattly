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

    @Test func resetRestoresEveryScalarKey() {
        let d = makeDefaults(#function)
        // Dirty every key with a non-default value.
        d.set(ThemeMode.light.rawValue, forKey: StorageKey.theme)
        d.set(PollInterval.s5.rawValue, forKey: StorageKey.pollInterval)
        d.set(PanelMode.b.rawValue, forKey: StorageKey.panelMode)
        d.set(false, forKey: StorageKey.menubarTextEnabled)
        d.set(false, forKey: StorageKey.powerSmoothed)
        d.set("xyz", forKey: StorageKey.expandedCards)

        SettingsReset.applyDefaults(into: d, login: nil)

        #expect(d.string(forKey: StorageKey.theme) == Defaults.theme.rawValue)
        #expect(d.string(forKey: StorageKey.pollInterval) == Defaults.pollInterval.rawValue)
        #expect(d.string(forKey: StorageKey.panelMode) == Defaults.panelMode.rawValue)
        #expect(d.bool(forKey: StorageKey.menubarTextEnabled) == Defaults.menubarTextEnabled)
        #expect(d.bool(forKey: StorageKey.powerSmoothed) == Defaults.powerSmoothed)
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
            // Every card gets a menu key — even `.battery`, absent from Defaults.menuMetrics (F7).
            #expect(d.object(forKey: StorageKey.menu(card)) != nil)
            #expect(d.bool(forKey: StorageKey.menu(card)) == (Defaults.menuMetrics[card] ?? false))
        }
        // `.battery` is intentionally not a menu metric → defaults to false, key present.
        #expect(d.bool(forKey: StorageKey.menu(.battery)) == false)
    }

    @Test func resetReenablesLoginItem() {
        let d = makeDefaults(#function)
        let login = FakeLoginItem(enabled: false)

        SettingsReset.applyDefaults(into: d, login: login)

        #expect(login.lastSet == Defaults.loginItem)   // default is ON
        #expect(login.isEnabled == Defaults.loginItem)
        #expect(d.bool(forKey: StorageKey.loginItem) == Defaults.loginItem)
    }
}
