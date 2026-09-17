import Testing
@testable import Wattly

/// Pure PMP/Energy histogram math (macOS 27 processor-power migration). The IOReport I/O
/// in `IOReportPMPEnergySubscription` is verified on-device with `-WattlyPowerProbe`, not here.
struct PowerHistogramTests {

    // MARK: histogramBinWidthW — bin names are padded upper bounds like " 0.250W" / "   1W"

    @Test func binWidthParsesPaddedNames() {
        #expect(histogramBinWidthW(firstBinName: " 0.250W") == 0.25)
        #expect(histogramBinWidthW(firstBinName: "   1W") == 1)
        #expect(histogramBinWidthW(firstBinName: " 0.062W") == 0.062)
        #expect(histogramBinWidthW(firstBinName: "0.125W") == 0.125)
    }

    @Test func binWidthRejectsMalformedOrZero() {
        #expect(histogramBinWidthW(firstBinName: "abc") == nil)
        #expect(histogramBinWidthW(firstBinName: "   0W") == nil)
        #expect(histogramBinWidthW(firstBinName: "1") == nil)          // no unit suffix
        #expect(histogramBinWidthW(firstBinName: "") == nil)
        #expect(histogramBinWidthW(firstBinName: "-1W") == nil)
    }

    // MARK: histogramMeanWatts — Σ Δᵢ·(i+0.5)·w / Σ Δᵢ over cumulative residency bins

    @Test func meanOfSingleBinIsThatBinsMidpoint() {
        // all 100 new samples landed in bin 2 of a 1 W-wide histogram → (2+0.5)·1 = 2.5 W
        let prev: [UInt64] = [10, 20, 30, 40]
        let curr: [UInt64] = [10, 20, 130, 40]
        #expect(histogramMeanWatts(prev: prev, curr: curr, binWidthW: 1) == 2.5)
    }

    @Test func meanIsSampleWeightedAcrossBins() {
        // 0.25 W bins: 300 samples at 0.125 W, 100 at 0.375 W → (37.5 + 37.5) / 400 = 0.1875 W
        let prev: [UInt64] = [0, 0, 0]
        let curr: [UInt64] = [300, 100, 0]
        let w = histogramMeanWatts(prev: prev, curr: curr, binWidthW: 0.25)
        #expect(w != nil)
        #expect(abs(w! - 0.1875) < 1e-12)
    }

    @Test func meanIsNilWhenNoSamplesArrived() {
        #expect(histogramMeanWatts(prev: [5, 5], curr: [5, 5], binWidthW: 1) == nil)
    }

    @Test func meanIsNilOnCounterReset() {
        #expect(histogramMeanWatts(prev: [5, 9], curr: [6, 3], binWidthW: 1) == nil)
    }

    @Test func meanIsNilOnShapeMismatchOrEmpty() {
        #expect(histogramMeanWatts(prev: [1, 2], curr: [1, 2, 3], binWidthW: 1) == nil)
        #expect(histogramMeanWatts(prev: [], curr: [], binWidthW: 1) == nil)
        #expect(histogramMeanWatts(prev: [0], curr: [1], binWidthW: 0) == nil)
    }

    // MARK: isCPUClusterHistogramChannel — exactly EACC<n>/PACC<n>; SRAM/AGX never

    @Test func clusterChannelNamesAreExact() {
        #expect(isCPUClusterHistogramChannel("EACC0"))
        #expect(isCPUClusterHistogramChannel("PACC0"))
        #expect(isCPUClusterHistogramChannel("PACC1"))           // multi-die
        #expect(!isCPUClusterHistogramChannel("EACC0 SRAM"))     // SRAM excluded by decision
        #expect(!isCPUClusterHistogramChannel("AGX"))
        #expect(!isCPUClusterHistogramChannel("EACC"))
        #expect(!isCPUClusterHistogramChannel("PACC0 "))
        #expect(!isCPUClusterHistogramChannel(""))
    }

    // MARK: clusterHistogramCPUWatts — sum of matching channels; any nil ⇒ nil

    @Test func clusterWattsSumsEfficiencyAndPerformance() {
        let prev = [
            "EACC0": PowerHistogramChannel(binWidthW: 0.25, bins: [0, 0]),
            "PACC0": PowerHistogramChannel(binWidthW: 1, bins: [0, 0]),
            "EACC0 SRAM": PowerHistogramChannel(binWidthW: 0.062, bins: [0, 0]),
            "AGX": PowerHistogramChannel(binWidthW: 1, bins: [0, 0]),
        ]
        let curr = [
            "EACC0": PowerHistogramChannel(binWidthW: 0.25, bins: [100, 0]),   // 0.125 W
            "PACC0": PowerHistogramChannel(binWidthW: 1, bins: [0, 100]),      // 1.5 W
            "EACC0 SRAM": PowerHistogramChannel(binWidthW: 0.062, bins: [100, 0]),
            "AGX": PowerHistogramChannel(binWidthW: 1, bins: [0, 100]),
        ]
        let w = clusterHistogramCPUWatts(prev: prev, curr: curr)
        #expect(w != nil)
        #expect(abs(w! - 1.625) < 1e-12)                          // SRAM + AGX excluded
    }

    @Test func clusterWattsIsNilWhenAnyClusterIsUnreadable() {
        let prev = [
            "EACC0": PowerHistogramChannel(binWidthW: 0.25, bins: [0, 0]),
            "PACC0": PowerHistogramChannel(binWidthW: 1, bins: [5, 0]),
        ]
        let curr = [
            "EACC0": PowerHistogramChannel(binWidthW: 0.25, bins: [100, 0]),
            "PACC0": PowerHistogramChannel(binWidthW: 1, bins: [1, 0]),        // reset
        ]
        #expect(clusterHistogramCPUWatts(prev: prev, curr: curr) == nil)
        #expect(clusterHistogramCPUWatts(prev: [:], curr: curr) == nil)         // no prev baseline
        #expect(clusterHistogramCPUWatts(prev: prev, curr: [:]) == nil)         // no cluster channel at all
    }

    // MARK: EnergyModelStaleness — 2 consecutive kept polls with zero CPU-core delta ⇒ stale, sticky

    @Test func liveEnergyModelStaysLive() {
        var s = EnergyModelStaleness()
        #expect(s.observe(cpuCoreDeltaJ: 0.15) == .live)
        #expect(s.observe(cpuCoreDeltaJ: 2.5) == .live)
        #expect(!s.isStale)
    }

    @Test func singleZeroPollIsDecidingAndResetsOnActivity() {
        var s = EnergyModelStaleness()
        #expect(s.observe(cpuCoreDeltaJ: 0) == .deciding)
        #expect(s.observe(cpuCoreDeltaJ: 0.3) == .live)       // run broken → back to live
        #expect(s.zeroRun == 0)
        #expect(!s.isStale)
    }

    @Test func twoZeroPollsBecomeStaleAndStick() {
        var s = EnergyModelStaleness()
        #expect(s.observe(cpuCoreDeltaJ: 0) == .deciding)
        #expect(s.observe(cpuCoreDeltaJ: 0) == .stale)
        #expect(s.isStale)
        // A later Energy Model refresh (big positive delta) must NOT flip back — the refresh
        // itself is the 3–5 min stale cadence, not a recovery.
        #expect(s.observe(cpuCoreDeltaJ: 800) == .stale)
        #expect(s.observe(cpuCoreDeltaJ: 0) == .stale)
    }

    @Test func negativeDeltaCountsAsZero() {
        var s = EnergyModelStaleness()
        #expect(s.observe(cpuCoreDeltaJ: -1) == .deciding)
        #expect(s.observe(cpuCoreDeltaJ: -1) == .stale)
    }

    // MARK: StaleANERate — ANE watts averaged over the Energy Model refresh interval

    @Test func aneRateIsZeroUntilSecondRefresh() {
        var r = StaleANERate()
        let t0 = ContinuousClock.now
        // non-refresh polls (core delta 0) hold the current value
        #expect(r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 0, at: t0) == 0)
        // first refresh: no previous refresh instant → still 0, but the instant is recorded
        #expect(r.observe(aneDeltaJ: 30, cpuCoreDeltaJ: 500, at: t0.advanced(by: .seconds(1))) == 0)
        // second refresh 300 s later carrying 60 J of ANE energy → 0.2 W
        let w = r.observe(aneDeltaJ: 60, cpuCoreDeltaJ: 700, at: t0.advanced(by: .seconds(301)))
        #expect(abs(w - 0.2) < 1e-9)
        #expect(abs(r.heldW - 0.2) < 1e-9)
    }

    @Test func aneRateHoldsBetweenRefreshesAndUpdatesOnNext() {
        var r = StaleANERate()
        let t0 = ContinuousClock.now
        _ = r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 500, at: t0)
        _ = r.observe(aneDeltaJ: 100, cpuCoreDeltaJ: 500, at: t0.advanced(by: .seconds(200)))   // 0.5 W
        #expect(r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 0, at: t0.advanced(by: .seconds(201))) == 0.5)
        #expect(r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 0, at: t0.advanced(by: .seconds(250))) == 0.5)
        // idle ANE across the next interval → 0
        #expect(r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 500, at: t0.advanced(by: .seconds(400))) == 0)
    }

    @Test func aneRateIgnoresNegativeEnergyAndZeroElapsed() {
        var r = StaleANERate()
        let t0 = ContinuousClock.now
        _ = r.observe(aneDeltaJ: 0, cpuCoreDeltaJ: 1, at: t0)
        #expect(r.observe(aneDeltaJ: -5, cpuCoreDeltaJ: 1, at: t0.advanced(by: .seconds(10))) == 0)
        _ = r.observe(aneDeltaJ: 10, cpuCoreDeltaJ: 1, at: t0.advanced(by: .seconds(20)))   // 1 W
        #expect(r.observe(aneDeltaJ: 10, cpuCoreDeltaJ: 1, at: t0.advanced(by: .seconds(20))) == 1) // dt 0 → hold
    }
}
