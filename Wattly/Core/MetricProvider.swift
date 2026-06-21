import Foundation

/// A metric source. Implementations run off the MainActor (an `actor`, or a
/// dedicated serial context) so they can hold cross-poll raw state — previous CPU
/// ticks, an IOReport subscription, an SMC handle — without ever exposing it.
/// Only the Sendable `ProviderReading` (carrying `MetricSample`) hops back to the
/// MainActor model (L6 / PRD line 73).
protocol MetricProvider: Sendable {
    var kind: ProviderKind { get }

    /// Produce one reading. `instant` is the injected clock's time for this poll,
    /// so providers can reason about elapsed time deterministically under test.
    func read(at instant: ContinuousClock.Instant) async -> ProviderReading
}

/// A provider that can gather extra, more expensive detail on demand. The memory
/// provider enumerates top processes (a full `proc_listpids` sweep) only while the
/// memory card's expand is on-screen (issue 05 §M11) — toggled here by the model.
/// Off by default keeps the routine poll cheap (self-power, issue 03 render-stop).
protocol ProcessEnumerating: MetricProvider {
    func setEnumerating(_ enabled: Bool) async
}
