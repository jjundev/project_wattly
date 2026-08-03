# Use Nominal Voltage Constant for Battery Wh Calculation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change battery energy (Wh) calculations from using live instantaneous pack voltage to using a nominal voltage constant (11.55V) so displayed Wh matches official Apple hardware battery specs (72.4Wh) instead of displaying elevated/inflated Wh values (~80Wh).

**Architecture:** Update `remainingWattHours` in `Wattly/Core/BatteryPower.swift` to accept a `nominalVolts` parameter defaulting to `defaultNominalVolts` (11.55V, standard nominal voltage for Apple Silicon MacBook battery packs). Update `Wattly/Providers/BatteryProvider.swift` to use nominal voltage when constructing `BatterySample`, and update `WattlyTests/BatteryPowerTests.swift` to verify nominal-voltage Wh calculations.

**Tech Stack:** Swift, Swift Testing framework, macOS IOKit / SMC.

## Global Constraints

- Use standard nominal battery voltage constant `11.55V` (`defaultNominalVolts`).
- Preserve existing invalid input handling (`rawCapacityMilliampHours <= 0` or non-positive voltage returns `nil`).
- Maintain existing codebase conventions and formatting.

---

### Task 1: Update `remainingWattHours` and `BatteryProvider` to Use Nominal Voltage

**Files:**
- Modify: `Wattly/Core/BatteryPower.swift:51-56`
- Modify: `Wattly/Providers/BatteryProvider.swift:65-70,118-123`
- Modify: `WattlyTests/BatteryPowerTests.swift:97-105`

**Interfaces:**
- Consumes: `rawCapacityMilliampHours: Int`, `nominalVolts: Double`
- Produces: `func remainingWattHours(rawCapacityMilliampHours: Int, nominalVolts: Double = defaultNominalVolts) -> Double?`

- [ ] **Step 1: Write the failing unit tests for nominal voltage Wh calculation**

In `WattlyTests/BatteryPowerTests.swift`, update `remainingWattHoursUsesRawMilliampHoursAndPackVoltage` test to verify nominal voltage calculations and default parameter:

```swift
    // MARK: Remaining battery energy/time — AppleSmartBattery raw capacity + nominal voltage estimate

    @Test func remainingWattHoursUsesNominalVoltageDefault() {
        // 6,249 mAh (M5 MBP 14" design capacity) @ default nominal 11.55V = 72.17595 Wh (~72.2 Wh)
        let wh = remainingWattHours(rawCapacityMilliampHours: 6_249)
        #expect(abs(wh! - 72.17595) < 0.0001)
    }

    @Test func remainingWattHoursUsesExplicitNominalVoltage() {
        // 6,249 mAh @ 11.55V nominal voltage
        let wh = remainingWattHours(rawCapacityMilliampHours: 6_249, nominalVolts: 11.55)
        #expect(abs(wh! - 72.17595) < 0.0001)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BatteryPowerTests/remainingWattHours`
Expected: Test compilation failure because `remainingWattHours` still requires `volts: Double` without default.

- [ ] **Step 3: Update `BatteryPower.swift` and `BatteryProvider.swift`**

In `Wattly/Core/BatteryPower.swift`:
```swift
/// Standard nominal voltage constant for Apple Silicon MacBook battery packs (3S lithium-polymer ~11.55V).
public let defaultNominalVolts: Double = 11.55

/// Convert AppleSmartBattery raw capacity (mAh) at nominal pack voltage into Wh.
/// Uses standard nominal voltage (default 11.55V) so displayed Wh matches official hardware specifications.
/// Invalid registry inputs remain absent rather than becoming a misleading 0 Wh.
func remainingWattHours(rawCapacityMilliampHours: Int, nominalVolts: Double = defaultNominalVolts) -> Double? {
    guard rawCapacityMilliampHours > 0, nominalVolts.isFinite, nominalVolts > 0 else { return nil }
    return Double(rawCapacityMilliampHours) * nominalVolts / 1_000.0
}
```

In `Wattly/Providers/BatteryProvider.swift` (lines 65-70 and 118-123):
```swift
            remainingWh: remainingWattHours(
                rawCapacityMilliampHours: registry?.rawCurrentCapacityMilliampHours ?? 0),
            maxWh: remainingWattHours(
                rawCapacityMilliampHours: registry?.rawMaxCapacityMilliampHours ?? 0),
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: All tests PASS cleanly.

- [ ] **Step 5: Commit changes**

```bash
git add Wattly/Core/BatteryPower.swift Wattly/Providers/BatteryProvider.swift WattlyTests/BatteryPowerTests.swift docs/plans/2026-08-03-use-nominal-voltage-for-battery-wh-calculation.md
git commit -m "feat: use nominal voltage constant for battery Wh calculation"
```
