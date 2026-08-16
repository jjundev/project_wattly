# Codebase Design & Architecture Refactoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deepen shallow modules, establish clean seams, centralize fragmented preference state, and modularize monolithic components across Wattly to maximize maintainability, testability, and runtime efficiency.

**Architecture:** 
1. Unify menubar items and formatting behind a single deep `MenuBarText` module with a `MenuBarItemKind` model.
2. Centralize 15+ scattered `@AppStorage` keys into cohesive `CardVisibility` and `MenuBarSelection` domain models, reducing SwiftUI view invalidation overhead.
3. Decouple `SystemMonitor`'s internal battery transient filtering and self-power tracking into isolated, purely testable pipeline modules (`BatteryTelemetryPipeline`, `SelfPowerTracker`).
4. Introduce a mockable `GPUTransport` seam for `GPUProvider` matching `FanTransport` / `TemperatureTransport`.
5. Break down the 1,000-line monolithic `SettingsView` into modular section views and encapsulate privileged helper workflows into `FanControlClient`.

**Tech Stack:** Swift 6.0, SwiftUI, Observation framework, macOS 14.0+ SDK, XCTest / Swift Testing, XcodeGen.

## Global Constraints

- **Language Mode:** Swift 6 with strict concurrency (`Sendable` conformance across actor boundaries).
- **Target OS:** macOS 14.0+ (Sonoma, Sequoia).
- **No Regressions:** All 415 existing unit tests must continue to pass throughout each step.
- **Design Philosophy:** Codebase Design principles — Deep Modules (small interface, rich hidden implementation), pure functions for domain math, clean seams for I/O and tests, single source of truth for preferences.

---

### Task 1: Unify MenuBar Metric Assembly & Deepen `MenuBarText` Interface

**Files:**
- Create: `Wattly/Models/MenuBarItem.swift`
- Modify: `Wattly/Core/MenuBarText.swift:1-104`
- Modify: `Wattly/Core/Accessibility.swift:1-50`
- Modify: `Wattly/Views/MenuBarLabel.swift:1-108`
- Test: `WattlyTests/MenuBarTextTests.swift`
- Test: `WattlyTests/AccessibilityTests.swift`

**Interfaces:**
- Consumes: `CardKind`, `MetricState`, `MetricSample`
- Produces: 
  - `enum MenuBarItem: Sendable, Hashable, Identifiable` (`.card(CardKind)`, `.coreClock(prefix: String)`, `.memPressure`, `.batteryTemp`)
  - `MenuBarText.assemble(items: [MenuBarItem], states: [CardKind: MetricState]) -> String?`
  - `MenuBarText.formatItem(_ item: MenuBarItem, states: [CardKind: MetricState]) -> String`

- [ ] **Step 1: Write the failing tests for `MenuBarItem` and unified `MenuBarText.assemble`**

Add tests to `WattlyTests/MenuBarTextTests.swift` using Swift Testing:
```swift
import Testing
@testable import Wattly

@Suite struct MenuBarItemTests {
    @Test func unifiedAssemblyPreservesCanonicalOrder() {
        let items: [MenuBarItem] = [
            .card(.cpu),
            .coreClock(prefix: "P"),
            .card(.mem),
            .memPressure,
            .card(.battery),
            .batteryTemp
        ]
        let cpuSample = CPUSample(overall: 45.0, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 50.0, activeGHz: 3.45)
        ])
        let memSample = MemorySample(usedGB: 12.5, totalGB: 32.0, wiredGB: 4.0, compressedGB: 2.0, pressurePercent: 35)
        let batterySample = BatterySample(netW: -15.2, milliamps: 1200, volts: 12.6, charging: true, externalConnected: true, temperatureCelsius: 29.5)
        
        let states: [CardKind: MetricState] = [
            .cpu: .value(.cpu(cpuSample)),
            .mem: .value(.memory(memSample)),
            .battery: .value(.battery(batterySample))
        ]
        
        let assembled = MenuBarText.assemble(items: items, states: states)
        #expect(assembled == "CPU 45%  ·  P 3.45 GHz  ·  12.5 GB  ·  압력 35%  ·  +15.2 W  ·  배터리 30°C")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Wattly -destination "platform=macOS" -derivedDataPath .derivedData test -only-testing:WattlyTests/MenuBarItemTests`
Expected: FAIL (Cannot find type `MenuBarItem` in scope).

- [ ] **Step 3: Implement `MenuBarItem.swift` and update `MenuBarText.swift`**

Create `Wattly/Models/MenuBarItem.swift`:
```swift
import Foundation

public enum MenuBarItem: Sendable, Hashable, Identifiable {
    case card(CardKind)
    case coreClock(prefix: String)
    case memPressure
    case batteryTemp

    public var id: String {
        switch self {
        case .card(let kind): return "card.\(kind.rawValue)"
        case .coreClock(let p): return "clock.\(p)"
        case .memPressure: return "memPressure"
        case .batteryTemp: return "batteryTemp"
        }
    }
    
    public var requiredCard: CardKind {
        switch self {
        case .card(let kind): return kind
        case .coreClock: return .cpu
        case .memPressure: return .mem
        case .batteryTemp: return .battery
        }
    }
}
```

Update `Wattly/Core/MenuBarText.swift` to handle `[MenuBarItem]` directly with unified ordering, eliminating the need for `extraParts` split.

- [ ] **Step 4: Update `MenuBarLabel.swift` and `Accessibility.swift` to consume `MenuBarItem`**

Refactor `MenuBarLabel.assembled` and `Accessibility.menuBarLabel` to build a clean `[MenuBarItem]` list and call `MenuBarText.assemble(items:states:)`.

- [ ] **Step 5: Run all unit tests to ensure pass**

Run: `xcodebuild -scheme Wattly -destination "platform=macOS" -derivedDataPath .derivedData test`
Expected: PASS (All tests passing).

- [ ] **Step 6: Commit changes**

```bash
git add Wattly/Models/MenuBarItem.swift Wattly/Core/MenuBarText.swift Wattly/Core/Accessibility.swift Wattly/Views/MenuBarLabel.swift WattlyTests/MenuBarTextTests.swift
git commit -m "refactor: unify menubar item assembly and formatters behind MenuBarItem model"
```

---

### Task 2: Centralize Fragmented Preference State (`CardVisibility` & `MenuBarSelection`)

**Files:**
- Create: `Wattly/Settings/VisibilitySettings.swift`
- Modify: `Wattly/Settings/Settings.swift`
- Modify: `Wattly/Core/SettingsReset.swift`
- Modify: `Wattly/Views/PollPolicyBridge.swift`
- Modify: `Wattly/Views/PopoverContentView.swift`
- Modify: `Wattly/Views/MenuBarLabel.swift`
- Test: `WattlyTests/SettingsResetTests.swift`

**Interfaces:**
- Consumes: `CardKind`, `MenuBarItem`, `Defaults`
- Produces:
  - `struct CardVisibility: Sendable, Equatable` (Encapsulates all 8 card show/hide flags with single query API `isShown(_ card: CardKind) -> Bool`, `activeCards: Set<CardKind>`)
  - `struct MenuBarSelection: Sendable, Equatable` (Encapsulates active menubar items and required provider dependencies)

- [ ] **Step 1: Write unit tests for `CardVisibility` and `MenuBarSelection`**

Add tests to `WattlyTests/SettingsResetTests.swift`:
```swift
func testCardVisibilityDefaultsAndMutations() {
    var visibility = CardVisibility()
    XCTAssertTrue(visibility.isShown(.cpu))
    XCTAssertTrue(visibility.isShown(.power))
    
    visibility.setShown(.gpu, false)
    XCTAssertFalse(visibility.isShown(.gpu))
    XCTAssertTrue(visibility.activeCards.contains(.cpu))
    XCTAssertFalse(visibility.activeCards.contains(.gpu))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Wattly -destination "platform=macOS" -derivedDataPath .derivedData test -only-testing:WattlyTests/SettingsResetTests/testCardVisibilityDefaultsAndMutations`
Expected: FAIL (Cannot find type `CardVisibility`).

- [ ] **Step 3: Implement `VisibilitySettings.swift`**

Create `Wattly/Settings/VisibilitySettings.swift`:
Provides structured helper types that read/write individual standard UserDefaults keys for backward compatibility while presenting a clean, unified interface to views.

- [ ] **Step 4: Refactor `PollPolicyBridge.swift`, `PopoverContentView.swift`, and `MenuBarLabel.swift`**

Replace the 15+ `@AppStorage` properties in each file with clean bindings or lightweight observed models, simplifying `PollPolicyBridge` from 105 lines of boilerplate to ~40 lines.

- [ ] **Step 5: Run tests to verify compatibility**

Run: `xcodebuild -scheme Wattly -destination "platform=macOS" -derivedDataPath .derivedData test`
Expected: PASS.

- [ ] **Step 6: Commit changes**

```bash
git add Wattly/Settings/VisibilitySettings.swift Wattly/Settings/Settings.swift Wattly/Core/SettingsReset.swift Wattly/Views/PollPolicyBridge.swift Wattly/Views/PopoverContentView.swift Wattly/Views/MenuBarLabel.swift WattlyTests/SettingsResetTests.swift
git commit -m "refactor: centralize card visibility and menubar selection preference models"
```

---

### Task 3: Decouple `SystemMonitor` Internal Telemetry Pipelines

**Files:**
- Create: `Wattly/Core/BatteryTelemetryPipeline.swift`
- Create: `Wattly/Core/SelfPowerTracker.swift`
- Modify: `Wattly/Core/SystemMonitor.swift:1-550`
- Create: `WattlyTests/BatteryTelemetryPipelineTests.swift`
- Test: `WattlyTests/SystemMonitorTests.swift`
- Test: `WattlyTests/SelfPowerTests.swift`

**Interfaces:**
- Consumes: `BatterySample`, `ContinuousClock.Instant`, `SelfEnergySampling`, `PowerSmoothing`
- Produces:
  - `struct BatteryTelemetryPipeline: Sendable` (`ingest(_ raw: BatterySample, at instant: Instant) -> BatterySample`, `reset()`)
  - `struct SelfPowerTracker: Sendable` (`sample(using energySource: any SelfEnergySampling, at instant: Instant) -> Double?`)

- [ ] **Step 1: Write isolated tests for `BatteryTelemetryPipeline`**

Create `WattlyTests/BatteryTelemetryPipelineTests.swift`:
```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryTelemetryPipelineTests {
    @Test func suppressStaleRemainingTimeOnAdapterDisconnect() {
        var pipeline = BatteryTelemetryPipeline()
        let clock = ContinuousClock()
        let t0 = clock.now
        
        // Connected state
        let sampleConnected = BatterySample(netW: -20, milliamps: 1500, volts: 12, charging: true, externalConnected: true, timeRemainingMinutes: 45)
        let out1 = pipeline.ingest(sampleConnected, at: t0)
        #expect(out1.timeRemainingMinutes == 45)
        
        // Immediate disconnect with stale 45 min
        let sampleDisconnected = BatterySample(netW: 15, milliamps: 1200, volts: 12, charging: false, externalConnected: false, timeRemainingMinutes: 45)
        let out2 = pipeline.ingest(sampleDisconnected, at: t0.advanced(by: .seconds(1)))
        #expect(out2.timeRemainingMinutes == nil, "Stale time from connected era must be suppressed")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -scheme Wattly -destination "platform=macOS" -derivedDataPath .derivedData test`
Expected: FAIL (Cannot find type `BatteryTelemetryPipeline`).

- [ ] **Step 3: Implement `BatteryTelemetryPipeline.swift` & `SelfPowerTracker.swift`**

Create `Wattly/Core/BatteryTelemetryPipeline.swift` moving transient suppression, 1-minute EMA, and runtime projection out of `SystemMonitor`.
Create `Wattly/Core/SelfPowerTracker.swift` moving self-power nanojoule diffing out of `SystemMonitor`.
Run `xcodegen generate`.

- [ ] **Step 4: Update `SystemMonitor.swift` to delegate to these pipelines**

Simplify `SystemMonitor.apply(_ reading: ...)` and `sampleSelfPower` to single-line pipeline invocations, cutting ~120 lines of mixed concerns from `SystemMonitor.swift`.

- [ ] **Step 5: Run all test suites**

Run: `xcodebuild -scheme Wattly -destination "platform=macOS" -derivedDataPath .derivedData test`
Expected: PASS.

- [ ] **Step 6: Commit changes**

```bash
git add Wattly/Core/BatteryTelemetryPipeline.swift Wattly/Core/SelfPowerTracker.swift Wattly/Core/SystemMonitor.swift WattlyTests/BatteryTelemetryPipelineTests.swift Wattly.xcodeproj
git commit -m "refactor: extract BatteryTelemetryPipeline and SelfPowerTracker internal seams from SystemMonitor"
```

---

### Task 4: Introduce Mockable `GPUTransport` Seam for `GPUProvider`

**Files:**
- Create: `Wattly/Providers/GPUTransport.swift`
- Modify: `Wattly/Providers/GPUProvider.swift:1-89`
- Modify: `WattlyTests/GPUProviderTests.swift`

**Interfaces:**
- Consumes: `GPUStatsSnapshot`
- Produces:
  - `protocol GPUTransport: Sendable` (`readPerformanceStatistics() -> GPUStatsSnapshot?`, `readCoreCount() -> Int`)
  - `final class IOAcceleratorGPUTransport: GPUTransport, @unchecked Sendable`
  - `GPUProvider.init(transport: any GPUTransport, clock: ...)`

- [ ] **Step 1: Write tests using mock `GPUTransport`**

Update `WattlyTests/GPUProviderTests.swift`:
```swift
import Testing
@testable import Wattly

struct FakeGPUTransport: GPUTransport {
    var stats: GPUStatsSnapshot?
    var coreCount: Int = 10
    
    func readPerformanceStatistics() -> GPUStatsSnapshot? { stats }
    func readCoreCount() -> Int { coreCount }
}

@Suite struct GPUProviderSeamTests {
    @Test func unavailableWhenTransportFails() async {
        let provider = GPUProvider(transport: FakeGPUTransport(stats: nil))
        let reading = await provider.read(at: ContinuousClock().now)
        guard case .unavailable(let reason) = reading else {
            Issue.record("Expected unavailable")
            return
        }
        #expect(reason.shortMessage == "오류")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Wattly -destination "platform=macOS" -derivedDataPath .derivedData test -only-testing:WattlyTests/GPUProviderSeamTests`
Expected: FAIL (No initializer with `transport`).

- [ ] **Step 3: Implement `GPUTransport.swift` & update `GPUProvider.swift`**

Create `Wattly/Providers/GPUTransport.swift` with `IOAcceleratorGPUTransport` implementing real IOKit lookup and `GPUProvider` accepting `any GPUTransport` (defaulting to live).

- [ ] **Step 4: Run tests**

Run: `xcodebuild -scheme Wattly -destination "platform=macOS" -derivedDataPath .derivedData test`
Expected: PASS.

- [ ] **Step 5: Commit changes**

```bash
git add Wattly/Providers/GPUTransport.swift Wattly/Providers/GPUProvider.swift WattlyTests/GPUProviderTests.swift
git commit -m "feat: establish GPUTransport protocol seam for GPUProvider testability"
```

---

### Task 5: Componentize `SettingsView` & Encapsulate Helper Management

**Files:**
- Modify: `Wattly/Control/FanControlClient.swift:1-173`
- Create: `Wattly/Views/Settings/SettingsDisplaySection.swift`
- Create: `Wattly/Views/Settings/SettingsBehaviorSection.swift`
- Create: `Wattly/Views/Settings/SettingsFanCurveSection.swift`
- Create: `Wattly/Views/Settings/SettingsThresholdSection.swift`
- Create: `Wattly/Views/Settings/SettingsMenuBarSection.swift`
- Modify: `Wattly/Views/SettingsView.swift:1-1000`

**Interfaces:**
- Consumes: `SystemMonitor`, `FanControlClient`, `Tokens`
- Produces:
  - `FanControlClient.installAndEngage(curve: FanCurve, window: NSWindow?) async -> Bool`
  - Modular sub-views in `Wattly/Views/Settings/`

- [ ] **Step 1: Add helper orchestration methods to `FanControlClient`**

Move `installHelperThenEngage`, `raiseFront`, and activation policy handling into `FanControlClient.swift`.

- [ ] **Step 2: Extract modular section views under `Wattly/Views/Settings/`**

Decompose `SettingsView.swift` into clean, focused sub-views:
- `SettingsDisplaySection`: Themes, Layout mode, Card Visibility toggles.
- `SettingsBehaviorSection`: Polling interval, Power mode, Smoothing.
- `SettingsThresholdSection`: Warn/Crit sliders and GPU warning toggle.
- `SettingsFanCurveSection`: Preset selector, Curve graph editor, Fan status badge.
- `SettingsMenuBarSection`: Menu chip multi-select grid and advanced metrics.

- [ ] **Step 3: Simplify `SettingsView.swift`**

Reduce `SettingsView.swift` from 1,000 lines to under 150 lines, composing the section views cleanly.

- [ ] **Step 4: Run all tests and build verification**

Run: `xcodebuild -scheme Wattly -destination "platform=macOS" -derivedDataPath .derivedData test`
Expected: PASS (All 415+ tests succeed).

- [ ] **Step 5: Commit changes**

```bash
git add Wattly/Control/FanControlClient.swift Wattly/Views/Settings/ Wattly/Views/SettingsView.swift
git commit -m "refactor: modularize SettingsView sections and encapsulate helper installation in FanControlClient"
```

---

## Verification Plan

### Automated Test Suite
- Run full test suite via Xcodebuild:
  `xcodebuild -scheme Wattly -destination "platform=macOS" -derivedDataPath .derivedData test`
- Verify 100% pass across all existing and new test suites.

### Manual Verification
- Launch Wattly app on macOS.
- Verify Menubar text renders accurately for selected metrics in correct order.
- Open Popover panel in Modes A, B, and C to verify card presentation, sparklines, and expansion.
- Open Settings window, toggle preferences, test Fan Curve preset changes, and confirm live sync with Popover and Menubar.
