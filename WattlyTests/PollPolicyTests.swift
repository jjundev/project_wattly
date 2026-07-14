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

    // MARK: provider-level policy

    @Test func autoPolicyBudgetsProvidersByVisibility() {
        let all = Set(ProviderKind.allCases)
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                  menubarTextEnabled: true, active: all,
                                  menubarNeeds: [.cpu]) == [
            .cpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
            .memory: .seconds(5), .battery: .seconds(5),
        ])
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarTextEnabled: true, active: all,
                                  menubarNeeds: [.cpu]) == [.cpu: .seconds(2)])
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarTextEnabled: false, active: all,
                                  menubarNeeds: [.cpu]).isEmpty)
    }

    @Test func fixedPolicyKeepsEveryActiveProviderAtChosenInterval() {
        #expect(providerIntervals(mode: .eco, setting: .s2, panelVisible: false,
                                  menubarTextEnabled: false,
                                  active: [.cpu, .power], menubarNeeds: []) == [
            .cpu: .seconds(2), .power: .seconds(2),
        ])
    }

    @Test func performanceAutoPollsEveryActiveProviderWhenPanelIsClosed() {
        let active = Set(ProviderKind.allCases)
        let cases: [(menubarTextEnabled: Bool, interval: Duration)] = [
            (true, .seconds(2)),
            (false, .seconds(5)),
        ]

        for test in cases {
            #expect(providerIntervals(mode: .performance, setting: .auto,
                                      panelVisible: false,
                                      menubarTextEnabled: test.menubarTextEnabled,
                                      active: active, menubarNeeds: [.cpu]) ==
                Dictionary(uniqueKeysWithValues: active.map { ($0, test.interval) }))
        }

        let hidden = active.subtracting([.battery])
        #expect(providerIntervals(mode: .performance, setting: .auto,
                                  panelVisible: false, menubarTextEnabled: true,
                                  active: hidden, menubarNeeds: [.cpu]) ==
            Dictionary(uniqueKeysWithValues: hidden.map { ($0, .seconds(2)) }))
    }

    @Test func performanceAndEcoAgreeForFixedInterval() {
        let active: Set<ProviderKind> = [.cpu, .power]
        let eco = providerIntervals(mode: .eco, setting: .s2, panelVisible: false,
                                    menubarTextEnabled: false, active: active,
                                    menubarNeeds: [])
        let performance = providerIntervals(mode: .performance, setting: .s2,
                                            panelVisible: false,
                                            menubarTextEnabled: false, active: active,
                                            menubarNeeds: [])
        #expect(performance == eco)
    }

    @Test func dueProvidersOnlyReturnsExpiredIntervalsUnlessForced() {
        let now = ContinuousClock.now
        let intervals: [ProviderKind: Duration] = [.cpu: .seconds(1), .memory: .seconds(5)]
        let last: [ProviderKind: ContinuousClock.Instant] = [
            .cpu: now.advanced(by: .seconds(-1)),
            .memory: now.advanced(by: .seconds(-2)),
        ]
        #expect(dueProviders(intervals: intervals, lastRead: last, now: now, force: false) == [.cpu])
        #expect(dueProviders(intervals: intervals, lastRead: last, now: now, force: true) == [.cpu, .memory])
    }

    @Test func nextDelayNeverExceedsHousekeepingWake() {
        let now = ContinuousClock.now
        #expect(nextPollDelay(intervals: [:], lastRead: [:], now: now,
                              housekeeping: .seconds(30)) == .seconds(30))
        #expect(nextPollDelay(intervals: [.cpu: .seconds(2)], lastRead: [:], now: now,
                              housekeeping: .seconds(30)) == .zero)
    }

    @Test func nextDelayUsesTheEarliestProviderDeadline() {
        let now = ContinuousClock.now
        let last: [ProviderKind: ContinuousClock.Instant] = [
            .cpu: now.advanced(by: .seconds(-1)),
            .memory: now.advanced(by: .seconds(-1)),
        ]
        #expect(nextPollDelay(intervals: [.cpu: .seconds(5), .memory: .seconds(2)],
                              lastRead: last, now: now,
                              housekeeping: .seconds(30)) == .seconds(1))
    }
}
