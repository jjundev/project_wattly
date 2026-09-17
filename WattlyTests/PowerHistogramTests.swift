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
}
