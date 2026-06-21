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

/// Engines broken out in the card sub-line. (Total includes more — see `isTotalChannel`.)
enum PowerEngine: Equatable {
    case cpu, gpu, npu          // npu == Apple Neural Engine; HW channel is named "ANE"
}

/// Energy unit label → joules per unit. Unknown/absent → mJ (the dominant case).
/// A wrong scale is an order-of-magnitude error that `PowerProvider`'s sanity
/// ceiling catches at runtime; this keeps the common cases exact.
func unitScale(_ label: String?) -> Double {
    switch label {
    case "J":         return 1
    case "mJ":        return 1e-3
    case "uJ", "µJ":  return 1e-6
    case "nJ":        return 1e-9
    case "pJ":        return 1e-12
    default:          return 1e-3   // unknown → assume mJ
    }
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

/// Whether a channel contributes to `totalW`. The curated aggregates plus a generic
/// sweep of any `"… Energy"` channel (PCIe ports, apciec), which catches per-board
/// variance without hardcoding port counts. Per-core/SRAM/DTL/cluster sub-channels
/// have none of these names, so they are excluded — no double counting. (보류 #26:
/// validated on M-series/macOS 26; unrecognized engines on other chips undercount
/// *visibly*, never double-count.)
func isTotalChannel(_ name: String) -> Bool {
    let aggregates: Set<String> = ["CPU Energy", "GPU Energy", "GPU", "ANE", "DRAM", "DCS", "SOC_AON"]
    return aggregates.contains(name) || name.hasSuffix(" Energy")
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

/// Watts from two absolute-energy snapshots (joules) and the elapsed seconds.
/// Per-engine breakout via `classifyEngine`; `GPU`/`GPU Energy` are the *same*
/// quantity (coarse mJ vs precise nJ) so exactly one is counted. `totalW` sums every
/// `isTotalChannel`, GPU once — so it is honestly larger than CPU+GPU+NPU (it folds
/// in DRAM/DCS/SoC). Assumes a normal interval; negative deltas are floored at 0 as
/// defence (anomalies are caught upstream).
func powerSample(prev: [String: Double], curr: [String: Double], dt: Double) -> PowerSample {
    func deltaJ(_ name: String) -> Double { max(0, (curr[name] ?? 0) - (prev[name] ?? 0)) }
    func watts(_ j: Double) -> Double { dt > 0 ? j / dt : 0 }

    // Single GPU channel — prefer the precise "GPU Energy", fall back to "GPU".
    let gpuChannel = curr["GPU Energy"] != nil ? "GPU Energy" : (curr["GPU"] != nil ? "GPU" : nil)

    var cpuJ = 0.0, npuJ = 0.0
    for name in curr.keys {
        switch classifyEngine(name) {
        case .cpu: cpuJ += deltaJ(name)
        case .npu: npuJ += deltaJ(name)
        case .gpu, .none: break          // GPU handled via gpuChannel (dedup); .none = sub-component
        }
    }
    let gpuJ = gpuChannel.map(deltaJ) ?? 0

    var totalJ = gpuJ                     // GPU counted exactly once
    for name in curr.keys where isTotalChannel(name) {
        if name == "GPU" || name == "GPU Energy" { continue }
        totalJ += deltaJ(name)
    }

    return PowerSample(totalW: watts(totalJ), cpuW: watts(cpuJ), gpuW: watts(gpuJ), npuW: watts(npuJ))
}
