# Settings Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Simplify the Wattly Settings UI by implementing a 3-preset progressive disclosure for background refresh (Eco, Always Latest, Custom with selectable interval), unifying process limit settings into a single card, and categorizing menu bar telemetry chips into primary and advanced groups.

**Architecture:** 
- Maintain full backward compatibility with underlying `@AppStorage` keys (`powerMode`, `pollInterval`, `memoryProcessLimit`, `powerProcessLimit`, and menu metric flags).
- Add `BackgroundRefreshPreset` enum in `Settings.swift` as a pure presentation and bridging model.
- Revamp `SettingsView.swift` to use progressive disclosure: hide the poll interval selector unless "사용자 지정 (Custom)" is selected.
- Consolidate `memoryProcessLimitSection` and `powerProcessLimitSection` into a single `cardProcessLimitSection`.
- Split menu bar chips into primary essential telemetry (7 chips) and an expandable advanced telemetry section (5 chips: cluster core clocks, memory pressure, battery temp).

**Tech Stack:** Swift, SwiftUI, AppKit (`NSAppearance`), Swift Testing framework (`Testing`).

## Global Constraints

- Preserve all existing `@AppStorage` keys and defaults so existing user preferences are unchanged.
- Ensure all existing unit tests in `WattlyTests` continue to pass.
- Exact Korean UI terms:
  - Background presets: `절전`, `항상 최신`, `사용자 지정`
  - Fixed intervals: `1초`, `2초`, `5초`
  - Card process limit: `카드 펼침 목록`, `표시할 앱 수`
  - Menu bar advanced toggle: `세부 지표 (코어 클럭·메모리 압력·배터리 온도)`

---

### Task 1: Add BackgroundRefreshPreset and Update Helper Models

**Files:**
- Modify: `Wattly/Settings/Settings.swift:20-55`
- Test: `WattlyTests/PanelPresentationTests.swift:55-70`

**Interfaces:**
- Consumes: `PowerMode`, `PollInterval`
- Produces: `BackgroundRefreshPreset: String, CaseIterable, Identifiable, Sendable`

- [ ] **Step 1: Write the failing test for BackgroundRefreshPreset**

In `WattlyTests/PanelPresentationTests.swift`, add unit tests verifying `BackgroundRefreshPreset`:

```swift
    @Test func backgroundRefreshPresetResolvesCorrectly() {
        #expect(BackgroundRefreshPreset.resolve(interval: .auto, mode: .eco) == .eco)
        #expect(BackgroundRefreshPreset.resolve(interval: .auto, mode: .performance) == .performance)
        #expect(BackgroundRefreshPreset.resolve(interval: .s1, mode: .eco) == .custom)
        #expect(BackgroundRefreshPreset.resolve(interval: .s2, mode: .performance) == .custom)
        #expect(BackgroundRefreshPreset.resolve(interval: .s5, mode: .eco) == .custom)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test -only-testing:WattlyTests/PanelPresentationTests` (with BypassSandbox: true)
Expected: FAIL at compile time with "'BackgroundRefreshPreset' not found".

- [ ] **Step 3: Implement BackgroundRefreshPreset in Settings.swift**

In `Wattly/Settings/Settings.swift`, add `BackgroundRefreshPreset`:

```swift
enum BackgroundRefreshPreset: String, CaseIterable, Identifiable, Sendable {
    case eco
    case performance
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .eco: "절전"
        case .performance: "항상 최신"
        case .custom: "사용자 지정"
        }
    }

    static func resolve(interval: PollInterval, mode: PowerMode) -> BackgroundRefreshPreset {
        if interval != .auto { return .custom }
        return mode == .eco ? .eco : .performance
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test -only-testing:WattlyTests/PanelPresentationTests` (with BypassSandbox: true)
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Settings/Settings.swift WattlyTests/PanelPresentationTests.swift
git commit -m "feat: add BackgroundRefreshPreset enum and presentation tests"
```

---

### Task 2: Revamp Background Refresh Section in SettingsView

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:837-861`

**Interfaces:**
- Consumes: `BackgroundRefreshPreset`, `PollInterval`, `PowerMode`, `pollingDescription(for:mode:)`
- Produces: Simplified `backgroundUpdateSection` in `SettingsView`

- [ ] **Step 1: Implement progressive disclosure for backgroundUpdateSection in SettingsView.swift**

In `Wattly/Views/SettingsView.swift`, replace `backgroundUpdateSection` with:

```swift
    // MARK: 백그라운드 갱신

    private var refreshPresetBinding: Binding<BackgroundRefreshPreset> {
        Binding(
            get: {
                BackgroundRefreshPreset.resolve(interval: pollInterval, mode: powerMode)
            },
            set: { newPreset in
                switch newPreset {
                case .eco:
                    powerMode = .eco
                    pollInterval = .auto
                case .performance:
                    powerMode = .performance
                    pollInterval = .auto
                case .custom:
                    if pollInterval == .auto {
                        pollInterval = .s2
                    }
                }
            }
        )
    }

    private var backgroundUpdateSection: some View {
        SettingsSection(title: "백그라운드 갱신") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 10) {
                    WattlySegment(selection: refreshPresetBinding, options: [
                        (.eco, BackgroundRefreshPreset.eco.label),
                        (.performance, BackgroundRefreshPreset.performance.label),
                        (.custom, BackgroundRefreshPreset.custom.label),
                    ])

                    if pollInterval != .auto {
                        Rectangle().fill(t.line).frame(height: 1)
                        Text("갱신 주기")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                        WattlySegment(selection: $pollInterval,
                                      options: PollInterval.allCases.filter { $0 != .auto }.map { ($0, $0.label) },
                                      pillVPadding: 6)
                    }

                    Text(pollingDescription(for: pollInterval, mode: powerMode))
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
```

- [ ] **Step 2: Run all Settings and Polling tests to verify compilation and behavior**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test -only-testing:WattlyTests/PollPolicyTests -only-testing:WattlyTests/PanelPresentationTests -only-testing:WattlyTests/SettingsResetTests` (with BypassSandbox: true)
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "feat: simplify background refresh UI with progressive disclosure"
```

---

### Task 3: Unify Process Limit Sections into a Single Card

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:180-195,380-420`

**Interfaces:**
- Consumes: `@AppStorage(StorageKey.memoryProcessLimit)`, `@AppStorage(StorageKey.powerProcessLimit)`
- Produces: Consolidated `cardProcessLimitSection` in `SettingsView`

- [ ] **Step 1: Replace separate memory and power process limit sections with unified cardProcessLimitSection**

In `Wattly/Views/SettingsView.swift`:
1. In `displayGroup`, replace `memoryProcessLimitSection` and `powerProcessLimitSection` with `cardProcessLimitSection`.
2. Replace `memoryProcessLimitSection` and `powerProcessLimitSection` declarations with:

```swift
    // MARK: 카드 펼침 목록

    private var unifiedProcessLimitBinding: Binding<Int> {
        Binding(
            get: { memoryProcessLimit },
            set: { val in
                memoryProcessLimit = val
                powerProcessLimit = val
            }
        )
    }

    private var cardProcessLimitSection: some View {
        SettingsSection(title: "카드 펼침 목록") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("표시할 앱 수")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                    WattlySegment(selection: unifiedProcessLimitBinding, options: [
                        (3, "3개"), (5, "5개"), (7, "7개"),
                    ], fontSize: 11.5, pillVPadding: 6)
                    Text("메모리 및 프로세서 전력 카드를 펼쳤을 때 사용량이 큰 앱부터 표시합니다.")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
```

- [ ] **Step 2: Run test suite to verify settings and process limit tests pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test -only-testing:WattlyTests/SettingsResetTests -only-testing:WattlyTests/MemoryUsageTests -only-testing:WattlyTests/ProcessPowerTests` (with BypassSandbox: true)
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "feat: unify memory and power process limits into single card section"
```

---

### Task 4: Categorize Menu Bar Telemetry Chips into Primary and Advanced

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:766-836`

**Interfaces:**
- Consumes: Menu bar chips `@AppStorage` bindings (`menuCPU`, `menuPower`, `menuBattery`, `menuMem`, `menuCpuTemp`, `menuGpuTemp`, `menuFan`, `menuSClock`, `menuPClock`, `menuEClock`, `menuMemPressure`, `menuBatTemp`)
- Produces: Clean 2-tier menu bar telemetry grid with expandable advanced metrics

- [ ] **Step 1: Implement tiered menuChipGrid with disclosure in SettingsView.swift**

In `Wattly/Views/SettingsView.swift`:
1. Add state variable and helper:
```swift
    @State private var isAdvancedMenuMetricsExpanded = false

    private var hasActiveAdvancedMetrics: Bool {
        menuSClock || menuPClock || menuEClock || menuMemPressure || menuBatTemp
    }
```
2. In `.task` of `SettingsView`, seed `isAdvancedMenuMetricsExpanded`:
```swift
    .task {
        loginMirror = loginItem.isEnabled
        if hasActiveAdvancedMetrics { isAdvancedMenuMetricsExpanded = true }
    }
```
3. Update `menubarSection` and `menuChipGrid`:

```swift
    private var menubarSection: some View {
        SettingsSection(title: "메뉴바") {
            SettingsCard {
                SettingsToggleRow(isOn: $menubarText, divider: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle("텍스트 표시")
                        Text("메뉴바 아이콘 옆에 선택한 지표를 함께 표시합니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("표시할 지표 (복수 선택)")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                    if !menubarText {
                        Text("텍스트 표시를 켜면 선택한 지표가 아이콘 옆에 표시됩니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    menuChipGrid
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            }
        }
    }

    private var menuChipGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        return VStack(alignment: .leading, spacing: 8) {
            // 주요 지표 (Primary)
            LazyVGrid(columns: columns, spacing: 4) {
                menuMetricChip(.cpu, label: "CPU (%)", isOn: menuCPU) { menuCPU.toggle() }
                menuMetricChip(.power, label: "전력 (W)", isOn: menuPower) { menuPower.toggle() }
                menuMetricChip(.battery, label: "배터리 (W)", isOn: menuBattery) { menuBattery.toggle() }
                menuMetricChip(.mem, label: "메모리 (GB)", isOn: menuMem) { menuMem.toggle() }
                menuMetricChip(.cpuTemp, label: "CPU 온도 (°C)", isOn: menuCpuTemp) { menuCpuTemp.toggle() }
                menuMetricChip(.gpuTemp, label: "GPU 온도 (°C)", isOn: menuGpuTemp) { menuGpuTemp.toggle() }
                menuMetricChip(.fan, label: "팬 (RPM)", isOn: menuFan) { menuFan.toggle() }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(t.segTrack))

            // 세부 지표 접기/펼치기 버튼
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAdvancedMenuMetricsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isAdvancedMenuMetricsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    Text(isAdvancedMenuMetricsExpanded ? "세부 지표 접기" : "세부 지표 (코어 클럭·메모리 압력·배터리 온도) 보기")
                        .font(WattlyFont.at(11, weight: .medium))
                }
                .foregroundStyle(t.faint)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            // 세부 지표 (Advanced)
            if isAdvancedMenuMetricsExpanded {
                LazyVGrid(columns: columns, spacing: 4) {
                    menuClockChip(label: "S 코어 클럭 (GHz)", isOn: menuSClock) { menuSClock.toggle() }
                    menuClockChip(label: "P 코어 클럭 (GHz)", isOn: menuPClock) { menuPClock.toggle() }
                    menuClockChip(label: "E 코어 클럭 (GHz)", isOn: menuEClock) { menuEClock.toggle() }
                    menuMetricChip(.mem, label: "메모리 압력 (%)", isOn: menuMemPressure) { menuMemPressure.toggle() }
                    menuMetricChip(.batTemp, label: "배터리 온도 (°C)", isOn: menuBatTemp) { menuBatTemp.toggle() }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(t.segTrack))
            }
        }
    }
```

- [ ] **Step 2: Run all test suites to verify everything builds and passes**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test -only-testing:WattlyTests/SettingsResetTests -only-testing:WattlyTests/PanelPresentationTests` (with BypassSandbox: true)
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "feat: categorize menubar chips into primary and expandable advanced metrics"
```

---

### Task 5: Verify Full Settings Reset and Integration

**Files:**
- Test: `WattlyTests/SettingsResetTests.swift`
- Test: `WattlyTests/PanelPresentationTests.swift`

**Interfaces:**
- Consumes: All updated settings and models

- [ ] **Step 1: Run full test suite across all targets**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData test` (with BypassSandbox: true)
Expected: All tests PASS with 0 failures.

- [ ] **Step 2: Commit any final test documentation**

```bash
git commit --allow-empty -m "chore: verify full test suite passes for settings simplification"
```
