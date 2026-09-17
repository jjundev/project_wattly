import Foundation

/// Pure SoC-power derivation from IOReport "Energy Model" channels (issue 06).
/// No private API here — `PowerProvider` does the I/O and hands these functions a
/// decoded `[channelName: joules]` snapshot. Mirrors `CPUUsage`/`MemoryUsage`: all
/// the version-fragile, double-count-prone logic lives in one tested place.
///
/// On-device reality (M-series / macOS 26, grilled 2026-06-21): the group exposes
/// ~169 *hierarchical* channels — per-core `ECPU0..`/`PCPU0..` → cluster `ECPU`/
/// `PCPU` → roll-up `"CPU Energy"`, plus `_SRAM`/`*DTL*` sub-components. Summing all
/// of them double-counts ~4×. Units are mixed *within one sample* (`CPU Energy`=mJ,
/// `GPU Energy`=nJ, PCIe=µJ), so every value must be unit-decoded, not assumed mJ.

/// Engines that make up "Combined Power": CPU cores + GPU + ANE. `totalW` is exactly
/// their sum. CPU deliberately means the sum of per-core channels, matching the idle
/// scope reported by `powermetrics`; the broader `CPU Energy` roll-up is fallback-only.
enum PowerEngine: Equatable {
    case cpu, gpu, npu          // npu == Apple Neural Engine; HW channel is named "ANE"
}

/// Energy unit label → joules per unit. Unknown/absent units are rejected: silently
/// assuming mJ can turn an OS/channel change into a plausible-looking wrong value.
func unitScale(_ label: String?) -> Double? {
    switch label {
    case "J":         return 1
    case "mJ":        return 1e-3
    case "uJ", "µJ":  return 1e-6
    case "nJ":        return 1e-9
    case "pJ":        return 1e-12
    default:          return nil
    }
}

private func isDecimal(_ text: Substring) -> Bool {
    !text.isEmpty && text.allSatisfy(\.isNumber)
}

/// Exact per-core CPU energy patterns across known Apple-silicon channel families.
/// Cluster roll-ups, managers, SRAM and DTL channels intentionally do not match.
func isCPUCoreEnergyChannel(_ name: String) -> Bool {
    for prefix in ["ECPU", "PCPU"] where name.hasPrefix(prefix) {
        return isDecimal(name.dropFirst(prefix.count))
    }
    if name.hasPrefix("EACC_CPU") {
        return isDecimal(name.dropFirst("EACC_CPU".count))
    }
    if name.hasPrefix("MCPU") {
        let parts = name.dropFirst("MCPU".count).split(separator: "_", omittingEmptySubsequences: false)
        return (parts.count == 1 || parts.count == 2) && parts.allSatisfy(isDecimal)
    }
    guard name.hasPrefix("PACC") else { return false }
    let rest = name.dropFirst("PACC".count)
    if rest.first == "_" { return isDecimal(rest.dropFirst()) }             // PACC_0
    let parts = rest.split(separator: "_", omittingEmptySubsequences: false)
    return parts.count == 2 && isDecimal(parts[0]) && parts[1].hasPrefix("CPU")
        && isDecimal(parts[1].dropFirst(3))                                  // PACC0_CPU0
}

/// Channels whose presence/absence changes the engine calculation. A set change between
/// snapshots means a unit was dropped or the OS exposed a different topology, so the
/// provider re-baselines instead of interpreting a newly appearing absolute counter as a delta.
func powerEngineChannelNames(_ snapshot: [String: Double]) -> Set<String> {
    Set(snapshot.keys.filter { name in
        isCPUCoreEnergyChannel(name) || name == "CPU Energy" || classifyEngine(name) != nil
    })
}

func hasEngineChannelSetChanged(prev: [String: Double], curr: [String: Double]) -> Bool {
    powerEngineChannelNames(prev) != powerEngineChannelNames(curr)
}

/// Which engine a channel is broken out as, or nil for sub-components / channels
/// that count only toward the total. Exact names (the rolled-up aggregates) — never
/// the per-core/SRAM/DTL/cluster codes, which would double-count.
func classifyEngine(_ name: String) -> PowerEngine? {
    switch name {
    case "CPU Energy":                 return .cpu
    case "GPU Energy", "GPU":          return .gpu
    case "ANE", "ANE Energy", "ANE0":  return .npu   // HW channel "ANE" → surfaced as NPU
    default:                           return nil
    }
}

/// Any monotonic energy counter going backwards ⇒ counter reset / rollover (sleep,
/// wake, very long uptime). `PowerProvider` re-baselines instead of emitting a bogus
/// spike or a clamped zero.
func hasCounterReset(prev: [String: Double], curr: [String: Double]) -> Bool {
    for (name, c) in curr {
        if let p = prev[name], c < p { return true }
    }
    return false
}

/// Per-engine overrides for the macOS 27 stale-Energy-Model path: `PowerProvider` derives CPU
/// from the PMP histograms and ANE from the refresh-interval average, and hands them in here so
/// the `totalW == cpuW + gpuW + npuW` invariant is kept in ONE place. nil = use the Energy Model
/// delta for that engine (macOS ≤ 26 behaviour).
struct PowerOverrides: Sendable, Equatable {
    var cpuW: Double? = nil
    var npuW: Double? = nil
}

private func energyDeltaJ(_ name: String, prev: [String: Double], curr: [String: Double]) -> Double {
    max(0, (curr[name] ?? 0) - (prev[name] ?? 0))
}

/// Joules the recognised CPU cores accrued between two snapshots — exact per-core channels,
/// or the `CPU Energy` roll-up only when no core channel exists (same selection `powerSample`
/// uses). Doubles as the macOS 27 staleness signal: a live Energy Model never yields 0 here.
func cpuCoreEnergyDeltaJ(prev: [String: Double], curr: [String: Double]) -> Double {
    let coreChannels = curr.keys.filter(isCPUCoreEnergyChannel)
    let cpuChannels = coreChannels.isEmpty
        ? (curr["CPU Energy"] != nil ? ["CPU Energy"] : [])
        : Array(coreChannels)
    return cpuChannels.reduce(0.0) { $0 + energyDeltaJ($1, prev: prev, curr: curr) }
}

/// True when the snapshot carries any CPU energy counter `cpuCoreEnergyDeltaJ` can watch (a
/// per-core channel, or the `CPU Energy` roll-up). Without one a zero delta means "nothing to
/// measure", not "stale".
func hasCPUEnergyChannel(_ snapshot: [String: Double]) -> Bool {
    snapshot.keys.contains(where: isCPUCoreEnergyChannel) || snapshot["CPU Energy"] != nil
}

/// Joules the ANE channel(s) accrued between two snapshots (floored at 0 like every delta).
func aneEnergyDeltaJ(prev: [String: Double], curr: [String: Double]) -> Double {
    curr.keys.reduce(0.0) { acc, name in
        classifyEngine(name) == .npu ? acc + energyDeltaJ(name, prev: prev, curr: curr) : acc
    }
}

/// Watts from two absolute-energy snapshots (joules) and the elapsed seconds.
/// CPU prefers exact per-core channels; `CPU Energy` is a compatibility fallback when
/// a chip exposes no recognized cores. `GPU`/`GPU Energy` are the same quantity, so one
/// is counted. DRAM/DCS/SoC fabric/PCIe and hierarchical CPU sub-components are excluded.
/// `overrides` replace the CPU/ANE watts (macOS 27 stale path); the total is always the sum
/// of the three engine figures actually emitted.
func powerSample(prev: [String: Double], curr: [String: Double], dt: Double,
                 overrides: PowerOverrides = PowerOverrides()) -> PowerSample {
    func watts(_ j: Double) -> Double { dt > 0 ? j / dt : 0 }

    // Single GPU channel — prefer the precise "GPU Energy", fall back to "GPU".
    let gpuChannel = curr["GPU Energy"] != nil ? "GPU Energy" : (curr["GPU"] != nil ? "GPU" : nil)
    let gpuJ = gpuChannel.map { energyDeltaJ($0, prev: prev, curr: curr) } ?? 0

    let cpuW = overrides.cpuW ?? watts(cpuCoreEnergyDeltaJ(prev: prev, curr: curr))
    let npuW = overrides.npuW ?? watts(aneEnergyDeltaJ(prev: prev, curr: curr))
    let gpuW = watts(gpuJ)

    // Combined Power — per-core CPU + GPU + ANE; the headline is exactly the breakout's sum.
    return PowerSample(totalW: cpuW + gpuW + npuW, cpuW: cpuW, gpuW: gpuW, npuW: npuW)
}
