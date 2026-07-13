import Testing
import Foundation
@testable import Wattly

struct CPUFrequencyTests {
    @Test func perfLevelActiveGHzDefaultsNil() {
        #expect(PerfLevelUsage(name: "P", usage: 0).activeGHz == nil)
    }

    // MARK: DVFS table decode
    private func dvfs(_ pairs: [(UInt32, UInt32)]) -> Data {
        var d = Data()
        for (f, v) in pairs {
            withUnsafeBytes(of: f.littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }

    @Test func decodesEightBytePairsToGHz() {
        // (2_000_000, 700) & (4_000_000, 800) → 2.0, 4.0 GHz (exactly representable).
        #expect(CPUFrequency.decodeDVFSTable(dvfs([(2_000_000, 700), (4_000_000, 800)])) == [2.0, 4.0])
    }

    @Test func keepsEveryEntryIncludingZeroForBinAlignment() {
        // A zero-freq padding entry is KEPT (as 0.0) so table index stays aligned to residency bins.
        #expect(CPUFrequency.decodeDVFSTable(dvfs([(1_000_000, 700), (0, 0), (2_000_000, 800)])) == [1.0, 0.0, 2.0])
    }

    // MARK: active-frequency weighting
    @Test func weightsResidencyDeltasSkippingIdleBin() {
        // table [2.0, 4.0]; bins [idle, s0, s1]. delta idle 0, s0 3@2.0, s1 1@4.0 → (6+4)/4 = 2.5
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0, 4.0], prev: [10, 0, 0], curr: [10, 3, 1]) == 2.5)
    }

    @Test func fullyIdleIntervalIsNil() {
        // only the idle bin advanced → no active dwell.
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0, 4.0], prev: [10, 5, 5], curr: [20, 5, 5]) == nil)
    }

    @Test func counterResetIsNil() {
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0], prev: [0, 100], curr: [0, 40]) == nil)
    }

    @Test func mismatchedLengthsAreNil() {
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0], prev: [0, 1], curr: [0, 1, 2]) == nil)
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0], prev: [5], curr: [5]) == nil)
    }

    @Test func ignoresBinsBeyondTableLength() {
        // table has 1 entry but there are 2 active bins → only bin 1 (↔ table[0]) counts.
        // delta bin1 = 2 @ 2.0 GHz → weighted 4 / total 2 = 2.0; the extra bin is truncated by min().
        #expect(CPUFrequency.activeGHz(tableGHz: [2.0], prev: [0, 1, 1], curr: [0, 3, 9]) == 2.0)
    }

    // MARK: order-based attach
    @Test func attachesClockByPerfLevelOrder() {
        let s = CPUSample(overall: 50, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 60, cores: [60]),
            PerfLevelUsage(name: "Efficiency", usage: 20, cores: [20]),
        ])
        let out = CPUFrequency.attaching(s, clockGHz: [3.4, 2.1])
        #expect(out.perfLevels[0].activeGHz == 3.4)
        #expect(out.perfLevels[1].activeGHz == 2.1)
    }

    @Test func attachToleratesNilAndShortArray() {
        let s = CPUSample(overall: 0, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 0, cores: []),
            PerfLevelUsage(name: "Efficiency", usage: 0, cores: []),
        ])
        let out = CPUFrequency.attaching(s, clockGHz: [nil])   // short + nil
        #expect(out.perfLevels[0].activeGHz == nil)
        #expect(out.perfLevels[1].activeGHz == nil)
    }
}
