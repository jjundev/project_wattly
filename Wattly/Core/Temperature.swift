import Foundation

/// Pure temperature helpers (issue 08). `TemperatureProvider` does the SMC /
/// AppleSmartBattery I/O and hands these functions decoded numbers; no IOKit here,
/// so the version-fragile aggregation / profile / backoff logic is tested in one
/// place (mirrors `PowerEnergy`/`BatteryPower`/`CPUUsage`).
///
/// On-device reality (Mac17,2 / Apple M5 / macOS 26.5.1, **verified 2026-06-22** via a
/// read-only SMC index-enumeration spike — plan 08 Phase 0): CPU die temps are the
/// `Tp*` (P-core) + `Te*` (E-core) keys, GPU die temps the `Tg*` keys, all type
/// `flt ` (IEEE-754 LE float °C). "최고 온도" = the max across a category's keys.
/// Load-response confirmed the sources track real work: CPU +29 °C under a `yes`
/// saturation load, GPU +40 °C under a Metal compute burn. Other `T*` families
/// (`TPD*`/`Ta*`/`Ts*`/`TV*`/`TR*`, and the `ioft`-typed `TG0*`) are PMIC / ambient /
/// display / fixed-point sensors — NOT CPU/GPU die, so they are deliberately excluded.

// MARK: - Verified per-chip profile

/// A chip whose temperature sensors have passed the plan 08 Phase 0 gate (identity +
/// plausibility + per-category load-response). Only chips with a profile show CPU/GPU
/// temps; everything else is `noVerifiedProfile` (we never auto-classify unknown `T*`
/// keys on an unverified chip). The key lists are explicit (not a prefix glob) so each
/// profile is re-verified, not inferred — OS updates may change the set.
/// One named cluster of verified SMC keys (type `flt `). CPU splits into P-코어/E-코어;
/// GPU is one group. The `name` is the static cluster label shown in the card expand.
struct TemperatureKeyGroup: Sendable, Equatable {
    let name: String
    let keys: [String]
}

struct TemperatureProfile: Sendable, Equatable {
    /// `hw.model` values this profile is verified for (e.g. `Mac17,2`).
    let chipModels: Set<String>
    /// Verified CPU die-sensor clusters (type `flt `). Headline = average across all;
    /// each cluster is summarised (avg + hottest) in the expand.
    let cpuGroups: [TemperatureKeyGroup]
    /// Verified GPU die-sensor clusters (one group on M5).
    let gpuGroups: [TemperatureKeyGroup]
    /// Plausibility band (°C). A finite reading outside this is rejected as bogus.
    let validRange: ClosedRange<Double>
}

enum TemperatureProfiles {
    /// Apple M5 (`Mac17,2`), verified 2026-06-22 (macOS 26.5.1 / 25F80). CPU = `Tp*`
    /// (P-core) + `Te*` (E-core), GPU = `Tg*`, all `flt `. See `Temperature.swift` header.
    static let m5 = TemperatureProfile(
        chipModels: ["Mac17,2"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어",
                keys: ["Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X",
                       "Tp0a", "Tp0p", "Tp0u", "Tp0y", "Tp12", "Tp16", "Tp1E"]),
            TemperatureKeyGroup(name: "E-코어",
                keys: ["Te04", "Te08", "Te0C", "Te0R"]),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "GPU",
                keys: ["Tg04", "Tg0C", "Tg0G", "Tg0K", "Tg0O", "Tg0R", "Tg0U", "Tg0X",
                       "Tg0d", "Tg0g", "Tg0j", "Tg0m", "Tg0p", "Tg12", "Tg16", "Tg1A",
                       "Tg1I", "Tg1M", "Tg1Y", "Tg1c", "Tg1g", "Tg1o", "Tg1s"]),
        ],
        validRange: 0...120)

    static let all = [m5]

    /// The verified profile for a `hw.model`, or nil → `noVerifiedProfile` (terminal).
    static func profile(forModel model: String) -> TemperatureProfile? {
        all.first { $0.chipModels.contains(model) }
    }
}

// MARK: - Aggregation / decode

/// Hottest in-range finite reading of a category/cluster, or nil if none qualifies
/// (non-finite rejected, out-of-range rejected per profile). Empty input → nil.
func hottestCelsius(_ readings: [Double], in range: ClosedRange<Double>) -> Double? {
    readings.filter { $0.isFinite && range.contains($0) }.max()
}

/// Mean of the in-range finite readings (the card headline = category average; issue 08
/// follow-up), or nil if none qualify. Same filter as `hottestCelsius`, so the headline
/// and the per-cluster summaries never disagree on which sensors count.
func averageCelsius(_ readings: [Double], in range: ClosedRange<Double>) -> Double? {
    let valid = readings.filter { $0.isFinite && range.contains($0) }
    guard !valid.isEmpty else { return nil }
    return valid.reduce(0, +) / Double(valid.count)
}

/// Battery temperature from AppleSmartBattery `Temperature` (centi-°C on Apple silicon
/// — verified on-device: `3072` → 30.72 °C). Out-of-range → nil (plan 08 §9).
func batteryCelsius(rawCentiCelsius raw: Int, in range: ClosedRange<Double>) -> Double? {
    let c = Double(raw) / 100.0
    return range.contains(c) ? c : nil
}

// MARK: - Reconnect backoff ladder (plan 08 §7 / PRD lines 83–84)

/// Seconds to wait before the next SMC reconnect attempt, by consecutive-failure count.
/// `1` → 0 s (the immediate single reconnect), then `2…` → 1·2·4·8·16·30 s, capped.
/// Pure so the ladder is table-tested without hardware.
func reconnectBackoffSeconds(consecutiveFailures n: Int) -> Double {
    guard n >= 2 else { return 0 }                 // 0 (idle) and 1 (immediate retry) → no wait
    let ladder = [1.0, 2, 4, 8, 16, 30]
    return ladder[min(n - 2, ladder.count - 1)]
}
