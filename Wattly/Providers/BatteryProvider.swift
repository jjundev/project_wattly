import Foundation
import IOKit

/// Real battery provider (issue 07) — no entitlements, laptop-only.
///
/// Primary source is the **SMC** (`SMCConnection`), which exposes live (~1 s) power sensors:
/// `B0AP` = net battery power mW (signed, negative = discharging), `B0AV`/`B0AC` = mV/mA,
/// `PDTR` = adapter power W (>0 ⇒ on AC). This is what HWiNFO/iStat read; verified on
/// Mac17,2 to update every poll, unlike AppleSmartBattery's ~10–20 s plateaus.
///
/// Falls back to AppleSmartBattery's `PowerTelemetryData.BatteryPower` (documented but coarse)
/// when the SMC or its battery keys are unavailable — that path also covers desktops (no
/// battery service → `.notPresent`, hides the card). All decoding/arithmetic is in pure
/// `BatteryPower`/`smcDouble`.
///
/// `actor` is required: `read` is awaited from the `@MainActor` `SystemMonitor`, so the
/// synchronous IOKit/SMC calls must run off the actor's executor to stay off the main thread.
actor BatteryProvider: MetricProvider {
    let kind: ProviderKind = .battery

    /// Matches `FakeProvider`'s desktop copy and the `desktopBatteryIsHidden` test.
    static let notPresentMessage = "배터리 없음 — 데스크톱 Mac"

    /// One-shot lazy SMC open (like `PowerProvider`'s subscription). A nil after the attempt
    /// just means we use the AppleSmartBattery fallback — we don't re-open every poll.
    private var smcAttempted = false
    private var smc: SMCConnection?

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        if !smcAttempted { smcAttempted = true; smc = SMCConnection() }
        if let sample = smcSample() { return .value(.battery(sample)) }
        return appleSmartBatteryReading()
    }

    /// Live SMC path. nil if the SMC or its battery keys are absent (desktop / unsupported
    /// model) → the caller falls back to AppleSmartBattery.
    private func smcSample() -> BatterySample? {
        guard let smc,
              let power = smc.read("B0AP"),
              let voltage = smc.read("B0AV") else { return nil }
        let milliwatts = Int(smcDouble(power.bytes, type: power.type).rounded())   // mW, signed
        let volts = smcDouble(voltage.bytes, type: voltage.type) / 1000.0
        let netW = netWatts(batteryMilliwatts: milliwatts)
        let mA = smc.read("B0AC").map { Int(smcDouble($0.bytes, type: $0.type).rounded()) }
            ?? batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)
        let adapterW = smc.read("PDTR").map { smcDouble($0.bytes, type: $0.type) } ?? 0
        return BatterySample(netW: netW, milliamps: abs(mA), volts: volts,
                             charging: isCharging(netW: netW), externalConnected: adapterW > 0.5)
    }

    /// Fallback: AppleSmartBattery `PowerTelemetryData.BatteryPower` (mW, signed) — coarse but
    /// documented, and the desktop path (no service → `.notPresent`).
    private func appleSmartBatteryReading() -> ProviderReading {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .unavailable(.notPresent(Self.notPresentMessage)) }
        defer { IOObjectRelease(service) }
        guard let mv = number(service, "Voltage")?.int64Value else { return .pending }
        let volts = Double(mv) / 1000.0
        let externalConnected = bool(service, "ExternalConnected") ?? false
        let milliwatts: Int
        if let telemetry = dict(service, "PowerTelemetryData"),
           let raw = (telemetry["BatteryPower"] as? NSNumber)?.uint64Value {
            milliwatts = twosComplement(raw)
        } else if let rawAmp = number(service, "InstantAmperage")?.uint64Value {
            milliwatts = Int((Double(twosComplement(rawAmp)) * volts).rounded())   // mA × V = mW
        } else {
            return .pending
        }
        // BatteryPower/InstantAmperage signs are unreliable here (observed flipping while
        // discharging) — resolve direction from ExternalConnected, keep only the magnitude.
        let netW = fallbackNetWatts(batteryMilliwatts: milliwatts, externalConnected: externalConnected)
        return .value(.battery(BatterySample(
            netW: netW, milliamps: abs(batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)),
            volts: volts, charging: isCharging(netW: netW), externalConnected: externalConnected)))
    }

    private func number(_ service: io_service_t, _ key: String) -> NSNumber? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
    }
    private func bool(_ service: io_service_t, _ key: String) -> Bool? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }
    private func dict(_ service: io_service_t, _ key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
    }
}
