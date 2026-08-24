# Dynamic Battery Charge Time Calculation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dynamically calculate and display the remaining battery charge time according to the active charge limit (e.g., 85%) and 1-time full charge ("한 번만 완충" / Top Up) state, displaying targeted copy such as `"85%까지 약 25분 남음"` and seamlessly switching to `"완충까지 약 1시간 10분 남음"` when Top Up is active.

**Architecture:** Pure target energy and duration math in `BatteryPower`, stateful countdown projection with target-aware re-anchoring in `BatteryRuntimeProjection` and `BatteryTelemetryPipeline`, target configuration injection from `BatteryControlBridge` (which receives `SystemMonitor` and observes `@AppStorage` + `BatteryControlClient.status`) into `SystemMonitor`, and single-source-of-truth text formatting in `CardPresentation` consumed by `MetricCardView`, `PopoverHeroView`, `CardExpandRegion`, and `Accessibility`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing framework (`import Testing`), IOKit / SMC telemetry.

## Global Constraints

- **Language / Copy:** Korean copy for user-facing strings (e.g. `"%lld%%까지 약 %@ 남음"`, `"완충까지 약 %@ 남음"`, `"%lld%%까지 남은 시간"`).
- **Pure Math Isolation:** All unit-testable math and algorithms belong in pure structs/enums (`BatteryPower`, `BatteryRuntimeProjection`, `CardPresentation`) without SwiftUI or IOKit imports.
- **Single Source of Truth:** `CardPresentation` owns all card text rules; views (`MetricCardView`, `PopoverHeroView`, `CardExpandRegion`) must not duplicate formatting branches.
- **Clamped Range:** Target percentage is clamped between 50% and 100%. If current capacity $\ge$ target capacity ($E_{needed} \le 0$), remaining charge time must evaluate to `nil`.

---

### Task 1: Extend Pure Math in `BatteryPower.swift` & Unit Tests

**Files:**
- Modify: `Wattly/Core/BatteryPower.swift:84-95`
- Test: `WattlyTests/BatteryPowerTests.swift:145-154`

**Interfaces:**
- Produces: `func estimatedTimeToTargetMinutes(remainingWh: Double?, maxWh: Double?, targetPercentage: Int, netW: Double) -> Int?`
- Produces: `func estimatedTimeToFullMinutes(remainingWh: Double?, maxWh: Double?, netW: Double) -> Int?` (delegates to target 100%)

- [ ] **Step 1: Write failing tests in `BatteryPowerTests.swift`**

```swift
    @Test func estimatedTimeToTargetCalculatesMinutesForCustomLimit() {
        // 30 Wh remaining, 60 Wh max, 80% target = 48 Wh target. Needed = 18 Wh.
        // Charging at netW = -20.0 W -> 18 / 20 = 0.9 h = 54 min.
        #expect(estimatedTimeToTargetMinutes(remainingWh: 30.0, maxWh: 60.0, targetPercentage: 80, netW: -20.0) == 54)
        
        // 85% limit: target = 51 Wh. Needed = 21 Wh. 21 / 20 = 1.05 h = 63 min.
        #expect(estimatedTimeToTargetMinutes(remainingWh: 30.0, maxWh: 60.0, targetPercentage: 85, netW: -20.0) == 63)
        
        // Already at or above target (e.g. 50 Wh remaining, 80% target = 48 Wh) -> nil
        #expect(estimatedTimeToTargetMinutes(remainingWh: 50.0, maxWh: 60.0, targetPercentage: 80, netW: -20.0) == nil)
        
        // 100% target delegates identically
        #expect(estimatedTimeToTargetMinutes(remainingWh: 30.0, maxWh: 60.0, targetPercentage: 100, netW: -20.0) == 90)
        #expect(estimatedTimeToFullMinutes(remainingWh: 30.0, maxWh: 60.0, netW: -20.0) == 90)
    }

    @Test func estimatedTimeToTargetRejectsInvalidTargetPercentages() {
        #expect(estimatedTimeToTargetMinutes(remainingWh: 30.0, maxWh: 60.0, targetPercentage: 40, netW: -20.0) == nil)
        #expect(estimatedTimeToTargetMinutes(remainingWh: 30.0, maxWh: 60.0, targetPercentage: 105, netW: -20.0) == nil)
    }
```

- [ ] **Step 2: Run tests to verify failure**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/BatteryPowerTests`
Expected: FAIL with "estimatedTimeToTargetMinutes not found"

- [ ] **Step 3: Implement `estimatedTimeToTargetMinutes` in `BatteryPower.swift`**

```swift
/// Estimated time until target charge percentage from current energy, maximum energy capacity,
/// target percentage (50...100), and live charging power.
func estimatedTimeToTargetMinutes(
    remainingWh: Double?,
    maxWh: Double?,
    targetPercentage: Int = 100,
    netW: Double
) -> Int? {
    guard let remainingWh, remainingWh.isFinite, remainingWh >= 0,
          let maxWh, maxWh.isFinite, maxWh > 0,
          (50...100).contains(targetPercentage),
          netW.isFinite, netW < -0.2 else { return nil }
    let targetWh = maxWh * (Double(targetPercentage) / 100.0)
    let neededWh = targetWh - remainingWh
    guard neededWh > 0 else { return nil }
    let chargingW = abs(netW)
    let minutes = neededWh / chargingW * 60
    guard minutes.isFinite, (1...1_440).contains(minutes) else { return nil }
    return Int(minutes.rounded())
}

/// Estimated time until full charge (target = 100%) from current energy, maximum energy capacity, and live charging power.
func estimatedTimeToFullMinutes(remainingWh: Double?, maxWh: Double?, netW: Double) -> Int? {
    estimatedTimeToTargetMinutes(remainingWh: remainingWh, maxWh: maxWh, targetPercentage: 100, netW: netW)
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/BatteryPowerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/BatteryPower.swift WattlyTests/BatteryPowerTests.swift
git commit -m "feat(battery): add estimatedTimeToTargetMinutes pure calculation"
```

---

### Task 2: Extend Telemetry & Runtime Projection Pipeline

**Files:**
- Modify: `Wattly/Models/MetricSample.swift:127-163`
- Modify: `Wattly/Core/BatteryRuntimeProjection.swift:7-85`
- Modify: `Wattly/Core/BatteryTelemetryPipeline.swift:24-48`
- Test: `WattlyTests/BatteryRuntimeProjectionTests.swift:83-98`
- Test: `WattlyTests/BatteryTelemetryPipelineTests.swift`

**Interfaces:**
- Consumes: `estimatedTimeToTargetMinutes` from Task 1
- Produces: `BatterySample.targetPercentage: Int`
- Produces: `BatteryRuntimeProjection.ingest(_ sample: BatterySample, at now: ContinuousClock.Instant)` (re-anchors on target change)
- Produces: `BatteryTelemetryPipeline.ingest(_ raw: BatterySample, at instant: ContinuousClock.Instant, targetPercentage: Int)`

- [ ] **Step 1: Add `targetPercentage` to `BatterySample` in `MetricSample.swift`**

```swift
struct BatterySample: Sendable, Equatable {
    // ... existing fields ...
    var temperatureCelsius: Double? = nil
    /// Active target charge percentage (50...100, default 100).
    var targetPercentage: Int = 100
}
```

- [ ] **Step 2: Update `BatteryRuntimeProjection.swift` to track `targetPercentage` and re-anchor**

```swift
struct BatteryRuntimeProjection {
    private enum Source: Equatable {
        case registry
        case estimated
    }

    private struct Candidate {
        var minutes: Int
        var source: Source
        var targetPercentage: Int
    }

    private struct Anchor {
        var minutes: Int
        var source: Source
        var targetPercentage: Int
        var at: ContinuousClock.Instant
    }

    private static let maximumProjectionGap: Double = 30
    private var anchor: Anchor?
    private var lastObservation: ContinuousClock.Instant?

    mutating func ingest(_ sample: BatterySample, at now: ContinuousClock.Instant) -> Int? {
        guard let candidate = candidate(for: sample) else {
            reset()
            return nil
        }

        guard let anchor,
              let lastObservation,
              anchor.minutes == candidate.minutes,
              anchor.source == candidate.source,
              anchor.targetPercentage == candidate.targetPercentage,
              seconds(from: lastObservation, to: now) <= Self.maximumProjectionGap
        else {
            self.anchor = Anchor(minutes: candidate.minutes, source: candidate.source, targetPercentage: candidate.targetPercentage, at: now)
            self.lastObservation = now
            return candidate.minutes
        }

        self.lastObservation = now
        let minutes = Int(ceil(Double(anchor.minutes) - seconds(from: anchor.at, to: now) / 60))
        guard (1...1_440).contains(minutes) else {
            reset()
            return nil
        }
        return minutes
    }

    mutating func reset() {
        anchor = nil
        self.lastObservation = nil
    }

    private func candidate(for sample: BatterySample) -> Candidate? {
        let target = sample.targetPercentage
        if sample.charging {
            if let average = sample.average1mW,
               let minutes = estimatedTimeToTargetMinutes(remainingWh: sample.remainingWh, maxWh: sample.maxWh, targetPercentage: target, netW: average) {
                return Candidate(minutes: minutes, source: .estimated, targetPercentage: target)
            }
            if let minutes = estimatedTimeToTargetMinutes(remainingWh: sample.remainingWh, maxWh: sample.maxWh, targetPercentage: target, netW: sample.netW) {
                return Candidate(minutes: minutes, source: .estimated, targetPercentage: target)
            }
            if let minutes = validatedTimeRemainingMinutes(sample.timeRemainingMinutes) {
                let scaledMinutes: Int
                if target < 100, let rem = sample.remainingWh, let max = sample.maxWh, max > 0 {
                    let currentPct = Int((rem / max * 100).rounded())
                    if target > currentPct, currentPct < 100 {
                        scaledMinutes = max(1, Int((Double(minutes) * Double(target - currentPct) / Double(100 - currentPct)).rounded()))
                    } else {
                        return nil
                    }
                } else {
                    scaledMinutes = minutes
                }
                return Candidate(minutes: scaledMinutes, source: .registry, targetPercentage: target)
            }
            return nil
        } else {
            if let minutes = validatedTimeRemainingMinutes(sample.timeRemainingMinutes) {
                return Candidate(minutes: minutes, source: .registry, targetPercentage: target)
            }
            if let average = sample.average1mW,
               let minutes = estimatedTimeRemainingMinutes(remainingWattHours: sample.remainingWh, netW: average) {
                return Candidate(minutes: minutes, source: .estimated, targetPercentage: target)
            }
            if let minutes = estimatedTimeRemainingMinutes(remainingWattHours: sample.remainingWh, netW: sample.netW) {
                return Candidate(minutes: minutes, source: .estimated, targetPercentage: target)
            }
            return nil
        }
    }
    // ...
}
```

- [ ] **Step 3: Update `BatteryTelemetryPipeline.swift` to accept `targetPercentage`**

```swift
    mutating func ingest(
        _ raw: BatterySample,
        at instant: ContinuousClock.Instant,
        targetPercentage: Int = 100
    ) -> BatterySample {
        var sample = suppressingStaleTimeAfterDisconnect(raw)
        sample.targetPercentage = targetPercentage

        if let last = lastExternalConnected, last != sample.externalConnected {
            hasConnectionChanged = true
            oneMinuteAverage = nil
            oneMinuteInstant = nil
            runtimeProjection.reset()
        } else {
            hasConnectionChanged = false
        }
        lastExternalConnected = sample.externalConnected

        let averageDt = oneMinuteInstant.map { seconds(from: $0, to: instant) } ?? 0
        oneMinuteAverage = PowerSmoothing.emaStep(
            previous: oneMinuteAverage, raw: sample.netW, dt: averageDt, tau: 60)
        oneMinuteInstant = instant

        var presented = sample
        presented.average1mW = oneMinuteAverage
        presented.projectedTimeRemainingMinutes = runtimeProjection.ingest(presented, at: instant)
        return presented
    }
```

- [ ] **Step 4: Add Unit Tests in `BatteryRuntimeProjectionTests.swift`**

```swift
    @Test func ingestProjectsChargingTimeToCustomTargetAndReanchorsOnTargetChange() {
        var projection = BatteryRuntimeProjection()
        let now = ContinuousClock.now
        let sample85 = BatterySample(
            netW: -20.0,
            milliamps: 1500,
            volts: 12.5,
            charging: true,
            externalConnected: true,
            remainingWh: 30.0,
            maxWh: 60.0,
            targetPercentage: 85
        )
        // 60 * 0.85 = 51 Wh target. Needed = 21 Wh. 21 / 20 * 60 = 63 min.
        let minutes85 = projection.ingest(sample85, at: now)
        #expect(minutes85 == 63)

        // Switching target to 100% (Top Up activated)
        let sample100 = BatterySample(
            netW: -20.0,
            milliamps: 1500,
            volts: 12.5,
            charging: true,
            externalConnected: true,
            remainingWh: 30.0,
            maxWh: 60.0,
            targetPercentage: 100
        )
        // 60 * 1.0 = 60 Wh target. Needed = 30 Wh. 30 / 20 * 60 = 90 min.
        let minutes100 = projection.ingest(sample100, at: now.advanced(by: .seconds(1)))
        #expect(minutes100 == 90)
    }
```

- [ ] **Step 5: Run tests to verify pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/BatteryRuntimeProjectionTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Wattly/Models/MetricSample.swift Wattly/Core/BatteryRuntimeProjection.swift Wattly/Core/BatteryTelemetryPipeline.swift WattlyTests/BatteryRuntimeProjectionTests.swift
git commit -m "feat(battery): integrate target percentage into runtime projection and telemetry pipeline"
```

---

### Task 3: Integrate SystemMonitor & Bridge Synchronization

**Files:**
- Modify: `Wattly/App/WattlyApp.swift:38`
- Modify: `Wattly/Core/SystemMonitor.swift:60-120,380-396`
- Modify: `Wattly/Views/BatteryControlBridge.swift:10-35`
- Test: `WattlyTests/SystemMonitorTests.swift`

**Interfaces:**
- Consumes: `BatteryTelemetryPipeline.ingest(_:at:targetPercentage:)`
- Produces: `SystemMonitor.setBatteryChargeTarget(enabled: Bool, limitPercentage: Int, topUpActive: Bool)`
- Produces: `SystemMonitor.batteryTargetPercentage: Int`

- [ ] **Step 1: Add target state and setter to `SystemMonitor.swift`**

In `SystemMonitor.swift`:
```swift
    private(set) var batteryTargetPercentage: Int = 100

    func setBatteryChargeTarget(enabled: Bool, limitPercentage: Int, topUpActive: Bool) {
        let target = topUpActive ? 100 : (enabled ? max(50, min(100, limitPercentage)) : 100)
        guard batteryTargetPercentage != target else { return }
        batteryTargetPercentage = target
        if let state = states[.battery], case .value(.battery(var sample)) = state {
            sample.targetPercentage = target
            states[.battery] = .value(sample)
        }
    }
```
In `SystemMonitor.swift`'s battery ingest step (`processBatterySample` or pipeline call):
```swift
    let presented = batteryPipeline.ingest(sample, at: instant, targetPercentage: batteryTargetPercentage)
```
In `SystemMonitor.batterySmoothed`:
```swift
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
        average1mW: raw.average1mW,
        temperatureCelsius: raw.temperatureCelsius,
        targetPercentage: raw.targetPercentage)
```

- [ ] **Step 2: Update `BatteryControlBridge.swift` and `WattlyApp.swift` to synchronize charge target**

In `WattlyApp.swift`:
```swift
    .background(BatteryControlBridge(client: batteryControl, monitor: monitor))
```

In `BatteryControlBridge.swift`:
```swift
struct BatteryControlBridge: View {
    let client: BatteryControlClient
    var monitor: SystemMonitor? = nil

    @AppStorage(StorageKey.batteryLimitEnabled) private var enabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var limit = Defaults.batteryLimitPercentage
    // ...

    private func syncMonitorTarget() {
        let isTopUp = client.status.desiredConfiguration?.topUpActive == true || client.status.activity == .topUp
        monitor?.setBatteryChargeTarget(enabled: enabled, limitPercentage: limit, topUpActive: isTopUp)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                syncMonitorTarget()
                // ...
            }
            .onChange(of: enabled) { _, _ in syncMonitorTarget() }
            .onChange(of: limit) { _, _ in syncMonitorTarget() }
            .onChange(of: client.status) { _, newStatus in
                syncMonitorTarget()
                if topUpDetector.update(reasonKind: newStatus.detailReason?.kind) {
                    BatteryNotificationManager.postTopUpCompleteNotification()
                }
            }
    }
}
```

- [ ] **Step 3: Run tests to verify pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/SystemMonitorTests`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Wattly/App/WattlyApp.swift Wattly/Core/SystemMonitor.swift Wattly/Views/BatteryControlBridge.swift WattlyTests/SystemMonitorTests.swift
git commit -m "feat(battery): synchronize charge target settings and Top Up status with SystemMonitor"
```

---

### Task 4: Enhance Presentation Formats & Deduplicate Views

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift:238-281`
- Modify: `Wattly/Views/MetricCardView.swift:78-105`
- Modify: `Wattly/Views/PopoverHeroView.swift:213-248`
- Modify: `Wattly/Views/CardExpandRegion.swift:241-267`
- Modify: `Wattly/Core/Accessibility.swift:25-34`
- Test: `WattlyTests/CardPresentationTests.swift:195-206`
- Test: `WattlyTests/AccessibilityTests.swift`

**Interfaces:**
- Produces: `CardPresentation.batteryRemainingTimeSummary(_ s: BatterySample) -> String?`
- Produces: `CardPresentation.batteryTimeToFullLabel: String` (backward compatibility)
- Produces: `CardPresentation.batteryTimeToFullLabel(targetPercentage: Int) -> String`
- Produces: `CardPresentation.batteryTimeToFullText(_ s: BatterySample) -> String?`

- [ ] **Step 1: Write failing tests in `CardPresentationTests.swift`**

```swift
    @Test func batteryRemainingTimeSummaryShowsTargetPercentageWhenChargingUnder100() {
        let sample85 = BatterySample(
            netW: -20.0,
            milliamps: 1500,
            volts: 12.5,
            charging: true,
            externalConnected: true,
            projectedTimeRemainingMinutes: 25,
            targetPercentage: 85
        )
        #expect(CardPresentation.batteryRemainingTimeSummary(sample85) == "85%까지 약 25분 남음")
        #expect(CardPresentation.batteryTimeToFullText(sample85) == "약 25분 남음")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 85) == "85%까지 남은 시간")
        #expect(CardPresentation.batteryTimeToFullLabel == "완충까지 남은 시간")
    }

    @Test func batteryRemainingTimeSummaryShowsFullWhenTargetIs100() {
        let sample100 = BatterySample(
            netW: -20.0,
            milliamps: 1500,
            volts: 12.5,
            charging: true,
            externalConnected: true,
            projectedTimeRemainingMinutes: 70,
            targetPercentage: 100
        )
        #expect(CardPresentation.batteryRemainingTimeSummary(sample100) == "완충까지 약 1시간 10분 남음")
        #expect(CardPresentation.batteryTimeToFullText(sample100) == "약 1시간 10분 남음")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 100) == "완충까지 남은 시간")
    }

    @Test func batteryRemainingTimeSummaryShowsDischargeWithoutTarget() {
        let sampleDischarge = BatterySample(
            netW: 15.0,
            milliamps: 1200,
            volts: 12.5,
            charging: false,
            externalConnected: false,
            projectedTimeRemainingMinutes: 140,
            targetPercentage: 85
        )
        #expect(CardPresentation.batteryRemainingTimeSummary(sampleDischarge) == "약 2시간 20분 남음")
    }
```

- [ ] **Step 2: Implement formatting logic in `CardPresentation.swift`**

```swift
    static var batteryTimeToFullLabel: String { batteryTimeToFullLabel(targetPercentage: 100) }

    static func batteryTimeToFullLabel(targetPercentage: Int = 100) -> String {
        targetPercentage < 100 ? "\(targetPercentage)%까지 남은 시간" : "완충까지 남은 시간"
    }

    static func batteryRemainingTimeSummary(_ s: BatterySample) -> String? {
        guard let totalMinutes = validatedTimeRemainingMinutes(s.projectedTimeRemainingMinutes)
        else { return nil }
        let duration = formatDuration(minutes: totalMinutes)
        if s.charging {
            if s.targetPercentage < 100 {
                return "\(s.targetPercentage)%까지 약 \(duration) 남음"
            } else {
                return "완충까지 약 \(duration) 남음"
            }
        } else {
            return "약 \(duration) 남음"
        }
    }

    static func batteryTimeToFullText(_ s: BatterySample) -> String? {
        guard s.charging,
              let totalMinutes = validatedTimeRemainingMinutes(s.projectedTimeRemainingMinutes)
        else { return nil }
        return "약 \(formatDuration(minutes: totalMinutes)) 남음"
    }
```

- [ ] **Step 3: Deduplicate `subTextView` in `MetricCardView.swift` & `PopoverHeroView.swift`**

In `MetricCardView.swift`:
```swift
    @ViewBuilder
    private func subTextView(_ fallbackSubText: String?) -> some View {
        if let sub = fallbackSubText, !sub.isEmpty {
            Text(sub)
        }
    }
```
In `PopoverHeroView.swift`:
```swift
    @ViewBuilder
    private func subTextView(_ fallbackSubText: String?) -> some View {
        if let sub = fallbackSubText, !sub.isEmpty {
            Text(sub)
        }
    }
```

- [ ] **Step 4: Update `CardExpandRegion.swift` to display dynamic time-to-target row & optimistic Top Up button**

In `CardExpandRegion.swift` `batteryExpand`:
```swift
            if let value = CardPresentation.batteryAverage1mText(s) {
                batteryDetailRow(label: CardPresentation.batteryAverage1mLabel, value: value)
            }
            if let value = CardPresentation.batteryRemainingCapacityText(s) {
                batteryDetailRow(label: CardPresentation.batteryRemainingCapacityLabel, value: value)
            }
            if s.charging, let value = CardPresentation.batteryTimeToFullText(s) {
                batteryDetailRow(
                    label: CardPresentation.batteryTimeToFullLabel(targetPercentage: s.targetPercentage),
                    value: value
                )
            }
            if showBatteryEfficiency, let value = CardPresentation.batteryEfficiencyText(s) {
                batteryDetailRow(label: CardPresentation.batteryEfficiencyLabel, value: value)
            }
            if let value = CardPresentation.batteryCycleText(s) {
                batteryDetailRow(label: CardPresentation.batteryCycleLabel, value: value)
            }
            if let value = CardPresentation.batteryTemperatureText(s) {
                batteryDetailRow(label: CardPresentation.batteryTemperatureLabel, value: value)
            }
            batteryDetailRow(label: "전류", value: CardPresentation.batteryCurrentText(s))
            batteryDetailRow(label: "전압", value: CardPresentation.batteryVoltageText(s))
```

- [ ] **Step 5: Run all test suites**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/CardPresentation.swift Wattly/Views/MetricCardView.swift Wattly/Views/PopoverHeroView.swift Wattly/Views/CardExpandRegion.swift Wattly/Core/Accessibility.swift WattlyTests/CardPresentationTests.swift WattlyTests/AccessibilityTests.swift
git commit -m "feat(battery): format dynamic charge time text and deduplicate view presentation"
```

---
