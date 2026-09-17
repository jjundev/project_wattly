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

    @Test func unitScaleUnknownOrNilIsRejected() {
        #expect(unitScale(nil) == nil)
        #expect(unitScale("zJ") == nil)
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

    @Test func cpuCoreChannelPatternsAreExact() {
        for name in ["ECPU0", "ECPU5", "PCPU0", "PCPU12", "MCPU0", "MCPU1_0",
                     "PACC_0", "PACC0_CPU0", "EACC_CPU3"] {
            #expect(isCPUCoreEnergyChannel(name), "\(name) should be a core channel")
        }
        for name in ["ECPU", "PCPU", "CPU Energy", "ECPU0_SRAM", "PCPU0_SRAM",
                     "ECPUDTL07", "PCPUDTL010", "PACC0_CPM", "MCPU0_SRAM"] {
            #expect(!isCPUCoreEnergyChannel(name), "\(name) must not be counted as a core")
        }
    }

    // MARK: powerSample — the J/s → W math, dedup, and "total == Combined" property

    @Test func wattsFromEnergyDelta() {
        // DRAM is present but must NOT inflate totalW — Combined = CPU+GPU+ANE only.
        let prev = ["CPU Energy": 1.0, "GPU Energy": 0.5, "ANE": 0.0, "DRAM": 0.2]
        let curr = ["CPU Energy": 3.0, "GPU Energy": 1.0, "ANE": 0.0, "DRAM": 0.6]
        let s = powerSample(prev: prev, curr: curr, dt: 2.0)
        #expect(s.cpuW == 1.0)                   // (3-1)/2
        #expect(s.gpuW == 0.25)                  // (1-0.5)/2
        #expect(s.npuW == 0.0)                   // idle NPU (HW "ANE") is a valid zero, not unavailable
        #expect(abs(s.totalW - 1.25) < 1e-9)     // (2+0.5)/2 — CPU+GPU+ANE, DRAM excluded
        #expect(s.totalW == s.cpuW + s.gpuW + s.npuW)   // headline == Combined breakout
    }

    @Test func perCoreSumIsPreferredOverBroaderCPURollup() {
        let prev = ["CPU Energy": 10.0, "ECPU0": 1.0, "PCPU0": 2.0, "GPU Energy": 0.0]
        let curr = ["CPU Energy": 20.0, "ECPU0": 2.0, "PCPU0": 4.0, "GPU Energy": 1.0]
        let s = powerSample(prev: prev, curr: curr, dt: 1.0)
        #expect(s.cpuW == 3.0)       // cores: (2-1) + (4-2), NOT rollup (20-10)
        #expect(s.gpuW == 1.0)
        #expect(s.totalW == 4.0)
    }

    @Test func cpuRollupIsFallbackWhenNoCoreChannelsExist() {
        let s = powerSample(prev: ["CPU Energy": 1.0], curr: ["CPU Energy": 3.0], dt: 2.0)
        #expect(s.cpuW == 1.0)
        #expect(s.totalW == 1.0)
    }

    @Test func engineChannelSetChangeRequiresRebaseline() {
        let prev = ["ECPU0": 1.0, "GPU Energy": 1.0]
        #expect(!hasEngineChannelSetChanged(prev: prev, curr: ["ECPU0": 2.0, "GPU Energy": 2.0]))
        #expect(hasEngineChannelSetChanged(prev: prev, curr: ["ECPU0": 2.0]))
        #expect(hasEngineChannelSetChanged(prev: prev, curr: ["ECPU0": 2.0, "GPU Energy": 2.0, "ANE": 0.0]))
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

    @Test func hierarchicalSubComponentsDoNotInflateCoreSum() {
        // A real per-core channel coexists with SRAM/DTL sub-components and the broader
        // roll-up. Count the core once; never add its hierarchy or the roll-up again.
        let prev = ["CPU Energy": 1.0, "ECPU0": 0.0, "PCPU0_SRAM": 0.0, "ECPUDTL07": 0.0]
        let curr = ["CPU Energy": 9.0, "ECPU0": 1.0, "PCPU0_SRAM": 5.0, "ECPUDTL07": 5.0]
        let s = powerSample(prev: prev, curr: curr, dt: 1.0)
        #expect(s.cpuW == 1.0)
        #expect(s.totalW == 1.0)                 // roll-up + sub-components excluded
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

    // MARK: overrides — macOS 27 stale-Energy-Model path swaps CPU/ANE, total stays Combined

    @Test func cpuCoreDeltaSumsRecognisedCoresOnly() {
        let prev = ["CPU Energy": 10.0, "ECPU0": 1.0, "PCPU0": 2.0, "PCPU0_SRAM": 0.0, "GPU Energy": 0.0]
        let curr = ["CPU Energy": 20.0, "ECPU0": 2.0, "PCPU0": 4.0, "PCPU0_SRAM": 9.0, "GPU Energy": 1.0]
        #expect(cpuCoreEnergyDeltaJ(prev: prev, curr: curr) == 3.0)
    }

    @Test func cpuCoreDeltaFallsBackToRollupWithoutCores() {
        #expect(cpuCoreEnergyDeltaJ(prev: ["CPU Energy": 1.0], curr: ["CPU Energy": 3.5]) == 2.5)
        #expect(cpuCoreEnergyDeltaJ(prev: [:], curr: ["GPU Energy": 3.5]) == 0)
    }

    @Test func aneDeltaSumsNPUChannels() {
        #expect(aneEnergyDeltaJ(prev: ["ANE": 1.0, "GPU": 0.0], curr: ["ANE": 4.0, "GPU": 9.0]) == 3.0)
        #expect(aneEnergyDeltaJ(prev: ["ANE": 5.0], curr: ["ANE": 1.0]) == 0)   // floored like powerSample
    }

    @Test func overridesReplaceCPUAndNPUAndRecomputeTotal() {
        // Stale Energy Model: cores read 0 J, ANE spikes 300 J in this 1 s poll.
        let prev = ["ECPU0": 5.0, "PCPU0": 5.0, "GPU Energy": 1.0, "ANE": 0.0]
        let curr = ["ECPU0": 5.0, "PCPU0": 5.0, "GPU Energy": 1.5, "ANE": 300.0]
        let s = powerSample(prev: prev, curr: curr, dt: 1.0,
                            overrides: PowerOverrides(cpuW: 1.625, npuW: 0.2))
        #expect(s.cpuW == 1.625)
        #expect(s.gpuW == 0.5)                    // GPU still from the live nJ channel
        #expect(s.npuW == 0.2)                    // not the 300 W spike
        #expect(s.totalW == s.cpuW + s.gpuW + s.npuW)
        #expect(abs(s.totalW - 2.325) < 1e-9)
    }

    @Test func partialOverrideKeepsOtherEnginesFromEnergyModel() {
        let prev = ["ECPU0": 0.0, "GPU Energy": 0.0, "ANE": 0.0]
        let curr = ["ECPU0": 2.0, "GPU Energy": 1.0, "ANE": 0.5]
        let s = powerSample(prev: prev, curr: curr, dt: 1.0, overrides: PowerOverrides(cpuW: 7.0))
        #expect(s.cpuW == 7.0)
        #expect(s.gpuW == 1.0)
        #expect(s.npuW == 0.5)
        #expect(s.totalW == 8.5)
    }

    @Test func emptyOverridesMatchLegacyBehaviour() {
        let prev = ["ECPU0": 1.0, "PCPU0": 2.0, "GPU Energy": 0.5, "ANE": 0.0]
        let curr = ["ECPU0": 2.0, "PCPU0": 4.0, "GPU Energy": 1.0, "ANE": 0.25]
        let legacy = powerSample(prev: prev, curr: curr, dt: 0.5)
        let explicit = powerSample(prev: prev, curr: curr, dt: 0.5, overrides: PowerOverrides())
        #expect(legacy == explicit)
        #expect(legacy.cpuW == 6.0)
        #expect(legacy.totalW == 7.5)
    }
}
