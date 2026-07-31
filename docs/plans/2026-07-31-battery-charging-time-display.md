# Battery Charging Time Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide subtext information on the collapsed Battery card during charging, and present "완충까지 남은 시간" (Time remaining until full charge) inside the expanded Battery card detail region when charging.

**Architecture:** Extend `BatteryPower` with a pure `estimatedTimeToFullMinutes` helper and update `BatteryRuntimeProjection` to project time-to-full during charging. `CardPresentation` will enforce that collapsed `subText` remains `nil` during charging while providing `batteryTimeToFullLabel` and `batteryTimeToFullText` for the expanded card. `CardExpandRegion` will render the "완충까지 남은 시간" detail row when expanded while charging.

**Tech Stack:** Swift, SwiftUI, Swift Testing (`import Testing`), IOKit (AppleSmartBattery)

## Global Constraints

- Preserve all existing API contracts and UI design tokens (`WattlyFont`, `Tokens`, `t.sub`, `t.faint`).
- All time/sign/label presentation rules live in pure `CardPresentation` and `BatteryPower` modules with 100% test coverage before touching UI views.
- Collapsed card subtext (`CardPresentation.subText`) must return `nil` when `charging == true`.

---

### Task 1: Add `maxWh` to `BatterySample` & `estimatedTimeToFullMinutes` to `BatteryPower`

**Files:**
- Modify: `Wattly/Models/MetricSample.swift:105-138`
- Modify: `Wattly/Core/BatteryPower.swift:65-79`
- Modify: `Wattly/Providers/BatteryProvider.swift:29-73`
- Modify: `Wattly/Providers/BatteryProvider.swift:104-125`
- Modify: `Wattly/Core/SystemMonitor.swift:398-412`
- Test: `WattlyTests/BatteryPowerTests.swift:97-140`

**Interfaces:**
- Consumes: `rawMaxCapacityMilliampHours`, `rawCurrentCapacityMilliampHours`, `volts`, `netW`, `remainingWh`
- Produces: `BatterySample.maxWh: Double?`, `estimatedTimeToFullMinutes(remainingWh: Double?, maxWh: Double?, netW: Double) -> Int?`

- [ ] **Step 1: Write failing unit tests for `estimatedTimeToFullMinutes` in `BatteryPowerTests.swift`**

```swift
@Test func estimatedTimeToFullCalculatesMinutesWhenCharging() {
    // 30 Wh remaining out of 60 Wh max, charging at netW = -20.0 W -> needed 30 Wh / 20 W = 1.5 h = 90 min
    #expect(estimatedTimeToFullMinutes(remainingWh: 30.0, maxWh: 60.0, netW: -20.0) == 90)
    // Discharging (netW > 0) -> nil
    #expect(estimatedTimeToFullMinutes(remainingWh: 30.0, maxWh: 60.0, netW: 15.0) == nil)
    // Fully charged or invalid inputs -> nil
    #expect(estimatedTimeToFullMinutes(remainingWh: 60.0, maxWh: 60.0, netW: -10.0) == nil)
    #expect(estimatedTimeToFullMinutes(remainingWh: nil, maxWh: 60.0, netW: -10.0) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build`
Expected: FAIL (symbol `estimatedTimeToFullMinutes` not found)

- [ ] **Step 3: Add `maxWh` to `BatterySample`, compute it in `BatteryProvider`, pass it in `SystemMonitor.batterySmoothed`, and implement `estimatedTimeToFullMinutes` in `BatteryPower.swift`**

In `Wattly/Models/MetricSample.swift`:
```swift
struct BatterySample: Sendable, Equatable {
    var netW: Double
    var milliamps: Int
    var volts: Double
    var charging: Bool
    var externalConnected: Bool
    var remainingWh: Double? = nil
    var maxWh: Double? = nil
    var timeRemainingMinutes: Int? = nil
    var projectedTimeRemainingMinutes: Int? = nil
    var efficiencyPercent: Double? = nil
    var cycleCount: Int? = nil
    var average1mW: Double? = nil
}
```

In `Wattly/Core/BatteryPower.swift`:
```swift
/// Estimated time until full charge from current energy, maximum energy capacity, and live charging power.
func estimatedTimeToFullMinutes(remainingWh: Double?, maxWh: Double?, netW: Double) -> Int? {
    guard let remainingWh, remainingWh.isFinite, remainingWh >= 0,
          let maxWh, maxWh.isFinite, maxWh > remainingWh,
          netW.isFinite, netW < -0.2 else { return nil }
    let neededWh = maxWh - remainingWh
    let chargingW = abs(netW)
    let minutes = neededWh / chargingW * 60
    guard minutes.isFinite, (1...1_440).contains(minutes) else { return nil }
    return Int(minutes.rounded())
}
```

In `Wattly/Providers/BatteryProvider.swift`:
Compute `maxWh` from `rawMaxCapacityMilliampHours` and `volts`:
```swift
maxWh: remainingWattHours(
    rawCapacityMilliampHours: registry?.rawMaxCapacityMilliampHours ?? 0,
    volts: volts)
```
Also in `appleSmartBatterySnapshot()`:
```swift
timeRemainingMinutes: number(service, "TimeRemaining")?.intValue
    ?? number(service, "AvgTimeToFull")?.intValue
    ?? number(service, "TimeToFull")?.intValue
```

In `Wattly/Core/SystemMonitor.swift`:
```swift
    private static func batterySmoothed(from raw: BatterySample, netW: Double) -> BatterySample {
        let mA = raw.volts > 0 ? Int((abs(netW) * 1000 / raw.volts).rounded()) : raw.milliamps
        return BatterySample(
            netW: netW,
            milliamps: mA,
            volts: raw.volts,
            charging: isCharging(netW: netW),
            externalConnected: raw.externalConnected,
            remainingWh: raw.remainingWh,
            maxWh: raw.maxWh,
            timeRemainingMinutes: raw.timeRemainingMinutes,
            projectedTimeRemainingMinutes: raw.projectedTimeRemainingMinutes,
            efficiencyPercent: raw.efficiencyPercent,
            cycleCount: raw.cycleCount,
            average1mW: raw.average1mW)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Models/MetricSample.swift Wattly/Core/BatteryPower.swift Wattly/Providers/BatteryProvider.swift Wattly/Core/SystemMonitor.swift WattlyTests/BatteryPowerTests.swift
git commit -m "feat: add maxWh and estimatedTimeToFullMinutes helper"
```

---

### Task 2: Update `BatteryRuntimeProjection` to support charging projection

**Files:**
- Modify: `Wattly/Core/BatteryRuntimeProjection.swift:59-72`
- Test: `WattlyTests/BatteryRuntimeProjectionTests.swift:1-120`

**Interfaces:**
- Consumes: `BatterySample`, `estimatedTimeToFullMinutes`, `estimatedTimeRemainingMinutes`
- Produces: `BatteryRuntimeProjection.ingest(_ sample: BatterySample, at now: ContinuousClock.Instant) -> Int?`

- [ ] **Step 1: Write failing unit test in `BatteryRuntimeProjectionTests.swift`**

```swift
@Test func ingestProjectsChargingTimeToFull() {
    var projection = BatteryRuntimeProjection()
    let now = ContinuousClock.now
    let chargingSample = BatterySample(
        netW: -20.0,
        milliamps: 1500,
        volts: 12.5,
        charging: true,
        externalConnected: true,
        remainingWh: 30.0,
        maxWh: 60.0
    )
    let minutes = projection.ingest(chargingSample, at: now)
    #expect(minutes == 90)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build`
Expected: FAIL (`minutes` is `nil` because `candidate` guards `!sample.charging`)

- [ ] **Step 3: Update `BatteryRuntimeProjection.candidate` to handle charging**

In `Wattly/Core/BatteryRuntimeProjection.swift`:
```swift
    private func candidate(for sample: BatterySample) -> Candidate? {
        if sample.charging {
            if let minutes = validatedTimeRemainingMinutes(sample.timeRemainingMinutes) {
                return Candidate(minutes: minutes, source: .registry)
            }
            if let average = sample.average1mW,
               let minutes = estimatedTimeToFullMinutes(remainingWh: sample.remainingWh, maxWh: sample.maxWh, netW: average) {
                return Candidate(minutes: minutes, source: .estimated)
            }
            if let minutes = estimatedTimeToFullMinutes(remainingWh: sample.remainingWh, maxWh: sample.maxWh, netW: sample.netW) {
                return Candidate(minutes: minutes, source: .estimated)
            }
            return nil
        } else {
            if let minutes = validatedTimeRemainingMinutes(sample.timeRemainingMinutes) {
                return Candidate(minutes: minutes, source: .registry)
            }
            if let average = sample.average1mW,
               let minutes = estimatedTimeRemainingMinutes(remainingWattHours: sample.remainingWh, netW: average) {
                return Candidate(minutes: minutes, source: .estimated)
            }
            if let minutes = estimatedTimeRemainingMinutes(remainingWattHours: sample.remainingWh, netW: sample.netW) {
                return Candidate(minutes: minutes, source: .estimated)
            }
            return nil
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/BatteryRuntimeProjection.swift WattlyTests/BatteryRuntimeProjectionTests.swift
git commit -m "feat: project battery time to full when charging"
```

---

### Task 3: Formulate `CardPresentation` rules for charging time-to-full and collapsed subtext

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift:240-250`
- Test: `WattlyTests/CardPresentationTests.swift:65-100`

**Interfaces:**
- Consumes: `BatterySample`
- Produces: `CardPresentation.batteryTimeToFullLabel: String`, `CardPresentation.batteryTimeToFullText(_ s: BatterySample) -> String?`, `CardPresentation.subText(state) -> String?`

- [ ] **Step 1: Write failing unit tests in `CardPresentationTests.swift`**

```swift
@Test func batteryChargingDisplayRules() {
    let charging = BatterySample(
        netW: -20.0,
        milliamps: 1500,
        volts: 12.5,
        charging: true,
        externalConnected: true,
        remainingWh: 30.0,
        maxWh: 60.0,
        projectedTimeRemainingMinutes: 90
    )
    let state = MetricState.value(.battery(charging))
    // Collapsed subText must be nil when charging
    #expect(CardPresentation.subText(state) == nil)
    // Label and text for expanded view
    #expect(CardPresentation.batteryTimeToFullLabel == "완충까지 남은 시간")
    #expect(CardPresentation.batteryTimeToFullText(charging) == "약 1시간 30분 남음")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build`
Expected: FAIL (missing `batteryTimeToFullLabel` / `batteryTimeToFullText`)

- [ ] **Step 3: Implement `batteryTimeToFullLabel` and `batteryTimeToFullText` in `CardPresentation.swift`**

In `Wattly/Core/CardPresentation.swift`:
```swift
    static let batteryTimeToFullLabel = "완충까지 남은 시간"

    static func batteryTimeToFullText(_ s: BatterySample) -> String? {
        guard s.charging,
              let totalMinutes = validatedTimeRemainingMinutes(s.projectedTimeRemainingMinutes)
        else { return nil }
        return "약 \(totalMinutes / 60)시간 \(totalMinutes % 60)분 남음"
    }
```
And verify `batteryRemainingTimeSummary(_ s: BatterySample)` remains guarded by `guard !s.charging` so `subText` for collapsed card returns `nil` when charging.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat: add batteryTimeToFull presentation helpers and enforce nil subText on collapsed charging card"
```

---

### Task 4: Render "완충까지 남은 시간" in `CardExpandRegion`

**Files:**
- Modify: `Wattly/Views/CardExpandRegion.swift:151-169`
- Test: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- Consumes: `CardPresentation.batteryTimeToFullLabel`, `CardPresentation.batteryTimeToFullText(s)`
- Produces: Expanded Battery card detail row for time remaining until full charge

- [ ] **Step 1: Update `batteryExpand` in `CardExpandRegion.swift`**

In `Wattly/Views/CardExpandRegion.swift`:
```swift
    private func batteryExpand(_ s: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if s.charging, let value = CardPresentation.batteryTimeToFullText(s) {
                batteryDetailRow(label: CardPresentation.batteryTimeToFullLabel, value: value)
            }
            if let value = CardPresentation.batteryAverage1mText(s) {
                batteryDetailRow(label: CardPresentation.batteryAverage1mLabel, value: value)
            }
            if let value = CardPresentation.batteryRemainingCapacityText(s) {
                batteryDetailRow(label: CardPresentation.batteryRemainingCapacityLabel, value: value)
            }
            if showBatteryEfficiency, let value = CardPresentation.batteryEfficiencyText(s) {
                batteryDetailRow(label: CardPresentation.batteryEfficiencyLabel, value: value)
            }
            if let value = CardPresentation.batteryCycleText(s) {
                batteryDetailRow(label: CardPresentation.batteryCycleLabel, value: value)
            }
            batteryDetailRow(label: "전류", value: CardPresentation.batteryCurrentText(s))
            batteryDetailRow(label: "전압", value: CardPresentation.batteryVoltageText(s))
        }
        .padding(.top, 8)
    }
```

- [ ] **Step 2: Run full unit test suite to verify UI rendering and full codebase compatibility**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build`
Expected: PASS (all tests pass, 0 failures)

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/CardExpandRegion.swift
git commit -m "feat: render time to full charge in expanded battery card region"
```

---

## Verification Plan

### Automated Tests
- Run `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build`
- Verify all unit test suites pass, including `BatteryPowerTests`, `BatteryRuntimeProjectionTests`, `CardPresentationTests`, and `SystemMonitorTests`.

### Manual Verification
- Launch the app or build via `xcodebuild build` to verify clean build without warnings.
- Confirm collapsed battery card displays no subText during charging.
- Confirm expanded battery card displays "완충까지 남은 시간" (e.g. "약 1시간 30분 남음") when charging.
