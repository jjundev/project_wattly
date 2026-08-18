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
/// One named cluster of verified SMC keys (type `flt `). CPU splits into S-코어/E-코어;
/// GPU splits into 클러스터 1/클러스터 2. The `name` is the static cluster label shown in the card expand.
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
    /// Verified GPU die-sensor clusters (클러스터 1 / 클러스터 2 on M5).
    let gpuGroups: [TemperatureKeyGroup]
    /// Plausibility band (°C). A finite reading outside this is rejected as bogus.
    let validRange: ClosedRange<Double>
}

enum TemperatureProfiles {
    // MARK: - Common Key Groups

    private static let baseCpuKeys = [
        "Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X", "Tp0a", "Tp0p", "Tp0u", "Tp0y"
    ]
    private static let proMaxCpuKeys = [
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X",
        "Tp0a", "Tp0d", "Tp0h", "Tp0p", "Tp0u", "Tp0y", "Tp12", "Tp16", "Tp1E"
    ]
    private static let ultraCpuKeys = proMaxCpuKeys + [
        "Tp20", "Tp24", "Tp28", "Tp2C", "Tp2G", "Tp2K", "Tp2O", "Tp2R", "Tp2U", "Tp2X",
        "Tp2a", "Tp2d", "Tp2h", "Tp2p", "Tp2u", "Tp2y", "Tp32", "Tp36", "Tp3E"
    ]

    private static let commonECoreKeys = ["Te04", "Te08", "Te09", "Te0C", "Te0H", "Te0R", "Te0S"]
    private static let ultraECoreKeys = commonECoreKeys + ["Te24", "Te28", "Te29", "Te2C", "Te2H", "Te2R", "Te2S"]

    private static let gpuCluster1Keys = [
        "Tg04", "Tg0C", "Tg0G", "Tg0K", "Tg0O", "Tg0R", "Tg0U", "Tg0X",
        "Tg0d", "Tg0g", "Tg0j", "Tg0m", "Tg0p"
    ]
    private static let gpuCluster2Keys = [
        "Tg12", "Tg16", "Tg1A", "Tg1I", "Tg1M", "Tg1Y", "Tg1c",
        "Tg1g", "Tg1o", "Tg1s"
    ]
    private static let ultraGpuClusterKeys = [
        "Tg24", "Tg2C", "Tg2G", "Tg2K", "Tg2O", "Tg2R", "Tg2U", "Tg2X",
        "Tg32", "Tg36", "Tg3A", "Tg3I", "Tg3M", "Tg3Y"
    ]

    // MARK: - M1 Series

    /// Apple M1 (MacBook Air, MacBook Pro 13", Mac mini, iMac 24")
    static let m1Base = TemperatureProfile(
        chipModels: ["MacBookAir10,1", "MacBookPro17,1", "Macmini9,1", "iMac21,1", "iMac21,2"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: baseCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M1 Pro / Max (MacBook Pro 14"/16", Mac Studio)
    static let m1ProMax = TemperatureProfile(
        chipModels: ["MacBookPro18,3", "MacBookPro18,1", "MacBookPro18,4", "MacBookPro18,2", "Mac13,1"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: proMaxCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M1 Ultra (Mac Studio)
    static let m1Ultra = TemperatureProfile(
        chipModels: ["Mac13,2"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: ultraCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: ultraECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "다이 1", keys: gpuCluster1Keys + gpuCluster2Keys),
            TemperatureKeyGroup(name: "다이 2", keys: ultraGpuClusterKeys),
        ],
        validRange: 0...120)

    // MARK: - M2 Series

    /// Apple M2 (MacBook Air 13"/15", MacBook Pro 13", Mac mini)
    static let m2Base = TemperatureProfile(
        chipModels: ["Mac14,2", "Mac14,15", "Mac14,7", "Mac14,3"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: baseCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M2 Pro / Max (MacBook Pro 14"/16", Mac mini, Mac Studio)
    static let m2ProMax = TemperatureProfile(
        chipModels: ["Mac14,9", "Mac14,10", "Mac14,12", "Mac14,5", "Mac14,6", "Mac14,13"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: proMaxCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M2 Ultra (Mac Studio, Mac Pro)
    static let m2Ultra = TemperatureProfile(
        chipModels: ["Mac14,14", "Mac14,8"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: ultraCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: ultraECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "다이 1", keys: gpuCluster1Keys + gpuCluster2Keys),
            TemperatureKeyGroup(name: "다이 2", keys: ultraGpuClusterKeys),
        ],
        validRange: 0...120)

    // MARK: - M3 Series

    /// Apple M3 (MacBook Pro 14", MacBook Air 13"/15", iMac 24")
    static let m3Base = TemperatureProfile(
        chipModels: ["Mac15,3", "Mac15,12", "Mac15,13", "Mac15,4", "Mac15,5"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: baseCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M3 Pro / Max (MacBook Pro 14"/16", Mac mini / Mac Studio)
    static let m3ProMax = TemperatureProfile(
        chipModels: ["Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: proMaxCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    // MARK: - M4 Series

    /// Apple M4 (MacBook Air 13"/15", MacBook Pro 14", Mac mini, iMac 24")
    static let m4Base = TemperatureProfile(
        chipModels: ["Mac16,12", "Mac16,13", "Mac16,1", "Mac16,10", "Mac16,2", "Mac16,3"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: baseCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M4 Pro / Max (MacBook Pro 14"/16", Mac mini Pro)
    static let m4ProMax = TemperatureProfile(
        chipModels: ["Mac16,8", "Mac16,6", "Mac16,7", "Mac16,5", "Mac16,11"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: proMaxCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    // MARK: - M5 Series

    /// Apple M5 (`Mac17,2`), verified 2026-06-22 (macOS 26.5.1 / 25F80)
    static let m5Base = TemperatureProfile(
        chipModels: ["Mac17,2"],
        cpuGroups: [
            TemperatureKeyGroup(name: "S-코어", keys: baseCpuKeys + ["Tp12", "Tp16", "Tp1E"]),
            TemperatureKeyGroup(name: "E-코어", keys: ["Te04", "Te08", "Te0C", "Te0R"]),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M5 Pro / Max (MacBook Pro 14"/16")
    static let m5ProMax = TemperatureProfile(
        chipModels: ["Mac17,9", "Mac17,8", "Mac17,7", "Mac17,6"],
        cpuGroups: [
            TemperatureKeyGroup(name: "S-코어", keys: proMaxCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Backwards compatibility alias for `m5Base`
    static var m5: TemperatureProfile { m5Base }

    static let all: [TemperatureProfile] = [
        m1Base, m1ProMax, m1Ultra,
        m2Base, m2ProMax, m2Ultra,
        m3Base, m3ProMax,
        m4Base, m4ProMax,
        m5Base, m5ProMax
    ]

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
