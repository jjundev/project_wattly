import Foundation

/// Pure per-cluster active-clock derivation for the CPU card (plan 21). No IOKit/IOReport
/// here — the provider does the I/O and hands raw bytes / residency counters in. Fully
/// deterministic under synthetic input.
enum CPUFrequency {
    /// Decode a `voltage-statesN-sram` property blob into per-state GHz.
    /// Layout: 8-byte entries `(freqRaw: UInt32 LE, microvolts: UInt32 LE)`, `GHz = freqRaw / 1e6`
    /// (verified M5: states5-sram → 1.31…4.61 GHz, states1-sram → 0.97…3.05 GHz).
    /// EVERY entry is kept (including zero-freq / repeated padding) so table index i stays
    /// aligned 1:1 with residency bin i+1 — filtering here would desync the two.
    static func decodeDVFSTable(_ data: Data) -> [Double] {
        let n = data.count / 8
        var out: [Double] = []
        out.reserveCapacity(n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let f = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self)
                out.append(Double(f) / 1_000_000.0)
            }
        }
        return out
    }

    /// Frequency-weighted active clock (GHz) from two cumulative DVFS residency snapshots.
    /// Bin 0 is the idle/off bin and is skipped; bin i (i≥1) is dwell in the DVFS state whose
    /// frequency is `tableGHz[i-1]`. Returns nil when no active dwell accrued this interval
    /// (fully idle, counter reset, or a length mismatch) so the caller shows no clock, not 0.
    static func activeGHz(tableGHz: [Double], prev: [UInt64], curr: [UInt64]) -> Double? {
        guard prev.count == curr.count, curr.count >= 2 else { return nil }
        let active = min(curr.count - 1, tableGHz.count)
        var weighted = 0.0, total = 0.0
        for i in 0..<active {
            let bin = i + 1
            if curr[bin] < prev[bin] { return nil }        // cumulative counter reset → drop interval
            let d = Double(curr[bin] - prev[bin])
            weighted += d * tableGHz[i]
            total += d
        }
        return total > 0 ? weighted / total : nil
    }

    /// Attach per-cluster clocks onto a freshly derived `CPUSample`, aligned by perf-level
    /// order (`clockGHz[i]` → `perfLevels[i]`). Pure so the order-mapping is unit-tested
    /// without touching IOReport. Extra/short `clockGHz` is tolerated (zip to the shorter).
    static func attaching(_ sample: CPUSample, clockGHz: [Double?]) -> CPUSample {
        var s = sample
        for i in s.perfLevels.indices where i < clockGHz.count {
            s.perfLevels[i].activeGHz = clockGHz[i]
        }
        return s
    }
}
