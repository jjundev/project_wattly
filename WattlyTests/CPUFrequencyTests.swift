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
}
