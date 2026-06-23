import Foundation

/// Display-only smoothing for the power-type cards (processor power + battery).
///
/// The underlying measurements are kept separate from presentation — processor power
/// uses per-core IOReport energy to match `powermetrics` scope, while battery netW is
/// cross-checked against SMC (B0AP = B0AV×B0AC = PSTR). A raw 1-second reading is *spiky*: a
/// momentary peak reads several percent above a tool like MX Power Gadget (which
/// shows a moving average), and a spiky battery watt misleads — the charge % drains
/// at the *average* power, not the peak. This applies an exponential moving average
/// to the *displayed* value so the number reads as steady as the real sustained
/// draw, while the raw series is kept untouched for the sparkline (selectable) and
/// never altered at the measurement layer.
///
/// τ (tau) is the time constant in seconds: a step change is ~63% absorbed after τ,
/// ~95% after 3τ. 4 s reads "responsive but stable", matching MX's feel.
enum PowerSmoothing {
    static let tau = 4.0

    /// Smoothing factor for an elapsed `dt`, from the continuous-time form
    /// `1 − e^(−dt/τ)`. Interval-independent by construction: a 1 s and a 2 s poll
    /// reach the same place after the same wall-clock, so changing the poll rate
    /// doesn't change how fast the number settles (unlike a fixed-α EMA). Clamped to
    /// 1 for a non-positive τ or dt (degenerate → no smoothing).
    static func alpha(dt: Double, tau: Double = tau) -> Double {
        guard tau > 0, dt > 0 else { return 1 }
        return 1 - exp(-dt / tau)
    }

    /// One EMA step on a single scalar. Re-seeds (returns `raw` verbatim) when there
    /// is no prior value or the gap is implausibly large — sleep/wake or missed polls
    /// — the same anomaly stance as `PowerProvider`, so a stale pre-gap average is
    /// never dragged into a fresh reading. Used directly for the battery card's netW
    /// (the caller resets `previous` to nil across a plug/unplug so charge and
    /// discharge regimes never blend).
    static func emaStep(previous: Double?, raw: Double, dt: Double,
                        maxGap: Double = 30, tau: Double = tau) -> Double {
        guard let p = previous, dt > 0, dt <= maxGap else { return raw }
        return p + alpha(dt: dt, tau: tau) * (raw - p)
    }

    /// One EMA step over all four processor-power fields (each smoothed independently).
    /// `processes` (issue 16 follow-up) pass through from `raw` unchanged — smoothing damps
    /// only the headline watts, never the per-app Top-N list (the card reads the smoothed
    /// sample, so without this the expand would always see `nil`).
    static func step(previous: PowerSample?, raw: PowerSample, dt: Double,
                     maxGap: Double = 30, tau: Double = tau) -> PowerSample {
        PowerSample(
            totalW: emaStep(previous: previous?.totalW, raw: raw.totalW, dt: dt, maxGap: maxGap, tau: tau),
            cpuW: emaStep(previous: previous?.cpuW, raw: raw.cpuW, dt: dt, maxGap: maxGap, tau: tau),
            gpuW: emaStep(previous: previous?.gpuW, raw: raw.gpuW, dt: dt, maxGap: maxGap, tau: tau),
            npuW: emaStep(previous: previous?.npuW, raw: raw.npuW, dt: dt, maxGap: maxGap, tau: tau),
            processes: raw.processes)
    }
}
