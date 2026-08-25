import Testing
import Foundation
@testable import Wattly

/// Issue 09 — pure adaptive-poll policy: cadence resolution + active-provider derivation,
/// tested directly as tables (the live timer loop is verified on-device).
struct PollPolicyTests {

    // MARK: resolvePollInterval

    @Test func autoAdaptsToPanelAndMenubar() {
        // Open → 1 s live view, regardless of the menubar text.
        #expect(resolvePollInterval(setting: .auto, panelVisible: true, menubarLiveContentEnabled: true) == .seconds(1))
        #expect(resolvePollInterval(setting: .auto, panelVisible: true, menubarLiveContentEnabled: false) == .seconds(1))
        // Closed → 2 s while the menubar has live content (text or Kinetic Notch motion), 5 s when it doesn't.
        #expect(resolvePollInterval(setting: .auto, panelVisible: false, menubarLiveContentEnabled: true) == .seconds(2))
        #expect(resolvePollInterval(setting: .auto, panelVisible: false, menubarLiveContentEnabled: false) == .seconds(5))
    }

    @Test func fixedSettingsAreConstant() {
        // A pinned cadence ignores panel/menubar state entirely (only `.auto` adapts).
        for panel in [true, false] {
            for text in [true, false] {
                #expect(resolvePollInterval(setting: .s1, panelVisible: panel, menubarLiveContentEnabled: text) == .seconds(1))
                #expect(resolvePollInterval(setting: .s2, panelVisible: panel, menubarLiveContentEnabled: text) == .seconds(2))
                #expect(resolvePollInterval(setting: .s5, panelVisible: panel, menubarLiveContentEnabled: text) == .seconds(5))
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
        // Only CPU-temp shown → the temperature provider is still polled,
        // even though other cards are hidden.
        #expect(activeProviders(shown: [.cpuTemp], menubarNeeds: []) == [.temperature])
    }

    @Test func nothingShownYieldsNoProviders() {
        #expect(activeProviders(shown: [], menubarNeeds: []).isEmpty)
    }

    // MARK: provider-level policy

    @Test func autoPolicyBudgetsProvidersByVisibility() {
        let all = Set(ProviderKind.allCases)
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                  menubarLiveContentEnabled: true, active: all,
                                  menubarNeeds: [.cpu]) == [
            .cpu: .seconds(1), .gpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
            .memory: .seconds(5), .battery: .seconds(5), .fan: .seconds(5),
        ])
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarLiveContentEnabled: true, active: all,
                                  menubarNeeds: [.cpu]) == [.cpu: .seconds(2)])
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarLiveContentEnabled: true, active: all,
                                  menubarNeeds: [.mem]) == [.memory: .seconds(5)])
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarLiveContentEnabled: false, active: all,
                                  menubarNeeds: [.cpu]).isEmpty)
    }

    @Test func fixedPolicyKeepsEveryActiveProviderAtChosenInterval() {
        #expect(providerIntervals(mode: .eco, setting: .s2, panelVisible: false,
                                  menubarLiveContentEnabled: false,
                                  active: [.cpu, .power], menubarNeeds: []) == [
            .cpu: .seconds(2), .power: .seconds(2),
        ])
    }

    @Test func closedMenuRetainsOnlyMotionSourceWhenTextIsOff() {
        let active: Set<ProviderKind> = [.cpu, .gpu, .memory]
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarLiveContentEnabled: true, active: active,
                                  menubarNeeds: [.cpu]) == [.cpu: .seconds(2)])
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarLiveContentEnabled: true, active: active,
                                  menubarNeeds: [.cpu, .gpu]) == [.cpu: .seconds(2), .gpu: .seconds(2)])
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarLiveContentEnabled: false, active: active,
                                  menubarNeeds: []).isEmpty)
    }

    @Test func performanceTieredCadenceAdaptsByMetricSpeedAndAC() {
        let all = Set(ProviderKind.allCases)
        // Panel open
        let open = providerIntervals(mode: .performance, setting: .auto, panelVisible: true,
                                     menubarLiveContentEnabled: true, active: all, menubarNeeds: [.cpu])
        #expect(open[.cpu] == .seconds(1))
        #expect(open[.gpu] == .seconds(1))
        #expect(open[.power] == .seconds(1))
        #expect(open[.temperature] == .seconds(1))
        #expect(open[.memory] == .seconds(3))
        #expect(open[.battery] == .seconds(3))
        #expect(open[.fan] == .seconds(3))

        // Panel closed on battery (text on)
        let closedBattery = providerIntervals(mode: .performance, setting: .auto, panelVisible: false,
                                              menubarLiveContentEnabled: true, active: all, menubarNeeds: [.cpu],
                                              isACConnected: false)
        #expect(closedBattery[.cpu] == .seconds(3))
        #expect(closedBattery[.gpu] == .seconds(3))
        #expect(closedBattery[.power] == .seconds(3))
        #expect(closedBattery[.memory] == .seconds(10))
        #expect(closedBattery[.battery] == .seconds(10))
        #expect(closedBattery[.fan] == .seconds(10))

        // Panel closed on AC (text on)
        let closedAC = providerIntervals(mode: .performance, setting: .auto, panelVisible: false,
                                         menubarLiveContentEnabled: true, active: all, menubarNeeds: [.cpu],
                                         isACConnected: true)
        #expect(closedAC[.cpu] == .seconds(2))
        #expect(closedAC[.gpu] == .seconds(2))
        #expect(closedAC[.power] == .seconds(2))
        #expect(closedAC[.memory] == .seconds(5))
        #expect(closedAC[.battery] == .seconds(5))
        #expect(closedAC[.fan] == .seconds(5))
    }

    @Test func gpuPollIntervals() {
        let intervals = providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                          menubarLiveContentEnabled: true, active: [.gpu],
                                          menubarNeeds: [.gpu], isACConnected: true)
        #expect(intervals[.gpu] == .seconds(1))

        let closedIntervals = providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                                menubarLiveContentEnabled: true, active: [.gpu],
                                                menubarNeeds: [.gpu], isACConnected: true)
        #expect(closedIntervals[.gpu] == .seconds(2))
    }

    @Test func performanceAndEcoAgreeForFixedInterval() {
        let active: Set<ProviderKind> = [.cpu, .power]
        let eco = providerIntervals(mode: .eco, setting: .s2, panelVisible: false,
                                    menubarLiveContentEnabled: false, active: active,
                                    menubarNeeds: [])
        let performance = providerIntervals(mode: .performance, setting: .s2,
                                            panelVisible: false,
                                            menubarLiveContentEnabled: false, active: active,
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

    @Test func nextDelayNeverExceedsFallback() {
        let now = ContinuousClock.now
        #expect(nextPollDelay(intervals: [:], lastRead: [:], now: now,
                              fallback: .seconds(30)) == .seconds(30))
        #expect(nextPollDelay(intervals: [.cpu: .seconds(2)], lastRead: [:], now: now,
                              fallback: .seconds(30)) == .zero)
    }

    @Test func nextDelayUsesTheEarliestProviderDeadline() {
        let now = ContinuousClock.now
        let last: [ProviderKind: ContinuousClock.Instant] = [
            .cpu: now.advanced(by: .seconds(-1)),
            .memory: now.advanced(by: .seconds(-1)),
        ]
        #expect(nextPollDelay(intervals: [.cpu: .seconds(5), .memory: .seconds(2)],
                              lastRead: last, now: now,
                              fallback: .seconds(30)) == .seconds(1))
    }

    @Test func panelOpenSchedulesEveryProvider() {
        let ivals = providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                      menubarLiveContentEnabled: true,
                                      active: Set(ProviderKind.allCases), menubarNeeds: [])
        for kind in ProviderKind.allCases {
            #expect(ivals[kind] != nil, "\(kind) missing from the panel-open schedule")
        }
    }

    @Test func heroCardForcesOneSecondCadenceWhenPanelIsOpen() {
        let all = Set(ProviderKind.allCases)

        // In Eco mode, Battery is normally 5s, Memory is 5s, Fan is 5s, Temperature is 2s.
        // When Battery is the Hero card and panel is open, Battery must be 1s.
        let heroBattery = providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                            menubarLiveContentEnabled: true, active: all,
                                            menubarNeeds: [.cpu], heroCard: .battery)
        #expect(heroBattery[.battery] == .seconds(1))
        #expect(heroBattery[.memory] == .seconds(5))
        #expect(heroBattery[.fan] == .seconds(5))
        #expect(heroBattery[.temperature] == .seconds(2))

        // When Memory is the Hero card, Memory must be 1s while Battery remains 5s.
        let heroMem = providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                        menubarLiveContentEnabled: true, active: all,
                                        menubarNeeds: [.cpu], heroCard: .mem)
        #expect(heroMem[.memory] == .seconds(1))
        #expect(heroMem[.battery] == .seconds(5))

        // When CPU Temp is the Hero card, Temperature must be 1s (instead of 2s).
        let heroTemp = providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                         menubarLiveContentEnabled: true, active: all,
                                         menubarNeeds: [.cpu], heroCard: .cpuTemp)
        #expect(heroTemp[.temperature] == .seconds(1))

        // When Fan is the Hero card, Fan must be 1s.
        let heroFan = providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                        menubarLiveContentEnabled: true, active: all,
                                        menubarNeeds: [.cpu], heroCard: .fan)
        #expect(heroFan[.fan] == .seconds(1))

        // In Performance mode, Memory is normally 3s. When Memory is Hero card and panel is open, Memory must be 1s.
        let heroPerfMem = providerIntervals(mode: .performance, setting: .auto, panelVisible: true,
                                            menubarLiveContentEnabled: true, active: all,
                                            menubarNeeds: [.cpu], heroCard: .mem)
        #expect(heroPerfMem[.memory] == .seconds(1))
        #expect(heroPerfMem[.battery] == .seconds(3))

        // When panel is closed, heroCard does not force 1s cadence.
        let closedHeroBattery = providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                                  menubarLiveContentEnabled: true, active: all,
                                                  menubarNeeds: [.battery], heroCard: .battery)
        #expect(closedHeroBattery[.battery] == .seconds(5))
    }
}

