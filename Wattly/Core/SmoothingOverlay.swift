import Foundation

/// Per-card display-smoothing overlay (issue: match MX Power Gadget's damped readout):
/// the EMA-smoothed sample, the last poll instant, and the smoothed sparkline series for
/// ONE smoothable card. The raw measurement is untouched — this is a *presentation*
/// overlay kept parallel to the raw `states`/`history`.
///
/// A **value type on purpose**: it is a stored property of the `@Observable`
/// `SystemMonitor`, so every `ingest`/`reset` mutates the struct in place, which the
/// macro records as a tracked property write → SwiftUI re-renders. A `class` here would
/// mutate through a reference and the write would be invisible to observation.
///
/// The overlay owns only the *shared mechanics* (dt from the last instant, history
/// append, reset). The per-card EMA *policy* — power smooths four fields independently;
/// battery smooths `netW` then re-derives mA/charge direction — is the caller's, passed
/// as the `smooth` closure, so each card's asymmetry stays next to that card.
struct SmoothingOverlay<Sample: Sendable & Equatable>: Sendable {
    /// The current smoothed sample. nil until the first `ingest` (and after `reset`).
    private(set) var sample: Sample?
    private var instant: ContinuousClock.Instant?
    /// Smoothed sparkline series — the only series the view reads when smoothing is on,
    /// so the graph matches the smoothed headline.
    private(set) var history = HistoryBuffer()

    /// One smoothing step. `smooth` receives the previous smoothed sample and the elapsed
    /// `dt` (0 on the first step, and on the first step after `reset` — so a fresh regime
    /// seeds to its raw value instead of blending across the gap) and returns the new
    /// smoothed sample; `series` extracts the scalar that sample plots.
    mutating func ingest(at now: ContinuousClock.Instant,
                         smooth: (_ previous: Sample?, _ dt: Double) -> Sample,
                         series: (Sample) -> Double) {
        let dt = instant.map { Self.seconds(from: $0, to: now) } ?? 0
        let next = smooth(sample, dt)
        sample = next
        instant = now
        history.append(series(next), at: now)
    }

    /// Drop all smoothed state so the next `ingest` re-seeds (battery plug/unplug — the
    /// charge % drains at the *average* power, so charge and discharge regimes must never
    /// blend). Clearing `instant` is what forces the next step's `dt` to 0.
    mutating func reset() { self = SmoothingOverlay() }

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}
