import Foundation

/// Shared, no-entitlement process-enumeration primitives over `libproc` (own-user pids
/// only — system / other-user pids are simply skipped). Used by both the memory Top-3
/// (`MemoryProvider`, issue 05) and the per-app power Top-3 (`PowerProvider`, issue 16
/// follow-up): each provider reads its own per-pid metric (footprint vs energy); these
/// cover the pid list + identity (name/path), so the two providers don't duplicate it.
/// Free functions, like `appBundlePath`/`barFraction` — no shared mutable state.

/// Two-pass `proc_listpids` into a caller-allocated Swift array (no Mach free).
func listPIDs() -> [pid_t] {
    let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard needed > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride)
    let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, needed)
    guard written > 0 else { return [] }
    return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.stride))
}

/// Full executable path via `proc_pidpath` ("" if unreadable). Used for both the name
/// fallback and the icon (`appBundlePath`), so callers fetch it once.
func pidPath(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE = 4*MAXPATHLEN
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
}

/// `proc_name` → executable basename (from `path`) → "PID n".
func procName(of pid: pid_t, path: String) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    if proc_name(pid, &buf, UInt32(buf.count)) > 0 {
        let s = String(cString: buf)
        if !s.isEmpty { return s }
    }
    if let last = path.split(separator: "/").last, !last.isEmpty { return String(last) }
    return "PID \(pid)"
}
