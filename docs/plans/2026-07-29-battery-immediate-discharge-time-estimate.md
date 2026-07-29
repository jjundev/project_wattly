# Battery Immediate Discharge Time Estimate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a remaining-time value on the first discharging battery sample when macOS has not yet supplied a valid `TimeRemaining` value after the charger is unplugged.

**Architecture:** Keep the numerical fallback in `BatteryPower` as a pure helper that converts the already-collected remaining energy and live discharge power into a bounded minute count. `CardPresentation` remains the single display policy: when not charging, it prefers a valid AppleSmartBattery time and otherwise asks that helper for an estimate; the existing subtitle consumes the same formatter without any provider, model, or SwiftUI changes.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, IOKit, XcodeGen project.

## Global Constraints

- Swift 6 language mode; deployment target macOS 14.0; arm64 only. (`project.yml`)
- Use no dependencies and create no source files; XcodeGen does not need to run.
- Preserve AppleSmartBattery `TimeRemaining` as the preferred value whenever it passes the existing `validatedTimeRemainingMinutes(_:)` rule.
- Only when `BatterySample.charging == false` and registry time is absent or invalid, estimate minutes as `remainingWh ÷ netW × 60` from the current sample.
- An estimate is valid only when `remainingWh` and `netW` are finite, `remainingWh > 0`, `netW > 0.2` W, and the unrounded result is within `1...1_440` minutes; return the nearest whole minute.
- Never calculate or render a remaining-time value while charging, including when capacity and charging-power fields are present.
- Keep the user-facing copy exactly `N시간 M분 남음`; do not add an estimate label or a separate expanded row.
- This change produces the fallback on the first post-unplug battery sample. It does not add an IOKit power-source notification; the normal open-panel battery poll remains the delivery mechanism.

---

## File Structure

- Modify: `Wattly/Core/BatteryPower.swift` — add the pure, bounded fallback-minute calculation beside existing capacity/time validation helpers.
- Modify: `Wattly/Core/CardPresentation.swift` — choose validated registry minutes first, then the fallback calculation for non-charging samples.
- Modify: `WattlyTests/BatteryPowerTests.swift` — cover normal estimate rounding and every invalid input boundary.
- Modify: `WattlyTests/CardPresentationTests.swift` — prove immediate display fallback, raw-time precedence, and charging suppression through the real subtitle formatter.

## Decision Checkpoint

No execution-level decision remains. The codebase already stores `remainingWh`, live `netW`, `charging`, and the optional raw time in every `BatterySample`; a pure helper plus the existing presentation seam implements the requested behavior without changing provider I/O or crossing the actor boundary. The established one-day plausibility limit and `0.2` W direction dead zone make the fallback safe against idle/full-battery division noise.

---

### Task 1: Estimate display time when the registry value is temporarily unavailable

**Files:**

- Modify: `Wattly/Core/BatteryPower.swift:51-63`
- Modify: `Wattly/Core/CardPresentation.swift:241-246`
- Test: `WattlyTests/BatteryPowerTests.swift:97-142`
- Test: `WattlyTests/CardPresentationTests.swift:24-94`

**Interfaces:**

- Consumes: `estimatedTimeRemainingMinutes(remainingWattHours: Double?, netW: Double) -> Int?`, `BatterySample.remainingWh: Double?`, `BatterySample.netW: Double`, `BatterySample.timeRemainingMinutes: Int?`, and `BatterySample.charging: Bool`.
- Produces: `CardPresentation.batteryRemainingTimeSummary(_:) -> String?`, which returns a valid registry time first, otherwise a valid discharging fallback formatted as `N시간 M분 남음`.

- [ ] **Step 1: Write the failing calculation and presentation tests**

Append the following two tests before the closing brace of `BatteryPowerTests` in `WattlyTests/BatteryPowerTests.swift`:

~~~swift
    @Test func estimatedTimeRemainingUsesRemainingEnergyAndDischargePower() {
        // 49.5 Wh ÷ 20 W × 60 = 148.5 min → nearest whole minute, 149.
        #expect(estimatedTimeRemainingMinutes(remainingWattHours: 49.5, netW: 20.0) == 149)
        #expect(estimatedTimeRemainingMinutes(remainingWattHours: 12.0, netW: 8.0) == 90)
    }

    @Test func estimatedTimeRemainingRejectsUnsafeOrImplausibleInputs() {
        #expect(estimatedTimeRemainingMinutes(remainingWattHours: nil, netW: 20.0) == nil)
        #expect(estimatedTimeRemainingMinutes(remainingWattHours: 0, netW: 20.0) == nil)
        #expect(estimatedTimeRemainingMinutes(remainingWattHours: .infinity, netW: 20.0) == nil)
        #expect(estimatedTimeRemainingMinutes(remainingWattHours: 49.5, netW: 0.2) == nil)
        #expect(estimatedTimeRemainingMinutes(remainingWattHours: 49.5, netW: 0) == nil)
        #expect(estimatedTimeRemainingMinutes(remainingWattHours: 49.5, netW: -.infinity) == nil)
        #expect(estimatedTimeRemainingMinutes(remainingWattHours: 49.5, netW: -20.0) == nil)
        #expect(estimatedTimeRemainingMinutes(remainingWattHours: 49.5, netW: 1.0) == nil)
    }
~~~

Replace `batteryAverageAndRemainingTimeVisibilityRules` in `WattlyTests/CardPresentationTests.swift` with this test, retaining its existing average assertions while adding the first-post-unplug scenario:

~~~swift
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

        let immediatelyAfterUnplug = BatterySample(
            netW: 20.0,
            milliamps: 1_575,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            remainingWh: 49.5,
            timeRemainingMinutes: nil)
        #expect(CardPresentation.batteryRemainingTimeSummary(immediatelyAfterUnplug) == "2시간 29분 남음")
        #expect(CardPresentation.subText(.value(.battery(immediatelyAfterUnplug))) == "2시간 29분 남음")

        let charging = BatterySample(
            netW: -5.0,
            milliamps: 400,
            volts: 12.7,
            charging: true,
            externalConnected: true,
            remainingWh: 49.5,
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
~~~

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryPowerTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests
~~~

Expected: FAIL. `estimatedTimeRemainingMinutes(remainingWattHours:netW:)` does not yet exist, and the existing remaining-time formatter returns `nil` for the first discharging sample whose registry time is absent.

- [ ] **Step 3: Add the bounded fallback and preserve raw-time priority**

In `Wattly/Core/BatteryPower.swift`, insert this helper directly after `validatedTimeRemainingMinutes(_:)`:

~~~swift
/// Estimated remaining runtime from current energy and live discharge power. This fills the
/// AppleSmartBattery TimeRemaining gap immediately after an unplug, until the gas gauge has
/// recalculated its own estimate. It intentionally rejects charging, near-idle, non-finite,
/// and implausible inputs rather than displaying a misleading duration.
func estimatedTimeRemainingMinutes(remainingWattHours: Double?, netW: Double) -> Int? {
    guard let remainingWattHours,
          remainingWattHours.isFinite,
          remainingWattHours > 0,
          netW.isFinite,
          netW > 0.2 else { return nil }
    let minutes = remainingWattHours / netW * 60
    guard minutes.isFinite, (1...1_440).contains(minutes) else { return nil }
    return Int(minutes.rounded())
}
~~~

In `Wattly/Core/CardPresentation.swift`, replace `batteryRemainingTimeSummary(_:)` with:

~~~swift
    static func batteryRemainingTimeSummary(_ s: BatterySample) -> String? {
        guard !s.charging else { return nil }
        guard let totalMinutes = validatedTimeRemainingMinutes(s.timeRemainingMinutes)
            ?? estimatedTimeRemainingMinutes(remainingWattHours: s.remainingWh, netW: s.netW)
        else { return nil }
        return "\(totalMinutes / 60)시간 \(totalMinutes % 60)분 남음"
    }
~~~

- [ ] **Step 4: Run focused tests, full tests, and the macOS build**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryPowerTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' build
~~~

Expected: All commands succeed. The unit tests prove exact rounded estimates and rejected inputs; the presentation test proves the fallback appears on the first non-charging sample lacking registry time, while valid registry time still wins and charging still hides it.

- [ ] **Step 5: Commit the fallback behavior and regression coverage**

Run:

~~~bash
git add Wattly/Core/BatteryPower.swift Wattly/Core/CardPresentation.swift WattlyTests/BatteryPowerTests.swift WattlyTests/CardPresentationTests.swift docs/plans/2026-07-29-battery-immediate-discharge-time-estimate.md
git commit -m "fix(battery): estimate time after unplug"
~~~

Expected: Git creates one commit containing only the fallback calculation, presentation policy, regression tests, and this implementation plan.

---

## Self-Review

1. **Spec coverage:** Task 1 defines the exact fallback formula and bounds, preserves valid registry-time precedence, keeps charging output hidden, and tests the first post-unplug subtitle that previously remained empty.
2. **Placeholder scan:** No incomplete markers, unspecified test cases, or undefined interfaces remain. Each code step contains exact Swift and each verification step gives a command and expected result.
3. **Type consistency:** `estimatedTimeRemainingMinutes(remainingWattHours:netW:)` is defined as returning `Int?` in `BatteryPower` and consumed with the matching argument labels by `CardPresentation`; all test calls use the same signature.

## Automatic Plan Review

Skipped: this is a single-task plan, so the required automatic reviewer round-trip does not apply.
