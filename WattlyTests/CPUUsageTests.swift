import Testing
@testable import Wattly

/// Deterministic CPU derivation from synthetic ticks — no hardware (issue 18,
/// spec 04-cpu-spine.md:34).
struct CPUUsageTests {
    private func ticks(user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0) -> CoreTicks {
        CoreTicks(user: user, system: system, idle: idle, nice: nice)
    }

    @Test func zeroDeltaIsZeroNotNaN() {
        let t = ticks(user: 100, system: 50, idle: 200, nice: 10)
        let topo = [PerfLevel(name: "Performance", coreCount: 1),
                    PerfLevel(name: "Efficiency", coreCount: 1)]
        let s = cpuUsage(prev: [t, t], curr: [t, t], topology: topo)
        #expect(s.overall == 0)
        #expect(!s.overall.isNaN)
        #expect(s.perfLevels.allSatisfy { $0.usage == 0 })
        #expect(s.perfLevels.flatMap(\.cores).allSatisfy { $0 == 0 })
    }

    @Test func busyIncludesNiceOverIdle() {
        // busy = user+system+nice = 30+10+20 = 60; total = busy+idle = 100 → 60%
        let c = ticks(user: 30, system: 10, idle: 40, nice: 20)
        let s = cpuUsage(prev: [ticks()], curr: [c], topology: [PerfLevel(name: "Performance", coreCount: 1)])
        #expect(s.overall == 60)
        #expect(s.perfLevels.count == 1)
        #expect(s.perfLevels[0].name == "Performance")
        #expect(s.perfLevels[0].cores == [60])
    }

    @Test func perLevelTickWeightedAverageAndGrouping() {
        let z = ticks()
        let p0 = ticks(user: 80, idle: 20)   // 80%
        let p1 = ticks(user: 40, idle: 60)   // 40%
        let e0 = ticks(user: 10, idle: 90)   // 10%
        let topo = [PerfLevel(name: "Performance", coreCount: 2),
                    PerfLevel(name: "Efficiency", coreCount: 1)]
        let s = cpuUsage(prev: [z, z, z], curr: [p0, p1, e0], topology: topo)
        #expect(s.perfLevels.count == 2)
        #expect(s.perfLevels[0].name == "Performance")
        #expect(s.perfLevels[0].cores == [80, 40])
        #expect(s.perfLevels[0].usage == 60)            // (80+40)/(100+100)
        #expect(s.perfLevels[1].cores == [10])
        #expect(s.perfLevels[1].usage == 10)
        #expect(abs(s.overall - 130.0 / 3.0) < 0.0001)  // (80+40+10)/300
    }

    @Test func fallbackToFlatGroupOnTopologyMismatch() {
        let z = ticks()
        let c0 = ticks(user: 50, idle: 50)
        let c1 = ticks(user: 25, idle: 75)
        // topology claims 5 cores but only 2 sampled → degrade to one "C" group
        let s = cpuUsage(prev: [z, z], curr: [c0, c1], topology: [PerfLevel(name: "Performance", coreCount: 5)])
        #expect(s.perfLevels.count == 1)
        #expect(s.perfLevels[0].name == "C")
        #expect(s.perfLevels[0].cores == [50, 25])
    }

    @Test func emptyTopologyFallsBackToFlatGroup() {
        let s = cpuUsage(prev: [ticks()], curr: [ticks(user: 50, idle: 50)], topology: [])
        #expect(s.perfLevels.count == 1)
        #expect(s.perfLevels[0].name == "C")
        #expect(s.perfLevels[0].cores == [50])
    }
}
