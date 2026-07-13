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
}
