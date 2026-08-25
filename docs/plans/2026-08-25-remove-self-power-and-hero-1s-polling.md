# Remove Self-Power Measurement & Force 1s Polling for Hero Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove Wattly's internal self-power measurement logic and files, and ensure that when the panel is open in Mode C (Hero mode), the active Hero card metric is unconditionally polled at a 1-second interval.

**Architecture:** 
1. Deprecate and remove self-power tracking pipeline (`SelfEnergy`, `SelfPower`, `SelfPowerTracker`, and `SystemMonitor.selfPower`) along with housekeeping overhead.
2. Extend pure `PollPolicy.providerIntervals` to accept an optional `heroCard: CardKind?`. When `panelVisible == true`, the hero card's underlying provider interval is forced to `1s` (`.seconds(1)`).
3. Connect `PollPolicyBridge` to observe `@AppStorage(StorageKey.panelMode)`, `@AppStorage(StorageKey.heroMetric)`, and `@AppStorage(StorageKey.cardOrder)`, pushing the resolved hero card to `SystemMonitor.setHeroCard(_:)`.

**Tech Stack:** Swift 6 (Strict Concurrency), Swift Testing (`#expect`), SwiftUI `@AppStorage`, Xcode project (`Wattly.xcodeproj`).

## Global Constraints

- Swift 6 language mode with complete concurrency checking (`SWIFT_VERSION: "6.0"`).
- Target platform: macOS 14.0+ on Apple Silicon (`arm64`).
- Ad-hoc code signing (`CODE_SIGN_IDENTITY: "-"`).
- Pure logic must be separated from SwiftUI views and covered with unit tests using Swift Testing (`#expect`).
- No regressions in 30-language localization or existing metric provider scheduling.

---

### Task 1: Remove Self-Power measurement logic, obsolete files, PBX entries, and related tests

**Files:**
- Delete:
  - `Wattly/Core/SelfEnergy.swift`
  - `Wattly/Core/SelfPower.swift`
  - `Wattly/Core/SelfPowerTracker.swift`
  - `WattlyTests/SelfPowerTests.swift`
- Modify:
  - `Wattly/Core/SystemMonitor.swift`
  - `Wattly/Core/PollPolicy.swift`
  - `Wattly/Core/Accessibility.swift:55-65`
  - `WattlyTests/PollPolicyTests.swift:171-189`
  - `WattlyTests/SystemMonitorTests.swift:429-500`
  - `Wattly.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `SystemMonitor` constructor without `selfEnergy` parameter.
- Produces: `SystemMonitor` cleaned of `selfPowerTracker`, `selfPower`, `sampleSelfPower`, `sampleSelfPowerIfDue`.

- [ ] **Step 1: Remove self-power properties and methods from `SystemMonitor.swift` and comment in `Accessibility.swift`**

In `Wattly/Core/SystemMonitor.swift`:
1. Remove `private var selfPowerTracker = SelfPowerTracker()`.
2. Remove `private(set) var selfPower: Double?`.
3. Remove `private static let selfPowerInterval: Duration = .seconds(30)`.
4. Remove `private var lastSelfPowerSample: ContinuousClock.Instant?`.
5. Remove `private let selfEnergy: any SelfEnergySampling` from stored properties and initializer parameters (update `init(providers:clock:)`).
6. In `start(forceProviders:)`: remove `self.sampleSelfPowerIfDue(at: self.clock.now())`.
7. Remove `sampleSelfPower(at:)` and `sampleSelfPowerIfDue(at:)`.
8. In `nextScheduledDelay(at:)`: remove `housekeeping: Self.selfPowerInterval` argument passed to `nextPollDelay`.

In `Wattly/Core/Accessibility.swift` (lines 55–65):
Update the doc comment to remove obsolete `selfPowerPart` reference.

- [ ] **Step 2: Update `nextPollDelay` in `PollPolicy.swift` and tests in `PollPolicyTests.swift`**

In `Wattly/Core/PollPolicy.swift`:
```swift
func nextPollDelay(intervals: [ProviderKind: Duration],
                   lastRead: [ProviderKind: ContinuousClock.Instant],
                   now: ContinuousClock.Instant,
                   fallback: Duration = .seconds(5)) -> Duration {
    intervals.reduce(fallback) { next, entry in
        guard let last = lastRead[entry.key] else { return .zero }
        let remaining = max(0, seconds(entry.value) - seconds(from: last, to: now))
        return min(next, .seconds(remaining))
    }
}
```

In `WattlyTests/PollPolicyTests.swift` (lines 171–189):
```swift
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
```

- [ ] **Step 3: Remove obsolete tests in `SystemMonitorTests.swift`**

In `WattlyTests/SystemMonitorTests.swift`:
Delete `FakeSelfEnergy` class and the tests:
- `selfPowerComputesWattsFromEnergyDelta`
- `selfPowerRebaselinesAcrossASleepGap`
- `selfPowerKeepsLastValueOnTransientAnomaly`
- `scheduledSelfEnergySamplingIsCappedAtThirtySeconds`

- [ ] **Step 4: Delete obsolete self-power source & test files and remove from `project.pbxproj`**

Delete:
- `Wattly/Core/SelfEnergy.swift`
- `Wattly/Core/SelfPower.swift`
- `Wattly/Core/SelfPowerTracker.swift`
- `WattlyTests/SelfPowerTests.swift`

Remove their PBXBuildFile, PBXFileReference, and group membership references from `Wattly.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Run tests to verify clean compilation and pass**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(monitor): remove self-power measurement pipeline and files"
```

---

### Task 2: Update PollPolicy with hero card 1s polling override and add pure unit tests

**Files:**
- Modify: `Wattly/Core/PollPolicy.swift:35-105`
- Modify: `WattlyTests/PollPolicyTests.swift`

**Interfaces:**
- Consumes: `heroCard: CardKind?` in `providerIntervals`.
- Produces: Pure function returning 1s cadence for the hero card provider when `panelVisible == true`.

- [ ] **Step 1: Write failing unit tests in `PollPolicyTests.swift`**

In `WattlyTests/PollPolicyTests.swift`:
```swift
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

        // When panel is closed, heroCard does not force 1s cadence.
        let closedHeroBattery = providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                                  menubarLiveContentEnabled: true, active: all,
                                                  menubarNeeds: [.battery], heroCard: .battery)
        #expect(closedHeroBattery[.battery] == .seconds(5))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/PollPolicyTests test`
Expected: Compilation failure due to missing `heroCard` parameter.

- [ ] **Step 3: Update `providerIntervals` in `PollPolicy.swift`**

In `Wattly/Core/PollPolicy.swift`:
```swift
func providerIntervals(mode: PowerMode,
                       setting: PollInterval,
                       panelVisible: Bool,
                       menubarLiveContentEnabled: Bool,
                       active: Set<ProviderKind>,
                       menubarNeeds: Set<CardKind>,
                       heroCard: CardKind? = nil,
                       isACConnected: Bool = false) -> [ProviderKind: Duration] {
    if setting != .auto {
        let interval: Duration = switch setting {
        case .s1: .seconds(1)
        case .s2: .seconds(2)
        case .s5: .seconds(5)
        case .auto: preconditionFailure("handled above")
        }
        return Dictionary(uniqueKeysWithValues: active.map { ($0, interval) })
    }

    if mode == .performance {
        if panelVisible {
            var open: [ProviderKind: Duration] = [
                .cpu: .seconds(1), .gpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(1),
                .memory: .seconds(3), .battery: .seconds(3), .fan: .seconds(3),
            ]
            if let heroCard {
                open[heroCard.provider] = .seconds(1)
            }
            return open.filter { active.contains($0.key) }
        }

        let fastInterval: Duration = if menubarLiveContentEnabled {
            isACConnected ? .seconds(2) : .seconds(3)
        } else {
            isACConnected ? .seconds(3) : .seconds(5)
        }
        let slowInterval: Duration = if menubarLiveContentEnabled {
            isACConnected ? .seconds(5) : .seconds(10)
        } else {
            .seconds(10)
        }

        var result: [ProviderKind: Duration] = [:]
        for kind in active {
            switch kind {
            case .cpu, .gpu, .power, .temperature:
                result[kind] = fastInterval
            case .memory, .battery, .fan:
                result[kind] = slowInterval
            }
        }
        return result
    }

    if panelVisible {
        var open: [ProviderKind: Duration] = [
            .cpu: .seconds(1), .gpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
            .memory: .seconds(5), .battery: .seconds(5), .fan: .seconds(5),
        ]
        if let heroCard {
            open[heroCard.provider] = .seconds(1)
        }
        return open.filter { active.contains($0.key) }
    }

    guard menubarLiveContentEnabled else { return [:] }
    let menuProviders = Set(menubarNeeds.map(\.provider)).intersection(active)
    var result: [ProviderKind: Duration] = [:]
    for kind in menuProviders {
        switch kind {
        case .cpu, .gpu, .power, .temperature:
            result[kind] = .seconds(2)
        case .memory, .battery, .fan:
            result[kind] = .seconds(5)
        }
    }
    return result
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData -only-testing:WattlyTests/PollPolicyTests test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/PollPolicy.swift WattlyTests/PollPolicyTests.swift
git commit -m "feat(policy): force 1s polling for hero card when panel is open"
```

---

### Task 3: Integrate heroCard into SystemMonitor and PollPolicyBridge, verify full test suite and release build

**Files:**
- Modify: `Wattly/Core/SystemMonitor.swift`
- Modify: `Wattly/Views/PollPolicyBridge.swift`
- Modify: `WattlyTests/SystemMonitorTests.swift`

**Interfaces:**
- Consumes: `heroCard: CardKind?` in `SystemMonitor.setHeroCard(_:)`.
- Produces: Complete end-to-end integration between SwiftUI preferences, `PollPolicyBridge`, `SystemMonitor`, and `PollPolicy`.

- [ ] **Step 1: Add `heroCard` tracking to `SystemMonitor.swift`**

In `Wattly/Core/SystemMonitor.swift`:
1. Add property:
```swift
    private var heroCard: CardKind?
```
2. In `currentProviderIntervals`:
```swift
    private var currentProviderIntervals: [ProviderKind: Duration] {
        return providerIntervals(mode: powerMode, setting: pollSetting, panelVisible: panelVisible,
                                 menubarLiveContentEnabled: !currentMenubarNeeds.isEmpty,
                                 active: activeProviderKinds, menubarNeeds: currentMenubarNeeds,
                                 heroCard: heroCard, isACConnected: isACConnected)
    }
```
3. Add method:
```swift
    func setHeroCard(_ card: CardKind?) {
        guard card != heroCard else { return }
        let before = currentProviderIntervals
        heroCard = card
        let after = currentProviderIntervals
        if after != before {
            let forced = panelVisible ? (card.map { Set([$0.provider]) } ?? []) : []
            reschedule(forceProviders: forced)
        }
    }
```

- [ ] **Step 2: Update `PollPolicyBridge.swift` to observe and push Hero Card**

In `Wattly/Views/PollPolicyBridge.swift`:
```swift
    @AppStorage(StorageKey.panelMode) private var panelMode: PanelMode = Defaults.panelMode
    @AppStorage(StorageKey.heroMetric) private var heroMetric: CardKind = Defaults.heroMetric
    @AppStorage(StorageKey.cardOrder) private var cardOrder: CardOrder = Defaults.cardOrder

    private var resolvedHeroCard: CardKind? {
        guard panelMode == .c else { return nil }
        let visible = cardOrder.visible(present: { monitor.isPresent($0) }, shown: { visibilitySettings.isShown($0) })
        return CardPresentation.resolveHero(persisted: heroMetric, visible: visible)
    }
```
In `.task`:
```swift
    monitor.setHeroCard(resolvedHeroCard)
```
In live updates:
```swift
    .onChange(of: panelMode) { _, _ in monitor.setHeroCard(resolvedHeroCard) }
    .onChange(of: heroMetric) { _, _ in monitor.setHeroCard(resolvedHeroCard) }
    .onChange(of: cardOrder) { _, _ in monitor.setHeroCard(resolvedHeroCard) }
```
And inside `.onChange(of: visibilitySettings.activeCards)`:
```swift
    .onChange(of: visibilitySettings.activeCards) { _, v in
        Task {
            await monitor.setShownCards(v)
            monitor.setHeroCard(resolvedHeroCard)
        }
    }
```

- [ ] **Step 3: Add unit test in `SystemMonitorTests.swift`**

In `WattlyTests/SystemMonitorTests.swift`:
```swift
    @Test func heroCardSpeedsUpScheduledPollWhenPanelVisible() async {
        let clock = ManualClock()
        let provider = CountingProvider(kind: .battery)
        let monitor = SystemMonitor(providers: [provider], clock: clock)
        monitor.setPanelVisible(true)

        // Initial poll
        await monitor.pollScheduled(force: false)
        #expect(await provider.reads == 1)

        // Advance by 1 second without hero card -> Battery is 5s, not due yet
        clock.advance(by: .seconds(1))
        await monitor.pollScheduled(force: false)
        #expect(await provider.reads == 1)

        // Set Battery as hero card -> Battery becomes 1s cadence
        monitor.setHeroCard(.battery)
        clock.advance(by: .seconds(1))
        await monitor.pollScheduled(force: false)
        #expect(await provider.reads == 2)
    }
```

- [ ] **Step 4: Run full test suite**

Run: `xcodebuild -scheme Wattly -configuration Debug -derivedDataPath /tmp/WattlyDerivedData test`
Expected: `** TEST SUCCEEDED **` with all suites passing.

- [ ] **Step 5: Build Release and verify running application**

Run: `xcodebuild -scheme Wattly -configuration Release -derivedDataPath /tmp/WattlyDerivedData build`
Expected: `** BUILD SUCCEEDED **`.

Relaunch:
```bash
pkill -x Wattly || true
open /tmp/WattlyDerivedData/Build/Products/Release/Wattly.app
```

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/SystemMonitor.swift Wattly/Views/PollPolicyBridge.swift WattlyTests/SystemMonitorTests.swift
git commit -m "feat(monitor): bridge hero card visibility to poll scheduler"
```
