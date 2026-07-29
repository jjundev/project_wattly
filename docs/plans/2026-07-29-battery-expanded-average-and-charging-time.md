# Battery Expanded Average and Charging Time Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the battery card’s one-minute average only in the expanded details and hide the remaining-time copy while the battery is charging.

**Architecture:** Keep all formatting and visibility rules in `CardPresentation`, so collapsed-card text, the shared expanded region, and VoiceOver consume one deterministic presentation seam. Remove the average from the collapsed battery sub-line, expose it through an optional expanded-row formatter, and render that row in `CardExpandRegion`, which is shared by layout A and expanded layout-C hero cards.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, XcodeGen project.

## Global Constraints

- Swift 6 language mode; deployment target macOS 14.0; arm64 only. (`project.yml`)
- Use no dependencies and create no source files; XcodeGen does not need to run.
- Preserve the existing `BatterySample` telemetry and one-minute smoothing behavior; this change only changes presentation.
- The exact expanded-row label is `1분 평균`; format its signed watt value with the existing `CardPresentation.batterySign(netW:charging:)` and one-decimal formatter.
- The collapsed battery sub-line contains only a non-charging `N시간 M분 남음` value; it is `nil` when no valid remaining time is available or when `BatterySample.charging` is `true`.
- Do not show a separate remaining-time row when the card is expanded.
- Keep the `1분 평균` detail as the first optional battery expanded row, before the existing capacity, efficiency, cycle, current, and voltage rows.
- The shared expanded region must keep layout A and expanded mode-C hero cards in step.

---

## File Structure

- Modify: `Wattly/Core/CardPresentation.swift` — remove the average from collapsed `subText`, suppress charging remaining-time copy, and add the pure expanded average label/value helpers.
- Modify: `Wattly/Views/CardExpandRegion.swift` — render the optional average row only inside the shared expanded battery details.
- Modify: `WattlyTests/CardPresentationTests.swift` — pin the collapsed/expanded visibility, signed formatting, and charging-time suppression rules without rendering SwiftUI.

## Decision Checkpoint

No execution-level decision remains. `CardExpandRegion` is already the single implementation of expanded battery details for both applicable layouts, and `BatterySample.charging` already represents the app’s charge-direction decision. The average is placed first among optional details because it is the moved live-power summary, while preserving the existing capacity-to-voltage ordering after it.

---

### Task 1: Separate collapsed and expanded battery supplementary information

**Files:**

- Modify: `Wattly/Core/CardPresentation.swift:172-188,222-257`
- Modify: `Wattly/Views/CardExpandRegion.swift:149-166`
- Test: `WattlyTests/CardPresentationTests.swift:24-119`

**Interfaces:**

- Consumes: `BatterySample.average1mW: Double?`, `BatterySample.timeRemainingMinutes: Int?`, and `BatterySample.charging: Bool`.
- Produces: `CardPresentation.batteryAverage1mLabel: String`, `CardPresentation.batteryAverage1mText(_: BatterySample) -> String?`, and a collapsed `CardPresentation.subText(_:)` that is remaining-time-only and omits it during charging.

- [x] **Step 1: Write the failing presentation tests**

Replace `batteryValueAndCollapsedSummary` and `batteryRemainingCapacityEfficiencyAndCycleTextForExpand` in `WattlyTests/CardPresentationTests.swift` with the following tests. They assert that the collapsed text no longer includes `1분 평균`, that its formatting is available solely through the expanded-row helper, and that charging suppresses the otherwise-valid remaining time.

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
        #expect(CardPresentation.subText(discharging) == "3시간 30분 남음")

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
        #expect(CardPresentation.subText(averageOnly) == nil)

        let noDetail = MetricState.value(.battery(BatterySample(
            netW: 0.0,
            milliamps: 0,
            volts: 12.7,
            charging: false,
            externalConnected: true)))
        #expect(CardPresentation.subText(noDetail) == nil)
    }

    @Test func batteryAverageAndRemainingTimeVisibilityRules() {
        let discharging = BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 210,
            average1mW: 10.4)
        #expect(CardPresentation.batteryAverage1mLabel == "1분 평균")
        #expect(CardPresentation.batteryAverage1mText(discharging) == "\(minus)10.4 W")
        #expect(CardPresentation.batteryRemainingTimeSummary(discharging) == "3시간 30분 남음")

        let charging = BatterySample(
            netW: -5.0,
            milliamps: 400,
            volts: 12.7,
            charging: true,
            externalConnected: true,
            timeRemainingMinutes: 210,
            average1mW: -3.0)
        #expect(CardPresentation.batteryAverage1mText(charging) == "+3.0 W")
        #expect(CardPresentation.batteryRemainingTimeSummary(charging) == nil)

        let unavailableAverage = BatterySample(
            netW: 0.0,
            milliamps: 0,
            volts: 12.7,
            charging: false,
            externalConnected: true)
        #expect(CardPresentation.batteryAverage1mText(unavailableAverage) == nil)
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
        #expect(CardPresentation.batteryCycleText(populated) == "77")
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

- [x] **Step 2: Run the presentation tests to verify they fail**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests
~~~

Expected: FAIL. The existing collapsed summary still includes `1분 평균`, remaining time still formats while charging, and `batteryAverage1mLabel` / `batteryAverage1mText(_:)` do not exist.

- [x] **Step 3: Implement the presentation and shared expanded-row change**

In `Wattly/Core/CardPresentation.swift`, replace the battery branch of `subText(_:)` with this remaining-time-only implementation:

~~~swift
        case .battery(let s):
            return batteryRemainingTimeSummary(s)
~~~

In the same file, replace the battery helper block from `batteryRemainingCapacityLabel` through `batteryRemainingTimeSummary(_:)` with:

~~~swift
    static let batteryAverage1mLabel = "1분 평균"
    static let batteryRemainingCapacityLabel = "남은 용량"
    static let batteryEfficiencyLabel = "배터리 효율"
    static let batteryCycleLabel = "사이클"

    static func batteryAverage1mText(_ s: BatterySample) -> String? {
        guard let average = s.average1mW, average.isFinite else { return nil }
        let sign = batterySign(netW: average, charging: average < 0)
        return "\(sign)\(f1(abs(average))) W"
    }

    static func batteryRemainingCapacityText(_ s: BatterySample) -> String? {
        guard let wh = s.remainingWh, wh.isFinite, wh >= 0 else { return nil }
        return "\(f1(wh)) Wh"
    }

    static func batteryRemainingTimeSummary(_ s: BatterySample) -> String? {
        guard !s.charging,
              let totalMinutes = s.timeRemainingMinutes,
              (1...1_440).contains(totalMinutes) else { return nil }
        return "\(totalMinutes / 60)시간 \(totalMinutes % 60)분 남음"
    }
~~~

In `Wattly/Views/CardExpandRegion.swift`, update `batteryExpand(_:)` so the optional average is rendered first in the already-expanded shared region:

~~~swift
    private func batteryExpand(_ s: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
~~~

- [x] **Step 4: Run the focused test suite and build**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' build
~~~

Expected: Both commands succeed. The focused tests prove collapsed versus expanded presentation rules and charging suppression; the build type-checks the SwiftUI shared expanded detail row used by both layouts.

- [x] **Step 5: Commit the completed UI behavior change**

Run:

~~~bash
git add Wattly/Core/CardPresentation.swift Wattly/Views/CardExpandRegion.swift WattlyTests/CardPresentationTests.swift docs/plans/2026-07-29-battery-expanded-average-and-charging-time.md
git commit -m "fix(battery): move average to expanded details"
~~~

Expected: Git creates one commit containing the pure presentation rule, shared SwiftUI row, focused regression tests, and this implementation plan.

---

## Self-Review

1. **Spec coverage:** Task 1 removes `1분 평균` from the collapsed text, creates an expanded-only row in the shared region, and suppresses every `N시간 M분 남음` result when `charging` is true. The tests cover discharge, charging, absent average, valid time, and invalid time.
2. **Placeholder scan:** No incomplete markers, unspecified test cases, or undefined interfaces remain. Every code-changing step includes the exact replacement code and every verification step has an exact command and expected outcome.
3. **Type consistency:** `batteryAverage1mLabel` and `batteryAverage1mText(_:)` are declared in Task 1 and referenced with matching names and `BatterySample` input type by both the tests and `CardExpandRegion`.

## Automatic Plan Review

Skipped: this is a single-task plan, so the required automatic reviewer round-trip does not apply.
