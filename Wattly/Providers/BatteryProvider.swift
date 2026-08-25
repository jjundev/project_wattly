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

    private struct AppleSmartBatterySnapshot {
        var volts: Double?
        var externalConnected: Bool
        var batteryMilliwatts: Int?
        var rawCurrentCapacityMilliampHours: Int?
        var timeRemainingMinutes: Int?
        var rawMaxCapacityMilliampHours: Int?
        var designCapacityMilliampHours: Int?
        var cycleCount: Int?
        var temperatureCelsius: Double?
        var systemPowerInWatts: Double? = nil
        var systemLoadWatts: Double? = nil
    }

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        let registry = appleSmartBatterySnapshot()
        if !smcAttempted { smcAttempted = true; smc = SMCConnection() }
        if let sample = smcSample(registry: registry) { return .value(.battery(sample)) }
        return appleSmartBatteryReading(registry: registry)
    }

    /// Live SMC path. nil if the SMC or its battery keys are absent (desktop / unsupported
    /// model) → the caller falls back to AppleSmartBattery.
    private func smcSample(registry: AppleSmartBatterySnapshot?) -> BatterySample? {
        guard let smc,
              let power = smc.read("B0AP"),
              let voltage = smc.read("B0AV") else { return nil }
        let milliwatts = Int(smcDouble(power.bytes, type: power.type).rounded())
        let volts = smcDouble(voltage.bytes, type: voltage.type) / 1000.0
        let netW = netWatts(batteryMilliwatts: milliwatts)
        let mA = smc.read("B0AC").map { Int(smcDouble($0.bytes, type: $0.type).rounded()) }
            ?? batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)
        let adapterW = smc.read("PDTR").map { smcDouble($0.bytes, type: $0.type) } ?? registry?.systemPowerInWatts ?? 0.0
        let measuredSystemW = smc.read("PSTR").map { smcDouble($0.bytes, type: $0.type) } ?? registry?.systemLoadWatts
        let externalConnected = adapterW > 0.5 || (registry?.externalConnected == true)

        let systemWatts = calculateSystemWatts(
            adapterWatts: adapterW,
            batteryNetWatts: netW,
            measuredSystemWatts: measuredSystemW
        )
        let scenario = resolvePowerFlowScenario(
            externalConnected: externalConnected,
            adapterWatts: adapterW,
            batteryNetWatts: netW,
            isChargeInhibited: false
        )
        let powerFlow = PowerFlowSnapshot(
            scenario: scenario,
            adapterWatts: adapterW,
            systemWatts: systemWatts,
            batteryNetWatts: netW
        )

        return BatterySample(
            netW: netW,
            milliamps: abs(mA),
            volts: volts,
            charging: isCharging(netW: netW),
            externalConnected: externalConnected,
            remainingWh: remainingWattHours(
                rawCapacityMilliampHours: registry?.rawCurrentCapacityMilliampHours ?? 0),
            maxWh: remainingWattHours(
                rawCapacityMilliampHours: registry?.rawMaxCapacityMilliampHours ?? 0),
            timeRemainingMinutes: validatedTimeRemainingMinutes(registry?.timeRemainingMinutes),
            efficiencyPercent: batteryEfficiencyPercent(
                maxCapacityMilliampHours: registry?.rawMaxCapacityMilliampHours ?? 0,
                designCapacityMilliampHours: registry?.designCapacityMilliampHours ?? 0),
            cycleCount: validatedBatteryCycleCount(registry?.cycleCount),
            temperatureCelsius: registry?.temperatureCelsius,
            powerFlow: powerFlow)
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

        let tempCenti = number(service, "Temperature")?.intValue
        let tempC = tempCenti.flatMap { batteryCelsius(rawCentiCelsius: $0, in: 0.0...80.0) }

        var systemPowerInW: Double? = nil
        var systemLoadW: Double? = nil
        if let telemetry = dict(service, "PowerTelemetryData") {
            if let pin = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue {
                systemPowerInW = pin / 1000.0
            }
            if let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue {
                systemLoadW = load / 1000.0
            }
        }

        return AppleSmartBatterySnapshot(
            volts: volts,
            externalConnected: externalConnected,
            batteryMilliwatts: batteryMilliwatts,
            rawCurrentCapacityMilliampHours: number(service, "AppleRawCurrentCapacity")?.intValue,
            timeRemainingMinutes: number(service, "TimeRemaining")?.intValue ?? number(service, "AvgTimeToFull")?.intValue ?? number(service, "TimeToFull")?.intValue,
            rawMaxCapacityMilliampHours: number(service, "AppleRawMaxCapacity")?.intValue,
            designCapacityMilliampHours: number(service, "DesignCapacity")?.intValue,
            cycleCount: number(service, "CycleCount")?.intValue,
            temperatureCelsius: tempC,
            systemPowerInWatts: systemPowerInW,
            systemLoadWatts: systemLoadW)
    }

    /// Fallback: AppleSmartBattery `PowerTelemetryData.BatteryPower` (mW, signed) — coarse but
    /// documented, and the desktop path (no service → `.notPresent`).
    private func appleSmartBatteryReading(registry: AppleSmartBatterySnapshot?) -> ProviderReading {
        guard let registry else { return .unavailable(.notPresent(Self.notPresentMessage)) }
        guard let volts = registry.volts, let milliwatts = registry.batteryMilliwatts else { return .pending }
        // BatteryPower/InstantAmperage signs are unreliable here (observed flipping while
        // discharging) — resolve direction from ExternalConnected, keep only the magnitude.
        let netW = fallbackNetWatts(
            batteryMilliwatts: milliwatts,
            externalConnected: registry.externalConnected)

        let adapterW = registry.systemPowerInWatts ?? 0.0
        let systemWatts = calculateSystemWatts(
            adapterWatts: adapterW,
            batteryNetWatts: netW,
            measuredSystemWatts: registry.systemLoadWatts
        )
        let scenario = resolvePowerFlowScenario(
            externalConnected: registry.externalConnected,
            adapterWatts: adapterW,
            batteryNetWatts: netW,
            isChargeInhibited: false
        )
        let powerFlow = PowerFlowSnapshot(
            scenario: scenario,
            adapterWatts: adapterW,
            systemWatts: systemWatts,
            batteryNetWatts: netW
        )

        return .value(.battery(BatterySample(
            netW: netW, milliamps: abs(batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)),
            volts: volts, charging: isCharging(netW: netW), externalConnected: registry.externalConnected,
            remainingWh: remainingWattHours(
                rawCapacityMilliampHours: registry.rawCurrentCapacityMilliampHours ?? 0),
            maxWh: remainingWattHours(
                rawCapacityMilliampHours: registry.rawMaxCapacityMilliampHours ?? 0),
            timeRemainingMinutes: validatedTimeRemainingMinutes(registry.timeRemainingMinutes),
            efficiencyPercent: batteryEfficiencyPercent(
                maxCapacityMilliampHours: registry.rawMaxCapacityMilliampHours ?? 0,
                designCapacityMilliampHours: registry.designCapacityMilliampHours ?? 0),
            cycleCount: validatedBatteryCycleCount(registry.cycleCount),
            temperatureCelsius: registry.temperatureCelsius,
            powerFlow: powerFlow)))
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
