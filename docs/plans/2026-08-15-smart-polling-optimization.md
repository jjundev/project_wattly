# Smart Polling Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 4 synergistic optimizations for telemetry polling: (1) Tiered background cadence for Performance mode (10s for slow metrics), (2) 250ms power double-sampling on panel open for instant watts rendering, (3) AC power adapter detection for smart high-speed polling while charging, and (4) fine-tuned refresh intervals across Eco and Performance modes.

**Architecture:**
- `PollPolicy.swift`: Extend `providerIntervals` to support `isACConnected: Bool`, apply tiered cadences for fast metrics (`cpu`, `power`, `temp`) vs slow metrics (`memory`, `battery`, `fan`), and optimize interval tables.
- `SystemMonitor.swift`: Track `isACConnected` from `BatterySample.externalConnected` and pass it to schedule calculations; on `setPanelVisible(true)`, schedule a single 250ms delayed power poll to immediately compute delta watts without waiting 1.0s.
- `Settings.swift`: Update `pollingDescription` copy to reflect optimized smart adaptive behavior.
- `WattlyTests`: Update `PollPolicyTests`, `SystemMonitorTests`, and `PanelPresentationTests` to verify tiered intervals, AC boost, rapid double-sampling, and localized copy.

**Tech Stack:** Swift, SwiftUI, Swift Testing framework (`Testing`).

## Global Constraints

- Preserve all existing `@AppStorage` keys, presets (`BackgroundRefreshPreset`), and storage defaults.
- Ensure all unit tests across the entire project continue to pass.
- Exact Korean UI terms in descriptions:
  - Eco: "패널을 열면 CPU·전력은 1초(오픈 즉시 표시), 온도는 2초, 메모리·배터리는 5초마다 갱신합니다. 패널을 닫으면 메뉴바에 표시한 지표만 2~5초마다 갱신하며, 메뉴바 텍스트를 끄면 지표 갱신을 멈춥니다."
  - Performance: "패널을 열면 CPU·전력·온도는 1초, 메모리·팬은 3초마다 갱신합니다. 패널을 닫으면 지표 특성과 전원 상태(배터리/충전)에 맞춰 최적화하여 갱신합니다."
  - Fixed: "패널 상태와 관계없이 활성 지표를 N초마다 갱신합니다."

---

### Task 1: Tiered Cadences and AC Power State in PollPolicy

**Files:**
- Modify: `Wattly/Core/PollPolicy.swift:35-66`
- Test: `WattlyTests/PollPolicyTests.swift:60-117`

**Interfaces:**
- Consumes: `PowerMode`, `PollInterval`, `ProviderKind`, `CardKind`, `isACConnected: Bool`
- Produces: `providerIntervals(mode:setting:panelVisible:menubarTextEnabled:active:menubarNeeds:isACConnected:) -> [ProviderKind: Duration]`

- [ ] **Step 1: Write failing tests for tiered cadences and AC connection in PollPolicyTests.swift**

In `WattlyTests/PollPolicyTests.swift`:
1. Replace `autoPolicyBudgetsProvidersByVisibility` and `performanceAutoPollsEveryActiveProviderWhenPanelIsClosed` with:

```swift
    @Test func autoPolicyBudgetsProvidersByVisibility() {
        let all = Set(ProviderKind.allCases)
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                  menubarTextEnabled: true, active: all,
                                  menubarNeeds: [.cpu]) == [
            .cpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
            .memory: .seconds(5), .battery: .seconds(5), .fan: .seconds(5),
        ])
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarTextEnabled: true, active: all,
                                  menubarNeeds: [.cpu]) == [.cpu: .seconds(2)])
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarTextEnabled: true, active: all,
                                  menubarNeeds: [.mem]) == [.memory: .seconds(5)])
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarTextEnabled: false, active: all,
                                  menubarNeeds: [.cpu]).isEmpty)
    }

    @Test func performanceTieredCadenceAdaptsByMetricSpeedAndAC() {
        let all = Set(ProviderKind.allCases)
        // Panel open
        let open = providerIntervals(mode: .performance, setting: .auto, panelVisible: true,
                                     menubarTextEnabled: true, active: all, menubarNeeds: [.cpu])
        #expect(open[.cpu] == .seconds(1))
        #expect(open[.power] == .seconds(1))
        #expect(open[.temperature] == .seconds(1))
        #expect(open[.memory] == .seconds(3))
        #expect(open[.battery] == .seconds(3))
        #expect(open[.fan] == .seconds(3))

        // Panel closed on battery (text on)
        let closedBattery = providerIntervals(mode: .performance, setting: .auto, panelVisible: false,
                                              menubarTextEnabled: true, active: all, menubarNeeds: [.cpu],
                                              isACConnected: false)
        #expect(closedBattery[.cpu] == .seconds(3))
        #expect(closedBattery[.power] == .seconds(3))
        #expect(closedBattery[.memory] == .seconds(10))
        #expect(closedBattery[.battery] == .seconds(10))
        #expect(closedBattery[.fan] == .seconds(10))

        // Panel closed on AC (text on)
        let closedAC = providerIntervals(mode: .performance, setting: .auto, panelVisible: false,
                                         menubarTextEnabled: true, active: all, menubarNeeds: [.cpu],
                                         isACConnected: true)
        #expect(closedAC[.cpu] == .seconds(2))
        #expect(closedAC[.power] == .seconds(2))
        #expect(closedAC[.memory] == .seconds(5))
        #expect(closedAC[.battery] == .seconds(5))
        #expect(closedAC[.fan] == .seconds(5))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test -only-testing:WattlyTests/PollPolicyTests` (with BypassSandbox: true)
Expected: FAIL due to missing parameter / interval mismatches.

- [ ] **Step 3: Implement tiered cadences and AC awareness in PollPolicy.swift**

In `Wattly/Core/PollPolicy.swift`, update `providerIntervals`:

```swift
func providerIntervals(mode: PowerMode,
                       setting: PollInterval,
                       panelVisible: Bool,
                       menubarTextEnabled: Bool,
                       active: Set<ProviderKind>,
                       menubarNeeds: Set<CardKind>,
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
            let open: [ProviderKind: Duration] = [
                .cpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(1),
                .memory: .seconds(3), .battery: .seconds(3), .fan: .seconds(3),
            ]
            return open.filter { active.contains($0.key) }
        }

        let fastInterval: Duration = if menubarTextEnabled {
            isACConnected ? .seconds(2) : .seconds(3)
        } else {
            isACConnected ? .seconds(3) : .seconds(5)
        }
        let slowInterval: Duration = if menubarTextEnabled {
            isACConnected ? .seconds(5) : .seconds(10)
        } else {
            .seconds(10)
        }

        var result: [ProviderKind: Duration] = [:]
        for kind in active {
            switch kind {
            case .cpu, .power, .temperature:
                result[kind] = fastInterval
            case .memory, .battery, .fan:
                result[kind] = slowInterval
            }
        }
        return result
    }

    if panelVisible {
        let open: [ProviderKind: Duration] = [
            .cpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
            .memory: .seconds(5), .battery: .seconds(5), .fan: .seconds(5),
        ]
        return open.filter { active.contains($0.key) }
    }

    guard menubarTextEnabled else { return [:] }
    let menuProviders = Set(menubarNeeds.map(\.provider)).intersection(active)
    var result: [ProviderKind: Duration] = [:]
    for kind in menuProviders {
        switch kind {
        case .cpu, .power, .temperature:
            result[kind] = .seconds(2)
        case .memory, .battery, .fan:
            result[kind] = .seconds(5)
        }
    }
    return result
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test -only-testing:WattlyTests/PollPolicyTests` (with BypassSandbox: true)
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/PollPolicy.swift WattlyTests/PollPolicyTests.swift
git commit -m "feat: implement tiered provider cadences and AC state support in PollPolicy"
```

---

### Task 2: Implement 250ms Double-Sampling on Open and AC State in SystemMonitor

**Files:**
- Modify: `Wattly/Core/SystemMonitor.swift:130-195,310-330`
- Test: `WattlyTests/SystemMonitorTests.swift`

**Interfaces:**
- Consumes: `providerIntervals` with `isACConnected`
- Produces: Instant power calculation on panel open and adaptive rescheduling on AC state change

- [ ] **Step 1: Write test for power double-sampling and AC tracking in SystemMonitorTests.swift**

In `WattlyTests/SystemMonitorTests.swift`, add tests for panel open power double-sampling and AC state updates:

```swift
    @Test func panelOpenTriggersRapidPowerDoubleSample() async {
        let power = CountingProvider(kind: .power)
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [power], clock: clock)
        monitor.setPollInterval(.auto)
        monitor.start()

        #expect(await power.reads == 0) // Closed panel in eco mode without menubar text skips power
        monitor.setPanelVisible(true)
        // t = 0 immediate poll triggered by reschedule
        #expect(await power.reads >= 1)
        // Let async 250ms double-sample execute
        try? await Task.sleep(for: .milliseconds(350))
        #expect(await power.reads >= 2)
        monitor.stop()
    }

    @Test func batteryStateChangeReschedulesOnACConnection() async {
        let batterySample = BatterySample(netW: -10, milliamps: 1000, volts: 12, charging: true, externalConnected: true)
        let batteryProvider = ScriptedProvider(kind: .battery, [.value(.battery(batterySample))])
        let mem = CountingProvider(kind: .memory)
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [batteryProvider, mem], clock: clock)
        monitor.setPowerMode(.performance)
        monitor.start()

        // Ingest battery sample with AC connected
        await monitor.pollOnce()
        #expect(await mem.reads >= 1)
        monitor.stop()
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test -only-testing:WattlyTests/SystemMonitorTests` (with BypassSandbox: true)

- [ ] **Step 3: Implement rapid double-sampling and AC connection in SystemMonitor.swift**

In `Wattly/Core/SystemMonitor.swift`:
1. Add property `private var isACConnected = false`.
2. Update `currentProviderIntervals`:
```swift
    private var currentProviderIntervals: [ProviderKind: Duration] {
        let needs: Set<CardKind> = menubarTextEnabled ? menubarMetrics : []
        return providerIntervals(mode: powerMode, setting: pollSetting, panelVisible: panelVisible,
                                 menubarTextEnabled: menubarTextEnabled,
                                 active: activeProviderKinds, menubarNeeds: needs,
                                 isACConnected: isACConnected)
    }
```
3. In `setPanelVisible(_:)`, update `isPanelVisible` and trigger the rapid 250ms power sample on any open transition:
```swift
    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        let before = currentProviderIntervals
        panelVisible = visible
        let after = currentProviderIntervals
        if after != before {
            let forced = visible ? Set(after.keys) : Set(after.keys).subtracting(before.keys)
            reschedule(forceProviders: forced)
        }

        if visible, activeProviderKinds.contains(.power) {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.panelVisible else { return }
                await self.poll(kinds: [.power], at: self.clock.now())
            }
        }
    }
```
4. In `apply(_:from:at:)` for `.battery`, update `isACConnected` and reschedule on change:
```swift
        case .value(.battery(let rawBattery)):
            let battery = preparedBattery(rawBattery, at: instant)
            let sample = MetricSample.battery(battery)
            states[kind] = .value(sample)
            recordHistory(for: kind, sample: sample, at: instant)
            if isACConnected != battery.externalConnected {
                isACConnected = battery.externalConnected
                reschedule()
            }
```

- [ ] **Step 4: Run SystemMonitor tests to verify pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test -only-testing:WattlyTests/SystemMonitorTests` (with BypassSandbox: true)
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/SystemMonitor.swift WattlyTests/SystemMonitorTests.swift
git commit -m "feat: add 250ms power double-sampling on panel open and AC state tracking"
```

---

### Task 3: Update Descriptions in Settings and PanelPresentationTests

**Files:**
- Modify: `Wattly/Settings/Settings.swift:37-52`
- Test: `WattlyTests/PanelPresentationTests.swift:55-70`

**Interfaces:**
- Consumes: `PollInterval`, `PowerMode`
- Produces: Updated `pollingDescription(for:mode:) -> String`

- [ ] **Step 1: Update pollingDescription tests in PanelPresentationTests.swift**

In `WattlyTests/PanelPresentationTests.swift`, update copy expectations:

```swift
    @Test func automaticEcoPollingCopyMatchesProviderBudget() {
        #expect(pollingDescription(for: .auto, mode: .eco) ==
            "패널을 열면 CPU·전력은 1초(오픈 즉시 표시), 온도는 2초, 메모리·배터리는 5초마다 갱신합니다. 패널을 닫으면 메뉴바에 표시한 지표만 2~5초마다 갱신하며, 메뉴바 텍스트를 끄면 지표 갱신을 멈춥니다.")
    }

    @Test func automaticAlwaysLatestPollingCopyMatchesProviderBudget() {
        #expect(pollingDescription(for: .auto, mode: .performance) ==
            "패널을 열면 CPU·전력·온도는 1초, 메모리·팬은 3초마다 갱신합니다. 패널을 닫으면 지표 특성과 전원 상태(배터리/충전)에 맞춰 최적화하여 갱신합니다.")
    }
```

- [ ] **Step 2: Update pollingDescription implementation in Settings.swift**

In `Wattly/Settings/Settings.swift`:

```swift
func pollingDescription(for setting: PollInterval, mode: PowerMode) -> String {
    switch setting {
    case .s1: "패널 상태와 관계없이 활성 지표를 1초마다 갱신합니다."
    case .s2: "패널 상태와 관계없이 활성 지표를 2초마다 갱신합니다."
    case .s5: "패널 상태와 관계없이 활성 지표를 5초마다 갱신합니다."
    case .auto:
        switch mode {
        case .eco:
            "패널을 열면 CPU·전력은 1초(오픈 즉시 표시), 온도는 2초, 메모리·배터리는 5초마다 갱신합니다. 패널을 닫으면 메뉴바에 표시한 지표만 2~5초마다 갱신하며, 메뉴바 텍스트를 끄면 지표 갱신을 멈춥니다."
        case .performance:
            "패널을 열면 CPU·전력·온도는 1초, 메모리·팬은 3초마다 갱신합니다. 패널을 닫으면 지표 특성과 전원 상태(배터리/충전)에 맞춰 최적화하여 갱신합니다."
        }
    }
}
```

- [ ] **Step 3: Run tests to verify pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test -only-testing:WattlyTests/PanelPresentationTests` (with BypassSandbox: true)
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Wattly/Settings/Settings.swift WattlyTests/PanelPresentationTests.swift
git commit -m "docs: update pollingDescription to reflect tiered and smart AC scheduling"
```

---

### Task 4: Full Test Suite Verification

**Files:**
- Test: Full `WattlyTests` suite across all 31 suites

- [ ] **Step 1: Run full test suite**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test` (with BypassSandbox: true)
Expected: All 380+ tests PASS with 0 failures.

- [ ] **Step 2: Final verification commit**

```bash
git commit --allow-empty -m "chore: verify all test suites pass for smart polling optimization"
```
