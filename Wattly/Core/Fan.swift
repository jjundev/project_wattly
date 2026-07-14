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
}

/// The card headline — the mean actual RPM across all fans (per-fan detail lives in the
/// expand). `nil` for an empty list, so callers show "—". Mirrors temperature's
/// average-across-sensors headline.
func averageRPM(_ fans: [FanReading]) -> Double? {
    guard !fans.isEmpty else { return nil }
    return fans.map(\.actualRPM).reduce(0, +) / Double(fans.count)
}
