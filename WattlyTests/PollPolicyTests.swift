import Testing
import Foundation
@testable import Wattly

/// Issue 09 — pure adaptive-poll policy: cadence resolution + active-provider derivation,
/// tested directly as tables (the live timer loop is verified on-device).
struct PollPolicyTests {

    // MARK: resolvePollInterval

    @Test func autoAdaptsToPanelAndMenubar() {
        // Open → 1 s live view, regardless of the menubar text.
        #expect(resolvePollInterval(setting: .auto, panelVisible: true, menubarTextEnabled: true) == .seconds(1))
        #expect(resolvePollInterval(setting: .auto, panelVisible: true, menubarTextEnabled: false) == .seconds(1))
        // Closed → 2 s while the menubar shows a number, 5 s when it doesn't.
        #expect(resolvePollInterval(setting: .auto, panelVisible: false, menubarTextEnabled: true) == .seconds(2))
        #expect(resolvePollInterval(setting: .auto, panelVisible: false, menubarTextEnabled: false) == .seconds(5))
    }

    @Test func fixedSettingsAreConstant() {
        // A pinned cadence ignores panel/menubar state entirely (only `.auto` adapts).
        for panel in [true, false] {
            for text in [true, false] {
                #expect(resolvePollInterval(setting: .s1, panelVisible: panel, menubarTextEnabled: text) == .seconds(1))
                #expect(resolvePollInterval(setting: .s2, panelVisible: panel, menubarTextEnabled: text) == .seconds(2))
                #expect(resolvePollInterval(setting: .s5, panelVisible: panel, menubarTextEnabled: text) == .seconds(5))
            }
        }
    }

    // MARK: activeProviders

    @Test func allShownYieldsEveryProvider() {
        #expect(activeProviders(shown: Set(CardKind.allCases), menubarNeeds: []) == Set(ProviderKind.allCases))
    }

    @Test func hidingACardDropsItsProvider() {
        let shown = Set(CardKind.allCases).subtracting([.power])
        #expect(activeProviders(shown: shown, menubarNeeds: []).contains(.power) == false)
    }

    @Test func menubarKeepsAProviderEvenWhenItsCardIsHidden() {
        // CPU card hidden but the menubar still shows CPU → the cpu provider stays active.
        let shown = Set(CardKind.allCases).subtracting([.cpu])
        #expect(activeProviders(shown: shown, menubarNeeds: [.cpu]).contains(.cpu))
    }

    @Test func temperatureProviderActiveIfAnyTempCardShown() {
        // Only battery-temp shown → the temperature provider is still polled (for batTemp),
        // even though cpuTemp/gpuTemp are hidden. (The CPU/GPU SMC sub-path is gated
        // separately by the provider's setEnabled.)
        #expect(activeProviders(shown: [.batTemp], menubarNeeds: []) == [.temperature])
    }

    @Test func nothingShownYieldsNoProviders() {
        #expect(activeProviders(shown: [], menubarNeeds: []).isEmpty)
    }
}
