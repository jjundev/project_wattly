import Foundation

/// Pure memory derivations — no Mach/libproc calls, fully deterministic under
/// synthetic input (issue 18). The provider does the I/O and hands raw page
/// counts + the already-gathered process list here. Mirrors `CPUUsage.swift`.

private let bytesPerGiB = 1024.0 * 1024.0 * 1024.0

/// The kernel's own memory-pressure verdict (macOS "활성 상태 보기" 메모리 압력) — what
/// Activity Monitor colors the pressure graph by, NOT raw occupancy. Sourced from
/// `kern.memorystatus_vm_pressure_level`, whose values match `dispatch/source.h`'s
/// `DISPATCH_MEMORYPRESSURE_*` (NORMAL 0x01 / WARN 0x02 / CRITICAL 0x04).
enum MemoryPressure: Sendable, Equatable {
    case normal, warn, critical

    /// Map the raw sysctl int to a level. Defensive: 4→critical, 2→warn, anything else
    /// (1 = NORMAL, 0, or an unknown future value) → normal.
    init(fromSysctl raw: Int32) {
        switch raw {
        case 4: self = .critical
        case 2: self = .warn
        default: self = .normal
        }
    }

    /// Pressure → the shared color band the sparkline/bars resolve. Keeps `MemoryPressure`
    /// (a kernel fact) and `ThresholdLevel` (a presentation band) separate but trivially
    /// aligned, so the memory card can color by pressure without a special case in the view.
    var thresholdLevel: ThresholdLevel {
        switch self {
        case .normal: .normal
        case .warn: .warn
        case .critical: .crit
        }
    }
}

/// "Used" memory = (active + wired + compressed) pages × page size, in bytes
/// (plan 05 §In-2 — matches the `HOST_VM_INFO64` fields the provider reads).
func usedBytes(active: UInt64, wire: UInt64, compressor: UInt64, pageSize: UInt64) -> UInt64 {
    (active + wire + compressor) * pageSize
}

/// Assemble a `MemorySample` from raw page counts, the physical memory size, and
/// the gathered process list. GB are GiB (÷1024³) so a 16 GiB Mac reads "16"
/// (plan 05 §M5). The process list is reduced to the top-N here.
func memorySample(active: UInt64, wire: UInt64, compressor: UInt64,
                  pageSize: UInt64, memsize: UInt64,
                  processes: [ProcessUsage],
                  pressure: MemoryPressure? = nil,
                  swapUsedBytes: UInt64 = 0) -> MemorySample {
    MemorySample(
        usedGB: Double(usedBytes(active: active, wire: wire, compressor: compressor, pageSize: pageSize)) / bytesPerGiB,
        totalGB: Double(memsize) / bytesPerGiB,
        wiredGB: Double(wire * pageSize) / bytesPerGiB,
        compressedGB: Double(compressor * pageSize) / bytesPerGiB,
        swapUsedGB: Double(swapUsedBytes) / bytesPerGiB,
        processes: topProcesses(processes),
        pressure: pressure)
}

/// Top-N processes by physical footprint, descending (plan 05 §M8).
func topProcesses(_ all: [ProcessUsage], limit: Int = 3) -> [ProcessUsage] {
    Array(all.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(limit))
}

/// Bar width fraction (0…1) relative to the largest process, guarded against a
/// zero denominator (plan 05 §M19 — mirrors `CPUUsage` `pct`).
func barFraction(footprint: UInt64, maxBytes: UInt64) -> Double {
    maxBytes > 0 ? Double(footprint) / Double(maxBytes) : 0
}

/// Responsible app bundle for an executable path: the OUTERMOST `.app` component,
/// so a Chrome helper resolves to `Google Chrome.app` and `lldb-rpc-server` to
/// `Xcode.app` — without the private responsible-pid API. Falls back to the
/// executable path itself when there's no enclosing `.app` (a plain CLI tool →
/// generic icon), or nil for an empty path. The view feeds this to `NSWorkspace`.
func appBundlePath(forExecutable path: String) -> String? {
    guard !path.isEmpty else { return nil }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    if let idx = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
        return "/" + parts[1...idx].joined(separator: "/")
    }
    return path
}
