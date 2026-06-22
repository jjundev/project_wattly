import Foundation

/// Pure per-process self-power derivation (issue 16). Wattly measures its OWN energy
/// draw so a release that turns the monitor into a battery hog is caught — the PRD's
/// "a power tool that uses lots of power is a contradiction" safeguard (PRD.md:11).
///
/// Source: `proc_pid_rusage(getpid(), RUSAGE_INFO_V6).ri_energy_nj` — a per-process
/// cumulative energy counter in nanojoules (public, no entitlement; the same libproc
/// surface `MemoryProvider` already uses). Two snapshots diffed over elapsed time give
/// average self-power in watts — the same energy→W shape as `PowerEnergy`, but a single
/// scalar instead of IOReport's 169-channel dict, so it lives in its own tiny file.
/// IOReport's "Energy Model" is SoC-wide with no per-process channel, so it is *not*
/// the source here (issue 06 findings).
///
/// On-device reality (M-series, verified 2026-06-22): busy spin ≈ 6.6 W, asleep ≈ 0 W.
/// The counter is task-scoped, so it captures Wattly's own CPU+GPU work but NOT the
/// WindowServer cost of compositing our window (a separate process) — the right scope
/// for a self-regression guard.
enum SelfPower {
    /// Elapsed time beyond which the interval is treated as a gap (missed poll, or
    /// sleep/wake — `ContinuousClock` advances through sleep) → re-baseline. Mirrors
    /// `PowerProvider.maxPlausibleDt`.
    static let maxPlausibleDt = 30.0

    /// Average self-power (watts) from two absolute nanojoule counters and the elapsed
    /// seconds, or nil when the interval is anomalous → "re-baseline, emit no value"
    /// (never a bogus spike or a clamped zero). The no-prior-sample case is the caller's;
    /// here nil means: dt ≤ 0 or dt > `maxPlausibleDt` (gap), or curr < prev (the counter
    /// reset — process restart / impossible rollover).
    static func watts(prevNanojoules prev: UInt64, currNanojoules curr: UInt64, dt: Double) -> Double? {
        guard dt > 0, dt <= maxPlausibleDt else { return nil }   // gap → re-baseline
        guard curr >= prev else { return nil }                   // counter reset → re-baseline
        return Double(curr - prev) / 1e9 / dt
    }
}
