import Foundation

/// Pure battery-power helpers (issue 07). `BatteryProvider` reads the IOKit fields and
/// hands these the decoded values; no IOKit here, so the version-fragile math is tested
/// in one place (mirrors `PowerEnergy`/`CPUUsage`).
///
/// On-device reality (Mac17,2 / macOS 26, 2026-06-21): AppleSmartBattery's
/// `PowerTelemetryData.BatteryPower` is a *directly-measured* net battery power (mW,
/// signed, negative = discharging) that tracks a plug/unplug within ~2 s. The gas-gauge
/// `InstantAmperage` lags 30–60 s and even glitches to the wrong sign on AC, so it is only
/// a fallback. Verified: `SystemPowerIn − SystemLoad = BatteryPower` (power balance), e.g.
/// 5842 − 15768 = −9926 mW while plugged into an under-powered adapter (battery still
/// discharging 9.9 W).

/// Decode a 64-bit two's-complement counter that IOKit returns as a large unsigned when
/// the sign bit is set (`BatteryPower` mW, `InstantAmperage` mA). Pure + total.
func twosComplement(_ raw: UInt64) -> Int {
    raw > UInt64(Int64.max) ? Int(Int64(bitPattern: raw)) : Int(raw)
}

/// Net system power in watts from the signed battery power (mW). AppleSmartBattery reports
/// negative = discharging; we flip to the app convention `> 0 discharging, < 0 charging`.
func netWatts(batteryMilliwatts mw: Int) -> Double {
    -Double(mw) / 1000.0
}

/// Net watts for the **AppleSmartBattery fallback only**, where the signed source is
/// unreliable: `BatteryPower` was observed flipping sign while discharging (and
/// `InstantAmperage` reads the wrong sign on AC). When on battery
/// (`externalConnected == false`) charging is physically impossible, so we keep only the
/// magnitude and force the discharge direction (`netW > 0`); on AC we trust the field's
/// sign as a best effort. The SMC primary path is sign-reliable and does NOT use this —
/// it calls `netWatts` directly.
func fallbackNetWatts(batteryMilliwatts mw: Int, externalConnected: Bool) -> Double {
    let net = netWatts(batteryMilliwatts: mw)
    return externalConnected ? net : abs(net)
}

/// Charging iff net is meaningfully negative (> 0.2 W into the battery). The dead-zone
/// keeps an idle/full battery on AC from flickering. Now lag-free because `netW` comes
/// from the fast `BatteryPower` (the old `InstantAmperage`-derived sign lagged, issue 07).
func isCharging(netW: Double) -> Bool { netW < -0.2 }

/// Effective battery current magnitude proxy (mA) from power/voltage, so the W and mA in
/// the sub-line stay consistent — raw `InstantAmperage` is unreliable on AC (it read
/// +1780 mA while the battery actually discharged 9.9 W). Sign-carrying; the view abs's it.
func batteryMilliamps(batteryMilliwatts mw: Int, volts: Double) -> Int {
    volts > 0 ? Int((Double(mw) / volts).rounded()) : 0
}

/// Decode an SMC value's raw bytes to a Double in its native unit (issue 07 live path).
/// `flt ` is a 32-bit little-endian IEEE float (e.g. `PSTR`/`PPBR` watts); `si*`/`ui*` are
/// little-endian integers (the SMC returns these LE on Apple silicon — verified: `B0AV`
/// bytes `b6 30` → 12470 mV, `B0AP` `7f b6 ff ff` → −18817 mW). `si*` is sign-extended.
func smcDouble(_ bytes: [UInt8], type: String) -> Double {
    if type == "flt ", bytes.count >= 4 {
        return Double(Array(bytes.prefix(4)).withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
    }
    var v: UInt64 = 0
    for (i, b) in bytes.enumerated() where i < 8 { v |= UInt64(b) << (8 * i) }   // little-endian
    let bits = min(bytes.count, 8) * 8
    if type.hasPrefix("si"), bits > 0, bits < 64, v & (UInt64(1) << (bits - 1)) != 0 {
        return Double(Int64(bitPattern: v | (~UInt64(0) << bits)))               // sign-extend
    }
    return Double(v)
}
