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
}
