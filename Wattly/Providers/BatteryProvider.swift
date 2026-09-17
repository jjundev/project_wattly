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
    static let notPresentMessage = String(localized: "배터리 없음 — 데스크톱 Mac")

    /// One-shot lazy SMC open (like `PowerProvider`'s subscription). A nil after the attempt
    /// just means we use the AppleSmartBattery fallback — we don't re-open every poll.
    private var smcAttempted = false
    private var smc: SMCConnection?

    private struct AppleSmartBatterySnapshot {
        var volts: Double?
        var externalConnected: Bool
        var batteryMilliwatts: Int?
        var timeRemainingMinutes: Int?
        /// 레지스트리에서 읽은 용량·사이클·온도(macOS 26 이하 최상위 키 → 27의 `BatteryData`).
        /// SMC 폴백과의 병합은 `smcSample`이 한다.
        var facts: BatteryFacts
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
              let voltage = smc.read("B0AV"),
              let milliwatts = smcInt(power.bytes, type: power.type) else { return nil }
        let volts = smcDouble(voltage.bytes, type: voltage.type) / 1000.0
        let netW = netWatts(batteryMilliwatts: milliwatts)
        let mA = smc.read("B0AC").flatMap { smcInt($0.bytes, type: $0.type) }
            ?? batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)
        let adapterW = smc.read("PDTR").map { smcDouble($0.bytes, type: $0.type) } ?? registry?.systemPowerInWatts ?? 0.0
        let measuredSystemW = smc.read("PSTR").map { smcDouble($0.bytes, type: $0.type) } ?? registry?.systemLoadWatts
        let externalConnected = adapterW > 0.5 || (registry?.externalConnected == true)
        // 레지스트리가 이기고 SMC가 빈칸을 채운다 — macOS 26 이하는 오늘과 같은 값, 27은
        // 사라진 최상위 키를 B0RM/B0NC/B0DC/B0CT/B0AT가 메운다(스펙 §3-2).
        let facts = BatteryFactsSource.merged(
            primary: registry?.facts ?? BatteryFacts(),
            fallback: BatteryFactsSource.fromSMC(read: smc.read))

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
                rawCapacityMilliampHours: facts.remainingMilliampHours ?? 0),
            maxWh: remainingWattHours(
                rawCapacityMilliampHours: facts.maxMilliampHours ?? 0),
            timeRemainingMinutes: validatedTimeRemainingMinutes(registry?.timeRemainingMinutes),
            efficiencyPercent: batteryEfficiencyPercent(
                maxCapacityMilliampHours: facts.maxMilliampHours ?? 0,
                designCapacityMilliampHours: facts.designMilliampHours ?? 0),
            cycleCount: validatedBatteryCycleCount(facts.cycleCount),
            temperatureCelsius: facts.temperatureCelsius,
            powerFlow: powerFlow)
    }

    private func appleSmartBatterySnapshot() -> AppleSmartBatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let volts = number(service, "Voltage").map { Double($0.int64Value) / 1000.0 }
        let rawExternalConnected = bool(service, "ExternalConnected") ?? false
        let adapterWatts = (dict(service, "AdapterDetails")?["Watts"] as? NSNumber)?.intValue ?? 0
        let externalConnected = rawExternalConnected || adapterWatts > 0
        let batteryMilliwatts: Int?
        if let telemetry = dict(service, "PowerTelemetryData"),
           let raw = (telemetry["BatteryPower"] as? NSNumber)?.uint64Value {
            batteryMilliwatts = twosComplement(raw)
        } else if let rawAmp = number(service, "InstantAmperage")?.uint64Value, let volts {
            batteryMilliwatts = Int((Double(twosComplement(rawAmp)) * volts).rounded())
        } else {
            batteryMilliwatts = nil
        }

        // macOS 26 이하 최상위 키(있는 것만 담는다) + macOS 27 `BatteryData` 서브딕셔너리.
        var topLevel: [String: Int] = [:]
        for key in ["AppleRawCurrentCapacity", "AppleRawMaxCapacity", "DesignCapacity", "CycleCount", "Temperature"] {
            if let value = number(service, key)?.intValue { topLevel[key] = value }
        }
        let facts = BatteryFactsSource.fromRegistry(topLevel: topLevel, batteryData: dict(service, "BatteryData"))

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
            timeRemainingMinutes: number(service, "TimeRemaining")?.intValue ?? number(service, "AvgTimeToFull")?.intValue ?? number(service, "TimeToFull")?.intValue,
            facts: facts,
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
                rawCapacityMilliampHours: registry.facts.remainingMilliampHours ?? 0),
            maxWh: remainingWattHours(
                rawCapacityMilliampHours: registry.facts.maxMilliampHours ?? 0),
            timeRemainingMinutes: validatedTimeRemainingMinutes(registry.timeRemainingMinutes),
            efficiencyPercent: batteryEfficiencyPercent(
                maxCapacityMilliampHours: registry.facts.maxMilliampHours ?? 0,
                designCapacityMilliampHours: registry.facts.designMilliampHours ?? 0),
            cycleCount: validatedBatteryCycleCount(registry.facts.cycleCount),
            temperatureCelsius: registry.facts.temperatureCelsius,
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

#if DEBUG
/// DEBUG 실기 프로브. 실제 `BatteryProvider`(SMC 우선 + 레지스트리)로 3회 읽어 출력하고 종료한다.
/// OS 업데이트 뒤 배터리 사실(효율·Wh·온도·사이클)이 살아 있는지 GUI 없이 확인하는 용도:
///   `Wattly.app/Contents/MacOS/Wattly -WattlyBatteryProbe`
/// Release에서는 제외. 막힌 메인 스레드 밖에서 돌도록 detached.
enum BatteryProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("-WattlyBatteryProbe") else { return }
        let provider = BatteryProvider()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let clock = ContinuousClock()
            for i in 0..<3 {
                let reading = await provider.read(at: clock.now)
                print("[battery-probe] sample \(i): \(describe(reading))")
                try? await Task.sleep(for: .seconds(1))
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func describe(_ r: ProviderReading) -> String {
        guard case .value(.battery(let s)) = r else { return "non-battery: \(r)" }
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "nil" }
        return "net \(f(s.netW)) W · \(s.milliamps) mA · \(f(s.volts)) V · charging=\(s.charging) ext=\(s.externalConnected)"
            + " · remaining \(f(s.remainingWh)) Wh / max \(f(s.maxWh)) Wh · pct \(s.percentage.map(String.init) ?? "nil")"
            + " · efficiency \(f(s.efficiencyPercent)) % · cycles \(s.cycleCount.map(String.init) ?? "nil")"
            + " · temp \(f(s.temperatureCelsius)) °C · timeRemaining \(s.timeRemainingMinutes.map(String.init) ?? "nil") min"
    }
}
#endif
