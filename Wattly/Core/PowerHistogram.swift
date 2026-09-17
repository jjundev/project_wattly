import Foundation

/// Pure math for the IOReport `PMP` / `Energy` state histograms (macOS 27 processor-power
/// migration). On macOS 27 the `Energy Model` mJ counters refresh only every 3–5 min, so
/// `PowerProvider` derives CPU watts from these per-cluster power histograms instead. No
/// private API here — `IOReportPMPEnergySubscription` does the I/O and hands these functions
/// cumulative residency bins.
///
/// On-device reality (M5 / macOS 27.0, probed 2026-09-17): channels `EACC0`, `PACC0`, `AGX`
/// (+ each ` SRAM`), 32 bins each, ~4.4k samples/s. Bin names are padded UPPER bounds of
/// uniform-width bins (`" 0.250W"`, `" 0.500W"`, … / `"   1W"`, `"   2W"`, …), so bin i spans
/// `(i·w, (i+1)·w]` and its midpoint is `(i+0.5)·w`. The last bin is open-ended (its midpoint
/// under-reads a cluster saturating above `32·w`; Mac17,2 never gets there).

/// One histogram channel: bin width (parsed once from the first bin's name) + cumulative
/// residency (sample counts) per bin.
struct PowerHistogramChannel: Sendable, Equatable {
    var binWidthW: Double
    var bins: [UInt64]
}

/// `" 0.250W"` → 0.25, `"   1W"` → 1. Whitespace-trimmed, must end in `W`, must be a finite
/// positive number — anything else is a topology we don't understand (nil ⇒ channel unusable).
func histogramBinWidthW(firstBinName: String) -> Double? {
    var text = firstBinName.trimmingCharacters(in: .whitespaces)
    guard text.hasSuffix("W") else { return nil }
    text.removeLast()
    guard let width = Double(text), width.isFinite, width > 0 else { return nil }
    return width
}

/// Interval-average watts from two cumulative residency snapshots: Σ Δᵢ·(i+0.5)·w / Σ Δᵢ.
/// nil on shape mismatch, non-positive width, any bin going backwards (counter reset), or no
/// new samples — the caller re-baselines instead of emitting a bogus number.
func histogramMeanWatts(prev: [UInt64], curr: [UInt64], binWidthW: Double) -> Double? {
    guard prev.count == curr.count, !curr.isEmpty, binWidthW > 0 else { return nil }
    var weighted = 0.0, total = 0.0
    for i in curr.indices {
        if curr[i] < prev[i] { return nil }
        let delta = Double(curr[i] - prev[i])
        weighted += delta * (Double(i) + 0.5) * binWidthW
        total += delta
    }
    return total > 0 ? weighted / total : nil
}

/// Exactly `EACC<n>` / `PACC<n>` — the per-cluster CPU power histograms. ` SRAM` siblings and
/// `AGX` deliberately do not match (decision: CPU = clusters without SRAM, closest to the
/// macOS ≤ 26 per-core sum). Multi-die chips contribute `EACC1`/`PACC1`… too.
func isCPUClusterHistogramChannel(_ name: String) -> Bool {
    for prefix in ["EACC", "PACC"] where name.hasPrefix(prefix) {
        let rest = name.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }
    return false
}

/// CPU watts = sum of every cluster channel's interval mean. nil if no cluster channel is
/// present, a channel lacks a baseline, its width changed, or its mean is nil (reset / no
/// samples) — partial sums would silently under-read.
func clusterHistogramCPUWatts(prev: [String: PowerHistogramChannel],
                              curr: [String: PowerHistogramChannel]) -> Double? {
    var sum = 0.0
    var matched = 0
    for (name, c) in curr where isCPUClusterHistogramChannel(name) {
        guard let p = prev[name], p.binWidthW == c.binWidthW,
              let watts = histogramMeanWatts(prev: p.bins, curr: c.bins, binWidthW: c.binWidthW)
        else { return nil }
        sum += watts
        matched += 1
    }
    return matched > 0 ? sum : nil
}
