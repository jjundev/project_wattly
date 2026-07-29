# Battery Stale Time After Unplug Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ignore the unchanged charging-era `TimeRemaining` value after unplugging so the battery card immediately uses its energy/power estimate until macOS supplies a changed discharging value.

**Architecture:** `SystemMonitor` already observes `ExternalConnected` transitions and owns battery presentation smoothing. It will remember the last valid raw time received while connected, suppress that identical value after a connected-to-disconnected transition, and restore raw-time use when a later non-nil value differs. Existing `CardPresentation` fallback then renders the estimate without a provider or model change.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, IOKit, XcodeGen project.

## Global Constraints

- Swift 6 language mode; deployment target macOS 14.0; arm64 only. (`project.yml`)
- Use no dependencies and create no source files; XcodeGen does not need to run.
- Only suppress a raw time value after an observed `ExternalConnected: true → false` transition when it equals the last non-nil value read while connected.
- While that stale value repeats or the raw value is absent, keep `BatterySample.timeRemainingMinutes` nil so existing `CardPresentation` uses `remainingWh ÷ netW × 60`.
- Resume raw-time use on the first non-nil discharging `TimeRemaining` value that differs from the remembered connected value.
- Do not change `CardPresentation`, `BatteryProvider`, `BatterySample`, polling cadence, the estimate formula, or Korean display copy.
- Preserve current history reset, smoothing reset, and one-minute-average reset behavior on every adapter-state change.

---

## File Structure

- Modify: `Wattly/Core/SystemMonitor.swift` — normalize stale raw time before storing and smoothing each battery sample.
- Modify: `WattlyTests/SystemMonitorTests.swift` — replay the connected → disconnected stale value → updated registry value sequence and assert both source selection and visible output.

## Decision Checkpoint

No execution-level decision remains. The failing screenshot supplied the exact stale-equality signal: `63.8 Wh` and `16.9 W` imply 227 minutes, while the displayed 58 minutes is the unchanged charging-era registry value. `SystemMonitor` is the only existing owner that sees both connection transitions and successive raw samples, so it can suppress only that false source without adding telemetry fields.

---

### Task 1: Suppress unchanged connected-time values after an unplug

**Files:**

- Modify: `Wattly/Core/SystemMonitor.swift:299-340`
- Test: `WattlyTests/SystemMonitorTests.swift:125-176`

**Interfaces:**

- Consumes: `BatterySample.externalConnected: Bool`, `BatterySample.timeRemainingMinutes: Int?`, `BatterySample.remainingWh: Double?`, and `BatterySample.netW: Double`.
- Produces: Stored and smoothed battery samples with `timeRemainingMinutes == nil` only while an unchanged connected-time value is stale; unchanged `CardPresentation.batteryRemainingTimeSummary(_:)` supplies the existing estimate.

- [x] **Step 1: Write the failing stale-time transition test**

Append this test before `batteryPlugInResetsHistory` in `WattlyTests/SystemMonitorTests.swift`:

~~~swift
    @Test func batteryDisconnectSuppressesUnchangedChargingTimeUntilRegistryChanges() async {
        func battery(netW: Double, connected: Bool, time: Int?) -> ProviderReading {
            .value(.battery(BatterySample(
                netW: netW,
                milliamps: Int((abs(netW) * 1_000 / 12.5).rounded()),
                volts: 12.5,
                charging: netW < -0.2,
                externalConnected: connected,
                remainingWh: 63.8,
                timeRemainingMinutes: time)))
        }

        let provider = ScriptedProvider(kind: .battery, [
            battery(netW: -16.9, connected: true, time: 58),
            battery(netW: 16.9, connected: false, time: 58),
            battery(netW: 16.9, connected: false, time: 58),
            battery(netW: 16.9, connected: false, time: 230),
        ])
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [provider], clock: clock)

        await monitor.pollOnce()
        clock.advance(by: .seconds(1))
        await monitor.pollOnce()
        guard case .value(.battery(let afterUnplug)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("battery card should have a value after unplug"); return
        }
        #expect(afterUnplug.timeRemainingMinutes == nil)
        #expect(CardPresentation.batteryRemainingTimeSummary(afterUnplug) == "3시간 47분 남음")

        clock.advance(by: .seconds(1))
        await monitor.pollOnce()
        guard case .value(.battery(let repeatedStaleTime)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("battery card should retain a value while stale time repeats"); return
        }
        #expect(repeatedStaleTime.timeRemainingMinutes == nil)
        #expect(CardPresentation.batteryRemainingTimeSummary(repeatedStaleTime) == "3시간 47분 남음")

        clock.advance(by: .seconds(1))
        await monitor.pollOnce()
        guard case .value(.battery(let updatedRegistryTime)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("battery card should have a value after registry time changes"); return
        }
        #expect(updatedRegistryTime.timeRemainingMinutes == 230)
        #expect(CardPresentation.batteryRemainingTimeSummary(updatedRegistryTime) == "3시간 50분 남음")
    }
~~~

- [x] **Step 2: Run the focused test to verify it fails**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/SystemMonitorTests
~~~

Expected: FAIL because the first disconnected sample still carries the unchanged raw value `58`, so the card formats `0시간 58분 남음` instead of the 227-minute estimate.

- [x] **Step 3: Normalize stale time before storing and smoothing the sample**

In `Wattly/Core/SystemMonitor.swift`, replace the `.value(let sample)` branch in `apply(_:from:at:)` with:

~~~swift
        case .value(let rawSample):
            let sample: MetricSample
            if case .battery(let battery) = rawSample {
                sample = .battery(suppressingStaleTimeAfterDisconnect(battery))
            } else {
                sample = rawSample
            }
            states[kind] = .value(sample)
            recordHistory(for: kind, sample: sample, at: instant)
~~~

Directly after `private var lastExternalConnected: Bool?`, add the state and helper:

~~~swift
    /// Last non-nil registry time observed while an adapter was connected. A matching value
    /// immediately after unplug is the charging-era estimate, not a fresh discharge estimate.
    private var lastConnectedTimeRemainingMinutes: Int?
    /// The connected-era value to suppress until AppleSmartBattery publishes a different,
    /// non-nil discharge estimate. nil means no stale value is being tracked.
    private var staleTimeRemainingAfterDisconnect: Int?

    private func suppressingStaleTimeAfterDisconnect(_ raw: BatterySample) -> BatterySample {
        var sample = raw
        let rawTime = raw.timeRemainingMinutes

        if raw.externalConnected {
            lastConnectedTimeRemainingMinutes = rawTime
            staleTimeRemainingAfterDisconnect = nil
        } else if lastExternalConnected == true {
            staleTimeRemainingAfterDisconnect = lastConnectedTimeRemainingMinutes
        } else if let stale = staleTimeRemainingAfterDisconnect,
                  let rawTime,
                  rawTime != stale {
            staleTimeRemainingAfterDisconnect = nil
        }

        if rawTime == staleTimeRemainingAfterDisconnect {
            sample.timeRemainingMinutes = nil
        }
        return sample
    }
~~~

- [x] **Step 4: Run the focused test, complete suite, and macOS build**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/SystemMonitorTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' build
~~~

Expected: All commands succeed. The focused test proves 58 is suppressed only across the unplug transition and that a later 230-minute registry value resumes normal precedence; the full suite and build protect the broader monitor/smoothing behavior.

- [x] **Step 5: Commit the stale-time correction**

Run:

~~~bash
git add Wattly/Core/SystemMonitor.swift WattlyTests/SystemMonitorTests.swift docs/plans/2026-07-29-battery-stale-time-after-unplug.md
git commit -m "fix(battery): ignore stale time after unplug"
~~~

Expected: Git creates one commit containing the transition-scoped correction, regression coverage, and this implementation plan.

---

## Self-Review

1. **Spec coverage:** Task 1 detects the connected-to-disconnected boundary, suppresses only a repeated connected value, keeps fallback behavior active while it repeats, and restores the changed macOS value.
2. **Placeholder scan:** No incomplete markers, unspecified test cases, or undefined interfaces remain. All source/test edits and commands are exact.
3. **Type consistency:** Both transition-tracking properties are `Int?`, matching `BatterySample.timeRemainingMinutes`; the helper accepts and returns `BatterySample`, and `apply` wraps it back into `MetricSample.battery`.

## Automatic Plan Review

Skipped: this is a single-task plan, so the required automatic reviewer round-trip does not apply.
