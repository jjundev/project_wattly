import Foundation

/// Pure fan helpers (Phase A — fan speed). `FanProvider` does the SMC I/O and hands these
/// decoded numbers; no IOKit here, so the aggregation is tested in one place (mirrors
/// `Temperature.swift` / `PowerEnergy`). Fan RPM keys (`FNum`, `F{n}Ac/Mn/Mx/Tg`) are
/// standard SMC keys, so — unlike temperature's die sensors — there is no per-chip verified
/// profile: the provider probes `FNum` at runtime and reads whatever fans exist.

/// One physical fan's live reading (RPM). `index` is the SMC fan index (0-based); the card
/// labels it "팬 \(index + 1)". Identifiable by index for stable SwiftUI diffing.
struct FanReading: Sendable, Equatable, Identifiable {
    var index: Int
    var actualRPM: Double
    var minRPM: Double
    var maxRPM: Double
    var targetRPM: Double
    var id: Int { index }
}

/// One snapshot carries every fan's reading. Empty only transiently — the provider returns
/// `.notPresent` (fanless) or `.channelUnreadable` (stale) rather than an empty sample.
struct FanSample: Sendable, Equatable {
    var fans: [FanReading]

    /// Maximum RPM across all physical fans (e.g. 6550), or nil if no fans exist.
    var maxFanRPM: Double? {
        fans.map(\.maxRPM).filter { $0 > 0 }.max()
    }

    /// Mean fan load as a percentage of each fan's **own** ceiling (0…100), or `nil` when no
    /// fan reports a readable `maxRPM`. This is the threshold input (the warning band is
    /// defined against the ceiling, not against raw RPM, so one default pair is correct on
    /// every Mac — ceilings range roughly 4 000–7 000 RPM by model, and multi-fan Macs can
    /// differ per fan). Averaging the per-fan ratios mirrors the card headline, which averages
    /// actual RPM. Fans with `maxRPM <= 0` are *skipped*, not counted as 0 %: an unreadable
    /// ceiling is missing data, and diluting the mean with it would mask a spinning fan.
    /// Reuses `fanBarFraction` so the band and the expand-region bars share one clamp.
    var loadPercent: Double? {
        let ratios = fans
            .filter { $0.maxRPM > 0 }
            .map { CardPresentation.fanBarFraction(actual: $0.actualRPM, max: $0.maxRPM) }
        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / Double(ratios.count) * 100
    }
}

/// The card headline — the mean actual RPM across all fans (per-fan detail lives in the
/// expand). `nil` for an empty list, so callers show "—". Mirrors temperature's
/// average-across-sensors headline.
func averageRPM(_ fans: [FanReading]) -> Double? {
    guard !fans.isEmpty else { return nil }
    return fans.map(\.actualRPM).reduce(0, +) / Double(fans.count)
}

/// Safe raw-`FNum` → fan-count conversion. `smcDouble` decodes the SMC `FNum` key's bytes
/// into a `Double`, and a corrupted key-info `dataSize` (e.g. a stale/garbage read reporting
/// more than the true 1-byte size) can make that `Double` finite but astronomically large —
/// `Int(v)` TRAPS in that case. Reject anything non-finite, negative, or implausibly large
/// (no real Mac has anywhere near this many fans) *before* the `Int` conversion, so the live
/// transport degrades to `nil` (→ `.channelUnreadable`) instead of crashing the process.
func fanCount(fromRawFNum v: Double) -> Int? {
    guard v.isFinite, v >= 0, v <= 1_000_000 else { return nil }
    return Int(v)
}

/// A fan RPM field coerced into the plausible display range: the value if finite and in
/// `range`, else 0. Keeps min/max/target `Int`-safe at the render sites (a corrupt `flt `
/// SMC decode can be finite yet exceed Int64 — mirrors the FNum guard).
func plausibleRPM(_ v: Double, in range: ClosedRange<Double>) -> Double {
    (v.isFinite && range.contains(v)) ? v : 0
}

/// The hottest CPU die sensor from a temperature snapshot (°C), or `nil` when CPU temperature
/// isn't a live reading (unavailable / no verified profile) or has no cluster groups. This is
/// the honest input for a *safety*-oriented curve — the max across the P-코어/E-코어 clusters'
/// hottest sensors, not the steadier average the card headline shows. Pure; consumes the
/// existing `TemperatureSnapshot`.
func hottestCPUCelsius(_ snapshot: TemperatureSnapshot) -> Double? {
    guard case .reading(let r) = snapshot.cpu else { return nil }
    return r.groups.map(\.hottest).max()
}
