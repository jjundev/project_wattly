# Battery Remaining Capacity and Time Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Show remaining battery energy in Wh and estimated remaining use time in h m on the existing expanded battery card.

**Architecture:** BatterySample gains optional remainingWh and timeRemainingMinutes fields. BatteryProvider reads AppleSmartBattery once per poll even when SMC supplies the live power headline, converts raw mAh plus SMC voltage to Wh, and preserves the OS TimeRemaining minute estimate. The existing smoothing path passes these fields through unchanged; CardPresentation formats Korean labels and CardExpandRegion renders the details in layouts A and C.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, IOKit, XcodeGen project.

## Global Constraints

- Swift 6 language mode; deployment target macOS 14.0; arm64 only. (project.yml)
- Use no new dependencies and create no new source files; XcodeGen does not need to run.
- SMC remains authoritative for live netW, current, voltage, and charge direction. AppleSmartBattery supplements it with capacity/time and remains the existing fallback.
- Read AppleRawCurrentCapacity (mAh), not CurrentCapacity (percentage), and calculate Wh as mAh × V / 1000.
- Accept TimeRemaining only in 1...1440 minutes; unknown, sentinel, zero, and out-of-range values become nil.
- Preserve capacity/time through battery display smoothing; never smooth or derive either value from power history.
- New Korean copy belongs in CardPresentation. Format Wh to one decimal and time as <hours>h <minutes>m.
- Layout B remains compact with no sub-line/expand interaction. The new details appear in expanded mode-A cards and expanded mode-C battery heroes.

---

## File Structure

- Modify: Wattly/Models/MetricSample.swift — optional BatterySample fields with nil defaults.
- Modify: Wattly/Core/BatteryPower.swift — pure raw-capacity conversion and time validation.
- Modify: Wattly/Providers/BatteryProvider.swift — one AppleSmartBattery snapshot per poll; enrich SMC/fallback samples.
- Modify: Wattly/Core/SystemMonitor.swift — retain the two fields when rebuilding a smoothed BatterySample.
- Modify: Wattly/Core/CardPresentation.swift — Korean labels and pure text formatters.
- Modify: Wattly/Views/CardExpandRegion.swift — optional capacity/time detail rows.
- Modify: WattlyTests/BatteryPowerTests.swift — conversion/validation tests.
- Modify: WattlyTests/SystemMonitorTests.swift — smoothing propagation test.
- Modify: WattlyTests/CardPresentationTests.swift — labels and display-format tests.

## Decision Checkpoint

No execution-level decision remains. The existing battery card already has a shared detail expansion for voltage/current, so its established component boundary also owns capacity/time without changing the compact grid.

---

### Task 1: Add validated remaining-energy and time telemetry

**Files:**

- Modify: Wattly/Models/MetricSample.swift:142-164
- Modify: Wattly/Core/BatteryPower.swift:1-61
- Modify: Wattly/Providers/BatteryProvider.swift:29-89
- Test: WattlyTests/BatteryPowerTests.swift:1-84

**Interfaces:**

- Consumes: AppleSmartBattery AppleRawCurrentCapacity (mAh), TimeRemaining (minutes), Voltage (mV), plus the existing SMC BatterySample.volts.
- Produces: BatterySample.remainingWh: Double?, BatterySample.timeRemainingMinutes: Int?, remainingWattHours(rawCapacityMilliampHours:volts:) -> Double?, validatedTimeRemainingMinutes(_:) -> Int?.

- [ ] **Step 1: Write failing pure conversion and validation tests**

Append to WattlyTests/BatteryPowerTests.swift:

~~~swift
    // MARK: Remaining battery energy/time — AppleSmartBattery raw capacity + estimate

    @Test func remainingWattHoursUsesRawMilliampHoursAndPackVoltage() {
        let wh = remainingWattHours(rawCapacityMilliampHours: 4_128, volts: 11.981)
        #expect(abs((wh ?? 0) - 49.457568) < 0.000_001)
    }

    @Test func remainingWattHoursRejectsInvalidCapacityOrVoltage() {
        #expect(remainingWattHours(rawCapacityMilliampHours: 0, volts: 12.0) == nil)
        #expect(remainingWattHours(rawCapacityMilliampHours: -1, volts: 12.0) == nil)
        #expect(remainingWattHours(rawCapacityMilliampHours: 4_128, volts: 0) == nil)
        #expect(remainingWattHours(rawCapacityMilliampHours: 4_128, volts: .infinity) == nil)
    }

    @Test func timeRemainingAcceptsOnlyPlausiblePositiveMinutes() {
        #expect(validatedTimeRemainingMinutes(210) == 210)
        #expect(validatedTimeRemainingMinutes(1) == 1)
        #expect(validatedTimeRemainingMinutes(1_440) == 1_440)
        #expect(validatedTimeRemainingMinutes(0) == nil)
        #expect(validatedTimeRemainingMinutes(-1) == nil)
        #expect(validatedTimeRemainingMinutes(65_535) == nil)
        #expect(validatedTimeRemainingMinutes(1_441) == nil)
    }
~~~

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryPowerTests
~~~

Expected: FAIL to compile because remainingWattHours and validatedTimeRemainingMinutes do not exist.

- [ ] **Step 3: Add model fields and pure helpers**

In Wattly/Models/MetricSample.swift, insert after externalConnected:

~~~swift
    /// Remaining energy estimated from AppleSmartBattery raw remaining mAh and the
    /// live pack voltage. nil when the registry does not expose valid capacity.
    var remainingWh: Double? = nil
    /// AppleSmartBattery estimated time remaining in minutes. nil when unavailable,
    /// sentinel, or implausible; it is not inferred from instantaneous wattage.
    var timeRemainingMinutes: Int? = nil
~~~

Append to Wattly/Core/BatteryPower.swift after batteryMilliamps:

~~~swift
/// Convert AppleSmartBattery raw remaining capacity (mAh) at current pack voltage into Wh.
/// Invalid registry inputs remain absent rather than becoming a misleading 0 Wh.
func remainingWattHours(rawCapacityMilliampHours: Int, volts: Double) -> Double? {
    guard rawCapacityMilliampHours > 0, volts.isFinite, volts > 0 else { return nil }
    return Double(rawCapacityMilliampHours) * volts / 1_000.0
}

/// TimeRemaining is an estimated minute count. Suppress zero, sentinels such as 65535,
/// and values outside a one-day laptop runtime so corrupt values cannot reach the UI.
func validatedTimeRemainingMinutes(_ minutes: Int?) -> Int? {
    guard let minutes, (1...1_440).contains(minutes) else { return nil }
    return minutes
}
~~~

- [ ] **Step 4: Refactor the provider to obtain one registry snapshot and enrich both paths**

Replace read(at:), smcSample(), and appleSmartBatteryReading() in Wattly/Providers/BatteryProvider.swift with this code. Keep number, bool, and dict unchanged.

~~~swift
    private struct AppleSmartBatterySnapshot {
        var volts: Double?
        var externalConnected: Bool
        var batteryMilliwatts: Int?
        var rawCurrentCapacityMilliampHours: Int?
        var timeRemainingMinutes: Int?
    }

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        let registry = appleSmartBatterySnapshot()
        if !smcAttempted { smcAttempted = true; smc = SMCConnection() }
        if let sample = smcSample(registry: registry) { return .value(.battery(sample)) }
        return appleSmartBatteryReading(registry: registry)
    }

    private func smcSample(registry: AppleSmartBatterySnapshot?) -> BatterySample? {
        guard let smc,
              let power = smc.read("B0AP"),
              let voltage = smc.read("B0AV") else { return nil }
        let milliwatts = Int(smcDouble(power.bytes, type: power.type).rounded())
        let volts = smcDouble(voltage.bytes, type: voltage.type) / 1000.0
        let netW = netWatts(batteryMilliwatts: milliwatts)
        let mA = smc.read("B0AC").map { Int(smcDouble($0.bytes, type: $0.type).rounded()) }
            ?? batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)
        let adapterW = smc.read("PDTR").map { smcDouble($0.bytes, type: $0.type) } ?? 0
        return BatterySample(
            netW: netW,
            milliamps: abs(mA),
            volts: volts,
            charging: isCharging(netW: netW),
            externalConnected: adapterW > 0.5,
            remainingWh: remainingWattHours(
                rawCapacityMilliampHours: registry?.rawCurrentCapacityMilliampHours ?? 0,
                volts: volts),
            timeRemainingMinutes: validatedTimeRemainingMinutes(registry?.timeRemainingMinutes))
    }

    private func appleSmartBatterySnapshot() -> AppleSmartBatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let volts = number(service, "Voltage").map { Double($0.int64Value) / 1000.0 }
        let externalConnected = bool(service, "ExternalConnected") ?? false
        let batteryMilliwatts: Int?
        if let telemetry = dict(service, "PowerTelemetryData"),
           let raw = (telemetry["BatteryPower"] as? NSNumber)?.uint64Value {
            batteryMilliwatts = twosComplement(raw)
        } else if let rawAmp = number(service, "InstantAmperage")?.uint64Value, let volts {
            batteryMilliwatts = Int((Double(twosComplement(rawAmp)) * volts).rounded())
        } else {
            batteryMilliwatts = nil
        }
        return AppleSmartBatterySnapshot(
            volts: volts,
            externalConnected: externalConnected,
            batteryMilliwatts: batteryMilliwatts,
            rawCurrentCapacityMilliampHours: number(service, "AppleRawCurrentCapacity")?.intValue,
            timeRemainingMinutes: number(service, "TimeRemaining")?.intValue)
    }

    private func appleSmartBatteryReading(registry: AppleSmartBatterySnapshot?) -> ProviderReading {
        guard let registry else { return .unavailable(.notPresent(Self.notPresentMessage)) }
        guard let volts = registry.volts, let milliwatts = registry.batteryMilliwatts else { return .pending }
        let netW = fallbackNetWatts(
            batteryMilliwatts: milliwatts,
            externalConnected: registry.externalConnected)
        return .value(.battery(BatterySample(
            netW: netW,
            milliamps: abs(batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)),
            volts: volts,
            charging: isCharging(netW: netW),
            externalConnected: registry.externalConnected,
            remainingWh: remainingWattHours(
                rawCapacityMilliampHours: registry.rawCurrentCapacityMilliampHours ?? 0,
                volts: volts),
            timeRemainingMinutes: validatedTimeRemainingMinutes(registry.timeRemainingMinutes))))
    }
~~~

- [ ] **Step 5: Run the focused test to verify it passes**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryPowerTests
~~~

Expected: PASS — existing battery math tests and three new conversion/validation tests pass.

- [ ] **Step 6: Commit**

~~~bash
git add Wattly/Models/MetricSample.swift Wattly/Core/BatteryPower.swift Wattly/Providers/BatteryProvider.swift WattlyTests/BatteryPowerTests.swift
git commit -m "feat(battery): collect remaining capacity and time"
~~~

### Task 2: Preserve telemetry through display smoothing

**Files:**

- Modify: Wattly/Core/SystemMonitor.swift:354-363
- Test: WattlyTests/SystemMonitorTests.swift:125-160

**Interfaces:**

- Consumes: BatterySample.remainingWh: Double? and BatterySample.timeRemainingMinutes: Int? from Task 1.
- Produces: smoothed samples that retain the same optional values.

- [ ] **Step 1: Extend the existing smoothing test**

Replace the local bat factory at the start of batteryDisplaySmoothingDampsAndResetsOnPlug in WattlyTests/SystemMonitorTests.swift:

~~~swift
        func bat(_ netW: Double, ext: Bool = false) -> ProviderReading {
            .value(.battery(BatterySample(
                netW: netW,
                milliamps: Int((abs(netW) * 1000 / 12.0).rounded()),
                volts: 12.0,
                charging: netW < -0.2,
                externalConnected: ext,
                remainingWh: 48.0,
                timeRemainingMinutes: netW > 0.05 ? 180 : nil)))
        }
~~~

Add after the existing smoothed-milliamps assertion:

~~~swift
        #expect(sm.remainingWh == 48.0)
        #expect(sm.timeRemainingMinutes == 180)
~~~

Add after the existing plugged-in charge-direction assertion:

~~~swift
        #expect(monitor.batteryOverlay.sample?.remainingWh == 48.0)
        #expect(monitor.batteryOverlay.sample?.timeRemainingMinutes == nil)
~~~

- [ ] **Step 2: Run the test to verify it fails**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/SystemMonitorTests/batteryDisplaySmoothingDampsAndResetsOnPlug
~~~

Expected: FAIL because batterySmoothed(from:netW:) reconstructs BatterySample without the new fields.

- [ ] **Step 3: Preserve the fields in the smoothed sample**

Replace the return body of batterySmoothed(from:netW:) in Wattly/Core/SystemMonitor.swift:

~~~swift
        return BatterySample(
            netW: netW,
            milliamps: mA,
            volts: raw.volts,
            charging: isCharging(netW: netW),
            externalConnected: raw.externalConnected,
            remainingWh: raw.remainingWh,
            timeRemainingMinutes: raw.timeRemainingMinutes,
            average1mW: raw.average1mW)
~~~

- [ ] **Step 4: Run the test to verify it passes**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/SystemMonitorTests/batteryDisplaySmoothingDampsAndResetsOnPlug
~~~

Expected: PASS — smoothing changes only power-derived fields while capacity/time remain supplied values.

- [ ] **Step 5: Commit**

~~~bash
git add Wattly/Core/SystemMonitor.swift WattlyTests/SystemMonitorTests.swift
git commit -m "fix(battery): retain remaining telemetry through smoothing"
~~~

### Task 3: Format and render remaining capacity and use time

**Files:**

- Modify: Wattly/Core/CardPresentation.swift:212-229
- Modify: Wattly/Views/CardExpandRegion.swift:148-171
- Test: WattlyTests/CardPresentationTests.swift:64-78

**Interfaces:**

- Consumes: BatterySample.remainingWh: Double? and BatterySample.timeRemainingMinutes: Int? from Tasks 1–2.
- Produces: CardPresentation.batteryRemainingCapacityLabel, CardPresentation.batteryRemainingTimeLabel, batteryRemainingCapacityText(_:), batteryRemainingTimeText(_:), and two optional expanded detail rows.

- [ ] **Step 1: Write failing pure presentation tests**

Append after batteryCurrentAndVoltageTextForExpand in WattlyTests/CardPresentationTests.swift:

~~~swift
    @Test func batteryRemainingCapacityAndTimeTextForExpand() {
        let populated = BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            remainingWh: 49.457568,
            timeRemainingMinutes: 210)
        #expect(CardPresentation.batteryRemainingCapacityLabel == "남은 용량")
        #expect(CardPresentation.batteryRemainingTimeLabel == "남은 사용시간")
        #expect(CardPresentation.batteryRemainingCapacityText(populated) == "49.5 Wh")
        #expect(CardPresentation.batteryRemainingTimeText(populated) == "3h 30m")

        let unavailable = BatterySample(
            netW: -10.0,
            milliamps: 800,
            volts: 12.0,
            charging: true,
            externalConnected: true)
        #expect(CardPresentation.batteryRemainingCapacityText(unavailable) == nil)
        #expect(CardPresentation.batteryRemainingTimeText(unavailable) == nil)

        let malformed = BatterySample(
            netW: 12.0,
            milliamps: 800,
            volts: 12.0,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 1_441)
        #expect(CardPresentation.batteryRemainingTimeText(malformed) == nil)
    }
~~~

- [ ] **Step 2: Run the focused presentation tests to verify they fail**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests
~~~

Expected: FAIL to compile because the labels and formatter functions do not exist.

- [ ] **Step 3: Add labels and formatters to the pure presentation module**

Insert immediately after batteryVoltageText(_:) in Wattly/Core/CardPresentation.swift:

~~~swift
    static let batteryRemainingCapacityLabel = "남은 용량"
    static let batteryRemainingTimeLabel = "남은 사용시간"

    static func batteryRemainingCapacityText(_ s: BatterySample) -> String? {
        guard let wh = s.remainingWh, wh.isFinite, wh >= 0 else { return nil }
        return "\(f1(wh)) Wh"
    }

    static func batteryRemainingTimeText(_ s: BatterySample) -> String? {
        guard let totalMinutes = s.timeRemainingMinutes,
              (1...1_440).contains(totalMinutes) else { return nil }
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }
~~~

- [ ] **Step 4: Render the optional rows in the shared expand region**

Replace batteryExpand(_:) in Wattly/Views/CardExpandRegion.swift:

~~~swift
    private func batteryExpand(_ s: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let value = CardPresentation.batteryRemainingCapacityText(s) {
                batteryDetailRow(label: CardPresentation.batteryRemainingCapacityLabel, value: value)
            }
            if let value = CardPresentation.batteryRemainingTimeText(s) {
                batteryDetailRow(label: CardPresentation.batteryRemainingTimeLabel, value: value)
            }
            batteryDetailRow(label: "전류", value: CardPresentation.batteryCurrentText(s))
            batteryDetailRow(label: "전압", value: CardPresentation.batteryVoltageText(s))
        }
        .padding(.top, 8)
    }
~~~

batteryDetailRow already makes each row a separate VoiceOver element with its label and formatted value, so no additional accessibility implementation is required.

- [ ] **Step 5: Run the focused tests to verify they pass**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests
~~~

Expected: PASS — the new test produces 49.5 Wh and 3h 30m only when telemetry is present.

- [ ] **Step 6: Run the full suite and verify on-device**

Run:

~~~bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
~~~

Expected: PASS — the complete WattlyTests suite succeeds.

Launch the Debug app on a MacBook, open the battery card, and verify:

- On battery, the expanded card shows 남은 용량 as one-decimal Wh and 남은 사용시간 as h m. Compare against AppleRawCurrentCapacity, Voltage, and TimeRemaining using:

~~~bash
ioreg -r -n AppleSmartBattery -w0 | rg 'AppleRawCurrentCapacity|TimeRemaining|"Voltage"'
~~~
- The laptop scenario intentionally uses the real BatteryProvider. Confirm the values are the current raw-registry conversion, and confirm the use-time row is absent whenever the live TimeRemaining estimate is unavailable or invalid.
- Plugging/unplugging retains capacity, preserves the existing sparkline reset, and hides time when TimeRemaining is unavailable or invalid.
- Layout B stays compact. In layout C, make battery the hero and expand it to verify the same two rows on the dark surface.

- [ ] **Step 7: Commit**

~~~bash
git add Wattly/Core/CardPresentation.swift Wattly/Views/CardExpandRegion.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(battery): show remaining capacity and use time"
~~~

## Self-Review

1. **Spec coverage:** Task 1 collects remaining capacity and time; Task 2 ensures they survive the display path; Task 3 renders labelled Wh and h m values in the battery card. The scope retains compact layout B while covering expandable layouts A and C.
2. **Placeholder scan:** No unfinished markers, deferred implementation, or unspecified validation is present. Every code-changing step includes concrete Swift and each test step names an exact command and expected outcome.
3. **Type consistency:** remainingWh: Double? and timeRemainingMinutes: Int? are introduced in Task 1, retained with those names in Task 2, and consumed by Task 3 formatters and view. Test names match the interfaces introduced in the plan.
