import Testing
@testable import Wattly

/// Unit tests for the shared display-smoothing mechanics, in isolation (no SystemMonitor,
/// no providers). Deterministic instants come from a base `ContinuousClock.Instant` plus
/// `.advanced(by:)`, so `dt` is exact. The per-card EMA *policy* is tested via
/// `PowerSmoothingTests`; here we pin the overlay's dt/append/reset behaviour.
struct SmoothingOverlayTests {
    private let clock = ContinuousClock()

    @Test func firstIngestSeedsWithDtZero() {
        var overlay = SmoothingOverlay<Double>()
        var seenDts: [Double] = []
        overlay.ingest(at: clock.now,
                       smooth: { previous, dt in seenDts.append(dt); return previous ?? 10 },
                       series: { $0 })
        #expect(seenDts == [0])                  // no prior instant → dt 0 → seeds
        #expect(overlay.sample == 10)
        #expect(overlay.history.values == [10])
    }

    @Test func secondIngestComputesElapsedDtAndAppends() {
        var overlay = SmoothingOverlay<Double>()
        let t0 = clock.now
        overlay.ingest(at: t0, smooth: { _, _ in 10 }, series: { $0 })
        var seenDt: Double?
        overlay.ingest(at: t0.advanced(by: .seconds(2)),
                       smooth: { _, dt in seenDt = dt; return 20 },
                       series: { $0 })
        #expect(seenDt == 2)
        #expect(overlay.sample == 20)
        #expect(overlay.history.values == [10, 20])
    }

    @Test func resetClearsStateAndReseedsWithDtZero() {
        var overlay = SmoothingOverlay<Double>()
        let t0 = clock.now
        overlay.ingest(at: t0, smooth: { _, _ in 10 }, series: { $0 })
        overlay.reset()
        #expect(overlay.sample == nil)
        #expect(overlay.history.values == [])

        // Even though wall-clock advanced 5 s, the post-reset step sees dt 0 (re-seed),
        // so a fresh regime never blends across the gap — this is what guarantees the
        // battery plug/unplug seeds to its new value at once.
        var seenDt: Double?
        overlay.ingest(at: t0.advanced(by: .seconds(5)),
                       smooth: { _, dt in seenDt = dt; return 99 },
                       series: { $0 })
        #expect(seenDt == 0)
        #expect(overlay.sample == 99)
        #expect(overlay.history.values == [99])
    }

    @Test func historyPlotsTheSeriesScalar() {
        var overlay = SmoothingOverlay<Double>()
        // `series` halves the sample → the plotted scalar differs from the sample itself.
        overlay.ingest(at: clock.now, smooth: { _, _ in 8 }, series: { $0 / 2 })
        #expect(overlay.sample == 8)
        #expect(overlay.history.values == [4])
    }
}
