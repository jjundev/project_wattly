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

// MARK: - Fan curve (Phase B-1) — pure model, no I/O, no SMC writes

/// A CPU-temperature → target-RPM fan curve. **Fixed-band model**: the temperature anchors
/// are constant (`anchorsCelsius`); only the four RPMs are user-editable. `evaluate` is
/// piecewise-linear between anchors (flat below the first / above the last). Phase B-1 only
/// *displays* the evaluated target (a preview) — nothing writes to the SMC; actual fan
/// control is Phase B-2. JSON `RawRepresentable` so it persists via `@AppStorage`, exactly
/// like `Thresholds`.
struct FanCurve: Equatable, Sendable, RawRepresentable {
    /// The fixed temperature anchors (°C), ascending — the same for every curve.
    static let anchorsCelsius: [Double] = [40, 60, 80, 95]

    /// Target RPM at each anchor, parallel to `anchorsCelsius` (so `rpms.count == 4`).
    var rpms: [Double]

    init(rpms: [Double]) { self.rpms = rpms }

    /// Target RPM for an input temperature: `rpms.first` at/below the first anchor,
    /// `rpms.last` at/above the last, linearly interpolated between adjacent anchors. `0` if
    /// the curve is malformed (wrong rpm count) — a defensive default, never expected at runtime.
    func evaluate(inputCelsius c: Double) -> Double {
        let anchors = Self.anchorsCelsius
        guard rpms.count == anchors.count, let first = anchors.first, let last = anchors.last
        else { return 0 }
        if c <= first { return rpms[0] }
        if c >= last { return rpms[rpms.count - 1] }
        for i in 0..<(anchors.count - 1) where c >= anchors[i] && c < anchors[i + 1] {
            let t = (c - anchors[i]) / (anchors[i + 1] - anchors[i])
            return rpms[i] + t * (rpms[i + 1] - rpms[i])
        }
        return rpms[rpms.count - 1]
    }

    /// Explicit field-wise equality. Mirrors the `Thresholds` fix: a `RawRepresentable`
    /// type's synthesized `==` can resolve to the (fragile) `rawValue`-string comparison, so
    /// compare the stored RPMs directly.
    static func == (lhs: FanCurve, rhs: FanCurve) -> Bool { lhs.rpms == rhs.rpms }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let values = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        // Reject the whole value (falls back to `Defaults.fanCurve` via `@AppStorage`) if any
        // RPM is out of a sane plausibility range. Mirrors `fanCount`/`plausibleRPM`'s defense
        // against a finite-but-astronomical decode TRAPping the `Int(...)` sites in
        // `SettingsView` (slider readout, curve preview) — see `plausibleRPMHugeFiniteIsZeroNotTrap`.
        guard values.count == Self.anchorsCelsius.count,
              values.allSatisfy({ (0.0...20000.0).contains($0) }) else { return nil }
        self.init(rpms: values)
    }

    var rawValue: String {
        guard let data = try? JSONSerialization.data(withJSONObject: rpms),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
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
