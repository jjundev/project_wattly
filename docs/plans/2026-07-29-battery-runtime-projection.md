# Battery Runtime Projection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the battery card's remaining-runtime subtitle moving by whole minutes between macOS estimate updates, while preserving trustworthy re-anchoring after fresh telemetry, charger changes, and sleep/wake gaps.

**Architecture:** Add `BatteryRuntimeProjection`, a small pure-state module that receives a normalized `BatterySample` and its monotonic poll time, chooses registry time first or a sustained-power fallback second, and projects a stable whole-minute value only while the candidate source is unchanged. It keeps the candidate's original anchor separate from its most recent observation, so ordinary 1–5-second polls can cross a minute boundary but a true sleep/wake-sized inter-sample gap re-anchors safely. `SystemMonitor` owns this module because it already owns adapter-transition cleanup, the one-minute average, smoothing, and the injected clock; it writes the resulting display-only minute field into the sample consumed by `CardPresentation`.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI Observation, IOKit, XcodeGen.

## Global Constraints

- Swift 6 language mode; deployment target macOS 14.0; arm64 only. (`project.yml`)
- Add no third-party dependency and make no extra IOKit/SMC reads; the existing battery polling cadence remains unchanged.
- Create `Wattly/Core/BatteryRuntimeProjection.swift`; regenerate `Wattly.xcodeproj` from `project.yml` with `xcodegen generate` after adding the source/test files.
- Keep valid, normalized AppleSmartBattery `TimeRemaining` as the first candidate; retain the existing connected-era stale-time suppression before projection.
- When registry time is unavailable, calculate a candidate with the existing bounded `estimatedTimeRemainingMinutes(remainingWattHours:netW:)`, preferring a valid positive one-minute average and otherwise the current net discharge power.
- Never project or render runtime while `BatterySample.charging == true`, when no bounded candidate exists, or across a sampling gap longer than 30 seconds; the next sample becomes a new anchor instead.
- Do not add a one-second UI timer or lower the battery poll interval. The visible panel already causes a 1- or 5-second monitor update, which is sufficient for a whole-minute subtitle.
- User-facing remaining-time copy is exactly `약 N시간 M분 남음` and must flow through the existing `CardPresentation.subText(_:)` path so VoiceOver receives the same wording.
- Preserve the raw `timeRemainingMinutes` field as provider telemetry. Add a separate optional `projectedTimeRemainingMinutes` display field; do not overwrite raw registry data.
- Keep the adapter-transition reset, power smoothing, sparkline history, one-minute average, capacity, efficiency, and cycle fields working exactly as they do now.

---

## File Structure

- Create: `Wattly/Core/BatteryRuntimeProjection.swift` — stateful, deterministic runtime-candidate selection, anchoring, minute projection, long-gap handling, and reset behavior.
- Create: `WattlyTests/BatteryRuntimeProjectionTests.swift` — direct tests of registry priority, fallback selection, same-source countdown, re-anchoring, charging reset, and sleep/wake gap handling.
- Modify: `Wattly/Models/MetricSample.swift` — add the display-only projected-minute field to `BatterySample`.
- Modify: `Wattly/Core/SystemMonitor.swift` — instantiate the projection module, update it after stale-time normalization and one-minute-average calculation, reset it on adapter changes, and preserve the projected field through smoothing.
- Modify: `Wattly/Core/CardPresentation.swift` — render only the monitor-owned projected value as the approximate Korean subtitle.
- Modify: `WattlyTests/SystemMonitorTests.swift` — prove the projected value survives monitor processing and the smoothed battery state, including the existing unplug-stale guard.
- Modify: `WattlyTests/CardPresentationTests.swift` — pin approximate copy, charging suppression, and the fact that raw provider fields alone cannot bypass monitor-owned display policy.
- Modify: `Wattly.xcodeproj/project.pbxproj` — XcodeGen-generated reference/build-file changes for the two new Swift files.
- Create: `docs/plans/2026-07-29-battery-runtime-projection.md` — this plan.

## Decision Checkpoint

No execution-level decision remains. The existing code already provides the exact seam required for deterministic time: `SystemMonitor` receives a `ContinuousClock.Instant` for every provider read, owns the adapter transition and the one-minute average, and is observed by all card layouts. A one-minute display projection is therefore an implementation detail of one module rather than a new SwiftUI timer, a provider responsibility, or a second source of truth in `CardPresentation`.

---

### Task 1: Add the isolated runtime-projection module and its deterministic tests

**Files:**

- Create: `Wattly/Core/BatteryRuntimeProjection.swift`
- Create: `WattlyTests/BatteryRuntimeProjectionTests.swift`
- Modify: `Wattly.xcodeproj/project.pbxproj` (generated by `xcodegen generate`)

**Interfaces:**

- Consumes: `BatterySample.charging: Bool`, `BatterySample.timeRemainingMinutes: Int?`, `BatterySample.remainingWh: Double?`, `BatterySample.netW: Double`, `BatterySample.average1mW: Double?`, and `ContinuousClock.Instant`.
- Produces: `BatteryRuntimeProjection.ingest(_:at:) -> Int?` and `BatteryRuntimeProjection.reset()`. The return is an integer in `1...1_440`, projected from the last matching candidate; `nil` means the card must not show a runtime.

- [ ] **Step 1: Write the failing projection tests**

Create `WattlyTests/BatteryRuntimeProjectionTests.swift` with the following complete test suite:

~~~swift
import Foundation
import Testing
@testable import Wattly

struct BatteryRuntimeProjectionTests {
    private let clock = ContinuousClock()

    private func discharging(time: Int? = nil,
                             remainingWh: Double? = 60,
                             netW: Double = 30,
                             average1mW: Double? = nil) -> BatterySample {
        BatterySample(netW: netW,
                      milliamps: Int((netW * 1_000 / 12).rounded()),
                      volts: 12,
                      charging: false,
                      externalConnected: false,
                      remainingWh: remainingWh,
                      timeRemainingMinutes: time,
                      average1mW: average1mW)
    }

    @Test func unchangedRegistryMinutesCountDownFromTheirFirstObservation() {
        var projection = BatteryRuntimeProjection()
        let now = clock.now
        let sample = discharging(time: 210)

        #expect(projection.ingest(sample, at: now) == 210)
        for seconds in stride(from: 5, through: 55, by: 5) {
            #expect(projection.ingest(sample, at: now.advanced(by: .seconds(seconds))) == 210)
        }
        #expect(projection.ingest(sample, at: now.advanced(by: .seconds(60))) == 209)
    }

    @Test func changedRegistryMinutesReanchorImmediately() {
        var projection = BatteryRuntimeProjection()
        let now = clock.now

        #expect(projection.ingest(discharging(time: 210), at: now) == 210)
        #expect(projection.ingest(discharging(time: 230), at: now.advanced(by: .seconds(5))) == 230)
        for seconds in stride(from: 10, through: 60, by: 5) {
            #expect(projection.ingest(discharging(time: 230), at: now.advanced(by: .seconds(seconds))) == 230)
        }
        #expect(projection.ingest(discharging(time: 230), at: now.advanced(by: .seconds(65))) == 229)
    }

    @Test func fallbackPrefersValidOneMinuteAverageThenCountsDown() {
        var projection = BatteryRuntimeProjection()
        let now = clock.now
        // 60 Wh / 30 W * 60 = 120 min. The 60 W instantaneous value would be 60 min.
        let sample = discharging(remainingWh: 60, netW: 60, average1mW: 30)

        #expect(projection.ingest(sample, at: now) == 120)
        for seconds in stride(from: 5, through: 55, by: 5) {
            #expect(projection.ingest(sample, at: now.advanced(by: .seconds(seconds))) == 120)
        }
        #expect(projection.ingest(sample, at: now.advanced(by: .seconds(60))) == 119)
    }

    @Test func invalidAverageFallsBackToCurrentDischargePower() {
        var projection = BatteryRuntimeProjection()
        let now = clock.now
        // The non-discharging average is unusable; 60 Wh / 20 W * 60 = 180 min.
        let sample = discharging(remainingWh: 60, netW: 20, average1mW: -2)

        #expect(projection.ingest(sample, at: now) == 180)
    }

    @Test func chargingAndLongGapsDiscardTheOldAnchor() {
        var projection = BatteryRuntimeProjection()
        let now = clock.now
        let sample = discharging(time: 210)
        let charging = BatterySample(netW: -20, milliamps: 1_667, volts: 12,
                                     charging: true, externalConnected: true,
                                     timeRemainingMinutes: 210)

        #expect(projection.ingest(sample, at: now) == 210)
        // A 31-second sleep/wake-sized gap is re-anchored, not decremented by elapsed time.
        #expect(projection.ingest(sample, at: now.advanced(by: .seconds(31))) == 210)
        #expect(projection.ingest(charging, at: now.advanced(by: .seconds(32))) == nil)
        #expect(projection.ingest(sample, at: now.advanced(by: .seconds(33))) == 210)
    }
}
~~~

- [ ] **Step 2: Regenerate the project and run the focused test to verify it fails**

Run:

~~~bash
xcodegen generate
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryRuntimeProjectionTests
~~~

Expected: FAIL to compile because `BatteryRuntimeProjection` is not defined yet. The generated Xcode project includes the new test file, so the failure confirms the test target sees it.

- [ ] **Step 3: Implement the projection module**

Create `Wattly/Core/BatteryRuntimeProjection.swift` with this complete implementation:

~~~swift
import Foundation

/// Stateful display policy for a battery runtime estimate. It deliberately owns neither I/O
/// nor SwiftUI: `SystemMonitor` supplies its normalized sample at each scheduled poll.
/// A repeated candidate is projected from its first observation, while any new telemetry,
/// source change, charging transition, or long gap becomes a new baseline.
struct BatteryRuntimeProjection {
    private enum Source: Equatable {
        case registry
        case estimated
    }

    private struct Candidate {
        var minutes: Int
        var source: Source
    }

    private struct Anchor {
        var minutes: Int
        var source: Source
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
              seconds(from: lastObservation, to: now) <= Self.maximumProjectionGap
        else {
            self.anchor = Anchor(minutes: candidate.minutes, source: candidate.source, at: now)
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
        guard !sample.charging else { return nil }
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

    private func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
}
~~~

- [ ] **Step 4: Regenerate the project and run the focused test to verify it passes**

Run:

~~~bash
xcodegen generate
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryRuntimeProjectionTests
~~~

Expected: PASS. The tests prove that registry time is authoritative, only unchanged candidates count down, a fresh value re-anchors, a valid one-minute average stabilizes the fallback, and neither charging nor a long suspension applies stale elapsed time.

- [ ] **Step 5: Commit the self-contained projection module**

Run:

~~~bash
git add Wattly/Core/BatteryRuntimeProjection.swift WattlyTests/BatteryRuntimeProjectionTests.swift Wattly.xcodeproj/project.pbxproj docs/plans/2026-07-29-battery-runtime-projection.md
git commit -m "feat(battery): project remaining runtime between updates"
~~~

Expected: Git creates a commit containing the pure module, its direct regression tests, generated project references, and this plan. It must not stage the pre-existing untracked `.superpowers/` or `prototypes/` directories.

---

### Task 2: Integrate projected minutes into the observed battery card state and approximate copy

**Files:**

- Modify: `Wattly/Models/MetricSample.swift:120-137`
- Modify: `Wattly/Core/SystemMonitor.swift:22-26,299-403,411-443`
- Modify: `Wattly/Core/CardPresentation.swift:241-246`
- Modify: `WattlyTests/SystemMonitorTests.swift:175-223`
- Modify: `WattlyTests/CardPresentationTests.swift:24-160`

**Interfaces:**

- Consumes: `BatteryRuntimeProjection.ingest(_:at:) -> Int?`, `BatteryRuntimeProjection.reset()`, the already normalized battery sample, `SystemMonitor.batteryOneMinuteAverage`, and adapter transition state.
- Produces: `BatterySample.projectedTimeRemainingMinutes: Int?`, set only by `SystemMonitor`; `CardPresentation.batteryRemainingTimeSummary(_:) -> String?`, which returns `약 N시간 M분 남음` only for a non-charging sample with a valid projected minute count.

- [ ] **Step 1: Write the failing monitor and presentation tests**

In `WattlyTests/CardPresentationTests.swift`, replace `batteryValueAndCollapsedSummary` with this version so every remaining-time assertion uses the monitor-owned field and approximate copy:

~~~swift
    @Test func batteryValueAndCollapsedSummary() {
        let discharging = MetricState.value(.battery(BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 210,
            projectedTimeRemainingMinutes: 210,
            average1mW: 10.4)))
        #expect(CardPresentation.valueText(.battery, discharging) == "\(minus)12.0")
        #expect(CardPresentation.subText(discharging) == "약 3시간 30분 남음")

        let timeOnly = MetricState.value(.battery(BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 1,
            projectedTimeRemainingMinutes: 1)))
        #expect(CardPresentation.subText(timeOnly) == "약 0시간 1분 남음")

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
~~~

In the existing `batteryRemainingCapacityEfficiencyAndCycleTextForExpand` test, add `projectedTimeRemainingMinutes: 210` immediately after its `timeRemainingMinutes: 210` argument and change only its final runtime assertion to:

~~~swift
        #expect(CardPresentation.batteryRemainingTimeSummary(populated) == "약 3시간 30분 남음")
~~~

In the same file, replace the body of `batteryAverageAndRemainingTimeVisibilityRules` with:

~~~swift
    @Test func batteryAverageAndRemainingTimeVisibilityRules() {
        let discharging = BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 210,
            projectedTimeRemainingMinutes: 210,
            average1mW: 10.4)
        #expect(CardPresentation.batteryAverage1mLabel == "1분 평균")
        #expect(CardPresentation.batteryAverage1mText(discharging) == "\(minus)10.4 W")
        #expect(CardPresentation.batteryRemainingTimeSummary(discharging) == "약 3시간 30분 남음")

        let rawOnly = BatterySample(
            netW: 20.0,
            milliamps: 1_575,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            remainingWh: 49.5,
            timeRemainingMinutes: 149)
        #expect(CardPresentation.batteryRemainingTimeSummary(rawOnly) == nil)

        let charging = BatterySample(
            netW: -5.0,
            milliamps: 400,
            volts: 12.7,
            charging: true,
            externalConnected: true,
            projectedTimeRemainingMinutes: 210,
            average1mW: -3.0)
        #expect(CardPresentation.batteryAverage1mText(charging) == "+3.0 W")
        #expect(CardPresentation.batteryRemainingTimeSummary(charging) == nil)
    }
~~~

In the existing `batteryDisconnectSuppressesUnchangedChargingTimeUntilRegistryChanges` test in `WattlyTests/SystemMonitorTests.swift`, change its three subtitle expectations to `"약 3시간 47분 남음"`, `"약 3시간 47분 남음"`, and `"약 3시간 50분 남음"` respectively. Immediately after that test, add:

~~~swift
    @Test func batteryProjectedMinutesSurviveTheSmoothedCardState() async {
        func battery() -> ProviderReading {
            .value(.battery(BatterySample(
                netW: 30,
                milliamps: 2_400,
                volts: 12.5,
                charging: false,
                externalConnected: false,
                remainingWh: 60,
                timeRemainingMinutes: nil)))
        }

        let provider = ScriptedProvider(kind: .battery, [battery(), battery()])
        let clock = ManualClock()
        let monitor = SystemMonitor(providers: [provider], clock: clock)

        await monitor.pollOnce()
        // Mirror the open panel's normal five-second battery reads. This keeps every
        // observation below the projection module's 30-second sleep/wake gap limit.
        for _ in 1...12 {
            clock.advance(by: .seconds(5))
            await monitor.pollOnce()
        }

        guard case .value(.battery(let sample)) = monitor.cardState(.battery, smoothed: true) else {
            Issue.record("smoothed battery card should have a value"); return
        }
        #expect(sample.projectedTimeRemainingMinutes == 119)
        #expect(CardPresentation.batteryRemainingTimeSummary(sample) == "약 1시간 59분 남음")
    }
~~~

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/SystemMonitorTests
~~~

Expected: FAIL to compile because `BatterySample.projectedTimeRemainingMinutes` does not exist. After temporarily adding the field, the tests still fail because monitor samples do not call the projection module and the current formatter renders the raw value without the `약` prefix.

- [ ] **Step 3: Add the display field, integrate it at the monitor seam, and update the formatter**

In `Wattly/Models/MetricSample.swift`, insert this field immediately after `timeRemainingMinutes`:

~~~swift
    /// Monitor-owned display value projected between telemetry updates. The provider never
    /// assigns it; nil means runtime is unavailable or intentionally hidden.
    var projectedTimeRemainingMinutes: Int? = nil
~~~

In `Wattly/Core/SystemMonitor.swift`, add the module state directly after `batteryOneMinuteInstant`:

~~~swift
    /// Projects a whole-minute battery runtime between unchanged registry/fallback values.
    /// It is reset with the battery regime so elapsed time never crosses an adapter change.
    private var batteryRuntimeProjection = BatteryRuntimeProjection()
~~~

Replace `apply(_:from:at:)` with the following implementation. This moves battery-specific presentation preparation before state assignment; every non-battery provider retains the existing behavior.

~~~swift
    private func apply(_ reading: ProviderReading, from kind: ProviderKind, at instant: ContinuousClock.Instant) {
        switch reading {
        case .pending:
            states[kind] = .loading
        case .unavailable(let reason):
            states[kind] = .unavailable(reason)
        case .value(.battery(let rawBattery)):
            let battery = preparedBattery(rawBattery, at: instant)
            let sample = MetricSample.battery(battery)
            states[kind] = .value(sample)
            recordHistory(for: kind, sample: sample, at: instant)
        case .value(let sample):
            states[kind] = .value(sample)
            recordHistory(for: kind, sample: sample, at: instant)
        }
    }
~~~

Insert this helper immediately after `suppressingStaleTimeAfterDisconnect(_:)`. It preserves the old reset/EMA/smoothing order, but enriches the exact sample stored in state before it reaches every card layout.

~~~swift
    private func preparedBattery(_ raw: BatterySample, at instant: ContinuousClock.Instant) -> BatterySample {
        let sample = suppressingStaleTimeAfterDisconnect(raw)
        if let last = lastExternalConnected, last != sample.externalConnected {
            history[.battery] = HistoryBuffer()
            batteryOverlay.reset()
            batteryOneMinuteAverage = nil
            batteryOneMinuteInstant = nil
            batteryRuntimeProjection.reset()
        }
        lastExternalConnected = sample.externalConnected

        let averageDt = batteryOneMinuteInstant.map { seconds(from: $0, to: instant) } ?? 0
        batteryOneMinuteAverage = PowerSmoothing.emaStep(
            previous: batteryOneMinuteAverage, raw: sample.netW, dt: averageDt, tau: 60)
        batteryOneMinuteInstant = instant

        var presented = sample
        presented.average1mW = batteryOneMinuteAverage
        presented.projectedTimeRemainingMinutes = batteryRuntimeProjection.ingest(presented, at: instant)
        batteryOverlay.ingest(at: instant,
            smooth: { previous, dt in
                let netW = PowerSmoothing.emaStep(previous: previous?.netW, raw: presented.netW, dt: dt)
                return Self.batterySmoothed(from: presented, netW: netW)
            },
            series: \.netW)
        return presented
    }
~~~

Replace the battery branch at the start of `recordHistory(for:sample:at:)` with nothing, leaving the existing power-overlay branch and the `for card in CardKind.allCases` history loop intact. The resulting method must begin exactly as follows:

~~~swift
    private func recordHistory(for kind: ProviderKind, sample: MetricSample, at instant: ContinuousClock.Instant) {
        if case .power(let s) = sample {
            powerOverlay.ingest(at: instant,
                smooth: { previous, dt in PowerSmoothing.step(previous: previous, raw: s, dt: dt) },
                series: \.totalW)
        }
        for card in CardKind.allCases where card.provider == kind {
            if let scalar = Self.scalar(of: card, from: sample) {
                history[card, default: HistoryBuffer()].append(scalar, at: instant)
            }
        }
    }
~~~

In `batterySmoothed(from:netW:)`, preserve the new field when rebuilding the sample by inserting it immediately after `timeRemainingMinutes`:

~~~swift
            projectedTimeRemainingMinutes: raw.projectedTimeRemainingMinutes,
~~~

Finally, replace `CardPresentation.batteryRemainingTimeSummary(_:)` with:

~~~swift
    static func batteryRemainingTimeSummary(_ s: BatterySample) -> String? {
        guard !s.charging,
              let totalMinutes = validatedTimeRemainingMinutes(s.projectedTimeRemainingMinutes)
        else { return nil }
        return "약 \(totalMinutes / 60)시간 \(totalMinutes % 60)분 남음"
    }
~~~

`Accessibility.cardLabel(_:_: )` needs no edit: it already appends `CardPresentation.subText(_:)`, so VoiceOver automatically gains the same approximate wording.

- [ ] **Step 4: Run focused tests, the full suite, and a macOS build**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryRuntimeProjectionTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/SystemMonitorTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' build
~~~

Expected: All commands succeed. The focused tests prove direct projection policy, approximate copy, raw-field isolation, stale-time fallback after unplug, and preservation through the smoothed card state; the full test/build checks all layouts and the fan-daemon target still compile.

- [ ] **Step 5: Commit monitor integration and user-visible copy**

Run:

~~~bash
git add Wattly/Models/MetricSample.swift Wattly/Core/SystemMonitor.swift Wattly/Core/CardPresentation.swift WattlyTests/SystemMonitorTests.swift WattlyTests/CardPresentationTests.swift docs/plans/2026-07-29-battery-runtime-projection.md
git commit -m "fix(battery): keep remaining-time subtitle current"
~~~

Expected: Git creates a second commit containing the monitor/model/presentation integration and regression coverage. The commit must not include the pre-existing untracked `.superpowers/` or `prototypes/` directories.

---

## Self-Review

1. **Spec coverage:** Task 1 provides the isolated anchor/advance/reset behavior, including registry priority, one-minute-average fallback, invalid-average fallback, charging suppression, and long-gap re-anchoring. Task 2 supplies the monitor-owned data flow, keeps unplug stale-time suppression ahead of candidate selection, resets the projection on adapter changes, retains the field through smoothing, changes the visible and VoiceOver copy, and updates every affected direct presentation assertion so no raw provider value bypasses monitor policy.
2. **Placeholder scan:** No incomplete markers, deferred decisions, or vague test instructions remain. Each source edit is supplied as a complete insertion/replacement and every test cycle names exact commands and expected outcomes.
3. **Type consistency:** `BatteryRuntimeProjection.ingest(_:at:)` accepts `BatterySample` and returns `Int?`; the new `BatterySample.projectedTimeRemainingMinutes` stores that exact type; `CardPresentation` validates and formats the same field. `preparedBattery(_:at:)` is the only monitor method assigning it, and `batterySmoothed(from:netW:)` preserves it.

## Automatic Plan Review

The first read-only review found one blocking issue: the 30-second gap was measured from the original anchor, which would re-anchor regular polling before a minute elapsed. The plan now stores a separate `lastObservation` timestamp and supplies five-second cadence tests through the minute boundary.

The single permitted re-review found one further blocking issue: two existing `CardPresentationTests` still expected raw time and non-approximate copy. Task 2 Step 1 now replaces or amends all three affected presentation tests (`batteryValueAndCollapsedSummary`, `batteryAverageAndRemainingTimeVisibilityRules`, and `batteryRemainingCapacityEfficiencyAndCycleTextForExpand`). No additional reviewer pass is permitted by the bounded review process; the final self-review above verifies the test names, field name, and expected copy agree with the source steps.
