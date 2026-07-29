# Battery Health, Cycle, and Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Show battery efficiency and cycle count when the battery card is expanded, while the collapsed card shows only remaining time and one-minute average power.

**Architecture:** Extend the existing AppleSmartBattery snapshot with maximum charge capacity, design capacity, and cycle count. BatteryPower derives a validated efficiency percentage; BatterySample carries that result and the cycle count through the existing smoothing boundary unchanged. CardPresentation replaces the charge/discharge copy with a composed remaining-time and average-power summary, and CardExpandRegion renders capacity, efficiency, and cycle details without a separate expanded remaining-time row.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, IOKit, XcodeGen project.

## Global Constraints

- Swift 6 language mode; deployment target macOS 14.0; arm64 only. (project.yml)
- Use no dependencies and create no source files; XcodeGen does not need to run.
- SMC remains the authoritative source for live netW, current, voltage, charge direction, and adapter state. AppleSmartBattery supplements only capacity, health, cycle, and time telemetry.
- Define 배터리 효율 as AppleRawMaxCapacity (mAh) divided by DesignCapacity (mAh), multiplied by 100. Preserve values above 100 when real manufacturing tolerance produces them; reject non-finite or out-of-range results outside 0...200 percent.
- Accept CycleCount only as an integer in 0...10_000. Absent, negative, or implausibly large values are nil and produce no expanded row.
- Preserve efficiencyPercent and cycleCount unchanged through display smoothing, just as remainingWh and timeRemainingMinutes are preserved.
- New Korean user-facing strings belong in CardPresentation. Use exactly 배터리 효율, 사이클, and N시간 M분 남음.
- The collapsed battery sub-line contains only the optional remaining-time segment and optional 1-minute-average segment, joined by " · ". Do not render 충전 중, 방전 중, or any other status word there.
- Do not render an expanded 남은 사용시간 row. The expanded order is 남은 용량, 배터리 효율, 사이클, 전류, 전압.
- Layout B remains compact; the shared expanded region keeps layouts A and the expanded mode-C hero in step.

---

## File Structure

- Modify: Wattly/Models/MetricSample.swift — optional BatterySample efficiency and cycle fields.
- Modify: Wattly/Core/BatteryPower.swift — pure efficiency and cycle validation helpers.
- Modify: Wattly/Providers/BatteryProvider.swift — read AppleRawMaxCapacity, DesignCapacity, and CycleCount into the existing one-read registry snapshot and produce sample fields on SMC and fallback paths.
- Modify: Wattly/Core/SystemMonitor.swift — retain health/cycle values when it rebuilds a smoothed BatterySample.
- Modify: Wattly/Core/CardPresentation.swift — collapsed summary composition, Korean labels, and pure expanded-row formatters.
- Modify: Wattly/Views/CardExpandRegion.swift — replace the time row with efficiency/cycle rows.
- Modify: WattlyTests/BatteryPowerTests.swift — efficiency/cycle derivation and validation tests.
- Modify: WattlyTests/SystemMonitorTests.swift — smoothing preservation tests.
- Modify: WattlyTests/CardPresentationTests.swift — exact collapsed copy and expanded detail formatting tests.

## Decision Checkpoint

No execution-level decision remains. AppleSmartBattery exposes AppleRawMaxCapacity, DesignCapacity, and CycleCount locally, so “배터리 효율” can use the standard maximum-versus-design-capacity health ratio without adding a dependency or inventing an estimate.

---

### Task 1: Collect, derive, and preserve battery health telemetry

**Files:**

- Modify: Wattly/Models/MetricSample.swift:107-131
- Modify: Wattly/Core/BatteryPower.swift:51-63
- Modify: Wattly/Providers/BatteryProvider.swift:29-108
- Modify: Wattly/Core/SystemMonitor.swift:358-368
- Test: WattlyTests/BatteryPowerTests.swift:97-119
- Test: WattlyTests/SystemMonitorTests.swift:125-169

**Interfaces:**

- Consumes: AppleSmartBattery AppleRawMaxCapacity (mAh), DesignCapacity (mAh), and CycleCount.
- Produces: BatterySample.efficiencyPercent: Double?, BatterySample.cycleCount: Int?, batteryEfficiencyPercent(maxCapacityMilliampHours:designCapacityMilliampHours:) -> Double?, and validatedBatteryCycleCount(_:) -> Int?.

- [ ] **Step 1: Write failing derivation and smoothing tests**

Append these tests before the closing brace of BatteryPowerTests in WattlyTests/BatteryPowerTests.swift:

~~~swift
    @Test func batteryEfficiencyUsesMaximumOverDesignCapacity() {
        let percent = batteryEfficiencyPercent(
            maxCapacityMilliampHours: 6_222,
            designCapacityMilliampHours: 6_249)
        #expect(abs((percent ?? 0) - 99.56793086893903) < 0.000_000_1)
    }

    @Test func batteryEfficiencyRejectsInvalidCapacityPairs() {
        #expect(batteryEfficiencyPercent(maxCapacityMilliampHours: 0, designCapacityMilliampHours: 6_249) == nil)
        #expect(batteryEfficiencyPercent(maxCapacityMilliampHours: 6_222, designCapacityMilliampHours: 0) == nil)
        #expect(batteryEfficiencyPercent(maxCapacityMilliampHours: -1, designCapacityMilliampHours: 6_249) == nil)
        #expect(batteryEfficiencyPercent(maxCapacityMilliampHours: 20_000, designCapacityMilliampHours: 6_249) == nil)
    }

    @Test func cycleCountAcceptsPlausibleNonNegativeValues() {
        #expect(validatedBatteryCycleCount(0) == 0)
        #expect(validatedBatteryCycleCount(77) == 77)
        #expect(validatedBatteryCycleCount(10_000) == 10_000)
        #expect(validatedBatteryCycleCount(nil) == nil)
        #expect(validatedBatteryCycleCount(-1) == nil)
        #expect(validatedBatteryCycleCount(10_001) == nil)
    }
~~~

In batteryDisplaySmoothingDampsAndResetsOnPlug in WattlyTests/SystemMonitorTests.swift, add these arguments to the local BatterySample factory after timeRemainingMinutes:

~~~swift
                efficiencyPercent: 99.6,
                cycleCount: 77
~~~

Add after its existing remainingWh/time assertions for the damped sample:

~~~swift
        #expect(sm.efficiencyPercent == 99.6)
        #expect(sm.cycleCount == 77)
~~~

Add after the plugged-in sample’s existing remainingWh/time assertions:

~~~swift
        #expect(monitor.batteryOverlay.sample?.efficiencyPercent == 99.6)
        #expect(monitor.batteryOverlay.sample?.cycleCount == 77)
~~~

- [ ] **Step 2: Run tests to verify they fail**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryPowerTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/SystemMonitorTests
~~~

Expected: BatteryPowerTests fails to compile because batteryEfficiencyPercent and validatedBatteryCycleCount do not exist; SystemMonitorTests fails because the smoothed BatterySample drops the new optional fields.

- [ ] **Step 3: Add model fields and pure validation**

In Wattly/Models/MetricSample.swift, insert the following fields after timeRemainingMinutes and before average1mW:

~~~swift
    /// Health/efficiency: AppleRawMaxCapacity ÷ DesignCapacity × 100. nil when the
    /// registry capacity pair is absent or invalid.
    var efficiencyPercent: Double? = nil
    /// AppleSmartBattery cycle count. nil when absent or outside the plausible range.
    var cycleCount: Int? = nil
~~~

In Wattly/Core/BatteryPower.swift, insert the following directly after validatedTimeRemainingMinutes:

~~~swift
/// Battery health/efficiency from the current maximum charge capacity relative to
/// original design capacity. Values slightly above 100 are legitimate manufacturing
/// tolerance; values outside 0...200 indicate corrupt registry input.
func batteryEfficiencyPercent(
    maxCapacityMilliampHours: Int,
    designCapacityMilliampHours: Int
) -> Double? {
    guard maxCapacityMilliampHours > 0, designCapacityMilliampHours > 0 else { return nil }
    let percent = Double(maxCapacityMilliampHours) / Double(designCapacityMilliampHours) * 100
    guard percent.isFinite, (0...200).contains(percent) else { return nil }
    return percent
}

/// CycleCount is a non-negative hardware counter. Ten thousand is well above supported
/// Apple battery life while still allowing a defensively validated value type.
func validatedBatteryCycleCount(_ count: Int?) -> Int? {
    guard let count, (0...10_000).contains(count) else { return nil }
    return count
}
~~~

- [ ] **Step 4: Thread registry fields through both provider paths**

In Wattly/Providers/BatteryProvider.swift, extend AppleSmartBatterySnapshot with:

~~~swift
        var rawMaxCapacityMilliampHours: Int?
        var designCapacityMilliampHours: Int?
        var cycleCount: Int?
~~~

Extend the AppleSmartBatterySnapshot initializer in appleSmartBatterySnapshot() with:

~~~swift
            rawMaxCapacityMilliampHours: number(service, "AppleRawMaxCapacity")?.intValue,
            designCapacityMilliampHours: number(service, "DesignCapacity")?.intValue,
            cycleCount: number(service, "CycleCount")?.intValue
~~~

In the SMC BatterySample initializer, immediately after timeRemainingMinutes, add:

~~~swift
            efficiencyPercent: batteryEfficiencyPercent(
                maxCapacityMilliampHours: registry?.rawMaxCapacityMilliampHours ?? 0,
                designCapacityMilliampHours: registry?.designCapacityMilliampHours ?? 0),
            cycleCount: validatedBatteryCycleCount(registry?.cycleCount)
~~~

In the fallback BatterySample initializer, registry is non-optional; add this mapping after timeRemainingMinutes instead:

~~~swift
            efficiencyPercent: batteryEfficiencyPercent(
                maxCapacityMilliampHours: registry.rawMaxCapacityMilliampHours ?? 0,
                designCapacityMilliampHours: registry.designCapacityMilliampHours ?? 0),
            cycleCount: validatedBatteryCycleCount(registry.cycleCount)
~~~

- [ ] **Step 5: Preserve the fields through display smoothing**

In Wattly/Core/SystemMonitor.swift, add these arguments to batterySmoothed(from:netW:), after timeRemainingMinutes and before average1mW:

~~~swift
            efficiencyPercent: raw.efficiencyPercent,
            cycleCount: raw.cycleCount,
~~~

- [ ] **Step 6: Run tests to verify they pass**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryPowerTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/SystemMonitorTests
~~~

Expected: PASS — conversion/validation tests and both smoothing preservation paths pass.

- [ ] **Step 7: Commit**

~~~bash
git add Wattly/Models/MetricSample.swift Wattly/Core/BatteryPower.swift Wattly/Providers/BatteryProvider.swift Wattly/Core/SystemMonitor.swift WattlyTests/BatteryPowerTests.swift WattlyTests/SystemMonitorTests.swift
git commit -m "feat(battery): collect efficiency and cycle count"
~~~

### Task 2: Recompose collapsed copy and expanded battery details

**Files:**

- Modify: Wattly/Core/CardPresentation.swift:172-243
- Modify: Wattly/Views/CardExpandRegion.swift:148-162
- Test: WattlyTests/CardPresentationTests.swift:24-111

**Interfaces:**

- Consumes: BatterySample.remainingWh, timeRemainingMinutes, efficiencyPercent, cycleCount, and average1mW.
- Produces: CardPresentation.batteryRemainingTimeSummary(_:) -> String?, batteryEfficiencyText(_:) -> String?, batteryCycleText(_:) -> String?, and the exact collapsed sub-line/expanded row layout.

- [ ] **Step 1: Write failing presentation tests**

Replace batteryValueAndSub, batteryAverageSignFollowsItsOwnDirection, and batteryRemainingCapacityAndTimeTextForExpand in WattlyTests/CardPresentationTests.swift with:

~~~swift
    @Test func batteryValueAndCollapsedSummary() {
        let discharging = MetricState.value(.battery(BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 210,
            average1mW: 10.4)))
        #expect(CardPresentation.valueText(.battery, discharging) == "\(minus)12.0")
        #expect(CardPresentation.subText(discharging) == "3시간 30분 남음 · 1분 평균 \(minus)10.4 W")

        let timeOnly = MetricState.value(.battery(BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 1)))
        #expect(CardPresentation.subText(timeOnly) == "0시간 1분 남음")

        let averageOnly = MetricState.value(.battery(BatterySample(
            netW: -5.0,
            milliamps: 400,
            volts: 12.7,
            charging: true,
            externalConnected: true,
            average1mW: -3.0)))
        #expect(CardPresentation.subText(averageOnly) == "1분 평균 +3.0 W")

        let noDetail = MetricState.value(.battery(BatterySample(
            netW: 0.0,
            milliamps: 0,
            volts: 12.7,
            charging: false,
            externalConnected: true)))
        #expect(CardPresentation.subText(noDetail) == nil)
    }

    @Test func batteryRemainingCapacityEfficiencyAndCycleTextForExpand() {
        let populated = BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            remainingWh: 49.457568,
            timeRemainingMinutes: 210,
            efficiencyPercent: 99.56793086893903,
            cycleCount: 77)
        #expect(CardPresentation.batteryRemainingCapacityLabel == "남은 용량")
        #expect(CardPresentation.batteryEfficiencyLabel == "배터리 효율")
        #expect(CardPresentation.batteryCycleLabel == "사이클")
        #expect(CardPresentation.batteryRemainingCapacityText(populated) == "49.5 Wh")
        #expect(CardPresentation.batteryEfficiencyText(populated) == "99.6%")
        #expect(CardPresentation.batteryCycleText(populated) == "77회")
        #expect(CardPresentation.batteryRemainingTimeSummary(populated) == "3시간 30분 남음")

        let unavailable = BatterySample(
            netW: -10.0,
            milliamps: 800,
            volts: 12.0,
            charging: true,
            externalConnected: true)
        #expect(CardPresentation.batteryEfficiencyText(unavailable) == nil)
        #expect(CardPresentation.batteryCycleText(unavailable) == nil)

        let invalid = BatterySample(
            netW: 12.0,
            milliamps: 800,
            volts: 12.0,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 1_441,
            efficiencyPercent: 201,
            cycleCount: 10_001)
        #expect(CardPresentation.batteryRemainingTimeSummary(invalid) == nil)
        #expect(CardPresentation.batteryEfficiencyText(invalid) == nil)
        #expect(CardPresentation.batteryCycleText(invalid) == nil)
    }
~~~

- [ ] **Step 2: Run presentation tests to verify they fail**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests
~~~

Expected: FAIL because the existing sub-line still emits 충전 중 or 방전 중, and the new efficiency/cycle formatters do not exist.

- [ ] **Step 3: Implement pure labels, formatters, and collapsed summary composition**

In Wattly/Core/CardPresentation.swift, replace the .battery branch of subText(_:) with:

~~~swift
        case .battery(let s):
            var segments: [String] = []
            if let time = batteryRemainingTimeSummary(s) {
                segments.append(time)
            }
            if let average = s.average1mW {
                let avgSign = batterySign(netW: average, charging: average < 0)
                segments.append("1분 평균 \(avgSign)\(f1(abs(average))) W")
            }
            return segments.isEmpty ? nil : segments.joined(separator: " · ")
~~~

Replace the existing block from batteryRemainingCapacityLabel through batteryRemainingTimeText(_:) with:

~~~swift
    static let batteryRemainingCapacityLabel = "남은 용량"
    static let batteryEfficiencyLabel = "배터리 효율"
    static let batteryCycleLabel = "사이클"

    static func batteryRemainingCapacityText(_ s: BatterySample) -> String? {
        guard let wh = s.remainingWh, wh.isFinite, wh >= 0 else { return nil }
        return "\(f1(wh)) Wh"
    }

    static func batteryRemainingTimeSummary(_ s: BatterySample) -> String? {
        guard let totalMinutes = s.timeRemainingMinutes,
              (1...1_440).contains(totalMinutes) else { return nil }
        return "\(totalMinutes / 60)시간 \(totalMinutes % 60)분 남음"
    }

    static func batteryEfficiencyText(_ s: BatterySample) -> String? {
        guard let percent = s.efficiencyPercent,
              percent.isFinite,
              (0...200).contains(percent) else { return nil }
        return "\(f1(percent))%"
    }

    static func batteryCycleText(_ s: BatterySample) -> String? {
        guard let count = s.cycleCount, (0...10_000).contains(count) else { return nil }
        return "\(count)회"
    }
~~~

- [ ] **Step 4: Replace the expanded time row with efficiency and cycle rows**

Replace batteryExpand(_:) in Wattly/Views/CardExpandRegion.swift with:

~~~swift
    private func batteryExpand(_ s: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let value = CardPresentation.batteryRemainingCapacityText(s) {
                batteryDetailRow(label: CardPresentation.batteryRemainingCapacityLabel, value: value)
            }
            if let value = CardPresentation.batteryEfficiencyText(s) {
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
~~~

- [ ] **Step 5: Run presentation tests to verify they pass**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests
~~~

Expected: PASS — the battery sub-line has no status word, valid output is exactly 3시간 30분 남음 · 1분 평균 −10.4 W, and expanded formatters produce 49.5 Wh, 99.6%, and 77회.

- [ ] **Step 6: Run the full suite and perform on-device verification**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
~~~

Expected: PASS — the complete WattlyTests suite succeeds.

On a MacBook, use the command below and verify the expanded card’s efficiency is AppleRawMaxCapacity ÷ DesignCapacity × 100, its cycle value matches CycleCount, and its collapsed line reads N시간 M분 남음 followed by 1분 평균 when those values are present:

~~~bash
ioreg -r -n AppleSmartBattery -w0 | rg 'AppleRawMaxCapacity|DesignCapacity|CycleCount|TimeRemaining'
~~~

Also confirm:

- The expanded card has no 남은 사용시간 row.
- The expanded rows are ordered 남은 용량, 배터리 효율, 사이클, 전류, 전압.
- The mode-B tile remains compact and unchanged.
- With battery selected as the mode-C hero, expanding the hero shows the same five rows on its dark surface.

This project has no SwiftUI snapshot or accessibility-tree test seam for CardExpandRegion, so the ordered A/C verification above is the required UI-level assertion for this task.

- [ ] **Step 7: Commit**

~~~bash
git add Wattly/Core/CardPresentation.swift Wattly/Views/CardExpandRegion.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(battery): show health and cycle details"
~~~

## Self-Review

1. **Spec coverage:** Task 1 collects and preserves the two new telemetry values. Task 2 changes the collapsed copy exactly as requested, removes the expanded time row, and adds expanded efficiency/cycle rows. Mode A/C reuse the shared region while B stays compact.
2. **Placeholder scan:** No unfinished markers, deferred implementation, or unspecified validation is present. Every code-changing step includes concrete Swift and each test step names an exact command and expected outcome.
3. **Type consistency:** efficiencyPercent and cycleCount are introduced by Task 1, preserved under the same names by SystemMonitor, and consumed by Task 2 formatters. The collapsed formatter is named batteryRemainingTimeSummary consistently in implementation and tests.
