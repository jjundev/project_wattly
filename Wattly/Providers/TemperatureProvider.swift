import Foundation
import IOKit

/// What the temperature provider reads through — the **single read-only seam** under
/// which the real SMC / AppleSmartBattery I/O lives (plan 08 §1). The provider knows
/// only this protocol, so the whole connection / backoff / partial-failure machine is
/// tested by injecting a fake transport (no hardware), and the `io_connect_t` / CF
/// objects never leave the live implementation.
protocol TemperatureTransport: Sendable {
    /// Open the SMC connection. `false` ⇒ `connectionFailed` (retryable → backoff).
    func open() -> Bool
    /// Read + `flt `-decode one SMC key to °C; nil if absent / unreadable / not `flt `
    /// (unknown data types are rejected, never int-fallback-misdecoded — plan 08 §3).
    func readCelsius(_ key: String) -> Double?
    /// AppleSmartBattery temperature (independent of the SMC — never blocked by an SMC
    /// failure, and never blocks it; plan 08 §6/§9).
    func batteryTemperature() -> BatterySource
    /// Release the SMC connection (on terminal / disable / stale-after-wake).
    func close()
}

/// Battery-temperature outcome from the transport. `.notPresent` is the desktop / no-battery
/// path (→ card hidden); `.unreadable` is a present-but-failed read (retryable).
enum BatterySource: Sendable, Equatable {
    case centiCelsius(Int)
    case notPresent
    case unreadable
}

/// Real temperature provider (issue 08) — no entitlements.
///
/// CPU/GPU come from the **SMC** (`Tp*`/`Te*` = CPU die, `Tg*` = GPU die, all `flt `),
/// but ONLY on a chip with an on-device-verified `TemperatureProfile` (plan 08 Phase 0);
/// any other chip is `noVerifiedProfile` (terminal, zero I/O). Battery temperature comes
/// from AppleSmartBattery's `Temperature` key (centi-°C), independent of the SMC, and is
/// `notPresent` on a desktop. All arithmetic / profile / backoff logic is in pure
/// `Temperature`; this actor only orchestrates I/O and the connection lifecycle.
///
/// `actor` is required: `read` is awaited from the `@MainActor` `SystemMonitor`, so the
/// synchronous IOKit/SMC calls run off the actor's executor, off the main thread (like
/// `BatteryProvider`/`PowerProvider`).
actor TemperatureProvider: MetricProvider, TemperatureGating {
    let kind: ProviderKind = .temperature

    /// Matches `FakeProvider`/`BatteryProvider`'s desktop copy.
    static let batteryNotPresentMessage = "배터리 없음 — 데스크톱 Mac"
    /// Battery plausibility band (°C) — its own, separate from the SMC profile's range.
    private static let batteryRange = 0.0...80.0
    /// Elapsed beyond this ⇒ a gap (missed poll / sleep-wake; `ContinuousClock` advances
    /// through sleep) → reset backoff and force a fresh SMC connection (mirrors
    /// `PowerProvider.maxPlausibleDt`).
    private static let maxPlausibleDt = 30.0

    private let transport: any TemperatureTransport
    private let model: String

    private var profile: TemperatureProfile?
    private var profileResolved = false
    private var enabled = true

    private var smcOpen = false
    private var consecutiveFailures = 0
    private var retryAt: ContinuousClock.Instant?
    private var lastInstant: ContinuousClock.Instant?

    init(transport: any TemperatureTransport = SMCTemperatureTransport(),
         model: String = currentHardwareModel()) {
        self.transport = transport
        self.model = model
    }

    // MARK: Gating hook (issue 08 owns this; issue 09 decides when to call it)

    /// Enable/disable the SMC CPU/GPU read path. Issue 09 calls `false` when both the
    /// CPU- and GPU-temperature cards are hidden (no sensor I/O for hidden cards), and
    /// `true` to re-enable — which resets the backoff/connection so it reconnects at once.
    /// Battery temperature is unaffected (cheap, separate source).
    func setEnabled(_ on: Bool) {
        if on && !enabled { resetConnection() }   // re-enable → fresh start
        enabled = on
        if !on { transport.close(); smcOpen = false }   // disable → drop the handle, zero I/O
    }

    // MARK: Poll

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        // Sleep/wake or a long gap → the io_connect_t may be stale: reset and reconnect.
        if let last = lastInstant, Self.seconds(from: last, to: instant) > Self.maxPlausibleDt {
            resetConnection()
        }
        defer { lastInstant = instant }

        if !profileResolved {
            profile = TemperatureProfiles.profile(forModel: model)
            profileResolved = true
        }

        // Battery temp is independent — read it regardless of SMC/enabled state.
        let battery = batteryReading()
        let (cpu, gpu) = cpuGpuReadings(at: instant)
        return .value(.temperature(TemperatureSnapshot(cpu: cpu, gpu: gpu, battery: battery)))
    }

    // MARK: CPU/GPU (SMC, with connection lifecycle)

    private func cpuGpuReadings(at instant: ContinuousClock.Instant)
        -> (cpu: CategoryReading, gpu: CategoryReading) {
        guard let profile else {
            return (.unavailable(.noVerifiedProfile), .unavailable(.noVerifiedProfile))   // terminal, no I/O
        }
        guard enabled else {
            return (.unavailable(.connectionFailed), .unavailable(.connectionFailed))      // gated off (issue 09), no I/O
        }

        if !smcOpen {
            if let retryAt, instant < retryAt {
                return (.unavailable(.connectionFailed), .unavailable(.connectionFailed))  // in backoff window, no I/O
            }
            if transport.open() {
                smcOpen = true
                consecutiveFailures = 0
                retryAt = nil
            } else {
                registerFailure(at: instant)
                return (.unavailable(.connectionFailed), .unavailable(.connectionFailed))
            }
        }

        let cpu = categoryReading(profile.cpuGroups, range: profile.validRange)
        let gpu = categoryReading(profile.gpuGroups, range: profile.validRange)
        if !cpu.anyReadable && !gpu.anyReadable {
            // Not one key readable ⇒ the connection went stale → invalidate + back off.
            transport.close(); smcOpen = false
            registerFailure(at: instant)
            return (.unavailable(.connectionFailed), .unavailable(.connectionFailed))
        }
        return (cpu.reading, gpu.reading)
    }

    /// Build a category reading from its clusters: read each cluster's keys, summarise it
    /// (average + hottest), and set the headline to the **average across all** the
    /// category's in-range sensors (issue 08 follow-up; was the single max). `anyReadable`
    /// is false only when not one key returned a value (⇒ stale connection, caller backs off).
    private func categoryReading(_ keyGroups: [TemperatureKeyGroup], range: ClosedRange<Double>)
        -> (reading: CategoryReading, anyReadable: Bool) {
        var groups: [TemperatureGroup] = []
        var all: [Double] = []
        var anyReadable = false
        for kg in keyGroups {
            let vals = kg.keys.compactMap { transport.readCelsius($0) }
            if !vals.isEmpty { anyReadable = true }
            all.append(contentsOf: vals)
            if let avg = averageCelsius(vals, in: range), let hot = hottestCelsius(vals, in: range) {
                groups.append(TemperatureGroup(name: kg.name, average: avg, hottest: hot))
            }
        }
        guard let headline = averageCelsius(all, in: range) else {
            return (.unavailable(.readFailed), anyReadable)
        }
        return (.reading(TemperatureReading(celsius: headline, groups: groups)), anyReadable)
    }

    /// Count a connection failure and arm the next reconnect (immediate once, then the
    /// 1·2·4·8·16·30 s ladder — `reconnectBackoffSeconds`).
    private func registerFailure(at instant: ContinuousClock.Instant) {
        consecutiveFailures += 1
        let wait = reconnectBackoffSeconds(consecutiveFailures: consecutiveFailures)
        retryAt = instant.advanced(by: .seconds(wait))
    }

    private func resetConnection() {
        consecutiveFailures = 0
        retryAt = nil
        if smcOpen { transport.close(); smcOpen = false }
    }

    // MARK: Battery temp (independent source)

    private func batteryReading() -> CategoryReading {
        switch transport.batteryTemperature() {
        case .notPresent:
            return .notPresent(Self.batteryNotPresentMessage)
        case .unreadable:
            return .unavailable(.readFailed)
        case .centiCelsius(let raw):
            if let c = batteryCelsius(rawCentiCelsius: raw, in: Self.batteryRange) {
                return .reading(TemperatureReading(celsius: c))
            }
            return .unavailable(.readFailed)
        }
    }

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}

/// A provider whose (expensive) sensor I/O can be gated off when its cards are hidden
/// (plan 08 §10). 08 supplies the hook; 09 decides when to call it. Parallel to
/// `ProcessEnumerating` for the memory provider.
protocol TemperatureGating: MetricProvider {
    func setEnabled(_ enabled: Bool) async
}

// MARK: - Live transport

/// Live `TemperatureTransport`: SMC (`SMCConnection`) for CPU/GPU `flt ` keys +
/// AppleSmartBattery for battery temp. Only ever touched inside `TemperatureProvider`'s
/// actor isolation, so `@unchecked Sendable` (same basis as `SMCConnection`).
final class SMCTemperatureTransport: TemperatureTransport, @unchecked Sendable {
    private var smc: SMCConnection?

    func open() -> Bool {
        if smc != nil { return true }
        smc = SMCConnection()
        return smc != nil
    }

    func readCelsius(_ key: String) -> Double? {
        guard let smc, let r = smc.read(key), r.type.hasPrefix("flt") else { return nil }
        let c = smcDouble(r.bytes, type: r.type)
        return c.isFinite ? c : nil
    }

    func batteryTemperature() -> BatterySource {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .notPresent }
        defer { IOObjectRelease(service) }
        guard let n = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return .unreadable }
        return .centiCelsius(n.intValue)
    }

    func close() { smc = nil }   // SMCConnection.deinit closes the io_connect_t
}

#if DEBUG
/// DEBUG re-verification probe (plan 08 Phase 0). Run headless to dump live temps from
/// the REAL provider + live transport, then exit — for re-checking the M5 profile after
/// an OS update without the GUI:
///   `Wattly.app/Contents/MacOS/Wattly -WattlyThermalProbe`
/// Excluded from Release. Detached so it runs off the (blocked) main thread.
enum ThermalProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("-WattlyThermalProbe") else { return }
        let provider = TemperatureProvider()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            print("[thermal-probe] model=\(currentHardwareModel())")
            let clock = ContinuousClock()
            for i in 0..<3 {
                let reading = await provider.read(at: clock.now)
                print("[thermal-probe] sample \(i): \(describe(reading))")
                try? await Task.sleep(for: .seconds(1))
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func describe(_ r: ProviderReading) -> String {
        guard case .value(.temperature(let s)) = r else { return "non-temperature: \(r)" }
        func d(_ c: CategoryReading) -> String {
            switch c {
            case .reading(let x):
                let groups = x.groups
                    .map { "\($0.name) \(String(format: "%.1f", $0.average))°(최고 \(String(format: "%.1f", $0.hottest))°)" }
                    .joined(separator: ", ")
                return String(format: "평균 %.2f°C", x.celsius) + (groups.isEmpty ? "" : " [\(groups)]")
            case .unavailable(let e): return "unavailable(\(e))"
            case .notPresent(let m): return "notPresent(\(m))"
            }
        }
        return "CPU \(d(s.cpu)) · GPU \(d(s.gpu)) · battery \(d(s.battery))"
    }
}
#endif
