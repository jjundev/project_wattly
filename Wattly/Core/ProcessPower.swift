import Foundation

/// Pure per-APP power ranking (per-app power Top-N, issue 16 follow-up). Electron/Chromium
/// apps (Claude, Codex, Chrome) fragment work across many helper pids — "Helper (Renderer)",
/// "Helper (GPU)", … — so per-PID ranking buries the real consumer (a single big renderer
/// can outrank an app whose draw is spread evenly across helpers). We coalesce per-pid
/// energy deltas by their resolved app bundle (`appBundlePath`), summing helpers into the
/// owning `.app`. The provider supplies absolute per-pid energy snapshots (nanojoules, from
/// `proc_pid_rusage(pid, RUSAGE_INFO_V6).ri_energy_nj`) + a pid→app-key map; these turn them
/// into watts, group, and rank — no I/O. Mirrors `PowerEnergy`/`MemoryUsage`.
///
/// Free functions (like `barFraction`/`appBundlePath`) so they don't collide with the
/// `ProcessPower` row model in `MetricSample`.

/// Per-pid average watts over the interval, for pids present in BOTH snapshots with a
/// positive delta (new/dead/idle pids and counter resets are skipped). dt ≤ 0 or > `maxDt`
/// (missed poll / sleep-wake) → empty.
func processWatts(prev: [Int32: UInt64], curr: [Int32: UInt64],
                  dt: Double, maxDt: Double = 30) -> [(pid: Int32, watts: Double)] {
    guard dt > 0, dt <= maxDt else { return [] }
    var out: [(pid: Int32, watts: Double)] = []
    out.reserveCapacity(curr.count)
    for (pid, c) in curr {
        guard let p = prev[pid], c >= p else { continue }   // new/dead pid or counter reset
        let watts = Double(c - p) / 1e9 / dt
        if watts > 0 { out.append((pid: pid, watts: watts)) }
    }
    return out
}

/// Coalesce per-pid watts into the top-`limit` apps by summed watts, keyed by `appKey`
/// (a `.app` bundle path, or a per-pid fallback for non-app processes). Stable order:
/// watts desc, then key asc, so equal-watt groups don't jitter between polls.
func topAppPower(perPidWatts: [(pid: Int32, watts: Double)],
                 appKey: [Int32: String], limit: Int) -> [(key: String, watts: Double)] {
    var sums: [String: Double] = [:]
    for (pid, watts) in perPidWatts {
        sums[appKey[pid] ?? "PID \(pid)", default: 0] += watts
    }
    return sums.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        .prefix(max(0, limit))
        .map { (key: $0.key, watts: $0.value) }
}

/// Display name for an app group key: the `.app` basename minus ".app" (e.g.
/// "/Applications/Claude.app" → "Claude"), else the path basename (a CLI), else the key.
func appDisplayName(forKey key: String) -> String {
    let last = key.split(separator: "/").last.map(String.init) ?? key
    return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
}

/// Bar width 0..1 for a power row, relative to the top app's watts (flat/zero guard).
func wattFraction(watts: Double, maxWatts: Double) -> Double {
    guard maxWatts > 0 else { return 0 }
    return min(1, max(0, watts / maxWatts))
}
