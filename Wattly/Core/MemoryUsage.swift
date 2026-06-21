import Foundation

/// Pure memory derivations — no Mach/libproc calls, fully deterministic under
/// synthetic input (issue 18). The provider does the I/O and hands raw page
/// counts + the already-gathered process list here. Mirrors `CPUUsage.swift`.

private let bytesPerGiB = 1024.0 * 1024.0 * 1024.0

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
                  processes: [ProcessUsage]) -> MemorySample {
    MemorySample(
        usedGB: Double(usedBytes(active: active, wire: wire, compressor: compressor, pageSize: pageSize)) / bytesPerGiB,
        totalGB: Double(memsize) / bytesPerGiB,
        wiredGB: Double(wire * pageSize) / bytesPerGiB,
        compressedGB: Double(compressor * pageSize) / bytesPerGiB,
        processes: topProcesses(processes))
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
