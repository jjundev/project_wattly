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
}
