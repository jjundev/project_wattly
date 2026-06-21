import Foundation

/// Raw per-core CPU tick counters from `PROCESSOR_CPU_LOAD_INFO`. Cumulative
/// since boot; usage is the delta between two snapshots. Kept as a plain value
/// type so the pure derivation below has no dependency on Mach.
struct CoreTicks: Sendable, Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// One runtime performance level (sysctl `hw.perflevelN.*`). Never hardcoded —
/// names and core counts come from the host at runtime (plan §2).
struct PerfLevel: Sendable, Equatable {
    var name: String    // runtime name, e.g. "Performance", "Efficiency"
    var coreCount: Int  // hw.perflevelN.physicalcpu
}

/// Pure CPU-usage derivation: diff two tick snapshots, group cores by perf level.
/// No Mach calls — fully deterministic under synthetic input (issue 18). The
/// provider does the Mach I/O and hands the raw ticks here.
///
/// Assumes core index → perf level is contiguous (cumulative `coreCount`
/// partitions the array — plan assumption #A). If the topology doesn't add up to
/// the sampled core count, it falls back to a single flat group "C0…Cn" rather
/// than mislabel cores.
func cpuUsage(prev: [CoreTicks], curr: [CoreTicks], topology: [PerfLevel]) -> CPUSample {
    let n = min(prev.count, curr.count)
    guard n > 0 else { return CPUSample(overall: 0, perfLevels: []) }

    // Per-core busy/total deltas. Wrapping subtraction (`&-`) survives the rare
    // UInt32 counter wrap; a 0-delta (identical snapshot) yields total == 0.
    var busy = [Double](repeating: 0, count: n)
    var total = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let p = prev[i], c = curr[i]
        let b = Double(c.user &- p.user) + Double(c.system &- p.system) + Double(c.nice &- p.nice)
        busy[i] = b
        total[i] = b + Double(c.idle &- p.idle)
    }

    func pct(_ b: Double, _ t: Double) -> Double { t > 0 ? min(100, max(0, b / t * 100)) : 0 }
    func groupUsage(_ range: Range<Int>) -> Double {
        var b = 0.0, t = 0.0
        for i in range { b += busy[i]; t += total[i] }
        return pct(b, t)
    }

    let overall = groupUsage(0..<n)

    // Partition cores by perf level (contiguous). Fall back to one flat group if
    // the runtime topology can't be trusted to map cleanly onto the core array.
    let topoSum = topology.reduce(0) { $0 + $1.coreCount }
    let usable = !topology.isEmpty && topology.allSatisfy { $0.coreCount > 0 } && topoSum == n

    var levels: [PerfLevelUsage] = []
    if usable {
        var start = 0
        for level in topology {
            let range = start..<(start + level.coreCount)
            levels.append(PerfLevelUsage(
                name: level.name,
                usage: groupUsage(range),
                cores: range.map { pct(busy[$0], total[$0]) }))
            start += level.coreCount
        }
    } else {
        levels.append(PerfLevelUsage(
            name: "C",
            usage: overall,
            cores: (0..<n).map { pct(busy[$0], total[$0]) }))
    }

    return CPUSample(overall: overall, perfLevels: levels)
}
