import Foundation

/// Development scenarios. These exist ONLY behind a launch argument — the
/// prototype's CONTROL STRIP is a demo harness, not an app feature (plan README
/// line 13). Real providers replace these in issues 04–08.
enum Scenario: String, Sendable {
    case laptop, desktop, cold, fail

    /// Selected via `-WattlyScenario <name>` (scheme arg / `defaults`). Defaults
    /// to `.laptop`. Production cold-start is "until the first real sample",
    /// interval-dependent — not the fake 1.7 s below.
    static func fromLaunchArguments() -> Scenario {
        if let raw = UserDefaults.standard.string(forKey: "WattlyScenario"),
           let s = Scenario(rawValue: raw) {
            return s
        }
        return .laptop
    }
}

/// Synthetic time-series provider modelled on the prototype's `basesFor`/`tick`
/// (lines 488–547). One actor per `ProviderKind`; each holds its own series and
/// advances on every poll. Randomness is fine here — this is the dev harness.
actor FakeProvider: MetricProvider {
    let kind: ProviderKind
    private let scenario: Scenario
    private var cur: [String: Double] = [:]
    private var coldStart: ContinuousClock.Instant?

    init(kind: ProviderKind, scenario: Scenario) {
        self.kind = kind
        self.scenario = scenario
    }

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        // Cold: stay pending for 1.7 s, then warm up (prototype line 521).
        if scenario == .cold {
            if coldStart == nil { coldStart = instant }
            if coldStart!.duration(to: instant) < .milliseconds(1700) { return .pending }
        }
        // Fail: only the power channel is unreadable (prototype lines 631, 684).
        if scenario == .fail, kind == .power {
            return .unavailable(.channelUnreadable(
                "Energy Model 그룹을 읽을 수 없음 — 이 macOS에서 채널이 바뀌었을 수 있습니다."))
        }
        // Desktop: no battery (prototype hides battery + battery temperature).
        if scenario == .desktop, kind == .battery {
            return .unavailable(.notPresent("배터리 없음 — 데스크톱 Mac"))
        }
        advance()
        return .value(makeSample())
    }

    private var effectiveScenario: Scenario { scenario == .cold ? .laptop : scenario }

    private func advance() {
        for (key, cfg) in Self.bases(kind: kind, scenario: effectiveScenario) {
            let prev = cur[key] ?? cfg.b
            let next = min(cfg.max, max(cfg.min, prev + Double.random(in: -0.5...0.5) * cfg.step))
            cur[key] = next
        }
    }

    private func v(_ key: String) -> Double { cur[key] ?? 0 }

    /// Synthetic per-core values jittered around a level average (dev harness only).
    private static func spread(_ avg: Double, count: Int) -> [Double] {
        (0..<count).map { _ in min(100, max(0, avg + Double.random(in: -12...12))) }
    }

    private func makeSample() -> MetricSample {
        switch kind {
        case .power:
            let p = v("power")
            // SoC engine split mirrors the prototype (line 588).
            return .power(PowerSample(totalW: p, cpuW: p * 0.37, gpuW: p * 0.24, npuW: p * 0.03 + 0.05))
        case .battery:
            let net = v("batteryW")
            let mag = abs(net)
            let charging = net < -0.2
            return .battery(BatterySample(
                netW: net,
                milliamps: Int((mag / 12.0 * 1000).rounded()),
                volts: 12.0,
                charging: charging,
                externalConnected: charging))   // synthetic dev harness — AC iff charging
        case .cpu:
            let c = v("cpu")
            // Real M-series names (issue 04): drives the same prefix logic ("P"/"E")
            // the live provider uses. Per-core values spread around each level avg.
            let pAvg = min(99, c * 1.25)
            let eAvg = c * 0.5
            return .cpu(CPUSample(overall: c, perfLevels: [
                PerfLevelUsage(name: "Performance", usage: pAvg, cores: Self.spread(pAvg, count: 4),
                               activeGHz: 1.6 + pAvg / 100 * 2.6),
                PerfLevelUsage(name: "Efficiency", usage: eAvg, cores: Self.spread(eAvg, count: 6),
                               activeGHz: 0.9 + eAvg / 100 * 1.5),
            ]))
        case .memory:
            let total = effectiveScenario == .desktop ? 64.0 : 16.0
            // Synthetic top-3 (prototype Chrome/Xcode/Figma, line 611) so any
            // fake-driven / test path still demos the expand. Unused at runtime —
            // the app routes .memory to the real MemoryProvider (issue 05 §M21).
            let used = v("mem")
            let gib = 1024.0 * 1024.0 * 1024.0
            let procs = [
                ProcessUsage(pid: 1, name: "Chrome", footprintBytes: UInt64(used * 0.30 * gib)),
                ProcessUsage(pid: 2, name: "Xcode", footprintBytes: UInt64(used * 0.21 * gib)),
                ProcessUsage(pid: 3, name: "Figma", footprintBytes: UInt64(used * 0.13 * gib)),
            ]
            // Synthesise pressure from the occupancy ratio so the fake/dev harness still
            // demos the pressure-colored card (the real sysctl drives it at runtime).
            let frac = total > 0 ? used / total : 0
            let pressure: MemoryPressure = frac > 0.85 ? .critical : (frac > 0.70 ? .warn : .normal)
            // Synthetic swap so the dev harness demos the "스왑" sub-line segment: none when
            // roomy, a little under pressure, more when critical (the real sysctl drives it at runtime).
            let swap = frac > 0.85 ? 5.0 : (frac > 0.70 ? 1.5 : 0.0)
            return .memory(MemorySample(usedGB: used, totalGB: total, wiredGB: 2.4, compressedGB: 1.1,
                                        swapUsedGB: swap, processes: procs, pressure: pressure))
        case .temperature:
            // Synthetic cluster groups so the expand demo works (P-코어 a touch hotter
            // than the E-코어; headline ≈ their blend, mirroring the real average).
            let c = v("cpuTemp")
            let cpu = CategoryReading.reading(TemperatureReading(celsius: c, groups: [
                TemperatureGroup(name: "P-코어", average: c + 4, hottest: c + 8),
                TemperatureGroup(name: "E-코어", average: c - 4, hottest: c - 1),
            ]))
            let g = v("gpuTemp")
            let gpu = CategoryReading.reading(TemperatureReading(celsius: g, groups: [
                TemperatureGroup(name: "GPU", average: g, hottest: g + 5),
            ]))
            let bat: CategoryReading = effectiveScenario == .desktop
                ? .notPresent("배터리 없음 — 데스크톱 Mac")
                : .reading(TemperatureReading(celsius: v("batTemp")))
            return .temperature(TemperatureSnapshot(cpu: cpu, gpu: gpu, battery: bat))
        case .fan:
            let base = 2200.0
            return .fan(FanSample(fans: [
                FanReading(index: 0, actualRPM: v("fan"), minRPM: 1200, maxRPM: 6000, targetRPM: base),
            ]))
        }
    }

    // Base values transcribed from the prototype (lines 489–500).
    private struct Base { let b, step, min, max: Double }

    private static func bases(kind: ProviderKind, scenario: Scenario) -> [String: Base] {
        let desktop = scenario == .desktop
        switch kind {
        case .power:
            return ["power": desktop ? Base(b: 14.7, step: 2.2, min: 6, max: 42)
                                     : Base(b: 8.4, step: 1.6, min: 3, max: 22)]
        case .cpu:
            return ["cpu": desktop ? Base(b: 28, step: 9, min: 5, max: 99)
                                   : Base(b: 42, step: 10, min: 6, max: 99)]
        case .memory:
            return ["mem": desktop ? Base(b: 22.4, step: 0.8, min: 14, max: 60)
                                   : Base(b: 9.2, step: 0.5, min: 6, max: 15.6)]
        case .battery:
            return desktop ? [:] : ["batteryW": Base(b: 6, step: 1.2, min: -10, max: 20)]
        case .temperature:
            var t: [String: Base] = [
                "cpuTemp": desktop ? Base(b: 51, step: 2.4, min: 40, max: 92)
                                   : Base(b: 54.3, step: 2.5, min: 42, max: 94),
                "gpuTemp": desktop ? Base(b: 57, step: 2.2, min: 40, max: 88)
                                   : Base(b: 48.1, step: 2, min: 38, max: 86),
            ]
            if !desktop { t["batTemp"] = Base(b: 31, step: 0.7, min: 22, max: 46) }
            return t
        case .fan:
            return ["fan": Base(b: 2400, step: 180, min: 1200, max: 6000)]
        }
    }
}

/// Builds the providers the app runs on: the real `CPUProvider` (issue 04),
/// `MemoryProvider` (issue 05), `PowerProvider` (issue 06), `BatteryProvider`
/// (issue 07), and `TemperatureProvider` (issue 08) plus fakes for the not-yet-implemented
/// metrics. The dev `-WattlyScenario` harness only shapes the fakes; the real providers
/// ignore it (so `-WattlyScenario desktop` shows real RAM, not the fake 64 GB — §M21).
/// Fault/shape-injection paths keep their fake: `fail` keeps the fake power provider so the
/// orange "channel unreadable" card stays demoable on a working Mac (issue 06 §R4), and
/// `desktop` keeps the fake battery AND fake temperature so the "no battery / no battery
/// temp" hide stays demoable on a laptop (a real desktop hides them anyway via the real
/// providers' `.notPresent`).
enum FakeProviders {
    static func all(scenario: Scenario) -> [any MetricProvider] {
        ProviderKind.allCases.map { kind -> any MetricProvider in
            switch kind {
            case .cpu:    return CPUProvider()
            case .memory: return MemoryProvider()
            case .power where scenario != .fail: return PowerProvider()
            case .battery where scenario != .desktop: return BatteryProvider()
            case .temperature where scenario != .desktop: return TemperatureProvider()
            default:      return FakeProvider(kind: kind, scenario: scenario)
            }
        }
    }
}
