import Foundation

/// THE single Sendable value type that crosses the actor boundary (PRD line 72).
/// Each provider produces exactly one case; raw C pointers are consumed and freed
/// inside the provider and never escape it.
///
/// This enum is the keystone of the whole concurrency model — if it breaks, every
/// provider and the partial-failure isolation break with it.
enum MetricSample: Sendable, Equatable {
    case cpu(CPUSample)
    case memory(MemorySample)
    case power(PowerSample)
    case battery(BatterySample)
    case temperature(TemperatureSnapshot)
    case fan(FanSample)
}

struct CPUSample: Sendable, Equatable {
    /// Overall usage, 0–100.
    var overall: Double
    /// Per perf-level usage (e.g. "S" super, "E" efficiency) — runtime names.
    var perfLevels: [PerfLevelUsage]
}

struct PerfLevelUsage: Sendable, Equatable {
    var name: String          // runtime perf-level name (e.g. "Performance", "Efficiency")
    var usage: Double          // 0–100, tick-weighted average across this level's cores
    var cores: [Double] = []   // per-core usage 0–100, in physical-cpu order (issue 04)
    /// Per-cluster active clock in GHz (plan 21), or nil when the DVFS residency source is
    /// unavailable (pre-"CPU Stats" macOS, single-cluster fallback, or first-poll baseline).
    var activeGHz: Double? = nil
}

struct MemorySample: Sendable, Equatable {
    var usedGB: Double
    var totalGB: Double
    var wiredGB: Double
    var compressedGB: Double
    /// Swap used, GiB (macOS `vm.swapusage` `xsu_used` — the number Activity Monitor's
    /// "사용된 스왑 공간" shows). 0 when there's no swap OR the sysctl was unavailable.
    var swapUsedGB: Double = 0
    /// Top memory-consuming processes (issue 05). Populated only while the memory
    /// card's expand is on-screen (gating keeps the routine poll cheap); empty
    /// otherwise. MUST stay `Equatable` — the whole `MetricSample`/`MetricState`
    /// chain synthesises `Equatable` through this field.
    var processes: [ProcessUsage] = []
    /// The kernel's memory-pressure verdict (`kern.memorystatus_vm_pressure_level`).
    /// Drives the card color when `Thresholds.memColorByPressure` is on (the macOS
    /// "활성 상태 보기" model: color by pressure, not occupancy). `nil` = sysctl
    /// unavailable → the card falls back to the used% threshold band.
    var pressure: MemoryPressure? = nil
    /// The kernel's RAM-pressure percentage (0–100), from `memorystatus_get_level` — the
    /// same number Activity Monitor's "메모리 압력" graph shows (`100 − free%`). Distinct from
    /// `pressure` (the coarse NORMAL/WARN/CRITICAL band that colors the card): this is the
    /// precise readout the sub-line prints. `nil` = the syscall was unavailable this poll →
    /// the sub-line drops the 압력 segment (never a fake 0%).
    var pressurePercent: Int? = nil
}

/// One process row in the memory card's expand (issue 05). `footprintBytes` is
/// `ri_phys_footprint` from `proc_pid_rusage`. Identifiable by pid for stable
/// SwiftUI diffing across polls.
struct ProcessUsage: Sendable, Equatable, Identifiable {
    var pid: Int32
    var name: String
    var footprintBytes: UInt64
    /// Responsible app-bundle (or executable) path for the row icon — resolved in
    /// the provider via `appBundlePath`. A `String` (not `NSImage`) so the sample
    /// stays `Sendable`; the view turns it into an icon with `NSWorkspace`. nil → no icon.
    var iconPath: String? = nil
    var id: Int32 { pid }
}

struct PowerSample: Sendable, Equatable {
    var totalW: Double
    var cpuW: Double
    var gpuW: Double
    var npuW: Double   // Apple Neural Engine; sourced from the HW "ANE" energy channel
    /// Top power-consuming processes (issue 16 follow-up). Three-state:
    /// `nil` = not measured this poll (card not expanded, OR the first sweep after expand
    /// has no delta yet / a dt anomaly → "측정 중…"); `[]` = measured but no readable
    /// consuming process → "프로세스를 읽을 수 없음"; non-empty = the Top-N rows. Carried
    /// through display smoothing UNCHANGED (smoothing damps only the headline watts).
    /// MUST stay `Equatable` — the `MetricSample`/`MetricState` chain synthesises through it.
    var processes: [ProcessPower]? = nil
}

/// One APP row in the power card's expand (issue 16 follow-up). `watts` is the app's
/// summed per-process average power over the last interval, from `ri_energy_nj` deltas
/// coalesced across helper pids by their owning `.app` (Electron apps like Claude/Chrome
/// fragment across helpers — per-pid would bury them). CPU+GPU compute energy only — ANE is
/// not attributed per-process, and only readable apps are counted, so these rows don't sum
/// to the card's Combined headline. `id` is the coalescing key (the `.app` bundle path, or
/// a per-pid fallback for non-app processes), which is also the icon path.
struct ProcessPower: Sendable, Equatable, Identifiable {
    /// Coalescing key — the `.app` bundle path (or a per-pid fallback). Stable across polls
    /// for SwiftUI diffing, and the path `NSWorkspace` resolves the icon from.
    var id: String
    var name: String
    var watts: Double
    /// App-bundle (or executable) path for the row icon — usually the same as `id`. A
    /// `String` (not `NSImage`) so the sample stays `Sendable`; the view turns it into an
    /// icon with `NSWorkspace`. nil → no icon (a per-pid fallback group).
    var iconPath: String? = nil
}

struct BatterySample: Sendable, Equatable {
    /// Net system power. `> 0` discharging, `< 0` charging. Sourced from
    /// AppleSmartBattery's directly-measured `BatteryPower` (PowerTelemetryData), which
    /// tracks a plug/unplug within ~2 s — unlike the gas-gauge `InstantAmperage`, which
    /// lags 30–60 s and reads the wrong sign under load (issue 07).
    var netW: Double
    /// Effective battery-current magnitude (abs), derived from `netW`/`volts`; the view
    /// prepends the sign.
    var milliamps: Int
    var volts: Double
    /// Charging — net power flowing into the battery (`netW < −0.2`). Drives the +/− sign
    /// and the 충전/방전 label.
    var charging: Bool
    /// Hardware `ExternalConnected` (AC adapter present). Flips immediately on
    /// plug/unplug; `SystemMonitor` resets the battery sparkline when it changes.
    var externalConnected: Bool
    /// Display-only one-minute EMA of signed net power. Providers leave this nil;
    /// `SystemMonitor` attaches it so the battery sub-line can show sustained draw.
    var average1mW: Double? = nil
}

// MARK: - Temperature (the partial-failure boundary, PRD line 74)

/// One snapshot carries all three temperature categories. CPU/GPU/battery each
/// resolve independently, so a single failing category never knocks out the
/// others (this is what makes the temperature fan-out safe).
struct TemperatureSnapshot: Sendable, Equatable {
    var cpu: CategoryReading
    var gpu: CategoryReading
    var battery: CategoryReading
}

enum CategoryReading: Sendable, Equatable {
    case reading(TemperatureReading)
    case unavailable(TemperatureError)
    case notPresent(String)   // e.g. no battery on a desktop Mac → hide the card
}

struct TemperatureReading: Sendable, Equatable {
    /// Headline temperature shown on the card, °C — the **average** of the category's
    /// verified in-range die sensors (issue 08 follow-up; the prototype showed the max,
    /// but the average is the steadier headline and matches the expand breakdown).
    var celsius: Double
    /// Per-cluster breakdown for the expand (issue 08 follow-up). CPU → P-코어 / E-코어;
    /// GPU → one GPU group. Empty for battery (a single sensor, not expandable). These
    /// are cluster *summaries* (average + hottest), not raw per-sensor lists — the SMC
    /// exposes die-region sensors, not 1:1 cores, so a cluster average is the honest unit.
    var groups: [TemperatureGroup] = []
}

/// One cluster's temperature summary for the card expand (issue 08 follow-up). `name`
/// is a static cluster label ("P-코어"/"E-코어"/"GPU"), NOT the runtime `hw.perflevel`
/// name the CPU-usage card uses. `average`/`hottest` are over that cluster's in-range
/// sensors, °C.
struct TemperatureGroup: Sendable, Equatable {
    var name: String
    var average: Double
    var hottest: Double
}

/// Retryable-vs-terminal taxonomy is a PRD concept (lines 83–84), realised in the
/// type for issue 08. It is NOT shown in the prototype, which has no retry UI.
enum TemperatureError: Sendable, Equatable {
    case connectionFailed     // retryable
    case readFailed           // transient, retryable
    case unsupportedChip      // terminal
    case noVerifiedProfile    // terminal
    case unsupportedDataType  // terminal
    case invalidReadings      // terminal

    var isRetryable: Bool {
        switch self {
        case .connectionFailed, .readFailed: true
        default: false
        }
    }
}
