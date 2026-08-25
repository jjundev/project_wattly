# Discharge Stop Transient Flicker Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the 1–2 second transient disappearing/flicker of the "한 번만 완충" (Top-Up) and "수동 방전" (Manual Discharge) rows when pressing "방전 중지" (Stop Discharge) in the menu bar popover.

**Architecture:** 
1. Use physical adapter presence telemetry (`AdapterDetails.Watts > 0` from `AppleSmartBattery`) across `BatteryProvider` and `FanControlDaemon` so that `s.externalConnected` and `status.isPowerAdapterConnected` remain `true` throughout forced discharge and its immediate deactivation recovery window.
2. Extract a pure policy `BatterySectionPresentation.shouldShowBatteryControlRows(...)` to gate the control rows cleanly without optional unwrapping bugs or transient gaps in `CardExpandRegion`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, IOKit (`AppleSmartBattery`), `BatterySample`, `BatteryControlServiceStatus`.

## Global Constraints

- Work only in `/Users/hyunjun_macbook_pro/.gemini/antigravity/worktrees/project_wattly/implement_manual_automatic_discharge`.
- Preserve all existing manual-discharge and automatic-discharge features, button styles, colors, and string catalogs.
- During forced discharge and discharge stop recovery, physical adapter connection must remain `true` while the cable is physically attached.
- When the adapter cable is physically unplugged (where `AdapterDetails.Watts` is 0 or absent and `ExternalConnected` is false), the control rows must cleanly hide as intended.
- Maintain 100% pass rate across the test suite (`xcodebuild test`).

---

### Task 1: Robust Physical Adapter Detection in `BatteryProvider` & `FanControlDaemon`

**Files:**
- Modify: `Wattly/Providers/BatteryProvider.swift:108`
- Modify: `WattlyFanDaemon/FanControlDaemon.swift:178-185`
- Test: `WattlyTests/BatteryDaemonControlServiceTests.swift`

**Interfaces:**
- `AppleSmartBattery` property `AdapterDetails.Watts`: integer representing adapter rated wattage (e.g. 68, 70, 96, 140).
- `BatterySample.externalConnected: Bool` remains `true` whenever `ExternalConnected == true || AdapterDetails.Watts > 0`.
- `BatteryPowerSourceReading.isPluggedIn: Bool` remains `true` whenever `isPowerSourceAC || isExternalConnected || adapterPowerWatts > 0`.

- [ ] **Step 1: Write test for daemon power reading with `adapterPowerWatts` during transition**

Add test in `WattlyTests/BatteryDaemonControlServiceTests.swift`:

```swift
@Test func activeDischargePreservesPluggedInStateWhenAdapterWattsPresent() throws {
    let hardware = MockBatteryHardware()
    hardware.reportedGate = .allowed
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501,
        store: PolicyStoreSpy(),
        engine: BatteryControlEngine(hardware: hardware),
        now: { 100 })
    let service = BatteryDaemonControlService(coordinator: coordinator)
    
    // Sample with isPluggedIn false (SMC transient cutoff) but adapterPowerWatts present (68W)
    let status = service.sample(
        currentReading: .init(
            stateOfCharge: 80,
            isPluggedIn: false,
            adapterPowerWatts: 68),
        force: true)
    
    #expect(status.isPowerAdapterConnected == true)
}
```

- [ ] **Step 2: Run test to verify status**

Run:
```bash
xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryDaemonControlServiceTests
```

- [ ] **Step 3: Update `BatteryProvider.swift` and `FanControlDaemon.swift`**

In `Wattly/Providers/BatteryProvider.swift:108`:
```swift
let rawExternalConnected = bool(service, "ExternalConnected") ?? false
let adapterWatts = (dict(service, "AdapterDetails")?["Watts"] as? NSNumber)?.intValue ?? 0
let externalConnected = rawExternalConnected || adapterWatts > 0
```

In `WattlyFanDaemon/FanControlDaemon.swift:178-185`:
```swift
let isPowerSourceAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
let telemetry = readBatteryTelemetryFromRegistry()
let hasAdapterWatts = (telemetry.adapterPowerWatts ?? 0) > 0
let isExternalConnected = (telemetry.isExternalConnected == true) || hasAdapterWatts
let isPlugged = isPowerSourceAC || isExternalConnected

return BatteryPowerSourceReading(
    stateOfCharge: soc,
    isPluggedIn: isPlugged,
    temperatureCelsius: telemetry.temperatureCelsius,
    adapterPowerWatts: telemetry.adapterPowerWatts)
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryDaemonControlServiceTests
```
Expected: PASS.

- [ ] **Step 5: Commit Task 1**

```bash
git add Wattly/Providers/BatteryProvider.swift WattlyFanDaemon/FanControlDaemon.swift WattlyTests/BatteryDaemonControlServiceTests.swift
git commit -m "fix(provider): robust physical adapter detection via AdapterDetails.Watts"
```

---

### Task 2: Pure Control Rows Visibility Policy & Stable Gating in `CardExpandRegion`

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift`
- Modify: `Wattly/Views/CardExpandRegion.swift:335`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`
- Test: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- `BatterySectionPresentation.shouldShowBatteryControlRows(sampleCharging:sampleExternalConnected:serviceAdapterConnected:activity:manualDischargeActive:) -> Bool`
- `CardExpandRegion` calls `BatterySectionPresentation.shouldShowBatteryControlRows(...)` inside `if let batteryControl` block to gate Top-Up and Manual Discharge rows without transient flickering.

- [ ] **Step 1: Write test for control rows visibility policy**

Add test in `WattlyTests/BatterySectionPresentationTests.swift`:
```swift
@Test func batteryControlRowsVisibilityPolicy() {
    // 1. Normal plugged in with adapter connected -> true
    #expect(BatterySectionPresentation.shouldShowBatteryControlRows(
        sampleCharging: false,
        sampleExternalConnected: true,
        serviceAdapterConnected: true,
        activity: .holdingAtLimit,
        manualDischargeActive: false
    ))

    // 2. Active forced discharge -> true
    #expect(BatterySectionPresentation.shouldShowBatteryControlRows(
        sampleCharging: false,
        sampleExternalConnected: false,
        serviceAdapterConnected: false,
        activity: .discharging,
        manualDischargeActive: true
    ))

    // 3. Forced discharge stop transition (activity holding, desired config active) -> true
    #expect(BatterySectionPresentation.shouldShowBatteryControlRows(
        sampleCharging: false,
        sampleExternalConnected: false,
        serviceAdapterConnected: false,
        activity: .holdingAtLimit,
        manualDischargeActive: true
    ))

    // 4. Pure battery unplugged (all false) -> false
    #expect(!BatterySectionPresentation.shouldShowBatteryControlRows(
        sampleCharging: false,
        sampleExternalConnected: false,
        serviceAdapterConnected: false,
        activity: nil,
        manualDischargeActive: false
    ))
}
```

- [ ] **Step 2: Implement `shouldShowBatteryControlRows` in `BatterySectionPresentation.swift`**

In `Wattly/Core/BatterySectionPresentation.swift`:
```swift
static func shouldShowBatteryControlRows(
    sampleCharging: Bool,
    sampleExternalConnected: Bool,
    serviceAdapterConnected: Bool,
    activity: BatteryControlActivity?,
    manualDischargeActive: Bool
) -> Bool {
    sampleCharging
        || sampleExternalConnected
        || serviceAdapterConnected
        || activity == .discharging
        || activity == .topUp
        || manualDischargeActive
}
```

- [ ] **Step 3: Update `CardExpandRegion.swift`**

In `Wattly/Views/CardExpandRegion.swift:335`:
```swift
if let batteryControl {
    let showControlRows = BatterySectionPresentation.shouldShowBatteryControlRows(
        sampleCharging: s.charging,
        sampleExternalConnected: s.externalConnected,
        serviceAdapterConnected: batteryControl.status.isPowerAdapterConnected,
        activity: batteryControl.status.activity,
        manualDischargeActive: batteryControl.status.desiredConfiguration?.manualDischargeActive == true
    )

    if showControlRows {
        Divider().background(t.line).opacity(0.6)
        batteryTopUpRow(batteryControl, s)
        if shouldShowDischargeRow(batteryControl, s) {
            batteryDischargeRow(batteryControl, s)
        }
    }
}
```

- [ ] **Step 4: Run targeted tests**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatterySectionPresentationTests -only-testing:WattlyTests/CardPresentationTests
```
Expected: PASS.

- [ ] **Step 5: Run full test suite**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
```
Expected: All 1,046+ tests PASS.

- [ ] **Step 6: Commit Task 2**

```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/CardExpandRegion.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "fix(ui): prevent control rows from flickering when stopping forced discharge"
```

---

## Self-Review

1. **Spec coverage:** Addresses the exact 1–2 second transition flicker when clicking "방전 중지" by bridging the physical hardware reconnection delay and making control rows visibility pure and tested.
2. **Placeholder scan:** No TODOs or placeholder steps.
3. **Type consistency:** Matches existing `BatteryPowerSourceReading`, `BatterySample`, and `BatteryControlServiceStatus` types.
