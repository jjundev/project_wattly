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

/// Coalesce per-pid watts into the top-`limit` apps by summed watts, keyed by
/// `AppIdentity.key` (the app's bundle id when readable, else its path, else a per-pid
/// fallback). Stable order: watts desc, then key asc, so equal-watt groups don't jitter
/// between polls. The group carries its largest member's identity, so the row gets the app's
/// real name and icon path.
func topAppPower(perPidWatts: [(pid: Int32, watts: Double)],
                 identity: [Int32: AppIdentity],
                 limit: Int) -> [(identity: AppIdentity, watts: Double)] {
    var sums: [String: Double] = [:]
    var representative: [String: AppIdentity] = [:]
    // Biggest member first, so the representative is deterministic (tie → pid asc).
    for (pid, watts) in perPidWatts.sorted(by: {
        $0.watts != $1.watts ? $0.watts > $1.watts : $0.pid < $1.pid
    }) {
        let member = identity[pid] ?? AppIdentity(key: "PID \(pid)", name: "PID \(pid)", iconPath: nil)
        sums[member.key, default: 0] += watts
        if representative[member.key] == nil { representative[member.key] = member }
    }
    return sums.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        .prefix(max(0, limit))
        .map { key, watts in
            (identity: representative[key]
                ?? AppIdentity(key: key, name: appDisplayName(forKey: key), iconPath: nil),
             watts: watts)
        }
}

/// Clamp the persisted processor-power expanded-list size to the supported 3...7 range.
/// The provider applies this at the pure ranking seam so malformed defaults cannot bypass the
/// Settings control's options.
func powerProcessLimit(_ persisted: Int?) -> Int {
    min(7, max(3, persisted ?? Defaults.powerProcessLimit))
}

/// Bar width 0..1 for a power row, relative to the top app's watts (flat/zero guard).
func wattFraction(watts: Double, maxWatts: Double) -> Double {
    guard maxWatts > 0 else { return 0 }
    return min(1, max(0, watts / maxWatts))
}
