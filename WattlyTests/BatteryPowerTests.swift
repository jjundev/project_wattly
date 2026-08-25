import Testing
@testable import Wattly

/// Deterministic battery-power math (issue 07, spec 07-power-battery.md). The IOKit I/O in
/// `BatteryProvider` is verified on-device, not here.
struct BatteryPowerTests {

    // MARK: twosComplement — IOKit returns a 64-bit signed counter as a large unsigned

    @Test func twosComplementNegative() {
        #expect(twosComplement(18446744073709550678) == -938)    // historic InstantAmperage vector
        #expect(twosComplement(18446744073709541690) == -9926)   // BatteryPower mW (discharge)
    }

    @Test func twosComplementZeroAndPositive() {
        #expect(twosComplement(0) == 0)
        #expect(twosComplement(15191) == 15191)                  // BatteryPower mW (charging)
    }

    @Test func twosComplementBoundaries() {
        #expect(twosComplement(UInt64(Int64.max)) == Int(Int64.max))
        #expect(twosComplement(UInt64(Int64.max) + 1) == Int(Int64.min))   // 2^63 → most negative
    }

    // MARK: netWatts — BatteryPower mW (neg = discharge) → app convention (>0 discharge)

    @Test func netWattsDischargeIsPositive() {
        #expect(netWatts(batteryMilliwatts: -9926) == 9.926)     // discharging → +
    }

    @Test func netWattsChargeIsNegative() {
        #expect(netWatts(batteryMilliwatts: 15191) == -15.191)   // charging → −
    }

    @Test func netWattsZero() {
        #expect(netWatts(batteryMilliwatts: 0) == 0)
    }

    // MARK: fallbackNetWatts — AppleSmartBattery sign is unreliable; pin direction by ExternalConnected

    @Test func fallbackOnBatteryForcesDischarge() {
        // On battery, charging is impossible → discharge (netW > 0) regardless of the
        // field's (flipping) sign. Both signed inputs map to the same +magnitude.
        #expect(fallbackNetWatts(batteryMilliwatts: -20680, externalConnected: false) == 20.68)
        #expect(fallbackNetWatts(batteryMilliwatts: 29428, externalConnected: false) == 29.428) // spurious + sign corrected
    }

    @Test func fallbackOnACTrustsSign() {
        // On AC the direction is genuinely ambiguous, so the (best-effort) field sign stands.
        #expect(fallbackNetWatts(batteryMilliwatts: 15191, externalConnected: true) == -15.191)  // charging
        #expect(fallbackNetWatts(batteryMilliwatts: -9926, externalConnected: true) == 9.926)    // discharging on weak adapter
    }

    @Test func fallbackOnBatteryNeverReadsAsCharging() {
        // The whole point: a discharging battery must never show 충전 중 via the fallback.
        let net = fallbackNetWatts(batteryMilliwatts: 29428, externalConnected: false)
        #expect(isCharging(netW: net) == false)
    }

    // MARK: isCharging — net < −0.2 dead-zone, now on the fast BatteryPower-derived net

    @Test func isChargingThreshold() {
        #expect(isCharging(netW: -0.2) == false)   // boundary: not charging
        #expect(isCharging(netW: -0.21) == true)
        #expect(isCharging(netW: 9.9) == false)    // discharging (even while plugged into a weak adapter)
        #expect(isCharging(netW: -15.2) == true)
    }

    // MARK: batteryMilliamps — effective current from power/voltage (W & mA stay consistent)

    @Test func batteryMilliampsFromPower() {
        #expect(batteryMilliamps(batteryMilliwatts: -9926, volts: 12.165) == -816)
        #expect(batteryMilliamps(batteryMilliwatts: 0, volts: 12.0) == 0)
        #expect(batteryMilliamps(batteryMilliwatts: 100, volts: 0) == 0)   // div-by-zero guard
    }

    // MARK: smcDouble — decode SMC raw bytes (little-endian; flt / si / ui), live path

    @Test func smcDecodesFloatWatts() {
        // PSTR (system power) raw bytes, little-endian IEEE float → 18.8177 W.
        #expect(abs(smcDouble([0x95, 0x8a, 0x96, 0x41], type: "flt ") - 18.818) < 0.01)
    }

    @Test func smcDecodesSignedLittleEndian() {
        #expect(smcDouble([0x7f, 0xb6, 0xff, 0xff], type: "si32") == -18817)   // B0AP mW (discharge)
        #expect(smcDouble([0x1b, 0xfa], type: "si16") == -1509)                // B0AC mA (discharge)
    }

    @Test func smcDecodesUnsignedLittleEndian() {
        #expect(smcDouble([0xb6, 0x30], type: "ui16") == 12470)                // B0AV mV
    }

    @Test func smcSignedPositiveStaysPositive() {
        #expect(smcDouble([0x88, 0x13], type: "si16") == 5000)                 // +5000 (charging current)
    }

    // MARK: Remaining battery energy/time — AppleSmartBattery raw capacity + estimate

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

    @Test func remainingWattHoursRejectsInvalidCapacityOrVoltage() {
        #expect(remainingWattHours(rawCapacityMilliampHours: 0, nominalVolts: 11.55) == nil)
        #expect(remainingWattHours(rawCapacityMilliampHours: -1, nominalVolts: 11.55) == nil)
        #expect(remainingWattHours(rawCapacityMilliampHours: 4_128, nominalVolts: 0) == nil)
        #expect(remainingWattHours(rawCapacityMilliampHours: 4_128, nominalVolts: .infinity) == nil)
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

    @Test func estimatedTimeToFullCalculatesMinutesWhenCharging() {
        // 30 Wh remaining out of 60 Wh max, charging at netW = -20.0 W -> needed 30 Wh / 20 W = 1.5 h = 90 min
        #expect(estimatedTimeToFullMinutes(remainingWh: 30.0, maxWh: 60.0, netW: -20.0) == 90)
        // Discharging (netW > 0) -> nil
        #expect(estimatedTimeToFullMinutes(remainingWh: 30.0, maxWh: 60.0, netW: 15.0) == nil)
        // Fully charged or invalid inputs -> nil
        #expect(estimatedTimeToFullMinutes(remainingWh: 60.0, maxWh: 60.0, netW: -10.0) == nil)
        #expect(estimatedTimeToFullMinutes(remainingWh: nil, maxWh: 60.0, netW: -10.0) == nil)
    }

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

    @Test func batterySampleAttachesPowerFlowSnapshot() {
        let netW = -32.4
        let adapterW = 48.5
        let systemW = 16.1
        let scenario = resolvePowerFlowScenario(
            externalConnected: true,
            adapterWatts: adapterW,
            batteryNetWatts: netW,
            isChargeInhibited: false
        )
        let snapshot = PowerFlowSnapshot(
            scenario: scenario,
            adapterWatts: adapterW,
            systemWatts: systemW,
            batteryNetWatts: netW
        )
        let sample = BatterySample(
            netW: netW,
            milliamps: 2612,
            volts: 12.4,
            charging: true,
            externalConnected: true,
            powerFlow: snapshot
        )
        #expect(sample.powerFlow != nil)
        #expect(sample.powerFlow?.scenario == .charging)
        #expect(sample.powerFlow?.adapterWatts == 48.5)
        #expect(sample.powerFlow?.systemWatts == 16.1)
        #expect(sample.powerFlow?.batteryNetWatts == -32.4)
    }
}

