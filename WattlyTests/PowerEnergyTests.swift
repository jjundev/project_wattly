import Testing
@testable import Wattly

/// Deterministic SoC-power derivation from synthetic energy snapshots — no IOReport,
/// no hardware (issue 18, spec 06-power-ioreport-soc.md). The private-API I/O in
/// `PowerProvider`/`IOReportEnergySubscription` is verified on-device, not here.
struct PowerEnergyTests {

    // MARK: unitScale — units are mixed within one real sample, so this MUST decode

    @Test func unitScaleKnownLabels() {
        #expect(unitScale("J") == 1)
        #expect(unitScale("mJ") == 1e-3)
        #expect(unitScale("uJ") == 1e-6)
        #expect(unitScale("µJ") == 1e-6)
        #expect(unitScale("nJ") == 1e-9)
        #expect(unitScale("pJ") == 1e-12)
    }

    @Test func unitScaleUnknownOrNilDefaultsToMilli() {
        #expect(unitScale(nil) == 1e-3)
        #expect(unitScale("zJ") == 1e-3)
    }

    // MARK: classifyEngine — only the rolled-up aggregates map; sub-components don't

    @Test func classifyAggregatesAndExcludesSubComponents() {
        #expect(classifyEngine("CPU Energy") == .cpu)
        #expect(classifyEngine("GPU Energy") == .gpu)
        #expect(classifyEngine("GPU") == .gpu)
        #expect(classifyEngine("ANE") == .npu)   // HW channel "ANE" classified as NPU
        // Sub-components and non-engine channels must NOT be broken out:
        #expect(classifyEngine("ECPU0") == nil)
        #expect(classifyEngine("PCPU3") == nil)
        #expect(classifyEngine("PCPU0_SRAM") == nil)
        #expect(classifyEngine("ECPUDTL07") == nil)
        #expect(classifyEngine("ECPM") == nil)
        #expect(classifyEngine("ECPU") == nil)          // cluster aggregate, folded into "CPU Energy"
        #expect(classifyEngine("DRAM") == nil)          // counts toward total, not an engine breakout
    }

    // MARK: isTotalChannel — aggregates + "… Energy" sweep, sub-components excluded

    @Test func totalChannelSelection() {
        for name in ["CPU Energy", "GPU Energy", "GPU", "ANE", "DRAM", "DCS", "SOC_AON",
                     "PCIe Port 0 Energy", "apciec0 Energy"] {
            #expect(isTotalChannel(name), "\(name) should count toward total")
        }
        for name in ["ECPU0", "PCPU3", "PCPU0_SRAM", "ECPUDTL07", "ECPM", "ECPU", "PCPU"] {
            #expect(!isTotalChannel(name), "\(name) is a sub-component, must be excluded")
        }
    }

    // MARK: powerSample — the J/s → W math, dedup, and "total > breakout" property

    @Test func wattsFromEnergyDelta() {
        let prev = ["CPU Energy": 1.0, "GPU Energy": 0.5, "ANE": 0.0, "DRAM": 0.2]
        let curr = ["CPU Energy": 3.0, "GPU Energy": 1.0, "ANE": 0.0, "DRAM": 0.6]
        let s = powerSample(prev: prev, curr: curr, dt: 2.0)
        #expect(s.cpuW == 1.0)                   // (3-1)/2
        #expect(s.gpuW == 0.25)                  // (1-0.5)/2
        #expect(s.npuW == 0.0)                   // idle NPU (HW "ANE") is a valid zero, not unavailable
        #expect(abs(s.totalW - 1.45) < 1e-9)     // (2+0.5+0.4)/2 — includes DRAM beyond the breakout
        #expect(s.totalW > s.cpuW + s.gpuW + s.npuW)   // headline folds in DRAM/SoC
    }

    @Test func gpuAliasesCountedOnce() {
        // Both the coarse "GPU" (mJ) and precise "GPU Energy" appear on real chips —
        // same physical quantity. Total must not double-count; breakout prefers the
        // precise channel.
        let prev = ["GPU": 1.0, "GPU Energy": 1.0]
        let curr = ["GPU": 2.0, "GPU Energy": 2.0]
        let s = powerSample(prev: prev, curr: curr, dt: 1.0)
        #expect(s.gpuW == 1.0)                   // (2-1)/1 from "GPU Energy"
        #expect(s.totalW == 1.0)                 // counted once, not 2.0
    }

    @Test func subComponentsDoNotInflateTotal() {
        // Per-core / SRAM / DTL channels coexist with the roll-up; only "CPU Energy"
        // may count, never its parts.
        let prev = ["CPU Energy": 1.0, "ECPU0": 0.0, "PCPU0_SRAM": 0.0, "ECPUDTL07": 0.0]
        let curr = ["CPU Energy": 2.0, "ECPU0": 5.0, "PCPU0_SRAM": 5.0, "ECPUDTL07": 5.0]
        let s = powerSample(prev: prev, curr: curr, dt: 1.0)
        #expect(s.cpuW == 1.0)
        #expect(s.totalW == 1.0)                 // sub-components excluded
    }

    @Test func negativeDeltaFlooredAtZero() {
        let s = powerSample(prev: ["CPU Energy": 5.0], curr: ["CPU Energy": 3.0], dt: 1.0)
        #expect(s.cpuW == 0.0)                   // defence; anomalies re-baseline upstream
    }

    @Test func zeroDtIsZeroNotInfinity() {
        let s = powerSample(prev: ["CPU Energy": 1.0], curr: ["CPU Energy": 9.0], dt: 0.0)
        #expect(s.cpuW == 0.0)
        #expect(s.totalW.isFinite)
    }

    // MARK: hasCounterReset — sleep/wake & rollover detection

    @Test func counterResetDetection() {
        #expect(!hasCounterReset(prev: ["CPU Energy": 1.0], curr: ["CPU Energy": 2.0]))
        #expect(hasCounterReset(prev: ["CPU Energy": 5.0], curr: ["CPU Energy": 1.0]))
        #expect(!hasCounterReset(prev: [:], curr: ["CPU Energy": 1.0]))   // new channel is fine
    }
}
